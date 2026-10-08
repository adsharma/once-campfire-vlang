// app.v is the V transpile of
// ../once-campfire-python/src/campfile/__init__.py: the application
// factory, the seeding step, the per-request session loading, and the
// route table. V has no Flask and no blueprints, so the table is a plain
// list of (method, pattern, handler) wired to a net.http Handler.
module campfile

import database
import encoding.base64
import encoding.hex
import crypto.hmac
import crypto.sha256
import net.http
import crypto.bcrypt
import workload as w

pub const cookie_name = 'session_token'

// ---------------------------------------------------------------------------
// Application factory
// ---------------------------------------------------------------------------

pub struct App {
pub mut:
	cfg Config
	db  &database.DB
}

// create_app mirrors the python create_app: open the database, apply the
// extension schema, seed an empty store, and stash the engine.
pub fn create_app(cfg Config) !App {
	mut db := database.open(cfg.db_path(), 4)!
	create_extensions(mut db, ) or { return err }
	mut app := App{
		cfg: cfg
		db:  db
	}
	app.seed_if_empty() or { return err }
	return app
}

// ---------------------------------------------------------------------------
// Seeding
// ---------------------------------------------------------------------------

pub fn (mut app App) seed_if_empty() ! {
	n := app.db.query_int('SELECT count(*) FROM messages', [])!
	if n > 0 {
		return
	}
	store := w.seed_store(app.cfg.users, app.cfg.messages, app.cfg.seed)
	digest := bcrypt.generate_from_password(app.cfg.seed_password.bytes(),
		bcrypt.default_cost) or { '' }
	counts := load_store(mut app.db, store, digest)!
	println('seeded users=${app.cfg.users} messages=${counts.messages} fts=${counts.fts}')
}

// ---------------------------------------------------------------------------
// Session cookies (signed tokens, same role as python's itsdangerous cookie)
//
// The python cookie uses itsdangerous, the rails app uses signed ids; each
// port signs differently, so cookies are only ever readable by the server
// sign_token signs a session token for the session_token cookie. Cookies
// are only readable by the server that wrote them; what travels between
// ports is the sessions table row the cookie points at.
pub fn (app &App) sign_token(token string) string {
	mac := hmac.new(app.cfg.secret_key.bytes(), token.bytes(), sha256.sum,
		sha256.block_size)
	return base64.url_encode((token + '.' + hex.encode(mac)).bytes())
}

pub fn (app &App) unsign_token(signed string) string {
	return unsign_token(app.cfg.secret_key, signed)
}

// ---------------------------------------------------------------------------
// Route table (one entry per Flask route in routes/*.py)
// ---------------------------------------------------------------------------

type HandlerFn = fn (mut database.DB, Req) Resp

struct Route {
	method  string
	pattern string
	handler HandlerFn @[required]
}

fn route_table() []Route {
	return [
		Route{'GET', '/__meta', meta},
		Route{'GET', '/', welcome},
		Route{'GET', '/first_run', first_run},
		Route{'POST', '/first_run', first_run},
		Route{'GET', '/join/:code', join},
		Route{'POST', '/join/:code', join},
		Route{'GET', '/session/new', session_new},
		Route{'POST', '/session', session_post},
		Route{'DELETE', '/session', session_delete},
		Route{'GET', '/users/me/sidebar', sidebar_handler},
		Route{'GET', '/searches', searches},
		Route{'POST', '/searches', searches_record},
		Route{'DELETE', '/searches', searches_clear},
		Route{'POST', '/searches/clear', searches_clear},
		Route{'GET', '/rooms/:id', room_page_handler},
		Route{'GET', '/rooms/:id/messages', room_messages},
		Route{'POST', '/rooms/:id/messages', post_message},
		Route{'GET', '/rooms/:kind/new', room_new_form},
		Route{'POST', '/rooms/:kind', room_create},
		Route{'GET', '/rooms/:kind/:id/edit', room_edit_form},
		Route{'PATCH', '/rooms/:kind/:id', room_update},
		Route{'PUT', '/rooms/:kind/:id', room_update},
		Route{'DELETE', '/rooms/:kind/:id', room_delete_kind},
		Route{'DELETE', '/rooms/:id', room_delete},
		Route{'GET', '/rooms/:id/refresh', refresh},
		Route{'GET', '/rooms/:id/involvement', involvement},
		Route{'PUT', '/rooms/:id/involvement', involvement},
		Route{'PATCH', '/rooms/:id/involvement', involvement},
		Route{'GET', '/rooms/:id/settings', involvement},
		Route{'PUT', '/rooms/:id/settings', involvement},
		Route{'PATCH', '/rooms/:id/settings', involvement},
		Route{'GET', '/rooms/:id/messages/:mid', message_show},
		Route{'PATCH', '/rooms/:id/messages/:mid', message_update},
		Route{'PUT', '/rooms/:id/messages/:mid', message_update},
		Route{'DELETE', '/rooms/:id/messages/:mid', message_delete},
		Route{'GET', '/messages/:mid/boosts', boost_list},
		Route{'POST', '/messages/:mid/boosts', boost_create},
		Route{'DELETE', '/messages/:mid/boosts/:bid', boost_delete},
		Route{'GET', '/autocompletable/users', autocomplete},
		Route{'GET', '/users/me/profile', profile},
		Route{'PATCH', '/users/me/profile', profile},
		Route{'PUT', '/users/me/profile', profile},
		Route{'GET', '/users/:id', user_show},
		Route{'GET', '/users/me/push_subscriptions', push_list},
		Route{'POST', '/users/me/push_subscriptions', push_create},
		Route{'DELETE', '/users/me/push_subscriptions/:id', push_delete},
		Route{'POST', '/users/me/push_subscriptions/:id/test_notifications', push_test},
		Route{'GET', '/account', account_show},
		Route{'PATCH', '/account', account_update},
		Route{'PUT', '/account', account_update},
		Route{'PUT', '/account/users/:id', account_user},
		Route{'PATCH', '/account/users/:id', account_user},
		Route{'DELETE', '/account/users/:id', account_user},
		Route{'GET', '/account/bots', bots_list},
		Route{'GET', '/account/bots/new', bot_new_form},
		Route{'GET', '/account/bots/:id/edit', bot_edit_form},
		Route{'POST', '/account/bots', bot_create},
		Route{'PATCH', '/account/bots/:id', bot_edit},
		Route{'PUT', '/account/bots/:id', bot_edit},
		Route{'DELETE', '/account/bots/:id', bot_edit},
		Route{'PUT', '/account/bots/:id/key', bot_key_reset},
		Route{'GET', '/account/custom_styles', styles_show},
		Route{'PATCH', '/account/custom_styles', styles_update},
		Route{'PUT', '/account/custom_styles', styles_update},
		Route{'POST', '/account/join_code', join_code_reset},
		Route{'POST', '/users/:id/ban', ban},
		Route{'DELETE', '/users/:id/ban', ban},
		Route{'GET', '/rooms/:id/:bot_key/messages', bot_list},
		Route{'POST', '/rooms/:id/:bot_key/messages', bot_post},
		Route{'POST', '/rooms/:id/:bot_key/messages/:mid/boosts', bot_boost_create},
		Route{'DELETE', '/rooms/:id/:bot_key/messages/:mid/boosts/:bid', bot_boost_delete},
	]
}

// match_path splits a pattern and a path on '/' and binds the :params.
pub fn match_path(pattern string, path string) ?map[string]string {
	want := pattern.split('/')
	got := path.split('/')
	if want.len != got.len {
		return none
	}
	mut args := map[string]string{}
	for i, seg in want {
		if seg.starts_with(':') {
			args[seg[1..]] = got[i]
		} else if seg != got[i] {
			return none
		}
	}
	return args
}

// ---------------------------------------------------------------------------
// Request dispatch (before_request + routing)
// ---------------------------------------------------------------------------

// load_uid resolves the signed session cookie to a user id, exactly what
// python's session.load_user stores in flask.g before every request except
// the login, session-create and meta endpoints.
fn (mut app App) load_uid(path string, cookies map[string]string) i64 {
	if path in ['/session/new', '/session', '/__meta'] {
		return 0
	}
	raw := cookies[cookie_name] or { return 0 }
	token := app.unsign_token(raw)
	if token == '' {
		return 0
	}
	me := user_from_token(mut app.db, token, now_epoch()) or { return 0 }
	return me.id
}

pub struct Dispatch {
pub mut:
	status  int
	body    string
	headers map[string]string
}

// dispatch runs before_request (session loading) and then the route table.
// It never touches the network, so routes are tested through this function.
pub fn (mut app App) dispatch(r Req) Dispatch {
	mut req := r
	req.secret_key = app.cfg.secret_key
	req.user_id = app.load_uid(r.path, r.cookies)
	for rt in route_table() {
		if rt.method != req.method {
			continue
		}
		if args := match_path(rt.pattern, req.path) {
			req.path_args = args.clone()
			mut resp := rt.handler(mut app.db, req)
			app.after_request(mut req, mut resp.headers)
			return Dispatch{
				status:  resp.status
				body:    resp.body
				headers: resp.headers
			}
		}
	}
	return Dispatch{
		status: 404
		body:   '{"error":"not found"}'
	}
}

// after_request clears the framework session scratch. The python port
// resets `fquery.env`; the V port keeps no per-request globals at all, so
// this is the documented no-op that owns the same position.
fn (app &App) after_request(mut req Req, mut headers map[string]string) {
	_ = req
	_ = headers
}

// ---------------------------------------------------------------------------
// net.http glue
// ---------------------------------------------------------------------------

struct CampfileHandler {
mut:
	app &App
}

pub fn (mut h CampfileHandler) handle(req http.Request) http.Response {
	path := req.url.split('?')[0]
	mut query := map[string]string{}
	if req.url.contains('?') {
		for pair in req.url.split('?')[1].split('&') {
			kv := pair.split_n('=', 2)
			if kv.len == 2 {
				query[kv[0]] = kv[1]
			}
		}
	}
	mut cookies := map[string]string{}
	for hv in req.header.values(.cookie) {
		for part in hv.split(';') {
			kv := part.trim_space().split_n('=', 2)
			if kv.len == 2 {
				cookies[kv[0]] = kv[1]
			}
		}
	}
	mut form := map[string]string{}
	content_type := req.header.get(.content_type) or { '' }
	if content_type.starts_with('application/x-www-form-urlencoded') {
		for pair in req.data.split('&') {
			kv := pair.split_n('=', 2)
			if kv.len == 2 {
				form[kv[0]] = kv[1]
			}
		}
	}
	d := h.app.dispatch(Req{
		method:      req.method.str()
		path:        path
		query:       query
		form:        form
		body:        req.data
		cookies:     cookies
		remote_addr: req.header.get(.x_forwarded_for) or { '' }
		user_agent:  req.user_agent
	})
	mut header := http.new_header()
	header.add_custom_map(d.headers) or {}
	return http.Response{
		status_code: d.status
		body:        d.body
		header:      header
	}
}

