// routes_bots_api.v is the V transpile of routes/bots_api.py: the
// key-authenticated bot message and boost endpoints.
module campfile

import json
import time
import database

fn room_for_bot(mut d database.DB, bot UserRow, rid i64) ?RoomRow {
	room := room_access(mut d, bot.id, rid) or { return none }
	return room
}

struct BotListLinks {
pub mut:
	link_header string
}

// bot_list lists room messages for a bot key with pagination headers.
pub fn bot_list(mut d database.DB, r Req) Resp {
	bot := bot_auth(mut d, r.path_args['bot_key'] or { '' }) or {
		return err_resp('unauthorized', 401)
	}
	rid := int_path_arg(r, 'id')
	if room_for_bot(mut d, bot, rid) == none {
		return err_resp('not found', 404)
	}
	direction := if 'after' in r.query { 'after' } else { 'before' }
	pivot_arg := r.query['after'] or { r.query['before'] or { '' } }
	mut conds := 'm.room_id=' + rid.str()
	mut params := [rid.str()]
	if pivot_arg != '' && is_digits(pivot_arg) {
		pivot := message_dict(mut d, pivot_arg.i64()) or { return err_resp('not found', 404) }
		if pivot.room_id != rid {
			return err_resp('not found', 404)
		}
		if direction == 'after' {
			conds += ' AND m.created_at > ?'
		} else {
			conds += ' AND m.created_at < ?'
		}
		params << to_db_time(pivot.created_at)
	}
	order := if direction == 'after' {
		'm.created_at, m.id'
	} else {
		'm.created_at DESC, m.id DESC'
	}
	mut rows := message_rows(mut d, 'SELECT ' + msg_cols + ' FROM messages WHERE ' + conds +
		' ORDER BY ' + order + ' LIMIT ' + page_size.str(), params)
	if direction == 'before' {
		rows = reversed(rows)
	}
	if rows.len == 0 {
		return blank(204)
	}
	mut resp := present(views_for(mut d, rows))
	total := d.query_int('SELECT count(*) FROM messages WHERE room_id=?', [
		rid.str(),
	]) or { 0 }
	resp.headers['X-Total-Count'] = total.str()
	edge := rows[rows.len - 1]
	mut has_more := false
	if direction == 'after' {
		n := d.query_int('SELECT count(*) FROM messages WHERE room_id=? AND created_at > ?', [
			rid.str(),
			to_db_time(edge.created_at),
		]) or { 0 }
		has_more = n > 0
	} else {
		n := d.query_int('SELECT count(*) FROM messages WHERE room_id=? AND created_at < ?', [
			rid.str(),
			to_db_time(edge.created_at),
		]) or { 0 }
		has_more = n > 0
	}
	if has_more {
		bot_key := r.path_args['bot_key'] or { '' }
		resp.headers['Link'] = '</rooms/' + rid.str() + '/' + bot_key + '/messages?' + direction +
			'=' + edge.id.str() + '>; rel="next"'
	}
	return resp
}

struct BotPostPayload {
pub mut:
	body string
}

// bot_post posts a bot message, returning 201 with a Location.
pub fn bot_post(mut d database.DB, r Req) Resp {
	bot := bot_auth(mut d, r.path_args['bot_key'] or { '' }) or {
		return err_resp('unauthorized', 401)
	}
	rid := int_path_arg(r, 'id')
	if room_for_bot(mut d, bot, rid) == none {
		return err_resp('not found', 404)
	}
	mut body := r.body
	if r.body != '' {
		payload := json.decode(BotPostPayload, r.body) or { BotPostPayload{} }
		if r.body.trim_space().starts_with('{') {
			body = payload.body
		}
	}
	if body.trim_space() == '' {
		return err_resp('body required', 422)
	}
	now := now_epoch()
	msg := post_message_view(mut d, rid, bot.id, body, 'bot-' + bot.id.str() + '-' + now.str(), now) or {
		return err_resp('unprocessable', 422)
	}
	touch_room(mut d, rid, now)
	mut resp := created(BotPosted{})
	resp.headers['Location'] = '/rooms/' + rid.str() + '/messages/' + msg.id.str()
	return resp
}

pub struct BotPosted {
}

// bot_boost_create creates a bot boost with the bot-shaped JSON.
pub fn bot_boost_create(mut d database.DB, r Req) Resp {
	bot := bot_auth(mut d, r.path_args['bot_key'] or { '' }) or {
		return err_resp('unauthorized', 401)
	}
	rid := int_path_arg(r, 'id')
	mid := int_path_arg(r, 'mid')
	if room_for_bot(mut d, bot, rid) == none {
		return err_resp('not found', 404)
	}
	row := message_dict(mut d, mid) or { return err_resp('not found', 404) }
	if row.room_id != rid {
		return err_resp('not found', 404)
	}
	mut content := r.body
	if r.body != '' {
		payload := json.decode(BotPostPayload, r.body) or { BotPostPayload{} }
		if r.body.trim_space().starts_with('{') && r.body.contains('"content"') {
			inner := json.decode(BoostContentPayload, r.body) or { BoostContentPayload{} }
			content = inner.content
		} else if r.body.trim_space().starts_with('{') {
			content = payload.body
		}
	}
	boost := create_boost(mut d, mid, bot.id, content, now_epoch()) or {
		return err_resp('invalid boost content', 422)
	}
	iso := time.unix(boost.created_at).as_utc().format_ss_milli().replace(' ', 'T') + 'Z'
	return created(BotBoostView{
		id:         boost.id
		content:    boost.content
		created_at: iso
		booster:    BotBooster{
			id:   bot.id
			name: bot.name
			role: 'bot'
		}
		message:    BotBoostMessage{
			id:  mid
			url: '/rooms/' + rid.str() + '/messages/' + mid.str()
		}
	})
}

struct BoostContentPayload {
pub mut:
	content string
}

pub struct BotBoostView {
pub mut:
	id         i64
	content    string
	created_at string
	booster    BotBooster
	message    BotBoostMessage
}

pub struct BotBooster {
pub mut:
	id   i64
	name string
	role string
}

pub struct BotBoostMessage {
pub mut:
	id  i64
	url string
}

// bot_boost_delete deletes a bot boost.
pub fn bot_boost_delete(mut d database.DB, r Req) Resp {
	bot := bot_auth(mut d, r.path_args['bot_key'] or { '' }) or {
		return err_resp('unauthorized', 401)
	}
	rid := int_path_arg(r, 'id')
	mid := int_path_arg(r, 'mid')
	bid := int_path_arg(r, 'bid')
	if room_for_bot(mut d, bot, rid) == none {
		return err_resp('not found', 404)
	}
	if !delete_boost(mut d, bid, mid, bot.id) {
		return err_resp('not found', 404)
	}
	return blank(204)
}
