// rooms.v is the V transpile of routes/rooms.py: room pages, message
// windows, and posting.
module campfile

import json
import database

struct PostPayload {
pub mut:
	body              string
	client_message_id string
	creator_id        i64
}

pub fn room_page_handler(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	res := room_page(mut db, int_path_arg(r, 'id'), uid)
	if !res.ok {
		return err_resp(res.error, 404)
	}
	return present(res.value)
}

pub fn room_messages(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	res := messages_page(mut db, int_path_arg(r, 'id'), uid, int_arg(r, 'before', 0), int_arg(r,
		'after', 0))
	if !res.ok {
		return err_resp(res.error, 404)
	}
	return present(res.value)
}

pub fn post_message(mut db database.DB, r Req) Resp {
	mut payload := PostPayload{}
	if r.body != '' {
		payload = json.decode(PostPayload, r.body) or { PostPayload{} }
	}
	mut creator := actor_or_login(r)
	if creator == -1 {
		creator = payload.creator_id
	}
	if creator == 0 {
		return login_redirect()
	}
	room_id := int_path_arg(r, 'id')
	msg := post_message_view(mut db, room_id, creator, payload.body, payload.client_message_id,
		now_epoch()) or { return err_resp(err.msg(), 422) }
	row := message_dict(mut db, msg.id) or { return err_resp('not found', 404) }
	names := users_by_id(mut db, [row.creator_id])
	boosts := boosts_by_message(mut db, [row.id])
	mentions := mentions_by_message(mut db, [row.id])
	mut bodies := map[i64]string{}
	bodies[row.id] = payload.body
	return created(message_view(row, names, boosts, mentions, bodies))
}
