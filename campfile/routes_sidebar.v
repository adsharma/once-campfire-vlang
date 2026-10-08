// sidebar.v is the V transpile of routes/sidebar.py.
module campfile

import database


pub fn sidebar_handler(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	res := sidebar(mut db, uid)
	if !res.ok {
		return err_resp(res.error, 404)
	}
	return present(res.value)
}
