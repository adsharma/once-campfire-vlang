module database

import crypto.rand
import encoding.hex
import time

pub struct DbError {
	msg  string
	code int
}

pub fn (e DbError) msg() string {
	return e.msg
}

pub fn (e DbError) code() int {
	return e.code
}

pub fn err_forbidden() DbError {
	return DbError{'forbidden', 1}
}

pub fn err_validation() DbError {
	return DbError{'invalid attributes', 2}
}

pub fn err_no_rows() DbError {
	return DbError{'sql: no rows in result set', 3}
}

pub fn is_no_rows(err IError) bool {
	return err.msg() == 'sql: no rows in result set'
}

pub fn is_forbidden(err IError) bool {
	return err.msg() == 'forbidden'
}

pub struct User {
pub mut:
	id         i64
	name       string
	email      string
	password   string
	bio        string
	bot_token  string
	updated_at time.Time
	role       int
	status     int
}

pub fn (u User) title() string {
	mut parts := []string{}
	for value in [u.name, u.bio] {
		if value.trim_space() != '' {
			parts << value
		}
	}
	return parts.join(' – ')
}

pub fn (u User) bot_key() string {
	return '${u.id}-${u.bot_token}'
}

pub struct Room {
pub mut:
	id         i64
	creator_id i64
	name       string
	typ        string
	updated_at time.Time
}

pub fn (r Room) param_key() string {
	match r.typ {
		'Rooms::Closed' {
			return 'rooms_closed'
		}
		'Rooms::Direct' {
			return 'rooms_direct'
		}
		else {
			return 'rooms_open'
		}
	}
}

pub fn (r Room) dom(prefix string) string {
	mut p := prefix
	if p != '' {
		p += '_'
	}
	return '${p}${r.param_key()}_${r.id}'
}

pub fn (r Room) edit_path() string {
	return '/rooms/${r.param_key().replace('rooms_', '')}/${r.id}/edit'
}

pub fn (r Room) noun() string {
	if r.typ == 'Rooms::Direct' {
		return 'Ping'
	}
	return 'room'
}

pub struct Message {
pub mut:
	id         i64
	room_id    i64
	creator_id i64
	client_id  string
	body       string
	creator    string
	created_at time.Time
	updated_at time.Time
}

pub struct Account {
pub mut:
	id            i64
	name          string
	join_code     string
	custom_styles string
	settings      string
	updated_at    time.Time
	has_logo      bool
}

pub fn (a Account) restrict_rooms() bool {
	// Minimal JSON check for {"restrict_room_creation_to_administrators":true}.
	idx := a.settings.index('restrict_room_creation_to_administrators') or { return false }
	rest := a.settings[idx..].to_lower()
	colon := rest.index(':') or { return false }
	return rest[colon + 1..].trim_space_left().starts_with('true')
}

pub struct Boost {
pub mut:
	id                 i64
	message_id         i64
	booster_id         i64
	content            string
	booster            string
	booster_title      string
	booster_updated_at time.Time
	created_at         time.Time
	updated_at         time.Time
}

pub struct Membership {
pub mut:
	id          i64
	room_id     i64
	user_id     i64
	involvement string
	unread      bool
	connections int
	updated_at  time.Time
}

pub struct SidebarRoom {
pub mut:
	room        Room
	involvement string
	unread      bool
}

pub struct PushSubscription {
pub mut:
	id         i64
	user_id    i64
	endpoint   string
	key        string
	auth       string
	user_agent string
}

pub fn token() string {
	b := rand.bytes(24) or { panic(err) }
	return hex.encode(b)
}

pub fn uuid() string {
	b := rand.bytes(16) or { panic(err) }
	mut b2 := b.clone()
	b2[6] = (b2[6] & 15) | 64
	b2[8] = (b2[8] & 63) | 128
	s := hex.encode(b2)
	return s[..8] + '-' + s[8..12] + '-' + s[12..16] + '-' + s[16..20] + '-' + s[20..]
}

pub fn random_token(length int) string {
	alphabet := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
	mut out := []u8{cap: length}
	for out.len < length {
		b := rand.bytes(64) or { panic(err) }
		for v in b {
			if v < 248 {
				out << alphabet[int(v) % alphabet.len]
				if out.len == length {
					break
				}
			}
		}
	}
	return out.bytestr()
}
