// Minimal JSON value model preserving object key order and number literals,
// mirroring Go's encoding/json token stream with UseNumber. Used for the Rails
// signed/encrypted envelopes whose byte representation is part of the wire format.
module rails

pub struct JPair {
pub mut:
	k string
	v JVal
}

pub struct JVal {
pub mut:
	kind int // 0=null 1=false 2=true 3=number 4=string 5=array 6=object
	num  string
	str  string
	arr  []JVal
	obj  []JPair
}

pub fn jnull() JVal {
	return JVal{kind: 0}
}

pub fn jbool(b bool) JVal {
	return JVal{kind: if b { 2 } else { 1 }}
}

pub fn jnum(s string) JVal {
	return JVal{kind: 3, num: s}
}

pub fn jstr_val(s string) JVal {
	return JVal{kind: 4, str: s}
}

pub fn (v JVal) get(key string) JVal {
	if v.kind == 6 {
		for p in v.obj {
			if p.k == key {
				return p.v
			}
		}
	}
	return jnull()
}

struct JParser {
	s string
mut:
	pos int
}

fn jskip_ws(mut p JParser) {
	for p.pos < p.s.len && (p.s[p.pos] == ` ` || p.s[p.pos] == `\t` || p.s[p.pos] == `\n` || p.s[p.pos] == `\r`) {
		p.pos++
	}
}

fn jparse_string(mut p JParser) !string {
	// p.s[p.pos] == '"'
	p.pos++
	mut out := []u8{}
	for {
		if p.pos >= p.s.len {
			return error('unterminated string')
		}
		c := p.s[p.pos]
		if c == `"` {
			p.pos++
			return out.bytestr()
		}
		if c == `\\` {
			p.pos++
			if p.pos >= p.s.len {
				return error('unterminated escape')
			}
			e := p.s[p.pos]
			match e {
				`"`, `\\`, `/` {
					out << e
					p.pos++
				}
				`b` {
					out << u8(8)
					p.pos++
				}
				`f` {
					out << u8(12)
					p.pos++
				}
				`n` {
					out << u8(10)
					p.pos++
				}
				`r` {
					out << u8(13)
					p.pos++
				}
				`t` {
					out << u8(9)
					p.pos++
				}
				`u` {
					if p.pos + 4 >= p.s.len {
						return error('bad unicode escape')
					}
					hex := p.s[p.pos + 1..p.pos + 5]
					cp := parse_hex4(hex) or { return error('bad unicode escape') }
					p.pos += 5
					mut code := cp
					if code >= 0xd800 && code <= 0xdbff {
						if p.pos + 5 < p.s.len && p.s[p.pos] == `\\` && p.s[p.pos + 1] == `u` {
							lo := parse_hex4(p.s[p.pos + 2..p.pos + 6]) or { 0 }
							if lo >= 0xdc00 && lo <= 0xdfff {
								code = 0x10000 + ((code - 0xd800) << 10) + (lo - 0xdc00)
								p.pos += 6
							}
						}
					}
					out << utf8_encode(code)
				}
				else {
					return error('bad escape')
				}
			}
		} else {
			out << c
			p.pos++
		}
	}
	return error('unterminated string')
}

fn parse_hex4(s string) !int {
	if s.len != 4 {
		return error('bad hex')
	}
	mut n := 0
	for i in 0 .. 4 {
		c := s[i]
		n <<= 4
		if c >= `0` && c <= `9` {
			n |= int(c - `0`)
		} else if c >= `a` && c <= `f` {
			n |= int(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			n |= int(c - `A`) + 10
		} else {
			return error('bad hex')
		}
	}
	return n
}

fn utf8_encode(cp int) []u8 {
	if cp < 0x80 {
		return [u8(cp)]
	} else if cp < 0x800 {
		return [u8(0xc0 | (cp >> 6)), u8(0x80 | (cp & 0x3f))]
	} else if cp < 0x10000 {
		return [u8(0xe0 | (cp >> 12)), u8(0x80 | ((cp >> 6) & 0x3f)), u8(0x80 | (cp & 0x3f))]
	}
	return [u8(0xf0 | (cp >> 18)), u8(0x80 | ((cp >> 12) & 0x3f)), u8(0x80 | ((cp >> 6) & 0x3f)),
		u8(0x80 | (cp & 0x3f))]
}

fn jparse_value(mut p JParser) !JVal {
	jskip_ws(mut p)
	if p.pos >= p.s.len {
		return error('unexpected end')
	}
	c := p.s[p.pos]
	if c == `{` {
		p.pos++
		mut obj := []JPair{}
		jskip_ws(mut p)
		if p.pos < p.s.len && p.s[p.pos] == `}` {
			p.pos++
			return JVal{kind: 6, obj: obj}
		}
		for {
			jskip_ws(mut p)
			if p.pos >= p.s.len || p.s[p.pos] != `"` {
				return error('expected key')
			}
			k := jparse_string(mut p)!
			jskip_ws(mut p)
			if p.pos >= p.s.len || p.s[p.pos] != `:` {
				return error('expected colon')
			}
			p.pos++
			v := jparse_value(mut p)!
			obj << JPair{k, v}
			jskip_ws(mut p)
			if p.pos >= p.s.len {
				return error('unterminated object')
			}
			if p.s[p.pos] == `}` {
				p.pos++
				return JVal{kind: 6, obj: obj}
			}
			if p.s[p.pos] != `,` {
				return error('expected comma')
			}
			p.pos++
		}
	}
	if c == `[` {
		p.pos++
		mut arr := []JVal{}
		jskip_ws(mut p)
		if p.pos < p.s.len && p.s[p.pos] == `]` {
			p.pos++
			return JVal{kind: 5, arr: arr}
		}
		for {
			arr << jparse_value(mut p)!
			jskip_ws(mut p)
			if p.pos >= p.s.len {
				return error('unterminated array')
			}
			if p.s[p.pos] == `]` {
				p.pos++
				return JVal{kind: 5, arr: arr}
			}
			if p.s[p.pos] != `,` {
				return error('expected comma')
			}
			p.pos++
		}
	}
	if c == `"` {
		return JVal{kind: 4, str: jparse_string(mut p)!}
	}
	if p.s[p.pos..].starts_with('true') {
		p.pos += 4
		return JVal{kind: 2}
	}
	if p.s[p.pos..].starts_with('false') {
		p.pos += 5
		return JVal{kind: 1}
	}
	if p.s[p.pos..].starts_with('null') {
		p.pos += 4
		return JVal{kind: 0}
	}
	if c == `-` || (c >= `0` && c <= `9`) {
		start := p.pos
		if c == `-` {
			p.pos++
		}
		for p.pos < p.s.len && p.s[p.pos] >= `0` && p.s[p.pos] <= `9` {
			p.pos++
		}
		if p.pos < p.s.len && p.s[p.pos] == `.` {
			p.pos++
			for p.pos < p.s.len && p.s[p.pos] >= `0` && p.s[p.pos] <= `9` {
				p.pos++
			}
		}
		if p.pos < p.s.len && (p.s[p.pos] == `e` || p.s[p.pos] == `E`) {
			p.pos++
			if p.pos < p.s.len && (p.s[p.pos] == `+` || p.s[p.pos] == `-`) {
				p.pos++
			}
			for p.pos < p.s.len && p.s[p.pos] >= `0` && p.s[p.pos] <= `9` {
				p.pos++
			}
		}
		return JVal{kind: 3, num: p.s[start..p.pos]}
	}
	return error('unexpected character')
}

// jparse parses any JSON value and rejects trailing data, like Go's
// CanonicalJSON which requires the decoder to reach io.EOF after the root.
pub fn jparse(s string) !JVal {
	mut p := JParser{s: s}
	v := jparse_value(mut p)!
	jskip_ws(mut p)
	if p.pos != p.s.len {
		return error('trailing data')
	}
	return v
}

// jquote renders a JSON string literal. Like ActiveSupport with HTML escaping
// disabled it passes Unicode through literally, including U+2028/U+2029; with
// escape_html it escapes <, > and & as Go's encoding/json does.
pub fn jquote(s string, escape_html bool) string {
	mut out := []u8{cap: s.len + 2}
	out << `"`
	bs := s.bytes()
	mut i := 0
	for i < bs.len {
		c := bs[i]
		if c == `"` {
			out << `\\`
			out << `"`
		} else if c == `\\` {
			out << `\\`
			out << `\\`
		} else if c == `\n` {
			out << `\\`
			out << `n`
		} else if c == `\r` {
			out << `\\`
			out << `r`
		} else if c == `\t` {
			out << `\\`
			out << `t`
		} else if c == u8(8) {
			out << `\\`
			out << `b`
		} else if c == u8(12) {
			out << `\\`
			out << `f`
		} else if c == `<` || c == `>` || c == `&` {
			if escape_html {
				out << `\\`
				out << `u`
				hex4 := '0123456789abcdef'
				n := int(c)
				out << hex4[n >> 12]
				out << hex4[(n >> 8) & 15]
				out << hex4[(n >> 4) & 15]
				out << hex4[n & 15]
			} else {
				out << c
			}
		} else {
			if c < u8(0x20) {
				out << `\\`
				out << `u`
				out << `0`
				out << `0`
				hex4 := '0123456789abcdef'
				out << hex4[int(c) >> 4]
				out << hex4[int(c) & 15]
			} else {
				out << c
			}
		}
		i++
	}
	out << `"`
	return out.bytestr()
}

// canonical re-serializes a parsed value preserving object key order and
// integer precision, like Go's CanonicalJSON.
pub fn (v JVal) canonical(escape_html bool) string {
	match v.kind {
		0 {
			return 'null'
		}
		1 {
			return 'false'
		}
		2 {
			return 'true'
		}
		3 {
			return v.num
		}
		4 {
			return jquote(v.str, escape_html)
		}
		5 {
			mut parts := []string{cap: v.arr.len}
			for x in v.arr {
				parts << x.canonical(escape_html)
			}
			return '[' + parts.join(',') + ']'
		}
		else {
			mut parts := []string{cap: v.obj.len}
			for p in v.obj {
				parts << jquote(p.k, escape_html) + ':' + p.v.canonical(escape_html)
			}
			return '{' + parts.join(',') + '}'
		}
	}
}

// canonical_json parses raw and returns its canonical byte representation.
pub fn canonical_json(raw []u8, escape_html bool) ![]u8 {
	v := jparse(raw.bytestr())!
	return v.canonical(escape_html).bytes()
}
