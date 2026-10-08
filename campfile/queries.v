// queries.v is the V transpile of
// ../once-campfire-python/src/campfile/queries.py: the DB-backed hot paths
// (room page, message windows, sidebar, search, post) plus session auth.
//
// It mirrors workload/ exactly: same view structs, same membership scoping,
// same 40-per-page windows, same unread fan-out, same visibility rules. The
// domain rules it needs (sound_command, content_type_of, MAX_RECENT_SEARCHES,
// CONNECTION_TTL_SECS) come from campfire/ through the enum tables in
// db.v, never from SQL.
module campfile

import crypto.bcrypt
import crypto.rand
import db.sqlite
import encoding.base64
import time
import campfire as c
import workload as w
import database

pub const page_size = 40
pub const session_ttl_refresh = 3600

// msg_select is the projection every message query shares (python's
// MSG_COLNS in queries.py).
const msg_cols = 'm.id,m.room_id,m.creator_id,' + 'm.client_message_id,m.created_at,m.updated_at'

// ---------------------------------------------------------------------------
// Row views
// ---------------------------------------------------------------------------

pub struct MsgRow {
pub mut:
	id                i64
	room_id           i64
	creator_id        i64
	client_message_id string
	created_at        i64
	updated_at        i64
}

pub struct UserRow {
pub mut:
	id              i64
	name            string
	email_address   string
	password_digest string
	bio             string
	role            i64
	status          i64
}

pub struct AccountRow {
pub mut:
	id            i64
	name          string
	join_code     string
	custom_styles string
	settings      string
}

fn decode_msg(row sqlite.Row) MsgRow {
	return MsgRow{
		id:                row_i64(row, 0)
		room_id:           row_i64(row, 1)
		creator_id:        row_i64(row, 2)
		client_message_id: row_str(row, 3)
		created_at:        from_db_time(row_str(row, 4))
		updated_at:        from_db_time(row_str(row, 5))
	}
}

fn message_rows(mut d database.DB, statement string, params []string) []MsgRow {
	rows := d.query_all(statement, params) or { return []MsgRow{} }
	mut out := []MsgRow{cap: rows.len}
	for row in rows {
		out << decode_msg(row)
	}
	return out
}

// ---------------------------------------------------------------------------
// Scoped lookups
// ---------------------------------------------------------------------------

// member reports whether a user has any membership in a room.
pub fn member(mut d database.DB, room_id i64, user_id i64) bool {
	n := d.query_int('SELECT count(*) FROM memberships WHERE room_id=? AND user_id=?', [
		room_id.str(),
		user_id.str(),
	]) or { return false }
	return n > 0
}

// users_by_id maps user ids to display names.
pub fn users_by_id(mut d database.DB, ids []i64) map[i64]string {
	mut out := map[i64]string{}
	if ids.len == 0 {
		return out
	}
	rows := d.query_all(
		"SELECT id,coalesce(name,'') FROM users WHERE id IN (" + placeholders(ids.len) + ')',
		id_params(ids)) or { return out }
	for r in rows {
		out[row_i64(r, 0)] = row_str(r, 1)
	}
	return out
}

// user loads one user row by id.
pub fn user(mut d database.DB, id i64) ?UserRow {
	rows := d.query_all("SELECT id,coalesce(name,''),coalesce(email_address,''),coalesce(password_digest,''),coalesce(bio,''),role,status FROM users WHERE id=? LIMIT 1", [
		id.str(),
	]) or { return none }
	if rows.len == 0 {
		return none
	}
	r := rows[0]
	return UserRow{
		id:              row_i64(r, 0)
		name:            row_str(r, 1)
		email_address:   row_str(r, 2)
		password_digest: row_str(r, 3)
		bio:             row_str(r, 4)
		role:            row_i64(r, 5)
		status:          row_i64(r, 6)
	}
}

// boosts_by_message groups boost contents by message id.
pub fn boosts_by_message(mut d database.DB, ids []i64) map[i64][]string {
	mut out := map[i64][]string{}
	for id in ids {
		out[id] = []string{}
	}
	if ids.len == 0 {
		return out
	}
	rows := d.query_all(
		'SELECT message_id,content FROM boosts WHERE message_id IN (' + placeholders(ids.len) +
		') ORDER BY id', id_params(ids)) or { return out }
	for r in rows {
		out[row_i64(r, 0)] << row_str(r, 1)
	}
	return out
}

// mentions_by_message groups mention names by message id (empty without the extension table).
pub fn mentions_by_message(mut d database.DB, ids []i64) map[i64][]string {
	mut out := map[i64][]string{}
	for id in ids {
		out[id] = []string{}
	}
	if ids.len == 0 {
		return out
	}
	rows := d.query_all(
		"SELECT mm.message_id,coalesce(u.name,'') FROM message_mentions mm JOIN users u ON u.id=mm.user_id WHERE mm.message_id IN (" + placeholders(ids.len) +
		') ORDER BY mm.id', id_params(ids)) or {
		// Foreign schema without the extension table: mentions degrade to [].
		return out
	}
	for r in rows {
		name := row_str(r, 1)
		if name != '' {
			out[row_i64(r, 0)] << name
		}
	}
	return out
}

// bodies_by_message maps message ids to their rich-text bodies.
pub fn bodies_by_message(mut d database.DB, ids []i64) map[i64]string {
	mut out := map[i64]string{}
	if ids.len == 0 {
		return out
	}
	rows := d.query_all(
		"SELECT record_id,coalesce(body,'') FROM action_text_rich_texts WHERE name='body' AND record_type IN ('Message','ActionText::RichText') AND record_id IN (" + placeholders(ids.len) +
		') ORDER BY id', id_params(ids)) or { return out }
	for r in rows {
		out[row_i64(r, 0)] = row_str(r, 1)
	}
	return out
}

// ---------------------------------------------------------------------------
// View assembly (the same view structs the domain layer builds in memory)
// ---------------------------------------------------------------------------

// message_view assembles a workload view from a row and its preloaded maps.
pub fn message_view(m MsgRow, names map[i64]string, boosts map[i64][]string,
	mentions map[i64][]string, bodies map[i64]string) w.MessageView {
	mut v := w.MessageView{
		id:                m.id
		body:              bodies[m.id] or { '' }
		creator_id:        m.creator_id
		creator_name:      names[m.creator_id] or { '' }
		created_at:        m.created_at
		client_message_id: m.client_message_id
	}
	snd := c.sound_command(v.body)
	v.content_type = c.content_type_name(c.content_type_of(false, snd))
	v.boosts = boosts[m.id] or { []string{} }
	v.mentions = mentions[m.id] or { []string{} }
	return v
}

// views_for preloads names, boosts, mentions and bodies for a batch of rows.
pub fn views_for(mut d database.DB, msgs []MsgRow) []w.MessageView {
	mut ids := []i64{}
	mut creator_ids := []i64{}
	mut seen := map[i64]bool{}
	for m in msgs {
		ids << m.id
		if m.creator_id !in seen {
			seen[m.creator_id] = true
			creator_ids << m.creator_id
		}
	}
	names := users_by_id(mut d, creator_ids)
	boosts := boosts_by_message(mut d, ids)
	mentions := mentions_by_message(mut d, ids)
	bodies := bodies_by_message(mut d, ids)
	mut out := []w.MessageView{cap: msgs.len}
	for m in msgs {
		out << message_view(m, names, boosts, mentions, bodies)
	}
	return out
}

// ---------------------------------------------------------------------------
// Hot paths
// ---------------------------------------------------------------------------

fn page_window(mut d database.DB, room_id i64, anchor_created i64, anchor_id i64,
	ascending bool) []MsgRow {
	if ascending {
		return message_rows(mut d, 'SELECT ' + msg_cols +
			' FROM messages m WHERE m.room_id=? AND (m.created_at > ? OR (m.created_at = ? AND m.id > ?)) ORDER BY m.created_at, m.id LIMIT ' +
			page_size.str(), [room_id.str(), anchor_created.str(),
			anchor_created.str(), anchor_id.str()])
	}
	return message_rows(mut d, 'SELECT ' + msg_cols +
		' FROM messages m WHERE m.room_id=? AND (m.created_at < ? OR (m.created_at = ? AND m.id < ?)) ORDER BY m.created_at DESC, m.id DESC LIMIT ' +
		page_size.str(), [room_id.str(), anchor_created.str(),
		anchor_created.str(), anchor_id.str()])
}

fn reversed(msgs []MsgRow) []MsgRow {
	mut out := []MsgRow{cap: msgs.len}
	for i := msgs.len - 1; i >= 0; i-- {
		out << msgs[i]
	}
	return out
}

// room_page returns the newest page of a room for a member.
pub fn room_page(mut d database.DB, room_id i64, user_id i64) w.RoomPageResult {
	if !member(mut d, room_id, user_id) {
		return w.RoomPageResult{
			error: 'not a member'
		}
	}
	room := d.query_one("SELECT id,coalesce(name,''),type FROM rooms WHERE id=?", [
		room_id.str(),
	]) or { return w.RoomPageResult{
		error: 'room not found'
	} }
	rows := message_rows(mut d, 'SELECT ' + msg_cols +
		' FROM messages m WHERE m.room_id=? ORDER BY m.created_at DESC, m.id DESC LIMIT ' +
		page_size.str(), [room_id.str()])
	total := d.query_int('SELECT count(*) FROM messages m WHERE m.room_id=?', [
		room_id.str(),
	]) or { 0 }
	mut view := w.RoomPageView{
		room_id:   row_i64(room, 0)
		room_name: row_str(room, 1)
		room_kind: type_to_kind(row_str(room, 2))
		has_more:  total > page_size
	}
	for v in views_for(mut d, reversed(rows)) {
		view.messages << v
	}
	return w.RoomPageResult{
		ok:    true
		value: view
	}
}

// messages_page returns a message window around a before/after anchor.
pub fn messages_page(mut d database.DB, room_id i64, user_id i64, before_id i64,
	after_id i64) w.MessagesPageResult {
	if !member(mut d, room_id, user_id) {
		return w.MessagesPageResult{
			error: 'not a member'
		}
	}
	mut msgs := []MsgRow{}
	if before_id > 0 {
		pivot := anchor(mut d, before_id, room_id) or {
			return w.MessagesPageResult{
				error: 'message not found'
			}
		}
		msgs = reversed(page_window(mut d, room_id, pivot.created_at, pivot.id, false))
	} else if after_id > 0 {
		pivot := anchor(mut d, after_id, room_id) or {
			return w.MessagesPageResult{
				error: 'message not found'
			}
		}
		msgs = page_window(mut d, room_id, pivot.created_at, pivot.id, true)
	} else {
		msgs = reversed(message_rows(mut d, 'SELECT ' + msg_cols +
			' FROM messages m WHERE m.room_id=? ORDER BY m.created_at DESC, m.id DESC LIMIT ' +
			page_size.str(), [room_id.str()]))
	}
	return w.MessagesPageResult{
		ok:    true
		value: views_for(mut d, msgs)
	}
}

fn anchor(mut d database.DB, id i64, room_id i64) ?MsgRow {
	rows := d.query_all('SELECT ' + msg_cols + ' FROM messages m WHERE m.id=? AND m.room_id=?', [
		id.str(),
		room_id.str(),
	]) or { return none }
	if rows.len == 0 {
		return none
	}
	return decode_msg(rows[0])
}

// message_dict loads one message row by id.
pub fn message_dict(mut d database.DB, id i64) ?MsgRow {
	rows := d.query_all('SELECT ' + msg_cols + ' FROM messages m WHERE m.id=?', [
		id.str(),
	]) or { return none }
	if rows.len == 0 {
		return none
	}
	return decode_msg(rows[0])
}

// sidebar lists visible memberships ordered by room name.
pub fn sidebar(mut d database.DB, user_id i64) w.SidebarResult {
	if user(mut d, user_id) == none {
		return w.SidebarResult{
			error: 'user not found'
		}
	}
	rows := d.query_all("SELECT r.id,coalesce(r.name,''),r.type,m.involvement,m.unread_at FROM memberships m JOIN rooms r ON r.id=m.room_id WHERE m.user_id=? AND m.involvement != 'invisible' ORDER BY lower(r.name), r.id", [
		user_id.str(),
	]) or { return w.SidebarResult{} }
	mut out := []w.SidebarEntry{cap: rows.len}
	for r in rows {
		out << w.SidebarEntry{
			room_id:     row_i64(r, 0)
			room_name:   row_str(r, 1)
			room_kind:   type_to_kind(row_str(r, 2))
			unread:      from_db_time(row_str(r, 4)) != 0
			involvement: name_to_involvement(row_str(r, 3))
		}
	}
	return w.SidebarResult{
		ok:    true
		value: out
	}
}

// clean_query sanitizes a search query to word characters, like Django does.
pub fn clean_query(raw string) string {
	// Same as the Django/Rails sanitizer: everything that is not a word
	// character becomes a space, then the query is trimmed.
	mut out := []u8{}
	for ch in raw {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
			|| (ch >= `0` && ch <= `9`) || ch == `_` {
			out << ch
		} else {
			out << ` `
		}
	}
	return out.bytestr().trim_space()
}

// search_page searches FTS5 scoped to visible rooms and attaches room names.
pub fn search_page(mut d database.DB, user_id i64, query string, limit i64) w.SearchPageResult {
	if user(mut d, user_id) == none {
		return w.SearchPageResult{
			error: 'user not found'
		}
	}
	trimmed := query.trim_space()
	if trimmed == '' {
		return w.SearchPageResult{
			ok: true
		}
	}
	room_rows := d.query_all("SELECT room_id FROM memberships WHERE user_id=? AND involvement != 'invisible'", [
		user_id.str(),
	]) or { return w.SearchPageResult{
		ok: true
	} }
	mut room_ids := []i64{}
	for r in room_rows {
		room_ids << row_i64(r, 0)
	}
	if room_ids.len == 0 {
		return w.SearchPageResult{
			ok: true
		}
	}
	// Raw FTS5 query, like Rails (idx.body MATCH ?): the porter tokenizer
	// runs identically on indexed bodies and on the query.
	statement := 'SELECT ' + msg_cols +
		' FROM messages m JOIN message_search_index idx ON idx.rowid=m.id WHERE message_search_index MATCH ? AND m.room_id IN (' + placeholders(room_ids.len) +
		') ORDER BY m.created_at LIMIT ' + limit.str()
	// V array literals only take literal elements, so the bound parameters
	// are appended one at a time.
	mut args := []string{}
	args << trimmed
	args << id_params(room_ids)
	rows := d.query_all(statement, args) or {
		// FTS5 syntax error in user input: no hits, no error.
		return w.SearchPageResult{
			ok: true
		}
	}
	mut msgs := []MsgRow{}
	for r in rows {
		msgs << decode_msg(r)
	}
	name_rows := d.query_all("SELECT id,coalesce(name,'') FROM rooms", []) or {
		return w.SearchPageResult{
			ok: true
		}
	}
	mut names := map[i64]string{}
	for r in name_rows {
		names[row_i64(r, 0)] = row_str(r, 1)
	}
	mut out := []w.SearchHitView{}
	for v in views_for(mut d, msgs) {
		out << w.SearchHitView{
			message:   v
			room_name: room_name_for(msgs, v.id, names)
		}
	}
	return w.SearchPageResult{
		ok:    true
		value: out
	}
}

fn room_name_for(msgs []MsgRow, id i64, names map[i64]string) string {
	for m in msgs {
		if m.id == id {
			return names[m.room_id] or { '' }
		}
	}
	return ''
}

// post_message_view writes one message plus its rich text, marks the room
// unread for disconnected members, and returns the created row.
pub fn post_message_view(mut d database.DB, room_id i64, creator_id i64, body string,
	client_message_id string, now i64) !MsgRow {
	d.query_one('SELECT id FROM rooms WHERE id=?', [room_id.str()]) or {
		return error('room not found')
	}
	if !member(mut d, room_id, creator_id) {
		return error('creator is not a room member')
	}
	if body == '' {
		return error('body or attachment is required')
	}
	stamp := to_db_time(now)
	mut cid := client_message_id
	d.manual_begin() or { return error(err.msg()) }
	mut committed := false
	defer {
		if !committed {
			d.manual_rollback()
		}
	}
	d.tx_exec("INSERT INTO messages(room_id,creator_id,client_message_id,created_at,updated_at) VALUES(?,?,NULLIF(?,''),?,?)", [
		room_id.str(),
		creator_id.str(),
		cid,
		stamp,
		stamp,
	]) or { return error(err.msg()) }
	id := d.last_id()
	if cid == '' {
		cid = 'client-' + id.str()
		d.tx_exec('UPDATE messages SET client_message_id=? WHERE id=?', [
			cid,
			id.str(),
		]) or { return error(err.msg()) }
	}
	d.tx_exec("INSERT INTO action_text_rich_texts(record_type,record_id,name,body,created_at,updated_at) VALUES('Message',?,'body',?,?,?)", [
		id.str(),
		body,
		stamp,
		stamp,
	]) or { return error(err.msg()) }
	cutoff := to_db_time(now - c.connection_ttl_secs)
	d.tx_exec("UPDATE memberships SET unread_at=?, updated_at=? WHERE room_id=? AND user_id != ? AND involvement != 'invisible' AND (connected_at IS NULL OR connected_at < ?)", [
		stamp,
		stamp,
		room_id.str(),
		creator_id.str(),
		cutoff,
	]) or { return error(err.msg()) }
	d.tx_exec('UPDATE rooms SET updated_at=? WHERE id=?', [
		stamp,
		room_id.str(),
	]) or { return error(err.msg()) }
	d.manual_commit() or { return error(err.msg()) }
	committed = true
	return MsgRow{
		id:                id
		room_id:           room_id
		creator_id:        creator_id
		client_message_id: cid
		created_at:        now
		updated_at:        now
	}
}

// ---------------------------------------------------------------------------
// Session auth (bcrypt + token rows)
// ---------------------------------------------------------------------------

// hash_password uses V's crypto/bcrypt, the same primitive (and the same
// digest format) the Rails app and the python port store in password_digest.
pub fn hash_password(password string) string {
	return bcrypt.generate_from_password(password.bytes(), bcrypt.default_cost) or { panic(err) }
}

// authenticate verifies email plus bcrypt for an active user.
pub fn authenticate(mut d database.DB, email string, password string) ?UserRow {
	if email == '' {
		return none
	}
	row := user_by_email(mut d, email) or { return none }
	if row.password_digest == '' {
		return none
	}
	bcrypt.compare_hash_and_password(password.bytes(), row.password_digest.bytes()) or {
		return none
	}
	if row.status != 0 {
		return none
	}
	return row
}

// user_by_email loads one user row by email address.
pub fn user_by_email(mut d database.DB, email string) ?UserRow {
	rows := d.query_all("SELECT id,coalesce(name,''),coalesce(email_address,''),coalesce(password_digest,''),coalesce(bio,''),role,status FROM users WHERE email_address=? LIMIT 1", [
		email,
	]) or { return none }
	if rows.len == 0 {
		return none
	}
	r := rows[0]
	return UserRow{
		id:              row_i64(r, 0)
		name:            row_str(r, 1)
		email_address:   row_str(r, 2)
		password_digest: row_str(r, 3)
		bio:             row_str(r, 4)
		role:            row_i64(r, 5)
		status:          row_i64(r, 6)
	}
}

fn random_token() string {
	b := rand.bytes(24) or { panic(err) }
	return base64.url_encode(b)
}

// start_session inserts a session row and returns its token.
pub fn start_session(mut d database.DB, user_id i64, ip string, agent string, now i64) !string {
	token := random_token()
	stamp := to_db_time(now)
	d.exec_none("INSERT INTO sessions(user_id,token,ip_address,user_agent,last_active_at,created_at,updated_at) VALUES(?,?,NULLIF(?,''),NULLIF(?,''),?,?,?)", [
		user_id.str(),
		token,
		ip,
		agent,
		stamp,
		stamp,
		stamp,
	]) or { return err }
	return token
}

// user_from_token resolves a session token and throttles activity writes like
// Rails does (only past the refresh window).
pub fn user_from_token(mut d database.DB, token string, now i64) ?UserRow {
	if token == '' {
		return none
	}
	row := d.query_one('SELECT id,user_id,last_active_at FROM sessions WHERE token=?', [
		token,
	]) or { return none }
	last := from_db_time(row_str(row, 2))
	if now - last > session_ttl_refresh {
		stamp := to_db_time(now)
		d.exec_none('UPDATE sessions SET last_active_at=?, updated_at=? WHERE id=?', [
			stamp,
			stamp,
			row_i64(row, 0).str(),
		]) or {}
	}
	me := user(mut d, row_i64(row, 1)) or { return none }
	if me.status != 0 {
		return none
	}
	return me
}

// end_session deletes the session row for a token.
pub fn end_session(mut d database.DB, token string) {
	if token == '' {
		return
	}
	d.exec_none('DELETE FROM sessions WHERE token=?', [token]) or {}
}

// ---------------------------------------------------------------------------
// Account settings (json text column)
// ---------------------------------------------------------------------------

pub struct AccountSettings {
pub mut:
	restrict_room_creation_to_administrators bool
}

// account_settings decodes the account settings JSON text.
pub fn account_settings(row ?AccountRow) AccountSettings {
	settings := row or { return AccountSettings{} }

	if settings.settings == '' {
		return AccountSettings{}
	}
	return AccountSettings{
		restrict_room_creation_to_administrators: settings.settings.contains('"restrict_room_creation_to_administrators":true')
	}
}

// account_row loads the singleton account row.
pub fn account_row(mut d database.DB) ?AccountRow {
	row := d.query_one("SELECT id,name,join_code,coalesce(custom_styles,''),coalesce(settings,'') FROM accounts ORDER BY id LIMIT 1", []) or {
		return none
	}
	return AccountRow{
		id:            row_i64(row, 0)
		name:          row_str(row, 1)
		join_code:     row_str(row, 2)
		custom_styles: row_str(row, 3)
		settings:      row_str(row, 4)
	}
}

// now_epoch returns the current epoch seconds.
pub fn now_epoch() i64 {
	return time.now().unix()
}
