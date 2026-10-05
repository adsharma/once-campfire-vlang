module html

pub enum TokenType {
	error_token
	text_token
	start_tag_token
	end_tag_token
	self_closing_tag_token
	comment_token
	doctype_token
}

pub struct Token {
pub mut:
	typ   TokenType = .error_token
	data  string
	attrs []Attribute
}

pub struct Tokenizer {
	input string
mut:
	pos           int
	pending_err   string
	allow_cdata   bool
	tag_truncated bool
}

pub fn new_tokenizer(input string) Tokenizer {
	// Input-stream CR normalization, applied before tokenization.
	normalized := input.replace('\r\n', '\n').replace('\r', '\n')
	return Tokenizer{input: normalized}
}

pub fn (mut z Tokenizer) set_allow_cdata(allow bool) {
	z.allow_cdata = allow
}

fn (mut z Tokenizer) eof() bool {
	return z.pos >= z.input.len
}

fn peek_at(s string, pos int) u8 {
	if pos < s.len {
		return s[pos]
	}
	return 0
}

fn is_ascii_alpha(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
}

fn is_tag_name_char(c u8) bool {
	return is_ascii_alpha(c) || (c >= `0` && c <= `9`)
}

fn lower_str(s string) string {
	mut b := s.bytes()
	lower_in_place(mut b)
	return b.bytestr()
}

fn (mut z Tokenizer) read_tag_name() string {
	start := z.pos
	for z.pos < z.input.len {
		c := z.input[z.pos]
		if c == ` ` || c == `\t` || c == `\n` || c == `\x0c` || c == `\r` || c == `/` || c == `>` || c == `<` || c == 0 {
			break
		}
		z.pos++
	}
	mut name := z.input[start..z.pos]
	if name.contains('\x00') {
		name = name.replace('\x00', '�').replace('\ue000', '�')
	}
	return lower_str(name)
}

fn (mut z Tokenizer) skip_ws() {
	for z.pos < z.input.len {
		c := z.input[z.pos]
		if c == ` ` || c == `\t` || c == `\n` || c == `\x0c` {
			z.pos++
		} else {
			break
		}
	}
}

// read_attr_value reads a quoted or unquoted attribute value (pos is after '=').
fn (mut z Tokenizer) read_attr_value() string {
	z.skip_ws()
	if z.pos >= z.input.len {
		return ''
	}
	q := z.input[z.pos]
	if q == `"` || q == `'` {
		z.pos++
		start := z.pos
		for z.pos < z.input.len && z.input[z.pos] != q {
			z.pos++
		}
		v := z.input[start..z.pos]
		if z.pos < z.input.len {
			z.pos++
		}
		return unescape_text(v.replace('\x00', '�').replace('\ue000', '�'), true)
	}
	start := z.pos
	for z.pos < z.input.len {
		c := z.input[z.pos]
		if c == ` ` || c == `\t` || c == `\n` || c == `\x0c` || c == `>` {
			break
		}
		z.pos++
	}
	return unescape_text(z.input[start..z.pos].replace('\x00', '�').replace('\ue000', '�'), true)
}

// read_tag parses a start or end tag; z.pos is just after '<' (or '</').
fn (mut z Tokenizer) read_tag(is_end bool) Token {
	z.tag_truncated = false
	mut tok := Token{typ: if is_end { .end_tag_token } else { .start_tag_token }}
	if is_end {
		z.skip_ws()
	}
	tok.data = z.read_tag_name()
	mut attr_count := 0
	for {
		z.skip_ws()
		if z.pos >= z.input.len {
			// EOF inside a tag drops the token, like the reference tokenizer.
			z.tag_truncated = true
			break
		}
		c := z.input[z.pos]
		if c == `>` {
			z.pos++
			break
		}
		if c == `/` {
			z.pos++
			z.skip_ws()
			if z.pos < z.input.len && z.input[z.pos] == `>` {
				z.pos++
				if !is_end {
					tok.typ = .self_closing_tag_token
				}
				break
			}
			continue
		}
		if c == `<` {
			break
		}
		// Attribute name: quotes are consumed as part of the name (spec);
		// this also guarantees the scanner always makes progress.
		start := z.pos
		for z.pos < z.input.len {
			a := z.input[z.pos]
			if a == ` ` || a == `\t` || a == `\n` || a == `\x0c` || a == `\r` || a == `/` || a == `>` || a == `=` || a == `<` || a == 0 {
				break
			}
			z.pos++
		}
		mut key := lower_str(z.input[start..z.pos].replace('\x00', '�').replace('\ue000', '�'))
		mut val := ''
		z.skip_ws()
		if z.pos < z.input.len && z.input[z.pos] == `=` {
			z.pos++
			val = z.read_attr_value()
		}
		attr_count++
		if attr_count > 400 {
			z.pending_err = 'html: more than 400 attributes'
			return Token{typ: .error_token}
		}
		mut dup := false
		for a in tok.attrs {
			if a.key == key {
				dup = true
				break
			}
		}
		if !dup && key != '' {
			tok.attrs << Attribute{key: key, val: val}
		}
	}
	return tok
}

fn (mut z Tokenizer) read_comment(bogus bool, start int) Token {
	mut end := -1
	if !bogus {
		mut i := start
		for i < z.input.len {
			if z.input[i] == `-` && i + 2 < z.input.len && z.input[i + 1] == `-` && z.input[i + 2] == `>` {
				end = i
				i += 3
				break
			}
			if z.input[i] == `-` && i + 3 < z.input.len && z.input[i + 1] == `-` && z.input[i + 2] == `!` && z.input[i + 3] == `>` {
				end = i
				i += 4
				break
			}
			i++
		}
		if end < 0 {
			end = z.input.len
			i = z.input.len
		}
		data := z.input[start..end].replace('\x00', '�').replace('\ue000', '�')
		z.pos = i
		return Token{typ: .comment_token, data: data}
	}
	i := z.input.index_after('>', start) or { -1 }
	if i < 0 {
		data := z.input[start..].replace('\x00', '�').replace('\ue000', '�')
		z.pos = z.input.len
		return Token{typ: .comment_token, data: data}
	}
	data := z.input[start..i].replace('\x00', '�').replace('\ue000', '�')
	z.pos = i + 1
	return Token{typ: .comment_token, data: data}
}

fn (mut z Tokenizer) read_doctype() Token {
	start := z.pos
	i := z.input.index_after('>', z.pos) or { -1 }
	if i < 0 {
		z.pos = z.input.len
		return Token{typ: .doctype_token, data: lower_str(z.input[start..])}
	}
	z.pos = i + 1
	return Token{typ: .doctype_token, data: lower_str(z.input[start..i])}
}

// next_raw_text consumes raw text until the matching end tag (which is left
// unread). When rcdata is set, entities are decoded.
pub fn (mut z Tokenizer) next_raw_text(tag string, rcdata bool) string {
	mut i := z.pos
	lower := z.input.to_lower()
	needle := '</' + tag
	for {
		idx := lower.index_after(needle, i) or { -1 }
		if idx < 0 {
			text := z.input[z.pos..]
			z.pos = z.input.len
			if rcdata {
				return unescape_text(text.replace('\x00', '�').replace('\ue000', '�'), false)
			}
			return text.replace('\x00', '�').replace('\ue000', '�')
		}
		after := idx + needle.len
		if after < z.input.len {
			c := z.input[after]
			if c == `>` || c == ` ` || c == `\t` || c == `\n` || c == `\x0c` || c == `/` {
				text := z.input[z.pos..idx]
				z.pos = idx
				if rcdata {
					return unescape_text(text.replace('\x00', '�').replace('\ue000', '�'), false)
				}
				return text.replace('\x00', '�').replace('\ue000', '�')
			}
		}
		i = idx + 1
	}
	return ''
}

// next returns the next token.
pub fn (mut z Tokenizer) next() Token {
	if z.pending_err != '' {
		return Token{typ: .error_token}
	}
	if z.eof() {
		return Token{typ: .error_token}
	}
	if z.input[z.pos] != `<` {
		start := z.pos
		for z.pos < z.input.len && z.input[z.pos] != `<` {
			z.pos++
		}
		return Token{typ: .text_token, data: unescape_text(z.input[start..z.pos], false)}
	}
	// z.input[z.pos] == '<'
	if z.pos + 1 >= z.input.len {
		z.pos++
		return Token{typ: .text_token, data: '<'}
	}
	c1 := z.input[z.pos + 1]
	if c1 == `!` {
		rest := z.input[z.pos..]
		if rest.starts_with('<!--') {
			z.pos += 4
			return z.read_comment(false, z.pos)
		}
		if rest.starts_with('<![CDATA[') {
			if z.allow_cdata {
				z.pos += 9
				end := z.input.index_after(']]>', z.pos) or { -1 }
				if end < 0 {
					text := z.input[z.pos..]
					z.pos = z.input.len
					return Token{typ: .text_token, data: text}
				}
				text := z.input[z.pos..end]
				z.pos = end + 3
				return Token{typ: .text_token, data: text}
			}
			// Bogus comment: content starts after '<!'.
			z.pos += 2
			return z.read_comment(true, z.pos)
		}
		upper := rest[..min_int(9, rest.len)].to_upper()
		if upper.starts_with('<!DOCTYPE') {
			z.pos += 9
			return z.read_doctype()
		}
		z.pos += 2
		return z.read_comment(true, z.pos)
	}
	if c1 == `?` {
		z.pos++
		return z.read_comment(true, z.pos)
	}
	if c1 == `/` {
		if z.pos + 2 < z.input.len && is_ascii_alpha(z.input[z.pos + 2]) {
			z.pos += 2
			tok := z.read_tag(true)
			if z.tag_truncated {
				return Token{typ: .error_token}
			}
			return tok
		}
		z.pos += 2
		return z.read_comment(true, z.pos)
	}
	if is_ascii_alpha(c1) {
		z.pos++
		tok := z.read_tag(false)
		if z.tag_truncated {
			return Token{typ: .error_token}
		}
		return tok
	}
	z.pos++
	return Token{typ: .text_token, data: '<'}
}

fn min_int(a int, b int) int {
	if a < b {
		return a
	}
	return b
}
