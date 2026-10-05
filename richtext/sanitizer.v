module richtext

import html

// match_scheme mirrors schemePattern on an already-lowercased string,
// returning the scheme or ''.
fn match_scheme(s string) string {
	if s.len == 0 || s[0] < `a` || s[0] > `z` {
		return ''
	}
	mut i := 1
	for i < s.len {
		c := s[i]
		if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) || c == `+` || c == `-` || c == `.` {
			i++
		} else {
			break
		}
	}
	scheme := s[..i]
	rest := s[i..]
	if rest.starts_with(':') {
		return scheme
	}
	if rest.starts_with('%3a') {
		return scheme
	}
	if rest.starts_with('&#') {
		mut j := 2
		if rest[j..].starts_with('x') || rest[j..].starts_with('X') {
			// Lowercase compare needs the original; caller lowercases first.
			j++
			for j < rest.len && rest[j] == `0` {
				j++
			}
			if rest[j..].starts_with('3a') {
				return scheme
			}
		} else {
			for j < rest.len && rest[j] == `0` {
				j++
			}
			if rest[j..].starts_with('58') {
				return scheme
			}
		}
	}
	if rest.starts_with('&#37;3a') {
		return scheme
	}
	return ''
}

// match_color mirrors colorPattern (case-insensitive).
fn match_color(value string) bool {
	s := value.to_lower()
	if s == '' {
		return false
	}
	mut alpha := true
	for c in s.bytes() {
		if c < `a` || c > `z` {
			alpha = false
			break
		}
	}
	if alpha {
		return true
	}
	if s.starts_with('#') {
		hex := s[1..]
		if hex.len < 3 || hex.len > 8 {
			return false
		}
		for c in hex.bytes() {
			if !((c >= `0` && c <= `9`) || (c >= `a` && c <= `f`)) {
				return false
			}
		}
		return true
	}
	if s.starts_with('var(') && s.ends_with(')') {
		inner := s[4..s.len - 1].trim(' \t\n\r\x0b\x0c')
		if inner.starts_with('--') {
			rest := inner[2..]
			if rest == '' {
				return false
			}
			for c in rest.bytes() {
				if !((c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) || c == `_` || c == `-`) {
					return false
				}
			}
			return true
		}
		return false
	}
	for name in ['rgb', 'rgba', 'hsl', 'hsla'] {
		if s.starts_with(name + '(') && s.ends_with(')') {
			inner := s[name.len + 1..s.len - 1]
			for c in inner.bytes() {
				ok := (c >= `0` && c <= `9`) || (c >= `a` && c <= `z`) || c == `.` || c == `,` || c == `%` || c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == 0x0b || c == 0x0c || c == `/` || c == `+` || c == `-`
				if !ok {
					return false
				}
			}
			return true
		}
	}
	return false
}

fn append_rune(mut out []u8, r u32) {
	if r < 0x80 {
		out << u8(r)
	} else if r < 0x800 {
		out << u8(0xc0 | (r >> 6))
		out << u8(0x80 | (r & 63))
	} else if r < 0x10000 {
		out << u8(0xe0 | (r >> 12))
		out << u8(0x80 | ((r >> 6) & 63))
		out << u8(0x80 | (r & 63))
	} else {
		out << u8(0xf0 | (r >> 18))
		out << u8(0x80 | ((r >> 12) & 63))
		out << u8(0x80 | ((r >> 6) & 63))
		out << u8(0x80 | (r & 63))
	}
}

fn rune_str(r u32) string {
	mut out := []u8{}
	append_rune(mut out, r)
	return out.bytestr()
}

fn strip_bad(s string) string {
	mut out := []u8{cap: s.len}
	for c in s.runes() {
		r := u32(c)
		if r == 0x60 || r <= 32 || r == 127 || (r >= 128 && r <= 257) {
			continue
		}
		append_rune(mut out, r)
	}
	return out.bytestr()
}

fn allowed_uri(value string) bool {
	mut s := html.unescape_string(strip_bad(value)).to_lower()
	s = s.replace('&tab;', '').replace('&newline;', '').replace('&colon;', ':')
	scheme := match_scheme(s)
	if scheme == '' {
		return true
	}
	if scheme !in protocols {
		return false
	}
	if scheme != 'data' {
		return true
	}
	after := s[5..]
	comma := after.index(',') or { return false }
	metadata := after[..comma]
	mut media := metadata.split(';')[0]
	if !media.contains('/') {
		media = 'text/plain'
	}
	return media in data_types
}

fn sanitize_dom(root &html.Node, mode string) {
	sanitize_visit(root, mode)
}

fn sanitize_visit(n &html.Node, mode string) {
	for c in n.children() {
		sanitize_visit(c, mode)
	}
	if n.typ == .text_node {
		return
	}
	if n.parent == none {
		return
	}
	tag := n.data
	mut allowed := (tag in default_tags) || (tag in editor_tags)
	if mode == 'action' {
		allowed = allowed || (tag in action_tags)
	}
	if mode == 'filter' {
		allowed = tag != 'img' && (allowed || tag == 'action-text-attachment' || tag == 'figure' || tag == 'figcaption')
	}
	if !allowed {
		if n.namespace == '' {
			for c in n.children() {
				n.remove_child(c)
				if parent := n.parent {
					parent.insert_before(c, n)
				}
			}
		}
		if parent := n.parent {
			parent.remove_child(n)
		}
		return
	}
	mut i := 0
	for i < n.attr.len {
		a := n.attr[i]
		mut key := a.key
		if a.namespace != '' {
			key = a.namespace + ':' + key
		}
		mut keep := (key in default_attrs) || key == 'data-language'
		if mode != 'auto' {
			keep = keep || (key in attachment_attrs) || (key in action_attrs)
		}
		if !keep || ((key in uri_attrs) && !allowed_uri(a.val)) {
			n.delete_attr_at(i)
			continue
		}
		if key == 'src' && trim_unicode_space(a.val) == '' {
			n.delete_attr_at(i)
		} else {
			i++
		}
		for j, b in n.attr {
			if b.key == 'href' || b.key == 'action' || b.key == 'src' {
				mut v := b.val.bytes()
				mut clean := []u8{cap: v.len}
				for c in v {
					if c < 32 && c != `\t` && c != `\n` && c != `\r` {
						continue
					}
					clean << c
				}
				val := clean.bytestr().replace(' ', '%20').replace('"', '%22')
				n.set_attr_val_at(j, val)
			}
		}
	}
	for k, a in n.attr {
		if a.key != 'style' {
			continue
		}
		mut safe := []string{}
		mut all := true
		for declaration in a.val.split(';') {
			if declaration.trim_space() == '' {
				continue
			}
			cut := declaration.index(':') or { -1 }
			mut key := declaration
			mut value := ''
			if cut >= 0 {
				key = declaration[..cut]
				value = declaration[cut + 1..]
			}
			key = key.to_lower().trim_space()
			value = value.trim_space()
			if (key == 'color' || key == 'background-color') && match_color(value) {
				safe << key + ': ' + value + ';'
			} else {
				all = false
			}
		}
		if safe.len == 0 {
			n.delete_attr_at(k)
		} else if !all {
			n.set_attr_val_at(k, safe.join(''))
		}
		break
	}
}

fn filter_tags(root &html.Node) {
	walk(root, fn (n &html.Node) {
		if n.typ != .element_node {
			return
		}
		if n.parent == none {
			return
		}
		keep := n.data != 'img' && ((n.data in default_tags) || (n.data in editor_tags) || n.data == 'action-text-attachment' || n.data == 'figure' || n.data == 'figcaption')
		if !keep {
			if parent := n.parent {
				parent.remove_child(n)
			}
		}
	})
}

fn sanitize_string(s string) !string {
	n := parse_rich(s)!
	sanitize_dom(n, 'default')
	return serialize(n)
}

fn query_escape_href(s string) string {
	mut out := []u8{cap: s.len}
	hex_digits := '0123456789ABCDEF'
	for c in s.bytes() {
		if (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) || c == `-` || c == `_` || c == `.` || c == `~` {
			out << c
		} else if c == ` ` {
			out << `+`
		} else {
			out << `%`
			out << hex_digits[int(c) >> 4]
			out << hex_digits[int(c) & 15]
		}
	}
	return out.bytestr()
}

fn autolink(text string) !string {
	mut out := []u8{}
	mut last := 0
	tags := index_tags(text)
	matches := find_urls(text)
	mut k := 0
	for k < matches.len {
		m0 := matches[k]
		m1 := matches[k + 1]
		k += 2
		out << text[last..m0].bytes()
		last = m1
		whole := text[m0..m1]
		if tags.linked(m0, m1) {
			out << whole.bytes()
			continue
		}
		mut href := whole.runes()
		mut counts := map[u32]int{}
		for c in href {
			counts[u32(c)] = counts[u32(c)] + 1
		}
		mut punctuation := []u32{}
		for href.len > 0 {
			c := u32(href[href.len - 1])
			if is_word_rune(c) || c == u32(`/`) || c == u32(`=`) || c == u32(`-`) || c == u32(`;`) {
				break
			}
			href = href[..href.len - 1]
			punctuation << c
			counts[c] = counts[c] - 1
			opening := match c {
				u32(`)`) { u32(`(`) }
				u32(`]`) { u32(`[`) }
				u32(`}`) { u32(`{`) }
				else { u32(0) }
			}
			if opening != 0 && counts[opening] > counts[c] {
				href << c
				punctuation.pop()
				break
			}
		}
		mut display := href.string()
		mut trailing_gt := ''
		if display.ends_with('&gt;') {
			display = display[..display.len - 4]
			trailing_gt = '&gt;'
		}
		mut destination := display
		if destination.to_lower().starts_with('www.') {
			destination = 'http://' + destination
		}
		display = sanitize_string(display)!
		destination = sanitize_string(destination)!
		out << ('<a target="_blank" href="' + destination.replace('"', '&quot;') + '">' + display + '</a>').bytes()
		for i := punctuation.len - 1; i >= 0; i-- {
			out << erb_escape(rune_str(punctuation[i])).bytes()
		}
		out << trailing_gt.bytes()
	}
	out << text[last..].bytes()
	return autolink_emails(out.bytestr())
}

fn is_email_local(c u8) bool {
	if c < 128 {
		return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_` || c == `.` || c == `!` || c == `#` || c == `$` || c == `%` || c == `&` || c == `'` || c == `*` || c == `/` || c == `=` || c == `?` || c == `^` || c == u8(0x60) || c == `{` || c == `|` || c == `}` || c == `~` || c == `+` || c == `-`
	}
	return false
}

fn autolink_emails(text string) !string {
	mut out := []u8{}
	mut copied := 0
	mut position := 0
	tags := index_tags(text)
	for position < text.len {
		mut m_end := -1
		mut prev_ok := false
		if position == 0 {
			prev_ok = true
		} else {
			prev := rune_before(text, position)
			prev_ok = prev >= 128 || !is_email_local(u8(prev))
		}
		if prev_ok {
			m_end = match_email_at(text, position)
		}
		if m_end < 0 {
			position += utf8_len_at(text, position)
			continue
		}
		start := position
		end := m_end
		email := text[start..end]
		out << text[copied..start].bytes()
		if tags.linked(start, end) {
			out << email.bytes()
		} else {
			sanitized := sanitize_string(email)!
			mut display := sanitized
			if sanitized == email {
				display = erb_escape(email)
			}
			href := 'mailto:' + query_escape_href(sanitized).replace('%40', '@')
			out << ('<a target="_blank" href="' + erb_escape(href) + '">' + display + '</a>').bytes()
		}
		copied = end
		position = end
	}
	out << text[copied..].bytes()
	return out.bytestr()
}
