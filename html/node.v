// Package html is a V port of the Go port's HTML fork (golang.org/x/net/html
// v0.59.0 with compatibility changes for the pinned Rust/Gumbo parser). It
// preserves source attribute order, the 400-depth/attribute limits, and the
// scripting-disabled fragment parsing exercised by the richtext corpus.
module html

pub enum NodeType {
	error_node
	text_node
	document_node
	element_node
	comment_node
	doctype_node
	raw_node
	scope_marker_node
}

pub fn (t NodeType) str() string {
	return match t {
		.error_node { 'ErrorNode' }
		.text_node { 'TextNode' }
		.document_node { 'DocumentNode' }
		.element_node { 'ElementNode' }
		.comment_node { 'CommentNode' }
		.doctype_node { 'DoctypeNode' }
		.raw_node { 'RawNode' }
		.scope_marker_node { 'ScopeMarkerNode' }
	}
}

pub struct Attribute {
pub mut:
	namespace string
	key       string
	val       string
}

@[heap]
pub struct Node {
pub mut:
	parent       ?&Node
	first_child  ?&Node
	last_child   ?&Node
	prev_sibling ?&Node
	next_sibling ?&Node
	typ          NodeType = .error_node
	data         string
	namespace    string
	attr         []Attribute
}

pub fn new_node(typ NodeType, data string) &Node {
	return &Node{typ: typ, data: data}
}

pub fn (n &Node) children() []&Node {
	mut out := []&Node{}
	mut c := n.first_child
	for {
		child := c or { break }
		out << child
		c = child.next_sibling
	}
	return out
}

// append_child appends c as the last child of n.
pub fn (n &Node) append_child(c &Node) {
	unsafe {
		mut nc := c
		mut nn := n
		nc.parent = nn
		nc.prev_sibling = nn.last_child
		nc.next_sibling = none
		if mut last := nn.last_child {
			last.next_sibling = nc
		} else {
			nn.first_child = nc
		}
		nn.last_child = nc
	}
}

// remove_child detaches c from n.
pub fn (n &Node) remove_child(c &Node) {
	unsafe {
		mut nc := c
		mut nn := n
		nc.parent = none
		prev := nc.prev_sibling
		next := nc.next_sibling
		if p := prev {
			p.next_sibling = next
		} else {
			nn.first_child = next
		}
		if nx := next {
			nx.prev_sibling = prev
		} else {
			nn.last_child = prev
		}
		nc.prev_sibling = none
		nc.next_sibling = none
	}
}

// insert_before inserts new_child as a child of n before old_child (or at the
// end when old_child is none).
pub fn (n &Node) insert_before(new_child &Node, old_child ?&Node) {
	unsafe {
		mut nc := new_child
		mut nn := n
		nc.parent = nn
		if o := old_child {
			nc.next_sibling = o
			nc.prev_sibling = o.prev_sibling
			if p := o.prev_sibling {
				p.next_sibling = nc
			} else {
				nn.first_child = nc
			}
			o.prev_sibling = nc
		} else {
			nc.prev_sibling = nn.last_child
			nc.next_sibling = none
			if l := nn.last_child {
				l.next_sibling = nc
			} else {
				nn.first_child = nc
			}
			nn.last_child = nc
		}
	}
}

// Field mutation goes through methods so callers can hold immutable references,
// mirroring how append_child works.
pub fn (n &Node) set_data(data string) {
	unsafe {
		n.data = data
	}
}

pub fn (n &Node) set_attrs(attrs []Attribute) {
	unsafe {
		n.attr = attrs.clone()
	}
}

pub fn (n &Node) set_attribute(key string, val string) {
	unsafe {
		for i, a in n.attr {
			if a.key == key {
				n.attr[i].val = val
				return
			}
		}
		n.attr << Attribute{key: key, val: val}
	}
}

pub fn (n &Node) remove_attribute(key string) {
	unsafe {
		for i, a in n.attr {
			if a.key == key {
				n.attr.delete(i)
				return
			}
		}
	}
}

pub fn (n &Node) delete_attr_at(i int) {
	unsafe {
		n.attr.delete(i)
	}
}

pub fn (n &Node) set_namespace(ns string) {
	unsafe {
		n.namespace = ns
	}
}

pub fn (n &Node) set_attr_val_at(i int, val string) {
	unsafe {
		n.attr[i].val = val
	}
}

// clone_node deep-copies n without its siblings or parent.
pub fn clone_node(n &Node) &Node {
	out := &Node{typ: n.typ, data: n.data, namespace: n.namespace, attr: n.attr.clone()}
	for c in n.children() {
		out.append_child(clone_node(c))
	}
	return out
}
