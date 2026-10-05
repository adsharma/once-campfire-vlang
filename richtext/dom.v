module richtext

import html

fn parse_rich(body string) !&html.Node {
	return parse_in(body, '')
}

fn parse_in(body string, context_tag string) !&html.Node {
	mut tag := context_tag
	if tag == '' {
		tag = 'body'
	}
	nodes := html.parse_fragment(body, tag)!
	root := html.new_node(.document_node, '')
	for n in nodes {
		root.append_child(n)
	}
	return root
}

fn attr(n &html.Node, key string) string {
	for a in n.attr {
		if a.key == key {
			return a.val
		}
	}
	return ''
}

fn set_attr(n &html.Node, key string, value string) {
	n.set_attribute(key, value)
}

fn remove_attr(n &html.Node, key string) {
	n.remove_attribute(key)
}

fn children(n &html.Node) []&html.Node {
	return n.children()
}

fn walk(n &html.Node, f fn (&html.Node)) {
	for c in n.children() {
		walk(c, f)
	}
	f(n)
}

fn replace_node(n &html.Node, markup string) ! {
	root := parse_in(markup, parent_tag(n))!
	if parent := n.parent {
		for cc in parent.children() {
		}
		for c in root.children() {
			root.remove_child(c)
			parent.insert_before(c, n)
		}
		parent.remove_child(n)
		for cc in parent.children() {
		}
	}
}

fn parent_tag(n &html.Node) string {
	if p := n.parent {
		if p.typ == .element_node {
			return p.data
		}
	}
	return 'body'
}

fn inner_html(n &html.Node, markup string) ! {
	root := parse_in(markup, n.data)!
	for cc in root.children() {
	}
	for c in n.children() {
		n.remove_child(c)
	}
	for c in root.children() {
		root.remove_child(c)
		n.append_child(c)
	}
}

fn words_set(s string) map[string]bool {
	mut m := map[string]bool{}
	for w in s.split(' ') {
		if w != '' {
			m[w] = true
		}
	}
	return m
}

const void_tags = {
	'area': true, 'base': true, 'br': true, 'col': true, 'embed': true, 'hr': true,
	'img': true, 'input': true, 'link': true, 'meta': true, 'param': true,
	'source': true, 'track': true, 'wbr': true,
}

const raw_tags = {
	'style': true, 'script': true, 'xmp': true, 'iframe': true, 'noembed': true,
	'noframes': true, 'plaintext': true, 'noscript': true,
}

fn escape_text(s string) string {
	return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace(' ', '&nbsp;')
}

fn escape_attr(s string) string {
	return s.replace('&', '&amp;').replace('"', '&quot;').replace(' ', '&nbsp;')
}

fn serialize(n &html.Node) string {
	mut out := []u8{}
	serialize_to(mut out, n, false, false)
	return out.bytestr()
}

fn serialize_to(mut out []u8, n &html.Node, raw bool, attribute_angles bool) {
	match n.typ {
		.text_node {
			if raw {
				out << n.data.bytes()
			} else {
				out << escape_text(n.data).bytes()
			}
			return
		}
		.comment_node {
			out << '<!--'.bytes()
			out << n.data.bytes()
			out << '-->'.bytes()
			return
		}
		.element_node {
			out << `<`.bytes()
			out << n.data.bytes()
			for a in n.attr {
				out << ` `.bytes()
				if a.namespace != '' {
					out << a.namespace.bytes()
					out << ':'.bytes()
				}
				out << a.key.bytes()
				out << '="'.bytes()
				mut value := escape_attr(a.val)
				if attribute_angles {
					value = value.replace('<', '&lt;').replace('>', '&gt;')
				}
				out << value.bytes()
				out << `"`.bytes()
			}
			out << `>`.bytes()
			if n.namespace == '' && n.data in void_tags {
				return
			}
		}
		else {}
	}
	for c in n.children() {
		serialize_to(mut out, c, n.namespace == '' && n.data in raw_tags, attribute_angles)
	}
	if n.typ == .element_node {
		out << '</'.bytes()
		out << n.data.bytes()
		out << `>`.bytes()
	}
}

fn serialize_presentation(n &html.Node) string {
	mut out := []u8{}
	serialize_to(mut out, n, false, true)
	return out.bytestr()
}
