module integrations

import net.urllib

pub const max_webhook_reply = 100 << 20

// WebhookReply is the bot-reply outcome as a sum type: a bare status, a
// text reply, or a file attachment. Go models these as nil-able fields on
// one struct; here every outcome is an explicit variant, so matching on a
// reply is exhaustive and the timeout text can never ride along with an
// attachment by accident.
pub type WebhookReply = BareReply | TextReply | AttachmentReply

pub struct BareReply {
pub:
	status int
}

pub struct TextReply {
pub:
	status int
	text   string
}

pub struct AttachmentReply {
pub:
	status       int
	filename     string
	content_type string
	data         []u8
}

pub struct WebhookClient {
pub mut:
	client HttpClient
}

pub fn new_webhook_client() WebhookClient {
	return WebhookClient{
		client: HttpClient{
			guarded:    false
			timeout_ms: 7000
		}
	}
}

pub fn (c WebhookClient) deliver(endpoint string, payload []u8) !WebhookReply {
	reply := c.deliver_inner(endpoint, payload) or {
		msg := err.msg().to_lower()
		if msg.contains('timeout') || msg.contains('timed out') || msg.contains('deadline') {
			return TextReply{
				status: 0
				text:   'Failed to respond within 7 seconds'
			}
		}
		return err
	}
	return reply
}

fn (c WebhookClient) deliver_inner(endpoint string, payload []u8) !WebhookReply {
	parse_webhook_url(endpoint)!
	mut cache := map[string]IpAddr{}
	response := c.client.do('POST', endpoint, {
		'Content-Type': 'application/json'
		'Accept':       '*/*'
		'User-Agent':   'Ruby'
	}, payload, max_webhook_reply + 1, mut cache)!
	if response.body.len > max_webhook_reply {
		return error('webhook reply exceeds 100 MB')
	}
	// An absent Content-Type ends the reply; a present-but-invalid one is an
	// error, like Go's Header map presence check.
	if 'content-type' !in response.headers {
		return BareReply{
			status: response.status
		}
	}
	ct := response.headers['content-type']
	content_type := response_media_type(ct)
	if response.status == 200 && (content_type == 'text/plain' || content_type == 'text/html') {
		return TextReply{
			status: response.status
			text:   to_valid_utf8(response.body.bytestr())
		}
	}
	symbol, registered := webhook_mime(content_type)!
	return AttachmentReply{
		status:       response.status
		filename:     'attachment.' + symbol
		content_type: registered
		data:         response.body.clone()
	}
}

fn parse_webhook_url(endpoint string) !string {
	u := urllib.parse(endpoint) or { return error('invalid webhook URL') }
	if u.hostname() == '' || (u.scheme != 'http' && u.scheme != 'https') {
		return error('invalid webhook URL')
	}
	return endpoint
}

fn response_media_type(header string) string {
	first := header.split(';')[0]
	parts := first.split('/')
	strip := fn (s string) string {
		return s.trim(' \t\n\x0b\x0c\r\x00')
	}
	main := strip(parts[0])
	if parts.len > 1 {
		return main + '/' + strip(parts[1])
	}
	return main
}

fn is_webhook_mime_name(s string) bool {
	if s.len == 0 || s.len > 127 {
		return false
	}
	first := s[0]
	if !((first >= `a` && first <= `z`) || (first >= `A` && first <= `Z`)
		|| (first >= `0` && first <= `9`)) {
		return false
	}
	for c in s.bytes() {
		ok := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
			|| (c >= `0` && c <= `9`) || c == `!` || c == `#` || c == `$` || c == `&`
			|| c == `-` || c == `^` || c == `_` || c == `.` || c == `+`
		if !ok {
			return false
		}
	}
	return true
}

fn webhook_mime(value string) !(string, string) {
	if reg := webhook_types[value] {
		return reg[0], reg[1]
	}
	v := value.split(';')[0].trim_right(' \t\n\x0b\x0c\r\x00')
	if reg := webhook_types[v] {
		return reg[0], reg[1]
	}
	if v == '*/*' {
		return '', value
	}
	parts := v.split('/')
	if parts.len != 2 || !is_webhook_mime_name(parts[0])
		|| (parts[1] != '*' && !is_webhook_mime_name(parts[1])) {
		return error('invalid webhook response MIME type')
	}
	return '', value
}

fn to_valid_utf8(s string) string {
	// Replace invalid UTF-8 sequences with U+FFFD like Go's ToValidUTF8.
	mut out := []u8{cap: s.len}
	bs := s.bytes()
	mut i := 0
	for i < bs.len {
		c := bs[i]
		if c < 0x80 {
			out << c
			i++
		} else if c >= 0xc2 && c < 0xe0 && i + 1 < bs.len && bs[i + 1] & 0xc0 == 0x80 {
			out << c
			out << bs[i + 1]
			i += 2
		} else if c >= 0xe0 && c < 0xf0 && i + 2 < bs.len && bs[i + 1] & 0xc0 == 0x80
			&& bs[i + 2] & 0xc0 == 0x80 {
			out << c
			out << bs[i + 1]
			out << bs[i + 2]
			i += 3
		} else if c >= 0xf0 && c < 0xf5 && i + 3 < bs.len && bs[i + 1] & 0xc0 == 0x80
			&& bs[i + 2] & 0xc0 == 0x80 && bs[i + 3] & 0xc0 == 0x80 {
			out << c
			out << bs[i + 1]
			out << bs[i + 2]
			out << bs[i + 3]
			i += 4
		} else {
			out << [u8(0xef), 0xbf, 0xbd]
			i++
		}
	}
	return out.bytestr()
}
