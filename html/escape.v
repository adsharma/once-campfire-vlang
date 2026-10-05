module html

const replacement_table = [0x20ac, 0x81, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020,
	0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018,
	0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a,
	0x153, 0x9d, 0x17e, 0x178]

fn is_alnum_byte(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
}

// unescape_entity consumes a character reference at s[src:] (s[src] == '&')
// and returns the rune(s) plus bytes consumed.
fn unescape_entity(s string, src int, attribute bool) (int, int, int) {
	if src + 1 >= s.len {
		return int(`&`), 0, 1
	}
	mut i := src + 1
	if s[i] == `#` {
		if src + 2 >= s.len {
			return int(`&`), 0, 1
		}
		i++
		c := s[i]
		mut hex := false
		if c == `x` || c == `X` {
			hex = true
			i++
		}
		i0 := i
		mut x := 0
		for i < s.len {
			c2 := s[i]
			mut d := -1
			if hex {
				if c2 >= `0` && c2 <= `9` {
					d = int(c2 - `0`)
				} else if c2 >= `a` && c2 <= `f` {
					d = int(c2 - `a`) + 10
				} else if c2 >= `A` && c2 <= `F` {
					d = int(c2 - `A`) + 10
				} else {
					break
				}
				if x <= 0x10ffff {
					x = 16 * x + d
				}
			} else {
				if c2 >= `0` && c2 <= `9` {
					d = int(c2 - `0`)
				} else {
					break
				}
				if x <= 0x10ffff {
					x = 10 * x + d
				}
			}
			i++
		}
		if i == i0 {
			return int(`&`), 0, 1
		}
		if i < s.len && s[i] == `;` {
			i++
		}
		if x >= 0x80 && x <= 0x9f {
			x = replacement_table[x - 0x80]
		} else if x == 0 || (x >= 0xd800 && x <= 0xdfff) || x > 0x10ffff {
			x = 0xfffd
		}
		return x, 0, i - src
	}
	for i < s.len {
		c := s[i]
		i++
		if is_alnum_byte(c) {
			continue
		}
		if c != `;` {
			i--
		}
		break
	}
	entity_name := s[src + 1..i]
	if entity_name == '' {
	} else if attribute && entity_name[entity_name.len - 1] != `;` && i < s.len && s[i] == `=` {
	} else if v := entity_table[entity_name] {
		return v, 0, i - src
	} else if v := entity2_table[entity_name] {
		return v[0], v[1], i - src
	} else if !attribute {
		mut max_len := entity_name.len - 1
		if max_len > longest_entity_without_semicolon {
			max_len = longest_entity_without_semicolon
		}
		mut j := max_len
		for j > 1 {
			if v := entity_table[entity_name[..j]] {
				return v, 0, j + 1
			}
			j--
		}
	}
	return int(`&`), 0, 1
}

fn append_rune(mut out []u8, r int) {
	if r < 0x80 {
		out << u8(r)
	} else if r < 0x800 {
		out << u8(0xc0 | (r >> 6))
		out << u8(0x80 | (r & 0x3f))
	} else if r < 0x10000 {
		out << u8(0xe0 | (r >> 12))
		out << u8(0x80 | ((r >> 6) & 0x3f))
		out << u8(0x80 | (r & 0x3f))
	} else {
		out << u8(0xf0 | (r >> 18))
		out << u8(0x80 | ((r >> 12) & 0x3f))
		out << u8(0x80 | ((r >> 6) & 0x3f))
		out << u8(0x80 | (r & 0x3f))
	}
}

// unescape_text decodes entities in text (attribute selects the attribute rules).
pub fn unescape_text(s string, attribute bool) string {
	first := s.index('&') or { return s }
	mut out := []u8{cap: s.len}
	out << s[..first].bytes()
	mut src := first
	for src < s.len {
		if s[src] != `&` {
			out << s[src]
			src++
			continue
		}
		r1, r2, n := unescape_entity(s, src, attribute)
		if n == 1 && r1 == `&` {
			out << `&`
			src++
			continue
		}
		append_rune(mut out, r1)
		if r2 != 0 {
			append_rune(mut out, r2)
		}
		src += n
	}
	return out.bytestr()
}

// unescape_string is the fragment-text entity decoder used by the sanitizer.
pub fn unescape_string(s string) string {
	return unescape_text(s, false)
}

fn lower_in_place(mut b []u8) {
	for i in 0 .. b.len {
		if b[i] >= `A` && b[i] <= `Z` {
			b[i] += 32
		}
	}
}

// escape_string escapes text for HTML output.
pub fn escape_string(s string) string {
	mut out := []u8{cap: s.len}
	for c in s.bytes() {
		if c == `&` {
			out << '&amp;'.bytes()
		} else if c == `<` {
			out << '&lt;'.bytes()
		} else if c == `>` {
			out << '&gt;'.bytes()
		} else if c == `"` {
			out << '&#34;'.bytes()
		} else if c == `'` {
			out << '&#39;'.bytes()
		} else {
			out << c
		}
	}
	return out.bytestr()
}
