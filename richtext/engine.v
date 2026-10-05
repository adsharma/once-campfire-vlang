module richtext

import html

pub struct Mention {
pub mut:
	id     i64
	name   string
	title  string
	sgid   string
	path   string
	avatar string
}

pub struct Context {
pub mut:
	host    string
	resolve ?fn (string, bool) !(Mention, bool)
}

pub struct RichResult {
pub mut:
	errors       map[string]IError
	presentation string
	body_html    string
	plain        string
	filtered     string
	editable     string
	mentioned    []i64
}

const attribute_order = ['sgid', 'content-type', 'url', 'href', 'filename', 'filesize',
	'width', 'height', 'previewable', 'presentation', 'caption', 'content']

fn load_visit(n &html.Node) ! {
	for c in n.children() {
		load_visit(c)!
	}
	if n.typ != .element_node {
		return
	}
	if attr(n, 'data-trix-attachment') != '' {
		mut data := map[string]string{}
		for _, key in ['data-trix-attachment', 'data-trix-attributes'] {
			// Comment/parse errors are ignored like the Go port, but a
			// successfully decoded non-object is a missing Trix merge.
			parsed, merge_fail := ruby_json(attr(n, key))
			if merge_fail {
				return error('missing merge on Trix attributes')
			}
			for k, v in parsed {
				data[k] = v
			}
		}
		mut attrs := []html.Attribute{}
		for _, name in attribute_order {
			key := if name == 'content-type' { 'contentType' } else { name }
			if value := data[key] {
				attrs << html.Attribute{key: name, val: value}
			}
		}
		if attrs.len == 0 {
			if parent := n.parent {
				parent.remove_child(n)
			}
			return
		}
		n.set_data('action-text-attachment')
		n.set_attrs(attrs)
	}
	if n.data == 'action-text-attachment' {
		for c in n.children() {
			n.remove_child(c)
		}
	}
}

fn load(body string) !&html.Node {
	root := parse_rich(trim_controls(body))!
	load_visit(root)!
	galleries(root, false)
	return root
}

fn trim_controls(s string) string {
	return s.trim('\x00\t\n\x0b\x0c\r ')
}

// plain_text follows the same attachment and whitespace rules as process
// without rendering HTML variants that search-text callers do not need.
pub fn plain_text(body string, ctx Context) !string {
	root := load(body)!
	replace_attachments(root, ctx, true, 0)!
	return chomp(plain(root))
}

pub fn process(body string, ctx Context) !RichResult {
	return process_fields(body, ctx, true, true, true, true)
}

fn process_fields(body string, ctx Context, want_editable bool, want_display bool, want_body bool, want_mentions bool) !RichResult {
	mut result := RichResult{
		mentioned: []i64{}
		errors:    {}
	}
	if want_editable {
		result.editable = editable_inner(body, ctx) or {
			result.errors['editable'] = err
			''
		}
	}
	root := load(body) or {
		for _, field in ['plain', 'body_html', 'filtered', 'mentioned'] {
			result.errors[field] = err
		}
		return result
	}
	if want_display {
		plain_root := html.clone_node(root)
		replace_attachments(plain_root, ctx, true, 0) or {
			result.errors['plain'] = err
		}
		if 'plain' !in result.errors {
			result.plain = chomp(plain(plain_root))
		}
	}
	if want_body {
		rendered := html.clone_node(root)
		replace_attachments(rendered, ctx, false, 0) or {
			result.errors['body_html'] = err
		}
		if 'body_html' !in result.errors {
			galleries(rendered, true)
			rendered2 := parse_rich(serialize(rendered))!
			sanitize_dom(rendered2, 'action')
			result.body_html = '<div class="lexxy-content">\n  ' + serialize(rendered2) + '\n</div>\n'
		}
	}
	if want_display {
		filtered := html.clone_node(root)
		if 'plain' in result.errors {
			result.errors['filtered'] = result.errors['plain']
		} else {
			remove_solo_embed(filtered, ctx, result.plain)
			filter_tags(filtered)
			sanitize_dom(filtered, 'filter')
			filtered2 := parse_rich(trim_controls(serialize(filtered)))!
			result.filtered = serialize(filtered2)
			// Like the Go port, a filtered expansion failure only skips the
			// presentation without recording an error.
			mut expanded := true
			replace_attachments(filtered2, ctx, false, 0) or { expanded = false }
			if expanded {
				galleries(filtered2, true)
				filtered3 := parse_rich(serialize(filtered2))!
				sanitize_dom(filtered3, 'action')
				// Like the Go port, a presentation re-parse failure keeps an
				// empty presentation without recording an error.
				if presentation := parse_rich('<div class="lexxy-content">\n  ' + serialize(filtered3) + '\n</div>\n') {
					sanitize_dom(presentation, 'auto')
					result.presentation = autolink(serialize_presentation(presentation)) or { '' }
				}
			}
		}
	}
	if want_mentions {
		collect_mentions(root, ctx, mut result.mentioned)
	}
	return result
}

fn collect_mentions(n &html.Node, ctx Context, mut out []i64) {
	for c in n.children() {
		collect_mentions(c, ctx, mut out)
	}
	if n.data == 'action-text-attachment' && attr(n, 'sgid') != '' {
		if r := ctx.resolve {
			user, found := r(attr(n, 'sgid'), true) or { return }
			if found {
				mut dup := false
				for id in out {
					if id == user.id {
						dup = true
						break
					}
				}
				if !dup {
					out << user.id
				}
			}
		}
	}
}

// display renders message HTML and plain text without computing editor markup,
// API body HTML or mention recipients that the message template never reads.
pub fn display(body string, ctx Context) !RichResult {
	return process_fields(body, ctx, false, true, false, false)
}

pub fn editable(body string, ctx Context) !string {
	return editable_inner(body, ctx)
}

pub fn mention_ids(body string, ctx Context) ![]i64 {
	result := process_fields(body, ctx, false, false, false, true)!
	if err := result.errors['mentioned'] {
		return err
	}
	return result.mentioned
}

fn editable_visit(n &html.Node, ctx Context, pass int) ! {
	for c in n.children() {
		editable_visit(c, ctx, pass)!
	}
	if n.data != 'action-text-attachment' || n.parent == none {
		return
	}
	if pass == 1 && attr(n, 'url').trim_space() != '' {
		return
	}
	markup, ct := attachment(n, ctx, false, 0)!
	if markup == '☒' {
		if parent := n.parent {
			parent.remove_child(n)
		}
		return
	}
	if ct != 'application/vnd.campfire.mention' && !match_opengraph_type(ct) {
		return error('missing attachable_content_type')
	}
	set_attr(n, 'content-type', ct)
	if pass == 1 {
		set_attr(n, 'content', json_quote(markup))
	} else {
		set_attr(n, 'content', markup)
	}
}

fn editable_inner(body string, ctx Context) !string {
	mut root := parse_rich(trim_controls(body))!
	for pass in 0 .. 2 {
		if pass == 1 {
			root = parse_rich(serialize(root))!
		}
		editable_visit(root, ctx, pass)!
	}
	if serialize(root).trim_space() == '' {
		return ''
	}
	return serialize(root)
}

fn match_opengraph_type(ct string) bool {
	// Mirrors opengraphType: the dots are unescaped regex wildcards.
	needle := 'application/vnd.actiontext.opengraph-embed'
	if ct.len < needle.len {
		return false
	}
	for i in 0 .. ct.len - needle.len + 1 {
		mut ok := true
		for j in 0 .. needle.len {
			n := needle[j]
			if n != `.` && ct[i + j] != n {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

fn collect_embeds(n &html.Node, mut out []&html.Node) {
	for c in n.children() {
		collect_embeds(c, mut out)
	}
	if n.data == 'action-text-attachment' && match_opengraph_type(attr(n, 'content-type')) {
		out << n
	}
}

fn first_link_href(n &html.Node) string {
	if n.data == 'a' {
		return attr(n, 'href')
	}
	for c in n.children() {
		h := first_link_href(c)
		if h != '' {
			return h
		}
	}
	return ''
}

fn collect_divs(n &html.Node, mut out []&html.Node) {
	for c in n.children() {
		collect_divs(c, mut out)
	}
	if n.data == 'div' {
		out << n
	}
}

fn paragraph_has_attachment(n &html.Node) bool {
	if n.data == 'action-text-attachment' {
		return true
	}
	for c in n.children() {
		if paragraph_has_attachment(c) {
			return true
		}
	}
	return false
}

fn remove_empty_paragraphs(n &html.Node) {
	for c in n.children() {
		remove_empty_paragraphs(c)
	}
	if n.data == 'p' && !paragraph_has_attachment(n) {
		if parent := n.parent {
			parent.remove_child(n)
		}
	}
}

fn remove_solo_embed(root &html.Node, ctx Context, text string) {
	mut embeds := []&html.Node{}
	collect_embeds(root, mut embeds)
	if embeds.len != 1 {
		return
	}
	markup := embed_html(embeds[0], ctx) or { return }
	parsed := parse_rich(markup) or { return }
	href := first_link_href(parsed)
	if href == '' {
		return
	}
	if normalize_url(href) != normalize_url(text) {
		return
	}
	mut divs := []&html.Node{}
	collect_divs(root, mut divs)
	if divs.len > 0 {
		attachment_html := serialize(embeds[0])
		for _, div in divs {
			inner_html(div, attachment_html) or {}
		}
		return
	}
	remove_empty_paragraphs(root)
}

fn normalize_url(value string) string {
	if !value.contains('x.com') && !value.contains('twitter.com') {
		return value
	}
	host := url_host(value).to_lower()
	mut out := value
	if host == 'x.com' {
		out = value.replace('x.com', 'twitter.com')
	}
	if idx := out.index('?') {
		if idx >= 0 {
			out = out[..idx]
		}
	}
	return out
}

fn url_host(value string) string {
	mut rest := value
	if i := rest.index('://') {
		if i >= 0 {
			rest = rest[i + 3..]
		}
	}
	for i, c in rest.bytes() {
		if c == `/` || c == `?` || c == `#` {
			return rest[..i]
		}
	}
	return rest
}

fn replace_visit(n &html.Node, ctx Context, as_plain bool, depth int) ! {
	for c in n.children() {
		replace_visit(c, ctx, as_plain, depth)!
	}
	if n.data != 'action-text-attachment' || n.parent == none {
		return
	}
	content_val := attr(n, 'content')
	if content_val != '' {
		content := parse_rich(content_val)!
		sanitize_dom(content, 'action')
		sanitized := serialize(content)
		remove_attr(n, 'content')
		if sanitized.trim_space() != '' {
			set_attr(n, 'content', sanitized)
		}
	}
	markup, _ := attachment(n, ctx, as_plain, depth)!
	if as_plain {
		replace_node(n, markup)!
		return
	}
	mut attrs := []html.Attribute{}
	for _, key in attribute_order {
		for _, a in n.attr {
			if a.key == key {
				attrs << a
				break
			}
		}
	}
	if attrs.len == 0 {
		return error('missing attachment attributes')
	}
	full := html.new_node(.element_node, 'action-text-attachment')
	full.set_attrs(attrs)
	inner_html(full, markup)!
	pn := if _ := n.parent { 'hasparent' } else { 'NOPARENT' }
	replace_node(n, serialize(full))!
}

fn replace_attachments(root &html.Node, ctx Context, as_plain bool, depth int) ! {
	replace_visit(root, ctx, as_plain, depth)!
}

fn attachment(n &html.Node, ctx Context, as_plain bool, depth int) !(string, string) {
	ct := attr(n, 'content-type')
	caption := attr(n, 'caption')
	if match_opengraph_type(ct) {
		markup := embed_html(n, ctx)!
		if as_plain {
			return '', 'application/vnd.actiontext.opengraph-embed'
		}
		return markup, 'application/vnd.actiontext.opengraph-embed'
	}
	sgid_val := attr(n, 'sgid')
	if sgid_val != '' {
		if r := ctx.resolve {
			user, found := r(sgid_val, false)!
			if found {
				new_ct := 'application/vnd.campfire.mention'
				set_attr(n, 'content-type', new_ct)
				if as_plain {
					return '@' + user.name, new_ct
				}
				mut m := mention_html(user)
				if m.ends_with('\n') {
					m = m[..m.len - 1]
				}
				return m, new_ct
			}
		}
	}
	content := attr(n, 'content')
	if ct.contains('html') && content.trim_space() != '' {
		if depth >= 8 {
			return '', ct
		}
		nested := load(content)!
		if !as_plain {
			replace_attachments(nested, ctx, false, depth + 1)!
		}
		if as_plain {
			return serialize(nested), ct
		}
		sanitize_dom(nested, 'action')
		return '<figure class="attachment attachment--content">\n  ' + serialize(nested) + '\n\n</figure>',
			ct
	}
	src_val := attr(n, 'url')
	if src_val != '' && (ct.starts_with('image/') || ct == 'image' || ct.starts_with('video/') || ct == 'video') {
		video := ct.starts_with('video')
		if as_plain {
			mut label := caption
			if label == '' {
				if video {
					label = attr(n, 'filename')
					if label == '' {
						label = 'Video'
					}
				} else {
					label = 'Image'
				}
			}
			return '[' + label + ']', ct
		}
		mut size := ''
		for _, key in ['width', 'height'] {
			wh := attr(n, key)
			if wh != '' {
				size += ' ' + key + '="' + erb_escape(wh) + '"'
			}
		}
		if !src_val.starts_with('/') && !src_val.contains('://') && !src_val.starts_with('cid:') && !src_val.starts_with('data:') {
			return error('missing remote image asset')
		}
		mut result := ''
		if video {
			result = '<figure class="attachment attachment--preview attachment--video">' + '\n  <video controls="controls"' + size + '>\n    <source src="' + erb_escape(src_val) + '" type="' + erb_escape(ct) + '">\n</video>'
		} else {
			result = '<figure class="attachment attachment--preview">' + '\n  <img' + size + ' src="' + erb_escape(src_val) + '" />' + '\n'
		}
		if caption != '' {
			result += '    <figcaption class="attachment__caption">\n      ' + erb_escape(caption) + '\n    </figcaption>\n'
		}
		return result + '</figure>', ct
	}
	if as_plain {
		return caption, ct
	}
	return '☒', ct
}

fn mention_html(user Mention) string {
	return '<span class="mention" sgid="' + erb_escape(user.sgid) + '"><a title="' + erb_escape(user.title) + '" class="btn avatar" data-turbo-frame="_top" href="' + erb_escape(user.path) + '"><img aria-hidden="true" src="' + erb_escape(user.avatar) + '" width="48" height="48" /></a> ' + erb_escape(user.name) + '</span>\n'
}

fn external_url(value string, host string) !string {
	if value.trim_space() == '' {
		return ''
	}
	before_q := value.split('?')[0]
	for c in before_q.bytes() {
		if c == `"` || c == `<` || c == `>` || c == ` ` || c == `\t` || c == `\r` || c == `\n` {
			return ''
		}
	}
	scheme := url_scheme(value)
	if scheme == 'mailto' {
		opaque := value[7..]
		if !opaque.contains('@') {
			return error('URI invalid component')
		}
		return ''
	}
	if scheme != 'http' && scheme != 'https' {
		return ''
	}
	mut name := url_host(value)
	if name == '' || name.contains('%') || !name.contains('.') {
		return ''
	}
	name = name.trim_right('.')
	if name == '' {
		return error('missing host label')
	}
	dot := name.last_index('.') or { -1 }
	label := if dot >= 0 { name[dot + 1..] } else { name }
	mut has_alpha := false
	for c in label.bytes() {
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) {
			has_alpha = true
			break
		}
	}
	if !has_alpha || label.to_lower().starts_with('0x') || name.to_lower() == host.trim_right('.').to_lower() {
		return ''
	}
	return value
}

fn url_scheme(value string) string {
	i := value.index(':') or { return '' }
	head := value[..i]
	if head.len == 0 {
		return ''
	}
	if !((head[0] >= `a` && head[0] <= `z`) || (head[0] >= `A` && head[0] <= `Z`)) {
		return ''
	}
	for c in head.bytes() {
		if !((c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `+` || c == `-` || c == `.`) {
			return ''
		}
	}
	return head.to_lower()
}

struct OgEmbed {
mut:
	href        string
	src         string
	title       string
	description string
}

fn og_visit(n &html.Node, mut og OgEmbed) {
	for c in n.children() {
		og_visit(c, mut og)
	}
	classes := words_set(attr(n, 'class'))
	if 'og-embed__title' in classes {
		og.title = plain(n).trim_space()
		og.href = first_link_href(n)
	}
	if 'og-embed__description' in classes {
		og.description = plain(n).trim_space()
	}
	if 'og-embed__image' in classes {
		img := first_img_src(n)
		if img != '' {
			og.src = img
		}
	}
}

fn first_img_src(n &html.Node) string {
	if n.data == 'img' {
		return attr(n, 'src')
	}
	for c in n.children() {
		s := first_img_src(c)
		if s != '' {
			return s
		}
	}
	return ''
}

fn embed_html(n &html.Node, ctx Context) !string {
	mut og := OgEmbed{
		href:  attr(n, 'href')
		src:   attr(n, 'url')
		title: attr(n, 'filename')
		description: attr(n, 'caption')
	}
	if og.title.trim_space() == '' {
		og.href = ''
		og.src = ''
		og.title = ''
		og.description = ''
		root := parse_rich(attr(n, 'content'))!
		og_visit(root, mut og)
	}
	og.href = external_url(og.href, ctx.host) or { return err }
	og.src = external_url(og.src, ctx.host) or { return err }
	title := erb_escape(truncate_runes(og.title, 280))
	description := erb_escape(truncate_runes(og.description, 560))
	mut heading := title
	if og.href != '' {
		if heading == '' {
			heading = erb_escape(og.href)
		}
		heading = '<a rel="noreferrer" target="_blank" href="' + erb_escape(og.href) + '">' + heading + '</a>'
	}
	mut avatar_class := ''
	if og.src.starts_with('https://pbs.twimg.com/profile_images') {
		avatar_class = 'og-embed--twitter-avatar'
	}
	mut result := '<figure class="attachment attachment--content attachment--og">\n  <actiontext-opengraph-embed>\n    <div class="og-embed gap ' + avatar_class + '">\n      <div class="og-embed__content">\n        <div class="og-embed__title">\n          ' + heading + '\n        </div>\n        <div class="og-embed__description">' + description + '</div>\n      </div>\n'
	if og.src != '' {
		result += '        <div class="og-embed__image">\n          <img src="' + erb_escape(og.src) + '" class="image center" alt="">\n        </div>\n'
	}
	return result + '    </div>\n  </actiontext-opengraph-embed>\n</figure>'
}

fn truncate_runes(s string, n int) string {
	r := s.runes()
	if r.len > n {
		return r[..n - 1].string() + '…'
	}
	return s
}

fn erb_escape(s string) string {
	return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;').replace("'", '&#39;')
}

fn galleries(root &html.Node, render_gallery bool) {
	for c in root.children() {
		galleries(c, render_gallery)
	}
	if root.data != 'div' {
		return
	}
	mut members := []&html.Node{}
	for _, c in children(root) {
		if c.typ == .text_node && c.data.trim('\n ') == '' {
			continue
		}
		if c.data != 'action-text-attachment' || attr(c, 'presentation') != 'gallery' {
			return
		}
		members << c
	}
	if members.len < 2 {
		return
	}
	root.set_attrs([])
	if render_gallery {
		set_attr(root, 'class', 'attachment-gallery attachment-gallery--${members.len}')
		mut out := '\n  '
		for _, c in members {
			out += serialize(c)
		}
		out += '\n'
		inner_html(root, out) or {}
	}
}

// ruby_json strips JSON comments and decodes Trix attributes. It returns
// the attributes plus whether a decoded non-object requires a merge failure.
fn ruby_json(s string) (map[string]string, bool) {
	cleaned := strip_json_comments(s) or { return map[string]string{}, false }
	t := cleaned.bytestr().trim_space()
	if t == '' || t == 'null' || t == 'true' || t == 'false' {
		return map[string]string{}, false
	}
	if !t.starts_with('{') {
		return map[string]string{}, true
	}
	m := parse_json_object(t) or { return map[string]string{}, false }
	return m, false
}

fn strip_json_comments(s string) ![]u8 {
	mut out := []u8{cap: s.len}
	mut quoted := false
	mut i := 0
	for i < s.len {
		c := s[i]
		if quoted {
			out << c
			if c == `\\` && i + 1 < s.len {
				i++
				out << s[i]
			} else if c == `"` {
				quoted = false
			}
			i++
			continue
		}
		if c == `"` {
			quoted = true
		}
		if c == `/` && i + 1 < s.len {
			if s[i + 1] == `*` {
				end := s[i + 2..].index('*/') or { return error('unterminated JSON comment') }
				i += end + 4
				out << ` `
				continue
			}
			if s[i + 1] == `/` {
				for i + 1 < s.len && s[i + 1] != `\n` {
					i++
				}
				out << ` `
				continue
			}
		}
		out << c
		i++
	}
	return out
}

fn skip_ws_json(s string, i int) int {
	mut j := i
	for j < s.len && (s[j] == ` ` || s[j] == `\t` || s[j] == `\n` || s[j] == `\r`) {
		j++
	}
	return j
}

// parse_json_object parses a flat JSON object with scalar values.
fn parse_json_object(s string) !map[string]string {
	t := s.trim_space()
	mut m := map[string]string{}
	mut i := 1
	for {
		i = skip_ws_json(t, i)
		if i < t.len && t[i] == `}` {
			return m
		}
		if i >= t.len || t[i] != `"` {
			return error('bad trix json')
		}
		key, ni := parse_json_string(t, i)!
		i = ni
		i = skip_ws_json(t, i)
		if i >= t.len || t[i] != `:` {
			return error('bad trix json')
		}
		i++
		i = skip_ws_json(t, i)
		if i >= t.len {
			return error('bad trix json')
		}
		if t[i] == `"` {
			val, ni2 := parse_json_string(t, i)!
			m[key] = val
			i = ni2
		} else if t[i..].starts_with('null') {
			m[key] = ''
			i += 4
		} else if t[i..].starts_with('true') {
			m[key] = 'true'
			i += 4
		} else if t[i..].starts_with('false') {
			m[key] = 'false'
			i += 5
		} else {
			start := i
			for i < t.len && t[i] != `,` && t[i] != `}` {
				i++
			}
			m[key] = t[start..i].trim_space()
		}
		i = skip_ws_json(t, i)
		if i < t.len && t[i] == `,` {
			i++
		}
	}
	return m
}

fn parse_json_string(s string, pos int) !(string, int) {
	mut i := pos + 1
	mut out := []u8{}
	for i < s.len {
		c := s[i]
		if c == `"` {
			return out.bytestr(), i + 1
		}
		if c == `\\` && i + 1 < s.len {
			nxt := s[i + 1]
			if nxt == `u` && i + 5 < s.len {
				cp := hex4(s[i + 2..i + 6])!
				append_rune(mut out, u32(cp))
				i += 6
				continue
			}
			if nxt == `n` {
				out << `\n`
			} else if nxt == `t` {
				out << `\t`
			} else if nxt == `r` {
				out << `\r`
			} else {
				out << nxt
			}
			i += 2
			continue
		}
		out << c
		i++
	}
	return error('unterminated string')
}

fn hex4(s string) !int {
	if s.len != 4 {
		return error('bad hex')
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
			return error('bad hex')
		}
	}
	return n
}

fn json_quote(s string) string {
	// Like Go's encoding/json with HTML escaping: <, > and & become \u escapes.
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
		} else if c == `<` {
			out << '\\u003c'.bytes()
		} else if c == `>` {
			out << '\\u003e'.bytes()
		} else if c == `&` {
			out << '\\u0026'.bytes()
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

// render is the context-free entry point for messages without attachments.
pub fn render(body string) (string, string) {
	result := process_fields(body, Context{}, false, true, false, false) or {
		return '', ''
	}
	return result.presentation, result.plain
}

// canonical mirrors assignment to an Action Text body.
pub fn canonical(body string) string {
	root := load(body) or { return body }
	return serialize(root)
}

// strip_tags matches Rails' FullSanitizer followed by the default sanitizer.
pub fn strip_tags(body string) !string {
	root := parse_rich(body)!
	mut text := []u8{}
	collect_text(root, mut text)
	return sanitize_string(escape_text(text.bytestr()))
}

fn collect_text(n &html.Node, mut out []u8) {
	if n.typ == .text_node {
		out << n.data.bytes()
	}
	for c in n.children() {
		collect_text(c, mut out)
	}
}
