// db.v is the V transpile of
// ../once-campfire-python/src/campfile/db.py: the Rails-compatible SQLite
// mapping. Table and column names come from database/schema.sql (the same
// schema the Go port and the Rails app use), so one database file opens in
// every port.
//
// Representation notes, documented differences rather than silent ones:
//
//   - involvement and room type live as Rails strings in the DB
//     (involvement_name/kind_type below) and map to the domain int enums at
//     the boundary.
//   - timestamps are stored as Rails datetime(6) text; the domain counts
//     epoch seconds, so to_db_time/from_db_time convert at the boundary.
//   - message_mentions is an extension table (Rails embeds mentions in the
//     rich text body). The sibling ports ignore unknown tables; the Rails
//     FTS triggers for it are created here.
module campfile

import database
import db.sqlite
import time
import campfire as c

// V only allows methods on locally declared types, so the shared engine is
// aliased here and every `def f(db, ...)` from python becomes a method.
// ---------------------------------------------------------------------------
// Enum tables (the domain int enums <-> the Rails strings in the database)
// ---------------------------------------------------------------------------

pub fn room_kind_to_type(kind i64) string {
	return match kind {
		c.room_closed { 'Rooms::Closed' }
		c.room_direct { 'Rooms::Direct' }
		else { 'Rooms::Open' }
	}
}

pub fn type_to_kind(typ string) i64 {
	return match typ {
		'Rooms::Closed' { c.room_closed }
		'Rooms::Direct' { c.room_direct }
		else { c.room_open }
	}
}

pub fn involvement_to_name(involvement i64) string {
	return c.involvement_name(involvement)
}

pub fn name_to_involvement(name string) i64 {
	return match name {
		'invisible' { c.involvement_invisible }
		'nothing' { c.involvement_nothing }
		'everything' { c.involvement_everything }
		else { c.involvement_mentions }
	}
}

// ---------------------------------------------------------------------------
// Time conversion (epoch seconds <-> Rails datetime(6) text)
// ---------------------------------------------------------------------------

pub fn to_db_time(ts i64) string {
	return database.stamp(time.unix(ts).as_utc())
}

pub fn from_db_time(value string) i64 {
	if value == '' {
		return 0
	}
	parsed := database.parse_stamp(value) or {
		return 0
	}
	return parsed.unix()
}

// ---------------------------------------------------------------------------
// Extension schema (messages mention rows and the porter FTS triggers)
// ---------------------------------------------------------------------------

const extension_sql = [
	'CREATE TABLE IF NOT EXISTS message_mentions ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "message_id" integer NOT NULL, "user_id" integer NOT NULL)',
	'CREATE INDEX IF NOT EXISTS index_message_mentions_on_message_id ON message_mentions (message_id)',
	'CREATE INDEX IF NOT EXISTS index_message_mentions_on_user_id ON message_mentions (user_id)',
	// Bodies live in action_text_rich_texts (the Rails form); the FTS index
	// follows them there. Legacy ActionText::RichText rows are covered too.
	"CREATE TRIGGER IF NOT EXISTS rich_texts_ai AFTER INSERT ON action_text_rich_texts WHEN new.record_type IN ('Message', 'ActionText::RichText') AND new.name = 'body' BEGIN INSERT INTO message_search_index(rowid, body) VALUES (new.record_id, new.body); END",
	"CREATE TRIGGER IF NOT EXISTS rich_texts_au AFTER UPDATE ON action_text_rich_texts WHEN new.record_type IN ('Message', 'ActionText::RichText') AND new.name = 'body' BEGIN UPDATE message_search_index SET body = new.body WHERE rowid = new.record_id; END",
	"CREATE TRIGGER IF NOT EXISTS rich_texts_ad AFTER DELETE ON action_text_rich_texts WHEN old.record_type IN ('Message', 'ActionText::RichText') AND old.name = 'body' BEGIN DELETE FROM message_search_index WHERE rowid = old.record_id; END",
	'CREATE TRIGGER IF NOT EXISTS rich_text_cleanup_ad AFTER DELETE ON messages BEGIN DELETE FROM action_text_rich_texts WHERE record_id = old.id AND name = \'body\' AND record_type IN (\'Message\', \'ActionText::RichText\'); END',
]

// create_extensions applies the tables the python port adds on top of the
// shared Rails schema.
pub fn create_extensions(mut d database.DB, ) ! {
	for stmt in extension_sql {
		d.exec_none(stmt, []) or { return err }
	}
}

// ---------------------------------------------------------------------------
// Bulk loading: domain Store -> database rows (ids preserved)
// ---------------------------------------------------------------------------

pub struct LoadCounts {
pub mut:
	messages i64
	fts      i64
}

// load_store is the transpile of db.py's load_store: one transaction, ids
// from the domain store so the seeded corpus matches every other port.
pub fn load_store(mut d database.DB, s c.Store, password_digest string) !LoadCounts {
	for u in s.users {
		// Rails stores NULL (not "") for absent bot tokens: NULLs do not
		// conflict in the UNIQUE index, empty strings would.
		d.exec_none('INSERT INTO users(id,name,email_address,password_digest,bio,bot_token,role,status,created_at,updated_at) VALUES(?,?,NULLIF(?, \'\'),NULLIF(?, \'\'),?,NULLIF(?, \'\'),?,?,?,?)', [
			u.id.str(),
			u.name,
			u.email,
			password_digest,
			u.bio,
			u.bot_token,
			u.role.str(),
			u.status.str(),
			to_db_time(u.created_at),
			to_db_time(u.created_at),
		]) or { return err }
	}
	for r in s.rooms {
		d.exec_none('INSERT INTO rooms(id,name,type,creator_id,created_at,updated_at) VALUES(?,NULLIF(?, \'\'),?,?,?,?)', [
			r.id.str(),
			r.name,
			room_kind_to_type(r.kind),
			r.creator_id.str(),
			to_db_time(r.created_at),
			to_db_time(r.created_at),
		]) or { return err }
	}
	for m in s.memberships {
		d.exec_none('INSERT INTO memberships(id,room_id,user_id,involvement,connections,connected_at,unread_at,created_at,updated_at) VALUES(?,?,?,?,?,NULLIF(?, \'\'),NULLIF(?, \'\'),?,?)', [
			m.id.str(),
			m.room_id.str(),
			m.user_id.str(),
			involvement_to_name(m.involvement),
			m.connections.str(),
			optional_ts(m.connected_at),
			optional_ts(m.unread_at),
			to_db_time(m.updated_at),
			to_db_time(m.updated_at),
		]) or { return err }
	}
	for m in s.messages {
		d.exec_none('INSERT INTO messages(id,room_id,creator_id,client_message_id,created_at,updated_at) VALUES(?,?,?,?,?,?)', [
			m.id.str(),
			m.room_id.str(),
			m.creator_id.str(),
			m.client_message_id,
			to_db_time(m.created_at),
			to_db_time(m.created_at),
		]) or { return err }
		d.exec_none("INSERT INTO action_text_rich_texts(record_type,record_id,name,body,created_at,updated_at) VALUES('Message',?,'body',?,?,?)", [
			m.id.str(),
			m.body,
			to_db_time(m.created_at),
			to_db_time(m.created_at),
		]) or { return err }
		for mid in m.mention_ids {
			d.exec_none('INSERT INTO message_mentions(message_id,user_id) VALUES(?,?)', [
				m.id.str(),
				mid.str(),
			]) or { return err }
		}
	}
	for b in s.boosts {
		d.exec_none('INSERT INTO boosts(id,message_id,booster_id,content,created_at,updated_at) VALUES(?,?,?,?,?,?)', [
			b.id.str(),
			b.message_id.str(),
			b.booster_id.str(),
			b.content,
			to_db_time(b.created_at),
			to_db_time(b.created_at),
		]) or { return err }
	}
	mut base := i64(0)
	if s.users.len > 0 {
		base = s.users[0].created_at
		for u in s.users {
			if u.created_at < base {
				base = u.created_at
			}
		}
	}
	for a in s.accounts {
		// The domain Account carries no timestamps; reuse the earliest user
		// time so Rails readers see a coherent NOT NULL value.
		d.exec_none('INSERT INTO accounts(id,name,join_code,singleton_guard,created_at,updated_at) VALUES(?,?,?,?,?,?)', [
			a.id.str(),
			a.name,
			a.join_code,
			a.id.str(),
			to_db_time(base),
			to_db_time(base),
		]) or { return err }
	}
	mut counts := LoadCounts{
		messages: d.query_int('SELECT count(*) FROM messages', []) or { return err }
		fts:      d.query_int('SELECT count(*) FROM message_search_index', []) or { return err }
	}
	return counts
}

// optional_ts renders an absent timestamp as '' so the NULLIF(?, '') in the
// insert above stores a real SQL NULL.
fn optional_ts(ts i64) string {
	return if ts == 0 { '' } else { to_db_time(ts) }
}

// row_i64 reads one integer column out of a sqlite row.
pub fn row_i64(row sqlite.Row, idx int) i64 {
	return row.vals[idx].i64()
}

// row_str reads one text column, mapping NULL to ''.
pub fn row_str(row sqlite.Row, idx int) string {
	if idx < 0 || idx >= row.vals.len {
		return ''
	}
	return row.vals[idx]
}
pub fn row_count(mut d database.DB) i64 {
	return d.query_int('SELECT count(*) FROM probe', []) or { -1 }
}
