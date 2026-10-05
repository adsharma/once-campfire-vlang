module html

// reset_mode recomputes the insertion mode from the stack after table/select
// closes, mirroring the fork's resetInsertionMode for the modes we track.
fn (mut p Parser) reset_mode() {
	p.mode = 'body'
	for i := p.stack.len - 1; i >= 0; i-- {
		n := p.stack[i]
		if n.namespace != '' {
			continue
		}
		match n.data {
			'select' {
				p.mode = 'select'
				return
			}
			'td', 'th' {
				p.mode = 'cell'
				return
			}
			'tr' {
				p.mode = 'row'
				return
			}
			'tbody', 'thead', 'tfoot' {
				p.mode = 'table_body'
				return
			}
			'table' {
				p.mode = 'table'
				return
			}
			'caption' {
				p.mode = 'caption'
				return
			}
			'colgroup' {
				p.mode = 'colgroup'
				return
			}
			else {}
		}
	}
}

fn (mut p Parser) clear_active_formatting() {
	p.formatting.clear()
}

fn (mut p Parser) clear_to_marker() {
	for p.formatting.len > 0 {
		is_marker := p.formatting[p.formatting.len - 1] == none
		p.formatting.pop()
		if is_marker {
			break
		}
	}
}

const foreign_breakout = {
	'b': true, 'big': true, 'blockquote': true, 'body': true, 'br': true, 'center': true,
	'code': true, 'dd': true, 'div': true, 'dl': true, 'dt': true, 'em': true,
	'embed': true, 'h1': true, 'h2': true, 'h3': true, 'h4': true, 'h5': true,
	'h6': true, 'head': true, 'hr': true, 'i': true, 'img': true, 'li': true,
	'listing': true, 'menu': true, 'meta': true, 'nobr': true, 'ol': true, 'p': true,
	'pre': true, 'ruby': true, 's': true, 'small': true, 'span': true, 'strong': true,
	'strike': true, 'sub': true, 'sup': true, 'table': true, 'tt': true, 'u': true,
	'ul': true, 'var': true,
}

fn is_math_integration(n &Node) bool {
	if n.namespace != 'math' {
		return false
	}
	return n.data in ['mi', 'mo', 'mn', 'ms', 'mtext']
}

// in_foreign mirrors the fork's inForeignContent for fragment parsing.
fn (mut p Parser) in_foreign(tok Token) bool {
	top := p.top() or { return false }
	if top.namespace == '' {
		return false
	}
	if top.namespace == 'math' && top.data == 'annotation-xml' && tok.typ == .start_tag_token && tok.data == 'svg' {
		return false
	}
	if is_math_integration(top) {
		if tok.typ == .start_tag_token && tok.data != 'mglyph' && tok.data != 'malignmark' {
			return false
		}
		if tok.typ == .text_token {
			return false
		}
	}
	if is_integration_point(top) && (tok.typ == .start_tag_token || tok.typ == .text_token) {
		return false
	}
	if tok.typ == .error_token {
		return false
	}
	return true
}

// foreign_token implements the in-foreign-content rules (subset).
fn (mut p Parser) foreign_token(tok Token) {
	match tok.typ {
		.text_token {
			p.insert_text_raw(tok.data.replace('\x00', '�').replace('\ue000', '�'))
		}
		.comment_token {
			p.skip_leading_newline = false
			comment := new_node(.comment_node, tok.data)
			parent := p.top() or { p.root }
			parent.append_child(comment)
		}
		.doctype_token {
			p.skip_leading_newline = false
		}
		.start_tag_token, .self_closing_tag_token {
			tag := tok.data
			if tag in foreign_breakout || (tag == 'font' && tok_has_font_attr(tok)) {
				p.breakout_foreign()
				p.start_tag(tok)
				if tok.typ == .self_closing_tag_token {
					p.pop_self_closing(tok.data)
				}
				return
			}
			mut ns := ''
			if top := p.top() {
				ns = top.namespace
			}
			p.insert_element(tag, tok.attrs, false)
			if inserted := p.top() {
				inserted.set_namespace(ns)
			}
			// Foreign void elements stay open; only self-closing pops.
			if tok.typ == .self_closing_tag_token {
				p.stack.pop()
			}
		}
		.end_tag_token {
			if tok.data == 'br' {
				p.breakout_foreign()
				p.body_start(Token{typ: .start_tag_token, data: 'br'})
				return
			}
			// Pop toward the match; if a non-foreign node intervenes, use
			// the body rules instead.
			for i := p.stack.len - 1; i >= 0; i-- {
				n := p.stack[i]
				if n.data == tok.data && n.namespace != '' {
					for p.stack.len > i {
						p.stack.pop()
					}
					return
				}
				if n.namespace == '' || is_integration_point(n) {
					p.body_end(tok.data)
					return
				}
			}
		}
		.error_token {}
	}
}

fn tok_has_attr(tok Token, key string, want string) bool {
	for a in tok.attrs {
		if a.key == key && a.val.to_lower() == want {
			return true
		}
	}
	return false
}

fn tok_has_font_attr(tok Token) bool {
	for a in tok.attrs {
		if a.key == 'color' || a.key == 'face' || a.key == 'size' {
			return true
		}
	}
	return false
}

// breakout_foreign pops back to HTML content for breakout elements.
fn (mut p Parser) breakout_foreign() {
	for p.stack.len > 1 {
		top := p.stack[p.stack.len - 1]
		if top.namespace == '' || is_integration_point(top) {
			break
		}
		p.stack.pop()
	}
}

fn (mut p Parser) pop_self_closing(tag string) {
	if top := p.top() {
		if top.data == tag && top.children().len == 0 {
			p.stack.pop()
		}
	}
}

// process_token routes a token through the current insertion mode.
fn (mut p Parser) process_token(tok Token) ! {
	p.tok.set_allow_cdata(p.foreign_cdata())
	// Like the fork, table text tokens skip the depth check: fostered
	// formatting reconstruction may grow the stack without bound here.
	skip_depth := tok.typ == .text_token && p.in_table_text_context()
	if p.in_foreign(tok) {
		p.foreign_token(tok)
		if !skip_depth {
			p.check_depth()!
		}
		return
	}
	match tok.typ {
		.text_token {
			if p.skip_leading_newline {
				p.skip_leading_newline = false
				if top := p.top() {
					if top.namespace == '' && (top.data == 'pre' || top.data == 'listing') && top.first_child == none && tok.data.starts_with('\n') {
						p.table_text(tok.data[1..])
						return
					}
				}
			}
			p.table_text(tok.data)
		}
		.comment_token {
			p.skip_leading_newline = false
			comment := new_node(.comment_node, tok.data)
			parent := p.top() or { p.root }
			parent.append_child(comment)
		}
		.doctype_token {
			p.skip_leading_newline = false
		}
		.start_tag_token, .self_closing_tag_token {
			p.skip_leading_newline = false
			p.start_tag(tok)
			if tok.typ == .self_closing_tag_token {
				p.pop_self_closing(tok.data)
			}
		}
		.end_tag_token {
			p.skip_leading_newline = false
			p.end_tag(tok.data)
		}
		.error_token {}
	}
	if !skip_depth {
		p.check_depth()!
	}
}

fn (mut p Parser) foreign_cdata() bool {
	top := p.top() or { return false }
	return top.namespace != ''
}

fn (mut p Parser) check_depth() ! {
	if p.stack.len > 401 {
			return error('html: tree depth exceeds 400')
	}
}

// table_text handles character tokens with the table whitespace rules.
fn (mut p Parser) table_text(data string) {
	if p.in_table_text_context() {
		if is_all_space(data) {
			p.insert_text_raw(data)
		} else {
			clean := data.replace('\x00', '').replace('\ue000', '')
			if clean == '' {
				return
			}
			p.foster_all = true
			p.reconstruct_formatting()
			p.foster_all = false
			p.foster_text(clean)
		}
		return
	}
	p.insert_text(data)
}

// insert_text_raw appends text to the current node, merging runs.
fn (mut p Parser) insert_text_raw(raw string) {
	data := raw.replace('\ue000', '�')
	if data == '' {
		return
	}
	parent := p.top() or { p.root }
	if mut last := parent.last_child {
		if last.typ == .text_node {
			last.data += data
			return
		}
	}
	parent.append_child(new_node(.text_node, data))
}

fn (mut p Parser) foster_text(data string) {
	if data == '' {
		return
	}
	// Like the fork's shouldFosterParent, fostering applies only when the
	// current top is table-ish; reconstructed formatting receives the text.
	if p.in_table_text_context() {
		node := new_node(.text_node, data)
		p.foster_append(node)
		return
	}
	p.insert_text_raw(data)
}

fn (mut p Parser) start_tag(tok Token) {
	if p.in_select() {
		p.select_start(tok)
		return
	}
	match p.mode {
		'table' {
			p.table_start(tok)
		}
		'table_body' {
			p.table_body_start(tok)
		}
		'row' {
			p.row_start(tok)
		}
		'cell' {
			p.cell_start(tok)
		}
		'caption' {
			p.caption_start(tok)
		}
		'colgroup' {
			p.colgroup_start(tok)
		}
		else {
			p.body_start(tok)
		}
	}
}

fn (mut p Parser) end_tag(tag string) {
	if p.in_select() && tag != 'select' {
		p.select_end(tag)
		return
	}
	match p.mode {
		'table' {
			p.table_end(tag)
		}
		'table_body' {
			p.table_body_end(tag)
		}
		'row' {
			p.row_end(tag)
		}
		'cell' {
			p.cell_end(tag)
		}
		'caption' {
			p.caption_end(tag)
		}
		'colgroup' {
			p.colgroup_end(tag)
		}
		else {
			p.body_end(tag)
		}
	}
}

// table_start implements the in-table start-tag rules.
fn (mut p Parser) table_start(tok Token) {
	tag := tok.data
	match tag {
		'caption' {
			p.clear_to_table_context()
			p.formatting << none
			p.insert_element(tag, tok.attrs, false)
			p.mode = 'caption'
		}
		'colgroup' {
			p.clear_to_table_context()
			p.insert_element(tag, tok.attrs, false)
			p.mode = 'colgroup'
		}
		'col' {
			p.clear_to_table_context()
			p.insert_element('colgroup', [], false)
			p.mode = 'colgroup'
			p.insert_element('col', tok.attrs, false)
			p.stack.pop()
		}
		'tbody', 'tfoot', 'thead' {
			p.clear_to_table_context()
			p.insert_element(tag, tok.attrs, false)
			p.mode = 'table_body'
		}
		'td', 'th', 'tr' {
			// Implied tbody, then reprocess.
			p.clear_to_table_context()
			p.insert_element('tbody', [], false)
			p.mode = 'table_body'
			p.table_body_start(tok)
		}
		'table' {
			if p.pop_until_table_scope('table') {
				p.reset_mode()
			}
		}
		'style', 'script', 'template' {
			p.body_start(tok)
		}
		'input' {
			is_hidden := tok_has_attr(tok, 'type', 'hidden')
			if is_hidden {
				p.insert_element(tag, tok.attrs, false)
				p.stack.pop()
			} else {
				p.foster_body_start(tok)
			}
		}
		'form' {
			if p.stack_has('template') || p.form != none {
				return
			}
			p.insert_element(tag, tok.attrs, false)
			p.form = p.top()
			p.stack.pop()
		}
		'select' {
			p.reconstruct_formatting()
			foster := p.in_table_text_context() || p.foster_all
			p.insert_element(tag, tok.attrs, foster)
		}
		else {
			p.foster_body_start(tok)
		}
	}
}

// foster_body_start foster-parents a token then processes it with body rules.
// The foster_all flag makes nested reconstruction foster as well, mirroring
// the fork's fosterParenting flag.
fn (mut p Parser) foster_body_start(tok Token) {
	end := tok.data in ['html', 'head', 'body', 'frameset', 'frame', 'caption',
		'colgroup', 'tbody', 'tfoot', 'thead', 'tr', 'td', 'th', 'col']
	if end {
		return
	}
	if tok.data == 'form' {
		return
	}
	p.foster_all = true
	p.body_start(tok)
	p.foster_all = false
}

// table_end implements the in-table end-tag rules.
fn (mut p Parser) table_end(tag string) {
	match tag {
		'table' {
			if p.pop_until_table_scope('table') {
				p.reset_mode()
			}
		}
		'template' {
			p.body_end(tag)
		}
		'body', 'caption', 'col', 'colgroup', 'html', 'tbody', 'td', 'tfoot', 'th',
		'thead', 'tr' {}
		else {
			// Foster-parent and process in body.
			if p.foster_table() != none {
				p.foster_end(tag)
			} else {
				p.body_end(tag)
			}
		}
	}
}

fn (mut p Parser) foster_end(tag string) {
	// Run body end-tag rules with foster parenting enabled for insertions.
	// Only br/p-like insertions foster; adoption agency handles the rest.
	if tag == 'br' {
		p.reconstruct_formatting()
		p.insert_element('br', [], true)
		p.stack.pop()
		return
	}
	if tag == 'p' {
		if !p.has_button_scope('p') {
			p.insert_element('p', [], true)
			p.stack.pop()
		}
		p.close_p_element()
		return
	}
	p.body_end(tag)
}

fn (mut p Parser) pop_until_table_scope(tag string) bool {
	if !p.has_table_scope(tag) {
		return false
	}
	p.pop_until(tag)
	return true
}

// table_body_start implements the in-table-body start-tag rules.
fn (mut p Parser) table_body_start(tok Token) {
	tag := tok.data
	match tag {
		'tr' {
			p.clear_to_table_body()
			p.insert_element(tag, tok.attrs, false)
			p.mode = 'row'
		}
		'td', 'th' {
			// Implied tr, then reprocess.
			p.clear_to_table_body()
			p.insert_element('tr', [], false)
			p.mode = 'row'
			p.row_start(tok)
		}
		'caption', 'col', 'colgroup', 'tbody', 'tfoot', 'thead' {
			if p.pop_until_table_scope('tbody') || p.pop_until_table_scope('thead') || p.pop_until_table_scope('tfoot') {
				p.mode = 'table'
				p.table_start(tok)
			}
		}
		else {
			p.table_start(tok)
		}
	}
}

fn (mut p Parser) table_body_end(tag string) {
	match tag {
		'tbody', 'tfoot', 'thead' {
			if p.has_table_scope(tag) {
				p.clear_to_table_body()
				p.stack.pop()
				p.mode = 'table'
			}
		}
		'table' {
			if p.pop_until_table_scope('tbody') || p.pop_until_table_scope('thead') || p.pop_until_table_scope('tfoot') {
				p.mode = 'table'
				p.table_end(tag)
			}
		}
		'body', 'caption', 'col', 'colgroup', 'html', 'td', 'th', 'tr' {}
		else {
			p.table_end(tag)
		}
	}
}

// row_start implements the in-row start-tag rules.
fn (mut p Parser) row_start(tok Token) {
	tag := tok.data
	match tag {
		'td', 'th' {
			p.clear_to_table_row()
			p.insert_element(tag, tok.attrs, false)
			p.formatting << none
			p.mode = 'cell'
		}
		'caption', 'col', 'colgroup', 'tbody', 'tfoot', 'thead', 'tr' {
			if p.pop_until_table_scope('tr') {
				p.mode = 'table_body'
				p.table_body_start(tok)
			}
		}
		else {
			p.table_start(tok)
		}
	}
}

fn (mut p Parser) row_end(tag string) {
	match tag {
		'tr' {
			if p.pop_until_table_scope('tr') {
				p.mode = 'table_body'
			}
		}
		'table' {
			if p.pop_until_table_scope('tr') {
				p.mode = 'table_body'
				p.table_body_end(tag)
			}
		}
		'tbody', 'tfoot', 'thead' {
			if p.has_table_scope(tag) {
				// Implied tr end, then reprocess.
				if p.pop_until_table_scope('tr') {
				}
				p.mode = 'table_body'
				p.table_body_end(tag)
			}
		}
		'body', 'caption', 'col', 'colgroup', 'html', 'td', 'th' {}
		else {
			p.table_end(tag)
		}
	}
}

// cell_start implements the in-cell start-tag rules (others use body rules).
fn (mut p Parser) cell_start(tok Token) {
	tag := tok.data
	if tag in ['caption', 'col', 'colgroup', 'tbody', 'td', 'tfoot', 'th', 'thead',
		'tr'] {
		if p.pop_until_table_scope('td') || p.pop_until_table_scope('th') {
			p.clear_active_formatting()
			p.mode = 'row'
			p.row_start(tok)
		}
		return
	}
	if tag == 'select' {
		p.reconstruct_formatting()
		p.insert_element(tag, tok.attrs, false)
		return
	}
	p.body_start(tok)
}

fn (mut p Parser) close_cell() {
	p.generate_implied_end_tags('')
	if top := p.top() {
		if top.namespace == '' && (top.data == 'td' || top.data == 'th') {
			p.stack.pop()
		} else {
			p.pop_until_table_cell()
		}
	}
	p.clear_active_formatting()
	p.mode = 'row'
}

fn (mut p Parser) pop_until_table_cell() {
	for p.stack.len > 1 {
		n := p.stack.pop()
		if n.namespace == '' && (n.data == 'td' || n.data == 'th') {
			break
		}
	}
}

fn (mut p Parser) cell_end(tag string) {
	match tag {
		'td', 'th' {
			if p.pop_until_table_scope(tag) {
				p.generate_implied_end_tags('')
				p.pop_until(tag)
				p.clear_active_formatting()
				p.mode = 'row'
			}
		}
		'body', 'caption', 'col', 'colgroup', 'html' {}
		'table', 'tbody', 'tfoot', 'thead', 'tr' {
			if p.has_table_scope(tag) {
				if p.pop_until_table_scope('td') || p.pop_until_table_scope('th') {
					p.clear_active_formatting()
				}
				p.mode = 'row'
				p.row_end(tag)
			}
		}
		else {
			p.body_end(tag)
		}
	}
}

// caption_start: table-section tokens close the caption first.
fn (mut p Parser) caption_start(tok Token) {
	tag := tok.data
	if tag in ['caption', 'col', 'colgroup', 'tbody', 'td', 'tfoot', 'th', 'thead',
		'tr'] {
		if p.has_table_scope('caption') {
			p.caption_close()
			p.table_start(tok)
		}
		return
	}
	if tag == 'table' {
		if p.has_table_scope('caption') {
			p.caption_close()
			p.table_start(tok)
		}
		return
	}
	if tag in ['body', 'col', 'colgroup', 'html'] {
		return
	}
	p.body_start(tok)
}

fn (mut p Parser) caption_close() {
	if p.has_table_scope('caption') {
		p.generate_implied_end_tags('')
		p.pop_until('caption')
		p.clear_to_marker()
		p.mode = 'table'
	}
}

fn (mut p Parser) caption_end(tag string) {
	match tag {
		'caption' {
			p.caption_close()
		}
		'table' {
			if p.has_table_scope('caption') {
				p.caption_close()
				p.table_end(tag)
			}
		}
		'body', 'col', 'colgroup', 'html', 'tbody', 'td', 'tfoot', 'th', 'thead',
		'tr' {}
		else {
			p.body_end(tag)
		}
	}
}

// colgroup_start implements the in-column-group rules.
fn (mut p Parser) colgroup_start(tok Token) {
	tag := tok.data
	match tag {
		'col' {
			p.insert_element(tag, tok.attrs, false)
			p.stack.pop()
		}
		'template' {
			p.body_start(tok)
		}
		else {
			if top := p.top() {
				if top.data == 'colgroup' && top.namespace == '' {
					p.stack.pop()
					p.mode = 'table'
					p.table_start(tok)
				}
			}
		}
	}
}

fn (mut p Parser) colgroup_end(tag string) {
	match tag {
		'colgroup' {
			if top := p.top() {
				if top.data == 'colgroup' && top.namespace == '' {
					p.stack.pop()
					p.mode = 'table'
					return
				}
			}
		}
		'col' {}
		'template' {
			p.body_end(tag)
		}
		else {
			if top := p.top() {
				if top.data == 'colgroup' && top.namespace == '' {
					p.stack.pop()
					p.mode = 'table'
					p.table_end(tag)
				}
			}
		}
	}
}

// body_start processes a start-tag token with the in-body rules.
fn (mut p Parser) body_start(tok Token) {
	tag := tok.data
	match tag {
		'html', 'head', 'frameset', 'frame' {
			// Ignored in fragments.
		}
		'body' {
			// Ignored in fragments.
		}
		'base', 'basefont', 'bgsound', 'link', 'meta' {
			p.insert_element(tag, tok.attrs, false)
			p.stack.pop()
		}
		'br' {
			p.reconstruct_formatting()
			p.insert_element('br', tok.attrs, false)
			p.stack.pop()
		}
		'address', 'article', 'aside', 'blockquote', 'center', 'details', 'dialog',
		'dir', 'div', 'dl', 'fieldset', 'figcaption', 'figure', 'footer', 'header',
		'hgroup', 'main', 'menu', 'nav', 'ol', 'p', 'search', 'section', 'summary', 'ul' {
			p.pop_to_p()
			p.insert_element(tag, tok.attrs, false)
		}
		'h1', 'h2', 'h3', 'h4', 'h5', 'h6' {
			p.pop_to_p()
			if top := p.top() {
				if top.namespace == '' && top.data in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'] {
					p.stack.pop()
				}
			}
			p.insert_element(tag, tok.attrs, false)
		}
		'pre', 'listing' {
			p.pop_to_p()
			p.insert_element(tag, tok.attrs, false)
			p.skip_leading_newline = true
		}
		'form' {
			if p.form != none {
				return
			}
			p.pop_to_p()
			node := p.insert_element(tag, tok.attrs, false)
			p.form = node
		}
		'li' {
			if p.has_list_scope('li') {
				p.generate_implied_end_tags('li')
				p.pop_until('li')
			}
			p.pop_to_p()
			p.insert_element(tag, tok.attrs, false)
		}
		'dd', 'dt' {
			if p.has_in_scope('dd') {
				p.generate_implied_end_tags('dd')
				p.pop_until('dd')
			}
			if p.has_in_scope('dt') {
				p.generate_implied_end_tags('dt')
				p.pop_until('dt')
			}
			p.pop_to_p()
			p.insert_element(tag, tok.attrs, false)
		}
		'plaintext' {
			p.pop_to_p()
			p.insert_element(tag, tok.attrs, false)
			rest := p.tok.input[p.tok.pos..]
			p.tok.pos = p.tok.input.len
			p.insert_text_raw(rest.replace('\x00', '�'))
		}
		'button' {
			if p.has_in_scope('button') {
				p.generate_implied_end_tags('')
				p.pop_until('button')
			}
			p.reconstruct_formatting()
			p.insert_element(tag, tok.attrs, false)
		}
		'a' {
			// Marker-bounded scan for an existing a element.
			mut found := ?&Node(none)
			for i := p.formatting.len - 1; i >= 0; i-- {
				if ent := p.formatting[i] {
					if ent.tag == 'a' {
						found = ent.node
						break
					}
				} else {
					break
				}
			}
			if old := found {
				p.adoption_agency('a')
				stack_remove(mut p.stack, old)
				afe_remove(mut p.formatting, old)
			}
			p.add_formatting_element(tag, tok.attrs)
		}
		'b', 'big', 'code', 'em', 'font', 'i', 's', 'small', 'strike', 'strong', 'tt', 'u' {
			p.add_formatting_element(tag, tok.attrs)
		}
		'nobr' {
			p.reconstruct_formatting()
			if p.has_in_scope('nobr') {
				p.adoption_agency('nobr')
				p.reconstruct_formatting()
			}
			p.add_formatting_element(tag, tok.attrs)
		}
		'applet', 'marquee', 'object' {
			p.reconstruct_formatting()
			p.insert_element(tag, tok.attrs, false)
			p.formatting << none
		}
		'area', 'embed', 'img', 'keygen', 'wbr' {
			p.reconstruct_formatting()
			p.insert_element(tag, tok.attrs, false)
			p.stack.pop()
		}
		'input' {
			p.reconstruct_formatting()
			p.insert_element(tag, tok.attrs, false)
			p.stack.pop()
		}
		'param', 'source', 'track' {
			p.insert_element(tag, tok.attrs, false)
			p.stack.pop()
		}
		'hr' {
			p.pop_to_p()
			p.insert_element(tag, tok.attrs, false)
			p.stack.pop()
		}
		'image' {
			p.reconstruct_formatting()
			p.insert_element('img', tok.attrs, false)
			p.stack.pop()
		}
		'textarea' {
			p.insert_element(tag, tok.attrs, false)
			text := p.tok.next_raw_text(tag, true)
			raw := if text.starts_with('\n') { text[1..] } else { text }
			if p.foster_all {
				p.foster_text(raw)
			} else {
				p.insert_text_raw(raw)
			}
			p.stack.pop()
		}
		'xmp' {
			p.pop_to_p()
			p.reconstruct_formatting()
			p.insert_rawtext(tag, tok.attrs, false)
		}
		'iframe' {
			p.insert_rawtext(tag, tok.attrs, false)
		}
		'noembed', 'noframes' {
			p.insert_rawtext(tag, tok.attrs, false)
		}
		'noscript' {
			p.reconstruct_formatting()
			p.insert_element(tag, tok.attrs, false)
		}
		'select' {
			p.reconstruct_formatting()
			foster := p.in_table_text_context() || p.foster_all
			p.insert_element(tag, tok.attrs, foster)
		}
		'optgroup', 'option' {
			if top := p.top() {
				if top.data == 'option' && top.namespace == '' {
					p.stack.pop()
				}
			}
			p.reconstruct_formatting()
			p.insert_element(tag, tok.attrs, false)
		}
		'rb', 'rtc' {
			if p.has_in_scope('ruby') {
				p.generate_implied_end_tags('')
			}
			p.insert_element(tag, tok.attrs, false)
		}
		'rp', 'rt' {
			if p.has_in_scope('ruby') {
				p.generate_implied_end_tags('rtc')
			}
			p.insert_element(tag, tok.attrs, false)
		}
		'math' {
			p.reconstruct_formatting()
			mut node := p.insert_element(tag, tok.attrs, false)
			node.namespace = 'math'
			p.adjust_math_attrs(mut node)
		}
		'svg' {
			p.reconstruct_formatting()
			mut node := p.insert_element(tag, tok.attrs, false)
			node.namespace = 'svg'
			p.adjust_svg_attrs(mut node)
		}
		'table' {
			p.pop_to_p()
			p.insert_element(tag, tok.attrs, false)
			p.mode = 'table'
		}
		'caption', 'col', 'colgroup', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr' {
			// Ignore the token.
		}
		'script', 'style' {
			p.insert_rawtext(tag, tok.attrs, false)
		}
		'title' {
			p.insert_rawtext(tag, tok.attrs, true)
		}
		'template' {
			p.insert_element(tag, tok.attrs, false)
		}
		else {
			p.reconstruct_formatting()
			p.insert_element(tag, tok.attrs, false)
		}
	}
}

fn (mut p Parser) insert_rawtext(tag string, attrs []Attribute, rcdata bool) {
	p.insert_element(tag, attrs, false)
	text := p.tok.next_raw_text(tag, rcdata)
	if p.foster_all {
		p.foster_text(text)
	} else {
		p.insert_text_raw(text)
	}
	p.stack.pop()
}

// body_end processes an end-tag token with the in-body rules.
fn (mut p Parser) body_end(tag string) {
	if p.in_select() && tag != 'select' {
		p.select_end(tag)
		return
	}
	match tag {
		'body', 'html' {
			if p.has_in_scope('body') {
				p.generate_implied_end_tags('')
			}
		}
		'br' {
			p.reconstruct_formatting()
			p.insert_element('br', [], false)
			p.stack.pop()
		}
		'p' {
			if !p.has_button_scope('p') {
				p.insert_element('p', [], false)
			}
			p.pop_until_scope('button', ['p'])
		}
		'li' {
			p.pop_until_scope('list_item', ['li'])
		}
		'dd', 'dt' {
			p.pop_until_scope('default', [tag])
		}
		'h1', 'h2', 'h3', 'h4', 'h5', 'h6' {
			p.pop_until_scope('default', ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'])
		}
		'a', 'b', 'big', 'code', 'em', 'font', 'i', 'nobr', 's', 'small', 'strike',
		'strong', 'tt', 'u' {
			if !p.adoption_agency(tag) {
				p.other_end(tag)
			}
		}
		'applet', 'marquee', 'object' {
			if p.pop_until_scope('default', [tag]) {
				p.clear_active_formatting()
			}
		}
		'form' {
			if f := p.form {
				p.form = none
				i := p.index_in_scope('default', ['form'])
				if i >= 0 && p.stack[i] == f {
					p.generate_implied_end_tags('')
					stack_remove(mut p.stack, f)
				}
			}
		}
		'address', 'article', 'aside', 'blockquote', 'button', 'center', 'details', 'dialog',
		'dir', 'div', 'dl', 'fieldset', 'figcaption', 'figure', 'footer', 'header',
		'hgroup', 'listing', 'main', 'menu', 'nav', 'ol', 'pre', 'search', 'section',
		'summary', 'ul' {
			p.pop_until_scope('default', [tag])
		}
		'table' {
			if p.has_table_scope('table') {
				p.pop_until('table')
				p.reset_mode()
			}
		}
		'caption', 'colgroup', 'tbody', 'tfoot', 'thead', 'tr', 'td', 'th' {
			if p.has_table_scope(tag) {
				if tag in ['td', 'th'] {
					p.generate_implied_end_tags('')
				}
				p.pop_until(tag)
				p.reset_mode()
			}
		}
		'select' {
			if p.stack_has('select') {
				p.pop_until('select')
				p.reset_mode()
			}
		}
		'option', 'optgroup' {
			if top := p.top() {
				if top.data == 'option' && top.namespace == '' {
					p.stack.pop()
				}
				if tag == 'optgroup' {
					if top2 := p.top() {
						if top2.data == 'optgroup' && top2.namespace == '' {
							p.stack.pop()
						}
					}
				}
			}
		}
		'rp', 'rt', 'ruby' {
			if p.has_in_scope('ruby') {
				p.generate_implied_end_tags('')
				p.pop_until('ruby')
			}
		}
		'template' {
			if p.stack_has('template') {
				p.pop_until('template')
			}
		}
		'head', 'frame' {}
		else {
			p.other_end(tag)
		}
	}
}

// other_end implements the "any other end tag" steps: truncate to the match
// without implied end tags, stopping at the first special element.
fn (mut p Parser) other_end(tag string) {
	for i := p.stack.len - 1; i >= 0; i-- {
		n := p.stack[i]
		if n.data == tag && n.namespace == '' {
			p.stack = p.stack[..i]
			return
		}
		if is_special(n) {
			return
		}
	}
}

// select_start handles tokens when a select element is open.
fn (mut p Parser) select_start(tok Token) {
	tag := tok.data
	match tag {
		'option' {
			if top := p.top() {
				if top.data == 'option' && top.namespace == '' {
					p.stack.pop()
				}
			}
			p.insert_element(tag, tok.attrs, false)
		}
		'optgroup' {
			if top := p.top() {
				if top.data == 'option' && top.namespace == '' {
					p.stack.pop()
				}
			}
			if top := p.top() {
				if top.data == 'optgroup' && top.namespace == '' {
					p.stack.pop()
				}
			}
			p.insert_element(tag, tok.attrs, false)
		}
		'hr' {
			if top := p.top() {
				if top.data == 'option' && top.namespace == '' {
					p.stack.pop()
				}
			}
			if top := p.top() {
				if top.data == 'optgroup' && top.namespace == '' {
					p.stack.pop()
				}
			}
			p.insert_element(tag, tok.attrs, false)
			p.stack.pop()
		}
		'select' {
			p.body_end('select')
		}
		'textarea' {
			// Textarea is raw text even inside select.
			p.body_start(tok)
		}
		'input', 'keygen' {
			if !p.has_in_scope('select') {
				p.body_start(tok)
				return
			}
			p.insert_element(tag, tok.attrs, false)
			p.stack.pop()
		}
		'script', 'template' {
			p.body_start(tok)
		}
		else {
			// Ignored in select.
		}
	}
}

fn (mut p Parser) select_end(tag string) {
	match tag {
		'select' {
			if p.stack_has('select') {
				p.pop_until('select')
				p.reset_mode()
			}
		}
		'option' {
			if top := p.top() {
				if top.data == 'option' && top.namespace == '' {
					p.stack.pop()
				}
			}
		}
		'optgroup' {
			if top := p.top() {
				if top.data == 'option' && top.namespace == '' {
					p.stack.pop()
				}
			}
			if top := p.top() {
				if top.data == 'optgroup' && top.namespace == '' {
					p.stack.pop()
				}
			}
		}
		'script', 'template' {
			p.body_end(tag)
		}
		else {}
	}
}

// parse_fragment parses a fragment with the given context element name.
// Like the fork, the stack starts at a synthetic html root; the context only
// selects namespace-aware tokenization. Scopes terminate at the html root, so
// truncated content reattaches at the top level instead of being lost.
pub fn parse_fragment(input string, context_tag string) ![]&Node {
	mut src := input
	if src.len >= 3 && src[0] == 0xef && src[1] == 0xbb && src[2] == 0xbf {
		src = src[3..]
	}
	mut p := Parser{
		tok:  new_tokenizer(src)
		root: new_node(.document_node, '')
		mode: 'body'
	}
	syn := new_node(.element_node, 'html')
	p.root.append_child(syn)
	p.stack << syn
	for {
		tok := p.tok.next()
		if tok.typ == .error_token {
			if p.tok.pending_err != '' {
				return error(p.tok.pending_err)
			}
			break
		}
		p.process_token(tok)!
	}
	return syn.children()
}
