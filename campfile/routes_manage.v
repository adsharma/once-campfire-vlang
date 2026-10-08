// routes_manage.v is the V transpile of routes/manage.py: room and
// message management (CRUD, refresh, involvement, boosts, autocomplete).
module campfile

import json
import workload as w
import campfire as c
import database

fn kinds() map[string]i64 {
	return {'opens': c.room_open, 'closeds': c.room_closed, 'directs': c.room_direct}
}

struct RoomForm {
pub mut:
	name     string
	user_ids []i64
}

struct RoomPayload {
pub mut:
	name     string
	user_ids []i64
	room     RoomForm
}

fn room_payload(r &Req) (string, []i64) {
	mut name := ''
	mut ids := []i64{}
	if r.body != '' {
		outer := json.decode(RoomPayload, r.body) or { RoomPayload{} }
		if outer.room.name != '' || outer.room.user_ids.len > 0 {
			name = outer.room.name
			ids = outer.room.user_ids.clone()
		} else {
			name = outer.name
			ids = outer.user_ids.clone()
		}
	}
	return name.trim_space(), ids
}

// user_list mirrors manage.py's _user_list: active users, optionally scoped
// to a room and filtered by name, capped at 20, ordered by lower(name).
fn user_list(mut d database.DB, room_id i64, filt string) []UserEntry {
	mut conds := 'status=0'
	mut params := []string{}
	if room_id > 0 {
		mems := d.query_all('SELECT user_id FROM memberships WHERE room_id=?', [
			room_id.str(),
		]) or {
			return []UserEntry{}
		}
		mut ids := []i64{}
		for m in mems {
			ids << row_i64(m, 0)
		}
		if ids.len == 0 {
			return []UserEntry{}
		}
		conds += ' AND id IN (' + placeholders(ids.len) + ')'
		params << id_params(ids)
	}
	if filt != '' {
		conds += ' AND lower(name) LIKE ?'
		params << '%' + filt.to_lower() + '%'
	}
	rows := d.query_all('SELECT id,coalesce(name,\'\') FROM users WHERE ' + conds +
		' ORDER BY lower(name) LIMIT 20', params) or {
		return []UserEntry{}
	}
	mut out := []UserEntry{}
	for r in rows {
		out << UserEntry{id: row_i64(r, 0), name: row_str(r, 1)}
	}
	return out
}

pub struct UserEntry {
pub mut:
	id    i64
	name  string
	label string
}

pub fn room_new_form(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	kind := r.path_args['kind'] or { '' }
	if kind !in kinds() {
		return err_resp('not found', 404)
	}
	mut entries := user_list(mut d, 0, '')
	for i in 0 .. entries.len {
		entries[i].label = entries[i].name
	}
	_ = uid
	return present(new_room_form(kind, entries))
}

pub struct RoomFormView {
pub mut:
	kind    string
	members []UserEntry
}

fn new_room_form(kind string, members []UserEntry) RoomFormView {
	return RoomFormView{kind: kind, members: members}
}

pub fn room_create(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	kind := r.path_args['kind'] or { '' }
	if kind !in kinds() {
		return err_resp('not found', 404)
	}
	me := user(mut d, uid) or {
		return err_resp('not found', 404)
	}
	if kind != 'directs' {
		settings := account_settings(account_row(mut d, ))
		if settings.restrict_room_creation_to_administrators && me.role != c.role_admin {
			return err_resp('forbidden', 403)
		}
	}
	name, payload_ids := room_payload(r)
	mut ids := []i64{}
	for id in payload_ids {
		if id > 0 && id !in ids {
			ids << id
		}
	}
	if kind == 'directs' {
		if uid !in ids {
			ids << uid
		}
	} else if kind != 'opens' {
		if uid !in ids {
			ids << uid
		}
		if name == '' {
			return err_resp('name required', 422)
		}
	} else {
		actives := d.query_all('SELECT id FROM users WHERE status=0', []) or {
			return err_resp('unprocessable', 422)
		}
		ids = []i64{}
		for a in actives {
			ids << row_i64(a, 0)
		}
		if name == '' {
			return err_resp('name required', 422)
		}
	}
	room := create_room(mut d, kinds()[kind], name, uid, ids, now_epoch()) or {
		return err_resp('unprocessable', 422)
	}
	res := room_page(mut d, room.id, uid)
	if !res.ok {
		return err_resp('not found', 404)
	}
	return created(res.value)
}

pub fn room_edit_form(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	kind := r.path_args['kind'] or { '' }
	rid := int_path_arg(r, 'id')
	room := room_access(mut d, uid, rid) or {
		return err_resp('not found', 404)
	}
	if room.typ != wanted_type(kind) {
		return err_resp('not found', 404)
	}
	return present(RoomEditView{id: rid, name: room.name, kind: kind})
}

pub struct RoomEditView {
pub mut:
	id   i64
	name string
	kind string
}

fn wanted_type(kind string) string {
	return 'Rooms::' + kind[..kind.len - 1].capitalize()
}

pub fn room_update(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	kind := r.path_args['kind'] or { '' }
	rid := int_path_arg(r, 'id')
	room := room_access(mut d, uid, rid) or {
		return err_resp('not found', 404)
	}
	if room.typ != wanted_type(kind) {
		return err_resp('not found', 404)
	}
	me := user(mut d, uid) or {
		return err_resp('forbidden', 403)
	}
	if !c.can_administer(me.role, uid, room.creator_id, false) {
		return err_resp('forbidden', 403)
	}
	name, payload_ids := room_payload(r)
	mut ids := []i64{}
	for id in payload_ids {
		if id > 0 && id !in ids {
			ids << id
		}
	}
	revise_room(mut d, room, if name != '' { name } else { room.name }, ids,
		room.typ == 'Rooms::Open', now_epoch()) or {
		return err_resp('unprocessable', 422)
	}
	res := room_page(mut d, rid, uid)
	if !res.ok {
		return err_resp('not found', 404)
	}
	return present(res.value)
}

pub fn room_delete_kind(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	kind := r.path_args['kind'] or { '' }
	if kind !in kinds() {
		return err_resp('not found', 404)
	}
	return destroy_room(mut d, uid, int_path_arg(r, 'id'))
}

pub fn room_delete(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	return destroy_room(mut d, uid, int_path_arg(r, 'id'))
}

fn destroy_room(mut d database.DB, uid i64, rid i64) Resp {
	room := room_access(mut d, uid, rid) or {
		return err_resp('not found', 404)
	}
	me := user(mut d, uid) or {
		return err_resp('forbidden', 403)
	}
	if room.typ != 'Rooms::Direct' && !c.can_administer(me.role, uid, room.creator_id, false) {
		return err_resp('forbidden', 403)
	}
	delete_room_cascade(mut d, rid) or {
		return err_resp('unprocessable', 422)
	}
	return present(DeletedItem{deleted: rid})
}

pub struct DeletedItem {
pub mut:
	deleted i64
}

pub fn refresh(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	rid := int_path_arg(r, 'id')
	since_ms := r.query['since'] or { '0' }
	mut since := i64(0)
	if is_digits(since_ms) {
		since = since_ms.i64() / 1000
	} else {
		since = now_epoch()
	}
	stamp := to_db_time(since)
	room := room_access(mut d, uid, rid) or {
		return err_resp('not found', 404)
	}
	_ = room
	new_rows := message_rows(mut d, 'SELECT ' + msg_cols + ' FROM messages WHERE room_id=? AND created_at > ? ORDER BY created_at LIMIT ' +
		page_size.str(), [rid.str(), stamp])
	mut new_ids := map[i64]bool{}
	for m in new_rows {
		new_ids[m.id] = true
	}
	upd_rows := message_rows(mut d, 'SELECT ' + msg_cols + ' FROM messages WHERE room_id=? AND updated_at > ? ORDER BY created_at DESC LIMIT ' +
		page_size.str(), [rid.str(), stamp])
	mut updated := []MsgRow{}
	for m in upd_rows {
		if m.id !in new_ids {
			updated << m
		}
	}
	updated = reversed(updated)
	return present(RefreshView{
		new:     views_for(mut d, new_rows)
		updated: views_for(mut d, updated)
	})
}

pub struct RefreshView {
pub mut:
	new     []w.MessageView
	updated []w.MessageView
}

pub fn involvement(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	rid := int_path_arg(r, 'id')
	room := room_access(mut d, uid, rid) or {
		return err_resp('not found', 404)
	}
	mem := membership(mut d, rid, uid) or {
		return err_resp('not found', 404)
	}
	if r.method == 'PUT' || r.method == 'PATCH' {
		mut choice := ''
		if r.body != '' {
			payload := json.decode(InvolvementPayload, r.body) or {
				InvolvementPayload{}
			}
			choice = payload.involvement
		}
		if choice == '' {
			choice = r.query['involvement'] or { '' }
		}
		allowed := if room.typ == 'Rooms::Direct' {
			['everything', 'nothing']
		} else {
			['mentions', 'everything', 'nothing', 'invisible']
		}
		if choice !in allowed {
			return err_resp('invalid involvement', 422)
		}
		set_involvement(mut d, rid, uid, choice, now_epoch()) or {
			return err_resp('unprocessable', 422)
		}
		mem2 := membership(mut d, rid, uid) or {
			return err_resp('not found', 404)
		}
		return present(InvolvementView{room_id: rid, involvement: mem2.involvement})
	}
	return present(InvolvementView{room_id: rid, involvement: mem.involvement})
}

struct InvolvementPayload {
pub mut:
	involvement string
}

pub struct InvolvementView {
pub mut:
	room_id     i64
	involvement string
}

pub fn message_show(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	rid := int_path_arg(r, 'id')
	mid := int_path_arg(r, 'mid')
	if room_access(mut d, uid, rid) == none {
		return err_resp('not found', 404)
	}
	row := message_dict(mut d, mid) or {
		return err_resp('not found', 404)
	}
	if row.room_id != rid {
		return err_resp('not found', 404)
	}
	return present(views_for(mut d, [row])[0])
}

struct MessageBodyPayload {
pub mut:
	body    string
	message MessageBodyPayloadInner
}

struct MessageBodyPayloadInner {
pub mut:
	body string
}

pub fn message_update(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	rid := int_path_arg(r, 'id')
	mid := int_path_arg(r, 'mid')
	if room_access(mut d, uid, rid) == none {
		return err_resp('not found', 404)
	}
	row := message_dict(mut d, mid) or {
		return err_resp('not found', 404)
	}
	if row.room_id != rid {
		return err_resp('not found', 404)
	}
	me := user(mut d, uid) or {
		return err_resp('forbidden', 403)
	}
	if !c.can_administer(me.role, uid, row.creator_id, false) {
		return err_resp('forbidden', 403)
	}
	mut body := ''
	mut has_body := false
	if r.body != '' {
		payload := json.decode(MessageBodyPayload, r.body) or {
			MessageBodyPayload{}
		}
		if payload.body != '' || r.body.contains('"body"') {
			body = payload.body
			has_body = true
		}
		if payload.message.body != '' {
			body = payload.message.body
			has_body = true
		}
	}
	if !has_body {
		return err_resp('body required', 422)
	}
	update_message_body(mut d, mid, body, now_epoch())
	updated := message_dict(mut d, mid) or {
		return err_resp('not found', 404)
	}
	return present(views_for(mut d, [updated])[0])
}

pub fn message_delete(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	rid := int_path_arg(r, 'id')
	mid := int_path_arg(r, 'mid')
	if room_access(mut d, uid, rid) == none {
		return err_resp('not found', 404)
	}
	row := message_dict(mut d, mid) or {
		return err_resp('not found', 404)
	}
	if row.room_id != rid {
		return err_resp('not found', 404)
	}
	me := user(mut d, uid) or {
		return err_resp('forbidden', 403)
	}
	if !c.can_administer(me.role, uid, row.creator_id, false) {
		return err_resp('forbidden', 403)
	}
	delete_message_cascade(mut d, mid) or {
		return err_resp('not found', 404)
	}
	return blank(204)
}

pub struct BoostView {
pub mut:
	id         i64
	content    string
	booster_id i64
}

pub fn boost_list(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mid := int_path_arg(r, 'mid')
	row := message_dict(mut d, mid) or {
		return err_resp('not found', 404)
	}
	if room_access(mut d, uid, row.room_id) == none {
		return err_resp('not found', 404)
	}
	rows := d.query_all('SELECT id,content,booster_id FROM boosts WHERE message_id=? ORDER BY id', [
		mid.str(),
	]) or {
		return err_resp('not found', 404)
	}
	mut out := []BoostView{}
	for b in rows {
		out << BoostView{id: row_i64(b, 0), content: row_str(b, 1), booster_id: row_i64(b, 2)}
	}
	return present(out)
}

struct BoostPayload {
pub mut:
	content string
	boost   BoostPayloadInner
}

struct BoostPayloadInner {
pub mut:
	content string
}

pub fn boost_create(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mid := int_path_arg(r, 'mid')
	row := message_dict(mut d, mid) or {
		return err_resp('not found', 404)
	}
	if room_access(mut d, uid, row.room_id) == none {
		return err_resp('not found', 404)
	}
	mut content := ''
	if r.body != '' {
		payload := json.decode(BoostPayload, r.body) or { BoostPayload{} }
		content = payload.content
		if payload.boost.content != '' {
			content = payload.boost.content
		}
	}
	boost := create_boost(mut d, mid, uid, content, now_epoch()) or {
		return err_resp('invalid boost content', 422)
	}
	return created(BoostView{id: boost.id, content: boost.content, booster_id: uid})
}

pub fn boost_delete(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mid := int_path_arg(r, 'mid')
	bid := int_path_arg(r, 'bid')
	row := message_dict(mut d, mid) or {
		return err_resp('not found', 404)
	}
	if room_access(mut d, uid, row.room_id) == none {
		return err_resp('not found', 404)
	}
	if !delete_boost(mut d, bid, mid, uid) {
		return err_resp('not found', 404)
	}
	return blank(204)
}

pub fn autocomplete(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mut rid := i64(0)
	raw := r.query['room_id'] or { '' }
	if is_digits(raw) {
		rid = raw.i64()
		if room_access(mut d, uid, rid) == none {
			return err_resp('not found', 404)
		}
	}
	filt := r.query['filter'] or { r.query['query'] or { '' } }
	mut entries := user_list(mut d, rid, filt)
	for i in 0 .. entries.len {
		entries[i].label = entries[i].name
	}
	return present(entries)
}
