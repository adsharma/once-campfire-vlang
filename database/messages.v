module database

import db.sqlite
import time

pub const message_select = "SELECT m.id,m.room_id,m.creator_id,m.client_message_id,coalesce(t.body,''),coalesce(u.name,''),m.created_at,m.updated_at FROM messages m LEFT JOIN users u ON u.id=m.creator_id LEFT JOIN action_text_rich_texts t ON t.record_type='Message' AND t.record_id=m.id AND t.name='body' "

fn scan_message_rows(rows []sqlite.Row) ![]Message {
	mut result := []Message{}
	for r in rows {
		result << Message{
			id:         r.vals[0].i64()
			room_id:    r.vals[1].i64()
			creator_id: r.vals[2].i64()
			client_id:  r.vals[3]
			body:       r.vals[4]
			creator:    r.vals[5]
			created_at: parse_stamp(r.vals[6])!
			updated_at: parse_stamp(r.vals[7])!
		}
	}
	return result
}

pub fn (mut d DB) reachable_message(user_id i64, id i64) !Message {
	rows := d.query_all(message_select + 'JOIN memberships member ON member.room_id=m.room_id WHERE member.user_id=? AND m.id=?',
		[user_id.str(), id.str()])!
	messages := scan_message_rows(rows)!
	if messages.len == 0 {
		return err_no_rows()
	}
	return messages[0]
}

pub fn (mut d DB) messages(room i64, before i64) ![]Message {
	mut query := message_select + 'WHERE m.room_id=? '
	mut args := [room.str()]
	if before != 0 {
		query += 'AND m.created_at < (SELECT created_at FROM messages WHERE id=? AND room_id=?) '
		args << before.str()
		args << room.str()
	}
	rows := d.query_all(query + 'ORDER BY m.created_at DESC LIMIT 40', args)!
	mut msgs := scan_message_rows(rows)!
	msgs.reverse_in_place()
	return msgs
}

pub fn (mut d DB) message_page(room i64, anchor i64, direction string) ![]Message {
	if direction == 'before' || anchor == 0 {
		return d.messages(room, anchor)
	}
	row := d.query_one('SELECT created_at FROM messages WHERE id=? AND room_id=?', [
		anchor.str(),
		room.str(),
	])!
	stamp_str := row.vals[0]
	after := scan_message_rows(d.query_all(message_select + 'WHERE m.room_id=? AND m.created_at>? ORDER BY m.created_at LIMIT 40',
		[room.str(), stamp_str])!)!
	if direction == 'after' {
		return after
	}
	before := d.messages(room, anchor)!
	center := scan_message_rows(d.query_all(message_select + 'WHERE m.room_id=? AND m.id=?',
		[room.str(), anchor.str()])!)!
	mut out := before.clone()
	out << center
	out << after
	return out
}

pub fn (mut d DB) refreshed_messages(room i64, since time.Time) !([]Message, []Message) {
	since_str := stamp(since)
	created := scan_message_rows(d.query_all(message_select + 'WHERE m.room_id=? AND m.created_at>? ORDER BY m.created_at LIMIT 40',
		[room.str(), since_str])!)!
	mut updated := scan_message_rows(d.query_all(message_select + 'WHERE m.room_id=? AND m.updated_at>? ORDER BY m.created_at DESC LIMIT 40',
		[room.str(), since_str])!)!
	updated.reverse_in_place()
	mut ids := map[string]bool{}
	for m in created {
		ids[m.id.str()] = true
	}
	mut fresh := []Message{}
	for m in updated {
		if m.id.str() !in ids {
			fresh << m
		}
	}
	return created, fresh
}

fn message_permission(mut tx DB, user_id i64, id i64, administer bool) !i64 {
	row := tx.tx_one('SELECT m.room_id,m.creator_id,u.role FROM messages m JOIN memberships member ON member.room_id=m.room_id JOIN users u ON u.id=member.user_id WHERE m.id=? AND u.id=? AND u.status=0',
		[id.str(), user_id.str()])!
	room := row.vals[0].i64()
	creator := row.vals[1].i64()
	role := row.vals[2].int()
	if administer && creator != user_id && role != 1 {
		return err_forbidden()
	}
	return room
}

fn touch_message(mut tx DB, id i64, room i64, now string) ! {
	tx.tx_exec('UPDATE messages SET updated_at=? WHERE id=?', [now, id.str()])!
	tx.tx_exec('UPDATE rooms SET updated_at=? WHERE id=?', [now, room.str()])!
}

pub fn (mut d DB) update_message(user_id i64, id i64, body string, plain string) !Message {
	return d.update_message_attributes(user_id, id, body, plain, none)
}

pub fn (mut d DB) update_message_attributes(user_id i64, id i64, body ?string, plain string, attachment ?i64) !Message {
	return d.update_message_with_upload(user_id, id, body, plain, attachment, none)
}

// none_staged is the empty staging slot marker.
fn (mut d DB) update_message_with_upload(user_id i64, id i64, body ?string, plain string, attachment ?i64, staged_opt ?BlobStager) !Message {
	d.manual_begin() or {
		return err
	}
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
		}
	}
	mut staged := staged_opt
	mut attach := attachment
	room := message_permission(mut d, user_id, id, true) or {
		return err
	}
	now := stamp(d.now())
	mut changed := false
	if b := body {
		old := d.tx_one("SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'",
			[id.str()]) or {
			if is_no_rows(err) {
				d.tx_exec("INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES ('body','Message',?,?,?,?)",
					[id.str(), b, now, now]) or {
					return err
				}
				changed = true
				sqlite.Row{}
			} else {
				return err
			}
		}
		if !changed && old.vals[0] != b {
			d.tx_exec("UPDATE action_text_rich_texts SET body=?,updated_at=? WHERE record_type='Message' AND record_id=? AND name='body'",
				[b, now, id.str()]) or {
				return err
			}
			changed = true
		}
	}
	if mut st := staged {
		blob := st.insert(mut d) or {
			st.discard()
			return err
		}
		attach = blob
		st.discard()
		staged = none
	}
	mut purged := []i64{}
	if a := attach {
		purged = d.attachment_blob_ids("record_type='Message' AND record_id=? AND name='attachment'",
			[id.str()]) or {
			return err
		}
		d.tx_exec("DELETE FROM active_storage_attachments WHERE record_type='Message' AND record_id=? AND name='attachment'",
			[id.str()]) or {
			return err
		}
		if a != 0 {
			d.tx_exec("INSERT INTO active_storage_attachments(blob_id,record_type,record_id,name,created_at) VALUES (?,'Message',?,'attachment',?)",
				[a.str(), id.str(), now]) or {
				return err
			}
		}
		if purged.len > 0 || a != 0 {
			changed = true
		}
	}
	if changed {
		d.tx_exec('UPDATE message_search_index SET body=? WHERE rowid=?', [plain, id.str()]) or {
			return err
		}
		touch_message(mut d, id, room, now) or {
			return err
		}
	}
	d.manual_commit() or {
		return err
	}
	failed = false
	d.purge_detached(purged)
	return d.reachable_message(user_id, id)
}

pub fn (mut d DB) delete_message(user_id i64, id i64) ! {
	d.delete_message_inner(user_id, id, true)!
}

pub fn (mut d DB) remove_banned_message(id i64) ! {
	d.delete_message_inner(0, id, false)!
}

fn (mut d DB) delete_message_inner(user_id i64, id i64, check_permission bool) ! {
	d.manual_begin() or {
		return err
	}
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
		}
	}
	mut room := i64(0)
	if check_permission {
		room = message_permission(mut d, user_id, id, true) or {
			return err
		}
	} else {
		row := d.tx_one('SELECT room_id FROM messages WHERE id=?', [id.str()]) or {
			return err
		}
		room = row.vals[0].i64()
	}
	blobs := d.attachment_blob_ids("(record_type='Message' AND record_id=?) OR (record_type='ActionText::RichText' AND record_id IN (SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?))",
		[id.str(), id.str()]) or {
		return err
	}
	for q in ['DELETE FROM boosts WHERE message_id=?',
		'DELETE FROM message_search_index WHERE rowid=?',
		"DELETE FROM active_storage_attachments WHERE record_type='ActionText::RichText' AND record_id IN (SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?)",
		"DELETE FROM active_storage_attachments WHERE record_type='Message' AND record_id=?",
		"DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",
		'DELETE FROM messages WHERE id=?'] {
		d.tx_exec(q, [id.str()]) or {
			return err
		}
	}
	d.tx_exec('UPDATE rooms SET updated_at=? WHERE id=?', [stamp(d.now()), room.str()]) or {
		return err
	}
	d.manual_commit() or {
		return err
	}
	failed = false
	d.purge_detached(blobs)
}

pub fn (mut d DB) boosts(message i64) ![]Boost {
	rows := d.query_all('SELECT b.id,b.message_id,b.booster_id,b.content,u.name,coalesce(u.bio,\'\'),u.updated_at,b.created_at,b.updated_at FROM boosts b JOIN users u ON u.id=b.booster_id WHERE b.message_id=? ORDER BY b.created_at',
		[message.str()])!
	mut result := []Boost{}
	for r in rows {
		bio := r.vals[5]
		result << Boost{
			id:                 r.vals[0].i64()
			message_id:         r.vals[1].i64()
			booster_id:         r.vals[2].i64()
			content:            r.vals[3]
			booster:            r.vals[4]
			booster_title:      User{name: r.vals[4], bio: bio}.title()
			booster_updated_at: parse_stamp(r.vals[6])!
			created_at:         parse_stamp(r.vals[7])!
			updated_at:         parse_stamp(r.vals[8])!
		}
	}
	return result
}

pub fn (mut d DB) create_boost(user_id i64, message i64, content string) !Boost {
	now := d.now()
	mut b := Boost{
		message_id: message
		booster_id: user_id
		content:    content
		created_at: now
		updated_at: now
	}
	d.manual_begin() or {
		return err
	}
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
		}
	}
	room := message_permission(mut d, user_id, message, false) or {
		return err
	}
	row := d.tx_one("SELECT name,coalesce(bio,''),updated_at FROM users WHERE id=?",
		[user_id.str()]) or {
		return err
	}
	b.booster = row.vals[0]
	b.booster_title = User{name: row.vals[0], bio: row.vals[1]}.title()
	b.booster_updated_at = parse_stamp(row.vals[2]) or {
		return err
	}
	d.tx_exec('INSERT INTO boosts(message_id,booster_id,content,created_at,updated_at) VALUES (?,?,?,?,?)',
		[message.str(), user_id.str(), b.content, stamp(now), stamp(now)]) or {
		return err
	}
	b.id = d.writer.last_insert_rowid()
	touch_message(mut d, message, room, stamp(now)) or {
		return err
	}
	d.manual_commit() or {
		return err
	}
	failed = false
	return b
}

pub fn (mut d DB) delete_boost(user_id i64, message i64, id i64) ! {
	d.manual_begin() or {
		return err
	}
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
		}
	}
	room := message_permission(mut d, user_id, message, false) or {
		return err
	}
	d.tx_exec('DELETE FROM boosts WHERE id=? AND message_id=? AND booster_id=?', [
		id.str(),
		message.str(),
		user_id.str(),
	]) or {
		return err
	}
	if d.writer.get_affected_rows_count() == 0 {
		return err_no_rows()
	}
	touch_message(mut d, message, room, stamp(d.now())) or {
		return err
	}
	d.manual_commit() or {
		return err
	}
	failed = false
}

// message is the unscoped model lookup used by background jobs.
pub fn (mut d DB) message(id i64) !Message {
	rows := d.query_all(message_select + 'WHERE m.id=?', [id.str()])!
	messages := scan_message_rows(rows)!
	if messages.len == 0 {
		return err_no_rows()
	}
	return messages[0]
}

pub fn (mut d DB) find_room(id i64) !Room {
	row := d.query_one("SELECT id,creator_id,coalesce(name,''),type,updated_at FROM rooms WHERE id=?",
		[id.str()])!
	return Room{
		id:         row.vals[0].i64()
		creator_id: row.vals[1].i64()
		name:       row.vals[2]
		typ:        row.vals[3]
		updated_at: parse_stamp(row.vals[4])!
	}
}

pub fn (mut d DB) message_page_references(room i64, anchor i64, direction string) ![]Message {
	if direction != 'before' && anchor != 0 {
		return d.message_page(room, anchor, direction)
	}
	mut query := 'SELECT id,updated_at FROM messages WHERE room_id=? '
	mut args := [room.str()]
	if anchor != 0 {
		query += 'AND created_at < (SELECT created_at FROM messages WHERE id=? AND room_id=?) '
		args << anchor.str()
		args << room.str()
	}
	rows := d.query_all(query + 'ORDER BY created_at DESC LIMIT 40', args)!
	mut messages := []Message{}
	for r in rows {
		messages << Message{
			room_id:    room
			id:         r.vals[0].i64()
			updated_at: parse_stamp(r.vals[1])!
		}
	}
	messages.reverse_in_place()
	return messages
}

pub fn (mut d DB) messages_by_id(ids []i64) ![]Message {
	mut parts := []string{cap: ids.len}
	for id in ids {
		parts << id.str()
	}
	rows := d.query_all(message_select + 'WHERE m.id IN (SELECT value FROM json_each(?))',
		['[' + parts.join(',') + ']'])!
	return scan_message_rows(rows)
}

// create_message mirrors Message and Room callbacks in the reference app models.
// Publication and job delivery happen only after this transaction commits.
pub fn (mut d DB) create_message(user_id i64, room i64, client string, body string, plain string) !Message {
	return d.create_message_opt(user_id, room, client, body, plain, 0, none, true)
}

pub fn (mut d DB) create_message_with_blob(user_id i64, room i64, client string, body string, plain string, blob i64) !Message {
	return d.create_message_opt(user_id, room, client, body, plain, blob, none, true)
}

// create_webhook_reply is called only by a queued, authorized webhook delivery.
pub fn (mut d DB) create_webhook_reply(user_id i64, room i64, body string, plain string, blob i64) !Message {
	return d.create_message_opt(user_id, room, '', body, plain, blob, none, false)
}

pub fn (mut d DB) create_message_with_upload(user_id i64, room i64, client string, body ?string, plain string, staged BlobStager, webhook bool) !Message {
	return d.create_message_opt(user_id, room, client, body, plain, 0, staged, !webhook)
}

fn (mut d DB) create_message_opt(user_id i64, room i64, client string, body ?string, plain string, blob_arg i64, staged_opt ?BlobStager, check_membership bool) !Message {
	mut client_id := client
	if client_id == '' {
		client_id = uuid()
	}
	now := d.now()
	d.manual_begin() or {
		return err
	}
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
		}
	}
	mut staged := staged_opt
	mut blob := blob_arg
	if check_membership {
		n := d.tx_one('SELECT count(*) FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.room_id=? AND m.user_id=? AND u.status=0',
			[room.str(), user_id.str()]) or {
			return err
		}
		if n.vals[0] != '1' {
			return err_forbidden()
		}
	}
	creator_row := d.tx_one('SELECT name FROM users WHERE id=?', [user_id.str()]) or {
		return err
	}
	creator := creator_row.vals[0]
	if mut st := staged {
		b := st.insert(mut d) or {
			st.discard()
			return err
		}
		blob = b
		st.discard()
		staged = none
	}
	stamp_str := stamp(now)
	d.tx_exec('INSERT INTO messages(client_message_id,creator_id,room_id,created_at,updated_at) VALUES (?,?,?,?,?)',
		[client_id, user_id.str(), room.str(), stamp_str, stamp_str]) or {
		return err
	}
	id := d.writer.last_insert_rowid()
	d.tx_exec('UPDATE rooms SET updated_at=? WHERE id=?', [stamp_str, room.str()]) or {
		return err
	}
	d.tx_exec("UPDATE memberships SET unread_at=?,updated_at=? WHERE room_id=? AND user_id!=? AND involvement!='invisible' AND (connected_at IS NULL OR connected_at < ?)",
		[stamp_str, stamp_str, room.str(), user_id.str(), stamp(now.add(-60 * time.second))]) or {
		return err
	}
	d.tx_exec('INSERT INTO message_search_index(rowid,body) VALUES (?,?)', [id.str(), plain]) or {
		return err
	}
	text := body or { '' }
	has_body := body != none
	if has_body {
		d.tx_exec("INSERT INTO action_text_rich_texts(name,record_type,record_id,body,created_at,updated_at) VALUES ('body','Message',?,?,?,?)",
			[id.str(), text, stamp_str, stamp_str]) or {
			return err
		}
	}
	if blob != 0 {
		d.tx_exec("INSERT INTO active_storage_attachments(blob_id,record_type,record_id,name,created_at) VALUES (?,'Message',?,'attachment',?)",
			[blob.str(), id.str(), stamp_str]) or {
			return err
		}
	}
	d.manual_commit() or {
		return err
	}
	failed = false
	return Message{
		id:         id
		room_id:    room
		creator_id: user_id
		client_id:  client_id
		body:       text
		creator:    creator
		created_at: now
		updated_at: now
	}
}
