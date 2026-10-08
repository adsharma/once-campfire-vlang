// meta.v is the V transpile of routes/meta.py: the bench discovery endpoint.
module campfile

import database


pub struct MetaInfo {
pub mut:
	users        i64
	rooms        i64
	messages     i64
	fts_rows     i64
	watercooler  i64
	first_user   i64
	busy_message i64
}

pub fn meta(mut db database.DB, r Req) Resp {
	users := db.query_int('SELECT count(*) FROM users', []) or { 0 }
	rooms := db.query_int('SELECT count(*) FROM rooms', []) or { 0 }
	total := db.query_int('SELECT count(*) FROM messages', []) or { 0 }
	fts := db.query_int('SELECT count(*) FROM message_search_index', []) or {
		0
	}
	watercooler := db.query_int('SELECT id FROM rooms ORDER BY id LIMIT 1', []) or {
		0
	}
	first_user := db.query_int('SELECT id FROM users ORDER BY id LIMIT 1', []) or {
		0
	}
	mut mid := i64(0)
	if total > 0 {
		mid = db.query_int('SELECT id FROM messages ORDER BY id LIMIT 1 OFFSET ' +
			(total / 2).str(), []) or { 0 }
	}
	_ = r
	return present(MetaInfo{
		users:        users
		rooms:        rooms
		messages:     total
		fts_rows:     fts
		watercooler:  watercooler
		first_user:   first_user
		busy_message: mid
	})
}
