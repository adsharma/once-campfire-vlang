module integrations

import compress.gzip
import compress.zlib
import io
import net
import net.urllib
import time

pub struct HttpResponse {
pub mut:
	status  int
	headers map[string]string
	body    []u8
}

// TransportHook replaces the socket layer in tests, mirroring Go's scripted
// http.RoundTripper oracles. It returns raw HTTP/1.x response bytes, which
// flow through the real status/header/framing parser below.
pub type TransportHook = fn (method string, url string, headers map[string]string, body []u8) ![]u8

pub struct HttpClient {
pub mut:
	guarded    bool
	timeout_ms int
	resolver   ?Resolver
	transport ?TransportHook
}

pub fn (c HttpClient) resolver_or_default() Resolver {
	if r := c.resolver {
		return r
	}
	return SystemResolver{}
}

struct ParsedTarget {
	scheme      string
	host        string
	host_header string
	port        int
	path        string
	dial_ip     string
	use_tls     bool
}

fn split_host_port(hostport string, scheme string) (string, int) {
	mut host := hostport
	mut port := if scheme == 'https' { 443 } else { 80 }
	if host.starts_with('[') {
		end := host.index(']') or { -1 }
		if end >= 0 {
			rest := host[end + 1..]
			host = host[..end + 1]
			if rest.starts_with(':') {
				port = rest[1..].int()
			}
			return host, port
		}
		return host, port
	}
	if host.count(':') == 1 {
		cut := host.index(':') or { -1 }
		port = host[cut + 1..].int()
		if port == 0 {
			port = if scheme == 'https' { 443 } else { 80 }
		}
		host = host[..cut]
	}
	return host, port
}

fn parse_target(rawurl string, mut resolver Resolver, guarded bool, mut cache map[string]IpAddr) !ParsedTarget {
	u := urllib.parse(rawurl) or { return error('invalid URL') }
	if (u.scheme != 'http' && u.scheme != 'https') || u.hostname() == '' {
		return error('invalid URL')
	}
	host, port := split_host_port(u.host, u.scheme)
	mut path := u.path
	if path == '' {
		path = '/'
	}
	if u.raw_query != '' {
		path += '?' + u.raw_query
	}
	mut dial_ip := host
	if guarded {
		ip := resolve_cached(host, mut cache, mut resolver)!
		if ip.is_v6 {
			mut v6parts := []string{}
			for i := 0; i < 16; i += 2 {
				v6parts << hex16(int(ip.b[i]) * 256 + int(ip.b[i + 1]))
			}
			dial_ip = v6parts.join(':')
		} else {
			dial_ip = ip.str()
		}
	} else if parse_ip(host.trim('[]')) == none {
		ips, _ := system_lookup(host)
		if ips.len > 0 {
			dial_ip = ips[0]
		}
	}
	return ParsedTarget{u.scheme, host, u.host, port, path, dial_ip, u.scheme == 'https'}
}

fn strip_brackets(s string) string {
	if s.starts_with('[') && s.ends_with(']') {
		return s[1..s.len - 1]
	}
	return s
}

// Sock is the transport as a sum type: either a plain TCP connection or
// a TLS upgrade of one. Matching on it is exhaustive, so no socket kind
// can fall through the cracks.
type Sock = TcpSock | TlsSock

struct TcpSock {
mut:
	conn &net.TcpConn
}

fn dial_target(t ParsedTarget, timeout_ms int) !Sock {
	if t.use_tls {
		return tls_connect(strip_brackets(t.dial_ip), t.port, t.host, timeout_ms)!
	}
	mut conn := net.dial_tcp('${t.dial_ip}:${t.port}')!
	conn.set_read_timeout(time.Duration(i64(timeout_ms) * 1000000))
	return TcpSock{conn}
}

fn (mut s Sock) close() {
	match s {
		TcpSock {
			s.conn.close() or {}
		}
		TlsSock {
			s.close()
		}
	}
}

fn (mut s Sock) write_all(data []u8) ! {
	mut done := 0
	for done < data.len {
		n := match s {
			TcpSock {
				s.conn.write(data[done..])!
			}
			TlsSock {
				s.write(data[done..])!
			}
		}
		done += n
	}
}

// read_all reads to EOF, keeping at most limit+1 bytes when limit > 0.
// A non-positive limit reads the whole body, like an uncapped ReadAll.
fn (mut s Sock) read_all(limit int) ![]u8 {
	mut out := []u8{}
	mut buf := []u8{len: 32768}
	mut total := 0
	for {
		n := match s {
			TlsSock {
				s.read(mut buf) or {
					if err is io.Eof {
						break
					}
					return err
				}
			}
			TcpSock {
				s.conn.read(mut buf) or {
					if err is io.Eof {
						break
					}
					return err
				}
			}
		}
		if n <= 0 {
			break
		}
		if limit > 0 {
			room := limit + 1 - total
			if room <= 0 {
				break
			}
			take := if n < room { n } else { room }
			out << buf[..take]
			total += take
			if total > limit {
				break
			}
		} else {
			out << buf[..n]
		}
	}
	return out
}

// with_request_defaults adds the transport headers Go and Ruby clients
// always send: the shared Accept-Encoding offer and Content-Length.
fn with_request_defaults(headers map[string]string, body []u8) map[string]string {
	mut full := headers.clone()
	mut has_encoding := false
	mut has_length := false
	for k in headers.keys() {
		lk := k.to_lower()
		if lk == 'accept-encoding' {
			has_encoding = true
		}
		if lk == 'content-length' {
			has_length = true
		}
	}
	if !has_encoding {
		full['Accept-Encoding'] = 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3'
	}
	if body.len > 0 && !has_length {
		full['Content-Length'] = body.len.str()
	}
	return full
}

// ContentCoding is the response content coding as an enum, so the
// inflation dispatch below matches exhaustively over known codings.
pub enum ContentCoding {
	identity
	gzip
	x_gzip
	deflate
}

fn content_coding_of(header_value string) ContentCoding {
	match header_value.to_lower() {
		'gzip' {
			return .gzip
		}
		'x-gzip' {
			return .x_gzip
		}
		'deflate' {
			return .deflate
		}
		else {
			return .identity
		}
	}
}

fn find_header_end(data []u8) int {
	for i in 0 .. data.len - 3 {
		if data[i] == `\r` && data[i + 1] == `\n` && data[i + 2] == `\r` && data[i + 3] == `\n` {
			return i + 4
		}
	}
	for i in 0 .. data.len - 1 {
		if data[i] == `\n` && data[i + 1] == `\n` {
			return i + 2
		}
	}
	return -1
}

fn decode_chunked(data []u8) []u8 {
	mut out := []u8{}
	mut i := 0
	for {
		mut j := i
		for j < data.len && data[j] != `\n` {
			j++
		}
		if j >= data.len {
			break
		}
		line := data[i..j].bytestr().trim_space().split(';')[0]
		size := parse_hex_int(line)
		i = j + 1
		if size <= 0 {
			break
		}
		if i + size > data.len {
			out << data[i..]
			break
		}
		out << data[i..i + size]
		i += size
		if i + 1 < data.len && data[i] == `\r` && data[i + 1] == `\n` {
			i += 2
		} else if i < data.len && data[i] == `\n` {
			i++
		}
	}
	return out
}

fn is_all_digits(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s.bytes() {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

fn parse_hex_int(s string) int {
	mut n := 0
	for c in s.bytes() {
		n <<= 4
		if c >= `0` && c <= `9` {
			n |= int(c - `0`)
		} else if c >= `a` && c <= `f` {
			n |= int(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			n |= int(c - `A`) + 10
		} else {
			return 0
		}
	}
	return n
}

// do performs one request without following redirects, like Go's
// ErrUseLastResponse client.
pub fn (c HttpClient) do(method string, rawurl string, headers map[string]string, body []u8, body_limit int, mut cache map[string]IpAddr) !HttpResponse {
	if hook := c.transport {
		u := urllib.parse(rawurl) or { return error('invalid URL') }
		if (u.scheme != 'http' && u.scheme != 'https') || u.hostname() == '' {
			return error('invalid URL')
		}
		// The hook observes the wire header set, like Go's RoundTripper.
		mut observed := with_request_defaults(headers, body)
		observed['Host'] = u.host
		observed['Connection'] = 'close'
		raw := hook(method, rawurl, observed, body)!
		return parse_response(method, raw)
	}
	mut rr := c.resolver_or_default()
	t := parse_target(rawurl, mut rr, c.guarded, mut cache)!
	mut sock := dial_target(t, c.timeout_ms)!
	defer {
		sock.close()
	}
	mut req := '${method} ${t.path} HTTP/1.1\r\nHost: ${t.host_header}\r\nConnection: close\r\n'
	full := with_request_defaults(headers, body)
	for k in full.keys() {
		req += '${k}: ${full[k]}\r\n'
	}
	req += '\r\n'
	sock.write_all(req.bytes())!
	if body.len > 0 {
		sock.write_all(body)!
	}
	raw := sock.read_all(body_limit)!
	return parse_response(method, raw)
}

fn parse_response(method string, raw []u8) !HttpResponse {
	end := find_header_end(raw)
	if end < 0 {
		return error('bad response headers')
	}
	head := raw[..end].bytestr()
	mut payload := raw[end..]
	lines := head.split('\n')
	if lines.len == 0 {
		return error('bad response status')
	}
	status_parts := lines[0].trim_space().split(' ')
	if status_parts.len < 2 {
		return error('bad response status')
	}
	status := status_parts[1].int()
	mut resp_headers := map[string]string{}
	for line in lines[1..] {
		l := line.trim_space().trim_right('\r')
		if l == '' {
			continue
		}
		cut := l.index(':') or { continue }
		k := l[..cut].trim_space().to_lower()
		v := l[cut + 1..].trim_space()
		if k in resp_headers {
			resp_headers[k] = resp_headers[k] + ', ' + v
		} else {
			resp_headers[k] = v
		}
	}
	// Body framing, in transport order like Go: de-chunk, then honor
	// Content-Length against the wire bytes, then inflate content codings.
	if method == 'HEAD' || status == 204 || status == 304 {
		return HttpResponse{status, resp_headers, []u8{}}
	}
	te := resp_headers['transfer-encoding'].to_lower()
	if te.contains('chunked') {
		payload = decode_chunked(payload)
	} else {
		clen := resp_headers['content-length']
		if clen != '' {
			want_str := clen.split(',')[0].trim_space()
			if !is_all_digits(want_str) {
				return error('bad content-length')
			}
			want := want_str.int()
			if payload.len > want {
				payload = payload[..want]
			}
		}
	}
	match content_coding_of(resp_headers['content-encoding']) {
		.gzip, .x_gzip {
			payload = gzip.decompress(payload) or { return error('gzip: ${err}') }
		}
		.deflate {
			payload = zlib.decompress(payload) or { return error('deflate: ${err}') }
		}
		.identity {}
	}
	return HttpResponse{status, resp_headers, payload}
}
