// Tests for workload/workload.v, mirroring
// ../once-campfire-python/tests/test_workload.py: porter, seed, pages,
// search, post.
module main

import time
import workload as w

// --- porter -----------------------------------------------------------------
fn test_porter() {
	assert w.porter_stem('caresses') == 'caress'
	assert w.porter_stem('ponies') == 'poni'
	assert w.porter_stem('caress') == 'caress'
	assert w.porter_stem('cats') == 'cat'
	assert w.porter_stem('running') == 'run'
	assert w.porter_stem('happy') == 'happi'
	assert w.porter_stem('relational') == 'relat'
	assert w.porter_stem('coffee') == 'coffe'
	assert w.porter_stem('searches') == 'search'
	assert w.porter_stem('rooms') == 'room'
	assert w.porter_stem('at') == 'at'
	assert w.tokenize('Hi @Bob, coffee x2!') == ['hi', 'bob', 'coffee', 'x2']
}

// --- seed --------------------------------------------------------------------
fn test_seed() {
	mut s := w.seed_store(8, 200, 7)
	assert s.users.len == 8
	assert s.messages.len == 200
	assert s.rooms.len == 2
	for i := 0; i < s.messages.len - 1; i++ {
		assert s.messages[i].created_at <= s.messages[i + 1].created_at
	}
	uid := s.users[0].id
	gid := s.rooms[0].id
	idx := w.build_search_index(s)
	assert idx.postings.len > 20
	assert idx.doc_count == 200

	// --- pages ---------------------------------------------------------------
	rp := w.room_page(s, gid, uid)
	assert rp.ok
	assert rp.value.messages.len == 40
	assert rp.value.has_more
	for m in rp.value.messages {
		assert m.creator_name != ''
	}
	mid := s.messages[100].id
	mp := w.messages_page(s, gid, uid, mid, 0)
	assert mp.ok && mp.value.len > 0 && mp.value[mp.value.len - 1].id < mid
	mp2 := w.messages_page(s, gid, uid, 0, mid)
	assert mp2.ok && mp2.value.len > 0 && mp2.value[0].id > mid
	assert !w.room_page(s, gid, 999999).ok
	sb := w.sidebar(s, uid)
	assert sb.ok && sb.value.len == 2
	assert sb.value[0].room_name <= sb.value[1].room_name

	// --- search --------------------------------------------------------------
	sp := w.search_page(s, idx, uid, 'coffee', 20)
	assert sp.ok && sp.value.len > 0
	for h in sp.value {
		assert h.room_name != ''
	}
	sp2 := w.search_page(s, idx, uid, 'zzzzqqqq', 20)
	assert sp2.ok && sp2.value.len == 0
	sp3 := w.search_page(s, idx, uid, '', 20)
	assert sp3.ok && sp3.value.len == 0

	// --- post ----------------------------------------------------------------
	posted := w.post_message_view(mut s, gid, uid, 'hello coffee world', 't1', time.now().unix())
	assert posted.ok && posted.value.client_message_id == 't1'
	v := w.build_message_view(s, posted.value)
	assert v.creator_name == 'user0' && v.content_type == 'text'
	assert s.memberships[1].unread_at != 0
}

// --- corpus parity ----------------------------------------------------------
// The seeder is the cross-language contract: the same seed must produce the
// same corpus in python, V and the other ports.
fn test_seed_is_deterministic() {
	a := w.seed_store(4, 50, 42)
	b := w.seed_store(4, 50, 42)
	assert a.messages.len == b.messages.len
	for i, m in a.messages {
		assert m.body == b.messages[i].body
		assert m.created_at == b.messages[i].created_at
		assert m.creator_id == b.messages[i].creator_id
	}
	other := w.seed_store(4, 50, 7)
	assert a.messages[0].body != other.messages[0].body
}
