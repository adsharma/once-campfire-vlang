// Package useragent preserves the useragent gem contracts used by Campfire.
module useragent

pub struct Value {
pub:
	text         string
	valid        bool
	raised       bool
}

fn value(s string) Value {
	return Value{text: s, valid: true}
}

fn raised_value() Value {
	return Value{raised: true}
}

pub struct Product {
pub mut:
	name    string
	version string
	comment []string
}

pub struct Agent {
pub mut:
	browser     Value
	version     Value
	platform    Value
	os          Value
	bot         bool
	mobile      bool
	mobile_error bool
	raw         string
	kind        string
	products    []Product
}

pub struct Platform {
pub mut:
	ios            bool
	android        bool
	mac            bool
	windows        bool
	chrome         bool
	firefox        bool
	safari         bool
	edge           bool
	mobile         bool
	desktop        bool
	apple_messages bool
	browser        string
	operating_system string
}

fn ruby_strip(s string) string {
	mut start := 0
	for start < s.len && is_strip(s[start]) {
		start++
	}
	mut end := s.len
	for end > start && is_strip(s[end - 1]) {
		end--
	}
	return s[start..end]
}

fn is_strip(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == 11 || c == 12 || c == 0
}

fn split_trim(s string, sep string) []string {
	mut parts := s.split(sep)
	for parts.len > 0 && parts[parts.len - 1] == '' {
		parts = parts[..parts.len - 1]
	}
	return parts
}

fn is_space(b u8) bool {
	return b == ` ` || b == `\t` || b == `\n` || b == `\r` || b == 11 || b == 12
}

fn parse_product(s string) (Product, int) {
	if s == '' {
		return Product{}, 0
	}
	mut start := 0
	for start < s.len && (s[start] == `'` || s[start] == `"`) {
		start++
	}
	good := fn (b u8) bool {
		return b != `/` && !is_space(b)
	}
	if start == s.len || !good(s[start]) {
		if start > 0 {
			start--
		} else {
			return Product{}, 0
		}
	}
	mut i := start + 1
	for i < s.len && good(s[i]) {
		i++
	}
	mut p := Product{name: s[start..i]}
	if i < s.len && s[i] == `/` {
		i++
	}
	begin := i
	for i < s.len && !is_space(s[i]) && s[i] != `,` {
		i++
	}
	p.version = s[begin..i]
	if i + 1 < s.len && is_space(s[i]) && s[i + 1] == `(` {
		end := s[i + 2..].index(')') or { -1 }
		if end >= 0 {
			p.comment = split_trim(s[i + 2..i + 2 + end], '; ')
			if p.comment.len == 0 {
				p.comment = []string{}
			}
			i += end + 3
		}
	} else if s[i..].starts_with(',gzip(gfe)') {
		i += 10
	}
	return p, i
}

pub fn parse(raw string) Agent {
	mut a := Agent{raw: raw, kind: 'base'}
	mut rest := raw
	if ruby_strip(rest) == '' {
		rest = 'Mozilla/4.0 (compatible)'
	}
	for {
		p, n := parse_product(rest)
		if n == 0 {
			break
		}
		a.products << p
		rest = ruby_strip(rest[n..])
	}
	first := a.first()
	last := a.last()
	any := fn (ps []Product, name string) bool {
		for p in ps {
			if p.name == name {
				return true
			}
		}
		return false
	}
	comments := first.comment
	joined := comments.join(' ')
	match true {
		last.name == 'Edge' {
			a.kind = 'edge'
		}
		comments.len > 0 && (at(comments, 1).text.contains('MSIE') || match_trident(joined)) {
			a.kind = 'ie'
		}
		first.name == 'Opera' || last.name == 'OPR' {
			a.kind = 'opera'
		}
		a.contains_product('micromessenger') {
			a.kind = 'wechat'
		}
		any(a.products, 'Vivaldi') {
			a.kind = 'vivaldi'
		}
		any(a.products, 'Chrome') || any(a.products, 'CriOS') {
			a.kind = 'chrome'
		}
		any(a.products, 'iTunes') {
			a.kind = 'itunes'
		}
		contains_any(at(comments, 0).text, 'PLAYSTATION 3', 'PlayStation Vita', 'PlayStation 4') {
			a.kind = 'playstation'
		}
		a.products.len >= 3 && a.products[0].name == 'Podcast' && a.products[1].name == 'Addict' && a.products[2].name == '-' {
			a.kind = 'podcast'
		}
		a.webkit().valid {
			a.kind = 'webkit'
		}
		first.name == 'Mozilla' {
			a.kind = 'gecko'
		}
		(any(a.products, 'NSPlayer') || any(a.products, 'Windows-Media-Player') || any(a.products, 'WMFSDK')) && !contains_exact(first.version, '4.1.0.3856', '7.10.0.3059', '7.0.0.1956') {
			a.kind = 'wmp'
		}
		any(a.products, 'AppleCoreMedia') {
			a.kind = 'coremedia'
		}
		any(a.products, 'Lavf') || (any(a.products, 'NSPlayer') && first.version == '4.1.0.3856') {
			a.kind = 'lavf'
		}
		else {}
	}
	a.os = a.operating_system()
	a.platform = a.platform_value()
	a.browser = a.browser_value()
	a.version = a.version_value()
	app_bot := if app := a.application() { app.name.contains('bot') } else { true }
	lighthouse := a.detect('Chrome-Lighthouse')
	a.bot = app_bot || lighthouse != none
	for p in a.products {
		for c in p.comment {
			a.bot = a.bot || c.to_lower().contains('bot')
		}
	}
	match a.kind {
		'opera' {
			a.mobile = a.opera_mini()
		}
		'playstation' {
			a.mobile = a.platform.text == 'PlayStation Vita'
		}
		'podcast' {
			a.mobile = true
		}
		'wmp' {
			a.mobile_error = a.os.raised
			a.mobile = contains_exact(a.os.text, 'Windows Phone 8', 'Windows Phone 8.1')
		}
		else {
			a.mobile = a.detect('Mobile') != none
			for p in a.products {
				for c in p.comment {
					a.mobile = a.mobile || c == 'Mobile'
				}
			}
			if !a.mobile {
				a.mobile_error = a.os.raised
				a.mobile = a.os.text.contains('Android')
			}
			for c in a.comments() {
				a.mobile = a.mobile || c.starts_with('IEMobile')
			}
		}
	}
	return a
}

fn contains_exact(s string, options ...string) bool {
	for v in options {
		if s == v {
			return true
		}
	}
	return false
}

fn contains_any(s string, options ...string) bool {
	for v in options {
		if s.contains(v) {
			return true
		}
	}
	return false
}

fn at(v []string, i int) Value {
	if i < v.len {
		return value(v[i])
	}
	return Value{}
}

fn (a Agent) first() Product {
	if a.products.len > 0 {
		return a.products[0]
	}
	return Product{}
}

fn (a Agent) last() Product {
	if a.products.len > 0 {
		return a.products[a.products.len - 1]
	}
	return Product{}
}

fn (a Agent) detect(name string) ?Product {
	for p in a.products {
		if ruby_lower(p.name) == ruby_lower(name) {
			return p
		}
	}
	return none
}

fn (a Agent) contains_product(name string) bool {
	for p in a.products {
		if ruby_lower(p.name).contains(name) {
			return true
		}
	}
	return false
}

fn (a Agent) application() ?Product {
	if contains_exact(a.kind, 'chrome', 'vivaldi', 'webkit', 'itunes', 'coremedia') {
		for p in a.products {
			if p.comment.len > 0 {
				return p
			}
		}
		return none
	}
	if a.products.len > 0 {
		return a.products[0]
	}
	return none
}

fn (a Agent) comments() []string {
	if p := a.application() {
		return p.comment
	}
	return []
}

fn (a Agent) base_version() Value {
	if p := a.application() {
		return value(p.version)
	}
	return Value{}
}

fn (a Agent) webkit() Value {
	if p := a.detect('AppleWebKit') {
		return value(p.version)
	}
	for p in a.products {
		for c in p.comment {
			if m := match_webkit_comment(c) {
				return value(m)
			}
		}
	}
	return Value{}
}

fn (a Agent) opera_mini() bool {
	return a.first().comment.join(' ').contains('Opera Mini')
}

fn browser_name(kind string) string {
	match kind {
		'edge' { return 'Edge' }
		'ie' { return 'Internet Explorer' }
		'opera' { return 'Opera' }
		'wechat' { return 'Wechat Browser' }
		'vivaldi' { return 'Vivaldi' }
		'itunes' { return 'iTunes' }
		'podcast' { return 'Podcast Addict' }
		'wmp' { return 'Windows Media Player' }
		'coremedia' { return 'AppleCoreMedia' }
		'lavf' { return 'libavformat' }
		else { return '' }
	}
}

fn (a Agent) browser_value() Value {
	match a.kind {
		'base' {
			if p := a.application() {
				return value(p.name)
			}
			return Value{}
		}
		'chrome' {
			if _ := a.detect('Iron') {
				return value('Iron')
			}
			return value('Chrome')
		}
		'playstation' {
			c := at(a.comments(), 0).text
			if c.contains('PLAYSTATION 3') {
				return value('PS3 Internet Browser')
			}
			if a.last().name == 'Silk' {
				return value('Silk')
			}
			if c.contains('PlayStation 4') {
				return value('PS4 Internet Browser')
			}
			return Value{}
		}
		'webkit' {
			if a.os.text.contains('Android') {
				return value('Android')
			}
			if a.platform.text == 'BlackBerry' {
				return value('BlackBerry')
			}
			return value('Safari')
		}
		'gecko' {
			for name in ['PaleMoon', 'Firefox', 'Camino', 'Iceweasel', 'Seamonkey'] {
				if _ := a.detect(name) {
					return value(name)
				}
			}
			return value(a.first().name)
		}
		else {
			return value(browser_name(a.kind))
		}
	}
}

fn (a Agent) version_value() Value {
	match a.kind {
		'base', 'wmp', 'coremedia' {
			return a.base_version()
		}
		'edge', 'vivaldi' {
			return value(a.last().version)
		}
		'ie' {
			if m := match_ie_version(a.comments().join(' ')) {
				return value(m)
			}
			return value('')
		}
		'opera' {
			if a.opera_mini() {
				for c in a.comments() {
					if c.contains('Opera Mini') {
						if m := match_opera_mini(c) {
							return value(m)
						}
						break
					}
				}
				return value('')
			}
			if p := a.detect('Version') {
				return value(p.version)
			}
			if p := a.detect('OPR') {
				return value(p.version)
			}
			return a.base_version()
		}
		'wechat' {
			return a.detect_version('MicroMessenger')
		}
		'chrome' {
			if _ := a.detect('CriOS') {
				return a.detect_version('CriOS')
			}
			return a.detect_version('Chrome')
		}
		'itunes' {
			return a.detect_version('iTunes')
		}
		'playstation' {
			if !a.os.valid {
				return Value{}
			}
			if a.browser.text == 'Silk' {
				return value(a.last().version)
			}
			mut marker := a.platform.text + ' '
			if a.platform.text == 'PlayStation 3' {
				marker = 'PLAYSTATION 3 '
			}
			parts := split_trim(a.os.text, marker)
			if a.platform.valid && parts.len > 0 {
				return value(parts[parts.len - 1])
			}
			return Value{}
		}
		'podcast' {
			return Value{}
		}
		'webkit' {
			if p := a.detect('Version') {
				return value(p.version)
			}
			ios_ver := match_ios_safari(a.os.text) or { '' }
			if ios_ver != '' && a.browser.text == 'Safari' {
				return value(ios_ver)
			}
			return value(webkit_build_versions[a.webkit().text])
		}
		'gecko' {
			v := a.detect_version(a.browser.text)
			if !v.raised && ruby_strip(v.text) == '' {
				return a.base_version()
			}
			return v
		}
		'lavf' {
			if _ := a.detect('NSPlayer') {
				return Value{}
			}
			return a.base_version()
		}
		else {
			return Value{}
		}
	}
}

fn (a Agent) detect_version(name string) Value {
	if p := a.detect(name) {
		return value(p.version)
	}
	return raised_value()
}

fn (a Agent) platform_value() Value {
	c := a.comments()
	first := at(c, 0)
	match a.kind {
		'base', 'lavf' {
			return Value{}
		}
		'edge', 'ie', 'wmp' {
			return value('Windows')
		}
		'opera', 'coremedia' {
			if first.text.contains('Windows') {
				return value('Windows')
			}
			return first
		}
		'wechat' {
			if first.text.contains('iPhone') {
				return value('iPhone')
			}
			for v in c {
				if v.contains('Android') {
					return value('Android')
				}
			}
			return first
		}
		'chrome', 'vivaldi' {
			if first.text.contains('Windows') {
				return value('Windows')
			}
			for needle in ['CrOS', 'Android'] {
				for v in c {
					if v.contains(needle) {
						if needle == 'CrOS' {
							return value('ChromeOS')
						}
						return value('Android')
					}
				}
			}
			return first
		}
		'webkit', 'itunes' {
			if first.text.contains('Windows') {
				return value('Windows')
			}
			if first.text == 'BB10' {
				return value('BlackBerry')
			}
			for v in c {
				if v.contains('Android') {
					return value('Android')
				}
			}
			return first
		}
		'playstation' {
			for pair in [['PLAYSTATION 3', 'PlayStation 3'], ['PlayStation 4', 'PlayStation 4'],
				['PlayStation Vita', 'PlayStation Vita']] {
				if a.os.text.contains(pair[0]) {
					return value(pair[1])
				}
			}
			return Value{}
		}
		'podcast' {
			if a.os.raised || !a.os.valid {
				return raised_value()
			}
			if a.os.text.contains('Android') {
				return value('Android')
			}
			return Value{}
		}
		'gecko' {
			if contains_exact(first.text, 'compatible', 'Mobile') {
				return Value{}
			}
			if first.text.starts_with('Windows ') {
				return value('Windows')
			}
			return first
		}
		else {
			return Value{}
		}
	}
}

fn (a Agent) operating_system() Value {
	c := a.comments()
	first := at(c, 0)
	match a.kind {
		'base', 'lavf' {
			return Value{}
		}
		'edge' {
			for p in a.products {
				for cc in p.comment {
					m := match_windows_os(cc)
					if m != '' {
						return value(normalize_os(m))
					}
				}
			}
			return value('')
		}
		'ie' {
			return value(normalize_os(match_windows_os(c.join(' '))))
		}
		'opera' {
			if first.text.contains('Windows') {
				return norm_os(first)
			}
			return at(c, 1)
		}
		'chrome', 'vivaldi', 'wechat', 'coremedia' {
			if first.text.contains('Windows NT') {
				return norm_os(first)
			}
			if c.len < 3 || at(c, 1).text.contains('Android') {
				return norm_os(at(c, 1))
			}
			return norm_os(at(c, 2))
		}
		'webkit', 'itunes' {
			if a.kind == 'itunes' && first.text.contains('Windows') {
				full := at(c, 1).text
				for name in ['Windows 8.1', 'Windows 8', 'Windows 7', 'Windows Vista', 'Windows XP'] {
					if full.contains(name) {
						return value(name)
					}
				}
				return value('Windows')
			}
			if first.text.contains('Windows NT') {
				return norm_os(first)
			}
			if c.len < 3 || at(c, 1).text.contains('Android') {
				return norm_os(at(c, 1))
			}
			for v in c {
				if match_ios_version(v) != '' {
					return value(normalize_os(v))
				}
			}
			return norm_os(at(c, 2))
		}
		'playstation' {
			if c.len > 0 {
				return value(c.join(' '))
			}
			return Value{}
		}
		'podcast' {
			if a.products.len < 4 {
				return Value{}
			}
			p := a.products[3]
			if p.name != 'Dalvik' && p.name != 'Mozilla' {
				return Value{}
			}
			if p.comment.len == 0 {
				return raised_value()
			}
			if p.comment.len > 3 {
				return at(p.comment, 2)
			}
			if p.comment.len == 3 {
				return value('Android')
			}
			return Value{}
		}
		'gecko' {
			if at(c, 1).text == 'U' {
				return norm_os(at(c, 2))
			}
			if first.text.starts_with('Windows ') || first.text.starts_with('Android') {
				return norm_os(first)
			}
			if first.text == 'Mobile' {
				return Value{}
			}
			return norm_os(at(c, 1))
		}
		'wmp' {
			return windows_player_os(a.base_version().text)
		}
		else {
			return Value{}
		}
	}
}

fn norm_os(v Value) Value {
	if v.valid {
		return value(normalize_os(v.text))
	}
	return v
}

fn (a Agent) application_os() Value {
	if a.platform.raised {
		return raised_value()
	}
	for pair in [['Android', 'Android'], ['iPad', 'iPad'], ['iPhone', 'iPhone'],
		['Macintosh', 'macOS'], ['Windows', 'Windows'], ['CrOS', 'ChromeOS']] {
		if a.platform.text.contains(pair[0]) {
			return value(pair[1])
		}
	}
	if a.os.text.contains('Linux') {
		return value('Linux')
	}
	return a.os
}

pub fn (a Agent) view() Platform {
	mut p := Platform{
		ios:              a.raw.contains('iPhone') || a.raw.contains('iPad')
		android:          a.raw.contains('Android')
		mac:              a.raw.contains('Macintosh')
		browser:          a.browser.text
		operating_system: a.application_os().text
	}
	p.chrome = p.browser.contains('Chrome')
	p.firefox = p.browser.contains('Firefox') || p.browser.contains('FxiOS')
	p.safari = p.browser.contains('Safari')
	p.edge = p.browser.contains('Edg')
	p.mobile = p.ios || p.android
	p.desktop = !p.mobile
	p.windows = p.operating_system == 'Windows'
	lower := a.raw.to_lower()
	p.apple_messages = lower.contains('facebookexternalhit') && lower.contains('twitterbot')
	return p
}

pub fn (a Agent) blocked() (bool, bool) {
	if a.version.raised {
		return false, true
	}
	if !a.version.valid || a.version.text.trim_space() == '' {
		return false, false
	}
	if a.browser.raised || !a.browser.valid {
		return false, true
	}
	browser := a.browser.text.to_lower()
	minimum := match browser {
		'safari' { '17.2' }
		'chrome' { '120' }
		'firefox' { '121' }
		'opera' { '104' }
		'internet explorer' { '' }
		else { return false, false }
	}
	known := browser in ['safari', 'chrome', 'firefox', 'opera', 'internet explorer']
	return known && (minimum == '' || compare(a.version.text, minimum) < 0) && !a.bot, false
}

fn ruby_lower(s string) string {
	return s.replace('İ', 'i̇').to_lower()
}
