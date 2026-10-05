module integrations

// Differential vectors ported from the Go port's network_test.go
// (TestAddressPolicy, TestGuardRejectsNumericAndMixedAnswers).

fn test_blocked_suite() {
	blocked_cases := [
		'0.0.0.0',
		'10.1.2.3',
		'100.64.0.1',
		'127.0.0.1',
		'168.63.129.16',
		'169.254.169.254',
		'172.16.0.0',
		'172.31.255.255',
		'192.0.0.8',
		'192.0.2.1',
		'192.88.99.1',
		'192.168.1.1',
		'198.18.0.1',
		'198.51.100.1',
		'203.0.113.1',
		'224.0.0.1',
		'240.0.0.1',
		'255.255.255.255',
		'::',
		'::1',
		'::ffff:192.168.1.1',
		'::ffff:8.8.8.8',
		'::8.8.8.8',
		'64:ff9b::a00:1',
		'64:ff9b:1::1',
		'::ffff:0:a00:1',
		'fc00::1',
		'fd00::1',
		'fe80::1',
		'fec0::1',
		'ff02::1',
		'2001::1',
		'2001:db8::1',
		'2002::1',
		'3fff::1',
		'5f00::1',
		'100::1',
		'2001:2::1',
		'4000::1',
		'2001:10::1',
	]
	for ip in blocked_cases {
		addr := parse_ip(ip) or { panic('cannot parse ${ip}') }
		assert blocked(addr), 'expected blocked: ${ip}'
	}
	public_cases := [
		'8.8.8.8',
		'1.1.1.1',
		'93.184.216.34',
		'142.250.185.206',
		'172.32.0.1',
		'100.128.0.1',
		'192.0.1.1',
		'2606:2800:220:1:248:1893:25c8:1946',
		'2a00:1450:4001:82a::200e',
		'2001:3::1',
		'2001:4:112::1',
		'64:ff9b::808:808',
		'::ffff:0:808:808',
		'2c0f:ffff::1',
	]
	for ip in public_cases {
		addr := parse_ip(ip) or { panic('cannot parse ${ip}') }
		assert !blocked(addr), 'expected public: ${ip}'
	}
}

struct FakeState {
pub mut:
	hosts map[string][]string
	calls map[string]int
	log   []string
}

struct FakeResolver {
mut:
	state &FakeState
}

fn new_fake_resolver(hosts map[string][]string) (FakeResolver, &FakeState) {
	mut st := &FakeState{hosts: hosts}
	return FakeResolver{state: st}, st
}

fn (mut f FakeResolver) lookup_net_ip(host string) ![]IpAddr {
	f.state.log << host
	answers := f.state.hosts[host]
	if answers.len == 0 {
		return error('unknown host ${host}')
	}
	n := f.state.calls[host]
	f.state.calls[host] = n + 1
	list := if n < answers.len { answers[n] } else { answers[answers.len - 1] }
	mut out := []IpAddr{}
	for s in list.split(',') {
		out << (parse_ip(s) or { return error('bad fixture ip ${s}') })
	}
	return out
}

fn test_guard_rejects_numeric_and_mixed() {
	mut r, _ := new_fake_resolver({
		'mixed.example': ['10.0.0.1,93.184.216.34']
	})
	for host in ['127.1', '0x7f.1', '2130706433', '0177.0.0.01', '[::1]', 'under_score.example', 'a..b', '1.2.3.4.'] {
		mut rejected := false
		if _ := resolve_public(host, mut r) {
		} else {
			rejected = true
		}
		assert rejected, 'expected rejection: ${host}'
	}
	ip := resolve_public('mixed.example', mut r) or { panic('mixed.example: ${err}') }
	assert ip.str() == '93.184.216.34'
}

fn test_push_endpoint() {
	for s in ['http://fcm.googleapis.com/x', 'https://fcm.googleapis.com:444/x', 'https://fcm.googleapis.com.attacker.test/x', 'https://localhost/x', 'https://fcm.googleapis.com/a b'] {
		if _ := push_endpoint(s) {
			assert false, 'expected push endpoint rejection: ${s}'
		} else {
		}
	}
	for s in ['https://fcm.googleapis.com/x', 'https://a.notify.windows.com:443/x'] {
		push_endpoint(s) or { panic('expected push endpoint acceptance: ${s}: ${err}') }
	}
}

fn test_truncate_push() {
	cases := [
		['short', 'short', '5'],
		['longer', 'lo…', '5'],
		['😀😀', '😀…', '7'],
		['\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01', '\x01\x01…', '16'],
		['"""', '"…', '5'],
	]
	for c in cases {
		assert truncate_push(c[0], c[2].int()) == c[1], 'truncate(${c[0]})'
	}
}
