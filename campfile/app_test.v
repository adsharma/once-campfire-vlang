// Integration test for the campfile app layer: factory, seeding, session
// auth, and the hot-path routes, all through App.dispatch (no sockets).
module main

import campfile
import json
import os

fn db_path_for_test() string {
	return os.join_path(os.temp_dir(), 'campfile_app_test.db')
}

fn config_for_test() campfile.Config {
	return campfile.Config{
		users:         4
		messages:      12
		seed:          42
		db_url:        'sqlite:///' + db_path_for_test()
		secret_key:    'test-secret'
		seed_password: 'password'
	}
}

fn make_req(method string, path string) campfile.Req {
	return campfile.Req{
		method:  method
		path:    path
		query:   map[string]string{}
		form:    map[string]string{}
		cookies: map[string]string{}
		headers: map[string]string{}
	}
}

fn seed_app() campfile.App {
	os.rm(db_path_for_test()) or {}
	os.rm(db_path_for_test() + '-wal') or {}
	os.rm(db_path_for_test() + '-shm') or {}
	return campfile.create_app(config_for_test()) or { panic(err) }
}

struct MetaInfo {
pub mut:
	users        i64
	rooms        i64
	messages     i64
	fts_rows     i64
	watercooler  i64
	first_user   i64
	busy_message i64
}

fn test_meta_reports_seed() {
	mut app := seed_app()
	d := app.dispatch(make_req('GET', '/__meta'))
	assert d.status == 200
	meta := json.decode(MetaInfo, d.body) or { panic(err) }
	assert meta.users == 4
	assert meta.messages == 12
	assert meta.rooms == 2
	assert meta.fts_rows == 12
	assert meta.watercooler > 0
	assert meta.first_user > 0
	assert meta.busy_message > 0
}

fn login_cookie(mut app campfile.App, email string, password string) string {
	mut req := make_req('POST', '/session')
	req.body = '{"email_address":"' + email + '","password":"' + password + '"}'
	d := app.dispatch(req)
	assert d.status == 302
	set_cookie := d.headers['Set-Cookie'] or { panic('no cookie') }
	assert set_cookie.starts_with('session_token=')
	return set_cookie['session_token='.len..].split(';')[0]
}

fn authed(method string, path string, cookie string) campfile.Req {
	mut req := make_req(method, path)
	req.cookies['session_token'] = cookie
	return req
}

fn test_session_and_hot_paths() {
	mut app := seed_app()
	// Wrong password is rejected like the python 401.
	mut bad := make_req('POST', '/session')
	bad.body = '{"email_address":"user0@example.com","password":"nope"}'
	assert app.dispatch(bad).status == 401
	// Seeded users share the seed password.
	cookie := login_cookie(mut app, 'user0@example.com', 'password')
	// Sidebar lists the two seeded rooms for the admin.
	sb := app.dispatch(authed('GET', '/users/me/sidebar', cookie))
	assert sb.status == 200
	assert sb.body.contains('Watercooler')
	// Room page renders the last page of the seeded corpus.
	d := app.dispatch(make_req('GET', '/__meta'))
	meta := json.decode(MetaInfo, d.body) or { panic(err) }
	rp := app.dispatch(authed('GET', '/rooms/${meta.watercooler}', cookie))
	assert rp.status == 200
	assert rp.body.contains('"has_more":false')
	assert !rp.body.contains('"creator_name":""')
	// Posting a message works and shows up on the next page.
	mut post := authed('POST', '/rooms/${meta.watercooler}/messages', cookie)
	post.body = '{"body":"hello from v","client_message_id":"t1"}'
	posted := app.dispatch(post)
	assert posted.status == 201
	assert posted.body.contains('"client_message_id":"t1"')
	// Search finds the seeded coffee corpus through FTS5.
	mut sq := authed('GET', '/searches', cookie)
	sq.query['q'] = 'coffee'
	found := app.dispatch(sq)
	assert found.status == 200
	assert found.body.contains('"messages":[')
	// Logout clears the session.
	bye := app.dispatch(authed('DELETE', '/session', cookie))
	assert bye.status == 302
	assert app.dispatch(authed('GET', '/users/me/sidebar', cookie)).status == 302
}

fn test_first_run_and_join() {
	mut app := seed_app()
	// The seeded database already has an account: first_run redirects home.
	assert app.dispatch(make_req('GET', '/first_run')).status == 302
	// Unknown join codes 404; the seeded code is readable from /account.
	cookie := login_cookie(mut app, 'user0@example.com', 'password')
	acc := app.dispatch(authed('GET', '/account', cookie))
	assert acc.status == 200
	assert acc.body.contains('/join/')
	assert app.dispatch(make_req('GET', '/join/nope')).status == 404
}
