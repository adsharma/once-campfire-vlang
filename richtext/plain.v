module richtext

import html

fn chomp(s string) string {
	return s.trim_right('\r\n')
}

fn plain(n &html.Node) string {
	if n.typ == .text_node {
		return chomp(n.data)
	}
	if n.typ == .comment_node {
		return ''
	}
	if n.data == 'script' || n.data == 'style' || n.data == 'unsupported' {
		return ''
	}
	mut text := ''
	for c in n.children() {
		text += plain(c)
	}
	mut depth := 0
	mut list := ''
	mut p := n.parent
	for {
		par := p or { break }
		if par.data == 'ul' || par.data == 'ol' {
			depth++
			if list == '' {
				list = par.data
			}
		}
		p = par.parent
	}
	match n.data {
		'p', 'h1' {
			return chomp(text) + '\n\n'
		}
		'ul', 'ol' {
			if depth > 0 {
				return '\n' + chomp(text) + '\n\n'
			}
			return chomp(text) + '\n\n'
		}
		'br' {
			return '\n'
		}
		'div' {
			return chomp(text) + '\n'
		}
		'figcaption' {
			return '[' + chomp(text) + ']'
		}
		'blockquote' {
			text = chomp(text) + '\n\n'
			trimmed := text.trim(' \t\n\x0b\x0c\r')
			if trimmed == '' {
				return '“”'
			}
			first := text.index(trimmed) or { 0 }
			return text[..first] + '“' + trimmed + '”' + text[first + trimmed.len..]
		}
		'li' {
			mut bullet := '•'
			if list == 'ol' {
				mut index := 1
				mut prev := n.prev_sibling
				for {
					sib := prev or { break }
					if sib.typ == .element_node {
						index++
					}
					prev = sib.prev_sibling
				}
				bullet = '${index}.'
			}
			mut indent := ''
			if depth > 1 {
				for _ in 0 .. depth - 1 {
					indent += '  '
				}
			}
			return indent + bullet + ' ' + chomp(text) + '\n'
		}
		else {
			return text
		}
	}
}
