module useragent

fn check_agent(raw string, browser string, version string, platform string, os string, bot bool, mobile bool) {
	a := parse(raw)
	assert a.browser.text == browser, '${raw}: browser=${a.browser.text}'
	assert a.version.text == version, '${raw}: version=${a.version.text}'
	assert a.platform.text == platform, '${raw}: platform=${a.platform.text}'
	assert a.os.text == os, '${raw}: os=${a.os.text}'
	assert a.bot == bot, '${raw}: bot=${a.bot}'
	assert a.mobile == mobile, '${raw}: mobile=${a.mobile}'
}

fn test_go_vectors() {
	check_agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
		'Chrome', '126.0.0.0', 'Windows', 'Windows 10', false, false)
	check_agent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15',
		'Safari', '17.4', 'Macintosh', 'OS X 10.15.7', false, false)
	check_agent('Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1',
		'Safari', '17.4', 'iPhone', 'iOS 17.4', false, true)
	check_agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0',
		'Firefox', '121.0', 'Windows', 'Windows 10', false, false)
	check_agent('Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 6.0)', 'Internet Explorer',
		'8.0', 'Windows', 'Windows Vista', false, false)
	check_agent('Opera/9.80 (Windows NT 6.0) Presto/2.12.388 Version/12.14', 'Opera',
		'12.14', 'Windows', 'Windows Vista', false, false)
	check_agent('curl/8.0', 'curl', '8.0', '', '', false, false)
	check_agent('Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
		'Mozilla', '5.0', '', 'Googlebot/2.1', true, false)
	check_agent('Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
		'Chrome', '120.0.0.0', 'Android', 'Android 10', false, true)
	check_agent('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
		'Chrome', '120.0.0.0', 'X11', 'Linux x86_64', false, false)
}

fn test_blocked() {
	blocked, _ := parse('Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 6.0)').blocked()
	assert blocked == true
	blocked2, _ := parse('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36').blocked()
	assert blocked2 == false
}

fn test_compare() {
	assert compare('120', '120') == 0
	assert compare('119', '120') == -1
	assert compare('17.4', '17.2') == 1
	assert version_parts('10.15.7') == ['i:10', 'i:15', 'i:7']
}
