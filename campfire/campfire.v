// Package campfire is the V transpile of
// ../once-campfire-python/src/campfile/domain/campfire.py: the Campfire
// business rules as pure functions over an in-memory Store. It has no
// IO, no database, and no HTTP, exactly like the python unit it mirrors.
//
// Translation notes (python -> V):
//
//   - `@dataclass` becomes a struct carrying attributes: `@[inline]` for
//     the small value entities that live in Store slices (value
//     semantics, like python dataclasses), `@[direct_array_access]` where
//     callers rewrite elements in place, and `@[heap]` for Store itself
//     so the large aggregate never lands on the stack. Every domain
//     function takes the store as `&Store`, so nothing copies it.
//   - python `int` becomes `i64`. V's `int` is pointer sized and python
//     ints are unbounded; IPv4 addresses alone need 33 bits.
//   - constants are snake_case (`ROLE_ADMIN` -> `role_admin`) because V
//     rejects uppercase identifiers, and typed constants use the
//     `= i64(...)` form V requires.
//   - python `assert` contracts carry over unchanged; the `CHECKER.pre`
//     / `CHECKER.post` annotations (a py2many verifier feature) are
//     dropped and their `result == ...` postconditions become the `assert`
//     statements V already supports.
//   - `str` -> `string`, `list[T]` -> `[]T`, `dict` -> `map[K]V`, and
//     `len(text)` counts UTF-8 bytes (V iterates strings bytewise).
module campfire

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const role_member = i64(0)
pub const role_admin = i64(1)
pub const role_bot = i64(2)

pub const status_active = i64(0)
pub const status_deactivated = i64(1)
pub const status_banned = i64(2)

pub const involvement_invisible = i64(0)
pub const involvement_nothing = i64(1)
pub const involvement_mentions = i64(2)
pub const involvement_everything = i64(3)

pub const room_open = i64(0)
pub const room_closed = i64(1)
pub const room_direct = i64(2)

pub const content_text = i64(0)
pub const content_attachment = i64(1)
pub const content_sound = i64(2)

pub const page_size = i64(40)
pub const connection_ttl_secs = i64(60)
pub const session_refresh_secs = i64(3600)
pub const max_recent_searches = i64(10)
pub const boost_max_len = i64(16)
pub const zero_code = i64(48)
pub const bot_token_len = i64(12)
pub const join_code_len = i64(12)
pub const webhook_timeout_secs = i64(7)

// ---------------------------------------------------------------------------
// Entities (zero values are valid: User{} means "none")
// ---------------------------------------------------------------------------

@[inline]
pub struct User {
pub mut:
	id         i64
	name       string
	email      string
	bio        string
	role       i64
	status     i64
	bot_token  string
	created_at i64
}

@[inline]
pub struct Room {
pub mut:
	id         i64
	name       string
	kind       i64
	creator_id i64
	created_at i64
}

@[direct_array_access; inline]
pub struct RoomMembership {
pub mut:
	id           i64
	room_id      i64
	user_id      i64
	involvement  i64 = involvement_mentions
	connections  i64
	connected_at i64
	unread_at    i64
	updated_at   i64
}

@[inline]
pub struct Message {
pub mut:
	id                i64
	room_id           i64
	creator_id        i64
	body              string
	client_message_id string
	attachment_name   string
	mention_ids       []i64
	created_at        i64
}

@[inline]
pub struct Boost {
pub mut:
	id         i64
	message_id i64
	booster_id i64
	content    string
	created_at i64
}

@[inline]
pub struct Ban {
pub mut:
	id         i64
	user_id    i64
	ip_address string
	created_at i64
}

@[inline]
pub struct Session {
pub mut:
	id             i64
	user_id        i64
	token          string
	ip_address     string
	user_agent     string
	last_active_at i64
	created_at     i64
}

@[inline]
pub struct SearchRecord {
pub mut:
	id         i64
	user_id    i64
	query      string
	updated_at i64
}

@[inline]
pub struct PushSubscription {
pub mut:
	id         i64
	user_id    i64
	endpoint   string
	created_at i64
}

@[inline]
pub struct Webhook {
pub mut:
	id         i64
	user_id    i64
	url        string
	created_at i64
}

@[inline]
pub struct Account {
pub mut:
	id                       i64
	name                     string
	join_code                string
	restrict_rooms_to_admins bool
}

@[inline]
pub struct SoundEntry {
pub mut:
	name  string
	text  string
	image string
}

// Store is the whole in-memory world. `@[heap]` keeps the aggregate out of
// the stack frame; every function below takes `&Store`, so the domain
// layer mutates it in place without ever copying it.
@[heap]
pub struct Store {
pub mut:
	next_id     i64 = 1
	users       []User
	rooms       []Room
	memberships []RoomMembership
	messages    []Message
	boosts      []Boost
	bans        []Ban
	sessions    []Session
	searches    []SearchRecord
	push_subs   []PushSubscription
	webhooks    []Webhook
	accounts    []Account
	outbox      []string
}

// ---------------------------------------------------------------------------
// Result types (returned instead of raising)
// ---------------------------------------------------------------------------

@[inline]
pub struct UserResult {
pub mut:
	ok    bool
	value User
	error string
}

@[inline]
pub struct RoomResult {
pub mut:
	ok    bool
	value Room
	error string
}

// The python module declares RoomRoomMembershipResult even though no
// operation returns it; kept for one-to-one parity.
@[inline]
pub struct RoomRoomMembershipResult {
pub mut:
	ok    bool
	value RoomMembership
	error string
}

@[inline]
pub struct MessageResult {
pub mut:
	ok    bool
	value Message
	error string
}

@[inline]
pub struct BoostResult {
pub mut:
	ok    bool
	value Boost
	error string
}

@[inline]
pub struct BanResult {
pub mut:
	ok    bool
	value Ban
	error string
}

@[inline]
pub struct SessionResult {
pub mut:
	ok    bool
	value Session
	error string
}

@[inline]
pub struct SearchResult {
pub mut:
	ok    bool
	value SearchRecord
	error string
}

@[inline]
pub struct WebhookResult {
pub mut:
	ok    bool
	value Webhook
	error string
}

@[inline]
pub struct SoundResult {
pub mut:
	ok    bool
	value SoundEntry
	error string
}

@[inline]
pub struct StrResult {
pub mut:
	ok    bool
	value string
	error string
}

@[inline]
pub struct IntResult {
pub mut:
	ok    bool
	value i64
	error string
}

// ---------------------------------------------------------------------------
// Small pure helpers
// ---------------------------------------------------------------------------

// alloc_id returns a fresh id from the store, advancing the counter.
pub fn (mut s Store) alloc_id() i64 {
	fresh := s.next_id
	s.next_id = s.next_id + 1
	assert fresh > 0
	return fresh
}

// is_digit_char reports whether c is an ASCII digit.
pub fn is_digit_char(c u8) bool {
	return c >= `0` && c <= `9`
}

// is_hex_char reports whether c is an ASCII hex digit.
pub fn is_hex_char(c u8) bool {
	if is_digit_char(c) {
		return true
	}
	if c >= `a` && c <= `f` {
		return true
	}
	if c >= `A` && c <= `F` {
		return true
	}
	return false
}

// is_name_char reports whether c is a sound-command word character.
pub fn is_name_char(c u8) bool {
	if c >= `a` && c <= `z` {
		return true
	}
	if c >= `A` && c <= `Z` {
		return true
	}
	if is_digit_char(c) {
		return true
	}
	return c == `_`
}

// parse_decimal parses an all-digit string, rejecting anything else.
pub fn parse_decimal(text string) IntResult {
	if text == '' {
		return IntResult{
			error: 'not a number'
		}
	}
	mut total := i64(0)
	for ch in text {
		if !is_digit_char(ch) {
			return IntResult{
				error: 'not a number'
			}
		}
		total = total * 10 + (i64(ch) - zero_code)
	}
	return IntResult{
		ok:    true
		value: total
	}
}

// str_len counts UTF-8 bytes, like the Go and V ports do.
pub fn str_len(text string) i64 {
	return text.len
}

// has_prefix reports whether text starts with pref.
pub fn has_prefix(text string, pref string) bool {
	return text.starts_with(pref)
}

// remove_all deletes every occurrence of needle from body.
pub fn remove_all(body string, needle string) string {
	if needle == '' {
		return body
	}
	return body.replace(needle, '')
}

// json_escape escapes a string for embedding in JSON output.
pub fn json_escape(text string) string {
	mut out := []u8{cap: text.len + 8}
	for ch in text {
		if ch == `"` {
			out << `\\`
			out << `"`
		} else if ch == `\\` {
			out << `\\`
			out << `\\`
		} else if ch == `\n` {
			out << `\\`
			out << `n`
		} else if ch == `\t` {
			out << `\\`
			out << `t`
		} else if ch == `\r` {
			out << `\\`
			out << `r`
		} else {
			out << ch
		}
	}
	return out.bytestr()
}

// ---------------------------------------------------------------------------
// User rules (User::Role, avatar initials, title)
// ---------------------------------------------------------------------------

// can_administer mirrors User::Role: admins, owners and new records may administer.
pub fn can_administer(role i64, self_id i64, creator_id i64, is_new_record bool) bool {
	if role == role_admin {
		return true
	} else if self_id == creator_id && self_id != 0 {
		return true
	} else if is_new_record {
		return true
	} else {
		return false
	}
}

// can_create_room reports whether a role may create rooms under the account restriction.
pub fn can_create_room(role i64, restrict_to_admins bool) bool {
	if restrict_to_admins && role != role_admin {
		return false
	} else {
		return true
	}
}

// user_initials returns the avatar initials (first byte of each word).
pub fn user_initials(name string) string {
	mut out := []u8{}
	for w in name.split(' ') {
		if w != '' {
			out << w[0]
		}
	}
	return out.bytestr()
}

// user_title returns "name - bio", whichever parts are present.
pub fn user_title(name string, bio string) string {
	if bio == '' {
		return name
	}
	if name == '' {
		return bio
	}
	title := name + ' - ' + bio
	return title
}

// ---------------------------------------------------------------------------
// Room rules (Room, Rooms::Open/Closed/Direct)
// ---------------------------------------------------------------------------

// default_involvement returns the membership level new members get (direct rooms notify on everything).
pub fn default_involvement(kind i64) i64 {
	if kind == room_direct {
		return involvement_everything
	} else {
		return involvement_mentions
	}
}

// is_valid_room_kind reports whether kind is open, closed or direct.
pub fn is_valid_room_kind(kind i64) bool {
	return kind == room_open || kind == room_closed || kind == room_direct
}

// direct_type_change_blocked forbids widening a direct room after the fact.
pub fn direct_type_change_blocked(old_kind i64, new_kind i64) bool {
	// A direct room's participants agreed to a private conversation, not to
	// one whose audience someone else widens afterwards.
	if old_kind == room_direct && new_kind != room_direct {
		return true
	} else {
		return false
	}
}

// room_kind_name names a room kind for display.
pub fn room_kind_name(kind i64) string {
	if kind == room_open {
		return 'open'
	} else if kind == room_closed {
		return 'closed'
	} else if kind == room_direct {
		return 'direct'
	} else {
		return 'unknown'
	}
}

// involvement_name names an involvement level (the Rails string form).
pub fn involvement_name(involvement i64) string {
	if involvement == involvement_invisible {
		return 'invisible'
	} else if involvement == involvement_nothing {
		return 'nothing'
	} else if involvement == involvement_everything {
		return 'everything'
	} else {
		return 'mentions'
	}
}

// is_visible_membership reports whether an involvement level shows in the sidebar.
pub fn is_visible_membership(involvement i64) bool {
	return involvement != involvement_invisible
}

// same_id_set reports whether two id lists hold the same members.
pub fn same_id_set(a []i64, b []i64) bool {
	if a.len != b.len {
		return false
	}
	for x in a {
		mut found := false
		for y in b {
			if x == y {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// RoomMembership connection rules (RoomMembership::Connectable)
// ---------------------------------------------------------------------------

// is_connected reports whether a membership heartbeat is still within the TTL.
pub fn is_connected(connected_at i64, now i64) bool {
	assert now >= 0 && connected_at >= 0
	if connected_at == 0 {
		return false
	} else {
		return now - connected_at <= connection_ttl_secs
	}
}

// connect_step models present/connect: record the connection and clear unread.
pub fn connect_step(connected_at i64, connections i64, now i64) RoomMembership {
	// Models present/connect: record the connection and clear unread.
	assert now > 0
	return RoomMembership{
		connections:  connections
		connected_at: now
		updated_at:   now
	}
}

// increment_connections adds a connection, or starts a fresh one when expired.
pub fn increment_connections(connected_at i64, connections i64, now i64) RoomMembership {
	if is_connected(connected_at, now) {
		return RoomMembership{
			connections:  connections + 1
			connected_at: connected_at
			updated_at:   now
		}
	}
	return RoomMembership{
		connections:  1
		connected_at: connected_at
		updated_at:   now
	}
}

// decrement_connections removes a connection, clearing the heartbeat at zero.
pub fn decrement_connections(connected_at i64, connections i64, now i64) RoomMembership {
	if is_connected(connected_at, now) {
		mut left := connections - 1
		if left < 0 {
			left = 0
		}
		if left < 1 {
			return RoomMembership{
				connections:  left
				connected_at: 0
				updated_at:   now
			}
		}
		return RoomMembership{
			connections:  left
			connected_at: connected_at
			updated_at:   now
		}
	}
	return RoomMembership{
		connections:  0
		connected_at: 0
		updated_at:   now
	}
}

// ---------------------------------------------------------------------------
// Message rules (body, sound commands, content types, mentions)
// ---------------------------------------------------------------------------

// message_plain_body falls back to the attachment name when the body is empty.
pub fn message_plain_body(body string, attachment_name string) string {
	if body != '' {
		return body
	} else {
		return attachment_name
	}
}

// sound_command parses exactly "/play <word>", else returns empty.
pub fn sound_command(body string) string {
	// Matches /\A\/play (?<name>\w+)\z/: exactly "/play <word>".
	if !has_prefix(body, '/play ') {
		return ''
	}
	mut name := ''
	for part in body.split('/play ') {
		if name != '' {
			return ''
		}
		name = part
	}
	if name == '' {
		return ''
	}
	for ch in name {
		if !is_name_char(ch) {
			return ''
		}
	}
	return name
}

// content_type_of classifies a message as text, attachment or sound.
pub fn content_type_of(has_attachment bool, sound_name string) i64 {
	if has_attachment {
		return content_attachment
	} else if sound_name != '' {
		return content_sound
	} else {
		return content_text
	}
}

// content_type_name names a content type for display.
pub fn content_type_name(content_type i64) string {
	if content_type == content_attachment {
		return 'attachment'
	} else if content_type == content_sound {
		return 'sound'
	} else {
		return 'text'
	}
}

// mention_text renders the @mention token for a user name.
pub fn mention_text(user_name string) string {
	return '@' + user_name
}

// strip_mention removes one user mention token from a body.
pub fn strip_mention(body string, user_name string) string {
	cleaned := remove_all(body, mention_text(user_name))
	return cleaned.trim_space()
}

// ---------------------------------------------------------------------------
// Ban rules (Ban: only public IPs may be banned)
// ---------------------------------------------------------------------------

// parse_ipv4 parses a dotted quad into a 32-bit address.
pub fn parse_ipv4(text string) IntResult {
	parts := text.split('.')
	if parts.len != 4 {
		return IntResult{
			error: 'is not a valid IP address'
		}
	}
	mut total := i64(0)
	for part in parts {
		if part == '' {
			return IntResult{
				error: 'is not a valid IP address'
			}
		}
		if str_len(part) > 3 {
			return IntResult{
				error: 'is not a valid IP address'
			}
		}
		parsed := parse_decimal(part)
		if !parsed.ok {
			return IntResult{
				error: 'is not a valid IP address'
			}
		}
		if parsed.value > 255 {
			return IntResult{
				error: 'is not a valid IP address'
			}
		}
		total = total * 256 + parsed.value
	}
	assert total >= 0
	return IntResult{
		ok:    true
		value: total
	}
}

// ipv4_is_public rejects loopback, private and link-local ranges.
pub fn ipv4_is_public(addr i64) bool {
	assert addr >= 0
	first := addr / 16777216
	second := (addr / 65536) % 256
	if first == 127 {
		return false
	}
	if first == 10 {
		return false
	}
	if first == 172 && second >= 16 && second <= 31 {
		return false
	}
	if first == 192 && second == 168 {
		return false
	}
	if first == 169 && second == 254 {
		return false
	}
	return true
}

// ipv6_tail_after_last_colon returns the embedded IPv4 tail of an IPv6 literal.
pub fn ipv6_tail_after_last_colon(text string) string {
	mut tail := ''
	for ch in text {
		if ch == `:` {
			tail = ''
		} else {
			tail += ch.ascii_str()
		}
	}
	return tail
}

// ipv6_is_well_formed checks the colon/hex/dot shape of an IPv6 literal.
pub fn ipv6_is_well_formed(text string) bool {
	if text == '' {
		return false
	}
	mut has_colon := false
	for ch in text {
		if ch == `:` {
			has_colon = true
		} else if ch == `.` {
			// embedded IPv4 tail: accepted as-is
		} else if is_hex_char(ch) {
			// hex digit: accepted as-is
		} else {
			return false
		}
	}
	return has_colon
}

// ipv6_is_public rejects loopback, link-local and unique-local ranges.
pub fn ipv6_is_public(lower string) bool {
	if lower == '::1' {
		return false
	}
	if has_prefix(lower, 'fe8') {
		return false
	}
	if has_prefix(lower, 'fe9') {
		return false
	}
	if has_prefix(lower, 'fea') {
		return false
	}
	if has_prefix(lower, 'feb') {
		return false
	}
	if has_prefix(lower, 'fc') {
		return false
	}
	if has_prefix(lower, 'fd') {
		return false
	}
	return true
}

// validate_ban_ip accepts only public IPv4/IPv6 addresses for bans.
pub fn validate_ban_ip(ip_address string) StrResult {
	assert ip_address != ''
	parsed := parse_ipv4(ip_address)
	if parsed.ok {
		if ipv4_is_public(parsed.value) {
			return StrResult{
				ok:    true
				value: ip_address
			}
		}
		return StrResult{
			error: 'cannot be a private or internal IP address'
		}
	}
	mut has_dot := false
	for ch in ip_address {
		if ch == `.` {
			has_dot = true
		}
	}
	if has_dot {
		tail := ipv6_tail_after_last_colon(ip_address)
		mapped := parse_ipv4(tail)
		if mapped.ok {
			if ipv4_is_public(mapped.value) {
				return StrResult{
					ok:    true
					value: ip_address
				}
			}
			return StrResult{
				error: 'cannot be a private or internal IP address'
			}
		}
		return StrResult{
			error: 'is not a valid IP address'
		}
	}
	lowered := ip_address.to_lower()
	if !ipv6_is_well_formed(lowered) {
		return StrResult{
			error: 'is not a valid IP address'
		}
	}
	if ipv6_is_public(lowered) {
		return StrResult{
			ok:    true
			value: ip_address
		}
	}
	return StrResult{
		error: 'cannot be a private or internal IP address'
	}
}

// ---------------------------------------------------------------------------
// Bot rules (User::Bot key handling)
// ---------------------------------------------------------------------------

// bot_key_of renders the "<id>-<token>" bot credential.
pub fn bot_key_of(user_id i64, token string) string {
	assert user_id > 0
	assert token != ''
	return user_id.str() + '-' + token
}

// parse_bot_key splits an "<id>-<token>" key and validates the id.
pub fn parse_bot_key(key string) IntResult {
	// Splits "id-token" on the first dash; value is the id when the token
	// part is nonempty.
	mut left := ''
	mut right := ''
	mut seen_dash := false
	for ch in key {
		if ch == `-` && !seen_dash {
			seen_dash = true
		} else if !seen_dash {
			left += ch.ascii_str()
		} else {
			right += ch.ascii_str()
		}
	}
	if !seen_dash {
		return IntResult{
			error: 'invalid bot key'
		}
	} else if right == '' {
		return IntResult{
			error: 'invalid bot key'
		}
	} else {
		parsed := parse_decimal(left)
		if !parsed.ok {
			return IntResult{
				error: 'invalid bot key'
			}
		} else if parsed.value <= 0 {
			return IntResult{
				error: 'invalid bot key'
			}
		} else {
			return IntResult{
				ok:    true
				value: parsed.value
			}
		}
	}
}

// bot_key_token returns the token half of a bot key.
pub fn bot_key_token(key string) string {
	mut right := ''
	mut seen_dash := false
	for ch in key {
		if ch == `-` && !seen_dash {
			seen_dash = true
		} else if seen_dash {
			right += ch.ascii_str()
		}
	}
	return right
}

// is_valid_bot_token checks the 12-character bot token length.
pub fn is_valid_bot_token(token string) bool {
	return str_len(token) == bot_token_len
}

// ---------------------------------------------------------------------------
// Account rules (Account::Joinable)
// ---------------------------------------------------------------------------

// is_valid_join_token checks the 12 alphanumeric join token shape.
pub fn is_valid_join_token(token string) bool {
	if str_len(token) != join_code_len {
		return false
	}
	for ch in token {
		mut ok_ch := false
		if ch >= `a` && ch <= `z` {
			ok_ch = true
		}
		if ch >= `A` && ch <= `Z` {
			ok_ch = true
		}
		if is_digit_char(ch) {
			ok_ch = true
		}
		if !ok_ch {
			return false
		}
	}
	return true
}

// format_join_code renders a join token as "xxxx-xxxx-xxxx".
pub fn format_join_code(token string) StrResult {
	if !is_valid_join_token(token) {
		return StrResult{
			error: 'join token must be 12 alphanumeric characters'
		}
	}
	mut out := ''
	mut i := i64(0)
	for ch in token {
		if i == 4 || i == 8 {
			out += '-'
		}
		out += ch.ascii_str()
		i++
	}
	assert str_len(out) == 14
	return StrResult{
		ok:    true
		value: out
	}
}

// deactivated_email rewrites an address to "head-deactivated-stamp@tail".
pub fn deactivated_email(email string, stamp string) string {
	if email == '' {
		return ''
	}
	assert stamp != ''
	parts := email.split('@')
	if parts.len != 2 {
		return email
	}
	head := parts[0]
	tail := parts[1]
	masked := head + '-deactivated-' + stamp + '@' + tail
	return masked
}

// ---------------------------------------------------------------------------
// Session rules
// ---------------------------------------------------------------------------

// session_needs_refresh reports whether activity is past the refresh window.
pub fn session_needs_refresh(last_active_at i64, now i64) bool {
	assert now >= last_active_at
	return now - last_active_at > session_refresh_secs
}

// ---------------------------------------------------------------------------
// Webhook rules (payload building + reply classification; no HTTP)
// ---------------------------------------------------------------------------

// webhook_timeout_text is the reply body for a timed-out webhook.
pub fn webhook_timeout_text() string {
	return 'Failed to respond within ' + webhook_timeout_secs.str() + ' seconds'
}

// build_webhook_payload takes the nine python arguments as one attributed
// struct: V has no default parameters and no positional call that stays
// readable past four arguments.
pub struct WebhookPayload {
pub mut:
	bot_user_id   i64
	bot_user_name string
	room_id       i64
	room_name     string
	room_path     string
	message_id    i64
	message_path  string
	html_body     string
	plain_body    string
}

// build_webhook_payload renders the JSON a bot webhook receives.
pub fn build_webhook_payload(p WebhookPayload) string {
	assert p.bot_user_id > 0
	assert p.room_id > 0
	assert p.message_id > 0
	mut out := '{"user":{"id":' + p.bot_user_id.str()
	out += ',"name":"' + json_escape(p.bot_user_name) + '"}'
	out += ',"room":{"id":' + p.room_id.str()
	out += ',"name":"' + json_escape(p.room_name) + '"'
	out += ',"path":"' + json_escape(p.room_path) + '"}'
	out += ',"message":{"id":' + p.message_id.str()
	out += ',"body":{"html":"' + json_escape(p.html_body) + '"'
	out += ',"plain":"' + json_escape(p.plain_body) + '"}'
	out += ',"path":"' + json_escape(p.message_path) + '"}}'
	return out
}

// webhook_reply_kind classifies a webhook reply as text, attachment or none.
pub fn webhook_reply_kind(content_type string) string {
	if content_type == 'text/html' {
		return 'text'
	}
	if content_type == 'text/plain' {
		return 'text'
	}
	if content_type == 'image/png' {
		return 'attachment'
	}
	if content_type == 'image/jpeg' {
		return 'attachment'
	}
	if content_type == 'image/webp' {
		return 'attachment'
	}
	if content_type == 'image/gif' {
		return 'attachment'
	}
	if content_type == 'application/pdf' {
		return 'attachment'
	}
	return 'none'
}

// webhook_attachment_ext maps a reply MIME type to a file extension.
pub fn webhook_attachment_ext(content_type string) string {
	if content_type == 'image/png' {
		return 'png'
	}
	if content_type == 'image/jpeg' {
		return 'jpg'
	}
	if content_type == 'image/webp' {
		return 'webp'
	}
	if content_type == 'image/gif' {
		return 'gif'
	}
	if content_type == 'application/pdf' {
		return 'pdf'
	}
	return ''
}

// ---------------------------------------------------------------------------
// Sound catalog (Sound::BUILTIN: name + text or image)
// ---------------------------------------------------------------------------

// builtin_sounds returns the Sound::BUILTIN catalog.
pub fn builtin_sounds() []SoundEntry {
	return [
		SoundEntry{
			name:  '56k'
			image: '56k.webp'
		},
		SoundEntry{
			name: 'ballmer'
			text: 'developers!'
		},
		SoundEntry{
			name: 'bell'
			text: 'bell'
		},
		SoundEntry{
			name: 'bezos'
			text: 'laughing'
		},
		SoundEntry{
			name: 'bueller'
			text: 'anyone?'
		},
		SoundEntry{
			name: 'butts'
			text: 'butts'
		},
		SoundEntry{
			name:  'clowntown'
			image: 'clowntown.webp'
		},
		SoundEntry{
			name: 'cottoneyejoe'
			text: 'cottoneyejoe'
		},
		SoundEntry{
			name: 'crickets'
			text: 'hears crickets chirping'
		},
		SoundEntry{
			name:  'curb'
			image: 'curb.webp'
		},
		SoundEntry{
			name: 'dadgummit'
			text: 'dad gummit!!'
		},
		SoundEntry{
			name:  'dangerzone'
			image: 'dangerzone.webp'
		},
		SoundEntry{
			name: 'danielsan'
			text: 'danielsan'
		},
		SoundEntry{
			name:  'deeper'
			image: 'top.webp'
		},
		SoundEntry{
			name:  'donotwant'
			image: 'donotwant.webp'
		},
		SoundEntry{
			name:  'drama'
			image: 'drama.webp'
		},
		SoundEntry{
			name: 'flawless'
			text: '#flawless'
		},
		SoundEntry{
			name: 'glados'
			text: 'glados'
		},
		SoundEntry{
			name: 'gogogo'
			text: 'Go, go, go!'
		},
		SoundEntry{
			name:  'greatjob'
			image: 'greatjob.webp'
		},
		SoundEntry{
			name: 'greyjoy'
			text: 'greyjoy'
		},
		SoundEntry{
			name: 'guarantee'
			text: 'guarantees it'
		},
		SoundEntry{
			name: 'heygirl'
			text: 'heygirl'
		},
		SoundEntry{
			name: 'honk'
			text: 'HONK'
		},
		SoundEntry{
			name: 'horn'
			text: 'horn'
		},
		SoundEntry{
			name: 'horror'
			text: 'horror'
		},
		SoundEntry{
			name: 'inconceivable'
			text: "doesn't think it means what you think it means"
		},
		SoundEntry{
			name: 'letitgo'
			text: 'letitgo'
		},
		SoundEntry{
			name: 'live'
			text: 'is DOING IT LIVE'
		},
		SoundEntry{
			name:  'loggins'
			image: 'loggins.webp'
		},
		SoundEntry{
			name: 'makeitso'
			text: 'make it so'
		},
		SoundEntry{
			name: 'noooo'
			text: 'noooo'
		},
		SoundEntry{
			name:  'nyan'
			image: 'nyan.webp'
		},
		SoundEntry{
			name: 'ohmy'
			text: 'raises an eyebrow'
		},
		SoundEntry{
			name: 'ohyeah'
			text: "isn't playing by the rules"
		},
		SoundEntry{
			name:  'pushit'
			image: 'pushit.webp'
		},
		SoundEntry{
			name: 'rimshot'
			text: 'plays a rimshot'
		},
		SoundEntry{
			name: 'rollout'
			text: 'is rolling out'
		},
		SoundEntry{
			name:  'rumble'
			image: 'rumble.webp'
		},
		SoundEntry{
			name: 'sax'
			text: 'sax'
		},
		SoundEntry{
			name: 'secret'
			text: 'found a secret area'
		},
		SoundEntry{
			name: 'sexyback'
			text: 'sexyback'
		},
		SoundEntry{
			name: 'story'
			text: 'and now you know'
		},
		SoundEntry{
			name: 'tada'
			text: 'plays a fanfare'
		},
		SoundEntry{
			name: 'tmyk'
			text: 'The More You Know'
		},
		SoundEntry{
			name: 'totes'
			text: 'totes'
		},
		SoundEntry{
			name: 'trololo'
			text: 'trololo'
		},
		SoundEntry{
			name: 'trombone'
			text: 'plays a sad trombone'
		},
		SoundEntry{
			name: 'unix'
			text: 'knows this'
		},
		SoundEntry{
			name: 'vuvuzela'
			text: 'vuvuzela'
		},
		SoundEntry{
			name:  'what'
			image: 'what.webp'
		},
		SoundEntry{
			name: 'whoomp'
			text: 'whoomp'
		},
		SoundEntry{
			name: 'wups'
			text: 'wups!'
		},
		SoundEntry{
			name:  'yay'
			image: 'yay.webp'
		},
		SoundEntry{
			name:  'yeah'
			image: 'yeah.webp'
		},
		SoundEntry{
			name: 'yodel'
			text: 'yodel'
		},
	]
}

// find_sound looks a sound up by name in the catalog.
pub fn find_sound(sounds []SoundEntry, name string) SoundResult {
	assert name != ''
	for s in sounds {
		if s.name == name {
			return SoundResult{
				ok:    true
				value: s
			}
		}
	}
	return SoundResult{
		error: 'unknown sound'
	}
}

// ---------------------------------------------------------------------------
// Store lookups (linear scans; index assignment keeps transpiled Go valid)
// ---------------------------------------------------------------------------

// find_user_index scans the store for a user id.
pub fn (s &Store) find_user_index(user_id i64) int {
	for i, u in s.users {
		if u.id == user_id {
			return i
		}
	}
	return -1
}

// find_room_index scans the store for a room id.
pub fn (s &Store) find_room_index(room_id i64) int {
	for i, r in s.rooms {
		if r.id == room_id {
			return i
		}
	}
	return -1
}

// find_membership_index scans the store for a room/user membership.
pub fn (s &Store) find_membership_index(room_id i64, user_id i64) int {
	for i, m in s.memberships {
		if m.room_id == room_id && m.user_id == user_id {
			return i
		}
	}
	return -1
}

// find_message_index scans the store for a message id.
pub fn (s &Store) find_message_index(message_id i64) int {
	for i, m in s.messages {
		if m.id == message_id {
			return i
		}
	}
	return -1
}

// find_session_index scans the store for a session id.
pub fn (s &Store) find_session_index(session_id i64) int {
	for i, sess in s.sessions {
		if sess.id == session_id {
			return i
		}
	}
	return -1
}

// find_search_index scans the store for a search record id.
pub fn (s &Store) find_search_index(search_id i64) int {
	for i, rec in s.searches {
		if rec.id == search_id {
			return i
		}
	}
	return -1
}

// find_webhook_index_for_user scans the store for a bot webhook.
pub fn (s &Store) find_webhook_index_for_user(user_id i64) int {
	for i, w in s.webhooks {
		if w.user_id == user_id {
			return i
		}
	}
	return -1
}

// is_banned_ip reports whether an address has a ban row.
pub fn (s &Store) is_banned_ip(ip_address string) bool {
	for b in s.bans {
		if b.ip_address == ip_address {
			return true
		}
	}
	return false
}

// member_user_ids lists every member of a room.
pub fn (s &Store) member_user_ids(room_id i64) []i64 {
	mut ids := []i64{}
	for m in s.memberships {
		if m.room_id == room_id {
			ids << m.user_id
		}
	}
	return ids
}

// room_messages lists every message of a room in id order.
pub fn (s &Store) room_messages(room_id i64) []Message {
	mut out := []Message{}
	for m in s.messages {
		if m.room_id == room_id {
			out << m
		}
	}
	return out
}

// message_is_before orders a message against a (created_at, id) anchor.
pub fn message_is_before(msg Message, anchor_created i64, anchor_id i64) bool {
	if msg.created_at < anchor_created {
		return true
	}
	if msg.created_at == anchor_created && msg.id < anchor_id {
		return true
	}
	return false
}

// message_is_after orders a message against a (created_at, id) anchor.
pub fn message_is_after(msg Message, anchor_created i64, anchor_id i64) bool {
	if msg.created_at > anchor_created {
		return true
	}
	if msg.created_at == anchor_created && msg.id > anchor_id {
		return true
	}
	return false
}

// last_page returns the newest page of at most 40 messages.
pub fn last_page(messages []Message) []Message {
	mut out := []Message{}
	mut start := messages.len - int(page_size)
	if start < 0 {
		start = 0
	}
	mut i := start
	for i < messages.len {
		out << messages[i]
		i++
	}
	return out
}

// first_page returns the oldest page of at most 40 messages.
pub fn first_page(messages []Message) []Message {
	mut out := []Message{}
	mut i := 0
	for i < messages.len && i < int(page_size) {
		out << messages[i]
		i++
	}
	return out
}

// page_before returns the 40 messages before an anchor.
pub fn page_before(messages []Message, anchor_created i64, anchor_id i64) []Message {
	mut older := []Message{}
	for m in messages {
		if message_is_before(m, anchor_created, anchor_id) {
			older << m
		}
	}
	return last_page(older)
}

// page_after returns the 40 messages after an anchor.
pub fn page_after(messages []Message, anchor_created i64, anchor_id i64) []Message {
	mut newer := []Message{}
	for m in messages {
		if message_is_after(m, anchor_created, anchor_id) {
			newer << m
		}
	}
	return first_page(newer)
}

// page_around returns an anchor with its surrounding pages.
pub fn page_around(messages []Message, anchor Message) []Message {
	mut out := page_before(messages, anchor.created_at, anchor.id)
	out << anchor
	for m in page_after(messages, anchor.created_at, anchor.id) {
		out << m
	}
	assert out.len >= 1
	return out
}

// is_paged reports whether a message list exceeds one page.
pub fn is_paged(messages []Message) bool {
	return messages.len > int(page_size)
}

// ---------------------------------------------------------------------------
// Store operations: users and rooms
// ---------------------------------------------------------------------------

// create_user validates and stores a user, granting open-room memberships.
pub fn (mut s Store) create_user(name string, email string, role i64, now i64,
	token string) UserResult {
	if name == '' {
		return UserResult{
			error: 'name is required'
		}
	}
	if role != role_member && role != role_admin && role != role_bot {
		return UserResult{
			error: 'unknown role'
		}
	}
	if email != '' {
		for u in s.users {
			if u.email == email {
				return UserResult{
					error: 'email already taken'
				}
			}
		}
	}
	mut bot_token := ''
	if role == role_bot {
		if !is_valid_bot_token(token) {
			return UserResult{
				error: 'bot token must be 12 characters'
			}
		}
		bot_token = token
	}
	user := User{
		id:         s.alloc_id()
		name:       name
		email:      email
		role:       role
		status:     status_active
		bot_token:  bot_token
		created_at: now
	}
	s.users << user
	// New users are automatically granted membership to every open room.
	for r in s.rooms {
		if r.kind == room_open {
			s.memberships << RoomMembership{
				id:          s.alloc_id()
				room_id:     r.id
				user_id:     user.id
				involvement: default_involvement(r.kind)
				updated_at:  now
			}
		}
	}
	assert user.id > 0
	return UserResult{
		ok:    true
		value: user
	}
}

// create_room validates and stores a room with its initial memberships.
pub fn (mut s Store) create_room(kind i64, name string, creator_id i64,
	member_ids []i64, now i64) RoomResult {
	if !is_valid_room_kind(kind) {
		return RoomResult{
			error: 'unknown room kind'
		}
	}
	if kind != room_direct && name == '' {
		return RoomResult{
			error: 'name is required'
		}
	}
	if s.find_user_index(creator_id) < 0 {
		return RoomResult{
			error: 'creator not found'
		}
	}
	room := Room{
		id:         s.alloc_id()
		name:       name
		kind:       kind
		creator_id: creator_id
		created_at: now
	}
	s.rooms << room
	for uid in member_ids {
		if s.find_user_index(uid) < 0 {
			continue
		}
		if s.find_membership_index(room.id, uid) >= 0 {
			continue
		}
		s.memberships << RoomMembership{
			id:          s.alloc_id()
			room_id:     room.id
			user_id:     uid
			involvement: default_involvement(kind)
			updated_at:  now
		}
	}
	assert room.id > 0
	return RoomResult{
		ok:    true
		value: room
	}
}

// find_direct_room finds the direct room for exactly a member set.
pub fn (s &Store) find_direct_room(user_ids []i64) RoomResult {
	for r in s.rooms {
		if r.kind == room_direct {
			members := s.member_user_ids(r.id)
			if same_id_set(members, user_ids) {
				return RoomResult{
					ok:    true
					value: r
				}
			}
		}
	}
	return RoomResult{
		error: 'no direct room for these users'
	}
}

// find_or_create_direct_room reuses the direct room or creates it.
pub fn (mut s Store) find_or_create_direct_room(creator_id i64, user_ids []i64,
	now i64) RoomResult {
	existing := s.find_direct_room(user_ids)
	if existing.ok {
		return existing
	}
	return s.create_room(room_direct, '', creator_id, user_ids, now)
}

// convert_room_kind changes a room kind, granting access when opening.
pub fn (mut s Store) convert_room_kind(room_id i64, new_kind i64, now i64) RoomResult {
	if !is_valid_room_kind(new_kind) {
		return RoomResult{
			error: 'unknown room kind'
		}
	}
	idx := s.find_room_index(room_id)
	if idx < 0 {
		return RoomResult{
			error: 'room not found'
		}
	}
	old := s.rooms[idx]
	if direct_type_change_blocked(old.kind, new_kind) {
		return RoomResult{
			error: "can't be changed for a direct room"
		}
	}
	updated := Room{
		id:         old.id
		name:       old.name
		kind:       new_kind
		creator_id: old.creator_id
		created_at: old.created_at
	}
	s.rooms[idx] = updated
	if new_kind == room_open && old.kind != room_open {
		// Converting to open grants access to every active user.
		for u in s.users {
			if u.status == status_active && s.find_membership_index(room_id, u.id) < 0 {
				s.memberships << RoomMembership{
					id:          s.alloc_id()
					room_id:     room_id
					user_id:     u.id
					involvement: default_involvement(new_kind)
					updated_at:  now
				}
			}
		}
	}
	return RoomResult{
		ok:    true
		value: updated
	}
}

// grant_memberships adds missing memberships and returns the count.
pub fn (mut s Store) grant_memberships(room_id i64, user_ids []i64, now i64) i64 {
	idx := s.find_room_index(room_id)
	assert idx >= 0
	mut added := i64(0)
	for uid in user_ids {
		if s.find_user_index(uid) < 0 {
			continue
		}
		if s.find_membership_index(room_id, uid) >= 0 {
			continue
		}
		s.memberships << RoomMembership{
			id:          s.alloc_id()
			room_id:     room_id
			user_id:     uid
			involvement: default_involvement(s.rooms[idx].kind)
			updated_at:  now
		}
		added++
	}
	assert added >= 0
	return added
}

// remove_memberships drops memberships and returns the count.
pub fn (mut s Store) remove_memberships(room_id i64, user_ids []i64) i64 {
	mut removed := i64(0)
	mut kept := []RoomMembership{}
	for m in s.memberships {
		mut drop := false
		if m.room_id == room_id {
			for uid in user_ids {
				if m.user_id == uid {
					drop = true
				}
			}
		}
		if drop {
			removed++
		} else {
			kept << m
		}
	}
	s.memberships = kept
	assert removed >= 0
	return removed
}

// revise_memberships grants and revokes memberships in one step.
pub fn (mut s Store) revise_memberships(room_id i64, granted []i64, revoked []i64,
	now i64) i64 {
	added := s.grant_memberships(room_id, granted, now)
	removed := s.remove_memberships(room_id, revoked)
	return added + removed
}

// set_involvement changes a membership notification level.
pub fn (mut s Store) set_involvement(room_id i64, user_id i64, involvement i64,
	now i64) bool {
	if involvement < involvement_invisible || involvement > involvement_everything {
		return false
	}
	idx := s.find_membership_index(room_id, user_id)
	if idx < 0 {
		return false
	}
	old := s.memberships[idx]
	s.memberships[idx] = RoomMembership{
		id:           old.id
		room_id:      old.room_id
		user_id:      old.user_id
		involvement:  involvement
		connections:  old.connections
		connected_at: old.connected_at
		unread_at:    old.unread_at
		updated_at:   now
	}
	return true
}

// read_membership clears the unread marker of a membership.
pub fn (mut s Store) read_membership(room_id i64, user_id i64, now i64) bool {
	idx := s.find_membership_index(room_id, user_id)
	if idx < 0 {
		return false
	}
	old := s.memberships[idx]
	s.memberships[idx] = RoomMembership{
		id:           old.id
		room_id:      old.room_id
		user_id:      old.user_id
		involvement:  old.involvement
		connections:  old.connections
		connected_at: old.connected_at
		updated_at:   now
	}
	return true
}

// present_membership records a live connection and clears unread.
pub fn (mut s Store) present_membership(room_id i64, user_id i64, connections i64,
	now i64) bool {
	assert now > 0
	idx := s.find_membership_index(room_id, user_id)
	if idx < 0 {
		return false
	}
	old := s.memberships[idx]
	s.memberships[idx] = RoomMembership{
		id:           old.id
		room_id:      old.room_id
		user_id:      old.user_id
		involvement:  old.involvement
		connections:  connections
		connected_at: now
		updated_at:   now
	}
	return true
}

// disconnect_membership drops one connection of a membership.
pub fn (mut s Store) disconnect_membership(room_id i64, user_id i64, now i64) bool {
	idx := s.find_membership_index(room_id, user_id)
	if idx < 0 {
		return false
	}
	old := s.memberships[idx]
	step := decrement_connections(old.connected_at, old.connections, now)
	s.memberships[idx] = RoomMembership{
		id:           old.id
		room_id:      old.room_id
		user_id:      old.user_id
		involvement:  old.involvement
		connections:  step.connections
		connected_at: step.connected_at
		unread_at:    old.unread_at
		updated_at:   now
	}
	return true
}

// disconnect_all clears every live connection.
pub fn (mut s Store) disconnect_all(now i64) i64 {
	mut count := i64(0)
	for i := 0; i < s.memberships.len; i++ {
		old := s.memberships[i]
		if old.connected_at != 0 {
			s.memberships[i] = RoomMembership{
				id:          old.id
				room_id:     old.room_id
				user_id:     old.user_id
				involvement: old.involvement
				unread_at:   old.unread_at
				updated_at:  now
			}
			count++
		}
	}
	assert count >= 0
	return count
}

// mark_room_unread flags disconnected visible members on a new message.
pub fn (mut s Store) mark_room_unread(room_id i64, creator_id i64, created_at i64,
	now i64) i64 {
	assert created_at > 0
	mut marked := i64(0)
	for i := 0; i < s.memberships.len; i++ {
		old := s.memberships[i]
		if old.room_id == room_id && old.user_id != creator_id
			&& is_visible_membership(old.involvement) && !is_connected(old.connected_at, now) {
			s.memberships[i] = RoomMembership{
				id:           old.id
				room_id:      old.room_id
				user_id:      old.user_id
				involvement:  old.involvement
				connections:  old.connections
				connected_at: old.connected_at
				unread_at:    created_at
				updated_at:   now
			}
			marked++
		}
	}
	assert marked >= 0
	return marked
}

// eligible_webhook_bots lists the bots a message notifies.
pub fn (s &Store) eligible_webhook_bots(room_id i64, message Message) []i64 {
	mut bots := []i64{}
	ridx := s.find_room_index(room_id)
	assert ridx >= 0
	if s.rooms[ridx].kind == room_direct {
		for uid in s.member_user_ids(room_id) {
			uidx := s.find_user_index(uid)
			if uidx >= 0 && s.users[uidx].role == role_bot && s.users[uidx].status == status_active
				&& uid != message.creator_id {
				bots << uid
			}
		}
	} else {
		for mid in message.mention_ids {
			midx := s.find_user_index(mid)
			if midx >= 0 && s.users[midx].role == role_bot && s.users[midx].status == status_active
				&& mid != message.creator_id {
				bots << mid
			}
		}
	}
	return bots
}

// post_message validates, stores and fans out a message.
pub fn (mut s Store) post_message(room_id i64, creator_id i64, body string,
	attachment_name string, mention_ids []i64, client_message_id string,
	now i64) MessageResult {
	assert now > 0
	if s.find_room_index(room_id) < 0 {
		return MessageResult{
			error: 'room not found'
		}
	}
	if s.find_user_index(creator_id) < 0 {
		return MessageResult{
			error: 'creator not found'
		}
	}
	if s.find_membership_index(room_id, creator_id) < 0 {
		return MessageResult{
			error: 'creator is not a room member'
		}
	}
	if body == '' && attachment_name == '' {
		return MessageResult{
			error: 'body or attachment is required'
		}
	}
	mut kept_mentions := []i64{}
	for mid in mention_ids {
		if s.find_membership_index(room_id, mid) >= 0 {
			mut dup := false
			for k in kept_mentions {
				if k == mid {
					dup = true
				}
			}
			if !dup {
				kept_mentions << mid
			}
		}
	}
	msg_id := s.alloc_id()
	mut cid := client_message_id
	if cid == '' {
		cid = 'client-' + msg_id.str()
	}
	message := Message{
		id:                msg_id
		room_id:           room_id
		creator_id:        creator_id
		body:              body
		client_message_id: cid
		attachment_name:   attachment_name
		mention_ids:       kept_mentions
		created_at:        now
	}
	s.messages << message
	s.mark_room_unread(room_id, creator_id, now, now)
	s.outbox << 'push:' + room_id.str() + ':' + msg_id.str()
	for bot_id in s.eligible_webhook_bots(room_id, message) {
		if s.find_webhook_index_for_user(bot_id) >= 0 {
			s.outbox << 'webhook:' + bot_id.str() + ':' + msg_id.str()
		}
	}
	assert message.id > 0
	return MessageResult{
		ok:    true
		value: message
	}
}

// message_mentionees intersects message mentions with room members.
pub fn (s &Store) message_mentionees(message Message) []i64 {
	mut out := []i64{}
	for mid in message.mention_ids {
		if s.find_membership_index(message.room_id, mid) >= 0 {
			out << mid
		}
	}
	return out
}

// boost_message validates and stores a boost.
pub fn (mut s Store) boost_message(message_id i64, booster_id i64, content string,
	now i64) BoostResult {
	assert now > 0
	if s.find_message_index(message_id) < 0 {
		return BoostResult{
			error: 'message not found'
		}
	}
	if s.find_user_index(booster_id) < 0 {
		return BoostResult{
			error: 'booster not found'
		}
	}
	if content == '' {
		return BoostResult{
			error: 'boost content is required'
		}
	}
	if str_len(content) > boost_max_len {
		return BoostResult{
			error: 'boost content is too long'
		}
	}
	boost := Boost{
		id:         s.alloc_id()
		message_id: message_id
		booster_id: booster_id
		content:    content
		created_at: now
	}
	s.boosts << boost
	return BoostResult{
		ok:    true
		value: boost
	}
}

// start_session validates and stores a session.
pub fn (mut s Store) start_session(user_id i64, token string, ip_address string,
	user_agent string, now i64) SessionResult {
	assert now > 0
	if s.find_user_index(user_id) < 0 {
		return SessionResult{
			error: 'user not found'
		}
	}
	if token == '' {
		return SessionResult{
			error: 'token is required'
		}
	}
	session := Session{
		id:             s.alloc_id()
		user_id:        user_id
		token:          token
		ip_address:     ip_address
		user_agent:     user_agent
		last_active_at: now
		created_at:     now
	}
	s.sessions << session
	return SessionResult{
		ok:    true
		value: session
	}
}

// touch_session refreshes activity past the refresh window.
pub fn (mut s Store) touch_session(session_id i64, user_agent string,
	ip_address string, now i64) bool {
	idx := s.find_session_index(session_id)
	if idx < 0 {
		return false
	}
	old := s.sessions[idx]
	assert now >= old.last_active_at
	if session_needs_refresh(old.last_active_at, now) {
		s.sessions[idx] = Session{
			id:             old.id
			user_id:        old.user_id
			token:          old.token
			ip_address:     ip_address
			user_agent:     user_agent
			last_active_at: now
			created_at:     old.created_at
		}
		return true
	}
	return false
}

// trim_searches caps per-user search history at ten records.
pub fn (mut s Store) trim_searches(user_id i64) i64 {
	mut removed := i64(0)
	for {
		mut count := i64(0)
		mut oldest_idx := -1
		mut oldest_time := i64(0)
		mut first_seen := true
		for i, rec in s.searches {
			if rec.user_id == user_id {
				count++
				if first_seen {
					oldest_time = rec.updated_at
					oldest_idx = i
					first_seen = false
				} else if rec.updated_at < oldest_time {
					oldest_time = rec.updated_at
					oldest_idx = i
				}
			}
		}
		if count <= max_recent_searches {
			break
		}
		if oldest_idx < 0 {
			break
		}
		s.searches.delete(oldest_idx)
		removed++
	}
	assert removed >= 0
	return removed
}

// record_search stores or re-touches a search query.
pub fn (mut s Store) record_search(user_id i64, query string, now i64) SearchResult {
	assert now > 0
	if query == '' {
		return SearchResult{
			error: 'query is required'
		}
	}
	if s.find_user_index(user_id) < 0 {
		return SearchResult{
			error: 'user not found'
		}
	}
	for rec in s.searches {
		if rec.user_id == user_id && rec.query == query {
			idx := s.find_search_index(rec.id)
			s.searches[idx] = SearchRecord{
				id:         rec.id
				user_id:    rec.user_id
				query:      rec.query
				updated_at: now
			}
			return SearchResult{
				ok:    true
				value: s.searches[idx]
			}
		}
	}
	// Constructed twice (once to store, once to return) so both share one
	// allocated id, like the python source.
	new_id := s.alloc_id()
	s.searches << SearchRecord{
		id:         new_id
		user_id:    user_id
		query:      query
		updated_at: now
	}
	s.trim_searches(user_id)
	return SearchResult{
		ok:    true
		value: SearchRecord{
			id:         new_id
			user_id:    user_id
			query:      query
			updated_at: now
		}
	}
}

// set_bot_webhook upserts or clears a bot webhook.
pub fn (mut s Store) set_bot_webhook(user_id i64, url string, now i64) WebhookResult {
	assert now > 0
	if s.find_user_index(user_id) < 0 {
		return WebhookResult{
			error: 'user not found'
		}
	}
	idx := s.find_webhook_index_for_user(user_id)
	if url == '' {
		if idx >= 0 {
			s.webhooks.delete(idx)
		}
		return WebhookResult{
			ok: true
		}
	}
	if idx >= 0 {
		old := s.webhooks[idx]
		s.webhooks[idx] = Webhook{
			id:         old.id
			user_id:    user_id
			url:        url
			created_at: old.created_at
		}
		return WebhookResult{
			ok:    true
			value: s.webhooks[idx]
		}
	}
	hook := Webhook{
		id:         s.alloc_id()
		user_id:    user_id
		url:        url
		created_at: now
	}
	s.webhooks << hook
	return WebhookResult{
		ok:    true
		value: hook
	}
}

// apply_webhook_reply posts a classified bot webhook reply.
pub fn (mut s Store) apply_webhook_reply(room_id i64, bot_user_id i64,
	content_type string, body string, now i64, client_id string) MessageResult {
	kind := webhook_reply_kind(content_type)
	no_mentions := []i64{}
	if kind == 'text' {
		if body == '' {
			return MessageResult{
				error: 'empty webhook reply'
			}
		}
		return s.post_message(room_id, bot_user_id, body, '', no_mentions, client_id, now)
	}
	if kind == 'attachment' {
		ext := webhook_attachment_ext(content_type)
		return s.post_message(room_id, bot_user_id, '', 'attachment.' + ext, no_mentions,
			client_id, now)
	}
	return MessageResult{
		error: 'unsupported webhook reply'
	}
}

// create_bot creates a bot user with an optional webhook.
pub fn (mut s Store) create_bot(name string, token string, webhook_url string,
	now i64) UserResult {
	created := s.create_user(name, '', role_bot, now, token)
	if !created.ok {
		return created
	}
	if webhook_url != '' {
		s.set_bot_webhook(created.value.id, webhook_url, now)
	}
	return created
}

// authenticate_bot resolves an "<id>-<token>" key to an active bot.
pub fn (s &Store) authenticate_bot(key string) UserResult {
	parsed := parse_bot_key(key)
	if !parsed.ok {
		return UserResult{
			error: parsed.error
		}
	}
	token := bot_key_token(key)
	for u in s.users {
		if u.id == parsed.value {
			if u.role == role_bot && u.status == status_active && u.bot_token == token {
				return UserResult{
					ok:    true
					value: u
				}
			}
			return UserResult{
				error: 'invalid bot credentials'
			}
		}
	}
	return UserResult{
		error: 'bot not found'
	}
}

// reset_bot_token replaces the token of a bot user.
pub fn (mut s Store) reset_bot_token(user_id i64, new_token string) UserResult {
	if !is_valid_bot_token(new_token) {
		return UserResult{
			error: 'bot token must be 12 characters'
		}
	}
	idx := s.find_user_index(user_id)
	if idx < 0 {
		return UserResult{
			error: 'user not found'
		}
	}
	old := s.users[idx]
	if old.role != role_bot {
		return UserResult{
			error: 'not a bot'
		}
	}
	s.users[idx] = User{
		id:         old.id
		name:       old.name
		email:      old.email
		bio:        old.bio
		role:       old.role
		status:     old.status
		bot_token:  new_token
		created_at: old.created_at
	}
	return UserResult{
		ok:    true
		value: s.users[idx]
	}
}

// create_ban validates and stores a public-IP ban.
pub fn (mut s Store) create_ban(user_id i64, ip_address string, now i64) BanResult {
	assert now > 0
	if s.find_user_index(user_id) < 0 {
		return BanResult{
			error: 'user not found'
		}
	}
	checked := validate_ban_ip(ip_address)
	if !checked.ok {
		return BanResult{
			error: checked.error
		}
	}
	// Constructed twice (once to store, once to return) so both share one
	// allocated id, like the python source.
	new_id := s.alloc_id()
	s.bans << Ban{
		id:         new_id
		user_id:    user_id
		ip_address: ip_address
		created_at: now
	}
	return BanResult{
		ok:    true
		value: Ban{
			id:         new_id
			user_id:    user_id
			ip_address: ip_address
			created_at: now
		}
	}
}

// ban_user bans session IPs, clears sessions and messages, and marks the user banned.
pub fn (mut s Store) ban_user(user_id i64, now i64) IntResult {
	assert now > 0
	uidx := s.find_user_index(user_id)
	if uidx < 0 {
		return IntResult{
			error: 'user not found'
		}
	}
	mut seen := []string{}
	for sess in s.sessions {
		if sess.user_id == user_id && sess.ip_address != '' {
			mut dup := false
			for ip in seen {
				if ip == sess.ip_address {
					dup = true
				}
			}
			if !dup {
				seen << sess.ip_address
			}
		}
	}
	mut count := i64(0)
	for ip in seen {
		res := s.create_ban(user_id, ip, now)
		if res.ok {
			count++
		}
	}
	mut kept_sessions := []Session{}
	for sess in s.sessions {
		if sess.user_id != user_id {
			kept_sessions << sess
		}
	}
	s.sessions = kept_sessions
	old := s.users[uidx]
	s.users[uidx] = User{
		id:         old.id
		name:       old.name
		email:      old.email
		bio:        old.bio
		role:       old.role
		status:     status_banned
		bot_token:  old.bot_token
		created_at: old.created_at
	}
	mut kept_msgs := []Message{}
	for m in s.messages {
		if m.creator_id == user_id {
			s.outbox << 'remove:' + m.id.str()
		} else {
			kept_msgs << m
		}
	}
	s.messages = kept_msgs
	assert count >= 0
	return IntResult{
		ok:    true
		value: count
	}
}

// unban_user clears bans and reactivates a user.
pub fn (mut s Store) unban_user(user_id i64, now i64) UserResult {
	assert now > 0
	uidx := s.find_user_index(user_id)
	if uidx < 0 {
		return UserResult{
			error: 'user not found'
		}
	}
	mut kept := []Ban{}
	for b in s.bans {
		if b.user_id != user_id {
			kept << b
		}
	}
	s.bans = kept
	old := s.users[uidx]
	s.users[uidx] = User{
		id:         old.id
		name:       old.name
		email:      old.email
		bio:        old.bio
		role:       old.role
		status:     status_active
		bot_token:  old.bot_token
		created_at: old.created_at
	}
	_ = now
	return UserResult{
		ok:    true
		value: s.users[uidx]
	}
}

// deactivate_user strips non-direct memberships and anonymizes a user.
pub fn (mut s Store) deactivate_user(user_id i64, stamp string, now i64) StrResult {
	assert now > 0
	uidx := s.find_user_index(user_id)
	if uidx < 0 {
		return StrResult{
			error: 'user not found'
		}
	}
	for i := 0; i < s.memberships.len; i++ {
		m := s.memberships[i]
		if m.user_id == user_id {
			s.memberships[i] = RoomMembership{
				id:          m.id
				room_id:     m.room_id
				user_id:     m.user_id
				involvement: m.involvement
				unread_at:   m.unread_at
				updated_at:  now
			}
		}
	}
	mut kept_m := []RoomMembership{}
	for m in s.memberships {
		mut drop := false
		if m.user_id == user_id {
			ridx := s.find_room_index(m.room_id)
			drop = ridx < 0 || s.rooms[ridx].kind != room_direct
		}
		if !drop {
			kept_m << m
		}
	}
	s.memberships = kept_m
	mut kept_p := []PushSubscription{}
	for p in s.push_subs {
		if p.user_id != user_id {
			kept_p << p
		}
	}
	s.push_subs = kept_p
	mut kept_q := []SearchRecord{}
	for rec in s.searches {
		if rec.user_id != user_id {
			kept_q << rec
		}
	}
	s.searches = kept_q
	mut kept_s := []Session{}
	for sess in s.sessions {
		if sess.user_id != user_id {
			kept_s << sess
		}
	}
	s.sessions = kept_s
	old := s.users[uidx]
	new_email := deactivated_email(old.email, stamp)
	s.users[uidx] = User{
		id:         old.id
		name:       old.name
		email:      new_email
		bio:        old.bio
		role:       old.role
		status:     status_deactivated
		bot_token:  old.bot_token
		created_at: old.created_at
	}
	return StrResult{
		ok:    true
		value: new_email
	}
}

// create_account validates and stores the singleton account.
pub fn (mut s Store) create_account(name string, join_token string, now i64) StrResult {
	assert now > 0
	if name == '' {
		return StrResult{
			error: 'name is required'
		}
	}
	code := format_join_code(join_token)
	if !code.ok {
		return code
	}
	account := Account{
		id:        s.alloc_id()
		name:      name
		join_code: code.value
	}
	s.accounts << account
	_ = now
	return StrResult{
		ok:    true
		value: code.value
	}
}

// reset_account_join_code replaces the account join code.
pub fn (mut s Store) reset_account_join_code(account_id i64, join_token string,
	now i64) StrResult {
	assert now > 0
	code := format_join_code(join_token)
	if !code.ok {
		return code
	}
	for i, a in s.accounts {
		if a.id == account_id {
			s.accounts[i] = Account{
				id:                       a.id
				name:                     a.name
				join_code:                code.value
				restrict_rooms_to_admins: a.restrict_rooms_to_admins
			}
			_ = now
			return StrResult{
				ok:    true
				value: code.value
			}
		}
	}
	return StrResult{
		error: 'account not found'
	}
}
