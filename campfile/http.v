// http.v is the V transpile of
// ../once-campfire-python/src/campfile/routes/helpers.py.
//
// Flask calls each view with injected globals (request, g, session); V has
// no framework, so a view takes the request explicitly (`Req`) and returns
// the response explicitly (`Resp`). app.v adapts net.http to these types,
// which keeps every route testable without a socket.
module campfile

import json
import campfire as c
import database
// Req is everything a view reads from the request: method, path, query and
// form arguments, the raw body, cookies, headers, the resolved actor, and
// any `:param` captures the router pulled out of the path.

pub struct Req {
pub mut:
	method      string
	path        string
	query       map[string]string
	form        map[string]string
	body        string
	cookies     map[string]string
	headers     map[string]string
	remote_addr string
	user_agent  string
	user_id     i64
	secret_key  string
	path_args   map[string]string
}

// Resp is everything a view returns: a status, a (usually JSON) body, and
// headers such as Location and Set-Cookie.
pub struct Resp {
pub mut:
	status  int
	body    string
	headers map[string]string
}

// present renders a value as a 200 JSON response.
pub fn present[T](obj T) Resp {
	return Resp{
		status: 200
		body:   json.encode(obj)
	}
}

// created renders a value as a 201 JSON response.
pub fn created[T](obj T) Resp {
	return Resp{
		status: 201
		body:   json.encode(obj)
	}
}

// blank renders an empty response with the given status.
pub fn blank(code int) Resp {
	return Resp{
		status: code
	}
}

// err_resp renders an error message as a JSON response with the given status.
pub fn err_resp(message string, code int) Resp {
	return Resp{
		status: code
		body:   json.encode(new_error(message))
	}
}

pub struct ErrorBody {
pub mut:
	error string
}

// new_error builds an error body.
pub fn new_error(message string) ErrorBody {
	return ErrorBody{
		error: message
	}
}

// login_redirect redirects anonymous requests to the login page.
pub fn login_redirect() Resp {
	return Resp{
		status:  302
		headers: {
			'Location': '/session/new'
		}
	}
}

// redirect_to redirects to the given path.
pub fn redirect_to(path string) Resp {
	return Resp{
		status:  302
		headers: {
			'Location': path
		}
	}
}

// actor_or_login mirrors the python backdoor: the session user when
// before_request resolved one, the `?as=` id for bench runs, else -1.
pub fn actor_or_login(r &Req) i64 {
	if r.user_id != 0 {
		return r.user_id
	}
	raw := r.query['as'] or { return -1 }
	if is_digits(raw) {
		return raw.i64()
	}
	return -1
}

// int_arg reads an integer query argument with a default.
pub fn int_arg(r &Req, name string, fallback i64) i64 {
	raw := r.query[name] or { return fallback }
	if !is_digits(raw) {
		return fallback
	}
	return raw.i64()
}

// form_or_json reads a scalar first from the request body (when it parses
// as JSON) and then from the form data, like the python views that accept
// both HTML pages and JSON API clients.
pub fn form_or_json(r &Req, key string, fallback string) string {
	if r.body != '' {
		obj := json.decode(map[string]string, r.body) or {
			map[string]string{}
		}
		if key in obj {
			return obj[key]
		}
	}
	return r.form[key] or { fallback }
}

// admin_uid returns the uid when it belongs to an administrator, else 0.
pub fn admin_uid(mut db database.DB, uid i64) i64 {
	row := user(mut db, uid) or { return 0 }
	if row.role != c.role_admin {
		return 0
	}
	return uid
}

// kind_to_room_type maps the `/rooms/<kind>` path segment to the Rails type,
// mirroring the KINDS lookup in routes/manage.py.
pub fn kind_to_room_type(kind string) string {
	return match kind {
		'closeds' { 'Rooms::Closed' }
		'directs' { 'Rooms::Direct' }
		'opens' { 'Rooms::Open' }
		else { '' }
	}
}

// int_path_arg reads an integer path capture, defaulting to zero.
pub fn int_path_arg(r &Req, name string) i64 {
	raw := r.path_args[name] or { return 0 }
	if !is_digits(raw) {
		return 0
	}
	return raw.i64()
}
