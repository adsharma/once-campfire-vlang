// Hand-rolled matchers for the eight patterns used by the useragent gem port,
// avoiding a regex dependency for small anchored expressions.
module useragent

fn is_digit_char(c u8) bool {
	return c >= `0` && c <= `9`
}

fn take_digits(s string) string {
	mut i := 0
	for i < s.len && (is_digit_char(s[i]) || s[i] == `.`) {
		i++
	}
	return s[..i]
}

// match_trident mirrors `Trident.+rv:`.
fn match_trident(s string) bool {
	idx := s.index('Trident') or { return false }
	rest := s[idx + 7..]
	rv := rest.index('rv:') or { return false }
	return rv > 0
}

// match_ie_version mirrors `(?:MSIE[ \t\n\r\v\f]|rv:)([0-9.]+)`.
fn match_ie_version(s string) ?string {
	mut i := 0
	for i < s.len {
		if s[i..].starts_with('MSIE') && i + 4 < s.len && is_space(s[i + 4]) {
			return take_digits(s[i + 5..])
		}
		if s[i..].starts_with('rv:') {
			return take_digits(s[i + 3..])
		}
		i++
	}
	return none
}

// match_opera_mini mirrors `Opera Mini/([0-9.]+)`.
fn match_opera_mini(s string) ?string {
	idx := s.index('Opera Mini/') or { return none }
	return take_digits(s[idx + 11..])
}

// match_webkit_comment mirrors `(?i)^AppleWebKit/([0-9.]+)`.
fn match_webkit_comment(s string) ?string {
	if s.len > 12 && s[..12].to_lower() == 'applewebkit/' {
		return take_digits(s[12..])
	}
	return none
}

// match_mac_version mirrors `(?:Intel|PPC) Mac OS X[ \t\r\n\v\f]*([0-9_.]+)?`
// and returns whether it matched plus the captured version (possibly empty).
fn match_mac_version(s string) (bool, string) {
	for marker in ['Intel Mac OS X', 'PPC Mac OS X'] {
		idx := s.index(marker) or { continue }
		rest := s[idx + marker.len..]
		mut i := 0
		for i < rest.len && (rest[i] == ` ` || rest[i] == `\t` || rest[i] == `\r` || rest[i] == `\n` || rest[i] == 11 || rest[i] == 12) {
			i++
		}
		mut j := i
		for j < rest.len && (is_digit_char(rest[j]) || rest[j] == `_` || rest[j] == `.`) {
			j++
		}
		return true, rest[i..j]
	}
	return false, ''
}

// match_ios_version mirrors `CPU (?:iPhone |iPod )?OS ([0-9_]+) like Mac OS X`.
fn match_ios_version(s string) string {
	idx := s.index('CPU ') or { return '' }
	mut rest := s[idx + 4..]
	if rest.starts_with('iPhone ') {
		rest = rest[7..]
	} else if rest.starts_with('iPod ') {
		rest = rest[5..]
	}
	if !rest.starts_with('OS ') {
		return ''
	}
	rest = rest[3..]
	mut i := 0
	for i < rest.len && (is_digit_char(rest[i]) || rest[i] == `_`) {
		i++
	}
	ver := rest[..i]
	if ver == '' || !rest[i..].starts_with(' like Mac OS X') {
		return ''
	}
	return ver
}

// match_ios_safari mirrors `iOS ([0-9.]+)`.
fn match_ios_safari(s string) ?string {
	idx := s.index('iOS ') or { return none }
	return take_digits(s[idx + 4..])
}

// match_chrome_os mirrors `CrOS[ \t\r\n\v\f][^ \t\r\n\v\f]+[ \t\r\n\v\f]([0-9]+(?:\.[0-9]+)*)`.
fn match_chrome_os(s string) string {
	mut i := 0
	for i < s.len {
		if s[i..].starts_with('CrOS') && i + 4 < s.len && is_space(s[i + 4]) {
			mut j := i + 5
			for j < s.len && !is_space(s[j]) {
				j++
			}
			if j < s.len {
				j++
				start := j
				for j < s.len && (is_digit_char(s[j]) || s[j] == `.`) {
					j++
				}
				if start != j {
					return s[start..j]
				}
			}
		}
		i++
	}
	return ''
}

// match_windows_os mirrors `Windows NT [0-9.]+|Windows Phone (?:OS )?[0-9.]+`
// and returns the first (leftmost) match.
fn match_windows_os(s string) string {
	mut best := -1
	mut best_val := ''
	nt := s.index('Windows NT ') or { -1 }
	if nt >= 0 {
		best = nt
		best_val = 'Windows NT ' + take_digits(s[nt + 11..])
	}
	ph := s.index('Windows Phone ') or { -1 }
	if ph >= 0 && (best < 0 || ph < best) {
		mut rest := s[ph + 14..]
		mut prefix := 'Windows Phone '
		if rest.starts_with('OS ') {
			rest = rest[3..]
			prefix += 'OS '
		}
		best = ph
		best_val = prefix + take_digits(rest)
	}
	if best < 0 {
		return ''
	}
	return best_val
}

fn normalize_os(s string) string {
	if v := windows_names[s] {
		return v
	}
	matched, ver := match_mac_version(s)
	if matched {
		if ver == '' {
			return 'OS X'
		}
		return 'OS X ' + ver.replace('_', '.')
	}
	_ = match_ios_version(s)
	// iOS tokens appear inside a longer comment; normalize the whole comment
	// the way the Go port passes the matching comment through.
	ios := ios_token(s)
	if ios != '' {
		return 'iOS ' + ios.replace('_', '.')
	}
	chrome := match_chrome_os(s)
	if chrome != '' {
		return 'ChromeOS ' + chrome
	}
	return s
}

// ios_token extracts the version from a `CPU ... OS x_y like Mac OS X` comment.
fn ios_token(s string) string {
	idx := s.index('CPU ') or { return '' }
	rest := s[idx..]
	os_idx := rest.index('OS ') or { return '' }
	after := rest[os_idx + 3..]
	mut i := 0
	for i < after.len && (is_digit_char(after[i]) || after[i] == `_`) {
		i++
	}
	if i == 0 || !after[i..].starts_with(' like Mac OS X') {
		return ''
	}
	return after[..i]
}

fn windows_player_os(version string) Value {
	parts := version_parts(version)
	if parts.len == 0 || !parts[0].starts_with('i:') {
		return raised_value()
	}
	part := fn (ps []string, i int) int {
		if i >= ps.len {
			return -1
		}
		p := ps[i]
		if !p.starts_with('i:') || p.len == 2 {
			return -1
		}
		num := p[2..]
		for c in num.bytes() {
			if c < `0` || c > `9` {
				return -1
			}
		}
		return num.int()
	}
	major := part(parts, 0)
	build := part(parts, 3)
	mut os := 'Windows'
	match true {
		major >= 0 && major <= 4 {
			os = match build {
				3564 { 'Windows 98' }
				3925 { 'Windows 98' }
				3857 { 'Windows 9x' }
				3936 { 'Windows XP' }
				3938 { 'Windows 2000' }
				else { '' }
			}
		}
		major == 7 {
			if build == 3055 {
				os = 'Windows 98'
			}
		}
		major == 8 {
			os = 'Windows XP'
		}
		major == 9 || major == 10 {
			os = match build {
				2980 { 'Windows 98/2000' }
				3268 { 'Windows 2000' }
				3367 { 'Windows 2000' }
				3270 { 'Windows 2000' }
				3802 { 'Windows XP' }
				4503 { 'Windows XP' }
				else { '' }
			}
		}
		major == 11 || major == 12 {
			os = match part(parts, 2) {
				9841 { 'Windows 10' }
				9858 { 'Windows 10' }
				9860 { 'Windows 10' }
				9879 { 'Windows 10' }
				9651 { 'Windows Phone 8.1' }
				9600 { 'Windows 8.1' }
				9200 { 'Windows 8' }
				7600 { 'Windows 7' }
				7601 { 'Windows 7' }
				6000 { 'Windows Vista' }
				6001 { 'Windows Vista' }
				6002 { 'Windows Vista' }
				5721 { 'Windows XP' }
				else { '' }
			}
		}
		else {}
	}
	if os == '' {
		os = 'Windows'
	}
	return value(os)
}
