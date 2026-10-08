// onboard.v is the V transpile of routes/onboard.py: welcome, first run,
// and join by code. Signed transfer URLs need the Rails crypto helpers and
// are out of scope; password login covers the same flow.
module campfile

import json
import campfire as c
import database

struct UserForm {
pub mut:
	name          string
	email_address string
	password      string
}

struct OnboardPayload {
pub mut:
	name          string
	email_address string
	password      string
	user          UserForm
}

pub fn welcome(mut db database.DB, r Req) Resp {
	if account_row(mut db, ) == none {
		return redirect_to('/first_run')
	}
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	first := db.query_int('SELECT r.id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? ORDER BY r.created_at LIMIT 1', [
		uid.str(),
	]) or {
		0
	}
	if first != 0 {
		return redirect_to('/rooms/' + first.str())
	}
	return present(new_welcome())
}

pub struct WelcomeBody {
pub mut:
	welcome bool
}

pub fn new_welcome() WelcomeBody {
	return WelcomeBody{welcome: true}
}

pub fn first_run(mut db database.DB, r Req) Resp {
	if account_row(mut db, ) != none {
		return redirect_to('/')
	}
	if r.method == 'GET' {
		return present(new_first_run())
	}
	payload := onboard_payload(r)
	if payload.name == '' || payload.email_address == '' || payload.password == '' {
		return err_resp('name, email and password required', 422)
	}
	now := now_epoch()
	run := first_run_create(mut db, payload.name, payload.email_address, payload.password,
		now) or {
		return err_resp('unprocessable', 422)
	}
	token := issue_session(mut db, run.user.id, r.remote_addr, r.user_agent, now)
	mut resp := created(new_user_created(run.user.id, run.user.name))
	set_session_cookie(r.secret_key, mut resp, token)
	return resp
}

pub struct FirstRunBody {
pub mut:
	first_run bool
}

pub fn new_first_run() FirstRunBody {
	return FirstRunBody{first_run: true}
}

pub struct UserCreated {
pub mut:
	id   i64
	name string
}

pub fn new_user_created(id i64, name string) UserCreated {
	return UserCreated{id: id, name: name}
}

fn onboard_payload(r &Req) UserForm {
	mut payload := UserForm{}
	if r.body != '' {
		outer := json.decode(OnboardPayload, r.body) or { OnboardPayload{} }
		if outer.user.name != '' || outer.user.email_address != '' {
			payload = outer.user
		} else {
			payload = UserForm{
				name:          outer.name
				email_address: outer.email_address
				password:      outer.password
			}
		}
	}
	if payload.name == '' {
		payload.name = r.form['name'] or { '' }
	}
	if payload.email_address == '' {
		payload.email_address = r.form['email_address'] or { '' }
	}
	if payload.password == '' {
		payload.password = r.form['password'] or { '' }
	}
	return payload
}

struct JoinBody {
pub mut:
	join_code string
}

pub fn join(mut db database.DB, r Req) Resp {
	code := r.path_args['code'] or { '' }
	account := account_row(mut db, ) or {
		return err_resp('not found', 404)
	}
	if account.join_code != code {
		return err_resp('not found', 404)
	}
	if actor_or_login(r) != -1 {
		return redirect_to('/')
	}
	if r.method == 'GET' {
		return present(JoinBody{join_code: code})
	}
	payload := onboard_payload(r)
	if payload.name == '' || payload.email_address == '' || payload.password == '' {
		return err_resp('name, email and password required', 422)
	}
	now := now_epoch()
	new_user := create_user(mut db, payload.name, payload.email_address, payload.password,
		c.role_member, '', now) or {
		return err_resp('email already taken', 422)
	}
	token := issue_session(mut db, new_user.id, r.remote_addr, r.user_agent, now)
	mut resp := created(new_user_created(new_user.id, new_user.name))
	set_session_cookie(r.secret_key, mut resp, token)
	return resp
}
