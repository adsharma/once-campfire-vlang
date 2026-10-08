// ops.v is the V transpile of
// ../once-campfire-python/src/campfile/ops.py: every create/update/delete
// plus the admin surface (users, bots, bans, account).
//
// Reads live in queries.v. The rules that decide *whether* an operation is
// allowed come from campfire/ (can_administer, BOOST_MAX_LEN, bot key
// handling, default_involvement) through the enum tables in db.v, so the
// domain rules stay in exactly one place.
module campfile

import crypto.bcrypt
import crypto.rand
import encoding.base64
import campfire as c
import database

pub struct RoomRow {
pub mut:
	id         i64
	name       string
	typ        string
	creator_id i64
}

pub struct MembershipRow {
pub mut:
	id          i64
	room_id     i64
	user_id     i64
	involvement string
	connections i64
}

pub struct BoostRow {
pub mut:
	id         i64
	message_id i64
	content    string
	created_at i64
}

pub struct PushRow {
pub mut:
	id         i64
	endpoint   string
	user_agent string
}

// ---------------------------------------------------------------------------
// Access helpers
// ---------------------------------------------------------------------------

// room_access returns (room row, membership row) scoped to a member.
pub fn room_access(mut d database.DB, user_id i64, room_id i64) ?RoomRow {
	rows := d.query_all("SELECT id,coalesce(name,''),type,creator_id FROM rooms WHERE id=? AND id IN (SELECT room_id FROM memberships WHERE room_id=? AND user_id=?)", [
		room_id.str(),
		room_id.str(),
		user_id.str(),
	]) or { return none }
	if rows.len == 0 {
		return none
	}
	r := rows[0]
	return RoomRow{
		id:         row_i64(r, 0)
		name:       row_str(r, 1)
		typ:        row_str(r, 2)
		creator_id: row_i64(r, 3)
	}
}

// membership loads one membership row.
pub fn membership(mut d database.DB, room_id i64, user_id i64) ?MembershipRow {
	rows := d.query_all("SELECT id,room_id,user_id,coalesce(involvement,'mentions'),connections FROM memberships WHERE room_id=? AND user_id=?", [
		room_id.str(),
		user_id.str(),
	]) or { return none }
	if rows.len == 0 {
		return none
	}
	r := rows[0]
	return MembershipRow{
		id:          row_i64(r, 0)
		room_id:     row_i64(r, 1)
		user_id:     row_i64(r, 2)
		involvement: row_str(r, 3)
		connections: row_i64(r, 4)
	}
}

// bot_auth resolves a `<id>-<token>` key to an active bot user.
pub fn bot_auth(mut d database.DB, key string) ?UserRow {
	if !key.contains('-') {
		return none
	}
	parsed := c.parse_bot_key(key.trim_space())
	if !parsed.ok {
		return none
	}
	row := user(mut d, parsed.value) or { return none }
	if row.role != c.role_bot || row.status != c.status_active {
		return none
	}
	if key.trim_space() != parsed.value.str() + '-' + row.password_digest {
		return none
	}
	return row
}

// bot_token_of reads the stored bot token (bot_auth compares against it).
pub fn bot_token_of(mut d database.DB, user_id i64) string {
	rows := d.query_all("SELECT coalesce(bot_token,'') FROM users WHERE id=?", [
		user_id.str(),
	]) or { return '' }
	if rows.len == 0 {
		return ''
	}
	return row_str(rows[0], 0)
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

// grant_open_rooms gives a new user membership in every open room.
pub fn grant_open_rooms(mut d database.DB, user_id i64) ! {
	d.exec_none("INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) SELECT id,?,'mentions',?,? FROM rooms WHERE type='Rooms::Open' AND id NOT IN (SELECT room_id FROM memberships WHERE user_id=?)", [
		user_id.str(),
		to_db_time(now_epoch()),
		to_db_time(now_epoch()),
		user_id.str(),
	]) or { return err }
}

// create_user inserts a user row, granting open rooms to non-bots.
pub fn create_user(mut d database.DB, name string, email string, password string, role i64,
	bot_token string, now i64) ?UserRow {
	stamp := to_db_time(now)
	mut digest := ''
	if password != '' {
		digest = bcrypt.generate_from_password(password.bytes(), bcrypt.default_cost) or {
			return none
		}
	}
	d.exec_none("INSERT INTO users(name,email_address,password_digest,role,status,bot_token,created_at,updated_at) VALUES(?,NULLIF(?,''),NULLIF(?,''),?,0,NULLIF(?,''),?,?)", [
		name,
		email,
		digest,
		role.str(),
		bot_token,
		stamp,
		stamp,
	]) or {
		// Unique email_address / bot_token violations land here.
		return none
	}
	id := d.query_int('SELECT last_insert_rowid()', []) or { return none }
	row := user(mut d, id) or { return none }
	if role != c.role_bot {
		grant_open_rooms(mut d, id) or { return none }
	}
	return row
}

pub struct ProfilePatch {
pub mut:
	name     string
	has_name bool
	bio      string
	has_bio  bool
	email    string
	has_mail bool
	password string
}

// update_profile patches name, bio, email and password digest.
pub fn update_profile(mut d database.DB, id i64, patch ProfilePatch, now i64) ! {
	mut sets := []string{}
	mut params := []string{}
	if patch.has_name {
		sets << 'name=?'
		params << patch.name
	}
	if patch.has_bio {
		sets << "bio=NULLIF(?,'')"
		params << patch.bio
	}
	if patch.has_mail {
		sets << "email_address=NULLIF(?,'')"
		params << patch.email
	}
	if patch.password != '' {
		sets << 'password_digest=?'
		params << bcrypt.generate_from_password(patch.password.bytes(), bcrypt.default_cost) or {
			''
		}
	}
	sets << 'updated_at=?'
	params << to_db_time(now)
	params << id.str()
	d.exec_none('UPDATE users SET ' + sets.join(',') + ' WHERE id=?', params) or { return err }
}

// set_role changes a user role.
pub fn set_role(mut d database.DB, id i64, role i64, now i64) ! {
	d.exec_none('UPDATE users SET role=?, updated_at=? WHERE id=?', [
		role.str(),
		to_db_time(now),
		id.str(),
	]) or { return err }
}

// deactivate_user strips non-direct memberships, drops push/search/session
// rows, marks the user deactivated and rewrites the email address.
pub fn deactivate_user(mut d database.DB, id i64, now i64) ! {
	stamp := to_db_time(now)
	rows := d.query_all('SELECT m.id,r.type FROM memberships m LEFT JOIN rooms r ON r.id=m.room_id WHERE m.user_id=?', [
		id.str(),
	]) or { return err }
	for r in rows {
		if row_str(r, 1) != 'Rooms::Direct' {
			d.exec_none('DELETE FROM memberships WHERE id=?', [
				row_i64(r, 0).str(),
			]) or { return err }
		}
	}
	for table in ['push_subscriptions', 'searches', 'sessions'] {
		d.exec_none('DELETE FROM ' + table + ' WHERE user_id=?', [
			id.str(),
		]) or { return err }
	}
	row := user(mut d, id) or { return err }
	mut email := row.email_address
	if email != '' {
		email = email.replace('@', '-deactivated-' + random_hex(8) + '@')
	}
	d.exec_none('UPDATE users SET status=?, email_address=?, updated_at=? WHERE id=?', [
		c.status_deactivated.str(),
		email,
		stamp,
		id.str(),
	]) or { return err }
	return
}

fn random_hex(n int) string {
	b := rand.bytes(n) or { return '' }
	hexdigits := '0123456789abcdef'
	mut out := []u8{cap: b.len * 2}
	for v in b {
		out << hexdigits[int(v >> 4)]
		out << hexdigits[int(v & 15)]
	}
	return out.bytestr()
}

// random_join_code generates a random account join code.
pub fn random_join_code() string {
	b := rand.bytes(18) or { panic(err) }
	return base64.url_encode(b)
}

// ---------------------------------------------------------------------------
// Rooms
// ---------------------------------------------------------------------------

// create_room inserts a room, reusing the direct room for a repeated member set.
pub fn create_room(mut d database.DB, kind i64, name string, creator_id i64, member_ids []i64,
	now i64) ?RoomRow {
	stamp := to_db_time(now)
	mut wanted := []i64{}
	for id in member_ids {
		if id !in wanted {
			wanted << id
		}
	}
	if creator_id !in wanted {
		wanted << creator_id
	}
	if kind == c.room_direct {
		// Direct rooms are singletons per member set.
		cands := d.query_all('SELECT id FROM rooms WHERE type=?', ['Rooms::Direct']) or {
			return none
		}
		for cand in cands {
			have := d.query_all('SELECT user_id FROM memberships WHERE room_id=?', [
				row_i64(cand, 0).str(),
			]) or { continue }
			if have.len == wanted.len {
				mut same := true
				for r in have {
					if row_i64(r, 0) !in wanted {
						same = false
					}
				}
				if same {
					return room_access(mut d, creator_id, row_i64(cand, 0))
				}
			}
		}
	}
	d.exec_none("INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES(NULLIF(?,''),?,?,?,?)", [
		name,
		room_kind_to_type(kind),
		creator_id.str(),
		stamp,
		stamp,
	]) or { return none }
	id := d.query_int('SELECT last_insert_rowid()', []) or { return none }
	involve := if kind == c.room_direct { 'everything' } else { 'mentions' }
	for uid in wanted {
		d.exec_none('INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,?,?,?)', [
			id.str(),
			uid.str(),
			involve,
			stamp,
			stamp,
		]) or { return none }
	}
	return RoomRow{
		id:         id
		name:       name
		typ:        room_kind_to_type(kind)
		creator_id: creator_id
	}
}

// revise_room renames a room and reconciles its membership set.
pub fn revise_room(mut d database.DB, room RoomRow, name string, member_ids []i64,
	is_open_kind bool, now i64) ! {
	stamp := to_db_time(now)
	if room.typ != 'Rooms::Direct' {
		d.exec_none("UPDATE rooms SET name=NULLIF(?,''), updated_at=? WHERE id=?", [
			name,
			stamp,
			room.id.str(),
		]) or { return err }
	} else {
		d.exec_none('UPDATE rooms SET updated_at=? WHERE id=?', [
			stamp,
			room.id.str(),
		]) or { return err }
	}
	mut wanted := []i64{}
	if is_open_kind {
		rows := d.query_all('SELECT id FROM users WHERE status=0', []) or { return err }
		for r in rows {
			wanted << row_i64(r, 0)
		}
	} else {
		for id in member_ids {
			if id !in wanted {
				wanted << id
			}
		}
	}
	mem := d.query_all('SELECT id,user_id FROM memberships WHERE room_id=?', [
		room.id.str(),
	]) or { return err }
	for r in mem {
		if row_i64(r, 1) !in wanted {
			d.exec_none('DELETE FROM memberships WHERE id=?', [
				row_i64(r, 0).str(),
			]) or { return err }
		}
	}
	have := d.query_all('SELECT user_id FROM memberships WHERE room_id=?', [
		room.id.str(),
	]) or { return err }
	involve := if room.typ == 'Rooms::Direct' { 'everything' } else { 'mentions' }
	for uid in wanted {
		mut found := false
		for r in have {
			if row_i64(r, 0) == uid {
				found = true
			}
		}
		if !found {
			d.exec_none('INSERT INTO memberships(room_id,user_id,involvement,created_at,updated_at) VALUES(?,?,?,?,?)', [
				room.id.str(),
				uid.str(),
				involve,
				stamp,
				stamp,
			]) or { return err }
		}
	}
}

// delete_room_cascade deletes a room with its messages and memberships.
pub fn delete_room_cascade(mut d database.DB, room_id i64) ! {
	msgs := d.query_all('SELECT id FROM messages WHERE room_id=?', [
		room_id.str(),
	]) or { return err }
	for r in msgs {
		delete_message_cascade(mut d, row_i64(r, 0)) or { return err }
	}
	d.exec_none('DELETE FROM memberships WHERE room_id=?', [room_id.str()]) or { return err }
	d.exec_none('DELETE FROM rooms WHERE id=?', [room_id.str()]) or { return err }
}

// set_involvement changes a membership notification level.
pub fn set_involvement(mut d database.DB, room_id i64, user_id i64, choice string, now i64) ! {
	d.exec_none('UPDATE memberships SET involvement=?, updated_at=? WHERE room_id=? AND user_id=?', [
		choice,
		to_db_time(now),
		room_id.str(),
		user_id.str(),
	]) or { return err }
}

// touch_room bumps a room updated_at timestamp.
pub fn touch_room(mut d database.DB, room_id i64, now i64) {
	d.exec_none('UPDATE rooms SET updated_at=? WHERE id=?', [
		to_db_time(now),
		room_id.str(),
	]) or {}
}

// ---------------------------------------------------------------------------
// Messages and boosts
// ---------------------------------------------------------------------------

// update_message_body upserts a message rich-text body.
pub fn update_message_body(mut d database.DB, message_id i64, body string, now i64) bool {
	stamp := to_db_time(now)
	rows := d.query_all("SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'", [
		message_id.str(),
	]) or { return false }
	if rows.len == 0 {
		d.exec_none("INSERT INTO action_text_rich_texts(record_type,record_id,name,body,created_at,updated_at) VALUES('Message',?,'body',?,?,?)", [
			message_id.str(),
			body,
			stamp,
			stamp,
		]) or { return false }
	} else {
		d.exec_none('UPDATE action_text_rich_texts SET body=?, updated_at=? WHERE id=?', [
			body,
			stamp,
			row_i64(rows[0], 0).str(),
		]) or { return false }
	}
	d.exec_none('UPDATE messages SET updated_at=? WHERE id=?', [
		stamp,
		message_id.str(),
	]) or { return false }
	return true
}

// delete_message_cascade deletes a message with boosts, bodies and mentions.
pub fn delete_message_cascade(mut d database.DB, message_id i64) ?i64 {
	d.exec_none('DELETE FROM boosts WHERE message_id=?', [message_id.str()]) or { return none }
	d.exec_none("DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", [
		message_id.str(),
	]) or { return none }
	d.exec_none('DELETE FROM message_mentions WHERE message_id=?', [
		message_id.str(),
	]) or {}
	row := message_dict(mut d, message_id) or { return none }
	d.exec_none('DELETE FROM messages WHERE id=?', [message_id.str()]) or { return none }
	return row.room_id
}

// create_boost validates and inserts a boost, touching the message.
pub fn create_boost(mut d database.DB, message_id i64, user_id i64, content string,
	now i64) ?BoostRow {
	trimmed := content.trim_space()
	if trimmed == '' || trimmed.len > int(c.boost_max_len) {
		return none
	}
	stamp := to_db_time(now)
	d.exec_none('INSERT INTO boosts(message_id,booster_id,content,created_at,updated_at) VALUES(?,?,?,?,?)', [
		message_id.str(),
		user_id.str(),
		trimmed,
		stamp,
		stamp,
	]) or { return none }
	id := d.query_int('SELECT last_insert_rowid()', []) or { return none }
	d.exec_none('UPDATE messages SET updated_at=? WHERE id=?', [
		stamp,
		message_id.str(),
	]) or {}
	return BoostRow{
		id:         id
		message_id: message_id
		content:    trimmed
		created_at: now
	}
}

// delete_boost deletes one own boost.
pub fn delete_boost(mut d database.DB, boost_id i64, message_id i64, user_id i64) bool {
	n := d.query_int('SELECT count(*) FROM boosts WHERE id=? AND message_id=? AND booster_id=?', [
		boost_id.str(),
		message_id.str(),
		user_id.str(),
	]) or { return false }
	if n == 0 {
		return false
	}
	d.exec_none('DELETE FROM boosts WHERE id=?', [boost_id.str()]) or { return false }
	return true
}

// ---------------------------------------------------------------------------
// Search history
// ---------------------------------------------------------------------------

// record_search upserts a search query and trims history to ten.
pub fn record_search(mut d database.DB, user_id i64, query string, now i64) ! {
	stamp := to_db_time(now)
	d.exec_none('INSERT INTO searches(user_id,query,created_at,updated_at) VALUES(?,?,?,?) ON CONFLICT DO NOTHING', [
		user_id.str(),
		query,
		stamp,
		stamp,
	]) or { return err }
	d.exec_none('UPDATE searches SET updated_at=? WHERE user_id=? AND query=?', [
		stamp,
		user_id.str(),
		query,
	]) or { return err }
	ids := d.query_all('SELECT id FROM searches WHERE user_id=? ORDER BY updated_at DESC', [
		user_id.str(),
	]) or { return err }
	for i in int(c.max_recent_searches) .. ids.len {
		d.exec_none('DELETE FROM searches WHERE id=?', [row_i64(ids[i], 0).str()]) or { return err }
	}
}

// clear_searches deletes all of a user search history.
pub fn clear_searches(mut d database.DB, user_id i64) {
	d.exec_none('DELETE FROM searches WHERE user_id=?', [user_id.str()]) or {}
}

// recent_searches lists the ten most recent search queries.
pub fn recent_searches(mut d database.DB, user_id i64) []string {
	rows := d.query_all('SELECT query FROM searches WHERE user_id=? ORDER BY updated_at DESC LIMIT 10', [
		user_id.str(),
	]) or { return []string{} }
	mut out := []string{cap: rows.len}
	for r in rows {
		out << row_str(r, 0)
	}
	return out
}

// ---------------------------------------------------------------------------
// Push subscriptions
// ---------------------------------------------------------------------------

// pushsub_upsert inserts or updates a push subscription by endpoint.
pub fn pushsub_upsert(mut d database.DB, user_id i64, endpoint string, p256dh string,
	auth string, agent string, now i64) ?PushRow {
	if endpoint.trim_space() == '' {
		return none
	}
	stamp := to_db_time(now)
	rows := d.query_all('SELECT id FROM push_subscriptions WHERE user_id=? AND endpoint=?', [
		user_id.str(),
		endpoint,
	]) or { return none }
	if rows.len == 0 {
		d.exec_none("INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,user_agent,created_at,updated_at) VALUES(?,?,NULLIF(?,''),NULLIF(?,''),NULLIF(?,''),?,?)", [
			user_id.str(),
			endpoint,
			p256dh,
			auth,
			agent,
			stamp,
			stamp,
		]) or { return none }
		id := d.query_int('SELECT last_insert_rowid()', []) or { return none }
		return PushRow{
			id:         id
			endpoint:   endpoint
			user_agent: agent
		}
	}
	d.exec_none("UPDATE push_subscriptions SET p256dh_key=NULLIF(?,''), auth_key=NULLIF(?,''), user_agent=NULLIF(?,''), updated_at=? WHERE id=?", [
		p256dh,
		auth,
		agent,
		stamp,
		row_i64(rows[0], 0).str(),
	]) or { return none }
	return PushRow{
		id:         row_i64(rows[0], 0)
		endpoint:   endpoint
		user_agent: agent
	}
}

// pushsub_list lists a user push subscriptions.
pub fn pushsub_list(mut d database.DB, user_id i64) []PushRow {
	rows := d.query_all("SELECT id,coalesce(endpoint,''),coalesce(user_agent,'') FROM push_subscriptions WHERE user_id=? ORDER BY id", [
		user_id.str(),
	]) or { return []PushRow{} }
	mut out := []PushRow{cap: rows.len}
	for r in rows {
		out << PushRow{
			id:         row_i64(r, 0)
			endpoint:   row_str(r, 1)
			user_agent: row_str(r, 2)
		}
	}
	return out
}

// pushsub_delete deletes one own push subscription.
pub fn pushsub_delete(mut d database.DB, user_id i64, subscription_id i64) bool {
	n := d.query_int('SELECT count(*) FROM push_subscriptions WHERE id=? AND user_id=?', [
		subscription_id.str(),
		user_id.str(),
	]) or { return false }
	if n == 0 {
		return false
	}
	d.exec_none('DELETE FROM push_subscriptions WHERE id=?', [
		subscription_id.str(),
	]) or { return false }
	return true
}

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

// update_account patches the account name and room-creation restriction.
pub fn update_account(mut d database.DB, id i64, name string, has_name bool,
	restrict bool, has_settings bool, now i64) ! {
	mut sets := []string{}
	mut params := []string{}
	if has_name {
		sets << 'name=?'
		params << name
	}
	if has_settings {
		sets << 'settings=?'
		settings := '{"restrict_room_creation_to_administrators":' + (restrict.str()) + '}'
		params << settings
	}
	sets << 'updated_at=?'
	params << to_db_time(now)
	params << id.str()
	d.exec_none('UPDATE accounts SET ' + sets.join(',') + ' WHERE id=?', params) or { return err }
}

// update_styles replaces the account custom styles.
pub fn update_styles(mut d database.DB, id i64, styles string, now i64) ! {
	d.exec_none("UPDATE accounts SET custom_styles=NULLIF(?,''), updated_at=? WHERE id=?", [
		styles,
		to_db_time(now),
		id.str(),
	]) or { return err }
}

// reset_join_code generates a fresh account join code.
pub fn reset_join_code(mut d database.DB, id i64, now i64) string {
	code := random_join_code()
	d.exec_none('UPDATE accounts SET join_code=?, updated_at=? WHERE id=?', [
		code,
		to_db_time(now),
		id.str(),
	]) or {}
	return code
}

// ---------------------------------------------------------------------------
// Bans
// ---------------------------------------------------------------------------

// ban_user bans session IPs, clears sessions and messages, and marks the user banned.
pub fn ban_user(mut d database.DB, id i64, now i64) i64 {
	stamp := to_db_time(now)
	sess := d.query_all("SELECT id,coalesce(ip_address,'') FROM sessions WHERE user_id=?", [
		id.str(),
	]) or { return 0 }
	mut ips := []string{}
	for r in sess {
		ip := row_str(r, 1)
		if ip != '' && ip !in ips {
			ips << ip
		}
	}
	for r in sess {
		d.exec_none('DELETE FROM sessions WHERE id=?', [row_i64(r, 0).str()]) or {}
	}
	d.exec_none('DELETE FROM bans WHERE user_id=?', [id.str()]) or {}
	for ip in ips {
		d.exec_none('INSERT INTO bans(user_id,ip_address,created_at,updated_at) VALUES(?,?,?,?)', [
			id.str(),
			ip,
			stamp,
			stamp,
		]) or {}
	}
	d.exec_none('UPDATE users SET status=?, updated_at=? WHERE id=?', [
		c.status_banned.str(),
		stamp,
		id.str(),
	]) or {}
	return ips.len
}

// unban_user clears bans and reactivates a user.
pub fn unban_user(mut d database.DB, id i64, now i64) {
	d.exec_none('DELETE FROM bans WHERE user_id=?', [id.str()]) or {}
	d.exec_none('UPDATE users SET status=?, updated_at=? WHERE id=?', [
		c.status_active.str(),
		to_db_time(now),
		id.str(),
	]) or {}
}

// ---------------------------------------------------------------------------
// Bots and first run
// ---------------------------------------------------------------------------

// bot_upsert_webhook upserts or clears a bot webhook URL.
pub fn bot_upsert_webhook(mut d database.DB, bot_id i64, url string, now i64) {
	stamp := to_db_time(now)
	rows := d.query_all('SELECT id FROM webhooks WHERE user_id=?', [
		bot_id.str(),
	]) or { return }
	if url != '' {
		if rows.len == 0 {
			d.exec_none('INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES(?,?,?,?)', [
				bot_id.str(),
				url,
				stamp,
				stamp,
			]) or {}
			return
		}
		d.exec_none('UPDATE webhooks SET url=?, updated_at=? WHERE id=?', [
			url,
			stamp,
			row_i64(rows[0], 0).str(),
		]) or {}
		return
	}
	if rows.len != 0 {
		d.exec_none('DELETE FROM webhooks WHERE id=?', [row_i64(rows[0], 0).str()]) or {}
	}
}

// bot_webhook reads a bot webhook URL.
pub fn bot_webhook(mut d database.DB, bot_id i64) string {
	rows := d.query_all("SELECT coalesce(url,'') FROM webhooks WHERE user_id=? LIMIT 1", [
		bot_id.str(),
	]) or { return '' }
	if rows.len == 0 {
		return ''
	}
	return row_str(rows[0], 0)
}

// set_bot_token replaces a bot stored token.
pub fn set_bot_token(mut d database.DB, bot_id i64, token string, now i64) {
	d.exec_none('UPDATE users SET bot_token=?, updated_at=? WHERE id=?', [
		token,
		to_db_time(now),
		bot_id.str(),
	]) or {}
}

// FirstRun is what ops.first_run_create returns.
pub struct FirstRun {
pub mut:
	account AccountRow
	user    UserRow
	room    RoomRow
}

// first_run_create creates the account, admin user and lobby room.
pub fn first_run_create(mut d database.DB, name string, email string, password string,
	now i64) ?FirstRun {
	stamp := to_db_time(now)
	d.exec_none('INSERT INTO accounts(name,join_code,singleton_guard,created_at,updated_at) VALUES(?,?,1,?,?)', [
		name,
		random_join_code(),
		stamp,
		stamp,
	]) or { return none }
	account := account_row(mut d) or { return none }
	me := create_user(mut d, name, email, password, c.role_admin, '', now) or { return none }
	room := create_room(mut d, c.room_open, 'All Talk', me.id, [me.id], now) or { return none }
	return FirstRun{
		account: account
		user:    me
		room:    room
	}
}
