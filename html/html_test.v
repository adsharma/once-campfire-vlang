module html

fn dump_tree(n &Node, depth int) string {
	mut s := ''
	for _ in 0 .. depth {
		s += '  '
	}
	match n.typ {
		.text_node {
			s += 'text:${n.data}\n'
		}
		.comment_node {
			s += 'comment:${n.data}\n'
		}
		.element_node {
			s += '<${n.data}> ns=${n.namespace} attrs=${n.attr}\n'
			for c in n.children() {
				s = s + dump_tree(c, depth + 1)
			}
		}
		else {
			s += '${n.typ}\n'
		}
	}
	return s
}

fn input_dump(input string) string {
	nodes := parse_fragment(input, 'body') or { return 'ERROR: ${err}' }
	mut s := ''
	for n in nodes {
		s = s + dump_tree(n, 0)
	}
	return s
}

fn test_basic_parse() {
	assert input_dump('<p>hi</p>') == '<p> ns= attrs=[]\n  text:hi\n'
	assert input_dump('<b><i>x</b></i>') == '<b> ns= attrs=[]\n  <i> ns= attrs=[]\n    text:x\n'
}

fn test_entities() {
	assert unescape_string('&lt;&amp;&nbsp;&#65;&#x42;&copy') == '<& AB©'
	assert unescape_string('&notit;') == '¬it;'
}

fn test_misnested_table() {
	println(input_dump('<table><tr><td>a<td>b</table>'))
}
