// Package workload is the V transpile of
// ../once-campfire-python/src/campfile/domain/workload.py: the five
// benchmark hot paths (room page, messages page, sidebar, search, post)
// plus the deterministic seeder and an in-memory inverted index with
// Porter stemming, mirroring the Rails FTS5 porter tokenizer.
//
// Like campfire/campfire.v this layer is pure: no IO, no database, no
// HTTP. campfile/queries.v is the SQL mirror of these functions over a
// real database; both must return the same views.
module workload

import campfire as c

// V only allows methods on local types; this alias is how the python
// `store: c.Store` first argument becomes a receiver here.
pub type Store = c.Store

// ---------------------------------------------------------------------------
// Deterministic RNG (LCG; same stream in every language)
// ---------------------------------------------------------------------------

// Rng is a mutable dataclass in python (`rng.state = ...`); V needs an
// explicit `mut` receiver. `@[heap]` gives it the reference semantics the
// python object had, so a `mut rng` receiver really does write through.
@[heap]
pub struct Rng {
mut:
	state i64
}

pub const rng_a = i64(1103515245)
pub const rng_c = i64(12345)
pub const rng_m = i64(2147483648)

pub fn (mut r Rng) next(modulus i64) i64 {
	assert modulus > 0
	// i64 arithmetic, not i32: rng_a * state reaches ~2.4e18.
	r.state = (rng_a * r.state + rng_c) % rng_m
	return r.state % modulus
}

// ---------------------------------------------------------------------------
// Porter stemmer (static-python subset: index loops, no slicing, no regex)
// ---------------------------------------------------------------------------

pub fn is_vowel_char(ch string) bool {
	return ch == 'a' || ch == 'e' || ch == 'i' || ch == 'o' || ch == 'u'
}

pub fn word_len(word string) i64 {
	return word.len
}

// char_at returns the one-byte character at i, or "" past the end.
pub fn char_at(word string, i i64) string {
	if i < 0 || i >= word.len {
		return ''
	}
	return word[i].ascii_str()
}

pub fn is_consonant_at(word string, i i64, n i64) bool {
	assert n >= 0
	ch := char_at(word, i)
	if is_vowel_char(ch) {
		return false
	}
	if ch == 'y' {
		if i == 0 {
			return true
		}
		return !is_consonant_at(word, i - 1, n)
	}
	return true
}

pub fn starts_at(word string, pos i64, suffix string) bool {
	mut k := i64(0)
	for ch in suffix {
		if char_at(word, pos + k) != ch.ascii_str() {
			return false
		}
		k++
	}
	return true
}

pub fn ends_with(word string, n i64, suffix string) bool {
	m := word_len(suffix)
	if m > n {
		return false
	}
	return starts_at(word, n - m, suffix)
}

pub fn head_upto(word string, n i64) string {
	mut out := []u8{cap: word.len}
	mut k := i64(0)
	for ch in word {
		if k < n {
			out << ch
		}
		k++
	}
	return out.bytestr()
}

pub fn measure(word string, n i64) i64 {
	mut m := i64(0)
	mut i := i64(0)
	for i < n {
		for i < n && is_consonant_at(word, i, n) {
			i++
		}
		if i >= n {
			break
		}
		for i < n && !is_consonant_at(word, i, n) {
			i++
		}
		if i < n {
			m++
		}
	}
	assert m >= 0
	return m
}

pub fn has_vowel(word string, n i64) bool {
	mut i := i64(0)
	for i < n {
		if !is_consonant_at(word, i, n) {
			return true
		}
		i++
	}
	return false
}

pub fn ends_double_consonant(word string, n i64) bool {
	if n < 2 {
		return false
	}
	if char_at(word, n - 1) != char_at(word, n - 2) {
		return false
	}
	return is_consonant_at(word, n - 1, n)
}

pub fn ends_cvc(word string, n i64) bool {
	if n < 3 {
		return false
	}
	if !is_consonant_at(word, n - 3, n) {
		return false
	}
	if is_consonant_at(word, n - 2, n) {
		return false
	}
	if !is_consonant_at(word, n - 1, n) {
		return false
	}
	last := char_at(word, n - 1)
	if last == 'w' || last == 'x' || last == 'y' {
		return false
	}
	return true
}

pub fn step_1a(word string) string {
	n := word_len(word)
	if ends_with(word, n, 'sses') {
		return head_upto(word, n - 2)
	}
	if ends_with(word, n, 'ies') {
		return head_upto(word, n - 2)
	}
	if ends_with(word, n, 'ss') {
		return word
	}
	if ends_with(word, n, 's') {
		return head_upto(word, n - 1)
	}
	return word
}

pub fn step_1b_helper(word string) string {
	n := word_len(word)
	if ends_with(word, n, 'at') || ends_with(word, n, 'bl') || ends_with(word, n, 'iz') {
		return word + 'e'
	}
	if ends_double_consonant(word, n) {
		last := char_at(word, n - 1)
		if last == 'l' || last == 's' || last == 'z' {
			return word
		}
		return head_upto(word, n - 1)
	}
	if measure(word, n) == 1 && ends_cvc(word, n) {
		return word + 'e'
	}
	return word
}

pub fn step_1b(word string) string {
	n := word_len(word)
	if ends_with(word, n, 'eed') {
		stem := head_upto(word, n - 3)
		if measure(stem, word_len(stem)) > 0 {
			return head_upto(word, n - 1)
		}
		return word
	}
	if ends_with(word, n, 'ed') {
		stem2 := head_upto(word, n - 2)
		if has_vowel(stem2, word_len(stem2)) {
			return step_1b_helper(stem2)
		}
		return word
	}
	if ends_with(word, n, 'ing') {
		stem3 := head_upto(word, n - 3)
		if has_vowel(stem3, word_len(stem3)) {
			return step_1b_helper(stem3)
		}
		return word
	}
	return word
}

pub fn step_1c(word string) string {
	n := word_len(word)
	if ends_with(word, n, 'y') {
		stem := head_upto(word, n - 1)
		if has_vowel(stem, word_len(stem)) {
			return stem + 'i'
		}
	}
	return word
}

// step_2 replaces each (suffix, replacement) pair in turn.
fn step_pairs(word string, pairs []string) string {
	n := word_len(word)
	mut k := 0
	for k < pairs.len {
		sfx := pairs[k]
		rep := pairs[k + 1]
		if ends_with(word, n, sfx) {
			stem := head_upto(word, n - word_len(sfx))
			if measure(stem, word_len(stem)) > 0 {
				return stem + rep
			}
			return word
		}
		k += 2
	}
	return word
}

pub fn step_2(word string) string {
	pairs := ['ational', 'ate', 'tional', 'tion', 'enci', 'ence', 'anci', 'ance', 'izer', 'ize',
		'bli', 'ble', 'alli', 'al', 'entli', 'ent', 'eli', 'e', 'ousli', 'ous', 'ization', 'ize',
		'ation', 'ate', 'ator', 'ate', 'alism', 'al', 'iveness', 'ive', 'fulness', 'ful', 'ousness',
		'ous', 'aliti', 'al', 'iviti', 'ive', 'biliti', 'ble', 'logi', 'log']
	return step_pairs(word, pairs)
}

pub fn step_3(word string) string {
	pairs := ['icate', 'ic', 'ative', '', 'alize', 'al', 'iciti', 'ic', 'ical', 'ic', 'ful', '',
		'ness', '']
	return step_pairs(word, pairs)
}

pub fn step_4(word string) string {
	n := word_len(word)
	suffixes := ['al', 'ance', 'ence', 'er', 'ic', 'able', 'ible', 'ant', 'ement', 'ment', 'ent',
		'ou', 'ism', 'ate', 'iti', 'ous', 'ive', 'ize']
	for sfx in suffixes {
		if ends_with(word, n, sfx) {
			stem := head_upto(word, n - word_len(sfx))
			if measure(stem, word_len(stem)) > 1 {
				return stem
			}
			return word
		}
	}
	if ends_with(word, n, 'sion') || ends_with(word, n, 'tion') {
		stem2 := head_upto(word, n - 3)
		if measure(stem2, word_len(stem2)) > 1 {
			return stem2
		}
		return word
	}
	return word
}

pub fn step_5(word string) string {
	n := word_len(word)
	if ends_with(word, n, 'e') {
		stem := head_upto(word, n - 1)
		m := measure(stem, word_len(stem))
		if m > 1 {
			return stem
		}
		if m == 1 && !ends_cvc(stem, word_len(stem)) {
			return stem
		}
	}
	if ends_with(word, n, 'll') {
		stem2 := head_upto(word, n - 1)
		if measure(stem2, word_len(stem2)) > 1 {
			return stem2
		}
	}
	return word
}

pub fn porter_stem(raw string) string {
	if word_len(raw) <= 2 {
		return raw
	}
	mut w := step_1a(raw)
	w = step_1b(w)
	w = step_1c(w)
	w = step_2(w)
	w = step_3(w)
	w = step_4(w)
	w = step_5(w)
	return w
}

// ---------------------------------------------------------------------------
// Tokenizer + inverted index
// ---------------------------------------------------------------------------

pub fn is_token_char(ch u8) bool {
	if ch >= `a` && ch <= `z` {
		return true
	}
	if ch >= `A` && ch <= `Z` {
		return true
	}
	if ch >= `0` && ch <= `9` {
		return true
	}
	return false
}

pub fn lower_char(ch u8) u8 {
	if ch >= `A` && ch <= `Z` {
		return ch + 32
	}
	return ch
}

pub fn tokenize(text string) []string {
	mut toks := []string{}
	mut cur := []u8{}
	for ch in text {
		if is_token_char(ch) {
			cur << lower_char(ch)
		} else {
			if cur.len != 0 {
				toks << cur.bytestr()
				cur = []u8{}
			}
		}
	}
	if cur.len != 0 {
		toks << cur.bytestr()
	}
	return toks
}

pub fn stem_tokens(toks []string) []string {
	mut out := []string{cap: toks.len}
	for t in toks {
		out << porter_stem(t)
	}
	return out
}

// SearchIndex is the in-memory stand-in for the message_search_index FTS5
// table: `postings` maps a term to a flat [id, count, id, count, ...] pair
// list in increasing id order, `doc_room` maps a message id to its room.
// `@[heap]` keeps `doc_count` writes visible to the caller, like the python
// dataclass attribute.
@[heap]
pub struct SearchIndex {
pub mut:
	postings  map[string][]i64
	doc_room  map[i64]i64
	doc_count i64
}

pub fn new_search_index() &SearchIndex {
	return &SearchIndex{
		postings: map[string][]i64{}
		doc_room: map[i64]i64{}
	}
}

pub fn (mut idx SearchIndex) add(term string, msg_id i64) {
	// Postings are flat [id, count, id, count, ...] pairs in increasing id
	// order (messages are indexed in id order), so intersections merge in
	// one linear pass instead of rescanning per candidate.
	if term in idx.postings {
		mut pairs := idx.postings[term]
		if pairs.len >= 2 && pairs[pairs.len - 2] == msg_id {
			pairs[pairs.len - 1] = pairs[pairs.len - 1] + 1
		} else {
			pairs << msg_id
			pairs << 1
		}
	} else {
		idx.postings[term] = [msg_id, 1]
	}
}

pub fn build_search_index(s &Store) &SearchIndex {
	mut idx := new_search_index()
	for m in s.messages {
		for t in stem_tokens(tokenize(m.body)) {
			idx.add(t, m.id)
		}
		idx.doc_room[m.id] = m.room_id
	}
	idx.doc_count = s.messages.len
	return idx
}

pub fn (mut idx SearchIndex) index_message(room_id i64, msg_id i64, body string) i64 {
	assert room_id > 0
	assert msg_id > 0
	mut added := i64(0)
	for t in stem_tokens(tokenize(body)) {
		idx.add(t, msg_id)
		added++
	}
	idx.doc_room[msg_id] = room_id
	idx.doc_count++
	assert added >= 0
	return added
}

pub fn (idx SearchIndex) postings_for(term string) []i64 {
	if term in idx.postings {
		return idx.postings[term]
	}
	return []i64{}
}

pub fn pair_id(pairs []i64, pos i64) i64 {
	return pairs[pos * 2]
}

pub fn pair_count(pairs []i64, pos i64) i64 {
	return pairs[pos * 2 + 1]
}

pub fn pair_len(pairs []i64) i64 {
	mut n := i64(0)
	mut i := i64(0)
	for i < pairs.len {
		n++
		i += 2
	}
	return n
}

pub fn search_messages(s &Store, idx &SearchIndex, user_id i64, query string,
	limit i64) []i64 {
	assert limit > 0
	terms := stem_tokens(tokenize(query))
	if terms.len == 0 {
		return []i64{}
	}
	mut rooms := []i64{}
	for m in s.memberships {
		if m.user_id == user_id && m.involvement != c.involvement_invisible {
			rooms << m.room_id
		}
	}
	mut lists := [][]i64{}
	for t in terms {
		hits := idx.postings_for(t)
		if pair_len(hits) == 0 {
			return []i64{}
		}
		lists << hits
	}
	mut pos := []i64{cap: lists.len}
	mut lens := []i64{cap: lists.len}
	for l in lists {
		pos << 0
		lens << pair_len(l)
	}
	mut scored_ids := []i64{}
	mut scored_vals := []i64{}
	for {
		mut done := false
		mut top := i64(0)
		mut li := 0
		for li < lists.len {
			if pos[li] >= lens[li] {
				done = true
			} else if pair_id(lists[li], pos[li]) > top {
				top = pair_id(lists[li], pos[li])
			}
			li++
		}
		if done {
			break
		}
		mut aligned := true
		mut score := i64(0)
		mut li2 := 0
		for li2 < lists.len {
			if pair_id(lists[li2], pos[li2]) < top {
				aligned = false
				pos[li2] = pos[li2] + 1
			} else {
				score += pair_count(lists[li2], pos[li2])
			}
			li2++
		}
		if aligned {
			if top in idx.doc_room {
				rid := idx.doc_room[top]
				mut in_room := false
				for r in rooms {
					if r == rid {
						in_room = true
					}
				}
				if in_room {
					scored_ids << top
					scored_vals << score
				}
			}
			mut li3 := 0
			for li3 < lists.len {
				pos[li3] = pos[li3] + 1
				li3++
			}
		}
	}
	mut out := []i64{}
	for out.len < limit && scored_ids.len > 0 {
		mut best := 0
		mut bi := 1
		for bi < scored_ids.len {
			if scored_vals[bi] > scored_vals[best] {
				best = bi
			}
			bi++
		}
		out << scored_ids[best]
		mut kept_ids := []i64{}
		mut kept_vals := []i64{}
		for i := 0; i < scored_ids.len; i++ {
			if i != best {
				kept_ids << scored_ids[i]
				kept_vals << scored_vals[i]
			}
		}
		scored_ids = kept_ids.clone()
		scored_vals = kept_vals.clone()
	}
	return out
}

// ---------------------------------------------------------------------------
// Presentation views (the JSON the bench compares; fields are the wire names)
// ---------------------------------------------------------------------------

@[inline]
pub struct MessageView {
pub mut:
	id                i64
	body              string
	creator_id        i64
	creator_name      string
	created_at        i64
	client_message_id string
	attachment_name   string
	content_type      string = 'text'
	boosts            []string
	mentions          []string
}

@[inline]
pub struct RoomPageView {
pub mut:
	room_id   i64
	room_name string
	room_kind i64
	messages  []MessageView
	has_more  bool
}

@[inline]
pub struct SidebarEntry {
pub mut:
	room_id     i64
	room_name   string
	room_kind   i64
	unread      bool
	involvement i64 = c.involvement_mentions
}

@[inline]
pub struct SearchHitView {
pub mut:
	message   MessageView
	room_name string
}

@[inline]
pub struct RoomPageResult {
pub mut:
	ok    bool
	value RoomPageView
	error string
}

@[inline]
pub struct MessagesPageResult {
pub mut:
	ok    bool
	value []MessageView
	error string
}

@[inline]
pub struct SidebarResult {
pub mut:
	ok    bool
	value []SidebarEntry
	error string
}

@[inline]
pub struct SearchPageResult {
pub mut:
	ok    bool
	value []SearchHitView
	error string
}

pub fn user_name_of(s &Store, user_id i64) string {
	idx := s.find_user_index(user_id)
	if idx < 0 {
		return ''
	}
	return s.users[idx].name
}

pub fn build_message_view(s &Store, m c.Message) MessageView {
	mut v := MessageView{
		id:                m.id
		body:              m.body
		creator_id:        m.creator_id
		creator_name:      user_name_of(s, m.creator_id)
		created_at:        m.created_at
		client_message_id: m.client_message_id
		attachment_name:   m.attachment_name
	}
	has_att := m.attachment_name != ''
	snd := c.sound_command(m.body)
	v.content_type = c.content_type_name(c.content_type_of(has_att, snd))
	for b in s.boosts {
		if b.message_id == m.id {
			v.boosts << b.content
		}
	}
	for mid in m.mention_ids {
		nm := user_name_of(s, mid)
		if nm != '' {
			v.mentions << nm
		}
	}
	return v
}

pub fn room_page(s &Store, room_id i64, user_id i64) RoomPageResult {
	if s.find_membership_index(room_id, user_id) < 0 {
		return RoomPageResult{
			error: 'not a member'
		}
	}
	ridx := s.find_room_index(room_id)
	if ridx < 0 {
		return RoomPageResult{
			error: 'room not found'
		}
	}
	room := s.rooms[ridx]
	msgs := s.room_messages(room_id)
	page := c.last_page(msgs)
	mut view := RoomPageView{
		room_id:   room.id
		room_name: room.name
		room_kind: room.kind
		has_more:  msgs.len > int(c.page_size)
	}
	for m in page {
		view.messages << build_message_view(s, m)
	}
	assert view.room_id > 0
	return RoomPageResult{
		ok:    true
		value: view
	}
}

pub fn messages_page(s &Store, room_id i64, user_id i64, before_id i64,
	after_id i64) MessagesPageResult {
	if s.find_membership_index(room_id, user_id) < 0 {
		return MessagesPageResult{
			error: 'not a member'
		}
	}
	msgs := s.room_messages(room_id)
	mut page := []c.Message{}
	if before_id > 0 {
		anchor_idx := s.find_message_index(before_id)
		if anchor_idx < 0 {
			return MessagesPageResult{
				error: 'message not found'
			}
		}
		anchor := s.messages[anchor_idx]
		page = c.page_before(msgs, anchor.created_at, anchor.id)
	} else if after_id > 0 {
		anchor_idx := s.find_message_index(after_id)
		if anchor_idx < 0 {
			return MessagesPageResult{
				error: 'message not found'
			}
		}
		anchor2 := s.messages[anchor_idx]
		page = c.page_after(msgs, anchor2.created_at, anchor2.id)
	} else {
		page = c.last_page(msgs)
	}
	mut out := []MessageView{}
	for m in page {
		out << build_message_view(s, m)
	}
	return MessagesPageResult{
		ok:    true
		value: out
	}
}

pub fn sidebar(s &Store, user_id i64) SidebarResult {
	if s.find_user_index(user_id) < 0 {
		return SidebarResult{
			error: 'user not found'
		}
	}
	mut entries := []SidebarEntry{}
	for m in s.memberships {
		if m.user_id == user_id && c.is_visible_membership(m.involvement) {
			ridx := s.find_room_index(m.room_id)
			if ridx >= 0 {
				entries << SidebarEntry{
					room_id:     m.room_id
					room_name:   s.rooms[ridx].name
					room_kind:   s.rooms[ridx].kind
					unread:      m.unread_at != 0
					involvement: m.involvement
				}
			}
		}
	}
	// Insertion sort by (lower(name), id), like the python bubble insert.
	mut ordered := []SidebarEntry{}
	for e in entries {
		mut pos := 0
		for pos < ordered.len {
			o := ordered[pos]
			if o.room_name.to_lower() > e.room_name.to_lower() {
				break
			}
			if o.room_name.to_lower() == e.room_name.to_lower() && o.room_id > e.room_id {
				break
			}
			pos++
		}
		mut head := []SidebarEntry{}
		mut tail := []SidebarEntry{}
		for i := 0; i < ordered.len; i++ {
			if i < pos {
				head << ordered[i]
			} else {
				tail << ordered[i]
			}
		}
		head << e
		head << tail
		ordered = head.clone()
	}
	return SidebarResult{
		ok:    true
		value: ordered
	}
}

pub fn search_page(s &Store, idx &SearchIndex, user_id i64, query string,
	limit i64) SearchPageResult {
	if s.find_user_index(user_id) < 0 {
		return SearchPageResult{
			error: 'user not found'
		}
	}
	ids := search_messages(s, idx, user_id, query, limit)
	mut out := []SearchHitView{}
	for mid in ids {
		midx := s.find_message_index(mid)
		if midx < 0 {
			continue
		}
		m := s.messages[midx]
		mut hit := SearchHitView{
			message: build_message_view(s, m)
		}
		ridx := s.find_room_index(m.room_id)
		if ridx >= 0 {
			hit.room_name = s.rooms[ridx].name
		}
		out << hit
	}
	return SearchPageResult{
		ok:    true
		value: out
	}
}

pub fn post_message_view(mut s Store, room_id i64, creator_id i64, body string,
	client_message_id string, now i64) c.MessageResult {
	return s.post_message(room_id, creator_id, body, '', [], client_message_id, now)
}

// ---------------------------------------------------------------------------
// Deterministic seeder (LCG only; same corpus in every language)
// ---------------------------------------------------------------------------

pub const words = ['coffee', 'morning', 'standup', 'deploy', 'review', 'lunch', 'weekend', 'hike',
	'trail', 'summit', 'server', 'latency', 'cache', 'query', 'index', 'search', 'rooms', 'sidebar',
	'mention', 'thread', 'reply', 'draft', 'ship', 'launch', 'retro', 'sprint', 'ticket', 'bugfix',
	'hotfix', 'merge', 'branch', 'commit', 'push', 'pull', 'test', 'green', 'red', 'flaky', 'retry',
	'timeout', 'queue', 'worker', 'cron', 'backup', 'restore', 'migrate', 'schema', 'column', 'row',
	'table', 'join', 'filter', 'sort', 'page', 'limit', 'offset', 'cursor', 'scroll', 'unread',
	'badge', 'ping', 'pong', 'hello', 'thanks', 'please', 'sorry', 'welcome', 'goodbye', 'night',
	'today', 'tomorrow', 'yesterday', 'meeting', 'agenda', 'notes', 'doc', 'link', 'image', 'video',
	'audio', 'file', 'upload', 'download', 'share', 'invite', 'join', 'leave', 'archive', 'pin',
	'star', 'emoji', 'react', 'laugh', 'party', 'tada', 'rocket', 'fire', 'water', 'cooler', 'chat',
	'talk', 'discuss', 'decide', 'shipit', 'rails', 'ruby', 'python', 'go', 'rust', 'lean', 'elixir',
	'postgres', 'redis', 'sqlite', 'docker', 'server', 'client']

pub fn (mut r Rng) pick_word() string {
	return words[r.next(words.len)]
}

pub fn (mut r Rng) make_body(coffees bool) string {
	n := 5 + r.next(20)
	mut out := []u8{}
	mut i := i64(0)
	for i < n {
		if i > 0 {
			out << ` `
		}
		if coffees && r.next(20) == 0 {
			out << 'coffee'.bytes()
		} else {
			out << r.pick_word().bytes()
		}
		i++
	}
	return out.bytestr()
}

pub fn seed_store(user_count i64, big_room_messages i64, seed i64) &c.Store {
	assert user_count > 0
	assert big_room_messages > 0
	mut rng := Rng{
		state: seed
	}
	mut store := &c.Store{}
	code := c.format_join_code('SeedCode1234')
	assert code.ok
	store.accounts << c.Account{
		id:        1
		name:      'Acme'
		join_code: code.value
	}
	store.next_id = 2
	mut now := i64(1700000000 - 30 * 86400)
	mut users := []i64{}
	mut ui := i64(0)
	for ui < user_count {
		nm := 'user' + ui.str()
		em := 'user' + ui.str() + '@example.com'
		mut role := c.role_member
		if ui == 0 {
			role = c.role_admin
		}
		res := store.create_user(nm, em, role, now, '')
		assert res.ok
		users << res.value.id
		ui++
	}
	general := store.create_room(c.room_open, 'Watercooler', users[0], users, now)
	assert general.ok
	eng := store.create_room(c.room_closed, 'Engineering', users[0], users, now)
	assert eng.ok
	gid := general.value.id
	mut mi := i64(0)
	for mi < big_room_messages {
		now += 1 + rng.next(30)
		uid := users[rng.next(users.len)]
		mut body := rng.make_body(true)
		mut mentions := []i64{}
		if rng.next(12) == 0 {
			mid2 := users[rng.next(users.len)]
			if mid2 != uid {
				body = '@' + user_name_of(store, mid2) + ' ' + body
				mentions << mid2
			}
		}
		posted := store.post_message(gid, uid, body, '', mentions, '', now)
		assert posted.ok
		if rng.next(12) == 0 {
			booster := users[rng.next(users.len)]
			store.boost_message(posted.value.id, booster, 'tada', now)
		}
		mi++
	}
	assert store.messages.len == int(big_room_messages)
	return store
}
