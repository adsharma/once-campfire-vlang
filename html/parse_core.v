module html

// is_special_element_map lists elements with special parsing rules (HTML
// namespace), from the WHATWG specification section 12.2.4.2.
const special_elements = {
	'address': true, 'applet': true, 'area': true, 'article': true, 'aside': true,
	'base': true, 'basefont': true, 'bgsound': true, 'blockquote': true, 'body': true,
	'br': true, 'button': true, 'caption': true, 'center': true, 'col': true,
	'colgroup': true, 'dd': true, 'details': true, 'dir': true, 'div': true,
	'dl': true, 'dt': true, 'embed': true, 'fieldset': true, 'figcaption': true,
	'figure': true, 'footer': true, 'form': true, 'frame': true, 'frameset': true,
	'h1': true, 'h2': true, 'h3': true, 'h4': true, 'h5': true, 'h6': true,
	'head': true, 'header': true, 'hgroup': true, 'hr': true, 'html': true,
	'iframe': true, 'img': true, 'input': true, 'keygen': true, 'li': true,
	'link': true, 'listing': true, 'main': true, 'marquee': true, 'menu': true,
	'meta': true, 'nav': true, 'noembed': true, 'noframes': true, 'noscript': true,
	'object': true, 'ol': true, 'p': true, 'param': true, 'plaintext': true,
	'pre': true, 'script': true, 'section': true, 'select': true, 'source': true,
	'style': true, 'summary': true, 'table': true, 'tbody': true, 'td': true,
	'template': true, 'textarea': true, 'tfoot': true, 'th': true, 'thead': true,
	'title': true, 'tr': true, 'track': true, 'ul': true, 'wbr': true, 'xmp': true,
}

const void_elements = {
	'area': true, 'base': true, 'br': true, 'col': true, 'embed': true, 'hr': true,
	'img': true, 'input': true, 'link': true, 'meta': true, 'param': true,
	'source': true, 'track': true, 'wbr': true, 'frame': true, 'basefont': true,
	'bgsound': true, 'keygen': true,
}

const rcdata_elements = {
	'textarea': true, 'title': true,
}

const rawtext_elements = {
	'script': true, 'style': true, 'iframe': true, 'noembed': true, 'noframes': true,
	'xmp': true,
}

const formatting_elements = {
	'a': true, 'b': true, 'big': true, 'code': true, 'em': true, 'font': true,
	'i': true, 'nobr': true, 's': true, 'small': true, 'strike': true,
	'strong': true, 'tt': true, 'u': true,
}

const implied_end_tags = {
	'dd': true, 'dt': true, 'li': true, 'optgroup': true, 'option': true, 'p': true,
	'rp': true, 'rt': true,
}

struct Parser {
mut:
	foster_all           bool
	tok                  Tokenizer
	stack                []&Node
	formatting           []?FormatEntry
	root                 &Node
	skip_leading_newline bool
	mode                 string
	form                 ?&Node
}

struct FormatEntry {
	node  &Node
	tag   string
	attrs []Attribute
}

fn is_special(n &Node) bool {
	if n.namespace == '' || n.namespace == 'html' {
		return n.data in special_elements
	}
	if n.namespace == 'math' {
		return n.data in ['mi', 'mo', 'mn', 'ms', 'mtext', 'annotation-xml']
	}
	if n.namespace == 'svg' {
		return n.data in ['foreignObject', 'desc', 'title']
	}
	return false
}

fn (mut p Parser) top() ?&Node {
	if p.stack.len == 0 {
		return none
	}
	return p.stack[p.stack.len - 1]
}

fn stop_tag(ns string, tag string) bool {
	if ns == '' || ns == 'html' {
		return tag in ['applet', 'caption', 'html', 'table', 'td', 'th', 'marquee', 'object',
			'template']
	}
	if ns == 'math' {
		return tag in ['mi', 'mo', 'mn', 'ms', 'mtext', 'annotation-xml']
	}
	if ns == 'svg' {
		return tag in ['foreignObject', 'desc', 'title']
	}
	return false
}

fn (mut p Parser) index_in_scope(scope string, tags []string) int {
	for i := p.stack.len - 1; i >= 0; i-- {
		n := p.stack[i]
		if n.namespace == '' {
			for t in tags {
				if n.data == t {
					return i
				}
			}
			match scope {
				'list_item' {
					if n.data == 'ol' || n.data == 'ul' {
						return -1
					}
				}
				'button' {
					if n.data == 'button' {
						return -1
					}
				}
				'table' {
					if n.data == 'html' || n.data == 'table' || n.data == 'template' {
						return -1
					}
				}
				'select' {
					if n.data != 'optgroup' && n.data != 'option' {
						return -1
					}
				}
				else {}
			}
		}
		if scope in ['default', 'list_item', 'button'] {
			if stop_tag(n.namespace, n.data) {
				return -1
			}
		}
	}
	return -1
}

// pop_until_scope truncates the stack to (excluding) the matched element.
fn (mut p Parser) pop_until_scope(scope string, tags []string) bool {
	i := p.index_in_scope(scope, tags)
	if i < 0 {
		return false
	}
	p.stack = p.stack[..i]
	return true
}

fn (mut p Parser) has_in_scope(tag string) bool {
	return p.index_in_scope('default', [tag]) >= 0
}

fn (mut p Parser) has_button_scope(tag string) bool {
	return p.index_in_scope('button', [tag]) >= 0
}

fn (mut p Parser) has_list_scope(tag string) bool {
	return p.index_in_scope('list_item', [tag]) >= 0
}

fn (mut p Parser) has_table_scope(tag string) bool {
	return p.index_in_scope('table', [tag]) >= 0
}

// pop_to_p truncates the stack above the p element in button scope.
fn (mut p Parser) pop_to_p() {
	i := p.index_in_scope('button', ['p'])
	if i >= 0 {
		p.stack = p.stack[..i]
	}
}

fn (mut p Parser) stack_has(tag string) bool {
	for i := p.stack.len - 1; i >= 0; i-- {
		if p.stack[i].data == tag && p.stack[i].namespace == '' {
			return true
		}
	}
	return false
}

// foster_table finds the last table in the stack for foster parenting.
fn (mut p Parser) foster_table() ?&Node {
	for i := p.stack.len - 1; i >= 0; i-- {
		if p.stack[i].data == 'table' && p.stack[i].namespace == '' {
			return p.stack[i]
		}
		if p.stack[i].data == 'template' || p.stack[i].data == 'html' {
			return none
		}
	}
	return none
}

fn (mut p Parser) in_table_text_context() bool {
	t := p.top() or { return false }
	return t.namespace == '' && t.data in ['table', 'tbody', 'thead', 'tfoot', 'tr']
}

fn (mut p Parser) insert_text(raw string) {
	data := raw.replace('\x00', '').replace('\ue000', '')
	if data == '' {
		return
	}
	p.reconstruct_formatting()
	if t := p.foster_table() {
		if top := p.top() {
			if top == t {
				if parent := t.parent {
					node := new_node(.text_node, data)
					parent.insert_before(node, t)
					return
				}
			}
		}
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

// foster_append inserts node before the foster table (or at the current
// position when there is no table).
fn (mut p Parser) foster_append(node &Node) {
	if t := p.foster_table() {
		if parent := t.parent {
			parent.insert_before(node, t)
			return
		}
	}
	parent := p.top() or { p.root }
	parent.append_child(node)
}

fn is_integration_point(n &Node) bool {
	if n.namespace == 'svg' {
		return n.data == 'foreignObject' || n.data == 'desc' || n.data == 'title'
	}
	if n.namespace == 'math' {
		if n.data == 'mi' || n.data == 'mo' || n.data == 'mn' || n.data == 'ms' || n.data == 'mtext' {
			return true
		}
		if n.data == 'annotation-xml' {
			for a in n.attr {
				if a.key == 'encoding' {
					enc := a.val.to_lower().trim_space()
					return enc == 'text/html' || enc == 'application/xhtml+xml'
				}
			}
		}
	}
	return false
}

fn (mut p Parser) insert_element(tag string, attrs []Attribute, foster_in bool) &Node {
	// Like the fork's shouldFosterParent, fostering applies per insertion based
	// on the current top element, so reconstructed formatting nests instead of
	// becoming siblings.
	foster := foster_in || (p.foster_all && p.in_table_text_context())
	mut node := new_node(.element_node, tag)
	node.attr = attrs.clone()
	if foster {
		p.foster_append(node)
		p.stack << node
		return node
	}
	parent := p.top() or { p.root }
	parent.append_child(node)
	p.stack << node
	return node
}

fn (mut p Parser) pop_until(tag string) {
	mut idx := -1
	for i := p.stack.len - 1; i >= 0; i-- {
		if p.stack[i].data == tag && p.stack[i].namespace == '' {
			idx = i
			break
		}
	}
	if idx < 0 {
		return
	}
	for p.stack.len > idx {
		p.stack.pop()
	}
}

fn (mut p Parser) generate_implied_end_tags(except string) {
	for p.stack.len > 0 {
		t := p.stack[p.stack.len - 1]
		if t.namespace == '' && t.data in implied_end_tags && t.data != except {
			p.stack.pop()
		} else {
			break
		}
	}
}

fn (mut p Parser) close_p_element() {
	p.generate_implied_end_tags('p')
	if p.stack.len > 0 {
		t := p.stack[p.stack.len - 1]
		if t.data == 'p' && t.namespace == '' {
			p.stack.pop()
		}
	}
}

// reconstruct_formatting implements the reconstruction step.
fn (mut p Parser) reconstruct_formatting() {
	if p.formatting.len == 0 {
		return
	}
	last := p.formatting[p.formatting.len - 1] or { return }
	for n in p.stack {
		if n == last.node {
			return
		}
	}
	mut idx := p.formatting.len - 1
	for {
		if idx == 0 {
			break
		}
		prev := p.formatting[idx - 1] or { break }
		mut found := false
		for n in p.stack {
			if n == prev.node {
				found = true
				break
			}
		}
		if found {
			break
		}
		idx--
	}
	for i := idx; i < p.formatting.len; i++ {
		ent := p.formatting[i] or { continue }
		node := p.insert_element(ent.tag, ent.attrs, false)
		p.formatting[i] = FormatEntry{node, ent.tag, ent.attrs}
	}
}

// add_formatting_element implements Noah's Ark + insertion.
fn (mut p Parser) add_formatting_element(tag string, attrs []Attribute) {
	p.reconstruct_formatting()
	node := p.insert_element(tag, attrs, false)
	mut count := 0
	mut first_pos := -1
	for i := p.formatting.len - 1; i >= 0; i-- {
		ent := p.formatting[i] or { break }
		if ent.tag == tag && attrs_equal(ent.attrs, attrs) {
			count++
			first_pos = i
			if count == 3 {
				p.formatting.delete(first_pos)
				break
			}
		}
	}
	p.formatting << FormatEntry{node, tag, attrs}
}

fn attrs_equal(a []Attribute, b []Attribute) bool {
	if a.len != b.len {
		return false
	}
	for i, x in a {
		if x.key != b[i].key || x.val != b[i].val || x.namespace != b[i].namespace {
			return false
		}
	}
	return true
}

fn afe_index(list []?FormatEntry, node &Node) int {
	for i, e in list {
		if ent := e {
			if ent.node == node {
				return i
			}
		}
	}
	return -1
}

fn afe_remove(mut list []?FormatEntry, node &Node) {
	idx := afe_index(list, node)
	if idx >= 0 {
		list.delete(idx)
	}
}

fn stack_remove(mut stack []&Node, node &Node) {
	for i, n in stack {
		if n == node {
			stack.delete(i)
			return
		}
	}
}

fn stack_index_of(stack []&Node, node &Node) int {
	for i, n in stack {
		if n == node {
			return i
		}
	}
	return -1
}

// shallow_clone copies an element without children, like the fork's Node.clone.
fn shallow_clone(n &Node) &Node {
	return &Node{typ: n.typ, data: n.data, attr: n.attr.clone()}
}

// adoption_agency is the fork's inBodyEndTagFormatting, step for step.
// Returns false when the caller should run the generic end-tag steps.
fn (mut p Parser) adoption_agency(tag string) bool {
	// Steps 1-2.
	if cur := p.top() {
		if cur.data == tag && cur.namespace == '' && afe_index(p.formatting, cur) == -1 {
			p.stack.pop()
			return true
		}
	}
	// Steps 3-5: outer loop.
	for _ in 0 .. 8 {
		// Step 6: find the formatting element.
		mut fe := ?&Node(none)
		mut fe_tag := ''
		mut fe_attrs := []Attribute{}
		for j := p.formatting.len - 1; j >= 0; j-- {
			if ent := p.formatting[j] {
				if ent.tag == tag {
					fe = ent.node
					fe_tag = ent.tag
					fe_attrs = ent.attrs.clone()
					break
				}
			} else {
				break
			}
		}
		fenode := fe or { return false }
		// Step 7.
		fe_stack := stack_index_of(p.stack, fenode)
		if fe_stack < 0 {
			afe_remove(mut p.formatting, fenode)
			return true
		}
		// Step 8.
		if !p.has_in_scope(tag) {
			return true
		}
		// Steps 10-11: furthest block.
		mut fb := ?&Node(none)
		for _, e in p.stack[fe_stack..] {
			if is_special(e) {
				fb = e
				break
			}
		}
		fbnode := fb or {
			mut e := p.stack.pop()
			for e != fenode {
				e = p.stack.pop()
			}
			afe_remove(mut p.formatting, e)
			return true
		}
		// Steps 12-13.
		common := p.stack[fe_stack - 1]
		mut bookmark := afe_index(p.formatting, fenode)
		// Step 14: inner loop.
		mut last_node := fbnode
		mut node := fbnode
		mut x := stack_index_of(p.stack, node)
		mut j := 0
		for {
			j++
			x--
			node = p.stack[x]
			if node == fenode {
				break
			}
			ni := afe_index(p.formatting, node)
			if j > 3 && ni > -1 {
				p.formatting.delete(ni)
				if ni <= bookmark {
					bookmark--
				}
				continue
			}
			if ni == -1 {
				stack_remove(mut p.stack, node)
				continue
			}
			clone := shallow_clone(node)
			p.formatting[ni] = FormatEntry{clone, node.data, node.attr.clone()}
			p.stack[stack_index_of(p.stack, node)] = clone
			node = clone
			if last_node == fbnode {
				bookmark = afe_index(p.formatting, node) + 1
			}
			if par := last_node.parent {
				par.remove_child(last_node)
			}
			node.append_child(last_node)
			last_node = node
		}
		// Step 15: reparent lastNode to the common ancestor (or foster parent).
		if par := last_node.parent {
			par.remove_child(last_node)
		}
		if common.data in ['table', 'tbody', 'tfoot', 'thead', 'tr'] && common.namespace == '' {
			p.foster_append(last_node)
		} else {
			common.append_child(last_node)
		}
		// Steps 16-18.
		mut clone := shallow_clone(fenode)
		clone.attr = fe_attrs.clone()
		clone.data = fe_tag
		reparent_into(clone, fbnode)
		fbnode.append_child(clone)
		// Step 19.
		old_loc := afe_index(p.formatting, fenode)
		if old_loc != -1 && old_loc < bookmark {
			bookmark--
		}
		afe_remove(mut p.formatting, fenode)
		if bookmark > p.formatting.len {
			bookmark = p.formatting.len
		}
		mut expanded := p.formatting[..bookmark].clone()
		expanded << FormatEntry{clone, fe_tag, fe_attrs}
		for e in p.formatting[bookmark..] {
			if ent := e {
				expanded << FormatEntry{ent.node, ent.tag, ent.attrs}
			} else {
				expanded << none
			}
		}
		p.formatting = expanded
		// Step 20.
		stack_remove(mut p.stack, fenode)
		p.stack.insert(stack_index_of(p.stack, fbnode) + 1, clone)
	}
	return true
}

// reparent_into moves all children of src into dst.
fn reparent_into(dst &Node, src &Node) {
	for {
		c := src.first_child or { break }
		src.remove_child(c)
		dst.append_child(c)
	}
}
