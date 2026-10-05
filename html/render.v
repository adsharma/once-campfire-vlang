module html

// render serializes a node tree back to HTML (debug/audit helper; the
// richtext pipeline has its own context-sensitive serializers).
pub fn render(n &Node) string {
	mut out := []u8{}
	render_into(mut out, n)
	return out.bytestr()
}

fn render_into(mut out []u8, n &Node) {
	match n.typ {
		.text_node {
			out << escape_string(n.data).bytes()
		}
		.comment_node {
			out << '<!--'.bytes()
			out << n.data.bytes()
			out << '-->'.bytes()
		}
		.doctype_node {
			out << '<!DOCTYPE '.bytes()
			out << n.data.bytes()
			out << '>'.bytes()
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
				out << escape_string(a.val).bytes()
				out << `"`.bytes()
			}
			out << `>`.bytes()
			if !(n.namespace == '' && n.data in void_elements) {
				for c in n.children() {
					render_into(mut out, c)
				}
				out << '</'.bytes()
				out << n.data.bytes()
				out << `>`.bytes()
			}
		}
		else {}
	}
	if n.typ == .document_node {
		for c in n.children() {
			render_into(mut out, c)
		}
	}
}
