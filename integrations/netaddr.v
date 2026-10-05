module integrations

// IpAddr is a parsed IP address: four bytes for v4, sixteen for v6.
pub struct IpAddr {
pub:
	is_v6 bool
	b     []u8
}

pub fn parse_ipv4(s string) ?IpAddr {
	parts := s.split('.')
	if parts.len != 4 {
		return none
	}
	mut b := []u8{cap: 4}
	for p in parts {
		if p.len == 0 || p.len > 3 {
			return none
		}
		for c in p.bytes() {
			if c < `0` || c > `9` {
				return none
			}
		}
		n := p.int()
		if n > 255 || (p.len > 1 && p[0] == `0`) {
			return none
		}
		b << u8(n)
	}
	return IpAddr{false, b}
}

fn parse_h16(s string) ?u16 {
	if s.len == 0 || s.len > 4 {
		return none
	}
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
			return none
		}
	}
	return u16(n)
}

pub fn parse_ipv6(s string) ?IpAddr {
	if s.count(':') < 2 {
		return none
	}
	// Split off embedded IPv4 tail.
	mut tail4 := []u8{}
	mut head := s
	if s.contains('.') {
		dot := s.last_index('.') or { return none }
		mut start := dot
		for start > 0 && ((s[start - 1] >= `0` && s[start - 1] <= `9`) || s[start - 1] == `.`) {
			start--
		}
		v4 := parse_ipv4(s[start..]) or { return none }
		tail4 = v4.b.clone()
		head = s[..start]
		if head.ends_with(':') {
			head = head[..head.len - 1]
			// A head of exactly "::" leaves a lone ":" separator here;
			// it denotes an all-zero v6 part before the embedded v4 tail.
			if head == ':' {
				head = ''
			}
		} else {
			return none
		}
	}
	halves := head.split('::')
	if halves.len > 2 {
		return none
	}
	mut groups := []u16{}
	if head == '' {
		// All-zero v6 part (e.g. the "::" in "::8.8.8.8").
		need := 8 - (if tail4.len > 0 { 2 } else { 0 })
		for _ in 0 .. need {
			groups << u16(0)
		}
	} else if halves.len == 2 {
		mut left := []u16{}
		if halves[0] != '' {
			for g in halves[0].split(':') {
				left << parse_h16(g) or { return none }
			}
		}
		mut right := []u16{}
		if halves[1] != '' {
			for g in halves[1].split(':') {
				right << parse_h16(g) or { return none }
			}
		}
		need := 8 - left.len - right.len - (if tail4.len > 0 { 2 } else { 0 })
		if need < 0 {
			return none
		}
		groups << left
		for _ in 0 .. need {
			groups << u16(0)
		}
		groups << right
	} else {
		for g in head.split(':') {
			groups << parse_h16(g) or { return none }
		}
	}
	want := if tail4.len > 0 { 6 } else { 8 }
	if groups.len != want {
		return none
	}
	mut b := []u8{cap: 16}
	for g in groups {
		b << u8(g >> 8)
		b << u8(g & 0xff)
	}
	b << tail4
	return IpAddr{true, b}
}

pub fn parse_ip(s string) ?IpAddr {
	t := s.trim('[]')
	if a := parse_ipv4(t) {
		return a
	}
	return parse_ipv6(t)
}

pub fn (a IpAddr) is_v4() bool {
	return !a.is_v6
}

pub fn (a IpAddr) str() string {
	if !a.is_v6 {
		return '${a.b[0]}.${a.b[1]}.${a.b[2]}.${a.b[3]}'
	}
	// Compressed rendering is unnecessary; callers use this for dialing only
	// when the textual form round-trips, otherwise they use the original host.
	mut parts := []string{}
	for i := 0; i < 16; i += 2 {
		parts << hex16(int(a.b[i]) * 256 + int(a.b[i + 1]))
	}
	return '[' + parts.join(':') + ']'
}

fn hex16(v int) string {
	digits := '0123456789abcdef'
	mut out := []u8{}
	mut n := v
	mut started := false
	for shift in [12, 8, 4, 0] {
		d := (n >> shift) & 15
		if d != 0 || started || shift == 0 {
			out << digits[d]
			started = true
		}
	}
	_ = n
	return out.bytestr()
}

pub struct IpPrefix {
	addr IpAddr
	bits int
}

pub fn parse_prefix(s string) IpPrefix {
	cut := s.index('/') or { panic('bad prefix ${s}') }
	addr := parse_ip(s[..cut]) or { panic('bad prefix ${s}') }
	return IpPrefix{addr, s[cut + 1..].int()}
}

fn prefix_contains(p IpPrefix, a IpAddr) bool {
	if p.addr.is_v6 != a.is_v6 {
		// Compare v4 against v4-mapped v6 by extracting the tail.
		if !p.addr.is_v6 && a.is_v6 && a.b.len == 16 {
			mut mapped := true
			for i in 0 .. 10 {
				if a.b[i] != 0 {
					mapped = false
					break
				}
			}
			if mapped && a.b[10] == 0xff && a.b[11] == 0xff {
				tail := IpAddr{false, a.b[12..].clone()}
				return prefix_contains(p, tail)
			}
		}
		return false
	}
	mut bits := p.bits
	mut i := 0
	for bits >= 8 {
		if p.addr.b[i] != a.b[i] {
			return false
		}
		i++
		bits -= 8
	}
	if bits > 0 {
		mask := u8(0xff << u8(8 - bits))
		if (p.addr.b[i] & mask) != (a.b[i] & mask) {
			return false
		}
	}
	return true
}

fn in_ranges(ip IpAddr, ranges []string) bool {
	for r in ranges {
		if prefix_contains(parse_prefix(r), ip) {
			return true
		}
	}
	return false
}

fn is_loopback(ip IpAddr) bool {
	if !ip.is_v6 {
		return ip.b[0] == 127
	}
	for i in 0 .. 15 {
		if ip.b[i] != 0 {
			return false
		}
	}
	return ip.b[15] == 1
}

// blocked mirrors the Go port's Blocked over the Surfguard tables.
pub fn blocked(ip IpAddr) bool {
	if ip.b.len == 0 {
		return true
	}
	if !ip.is_v6 {
		return in_ranges(ip, blocked_v4)
	}
	if in_ranges(ip, mapped_ranges) {
		return true
	}
	if in_ranges(ip, translated_ranges) {
		tail := IpAddr{false, ip.b[12..].clone()}
		return in_ranges(tail, blocked_v4)
	}
	if in_ranges(ip, ietf_public) {
		return false
	}
	return is_loopback(ip) || in_ranges(ip, private_v6) || in_ranges(ip, blocked_v6) || !in_ranges(ip, allocated_v6)
}

fn is_numeric_host_rune(c u8) bool {
	return (c >= `0` && c <= `9`) || c == `.` || c == `x` || c == `X` || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}

fn match_numeric_host(s string) bool {
	if s.len == 0 {
		return false
	}
	parts := s.split('.')
	if parts.len < 1 || parts.len > 4 {
		return false
	}
	for p in parts {
		if p.len == 0 {
			return false
		}
		if p[0] == `0` && (p.len > 1 && (p[1] == `x` || p[1] == `X`)) {
			if p.len == 2 {
				return false
			}
			for c in p[2..].bytes() {
				if !((c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)) {
					return false
				}
			}
		} else {
			for c in p.bytes() {
				if c < `0` || c > `9` {
					return false
				}
			}
		}
	}
	return true
}

fn match_host_label(s string) bool {
	if s.len == 0 || s.len > 63 {
		return false
	}
	if !is_alnum_byte(s[0]) || !is_alnum_byte(s[s.len - 1]) {
		return false
	}
	for c in s.bytes() {
		if !is_alnum_byte(c) && c != `-` {
			return false
		}
	}
	return true
}

fn is_alnum_byte(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
}

// numeric_address mirrors Go's Ruby-compatible dotted/host parsing.
pub fn numeric_address(host string) (IpAddr, bool) {
	if ip := parse_ip(host) {
		return ip, true
	}
	if !match_numeric_host(host) {
		return IpAddr{}, false
	}
	parts := host.split('.')
	mut address := u64(0)
	for i, part in parts {
		mut base := 10
		mut p := part
		lower := part.to_lower()
		if lower.starts_with('0x') {
			base = 16
			p = part[2..]
		} else if p.len > 1 && p[0] == `0` {
			base = 8
			p = part[1..]
		}
		n := parse_uint_base(p, base) or { return IpAddr{}, true }
		if i < parts.len - 1 {
			if n > 255 {
				return IpAddr{}, true
			}
			address |= n << u64(24 - 8 * i)
		} else {
			bits := 32 - 8 * i
			if n >= u64(1) << u64(bits) {
				return IpAddr{}, true
			}
			address |= n
		}
	}
	return IpAddr{false, [u8((address >> 24) & 0xff), u8((address >> 16) & 0xff), u8((address >> 8) & 0xff), u8(address & 0xff)]}, true
}

fn parse_uint_base(s string, base int) ?u64 {
	if s.len == 0 {
		return none
	}
	mut n := u64(0)
	for c in s.bytes() {
		mut d := u64(0)
		if c >= `0` && c <= `9` {
			d = u64(c - `0`)
		} else if base == 16 && c >= `a` && c <= `f` {
			d = u64(c - `a`) + 10
		} else if base == 16 && c >= `A` && c <= `F` {
			d = u64(c - `A`) + 10
		} else {
			return none
		}
		if d >= u64(base) {
			return none
		}
		// Limit to 32 bits like Go's ParseUint(..., 32).
		if n > (u64(0xffffffff) - d) / u64(base) {
			return none
		}
		n = n * u64(base) + d
	}
	return n
}
