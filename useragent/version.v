module useragent

fn is_version_start(s string) bool {
	if s.len == 0 || s[0] < `0` || s[0] > `9` {
		return false
	}
	mut i := 0
	for i < s.len && s[i] >= `0` && s[i] <= `9` {
		i++
	}
	return i == s.len || s[i] == `.`
}

fn is_word_byte(c u8) bool {
	return (c >= `0` && c <= `9`) || (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || c == `-`
}

fn is_letter(c u8) bool {
	return (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`)
}

// version_parts mirrors the Go port's comparableVersion/versionSequences split.
pub fn version_parts(s string) []string {
	if ruby_strip(s) == '' {
		return []string{}
	}
	if !is_version_start(s) {
		return ['s:' + s]
	}
	mut result := []string{}
	mut i := 0
	for i < s.len {
		c := s[i]
		if c >= `0` && c <= `9` {
			mut j := i
			for j < s.len && s[j] >= `0` && s[j] <= `9` {
				j++
			}
			mut part := s[i..j]
			for part.starts_with('0') && part.len > 1 {
				part = part[1..]
			}
			result << 'i:' + part
			i = j
		} else if is_letter(c) {
			// [A-Za-z][0-9A-Za-z-]*$ only matches at the end of the string.
			mut j := i + 1
			for j < s.len && is_word_byte(s[j]) {
				j++
			}
			if j == s.len {
				result << 's:' + s[i..j]
				i = j
			} else {
				i++
			}
		} else {
			i++
		}
	}
	return result
}

fn cmp_str(a string, b string) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

pub fn compare(a string, b string) int {
	if !is_version_start(a) {
		if a == b {
			return 0
		}
		return -1
	}
	ours := version_parts(a)
	theirs := version_parts(b)
	for i in 0 .. 6 {
		x := if i < ours.len { ours[i] } else { 'i:0' }
		y := if i < theirs.len { theirs[i] } else { 'i:0' }
		if x == y {
			continue
		}
		if x[0] != y[0] {
			if x[0] == `s` {
				return -1
			}
			return 1
		}
		if x[0] == `i` && x.len != y.len {
			if x.len < y.len {
				return -1
			}
			return 1
		}
		return cmp_str(x[2..], y[2..])
	}
	return 0
}

// Tables from the pinned useragent gem compatibility implementation.
const windows_names = {
	'Windows NT 10.0': 'Windows 10'
	'Windows NT 6.3':  'Windows 8.1'
	'Windows NT 6.2':  'Windows 8'
	'Windows NT 6.1':  'Windows 7'
	'Windows NT 6.0':  'Windows Vista'
	'Windows NT 5.2':  'Windows XP x64 Edition'
	'Windows NT 5.1':  'Windows XP'
	'Windows NT 5.01': 'Windows 2000, Service Pack 1 (SP1)'
	'Windows NT 5.0':  'Windows 2000'
	'Windows NT 4.0':  'Windows NT 4.0'
	'Windows 98':      'Windows 98'
	'Windows 95':      'Windows 95'
	'Windows CE':      'Windows CE'
}

const webkit_build_versions = {
	'85.7':     '1.0'
	'85.8.5':   '1.0.3'
	'85.8.2':   '1.0.3'
	'124':      '1.2'
	'125.2':    '1.2.2'
	'125.4':    '1.2.3'
	'125.5.5':  '1.2.4'
	'125.5.6':  '1.2.4'
	'125.5.7':  '1.2.4'
	'312.1.1':  '1.3'
	'312.1':    '1.3'
	'312.5':    '1.3.1'
	'312.5.1':  '1.3.1'
	'312.5.2':  '1.3.1'
	'312.8':    '1.3.2'
	'312.8.1':  '1.3.2'
	'412':      '2.0'
	'412.6':    '2.0'
	'412.6.2':  '2.0'
	'412.7':    '2.0.1'
	'416.11':   '2.0.2'
	'416.12':   '2.0.2'
	'417.9':    '2.0.3'
	'418':      '2.0.3'
	'418.8':    '2.0.4'
	'418.9':    '2.0.4'
	'418.9.1':  '2.0.4'
	'419':      '2.0.4'
	'425.13':   '2.2'
	'534.52.7': '5.1.2'
}
