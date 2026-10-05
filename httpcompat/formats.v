// Package httpcompat implements Rails HTTP contracts.
module httpcompat

import math

pub struct Mime {
pub:
	symbol     string
	typ        string
	synonyms   []string
	extensions []string
}

const mime_types = [
	Mime{'html', 'text/html', ['application/xhtml+xml'], ['xhtml']},
	Mime{'text', 'text/plain', [], ['txt']},
	Mime{'js', 'text/javascript', ['application/javascript', 'application/x-javascript'], []},
	Mime{'css', 'text/css', [], []},
	Mime{'ics', 'text/calendar', [], []},
	Mime{'csv', 'text/csv', [], []},
	Mime{'vcf', 'text/vcard', [], []},
	Mime{'vtt', 'text/vtt', [], ['vtt']},
	Mime{'md', 'text/markdown', [], ['md', 'markdown']},
	Mime{'png', 'image/png', [], ['png']},
	Mime{'jpeg', 'image/jpeg', [], ['jpg', 'jpeg', 'jpe', 'pjpeg']},
	Mime{'gif', 'image/gif', [], ['gif']},
	Mime{'bmp', 'image/bmp', [], ['bmp']},
	Mime{'tiff', 'image/tiff', [], ['tif', 'tiff']},
	Mime{'svg', 'image/svg+xml', [], []},
	Mime{'webp', 'image/webp', [], ['webp']},
	Mime{'mpeg', 'video/mpeg', [], ['mpg', 'mpeg', 'mpe']},
	Mime{'mp3', 'audio/mpeg', [], ['mp1', 'mp2', 'mp3']},
	Mime{'ogg', 'audio/ogg', [], ['oga', 'ogg', 'spx', 'opus']},
	Mime{'m4a', 'audio/aac', ['audio/mp4'], ['m4a', 'mpg4', 'aac']},
	Mime{'webm', 'video/webm', [], ['webm']},
	Mime{'mp4', 'video/mp4', [], ['mp4', 'm4v']},
	Mime{'otf', 'font/otf', [], ['otf']},
	Mime{'ttf', 'font/ttf', [], ['ttf']},
	Mime{'woff', 'font/woff', [], ['woff']},
	Mime{'woff2', 'font/woff2', [], ['woff2']},
	Mime{'xml', 'application/xml', ['text/xml', 'application/x-xml'], []},
	Mime{'rss', 'application/rss+xml', [], []},
	Mime{'atom', 'application/atom+xml', [], []},
	Mime{'yaml', 'application/x-yaml', ['text/yaml'], ['yml', 'yaml']},
	Mime{'multipart_form', 'multipart/form-data', [], []},
	Mime{'url_encoded_form', 'application/x-www-form-urlencoded', [], []},
	Mime{'json', 'application/json', ['text/x-json', 'application/jsonrequest', 'application/problem+json'], []},
	Mime{'pdf', 'application/pdf', [], ['pdf']},
	Mime{'zip', 'application/zip', [], ['zip']},
	Mime{'gzip', 'application/gzip', ['application/x-gzip'], ['gz']},
	Mime{'turbo_stream', 'text/vnd.turbo-stream.html', [], []},
]

fn extension(value string) string {
	for m in mime_types {
		if m.symbol == value || value in m.extensions {
			return m.symbol
		}
	}
	return ''
}

fn is_mime_name(s string) bool {
	if s.len == 0 || s.len > 127 {
		return false
	}
	first := s[0]
	if !((first >= `a` && first <= `z`) || (first >= `A` && first <= `Z`) || (first >= `0` && first <= `9`)) {
		return false
	}
	for c in s.bytes() {
		ok := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `!` || c == `#` || c == `$` || c == `&` || c == `-` || c == `^` || c == `_` || c == `.` || c == `+`
		if !ok {
			return false
		}
	}
	return true
}

fn lookup(value string) !string {
	v := value.split(';')[0].trim(' \t\r\n\x0b\x0c')
	if v == '*/*' {
		return v
	}
	for m in mime_types {
		if m.typ == v || v in m.synonyms {
			return m.symbol
		}
	}
	parts := v.split('/')
	if parts.len != 2 || !is_mime_name(parts[0]) || (parts[1] != '*' && !is_mime_name(parts[1])) {
		return error('invalid MIME type')
	}
	return ''
}

fn expand(value string) []string {
	mut prefix := ''
	for p in ['text/*', 'application/*'] {
		if value.starts_with(p) {
			prefix = p[..p.len - 1]
		}
	}
	if prefix == '' {
		return []
	}
	mut out := []string{}
	for m in mime_types {
		mut matched := m.typ.contains(prefix)
		for syn in m.synonyms {
			matched = matched || syn.contains(prefix)
		}
		if matched {
			out << m.typ
		}
	}
	return out
}

fn accept_items(value string) []string {
	mut items := []string{}
	mut i := 0
	for i < value.len {
		if value[i] == `,` || value[i] == ` ` || value[i] == `\t` || value[i] == `\r` || value[i] == `\n` || value[i] == 11 || value[i] == 12 || value[i] == `"` {
			i++
			continue
		}
		start := i
		i++
		for i < value.len && value[i] != `,` {
			if value[i] == `"` {
				end := value[i + 1..].index('"') or { -1 }
				if end < 0 {
					break
				}
				i += end + 2
			} else {
				i++
			}
		}
		items << value[start..i]
	}
	return items
}

pub fn parse_accept(value string) ![]string {
	if !value.contains(',') {
		mut v := value
		if loc := q_sep_index(value) {
			v = value[..loc]
		}
		if v.trim_space() == '' {
			return []
		}
		expanded := expand(v)
		if expanded.len > 0 {
			mut out := []string{}
			for x in expanded {
				symbol := lookup(x) or { '' }
				out << symbol
			}
			return out
		}
		symbol := lookup(v)!
		if symbol == '' {
			return []
		}
		return [symbol]
	}
	mut names := []string{}
	mut qs := []f64{}
	for value_item in accept_items(value) {
		mut fields := split_q_all(value_item)
		for fields.len > 0 && fields[fields.len - 1] == '' {
			fields = fields[..fields.len - 1]
		}
		if fields.len == 0 {
			continue
		}
		name := fields[0].trim_space()
		if name == '' {
			continue
		}
		mut expanded := expand(name)
		if expanded.len == 0 {
			expanded = [name]
		}
		for n in expanded {
			mut q := 1.0
			if fields.len > 1 {
				q = ruby_float(fields[1])
			} else if n == '*/*' {
				q = 0
			}
			names << n
			qs << math.trunc(q * 100)
		}
	}
	// Stable sort by q descending.
	mut order := []int{len: names.len, init: index}
	for i in 0 .. order.len {
		order[i] = i
	}
	// Insertion sort keeps equal-q order stable.
	for i in 1 .. order.len {
		j_val := order[i]
		mut j := i
		for j > 0 && qs[order[j - 1]] < qs[j_val] {
			order[j] = order[j - 1]
			j--
		}
		order[j] = j_val
	}
	mut items := []string{}
	mut item_q := []f64{}
	for o in order {
		items << names[o]
		item_q << qs[o]
	}
	find := fn (xs []string, name string) int {
		for i, x in xs {
			if x == name {
				return i
			}
		}
		return -1
	}
	text := find(items, 'text/xml')
	app := find(items, 'application/xml')
	if text >= 0 && app >= 0 {
		if item_q[text] > item_q[app] {
			item_q[app] = item_q[text]
		}
		if app > text {
			tmp := items[app]
			items[app] = items[text]
			items[text] = tmp
			qtmp := item_q[app]
			item_q[app] = item_q[text]
			item_q[text] = qtmp
			items.delete(app)
			item_q.delete(app)
		} else {
			items.delete(text)
			item_q.delete(text)
		}
	} else if text >= 0 {
		items[text] = 'application/xml'
	}
	app2 := find(items, 'application/xml')
	if app2 >= 0 {
		q := item_q[app2]
		mut ai := app2
		mut i := app2
		for i < items.len && item_q[i] >= q {
			if items[i].ends_with('+xml') {
				items[ai], items[i] = items[i], items[ai]
				ai = i
			}
			i++
		}
	}
	mut out := []string{}
	for _, item in items {
		symbol := lookup(item)!
		if symbol != '' && symbol !in out {
			out << symbol
		}
	}
	return out
}

// q_sep_index finds `;\s*q="` like the Go qSeparator regex.
fn q_sep_index(value string) ?int {
	mut i := 0
	for i < value.len {
		if value[i] == `;` {
			mut j := i + 1
			for j < value.len && (value[j] == ` ` || value[j] == `\t`) {
				j++
			}
			if value[j..].starts_with('q="') || value[j..].starts_with('q=') {
				return i
			}
		}
		i++
	}
	return none
}

// split_q_all splits an accept item on q separators.
fn split_q_all(value string) []string {
	mut parts := []string{}
	mut start := 0
	mut i := 0
	for i < value.len {
		if value[i] == `;` {
			mut j := i + 1
			for j < value.len && (value[j] == ` ` || value[j] == `\t`) {
				j++
			}
			if value[j..].starts_with('q="') || value[j..].starts_with('q=') {
				parts << value[start..i]
				if value[j + 1] == `"` {
					parts << value[j + 3..]
				} else {
					parts << value[j + 2..]
				}
				return parts
			}
		}
		i++
	}
	parts << value[start..]
	return parts
}

pub struct FormatInput {
pub mut:
	format       ?string
	accept       string
	content_type string
	path         string
	xhr          bool
}

pub fn (i FormatInput) uses_accept() bool {
	present := i.accept.trim_space() != ''
	compact := i.accept.replace(' ', '').replace('\t', '').replace('\r', '').replace('\n', '').replace('\x0b', '').replace('\x0c', '')
	browser := compact.contains(',*/*') || compact.contains('*/*,')
	return i.format == none && ((i.xhr && (present || i.content_type != '')) || (present && !browser))
}

pub fn formats(i FormatInput) ![]string {
	if f := i.format {
		fmt := extension(f)
		if fmt != '' {
			return [fmt]
		}
		return []
	}
	if i.uses_accept() {
		v := i.accept.trim_space()
		if v != '' {
			return parse_accept(v)
		}
		ct := i.content_type.split(';')[0].split(',')[0].trim_space().to_lower()
		if ct == '' {
			return []
		}
		symbol := lookup(ct)!
		if symbol == '' {
			return []
		}
		return [symbol]
	}
	if dot := i.path.last_index('.') {
		if dot >= 0 {
			fmt2 := extension(i.path[dot + 1..])
			if fmt2 != '' {
				return [fmt2]
			}
		}
	}
	if i.xhr {
		return ['js']
	}
	return ['html']
}

pub fn negotiate(input FormatInput, available ...string) !string {
	fmts := formats(input)!
	for f in fmts {
		if f == '*/*' && available.len > 0 {
			return available[0]
		}
		if f in available {
			return f
		}
	}
	if '*/*' in available && fmts.len > 0 {
		return fmts[0]
	}
	return ''
}

fn is_hex_digit(c u8) bool {
	return (c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}

fn ruby_float(value string) f64 {
	mut v := value.trim_left(' \t\r\n\x0b\x0c')
	// Remove underscores between digits like Ruby.
	mut out := []u8{cap: v.len}
	bs := v.bytes()
	for i in 0 .. bs.len {
		if bs[i] == `_` && i > 0 && i + 1 < bs.len && bs[i - 1] >= `0` && bs[i - 1] <= `9` && bs[i + 1] >= `0` && bs[i + 1] <= `9` {
			continue
		}
		out << bs[i]
	}
	v = out.bytestr()
	if v.starts_with('+0x') || v.starts_with('+0X') || v.starts_with('-0x') || v.starts_with('-0X') {
		mut hexpart := v
		mut neg := false
		if hexpart[0] == `+` || hexpart[0] == `-` {
			neg = hexpart[0] == `-`
			hexpart = hexpart[1..]
		}
		hexpart = hexpart[2..]
		mut n := u64(0)
		mut ok := hexpart.len > 0
		for c in hexpart.bytes() {
			if !is_hex_digit(c) {
				break
			}
			d := if c >= `0` && c <= `9` {
				u64(c - `0`)
			} else if c >= `a` {
				u64(c - `a` + 10)
			} else {
				u64(c - `A` + 10)
			}
			n = n * 16 + d
		}
		if ok {
			if neg {
				return -f64(n)
			}
			return f64(n)
		}
	}
	// Leading numeric prefix like Go's numberPrefix regex.
	mut i := 0
	if i < v.len && (v[i] == `+` || v[i] == `-`) {
		i++
	}
	mut digits := 0
	for i < v.len && v[i] >= `0` && v[i] <= `9` {
		i++
		digits++
	}
	if i < v.len && v[i] == `.` {
		i++
		for i < v.len && v[i] >= `0` && v[i] <= `9` {
			i++
			digits++
		}
	}
	if digits == 0 {
		return 0
	}
	if i < v.len && (v[i] == `e` || v[i] == `E`) {
		mut j := i + 1
		if j < v.len && (v[j] == `+` || v[j] == `-`) {
			j++
		}
		mut k := j
		for k < v.len && v[k] >= `0` && v[k] <= `9` {
			k++
		}
		if k > j {
			i = k
		}
	}
	return v[..i].f64()
}
