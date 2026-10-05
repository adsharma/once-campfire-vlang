module rails

import crypto.hmac
import crypto.sha256
import encoding.base64
import encoding.hex

// sign_stream matches Turbo::StreamsChannel.signed_stream_name: JSON, SHA256, no purpose.
pub fn (s &Secrets) sign_stream(name string) string {
	payload := base64.encode(jquote(name, false).bytes())
	mac := hmac.new(s.streams, payload.bytes(), sha256.sum, 64)
	return payload + '--' + hex.encode(mac)
}

pub fn (s &Secrets) verify_stream(signed string) !string {
	i := signed.len - 66
	if i <= 0 || signed[i..i + 2] != '--' {
		return err_invalid()
	}
	mac := hmac.new(s.streams, signed[..i].bytes(), sha256.sum, 64)
	if signed[i + 2..] != hex.encode(mac) {
		return err_invalid()
	}
	data := decode64(signed[..i]) or { return err_invalid() }
	value := jparse(data.bytestr()) or { return err_invalid() }
	if value.kind == 4 {
		return value.str
	}
	if value.kind == 3 {
		return value.num
	}
	return err_invalid()
}

pub fn room_stream(kind string, id i64) string {
	return base64.url_encode('gid://campfire/${kind}/${id}'.bytes()) + ':messages'
}

pub fn stream_room(name string) !(string, i64) {
	idx := name.index(':') or { return err_invalid() }
	gid := name[..idx]
	suffix := name[idx + 1..]
	if suffix != 'messages' {
		return err_invalid()
	}
	decoded := decode64(gid) or { return err_invalid() }
	parts := decoded.bytestr().split('/')
	if parts.len != 5 || parts[0] != 'gid:' || parts[1] != '' || parts[2] != 'campfire' {
		return err_invalid()
	}
	match parts[3] {
		'Room', 'Rooms::Open', 'Rooms::Closed', 'Rooms::Direct' {}
		else {
			return err_invalid()
		}
	}
	id := parts[4].i64()
	// Reject non-canonical integers the way ParseInt does.
	if id <= 0 || parts[4] != id.str() {
		return err_invalid()
	}
	return parts[3], id
}

pub fn user_rooms_stream(id i64) string {
	return base64.url_encode('gid://campfire/User/${id}'.bytes()) + ':rooms'
}
