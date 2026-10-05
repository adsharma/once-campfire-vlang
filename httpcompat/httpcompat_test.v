module httpcompat

fn test_parse_accept_vectors() {
	assert parse_accept('text/html')! == ['html']
	assert parse_accept('text/html,application/json;q=0.9')! == ['html', 'json']
	assert parse_accept('application/json')! == ['json']
	assert parse_accept('*/*')! == ['*/*']
	assert parse_accept('text/*')! == ['html', 'text', 'js', 'css', 'ics', 'csv', 'vcf',
		'vtt', 'md', 'xml', 'yaml', 'json', 'turbo_stream']
	if _ := parse_accept('invalid;;') {
		assert false, 'expected MIME error'
	} else {
		assert err.msg() == 'invalid MIME type'
	}
}

fn check_ranges(header string, size i64, want [][]i64) {
	r := byte_ranges(header, size) or {
		assert false, 'expected ranges for ${header}'
		return
	}
	assert r == want
}

fn test_byte_ranges_vectors() {
	check_ranges('bytes=0-99', 1000, [[i64(0), i64(99)]])
	check_ranges('bytes=500-', 1000, [[i64(500), i64(999)]])
	check_ranges('bytes=-200', 1000, [[i64(800), i64(999)]])
	check_ranges('bytes=0-0,-1', 1000, [[i64(0), i64(0)], [i64(999), i64(999)]])
	if r := byte_ranges('foo=bar', 1000) {
		assert false, 'expected none, got ${r}'
	}
}

fn test_ruby_float() {
	assert ruby_float('0.9') == 0.9
	assert ruby_float(' 1.5 ') == 1.5
	assert ruby_float('0x10') == 0
	assert ruby_float('+0x10') == 16
}

fn test_formats_negotiate() {
	assert formats(FormatInput{format: 'json'})! == ['json']
	assert negotiate(FormatInput{accept: 'text/html'}, 'html', 'json')! == 'html'
}
