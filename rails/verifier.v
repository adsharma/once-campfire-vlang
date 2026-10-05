module rails

import crypto.hmac
import crypto.sha1
import crypto.sha256
import encoding.base64
import encoding.hex
import time

pub struct Verifier {
pub mut:
	key           []u8
	sha256        bool
	url_safe      bool
	padded        bool
	html          bool
	allow_marshal bool
}

pub fn (s &Secrets) app_verifier(name string) Verifier {
	return Verifier{
		key:           derive_key(s.secret, name, 64)
		html:          true
		allow_marshal: true
	}
}

fn (s &Secrets) id_verifier() Verifier {
	return Verifier{
		key:      s.signed_ids
		sha256:   true
		url_safe: true
	}
}

fn (s &Secrets) sgid_verifier() Verifier {
	return Verifier{
		key:           s.signed_gids
		url_safe:      true
		padded:        true
		html:          true
		allow_marshal: true
	}
}

fn (v Verifier) mac(data string) string {
	if v.sha256 {
		return hex.encode(hmac.new(v.key, data.bytes(), sha256.sum, 64))
	}
	return hex.encode(hmac.new(v.key, data.bytes(), sha1.sum, 64))
}

pub fn (v Verifier) generate_raw(raw []u8, purpose string, expires time.Time) !string {
	data := canonical_json(raw, v.html)!
	mut payload_bytes := data.clone()
	if purpose != '' || !expires.is_zero() {
		mut out := '{"_rails":{"data":' + data.bytestr()
		if !expires.is_zero() {
			out += ',"exp":' + jquote(format_exp(expires), v.html)
		}
		if purpose != '' {
			out += ',"pur":' + jquote(purpose, v.html)
		}
		out += '}}'
		payload_bytes = out.bytes()
	}
	mut payload := base64.encode(payload_bytes)
	if v.url_safe {
		payload = base64.url_encode(payload_bytes)
		for payload.ends_with('=') {
			payload = payload[..payload.len - 1]
		}
		if v.padded {
			for payload.len % 4 != 0 {
				payload += '='
			}
		}
	}
	return payload + '--' + v.mac(payload)
}

pub fn (v Verifier) verify_raw(message string, purpose string, now time.Time) !string {
	length := if v.sha256 { 64 } else { 40 }
	i := message.len - length - 2
	if i <= 0 || message[i..i + 2] != '--' {
		return err_invalid()
	}
	if v.mac(message[..i]) != message[i + 2..] {
		return err_invalid()
	}
	data := decode64(message[..i]) or { return err_invalid() }
	return v.decode(data, purpose, now_ms(now))
}

fn (v Verifier) decode(data []u8, purpose string, now_ms i64) !string {
	if data.len > 1 && data[0] == 4 && data[1] == 8 {
		if !v.allow_marshal {
			return err_invalid()
		}
		s, ok := marshal_string(data)
		if !ok {
			return err_invalid()
		}
		return jquote(s, v.html)
	}
	outer := jparse(data.bytestr()) or { return err_purpose(purpose) }
	if outer.kind == 6 {
		rails_meta := outer.get('_rails')
		if rails_meta.kind == 6 {
			meta_data := rails_meta.get('data')
			meta_msg := rails_meta.get('message')
			meta_exp := rails_meta.get('exp')
			meta_pur := rails_meta.get('pur')
			if meta_exp.kind == 4 {
				expiry := parse_exp(meta_exp.str) or { return err_invalid() }
				if now_ms >= expiry {
					return err_expired()
				}
			} else if meta_exp.kind != 0 {
				return err_invalid()
			}
			mut actual := ''
			if meta_pur.kind == 4 {
				actual = meta_pur.str
			} else if meta_pur.kind == 3 {
				actual = meta_pur.num
			} else if meta_pur.kind != 0 {
				actual = meta_pur.canonical(v.html)
			}
			if actual != purpose {
				return err_purpose(purpose)
			}
			if meta_msg.kind == 4 {
				decoded := decode64(meta_msg.str) or { return err_invalid() }
				return v.decode(decoded, '', now_ms)
			}
			if meta_data.kind == 0 && !has_key(rails_meta, 'data') {
				return 'null'
			}
			if meta_data.kind == 0 {
				return 'null'
			}
			return meta_data.canonical(v.html)
		}
	}
	if purpose != '' {
		return err_purpose(purpose)
	}
	return outer.canonical(v.html)
}

fn has_key(v JVal, key string) bool {
	if v.kind == 6 {
		for p in v.obj {
			if p.k == key {
				return true
			}
		}
	}
	return false
}

fn err_purpose(purpose string) RailsError {
	return RailsError{RailsErrKind.purpose}
}

fn err_expired() RailsError {
	return RailsError{RailsErrKind.expired}
}

fn marshal_string(data []u8) (string, bool) {
	if data.len < 4 || data[0] != 4 || data[1] != 8 {
		return '', false
	}
	mut rest := data[2..]
	if rest[0] == `I` {
		rest = rest[1..]
	}
	if rest.len < 2 || rest[0] != `"` {
		return '', false
	}
	rest = rest[1..]
	first := int(i8(rest[0]))
	rest = rest[1..]
	mut length := 0
	if first == 0 {
	} else if first > 4 {
		length = first - 5
	} else if first > 0 {
		if rest.len < first {
			return '', false
		}
		for i in 0 .. first {
			length |= int(rest[i]) << (8 * i)
		}
		rest = rest[first..]
	} else {
		return '', false
	}
	if length < 0 || length > rest.len {
		return '', false
	}
	return rest[..length].bytestr(), true
}

fn model_purpose(model_name string, purpose string) string {
	mut m := model_name.replace('::', '/')
	m = camel_to_snake(m)
	if purpose.trim_space() != '' {
		m += '/' + purpose
	}
	return m
}

fn camel_to_snake(s string) string {
	mut out := []u8{cap: s.len + 4}
	bs := s.bytes()
	for i in 0 .. bs.len {
		c := bs[i]
		if c >= `A` && c <= `Z` {
			mut is_boundary := false
			if i > 0 {
				prev := bs[i - 1]
				if (prev >= `a` && prev <= `z`) || (prev >= `0` && prev <= `9`) {
					is_boundary = true
				} else if prev >= `A` && prev <= `Z` && i + 1 < bs.len {
					nxt := bs[i + 1]
					if nxt >= `a` && nxt <= `z` {
						is_boundary = true
					}
				}
			}
			if is_boundary {
				out << `_`
			}
			out << c + 32
		} else if c == `-` {
			out << `_`
		} else {
			out << c
		}
	}
	return out.bytestr().to_lower()
}

pub fn (s &Secrets) signed_id(model_name string, id i64, purpose string, expires time.Time) string {
	return s.id_verifier().generate_raw(id.str().bytes(), model_purpose(model_name, purpose),
		expires) or { panic(err) }
}

fn verify_id_raw(s &Secrets, v Verifier, model_name string, message string, purpose string, now time.Time) !string {
	return v.verify_raw(message, model_purpose(model_name, purpose), now) or {
		if err is RailsError {
			if err.kind != .invalid {
				return err
			}
		}
		mut fallback := v
		fallback.sha256 = false
		fallback.allow_marshal = true
		return fallback.verify_raw(message, model_purpose(model_name, purpose), now)
	}
}

pub fn (s &Secrets) verify_id(model_name string, message string, purpose string, now time.Time) !i64 {
	v := s.id_verifier()
	raw := verify_id_raw(s, v, model_name, message, purpose, now)!
	mut value := raw
	if raw.starts_with('"') {
		parsed := jparse(raw) or { return err_invalid() }
		if parsed.kind != 4 {
			return err_invalid()
		}
		value = parsed.str
	}
	id := value.trim_space().i64()
	if id == 0 && value.trim_space() != '0' {
		return err_invalid()
	}
	return id
}

pub fn (s &Secrets) sgid(gid string, purpose string, expires time.Time) string {
	return s.sgid_verifier().generate_raw(jquote(gid, true).bytes(), purpose, expires) or {
		panic(err)
	}
}

pub fn (s &Secrets) verify_sgid(message string, purpose string, now time.Time) !string {
	v := s.sgid_verifier()
	raw := v.verify_raw(message, purpose, now) or {
		// Legacy {gid,purpose,expires_at} envelope.
		legacy := v.verify_raw(message, '', now) or { return err }
		parsed := jparse(legacy) or { return err_invalid() }
		if parsed.kind != 6 {
			return err_invalid()
		}
		pur := parsed.get('purpose')
		if pur.kind != 4 || pur.str != purpose {
			return err_purpose(purpose)
		}
		exp := parsed.get('expires_at')
		if exp.kind == 4 {
			expiry := parse_exp(exp.str) or { return err_invalid() }
			if now_ms(now) >= expiry {
				return err_expired()
			}
		}
		gid := parsed.get('gid')
		if gid.kind != 4 {
			return err_invalid()
		}
		return gid.str
	}
	parsed := jparse(raw) or { return err_invalid() }
	if parsed.kind != 4 {
		return err_invalid()
	}
	return parsed.str
}

// unverified_user_gid is the deliberately User-only exception in
// rails_ext/action_text_attachables.rb.
pub fn unverified_user_gid(sgid string) !string {
	if sgid.trim('-') == '' {
		return ''
	}
	cut := sgid.index('--') or { -1 }
	payload := if cut < 0 { sgid } else { sgid[..cut] }
	raw := decode64(payload) or { return err_invalid() }
	// Go unmarshals into a struct: arrays and scalars fail, null decodes empty.
	outer := jparse(raw.bytestr()) or { return err_invalid() }
	if outer.kind != 6 && outer.kind != 0 {
		return err_invalid()
	}
	mut gid := ''
	if outer.kind == 6 {
		rails_meta := outer.get('_rails')
		if rails_meta.kind == 6 {
			data := rails_meta.get('data')
			if data.kind == 4 {
				gid = data.str
			} else if data.kind == 0 {
				msg := rails_meta.get('message')
				if msg.kind == 4 {
					decoded := decode64(msg.str) or { return err_invalid() }
					gid = extract_gid(decoded.bytestr())
				}
			}
		}
	}
	if !gid.starts_with('gid://') {
		decoded := decode64(gid) or { return err_invalid() }
		gid = decoded.bytestr()
	}
	gid = gid.split('?')[0]
	parts := gid.split('/')
	if parts.len != 5 || parts[0] != 'gid:' || parts[2] == '' || parts[3] != 'User' || parts[4] == '' {
		return ''
	}
	return 'gid://campfire/User/' + parts[4]
}

fn extract_gid(s string) string {
	idx := s.index('gid://campfire/') or { return '' }
	mut end := idx
	for end < s.len {
		c := s[end]
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `:` || c == `/` || c == `.` || c == `-` || c == `_` {
			end++
		} else {
			break
		}
	}
	return s[idx..end]
}
