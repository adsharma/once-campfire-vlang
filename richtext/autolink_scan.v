module richtext


const default_tags = {
	'a': true, 'abbr': true, 'acronym': true, 'address': true, 'b': true, 'big': true,
	'blockquote': true, 'br': true, 'cite': true, 'code': true, 'dd': true, 'del': true,
	'dfn': true, 'div': true, 'dl': true, 'dt': true, 'em': true, 'h1': true,
	'h2': true, 'h3': true, 'h4': true, 'h5': true, 'h6': true, 'hr': true, 'i': true,
	'img': true, 'ins': true, 'kbd': true, 'li': true, 'mark': true, 'ol': true,
	'p': true, 'pre': true, 'samp': true, 'small': true, 'span': true, 'strong': true,
	'sub': true, 'sup': true, 'time': true, 'tt': true, 'ul': true, 'var': true,
}

const editor_tags = {
	's': true, 'u': true, 'mark': true, 'table': true, 'thead': true, 'tbody': true,
	'tfoot': true, 'tr': true, 'th': true, 'td': true,
}

const attachment_attrs = {
	'sgid': true, 'content-type': true, 'url': true, 'href': true, 'filename': true,
	'filesize': true, 'width': true, 'height': true, 'previewable': true,
	'presentation': true, 'caption': true, 'content': true,
}

const default_attrs = {
	'abbr': true, 'alt': true, 'cite': true, 'class': true, 'datetime': true,
	'height': true, 'href': true, 'lang': true, 'src': true, 'title': true,
	'width': true, 'xml:lang': true,
}

const action_attrs = {
	'controls': true, 'poster': true, 'data-language': true, 'style': true,
	'value': true, 'start': true,
}

const action_tags = {
	'action-text-attachment': true, 'figure': true, 'figcaption': true, 'video': true,
	'audio': true, 'source': true, 'embed': true,
}

const uri_attrs = {
	'action': true, 'cite': true, 'href': true, 'longdesc': true, 'poster': true,
	'preload': true, 'src': true, 'xlink:href': true, 'xml:base': true,
}

const protocols = {
	'afs': true, 'aim': true, 'callto': true, 'data': true, 'ed2k': true, 'fax': true,
	'ftp': true, 'gopher': true, 'http': true, 'https': true, 'irc': true, 'line': true,
	'mailto': true, 'modem': true, 'news': true, 'nntp': true, 'rsync': true, 'rtsp': true,
	'sftp': true, 'sms': true, 'ssh': true, 'tag': true, 'tel': true, 'telnet': true,
	'urn': true, 'webcal': true, 'xmpp': true,
}

const data_types = {
	'image/gif': true, 'image/jpeg': true, 'image/png': true, 'text/css': true,
	'text/plain': true,
}

const url_schemes = {
	'ed2k': true, 'ftp': true, 'http': true, 'https': true, 'irc': true, 'mailto': true,
	'news': true, 'gopher': true, 'nntp': true, 'telnet': true, 'webcal': true,
	'xmpp': true, 'callto': true, 'feed': true, 'svn': true, 'urn': true, 'aim': true,
	'rsync': true, 'tag': true, 'ssh': true, 'sftp': true, 'rtsp': true, 'afs': true,
	'file': true,
}

fn is_word_rune(r u32) bool {
	mut lo := 0
	mut hi := word_ranges.len / 2
	for lo < hi {
		mid := (lo + hi) / 2
		if r < u32(word_ranges[mid * 2]) {
			hi = mid
		} else if r > u32(word_ranges[mid * 2 + 1]) {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

fn is_space_byte(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == 0x0b || c == 0x0c
}

fn trim_unicode_space(s string) string {
	mut start := 0
	mut end := s.len
	for start < end && is_unicode_space_at(s, start) {
		start += utf8_len_at(s, start)
	}
	for end > start && is_unicode_space_before(s, end) {
		end -= utf8_len_before(s, end)
	}
	return s[start..end]
}

fn is_unicode_space_at(s string, pos int) bool {
	c := rune_at(s, pos)
	return c == 9 || c == 10 || c == 11 || c == 12 || c == 13 || c == 32 || c == 0x85 || c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000
}

fn is_unicode_space_before(s string, end int) bool {
	c := rune_before(s, end)
	return c == 9 || c == 10 || c == 11 || c == 12 || c == 13 || c == 32 || c == 0x85 || c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000
}

fn utf8_len_at(s string, pos int) int {
	c := s[pos]
	if c < 0x80 {
		return 1
	} else if c < 0xe0 {
		return 2
	} else if c < 0xf0 {
		return 3
	}
	return 4
}

fn utf8_len_before(s string, end int) int {
	mut i := end - 1
	for i > 0 && s[i] & 0xc0 == 0x80 {
		i--
	}
	return end - i
}

fn rune_at(s string, pos int) u32 {
	c := s[pos]
	if c < 0x80 {
		return u32(c)
	} else if c < 0xe0 {
		return (u32(c & 0x1f) << 6) | u32(s[pos + 1] & 0x3f)
	} else if c < 0xf0 {
		return (u32(c & 0x0f) << 12) | (u32(s[pos + 1] & 0x3f) << 6) | u32(s[pos + 2] & 0x3f)
	}
	return (u32(c & 0x07) << 18) | (u32(s[pos + 1] & 0x3f) << 12) | (u32(s[pos + 2] & 0x3f) << 6) | u32(s[pos + 3] & 0x3f)
}

fn rune_before(s string, end int) u32 {
	mut i := end - 1
	for i > 0 && s[i] & 0xc0 == 0x80 {
		i--
	}
	return rune_at(s, i)
}

// match_url_at finds a URL starting at pos, returning its end index or -1.
// Mirrors the urlPattern regex scan.
fn match_url_at(s string, pos int) int {
	mut scheme_end := -1
	// Try scheme:// with maximal scheme-char run.
	mut j := pos
	for j < s.len {
		c := s[j]
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `+` || c == `-` || c == `.` {
			j++
		} else {
			break
		}
	}
	if j > pos && ((s[pos] >= `a` && s[pos] <= `z`) || (s[pos] >= `A` && s[pos] <= `Z`)) {
		candidate := s[pos..j].to_lower()
		if candidate in url_schemes && s[j..].starts_with('://') {
			scheme_end = j + 3
		}
	}
	mut start := -1
	if scheme_end >= 0 {
		start = pos
	} else if s[pos..].to_lower().starts_with('www.') && pos + 4 < s.len {
		c := s[pos + 4]
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_` {
			start = pos
			scheme_end = pos
		}
	}
	if start < 0 {
		return -1
	}
	mut k := scheme_end
	mut www_start := -1
	if k == pos && s[pos..].to_lower().starts_with('www.') {
		k = pos + 4
		www_start = pos
	}
	for k < s.len {
		c := s[k]
		if c == ` ` || c == `\t` || c == `\r` || c == `\n` || c == 0x0b || c == 0x0c || c == `<` || c == `"` {
			break
		}
		if k + 1 < s.len && s[k] == 0xc2 && s[k + 1] == 0xa0 {
			break
		}
		k++
	}
	if k == scheme_end {
		return -1
	}
	// www. matches need a character after the [a-z0-9_] class: the regex's
	// trailing run requires at least one more character.
	if www_start >= 0 && k <= www_start + 5 {
		return -1
	}
	return k
}

fn find_urls(s string) []int {
	mut out := []int{}
	mut i := 0
	for i < s.len {
		end := match_url_at(s, i)
		if end > i {
			out << i
			out << end
			i = end
		} else {
			i += utf8_len_at(s, i)
		}
	}
	return out
}

// match_email_at matches the emailPattern at pos, returning end or -1.
fn match_email_at(s string, pos int) int {
	if pos >= s.len {
		return -1
	}
	if !is_email_first(s[pos]) {
		return -1
	}
	mut i := pos + 1
	if i < s.len && s[i] == `.` {
		i++
	}
	for i < s.len && is_email_rest(s[i]) {
		i++
	}
	if i >= s.len || s[i] != `@` {
		return -1
	}
	i++
	mut labels := 0
	mut last_end := -1
	for {
		start := i
		for i < s.len && (is_alnum_byte(s[i]) || s[i] == `_` || s[i] == `-`) {
			i++
		}
		if i == start {
			// A trailing dot backtracks like the regex quantifier.
			if labels >= 2 {
				return last_end
			}
			return -1
		}
		labels++
		last_end = i
		if i < s.len && s[i] == `.` {
			i++
			continue
		}
		break
	}
	// Requires at least two labels ((?:\.[...])+ means 2+ total).
	if labels < 2 {
		return -1
	}
	return i
}

fn is_email_first(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_` || c == `.` || c == `!` || c == `#` || c == `$` || c == `%` || c == `+` || c == `-`
}

fn is_email_rest(c u8) bool {
	if is_email_first(c) || c == `%` {
		return true
	}
	return c == `&` || c == `'` || c == `*` || c == `/` || c == `=` || c == `?` || c == `^` || c == u8(0x60) || c == `{` || c == `|` || c == `}` || c == `~`
}

fn is_alnum_byte(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
}

// match_anchor_at matches ^<a\b.*?> (no newlines) at pos, returning end or -1.
fn match_anchor_at(s string, pos int) int {
	if pos + 2 >= s.len || s[pos] != `<` || (s[pos + 1] != `a` && s[pos + 1] != `A`) {
		return -1
	}
	c := s[pos + 2]
	if is_alnum_byte(c) || c == `_` {
		return -1
	}
	mut i := pos + 2
	for i < s.len {
		if s[i] == `>` {
			return i + 1
		}
		if s[i] == `\n` {
			return -1
		}
		i++
	}
	return -1
}

struct TagIndex {
mut:
	lts      []int
	gts      []int
	closes   []int
	anchors  [][]int
	dangling int
}

fn index_tags(s string) TagIndex {
	mut t := TagIndex{dangling: -1}
	mut unclosed := -1
	mut i := 0
	for i < s.len {
		if s[i] == `<` {
			t.lts << i
			if unclosed < 0 {
				unclosed = i
			}
			if i + 4 <= s.len && s[i..i + 4].to_lower() == '</a>' {
				t.closes << i
			}
			mut record := true
			if t.anchors.len > 0 && t.anchors[t.anchors.len - 1][1] > i {
				record = false
			}
			if record {
				end := match_anchor_at(s, i)
				if end > 0 {
					t.anchors << [i, end]
				}
			}
			i++
		} else if s[i] == `>` {
			t.gts << i
			unclosed = -1
			i++
		} else if s[i] == `\n` {
			if t.dangling < 0 && unclosed >= 0 && unclosed + 2 <= i {
				t.dangling = i
			}
			i++
		} else {
			i++
		}
	}
	return t
}

fn search_ints(xs []int, v int) int {
	mut lo := 0
	mut hi := xs.len
	for lo < hi {
		mid := (lo + hi) / 2
		if xs[mid] < v {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

fn (t TagIndex) linked(start int, end int) bool {
	mut open := t.dangling >= 0 && t.dangling < start
	mut last_gt := -1
	n := search_ints(t.gts, start)
	if n > 0 {
		last_gt = t.gts[n - 1]
	}
	m := search_ints(t.lts, last_gt + 1)
	if m < t.lts.len && t.lts[m] + 2 <= start {
		open = true
	}
	if open && t.gts.len > 0 && t.gts[t.gts.len - 1] >= end {
		return true
	}
	mut n2 := 0
	for n2 < t.anchors.len && t.anchors[n2][1] <= start {
		n2++
	}
	if n2 == 0 {
		return false
	}
	a := t.anchors[n2 - 1]
	c := search_ints(t.closes, a[1])
	return c == t.closes.len || t.closes[c] + 4 > start
}
