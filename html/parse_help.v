module html

fn is_all_space(s string) bool {
	for c in s.bytes() {
		if c != ` ` && c != `\t` && c != `\n` && c != `\x0c` && c != `\r` {
			return false
		}
	}
	return true
}

// clear_to_table_context pops until the current node is table-ish or the bottom.
fn (mut p Parser) clear_to_table_context() {
	for p.stack.len > 0 {
		t := p.stack[p.stack.len - 1]
		if t.namespace == '' && (t.data == 'table' || t.data == 'template' || t.data == 'html') {
			break
		}
		if p.stack.len == 1 {
			break
		}
		p.stack.pop()
	}
}

fn (mut p Parser) clear_to_table_body() {
	for p.stack.len > 1 {
		t := p.stack[p.stack.len - 1]
		if t.namespace == '' && (t.data == 'tbody' || t.data == 'thead' || t.data == 'tfoot' || t.data == 'template' || t.data == 'html') {
			break
		}
		p.stack.pop()
	}
}

fn (mut p Parser) clear_to_table_row() {
	for p.stack.len > 1 {
		t := p.stack[p.stack.len - 1]
		if t.namespace == '' && (t.data == 'tr' || t.data == 'template' || t.data == 'html') {
			break
		}
		p.stack.pop()
	}
}

fn (mut p Parser) in_select() bool {
	for i := p.stack.len - 1; i >= 0; i-- {
		n := p.stack[i]
		if n.data == 'select' && n.namespace == '' {
			return true
		}
		if n.data in ['table', 'template', 'html'] && n.namespace == '' {
			return false
		}
	}
	return false
}

fn (mut p Parser) in_table() bool {
	return p.foster_table() != none && !p.in_cell()
}

fn (mut p Parser) adjust_math_attrs(mut node Node) {
	for i, a in node.attr {
		if a.key == 'definitionurl' {
			node.attr[i].key = 'definitionURL'
		}
	}
}

fn (mut p Parser) adjust_svg_attrs(mut node Node) {
	for i, a in node.attr {
		fixed := match a.key {
			'attributename' { 'attributeName' }
			'attributetype' { 'attributeType' }
			'basefrequency' { 'baseFrequency' }
			'baseprofile' { 'baseProfile' }
			'calcmode' { 'calcMode' }
			'clippathunits' { 'clipPathUnits' }
			'diffuseconstant' { 'diffuseConstant' }
			'edgemode' { 'edgeMode' }
			'filterunits' { 'filterUnits' }
			'glyphref' { 'glyphRef' }
			'gradienttransform' { 'gradientTransform' }
			'gradientunits' { 'gradientUnits' }
			'kernelmatrix' { 'kernelMatrix' }
			'kernelunitlength' { 'kernelUnitLength' }
			'keypoints' { 'keyPoints' }
			'keysplines' { 'keySplines' }
			'keytimes' { 'keyTimes' }
			'lengthadjust' { 'lengthAdjust' }
			'limitingconeangle' { 'limitingConeAngle' }
			'markerheight' { 'markerHeight' }
			'markerunits' { 'markerUnits' }
			'markerwidth' { 'markerWidth' }
			'maskcontentunits' { 'maskContentUnits' }
			'maskunits' { 'maskUnits' }
			'numoctaves' { 'numOctaves' }
			'pathlength' { 'pathLength' }
			'patterncontentunits' { 'patternContentUnits' }
			'patterntransform' { 'patternTransform' }
			'patternunits' { 'patternUnits' }
			'pointsatx' { 'pointsAtX' }
			'pointsaty' { 'pointsAtY' }
			'pointsatz' { 'pointsAtZ' }
			'preservealpha' { 'preserveAlpha' }
			'preserveaspectratio' { 'preserveAspectRatio' }
			'primitiveunits' { 'primitiveUnits' }
			'refx' { 'refX' }
			'refy' { 'refY' }
			'repeatcount' { 'repeatCount' }
			'repeatdur' { 'repeatDur' }
			'requiredextensions' { 'requiredExtensions' }
			'requiredfeatures' { 'requiredFeatures' }
			'specularconstant' { 'specularConstant' }
			'specularexponent' { 'specularExponent' }
			'spreadmethod' { 'spreadMethod' }
			'startoffset' { 'startOffset' }
			'stddeviation' { 'stdDeviation' }
			'stitchtiles' { 'stitchTiles' }
			'surfacescale' { 'surfaceScale' }
			'systemlanguage' { 'systemLanguage' }
			'tablevalues' { 'tableValues' }
			'targetx' { 'targetX' }
			'targety' { 'targetY' }
			'textlength' { 'textLength' }
			'viewbox' { 'viewBox' }
			'viewtarget' { 'viewTarget' }
			'xchannelselector' { 'xChannelSelector' }
			'ychannelselector' { 'yChannelSelector' }
			'zoomandpan' { 'zoomAndPan' }
			else { '' }
		}
		if fixed != '' {
			node.attr[i].key = fixed
		}
		if a.key in ['xlink:actuate', 'xlink:arcrole', 'xlink:href', 'xlink:role',
			'xlink:show', 'xlink:title', 'xlink:type'] {
			parts := a.key.split(':')
			node.attr[i].namespace = 'xlink'
			node.attr[i].key = parts[1]
		}
		if a.key in ['xml:actuate', 'xml:base', 'xml:lang', 'xml:space'] {
			parts := a.key.split(':')
			node.attr[i].namespace = 'xml'
			node.attr[i].key = parts[1]
		}
		if a.key == 'xmlns' || a.key == 'xmlns:xlink' {
			node.attr[i].namespace = 'xmlns'
		}
	}
}

fn (mut p Parser) in_cell() bool {
	for i := p.stack.len - 1; i >= 0; i-- {
		n := p.stack[i]
		if n.namespace == '' && (n.data == 'td' || n.data == 'th') {
			return true
		}
		if n.namespace == '' && (n.data == 'table' || n.data == 'template' || n.data == 'html') {
			return false
		}
	}
	return false
}
