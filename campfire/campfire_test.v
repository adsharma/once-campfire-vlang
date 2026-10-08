// Tests for campfire/campfire.v, mirroring
// ../once-campfire-python/tests/test_campfire.py assertion for assertion.
module main

import campfire as c

const now = i64(1700000000)

fn fresh_account(mut s c.Store) c.Account {
	r := s.create_account('Acme', 'AbcDef123456', now)
	assert r.ok
	return s.accounts[0]
}

// --- account / join codes ---------------------------------------------------
fn test_account_and_join_codes() {
	mut s := c.Store{}
	fresh_account(mut s)
	assert s.accounts[0].join_code == 'AbcD-ef12-3456'
	bad := s.create_account('Bad', 'short', now)
	assert !bad.ok
	assert bad.error != ''
	r := s.reset_account_join_code(s.accounts[0].id, 'ZZZZZZ999999', now)
	assert r.ok && r.value == 'ZZZZ-ZZ99-9999'
	assert c.deactivated_email('amy@example.com', 'STAMP') == 'amy-deactivated-STAMP@example.com'
	assert c.deactivated_email('', 'STAMP') == ''
	assert c.user_initials('Ada M Byron') == 'AMB'
	assert c.user_title('Ada', 'writes code') == 'Ada - writes code'
	assert c.user_title('Ada', '') == 'Ada'
}

// --- users ------------------------------------------------------------------
fn test_users() {
	mut s := c.Store{}
	fresh_account(mut s)
	admin := s.create_user('Admin', 'admin@x.com', c.role_admin, now, '')
	assert admin.ok
	assert !s.create_user('X', 'x@x.com', 7, now, '').ok
	assert !s.create_user('', 'y@x.com', c.role_member, now, '').ok
	assert !s.create_user('Dup', 'admin@x.com', c.role_member, now, '').ok
	bot := s.create_user('Helper', '', c.role_bot, now, 'BotToken1234')
	assert bot.ok && bot.value.bot_token == 'BotToken1234'
	assert !s.create_user('B2', '', c.role_bot, now, 'short').ok
	assert c.bot_key_of(bot.value.id, 'BotToken1234') == bot.value.id.str() + '-BotToken1234'
	assert c.parse_bot_key(bot.value.id.str() + '-BotToken1234').value == bot.value.id
	assert !c.parse_bot_key('nonsense').ok
	assert s.authenticate_bot(bot.value.id.str() + '-BotToken1234').ok
	assert !s.authenticate_bot(bot.value.id.str() + '-WrongToken12').ok
}

// --- rooms ------------------------------------------------------------------
fn test_rooms() {
	mut s := c.Store{}
	fresh_account(mut s)
	admin := s.create_user('Admin', 'admin@x.com', c.role_admin, now, '')
	member := s.create_user('Amy', 'amy@x.com', c.role_member, now, '')
	general := s.create_room(c.room_open, 'General', admin.value.id, [
		admin.value.id,
		member.value.id,
	], now)
	assert general.ok
	assert s.memberships.len == 2
	// late joiner auto-granted to open rooms
	late := s.create_user('Late', 'late@x.com', c.role_member, now, '')
	assert s.find_membership_index(general.value.id, late.value.id) >= 0
	closed := s.create_room(c.room_closed, 'Secret', admin.value.id, [
		admin.value.id,
	], now)
	assert closed.ok
	assert s.find_membership_index(closed.value.id, late.value.id) < 0
	assert !s.create_room(c.room_open, '', admin.value.id, [], now).ok
	dm := s.find_or_create_direct_room(admin.value.id, [
		admin.value.id,
		member.value.id,
	], now)
	assert dm.ok && dm.value.kind == c.room_direct
	dm2 := s.find_or_create_direct_room(admin.value.id, [
		member.value.id,
		admin.value.id,
	], now)
	assert dm2.ok && dm2.value.id == dm.value.id
	assert s.memberships[s.find_membership_index(dm.value.id, member.value.id)].involvement == c.involvement_everything
	assert s.memberships[s.find_membership_index(general.value.id, member.value.id)].involvement == c.involvement_mentions
	blocked := s.convert_room_kind(dm.value.id, c.room_open, now)
	assert !blocked.ok
	conv := s.convert_room_kind(closed.value.id, c.room_open, now)
	assert conv.ok
	assert s.find_membership_index(closed.value.id, late.value.id) >= 0
}

// --- administer -------------------------------------------------------------
fn test_administer() {
	assert c.can_administer(c.role_admin, 99, 100, false)
	assert c.can_administer(c.role_member, 5, 5, false)
	assert !c.can_administer(c.role_member, 5, 6, false)
	assert c.can_administer(c.role_member, 5, 6, true)
	assert !c.can_create_room(c.role_member, true)
	assert c.can_create_room(c.role_admin, true)
	assert c.can_create_room(c.role_member, false)
}

// --- messages + unread ------------------------------------------------------
fn test_messages_and_unread() {
	mut s2 := c.Store{}
	fresh_account(mut s2)
	a := s2.create_user('A', 'a@x.com', c.role_admin, now, '').value
	b := s2.create_user('B', 'b@x.com', c.role_member, now, '').value
	g := s2.create_room(c.room_open, 'General', a.id, [
		a.id,
		b.id,
	], now).value
	m1 := s2.post_message(g.id, a.id, 'hello @B', '', [b.id], 'c1', now)
	assert m1.ok && m1.value.client_message_id == 'c1'
	assert ('push:' + g.id.str() + ':' + m1.value.id.str()) in s2.outbox
	bi := s2.find_membership_index(g.id, b.id)
	ai := s2.find_membership_index(g.id, a.id)
	assert s2.memberships[bi].unread_at == now
	assert s2.memberships[ai].unread_at == 0
	// connected member stays read
	s2.present_membership(g.id, b.id, 1, now + 10)
	s2.post_message(g.id, a.id, 'again', '', [], 'c2', now + 20)
	assert s2.memberships[bi].unread_at == 0
	assert s2.read_membership(g.id, b.id, now + 30)
	// invisible member never unread
	s2.set_involvement(g.id, b.id, c.involvement_invisible, now + 30)
	s2.post_message(g.id, a.id, 'third', '', [], 'c3', now + 40)
	assert s2.memberships[bi].unread_at == 0
	assert !s2.post_message(g.id, 9999, 'x', '', [], 'c9', now).ok
	assert !s2.post_message(g.id, a.id, '', '', [], 'ce', now).ok
	att := s2.post_message(g.id, a.id, '', 'photo.png', [], 'c4', now + 50)
	assert att.ok
	assert c.message_plain_body(att.value.body, att.value.attachment_name) == 'photo.png'
	assert s2.message_mentionees(m1.value) == [b.id]
	assert c.strip_mention('hi @B there', 'B') == 'hi  there'
}

// --- pagination -------------------------------------------------------------
fn test_pagination() {
	mut s3 := c.Store{}
	fresh_account(mut s3)
	u := s3.create_user('U', 'u@x.com', c.role_member, now, '').value
	r3 := s3.create_room(c.room_open, 'Big', u.id, [
		u.id,
	], now).value
	mut t := now
	for i := 0; i < 45; i++ {
		t++
		rr := s3.post_message(r3.id, u.id, 'msg' + i.str(), '', [], 'cc' + i.str(), t)
		assert rr.ok
	}
	msgs := s3.room_messages(r3.id)
	assert msgs.len == 45
	assert c.is_paged(msgs)
	lp := c.last_page(msgs)
	assert lp.len == 40 && lp[0].body == 'msg5'
	fp := c.first_page(msgs)
	assert fp.len == 40 && fp[0].body == 'msg0'
	anchor := msgs[20]
	bef := c.page_before(msgs, anchor.created_at, anchor.id)
	assert bef.len == 20 && bef[bef.len - 1].body == 'msg19'
	aft := c.page_after(msgs, anchor.created_at, anchor.id)
	assert aft.len == 24 && aft[0].body == 'msg21'
	ar := c.page_around(msgs, anchor)
	assert ar.len == 45 && ar[20].body == 'msg20'
}

// --- sounds -----------------------------------------------------------------
fn test_sounds() {
	assert c.sound_command('/play tada') == 'tada'
	assert c.sound_command('/play tada now') == ''
	assert c.sound_command('/play ') == ''
	assert c.sound_command('hello') == ''
	sounds := c.builtin_sounds()
	assert sounds.len > 40
	assert c.find_sound(sounds, 'tada').ok
	assert !c.find_sound(sounds, 'nope').ok
	assert c.content_type_of(false, '') == c.content_text
	assert c.content_type_of(true, '') == c.content_attachment
	assert c.content_type_of(false, 'tada') == c.content_sound
}

// --- boosts -----------------------------------------------------------------
fn test_boosts() {
	mut s2 := c.Store{}
	fresh_account(mut s2)
	a := s2.create_user('A', 'a@x.com', c.role_admin, now, '').value
	b := s2.create_user('B', 'b@x.com', c.role_member, now, '').value
	g := s2.create_room(c.room_open, 'General', a.id, [
		a.id,
		b.id,
	], now).value
	m1 := s2.post_message(g.id, a.id, 'hello', '', [], 'c1', now)
	bo := s2.boost_message(m1.value.id, b.id, 'tada', now + 60)
	assert bo.ok
	assert !s2.boost_message(m1.value.id, b.id, '0123456789abcdefg', now).ok
	assert !s2.boost_message(424242, b.id, 'tada', now).ok
}

// --- bans -------------------------------------------------------------------
fn test_bans() {
	assert c.validate_ban_ip('8.8.8.8').ok
	assert c.validate_ban_ip('127.0.0.1').error == 'cannot be a private or internal IP address'
	assert !c.validate_ban_ip('10.1.2.3').ok
	assert !c.validate_ban_ip('172.20.5.4').ok
	assert c.validate_ban_ip('172.32.0.1').ok
	assert !c.validate_ban_ip('192.168.1.1').ok
	assert !c.validate_ban_ip('169.254.9.9').ok
	assert c.validate_ban_ip('nope').error == 'is not a valid IP address'
	assert !c.validate_ban_ip('1.2.3').ok
	assert !c.validate_ban_ip('1.2.3.999').ok
	assert !c.validate_ban_ip('::1').ok
	assert !c.validate_ban_ip('fe80::1').ok
	assert !c.validate_ban_ip('fd00::5').ok
	assert c.validate_ban_ip('2001:4860:4860::8888').ok

	mut s2 := c.Store{}
	fresh_account(mut s2)
	b := s2.create_user('B', 'b@x.com', c.role_member, now, '').value
	ban := s2.create_ban(b.id, '8.8.8.8', now + 70)
	assert ban.ok
	assert !s2.create_ban(b.id, '10.0.0.1', now).ok
	assert s2.is_banned_ip('8.8.8.8')
	assert !s2.is_banned_ip('9.9.9.9')
}

// --- sessions ---------------------------------------------------------------
fn test_sessions() {
	mut s2 := c.Store{}
	fresh_account(mut s2)
	b := s2.create_user('B', 'b@x.com', c.role_member, now, '').value
	sess := s2.start_session(b.id, 'tok-1', '8.8.8.8', 'agent', now + 80)
	assert sess.ok
	assert !s2.touch_session(sess.value.id, 'agent2', '9.9.9.9', now + 90)
	assert s2.touch_session(sess.value.id, 'agent2', '9.9.9.9', now + 80 + 3601)
	si := s2.find_session_index(sess.value.id)
	assert s2.sessions[si].ip_address == '9.9.9.9'
}

// --- searches ---------------------------------------------------------------
fn test_search_records() {
	mut s2 := c.Store{}
	fresh_account(mut s2)
	b := s2.create_user('B', 'b@x.com', c.role_member, now, '').value
	for i := 0; i < 12; i++ {
		s2.record_search(b.id, 'q' + i.str(), now + 100 + i64(i))
	}
	mut mine := 0
	for sr in s2.searches {
		if sr.user_id == b.id {
			mine++
		}
	}
	assert mine == 10
}

// --- connections ------------------------------------------------------------
fn test_connections() {
	mut s2 := c.Store{}
	fresh_account(mut s2)
	a := s2.create_user('A', 'a@x.com', c.role_admin, now, '').value
	b := s2.create_user('B', 'b@x.com', c.role_member, now, '').value
	g := s2.create_room(c.room_open, 'General', a.id, [
		a.id,
		b.id,
	], now).value
	s2.post_message(g.id, a.id, 'hello', '', [], 'c1', now)
	s2.present_membership(g.id, a.id, 2, now + 200)
	ai2 := s2.find_membership_index(g.id, a.id)
	assert s2.memberships[ai2].connections == 2
	assert s2.memberships[ai2].unread_at == 0
	s2.disconnect_membership(g.id, a.id, now + 201)
	assert s2.memberships[ai2].connections == 1
	s2.disconnect_membership(g.id, a.id, now + 202)
	s2.disconnect_membership(g.id, a.id, now + 203)
	assert s2.memberships[ai2].connections == 0 && s2.memberships[ai2].connected_at == 0
	s2.disconnect_all(now + 300)
	for m in s2.memberships {
		assert m.connected_at == 0
	}
	_ = b
}

// --- ban user / unban / deactivate ------------------------------------------
fn test_ban_unban_deactivate() {
	mut s2 := c.Store{}
	fresh_account(mut s2)
	a := s2.create_user('A', 'a@x.com', c.role_admin, now, '').value
	b := s2.create_user('B', 'b@x.com', c.role_member, now, '').value
	g := s2.create_room(c.room_open, 'General', a.id, [
		a.id,
		b.id,
	], now).value
	// A session with a public IP is what ban_user turns into a ban row.
	s2.start_session(b.id, 'tok-0', '8.8.8.8', 'ag', now + 390)
	n := s2.ban_user(b.id, now + 400)
	assert n.ok && n.value >= 1
	assert s2.users[s2.find_user_index(b.id)].status == c.status_banned
	assert s2.sessions.len == 0
	assert s2.unban_user(b.id, now + 500).ok
	assert s2.users[s2.find_user_index(b.id)].status == c.status_active
	s2.start_session(b.id, 'tok-2', '1.1.1.1', 'ag', now + 510)
	s2.record_search(b.id, 'zzz', now + 520)
	dm_s2 := s2.find_or_create_direct_room(a.id, [
		a.id,
		b.id,
	], now + 525)
	assert dm_s2.ok
	dmail := s2.deactivate_user(b.id, 'STAMP9', now + 530)
	assert dmail.ok
	bu := s2.users[s2.find_user_index(b.id)]
	assert bu.status == c.status_deactivated
	assert bu.email == 'b-deactivated-STAMP9@x.com'
	assert s2.find_membership_index(g.id, b.id) < 0
	assert s2.find_membership_index(dm_s2.value.id, b.id) >= 0
}

// --- webhooks ---------------------------------------------------------------
fn test_webhooks() {
	mut s4 := c.Store{}
	fresh_account(mut s4)
	ba := s4.create_user('BA', 'ba@x.com', c.role_admin, now, '').value
	bb := s4.create_user('BB', 'bb@x.com', c.role_bot, now, 'Tok123456789').value
	s4.set_bot_webhook(bb.id, 'https://bots.example/hook', now)
	gr := s4.create_room(c.room_open, 'G', ba.id, [
		ba.id,
		bb.id,
	], now).value
	bm := s4.post_message(gr.id, ba.id, 'hi @BB', '', [bb.id], 'w1', now + 1)
	assert ('webhook:' + bb.id.str() + ':' + bm.value.id.str()) in s4.outbox
	payload := c.build_webhook_payload(c.WebhookPayload{
		bot_user_id:   bb.id
		bot_user_name: bb.name
		room_id:       gr.id
		room_name:     gr.name
		room_path:     '/rooms/1'
		message_id:    bm.value.id
		message_path:  '/m/1'
		html_body:     '<p>hi</p>'
		plain_body:    'hi'
	})
	assert payload.contains('"id":' + bb.id.str())
	assert c.webhook_reply_kind('text/plain') == 'text'
	assert c.webhook_reply_kind('image/png') == 'attachment'
	assert c.webhook_reply_kind('application/octet-stream') == 'none'
	tr := s4.apply_webhook_reply(gr.id, bb.id, 'text/plain', 'got it', now + 2, 'w2')
	assert tr.ok && tr.value.body == 'got it' && tr.value.creator_id == bb.id
	ar2 := s4.apply_webhook_reply(gr.id, bb.id, 'image/png', 'bytes', now + 3, 'w3')
	assert ar2.ok && ar2.value.attachment_name == 'attachment.png'
	assert c.webhook_timeout_text() == 'Failed to respond within 7 seconds'
	assert c.webhook_attachment_ext('image/jpeg') == 'jpg'
}
