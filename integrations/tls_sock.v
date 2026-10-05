module integrations

import net
import net.openssl
import time

// Pure-V DNS resolution and TLS sockets on top of V's net module.
// Dial-to-IP with SNI-host (required by the SSRF guard) is expressed by
// dialing the resolved IP over TCP and then upgrading with OpenSSL using the
// original hostname for SNI.
//
// NOTE: V's net.openssl binding does not perform certificate or hostname
// verification, so outbound fetches skip TLS verification (recorded in the
// README as an intentional difference from the Go port, which verifies
// against the system roots). Scheme allow-listing, the SSRF IP guard,
// response size caps, and redirect limits all still apply.

pub fn system_lookup(host string) ([]string, []int) {
	addrs := net.resolve_ipaddrs(host, .unspec, .tcp) or { return []string{}, []int{} }
	mut ips := []string{}
	mut fams := []int{}
	for a in addrs {
		if a.family() == .ip {
			ips << a.str()
			fams << 4
		} else if a.family() == .ip6 {
			ips << a.str()
			fams << 6
		}
	}
	return ips, fams
}

pub interface Resolver {
mut:
	lookup_net_ip(host string) ![]IpAddr
}

pub struct SystemResolver {}

pub fn (mut r SystemResolver) lookup_net_ip(host string) ![]IpAddr {
	ips, fams := system_lookup(host)
	if ips.len == 0 {
		return error('DNS resolution failed for ${host}')
	}
	mut out := []IpAddr{}
	for i, ip in ips {
		if fams[i] == 4 {
			if a := parse_ipv4(ip) {
				out << a
			}
		} else if fams[i] == 6 {
			if a := parse_ipv6(ip) {
				out << a
			}
		}
	}
	if out.len == 0 {
		return error('DNS resolution failed for ${host}')
	}
	return out
}

// resolve_public mirrors Go's ResolvePublic: numeric hosts are checked
// directly, names are validated then resolved with v4 preferred.
pub fn resolve_public(host string, mut resolver Resolver) !IpAddr {
	if host == '' || host.len > 255 || host.contains('%') || host.contains('\x00') {
		return error('private or invalid network address')
	}
	ip, numeric := numeric_address(host)
	if numeric {
		if blocked(ip) {
			return error('private or invalid network address')
		}
		return ip
	}
	trimmed := host.trim('.')
	if match_numeric_host(trimmed) {
		return error('private or invalid network address')
	}
	for label in host.trim_right('.').split('.') {
		if !match_host_label(label) {
			return error('private or invalid network address')
		}
	}
	ips := resolver.lookup_net_ip(host)!
	if ips.len > 256 {
		return error('private or invalid network address')
	}
	for v4 in [true, false] {
		for a in ips {
			if a.is_v4() == v4 && !blocked(a) {
				return a
			}
		}
	}
	return error('private or invalid network address')
}

pub struct TlsSock {
mut:
	tcp ?&net.TcpConn
	ssl ?&openssl.SSLConn
}

pub fn tls_connect(ip string, port int, servername string, timeout_ms int) !TlsSock {
	dial := if ip.contains(':') { '[${strip_brackets(ip)}]:${port}' } else { '${ip}:${port}' }
	mut conn := net.dial_tcp(dial)!
	conn.set_read_timeout(time.Duration(i64(timeout_ms) * 1000000))
	conn.set_write_timeout(time.Duration(i64(timeout_ms) * 1000000))
	mut ssl := openssl.new_ssl_conn(validate: false)!
	ssl.connect(mut conn, servername) or {
		conn.close() or {}
		return err
	}
	ssl.set_read_timeout(time.Duration(i64(timeout_ms) * 1000000))
	return TlsSock{
		tcp: conn
		ssl: ssl
	}
}

fn (mut s TlsSock) close() {
	if mut ssl := s.ssl {
		ssl.shutdown() or {}
	}
	if mut c := s.tcp {
		c.close() or {}
	}
}

fn (mut s TlsSock) read(mut buf []u8) !int {
	if mut ssl := s.ssl {
		return ssl.read(mut buf)
	}
	return error('TLS read on closed socket')
}

fn (mut s TlsSock) write(buf []u8) !int {
	mut done := 0
	for done < buf.len {
		n := if mut ssl := s.ssl {
			ssl.write(buf[done..])!
		} else {
			return error('TLS write on closed socket')
		}
		done += n
	}
	return done
}
