module integrations

import html
import net.urllib
import richtext

pub struct Unfurler {
pub mut:
	client HttpClient
}

pub fn new_unfurler() Unfurler {
	return Unfurler{client: HttpClient{guarded: true, timeout_ms: 5000}}
}

struct FetchResult {
	body         []u8
	content_type string
}

// resolve_cached resolves through the SSRF guard once per hostname per
// unfurl, pinning the answer. This stops a validation lookup from consuming
// a fresh answer ahead of the fetch (the DNS-rebinding oracle), while every
// distinct hop target is still resolved through the guard.
fn resolve_cached(host string, mut cache map[string]IpAddr, mut resolver Resolver) !IpAddr {
	if ip := cache[host] {
		return ip
	}
	ip := resolve_public(host, mut resolver)!
	cache[host] = ip
	return ip
}

fn (u Unfurler) fetch(method string, location string, mut cache map[string]IpAddr) !FetchResult {
	mut loc := location
	for _ in 0 .. 10 {
		// Like request construction in Go (and URI.parse in Ruby), URLs with
		// spaces or non-ASCII bytes fail before any DNS lookup happens.
		for c in loc.runes() {
			if u32(c) > 127 || u32(c) <= 32 {
				return error('private or invalid network address')
			}
		}
		parsed := urllib.parse(loc) or { return error('private or invalid network address') }
		if parsed.hostname() == '' {
			return error('private or invalid network address')
		}
		if parsed.scheme != 'http' && parsed.scheme != 'https' {
			return error('private or invalid network address')
		}
		mut rr := u.client.resolver_or_default()
		resolve_cached(parsed.hostname(), mut cache, mut rr) or {
			return error('private or invalid network address')
		}
		response := u.client.do(method, loc, {'Accept': '*/*', 'User-Agent': 'Ruby'}, [], (5 << 20) + 1, mut cache)!
		if response.status >= 300 && response.status < 400 {
			loc = response.headers['location']
			continue
		}
		content_type := response.headers['content-type']
		if method == 'HEAD' {
			return FetchResult{[], content_type}
		}
		media := content_type.split(';')[0].trim_space()
		if response.status != 200 || media != 'text/html' {
			return FetchResult{[], ''}
		}
		if response.body.len > 5 << 20 {
			return FetchResult{[], ''}
		}
		return FetchResult{response.body.clone(), content_type}
	}
	return error('too many Open Graph redirects')
}

// media_url matches downloadable/media links that skip fetching.
// Like Go's mediaURL regex, matching is case sensitive throughout.
fn media_url(s string) bool {
	mut i := 0
	for i < s.len {
		proto := if s[i..].starts_with('https://') { 8 } else if s[i..].starts_with('http://') { 7 } else { 0 }
		if proto == 0 {
			i++
			continue
		}
		mut j := i + proto
		for j < s.len {
			c := s[j]
			if c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == 0x0b || c == 0x0c {
				break
			}
			j++
		}
		token := s[i..j]
		// Like Go's regex, any dot in the token can start the extension.
		for di in 0 .. token.len {
			if token[di] != `.` {
				continue
			}
			ext := token[di + 1..]
			for _, candidate in ['zip', 'tar', 'tar.gz', 'tar.bz2', 'tar.xz', 'gz', 'bz2', 'rar', '7z', 'dmg', 'exe', 'msi', 'pkg', 'deb', 'iso', 'jpg', 'jpeg', 'png', 'gif', 'bmp', 'mp4', 'mov', 'avi', 'mkv', 'wmv', 'flv', 'heic', 'heif', 'mp3', 'wav', 'ogg', 'aac', 'wma', 'webm', 'ogv', 'mpg', 'mpeg'] {
				if ext == candidate || ext.starts_with(candidate) {
					// Word boundary: Go requires \b after the extension.
					rest := ext[candidate.len..]
					if rest == '' || !(rest[0] == `_` || (rest[0] >= `a` && rest[0] <= `z`) || (rest[0] >= `A` && rest[0] <= `Z`) || (rest[0] >= `0` && rest[0] <= `9`)) {
						return true
					}
				}
			}
		}
		i = j
	}
	return false
}

fn open_graph_attributes(body []u8) map[string]string {
	// Decode like Go (lone bytes become the same codepoint), cut at NUL.
	mut text := og_loose_decode(body)
	if idx := text.index('\x00') {
		if idx >= 0 {
			text = text[..idx]
		}
	}
	mut nodes := []map[string]string{}
	mut z := html.new_tokenizer(text)
	for {
		tok := z.next()
		if tok.typ == .error_token {
			break
		}
		if tok.typ != .start_tag_token && tok.typ != .self_closing_tag_token {
			continue
		}
		if tok.data != 'meta' {
			continue
		}
		mut attrs := map[string]string{}
		for a in tok.attrs {
			attrs[a.key] = a.val
		}
		nodes << attrs
	}
	mut metas := []map[string]string{}
	for m in nodes {
		metas << m
	}
	mut has_charset := false
	for m in metas {
		if m['charset'].trim_space() != '' {
			has_charset = true
		}
		if m['http-equiv'].to_lower() == 'content-type' && m['content'].to_lower().contains('charset=') {
			has_charset = true
		}
	}
	mut found := map[string]string{}
	for m in metas {
		prop := m['property']
		nm := m['name']
		if !prop.starts_with('og:') && !nm.starts_with('og:') {
			continue
		}
		mut key := nm
		if 'property' in m {
			key = prop
		}
		key = key.replace('og:', '')
		if key != 'title' && key != 'url' && key != 'image' && key != 'description' {
			continue
		}
		mut content := m['content']
		if og_is_blank(content) {
			continue
		}
		if !has_charset {
			content = strip_non_ascii(content)
		}
		found[key] = content
	}
	return found
}

// og_loose_decode mirrors Go's DecodeRune loop with a latin-1 fallback:
// well-formed UTF-8 sequences pass through, otherwise each byte becomes
// the Unicode codepoint of the same value.
fn og_loose_decode(body []u8) string {
	mut out := []u8{cap: body.len}
	mut i := 0
	for i < body.len {
		c := body[i]
		if c < 0x80 {
			out << c
			i++
		} else if c >= 0xc2 && c < 0xe0 && i + 1 < body.len && body[i + 1] & 0xc0 == 0x80 {
			out << c
			out << body[i + 1]
			i += 2
		} else if c >= 0xe0 && c < 0xf0 && i + 2 < body.len && body[i + 1] & 0xc0 == 0x80 && body[i + 2] & 0xc0 == 0x80 {
			out << c
			out << body[i + 1]
			out << body[i + 2]
			i += 3
		} else if c >= 0xf0 && c < 0xf5 && i + 3 < body.len && body[i + 1] & 0xc0 == 0x80 && body[i + 2] & 0xc0 == 0x80 && body[i + 3] & 0xc0 == 0x80 {
			out << c
			out << body[i + 1]
			out << body[i + 2]
			out << body[i + 3]
			i += 4
		} else {
			// Latin-1 fallback: encode U+0080..U+00FF as two bytes.
			out << u8(0xc0 | (c >> 6))
			out << u8(0x80 | (c & 0x3f))
			i++
		}
	}
	return out.bytestr()
}

// og_is_blank mirrors Go's strings.TrimSpace blank check over Unicode
// White Space: tab..cr, space, NEL, NBSP, Ogham space, en/em and other
// Unicode spaces, line/paragraph separators, narrow NBSP, medium space and
// the ideographic space.
fn og_is_blank(s string) bool {
	mut i := 0
	bs := s.bytes()
	for i < bs.len {
		c := bs[i]
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == 0x0b || c == 0x0c {
			i++
			continue
		}
		if c < 0x80 {
			return false
		}
		// Decode one rune.
		mut r := u32(0xfffd)
		mut n := 1
		if c >= 0xc2 && c < 0xe0 && i + 1 < bs.len && bs[i + 1] & 0xc0 == 0x80 {
			r = (u32(c & 0x1f) << 6) | u32(bs[i + 1] & 0x3f)
			n = 2
		} else if c >= 0xe0 && c < 0xf0 && i + 2 < bs.len && bs[i + 1] & 0xc0 == 0x80 && bs[i + 2] & 0xc0 == 0x80 {
			r = (u32(c & 0x0f) << 12) | (u32(bs[i + 1] & 0x3f) << 6) | u32(bs[i + 2] & 0x3f)
			n = 3
		} else if c >= 0xf0 && c < 0xf5 && i + 3 < bs.len && bs[i + 1] & 0xc0 == 0x80 && bs[i + 2] & 0xc0 == 0x80 && bs[i + 3] & 0xc0 == 0x80 {
			r = (u32(c & 0x07) << 18) | (u32(bs[i + 1] & 0x3f) << 12) | (u32(bs[i + 2] & 0x3f) << 6) | u32(bs[i + 3] & 0x3f)
			n = 4
		}
		if r == 0x85 || r == 0xa0 || r == 0x1680 || (r >= 0x2000 && r <= 0x200a) || r == 0x2028 || r == 0x2029 || r == 0x202f || r == 0x205f || r == 0x3000 {
			i += n
			continue
		}
		return false
	}
	return true
}

fn strip_non_ascii(s string) string {
	mut out := []u8{cap: s.len}
	for c in s.bytes() {
		if c <= 127 {
			out << c
		}
	}
	return out.bytestr()
}

// UnfurlBody is the unfurl outcome as a sum type: either there is nothing
// worth previewing, or there is a JSON preview document. Errors (bad mailto,
// dead tweet embeds) still travel in the Result channel.
pub type UnfurlBody = NoPreview | Preview

pub struct NoPreview {}

pub struct Preview {
pub:
	json []u8
}

pub fn (u Unfurler) unfurl(location string) !UnfurlBody {
	parsed := urllib.parse(location) or { return NoPreview{} }
	if parsed.scheme == 'mailto' {
		if !location[7..].contains('@') {
			return error('URI invalid component')
		}
		return NoPreview{}
	}
	for c in location.runes() {
		if u32(c) > 127 || u32(c) <= 32 {
			return NoPreview{}
		}
	}
	mut fetch_url := location
	mut tweet := false
	host := parsed.hostname().to_lower()
	if host in ['twitter.com', 'www.twitter.com', 'x.com', 'www.x.com'] {
		if parsed.path != '' && parsed.path != '/' {
			tweet = true
			scheme_end := location.index('://') or { 0 }
			prefix := location[..scheme_end + 3]
			suffix := location[prefix.len + parsed.host.len..]
			fetch_url = prefix + 'fxtwitter.com' + suffix
		}
	}
	// The reference validates the (possibly rewritten) fetch URL through the
	// guard even when the fetch itself is skipped for media URLs.
	parsed_fetch := urllib.parse(fetch_url) or { return NoPreview{} }
	if parsed_fetch.hostname() == '' {
		return NoPreview{}
	}
	mut cache := map[string]IpAddr{}
	mut rr_loc := u.client.resolver_or_default()
	resolve_cached(parsed_fetch.hostname(), mut cache, mut rr_loc) or { return NoPreview{} }
	mut body := []u8{}
	if !media_url(fetch_url) {
		fres := u.fetch('GET', fetch_url, mut cache) or { FetchResult{} }
		body = fres.body.clone()
	}
	if tweet && body.len == 0 {
		return error('missing Twitter Open Graph document')
	}
	found := open_graph_attributes(body)
	mut canonical := found['url']
	if !u.public_url(canonical, mut cache) {
		canonical = location
	}
	mut image := ?string(none)
	if !og_is_blank(found['image']) {
		value := found['image']
		hres := u.fetch('HEAD', value, mut cache) or { FetchResult{} }
		ct := hres.content_type
		match ct.to_lower() {
			'image/jpeg', 'image/png', 'image/gif', 'image/webp' {
				if u.public_url(value, mut cache) {
					image = value
				}
			}
			else {}
		}
	}
	title := richtext.strip_tags(found['title'])!
	description := richtext.strip_tags(found['description'])!
	if og_is_blank(title) || og_is_blank(description) || og_is_blank(canonical) {
		return NoPreview{}
	}
	// Preserve the reference model's attribute insertion order in render json.
	mut keys := []string{}
	for key in ['title', 'url', 'image', 'description'] {
		if key in found {
			keys << key
		}
	}
	for key in ['url', 'image', 'title', 'description'] {
		if key !in found {
			keys << key
		}
	}
	mut result := []u8{}
	result << `{`
	for i, key in keys {
		val := match key {
			'title' {
				title
			}
			'url' {
				canonical
			}
			'image' {
				image
			}
			else {
				description
			}
		}
		result << ('"' + key + '":').bytes()
		if key == 'image' {
			if img := image {
				result << json_quote_og(img).bytes()
			} else {
				result << 'null'.bytes()
			}
		} else {
			result << json_quote_og(val).bytes()
		}
		if i + 1 < keys.len {
			result << `,`
		}
	}
	result << ',"context_for_validation":{"context":null},"errors":{}}'.bytes()
	return Preview{result}
}

fn json_quote_og(s string) string {
	mut out := []u8{}
	out << `"`
	for c in s.bytes() {
		if c == `"` {
			out << `\\`
			out << `"`
		} else if c == `\\` {
			out << `\\`
			out << `\\`
		} else if c == `\n` {
			out << `\\`
			out << `n`
		} else if c < 0x20 {
			out << `\\`
			out << `u`
			out << `0`
			out << `0`
			out << '0123456789abcdef'[int(c) >> 4]
			out << '0123456789abcdef'[int(c) & 15]
		} else {
			out << c
		}
	}
	out << `"`
	return out.bytestr()
}

// public_url checks link usability through the SSRF guard.
pub fn (u Unfurler) public_url(value string, mut cache map[string]IpAddr) bool {
	parsed := urllib.parse(value) or { return false }
	if (parsed.scheme != 'http' && parsed.scheme != 'https') || parsed.hostname() == '' {
		return false
	}
	mut rr := u.client.resolver_or_default()
	resolve_cached(parsed.hostname(), mut cache, mut rr) or { return false }
	return true
}
