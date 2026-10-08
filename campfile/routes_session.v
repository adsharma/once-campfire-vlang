// session.v is the V transpile of routes/session.py: password login, the
// signed session cookie, and logout.
//
// Cookie crypto is app-native, not Rails-compatible, exactly like the
// python port's Flask-signed cookie (python documents the same boundary).
// What travels between ports is the sessions *row*, not the cookie.
module campfile

import crypto.hmac
import crypto.sha256
import encoding.base64
import encoding.hex
import json
import database

fn sign_token(secret string, token string) string {
	mac := hmac.new(secret.bytes(), token.bytes(), sha256.sum, sha256.block_size)
	return base64.url_encode((token + '.' + hex.encode(mac)).bytes())
}

pub fn issue_session(mut db database.DB, user_id i64, remote_addr string,
	agent string, now i64) string {
	return start_session(mut db, user_id, remote_addr, agent, now) or { '' }
}

pub fn set_session_cookie(secret string, mut resp Resp, token string) {
	resp.headers['Set-Cookie'] = cookie_name + '=' + sign_token(secret, token) +
		'; Path=/; HttpOnly'
}

pub fn clear_session_cookie(mut resp Resp) {
	resp.headers['Set-Cookie'] = cookie_name +
		'=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT'
}

pub fn session_new(mut db database.DB, r Req) Resp {
	_ = db
	_ = r
	return Resp{
		status: 200
		body:   '<form method=post action=/session><input name=email_address type=email><input name=password type=password><button>Sign in</button></form>'
	}
}

struct SessionPayload {
pub mut:
	email_address string
	password      string
}

pub fn session_post(mut db database.DB, r Req) Resp {
	mut email := r.form['email_address'] or { '' }
	mut password := r.form['password'] or { '' }
	if r.body != '' {
		payload := json.decode(SessionPayload, r.body) or { SessionPayload{} }
		email = payload.email_address
		password = payload.password
	}
	me := authenticate(mut db, email, password) or {
		return err_resp('Too many requests or unauthorized.', 401)
	}
	token := start_session(mut db, me.id, r.remote_addr, r.user_agent, now_epoch()) or {
		return err_resp('Too many requests or unauthorized.', 401)
	}
	mut resp := redirect_to('/')
	set_session_cookie(r.secret_key, mut resp, token)
	return resp
}

pub fn session_delete(mut db database.DB, r Req) Resp {
	raw := r.cookies[cookie_name] or { '' }
	if raw != '' {
		token := unsign_token(r.secret_key, raw)
		if token != '' {
			end_session(mut db, token)
		}
	}
	mut resp := redirect_to('/session/new')
	resp.headers['Set-Cookie'] = cookie_name +
		'=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT'
	return resp
}

pub fn unsign_token(secret string, signed string) string {
	raw := base64.url_decode_str(signed)
	cut := raw.last_index('.') or { return '' }
	head := raw[..cut]
	tail := raw[cut + 1..]
	mac := hmac.new(secret.bytes(), head.bytes(), sha256.sum, sha256.block_size)
	if hex.encode(mac) != tail {
		return ''
	}
	return head
}
