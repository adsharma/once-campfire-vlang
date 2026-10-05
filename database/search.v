module database

pub fn search_query(query string) string {
	mut out := []rune{}
	for r in query.runes() {
		if (r >= `a` && r <= `z`) || (r >= `A` && r <= `Z`) || (r >= `0` && r <= `9`) || r == `_` || int(r) > 127 {
			out << r
		} else {
			out << ` `
		}
	}
	return out.string()
}

pub fn (mut d DB) search(user_id i64, query string) ![]Message {
	words := search_query(query).split(' ').filter(it != '')
	if words.len == 0 {
		return []Message{}
	}
	mut quoted := []string{cap: words.len}
	for w in words {
		quoted << '"' + w.replace('"', '""') + '"'
	}
	rows := d.query_all(message_select + 'JOIN message_search_index idx ON idx.rowid=m.id JOIN memberships member ON member.room_id=m.room_id WHERE member.user_id=? AND idx.body MATCH ? ORDER BY m.created_at DESC LIMIT 100',
		[user_id.str(), quoted.join(' ')])!
	mut messages := scan_message_rows(rows)!
	messages.reverse_in_place()
	return messages
}

pub fn (mut d DB) record_search(user_id i64, query string) ! {
	d.transaction(fn [user_id, query] (mut tx DB) ! {
		now := stamp(tx.now())
		row := tx.tx_one('SELECT id FROM searches WHERE user_id=? AND query=? LIMIT 1', [
			user_id.str(),
			query,
		]) or {
			if is_no_rows(err) {
				tx.tx_exec('INSERT INTO searches(user_id,query,created_at,updated_at) VALUES (?,?,?,?)',
					[user_id.str(), query, now, now])!
				id := tx.writer.last_insert_rowid()
				tx.tx_exec('DELETE FROM searches WHERE user_id=? AND id NOT IN (SELECT id FROM searches WHERE user_id=? ORDER BY updated_at DESC LIMIT 10)',
					[user_id.str(), user_id.str()])!
				tx.tx_exec('UPDATE searches SET updated_at=? WHERE id=?', [now, id.str()])!
				return
			}
			return err
		}
		tx.tx_exec('UPDATE searches SET updated_at=? WHERE id=?', [now, row.vals[0]])!
	})!
}

pub fn (mut d DB) recent_searches(user_id i64) ![]string {
	rows := d.query_all('SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC',
		[user_id.str()])!
	mut queries := []string{}
	for r in rows {
		queries << r.vals[0]
	}
	return queries
}

// authorized_sessions checks a publication's distinct sessions in one snapshot.
pub fn (mut d DB) authorized_sessions(tokens []string, room i64) !map[string]i64 {
	mut quoted := []string{cap: tokens.len}
	for t in tokens {
		quoted << '"' + t.replace('"', '""') + '"'
	}
	raw := '[' + quoted.join(',') + ']'
	mut query := 'SELECT s.token,s.user_id FROM sessions s JOIN users u ON u.id=s.user_id WHERE u.status=0 AND s.token IN (SELECT value FROM json_each(?))'
	mut args := [raw]
	if room != 0 {
		query += ' AND EXISTS (SELECT 1 FROM memberships m WHERE m.user_id=s.user_id AND m.room_id=?)'
		args << room.str()
	}
	rows := d.query_all(query, args)!
	mut result := map[string]i64{}
	for r in rows {
		result[r.vals[0]] = r.vals[1].i64()
	}
	return result
}
