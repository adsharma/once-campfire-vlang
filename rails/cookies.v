// Package rails implements the persisted Rails wire formats used by Campfire.
module rails

import crypto.aes
import crypto.hmac
import crypto.rand
import crypto.pbkdf2
import crypto.sha1
import crypto.sha256
import encoding.base64
import encoding.hex
import time

pub enum RailsErrKind {
	invalid
	purpose
	expired
}

pub struct RailsError {
	kind RailsErrKind
}

pub fn (e RailsError) msg() string {
	match e.kind {
		.invalid { return 'invalid signed or encrypted message' }
		.purpose { return 'message purpose mismatch' }
		.expired { return 'message expired' }
	}
}

pub fn (e RailsError) code() int {
	return int(e.kind) + 1
}

fn err_invalid() RailsError {
	return RailsError{RailsErrKind.invalid}
}

// Secrets are derived once at boot, as in reference/crates/rails_compat/src/cookies.rs.
// Rails derives with SHA256 but signs cookies with SHA1.
pub struct Secrets {
	secret   string
	signing  []u8
	signed_ids  []u8
	signed_gids []u8
	streams  []u8
	aead     &aes.AesGcm
}

pub fn derive_key(secret string, salt string, length int) []u8 {
	return pbkdf2.key(secret.bytes(), salt.bytes(), 1000, length, sha256.new()) or { panic(err) }
}

pub fn new_secrets(secret string) !Secrets {
	if secret == '' {
		return error('SECRET_KEY_BASE is required')
	}
	aead := aes.new_aes_gcm(derive_key(secret, 'authenticated encrypted cookie', 32))!
	return Secrets{
		secret:      secret
		signed_ids:  derive_key(secret, 'active_record/signed_id', 64)
		signed_gids: derive_key(secret, 'signed_global_ids', 64)
		signing:     derive_key(secret, 'signed cookie', 64)
		aead:        aead
		streams:     derive_key(secret, 'turbo/signed_stream_verifier_key', 64)
	}
}

// encode_value escapes HTML characters in encoded JSON but preserves Unicode
// line separators, matching ActiveSupport's JSON encoder used by the Go port.
fn encode_value(inner_json string) string {
	mut out := []u8{cap: inner_json.len}
	bs := inner_json.bytes()
	mut i := 0
	for i < bs.len {
		if bs[i] == `\\` && i + 1 < bs.len {
			if i + 5 < bs.len && ((bs[i..i + 6].bytestr() == '\\u2028') || (bs[i..i + 6].bytestr() == '\\u2029')) {
				if bs[i + 5] == `8` {
					out << [u8(0xe2), 0x80, 0xa8]
				} else {
					out << [u8(0xe2), 0x80, 0xa9]
				}
				i += 6
			} else {
				out << bs[i]
				i++
				out << bs[i]
				i++
			}
		} else {
			out << bs[i]
			i++
		}
	}
	return out.bytestr()
}

// Struct field order is part of Rails' signed byte representation.
fn envelope(inner_json string, name string, expires time.Time) string {
	data := encode_value(inner_json)
	mut exp := 'null'
	if !expires.is_zero() {
		exp = jquote(format_exp(expires), true)
	}
	return '{"_rails":{"message":' + jquote(base64.encode(data.bytes()), false) + ',"exp":' + exp +
		',"pur":' + jquote('cookie.' + name, true) + '}}'
}

fn decode64(s string) ![]u8 {
	mut t := s.replace('-', '+').replace('_', '/')
	for t.ends_with('=') {
		t = t[..t.len - 1]
	}
	for t.len % 4 != 0 {
		t += '='
	}
	return base64.decode(t)
}

fn b64_std(data []u8) string {
	return base64.encode(data)
}

// b64_std_decode is a strict standard-alphabet base64 decoder matching Go's
// base64.StdEncoding.DecodeString (correct padding required).
fn b64_std_decode(s string) ![]u8 {
	alpha := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	if s.len % 4 != 0 {
		return error('bad base64 length')
	}
	mut vals := []int{cap: s.len}
	mut pad := 0
	for i in 0 .. s.len {
		c := s[i]
		if c == `=` {
			pad++
			vals << 0
			continue
		}
		if pad > 0 {
			return error('bad base64 padding')
		}
		idx := alpha.index(c.ascii_str()) or { return error('bad base64 character') }
		vals << idx
	}
	if pad > 2 {
		return error('bad base64 padding')
	}
	mut out := []u8{}
	mut i := 0
	for i < vals.len {
		lp := if i + 4 == vals.len { pad } else { 0 }
		n := (vals[i] << 18) | (vals[i + 1] << 12) | (vals[i + 2] << 6) | vals[i + 3]
		out << u8((n >> 16) & 0xff)
		if lp < 2 {
			out << u8((n >> 8) & 0xff)
		}
		if lp < 1 {
			out << u8(n & 0xff)
		}
		i += 4
	}
	return out
}

fn unpack(data []u8, name string, now time.Time, now_ms i64) !string {
	mut payload := data.clone()
	if data.bytestr().starts_with('{"_rails":{"message":') {
		outer := jparse(data.bytestr()) or { return err_invalid() }
		meta := outer.get('_rails')
		if meta.kind != 6 {
			return err_invalid()
		}
		msg := meta.get('message')
		if msg.kind != 4 {
			return err_invalid()
		}
		pur := meta.get('pur')
		if pur.kind == 4 && pur.str != '' && pur.str != 'cookie.' + name {
			return err_invalid()
		}
		exp := meta.get('exp')
		if exp.kind == 4 {
			expiry := parse_exp(exp.str) or { return err_invalid() }
			if now_ms >= expiry {
				return err_invalid()
			}
		} else if exp.kind != 0 {
			return err_invalid()
		}
		payload = decode64(msg.str) or { return err_invalid() }
	}
	// Pre-metadata JSON cookies are accepted; Marshal is deliberately never decoded.
	jparse(payload.bytestr()) or { return err_invalid() }
	return payload.bytestr()
}

// now_ms renders a time as milliseconds since the epoch for expiry comparison.
pub fn now_ms(t time.Time) i64 {
	return t.unix() * 1000 + i64(t.nanosecond / 1000000)
}

fn pad_n(n int, width int) string {
	mut s := n.str()
	for s.len < width {
		s = '0' + s
	}
	return s
}

fn format_exp(t time.Time) string {
	u := t
	ms := u.nanosecond / 1000000
	return pad_n(u.year, 4) + '-' + pad_n(u.month, 2) + '-' + pad_n(u.day, 2) + 'T' +
		pad_n(u.hour, 2) + ':' + pad_n(u.minute, 2) + ':' + pad_n(u.second, 2) + '.' + pad_n(ms, 3) + 'Z'
}

fn parse_exp(s string) !i64 {
	// Accepts RFC3339Nano timestamps like 2006-01-02T15:04:05.000Z.
	mut rest := s
	if rest.ends_with('Z') {
		rest = rest[..rest.len - 1]
	}
	date_time := rest.split('T')
	if date_time.len != 2 {
		return error('bad timestamp')
	}
	d := date_time[0].split('-')
	t := date_time[1].split(':')
	if d.len != 3 || t.len != 3 {
		return error('bad timestamp')
	}
	sec_frac := t[2].split('.')
	sec := sec_frac[0].int()
	mut ms := 0
	if sec_frac.len > 1 {
		mut frac := sec_frac[1]
		// Drop any trailing timezone offset; Rails always emits Z.
		for i, c in frac.bytes() {
			if c == `+` || c == `-` {
				frac = frac[..i]
				break
			}
		}
		for frac.len < 3 {
			frac += '0'
		}
		ms = frac[..3].int()
	}
	dt := time.Time{
		year:   d[0].int()
		month:  d[1].int()
		day:    d[2].int()
		hour:   t[0].int()
		minute: t[1].int()
		second: sec
	}
	return dt.unix() * 1000 + i64(ms)
}

pub fn (s &Secrets) sign_cookie(name string, inner_json string, expires time.Time) !string {
	data := envelope(inner_json, name, expires)
	payload := b64_std(data.bytes())
	mac := hmac.new(s.signing, payload.bytes(), sha1.sum, 64)
	return payload + '--' + hex.encode(mac)
}

pub fn (s &Secrets) verify_cookie(name string, raw string, now time.Time) !string {
	i := raw.len - 42
	if i <= 0 || raw[i..i + 2] != '--' {
		return err_invalid()
	}
	payload := raw[..i]
	signature := raw[i + 2..]
	mac := hmac.new(s.signing, payload.bytes(), sha1.sum, 64)
	if signature != hex.encode(mac) {
		return err_invalid()
	}
	data := decode64(payload) or { return err_invalid() }
	return unpack(data, name, now, now_ms(now))
}

pub fn (s &Secrets) encrypt_cookie(name string, inner_json string, expires time.Time) !string {
	data := envelope(inner_json, name, expires)
	nonce := rand.bytes(12)!
	sealed := s.aead.encrypt(data.bytes(), nonce, []u8{})!
	split := sealed.len - s.aead.overhead()
	return b64_std(sealed[..split]) + '--' + b64_std(nonce) + '--' + b64_std(sealed[split..])
}

pub fn (s &Secrets) decrypt_cookie(name string, raw string, now time.Time) !string {
	parts := raw.split('--')
	if parts.len != 3 {
		return err_invalid()
	}
	ciphertext := b64_std_decode(parts[0]) or { return err_invalid() }
	nonce := b64_std_decode(parts[1]) or { return err_invalid() }
	tag := b64_std_decode(parts[2]) or { return err_invalid() }
	if nonce.len != s.aead.nonce_size() || tag.len != s.aead.overhead() {
		return err_invalid()
	}
	mut combined := ciphertext.clone()
	combined << tag
	data := s.aead.decrypt(combined, nonce, []u8{}) or { return err_invalid() }
	return unpack(data, name, now, now_ms(now))
}

fn hex_val(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return -1
}

pub fn escape_cookie(s string) string {
	// Rack allows '*' and escapes '~', unlike Go's QueryEscape.
	mut out := []u8{cap: s.len}
	hex_digits := '0123456789ABCDEF'
	for c in s.bytes() {
		if (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) || c == `-` || c == `_` || c == `.` || c == `*` {
			out << c
		} else if c == ` ` {
			out << `+`
		} else if c == `~` {
			out << `%`
			out << `7`
			out << `E`
		} else {
			out << `%`
			out << hex_digits[int(c) >> 4]
			out << hex_digits[int(c) & 15]
		}
	}
	return out.bytestr()
}

pub fn unescape_cookie(s string) string {
	mut out := []u8{cap: s.len}
	bs := s.bytes()
	mut i := 0
	for i < bs.len {
		c := bs[i]
		if c == `+` {
			out << ` `
			i++
		} else if c == `%` {
			if i + 2 >= bs.len {
				return s
			}
			hi := hex_val(bs[i + 1])
			lo := hex_val(bs[i + 2])
			if hi < 0 || lo < 0 {
				return s
			}
			out << u8(hi * 16 + lo)
			i += 3
		} else {
			out << c
			i++
		}
	}
	return out.bytestr()
}
