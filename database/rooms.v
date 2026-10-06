module database

import time

pub fn (mut d DB) create_room(creator i64, kind string, name string, users []i64) !Room {
	mut room := Room{}
	if kind != 'Rooms::Open' && kind != 'Rooms::Closed' && kind != 'Rooms::Direct' {
		return err_validation()
	}
	mut members := users.clone()
	if kind == 'Rooms::Direct' {
		members << creator
	}
	members = unique_ids(members)
	d.manual_begin() or { return err }
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
		}
	}
	now := stamp(d.now())
	if kind == 'Rooms::Direct' {
		rows := d.tx_all("SELECT r.id,m.user_id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.type='Rooms::Direct' ORDER BY r.id,m.user_id", []) or {
			return err
		}
		mut groups := map[string][]i64{}
		mut order := []i64{}
		for r in rows {
			id := r.vals[0].i64()
			user := r.vals[1].i64()
			key := id.str()
			if key !in groups {
				order << id
				groups[key] = []i64{}
			}
			groups[key] << user
		}
		for id in order {
			if groups[id.str()] == members {
				room.id = id
				failed = false
				d.manual_rollback()
				return d.find_room_by_id(room.id)
			}
		}
	}
	if kind == 'Rooms::Direct' {
		d.tx_exec('INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES (NULL,?,?,?,?)', [
			kind,
			creator.str(),
			now,
			now,
		]) or { return err }
	} else {
		d.tx_exec('INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES (?,?,?,?,?)', [
			name,
			kind,
			creator.str(),
			now,
			now,
		]) or { return err }
	}
	room_id := d.writer.last_insert_rowid()
	room.id = room_id
	if kind == 'Rooms::Open' {
		d.tx_exec('INSERT INTO memberships(room_id,user_id,created_at,updated_at) SELECT ?,id,?,? FROM users WHERE status=0', [
			room_id.str(),
			now,
			now,
		]) or { return err }
		grant(mut d, room_id, creator, 'mentions', now) or { return err }
	} else {
		involvement := if kind == 'Rooms::Direct' { 'everything' } else { 'mentions' }
		for user in members {
			grant(mut d, room_id, user, involvement, now) or { return err }
		}
	}
	d.manual_commit() or { return err }
	failed = false
	return d.find_room_by_id(room.id)
}

fn (mut d DB) find_room_by_id(id i64) !Room {
	row := d.query_one("SELECT id,creator_id,coalesce(name,''),type,updated_at FROM rooms WHERE id=?", [
		id.str(),
	])!
	return Room{
		id:         row.vals[0].i64()
		creator_id: row.vals[1].i64()
		name:       row.vals[2]
		typ:        row.vals[3]
		updated_at: parse_stamp(row.vals[4])!
	}
}

fn unique_ids(ids []i64) []i64 {
	mut out := ids.clone()
	out.sort()
	mut compact := []i64{}
	for v in out {
		if compact.len == 0 || compact[compact.len - 1] != v {
			compact << v
		}
	}
	return compact
}

fn grant(mut d DB, room i64, user i64, involvement string, now string) ! {
	d.tx_exec('INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT ?,id,?,?,? FROM users WHERE id=? ON CONFLICT(room_id,user_id) DO NOTHING', [
		room.str(),
		involvement,
		now,
		now,
		user.str(),
	])!
}

pub fn (mut d DB) update_room(id i64, kind string, name string, users []i64) ! {
	mut revoked := []i64{}
	d.manual_begin() or { return err }
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
		}
	}
	row := d.tx_one('SELECT type FROM rooms WHERE id=?', [id.str()]) or { return err }
	old := row.vals[0]
	if old == 'Rooms::Direct' || (kind != 'Rooms::Open' && kind != 'Rooms::Closed') {
		return err_forbidden()
	}
	now := stamp(d.now())
	d.tx_exec('UPDATE rooms SET type=?,name=?,updated_at=? WHERE id=?', [kind, name, now,
		id.str()]) or { return err }
	if kind == 'Rooms::Open' && old != kind {
		d.tx_exec('INSERT INTO memberships(room_id,user_id,created_at,updated_at) SELECT ?,id,?,? FROM users WHERE status=0 ON CONFLICT(room_id,user_id) DO NOTHING', [
			id.str(),
			now,
			now,
		]) or { return err }
	} else if kind == 'Rooms::Closed' {
		members := d.tx_all('SELECT user_id FROM memberships WHERE room_id=?', [
			id.str(),
		]) or { return err }
		for r in members {
			user := r.vals[0].i64()
			if user !in users {
				revoked << user
			}
		}
		if users.len == 0 {
			d.tx_exec('DELETE FROM memberships WHERE room_id=?', [
				id.str(),
			]) or { return err }
		} else {
			mut args := [id.str()]
			mut marks := []string{}
			for user in users {
				marks << '?'
				args << user.str()
			}
			d.tx_exec(
				'DELETE FROM memberships WHERE room_id=? AND user_id NOT IN (' + marks.join(',') +
				')', args) or { return err }
			for user in unique_ids(users) {
				grant(mut d, id, user, 'mentions', now) or { return err }
			}
		}
	}
	d.manual_commit() or { return err }
	failed = false
	if f := d.reset_connections {
		for user in revoked {
			f(user)
		}
	}
}

pub fn (mut d DB) delete_room(id i64) ! {
	d.manual_begin() or { return err }
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
		}
	}
	blobs := d.attachment_blob_ids("(record_type='Message' AND record_id IN (SELECT id FROM messages WHERE room_id=?)) OR (record_type='ActionText::RichText' AND record_id IN (SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id IN (SELECT id FROM messages WHERE room_id=?)))", [
		id.str(),
		id.str(),
	]) or { return err }
	for q in [
		'DELETE FROM boosts WHERE message_id IN (SELECT id FROM messages WHERE room_id=?)',
		'DELETE FROM message_search_index WHERE rowid IN (SELECT id FROM messages WHERE room_id=?)',
		"DELETE FROM active_storage_attachments WHERE record_type='Message' AND record_id IN (SELECT id FROM messages WHERE room_id=?)",
		"DELETE FROM active_storage_attachments WHERE record_type='ActionText::RichText' AND record_id IN (SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id IN (SELECT id FROM messages WHERE room_id=?))",
		"DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id IN (SELECT id FROM messages WHERE room_id=?)",
		'DELETE FROM messages WHERE room_id=?',
		'DELETE FROM memberships WHERE room_id=?',
		'DELETE FROM rooms WHERE id=?',
	] {
		d.tx_exec(q, [id.str()]) or { return err }
	}
	d.manual_commit() or { return err }
	failed = false
	d.purge_detached(blobs)
}

pub fn (mut d DB) involvement(user_id i64, room i64) !string {
	row := d.query_one('SELECT involvement FROM memberships WHERE user_id=? AND room_id=?', [
		user_id.str(),
		room.str(),
	])!
	return row.vals[0]
}

pub fn (mut d DB) set_involvement(user_id i64, room i64, value string) ! {
	if value != 'invisible' && value != 'nothing' && value != 'mentions' && value != 'everything' {
		return err_validation()
	}
	n := d.affected('UPDATE memberships SET involvement=?,updated_at=? WHERE user_id=? AND room_id=?', [
		value,
		stamp(d.now()),
		user_id.str(),
		room.str(),
	])!
	if n == 0 {
		return err_no_rows()
	}
}

pub fn (mut d DB) presence(user_id i64, room i64, action string) ! {
	now := d.now()
	stamp_str := stamp(now)
	cutoff := stamp(now.add(-60 * time.second))
	match action {
		'present' {
			d.exec_none('UPDATE memberships SET connections=CASE WHEN connected_at>=? THEN connections+1 ELSE 1 END,connected_at=?,unread_at=NULL WHERE user_id=? AND room_id=?', [
				cutoff,
				stamp_str,
				user_id.str(),
				room.str(),
			])!
		}
		'refresh' {
			d.exec_none('UPDATE memberships SET connections=CASE WHEN connected_at>=? THEN connections ELSE 1 END,connected_at=? WHERE user_id=? AND room_id=?', [
				cutoff,
				stamp_str,
				user_id.str(),
				room.str(),
			])!
		}
		'absent' {
			d.transaction(fn [user_id, room, cutoff] (mut tx DB) ! {
				tx.tx_exec('UPDATE memberships SET connections=CASE WHEN connected_at>=? THEN max(0,connections-1) ELSE 0 END WHERE user_id=? AND room_id=?', [
					cutoff,
					user_id.str(),
					room.str(),
				])!
				tx.tx_exec('UPDATE memberships SET connected_at=NULL WHERE user_id=? AND room_id=? AND connections<1', [
					user_id.str(),
					room.str(),
				])!
			})!
		}
		else {
			return err_validation()
		}
	}
}

// original_room follows Room.original (creation order, not the fixture ID order).
pub fn (mut d DB) original_room(user_id i64) !i64 {
	return d.query_int('SELECT rooms.id FROM rooms JOIN memberships ON memberships.room_id=rooms.id WHERE memberships.user_id=? ORDER BY rooms.created_at LIMIT 1', [
		user_id.str(),
	])
}

pub fn (mut d DB) sidebar_rooms(user_id i64) ![]SidebarRoom {
	rows := d.query_all("SELECT r.id,r.creator_id,coalesce(r.name,''),r.type,r.updated_at,coalesce(m.involvement,''),m.unread_at IS NOT NULL FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? AND m.involvement!='invisible' ORDER BY lower(r.name)", [
		user_id.str(),
	])!
	mut rooms := []SidebarRoom{}
	for r in rows {
		rooms << SidebarRoom{
			room:        Room{
				id:         r.vals[0].i64()
				creator_id: r.vals[1].i64()
				name:       r.vals[2]
				typ:        r.vals[3]
				updated_at: parse_stamp(r.vals[4])!
			}
			involvement: r.vals[5]
			unread:      r.vals[6] != '0' && r.vals[6] != ''
		}
	}
	return rooms
}

pub fn (mut d DB) rooms(user_id i64) ![]Room {
	return d.rooms_inner(user_id, true)
}

pub fn (mut d DB) all_rooms(user_id i64) ![]Room {
	return d.rooms_inner(user_id, false)
}

fn (mut d DB) rooms_inner(user_id i64, visible bool) ![]Room {
	mut query := "SELECT r.id,r.creator_id,coalesce(r.name,''),r.type,r.updated_at FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=?"
	if visible {
		query += " AND m.involvement!='invisible'"
	}
	rows := d.query_all(query + ' ORDER BY lower(r.name)', [user_id.str()])!
	mut result := []Room{}
	for r in rows {
		result << Room{
			id:         r.vals[0].i64()
			creator_id: r.vals[1].i64()
			name:       r.vals[2]
			typ:        r.vals[3]
			updated_at: parse_stamp(r.vals[4])!
		}
	}
	return result
}

pub fn (mut d DB) room(user_id i64, id i64) !Room {
	row := d.query_one("SELECT r.id,r.creator_id,coalesce(r.name,''),r.type,r.updated_at FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? AND r.id=?", [
		user_id.str(),
		id.str(),
	])!
	return Room{
		id:         row.vals[0].i64()
		creator_id: row.vals[1].i64()
		name:       row.vals[2]
		typ:        row.vals[3]
		updated_at: parse_stamp(row.vals[4])!
	}
}
