module database

import os

fn db_test_path() string {
	p := os.join_path(os.temp_dir(), 'campfire-v-db-test.sqlite3')
	os.rm(p) or {}
	os.rm(p + '-wal') or {}
	os.rm(p + '-shm') or {}
	return p
}

fn setup_test_db() !&DB {
	mut d := open(db_test_path(), 2)!
	u := d.setup('Admin', 'admin@example.com', 'digest', [])!
	assert u.id == 1
	assert u.role == 1
	return d
}

fn test_schema_and_message_transaction() ! {
	mut d := setup_test_db()!
	defer {
		d.close() or {}
	}
	rooms := d.rooms(1)!
	assert rooms.len == 1
	assert rooms[0].name == 'All Talk'
	m := d.create_message(1, rooms[0].id, '', 'hello world', 'hello world')!
	assert m.id == 1
	assert m.creator == 'Admin'
	got := d.reachable_message(1, m.id)!
	assert got.body == 'hello world'
	found := d.search(1, 'hello')!
	assert found.len == 1
	assert found[0].id == m.id
}

fn test_session_revocation() ! {
	mut d := setup_test_db()!
	defer {
		d.close() or {}
	}
	tok := d.start_session(1, 'agent', '127.0.0.1')!
	u := d.session_user(tok)!
	assert u.id == 1
	refreshed := d.refresh_session(tok, 'agent', '127.0.0.1')!
	assert refreshed == false
	assert d.banned_ip('127.0.0.1')! == false
	d.ban_user(1, true)!
	assert d.banned_ip('127.0.0.1')! == true
	if _ := d.session_user(tok) {
		assert false, 'expected revoked session'
	}
	d.ban_user(1, false)!
}

fn test_rooms_and_boosts() ! {
	mut d := setup_test_db()!
	defer {
		d.close() or {}
	}
	room := d.create_room(1, 'Rooms::Closed', 'Secret', [i64(1)])!
	assert room.name == 'Secret'
	m := d.create_message(1, room.id, '', 'boost me', 'boost me')!
	b := d.create_boost(1, m.id, '🔥')!
	assert b.id == 1
	assert d.boosts(m.id)!.len == 1
	d.delete_boost(1, m.id, b.id)!
	assert d.boosts(m.id)!.len == 0
	updated := d.update_message(1, m.id, 'edited', 'edited')!
	assert updated.body == 'edited'
	d.delete_message(1, m.id)!
	if _ := d.reachable_message(1, m.id) {
		assert false, 'expected deleted message'
	}
}

fn test_search_query() {
	assert search_query('hello, world!') == 'hello  world '
	assert search_query('café_123') == 'café_123'
}
