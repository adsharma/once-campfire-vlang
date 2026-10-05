module integrations

import net.urllib
import time

pub fn push_endpoint(value string) !string {
	for c in value.bytes() {
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == 0x0b || c == 0x0c {
			return error('invalid endpoint URL')
		}
	}
	u := urllib.parse(value) or { return error('push endpoint must use HTTPS on port 443') }
	if u.scheme != 'https' || u.hostname() == '' {
		return error('push endpoint must use HTTPS on port 443')
	}
	_, port := split_host_port(u.host, u.scheme)
	if port != 443 {
		return error('push endpoint must use HTTPS on port 443')
	}
	host := u.hostname().to_lower()
	for allowed in push_hosts {
		if host == allowed || host.ends_with('.' + allowed) {
			return value
		}
	}
	return error('endpoint is not a permitted push service')
}

pub struct PushSender {
pub mut:
	client   HttpClient
	vapid    ?Vapid
	resolver ?Resolver
}

pub fn new_push_sender(vapid ?Vapid) PushSender {
	return PushSender{
		client:   HttpClient{guarded: true, timeout_ms: 10000}
		vapid:    vapid
		resolver: SystemResolver{}
	}
}

pub fn (s PushSender) validate(endpoint string) ! {
	ep := push_endpoint(endpoint)!
	parsed := urllib.parse(ep) or { return error('invalid endpoint URL') }
	mut rr := s.resolver_or_default()
	resolve_public(parsed.hostname(), mut rr)!
}

fn (s PushSender) resolver_or_default() Resolver {
	if r := s.resolver {
		return r
	}
	return SystemResolver{}
}

pub fn (s PushSender) send(endpoint string, key string, auth string, message []u8) ! {
	v := s.vapid or { return error('Web Push is not configured') }
	ep := push_endpoint(endpoint) or { return }
	parsed := urllib.parse(ep) or { return }
	mut rr2 := s.resolver_or_default()
	resolve_public(parsed.hostname(), mut rr2) or { return }
	// Errors above are swallowed like the Go port (return nil); only
	// delivery results propagate.
	payload := encrypt_push(message, key, auth)!
	authorization := v.authorization('https://' + parsed.hostname(), time.now())!
	headers := {
		'Content-Type':     'application/octet-stream'
		'Content-Encoding': 'aes128gcm'
		'TTL':              '2419200'
		'Urgency':          'high'
		'Authorization':    authorization
		'User-Agent':       'Ruby'
		'Accept':           '*/*'
	}
	mut cache := map[string]IpAddr{}
	response := s.client.do('POST', endpoint, headers, payload, 65536, mut cache)!
	if response.status == 404 || response.status == 410 {
		return error('push subscription is no longer valid')
	}
	if response.status < 200 || response.status >= 300 {
		return error('push service returned ${response.status}')
	}
}

// truncate_push counts JSON string contents like Rust's notification truncation.
pub fn truncate_push(text string, limit int) string {
	size := fn (r u32) int {
		if r == u32(`"`) || r == u32(`\\`) || r == 10 || r == 13 || r == 9 || r == 8 || r == 12 {
			return 2
		}
		if r < 32 {
			return 6
		}
		if r < 0x80 {
			return 1
		} else if r < 0x800 {
			return 2
		} else if r < 0x10000 {
			return 3
		}
		return 4
	}
	mut total := 0
	for c in text.runes() {
		total += size(u32(c))
	}
	if total <= limit {
		return text
	}
	mut used := '…'.len
	mut byte_idx := 0
	for r in text.runes() {
		ru := u32(r)
		used += size(ru)
		if used > limit {
			return text[..byte_idx] + '…'
		}
		if ru < 0x80 {
			byte_idx += 1
		} else if ru < 0x800 {
			byte_idx += 2
		} else if ru < 0x10000 {
			byte_idx += 3
		} else {
			byte_idx += 4
		}
	}
	return text
}
