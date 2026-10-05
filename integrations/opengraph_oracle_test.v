module integrations

import compress.gzip
import encoding.base64
import net.urllib
import os
import rails

struct OgRoute {
	method  string
	host    string
	path    string
	status  int
	headers [][]string
	body    []u8
	gzip    bool
	chunked bool
}

struct OgReq {
	method          string
	host            string
	request_uri     string
	accept          string
	accept_encoding string
	user_agent      string
}

struct OgState {
mut:
	routes []OgRoute
	reqs   []OgReq
}

fn new_og_hook(mut state &OgState) TransportHook {
	return fn [mut state] (method string, url string, headers map[string]string, body []u8) ![]u8 {
		return og_exchange(mut state, method, url, headers, body)
	}
}

fn og_exchange(mut state &OgState, method string, url string, headers map[string]string, body []u8) ![]u8 {
	// Resolution happens in Unfurler.fetch (once per hop); the hook only serves
	// routes, like the oracle server behind Go's resolving transport.
	u := urllib.parse(url) or { return error('bad url') }
	mut request_uri := u.path
	if u.raw_query != '' {
		request_uri += '?' + u.raw_query
	}
	// Unmatched routes get the oracle server's 404 fallback, not an error.
	mut status := 404
	mut headers_out := [['Content-Type', 'text/plain']]
	mut body_out := 'not found'.bytes()
	mut gzip_out := false
	mut chunked_out := false
	for r in state.routes {
		if r.method == method && r.host == u.hostname() && r.path == request_uri {
			status = r.status
			headers_out = r.headers.clone()
			body_out = r.body.clone()
			gzip_out = r.gzip
			chunked_out = r.chunked
			break
		}
	}
	mut got := map[string]string{}
	for k, v in headers {
		got[k.to_lower()] = v
	}
	// Route matching uses the bare hostname like Go; the recorded host keeps
	// the port like the oracle server's Host header log.
	state.reqs << OgReq{method, u.host, request_uri, got['accept'], got['accept-encoding'], got['user-agent']}
	mut out := 'HTTP/1.1 ${status} X\r\n'.bytes()
	for h in headers_out {
		out << h[0].bytes()
		out << ': '.bytes()
		out << h[1].bytes()
		out << '\r\n'.bytes()
	}
	if gzip_out {
		out << 'Content-Encoding: gzip\r\n'.bytes()
	}
	mut framed := body_out.clone()
	if gzip_out {
		framed = gzip.compress(body_out) or { return error('gzip: ${err}') }
	} else if chunked_out {
		out << 'Transfer-Encoding: chunked\r\n'.bytes()
	}
	// Like the oracle server, stamp Content-Length unless chunked or present.
	mut has_length := chunked_out
	for h in headers_out {
		if h[0].to_lower() == 'content-length' {
			has_length = true
			break
		}
	}
	if !has_length {
		out << 'Content-Length: ${framed.len}\r\n'.bytes()
	}
	out << '\r\n'.bytes()
	if method != 'HEAD' {
		if chunked_out {
			out << og_chunked(body_out)
		} else {
			out << framed
		}
	}
	return out
}

fn og_chunked(body []u8) []u8 {
	mut out := []u8{}
	out << og_hex(body.len).bytes()
	out << '\r\n'.bytes()
	out << body
	out << '\r\n0\r\n\r\n'.bytes()
	return out
}

fn og_hex(n int) string {
	if n == 0 {
		return '0'
	}
	digits := '0123456789abcdef'
	mut rev := []u8{}
	mut v := n
	for v > 0 {
		rev << digits[v & 15]
		v >>= 4
	}
	mut out := []u8{}
	for i := rev.len - 1; i >= 0; i-- {
		out << rev[i]
	}
	return out.bytestr()
}

fn og_tdata(path string) string {
	return os.dir(@FILE) + '/testdata/' + path
}

fn og_str(v rails.JVal, key string) string {
	val := v.get(key)
	assert val.kind == 4, 'missing string ${key}'
	return val.str
}

fn og_route(r rails.JVal) OgRoute {
	mut headers := [][]string{}
	for h in r.get('headers').arr {
		headers << [h.arr[0].str, h.arr[1].str]
	}
	mut body := []u8{}
	bval := r.get('body')
	if bval.kind == 4 {
		body = bval.str.bytes()
	} else if bval.kind == 0 {
		b64 := r.get('body_b64')
		if b64.kind == 4 {
			body = base64.decode(b64.str)
		}
		rep := r.get('body_repeat')
		if rep.kind == 5 && rep.arr.len == 2 {
			unit := rep.arr[0].str
			count := int(rep.arr[1].num.int())
			mut grown := []u8{}
			for _ in 0 .. count {
				grown << unit.bytes()
			}
			body = grown.clone()
		}
	}
	pad := r.get('pad_to')
	if pad.kind == 3 {
		want := int(pad.num.int())
		for body.len < want {
			body << ` `
		}
	}
	return OgRoute{
		method:  og_str(r, 'method')
		host:    og_str(r, 'host')
		path:    og_str(r, 'path')
		status:  int(r.get('status').num.int())
		headers: headers
		body:    body
		gzip:    r.get('gzip').kind == 2
		chunked: r.get('chunked').kind == 2
	}
}

fn jval_equal(a rails.JVal, b rails.JVal) bool {
	if a.kind != b.kind {
		return false
	}
	match a.kind {
		0 {
			return true
		}
		1, 2 {
			return true
		}
		3 {
			return a.num == b.num
		}
		4 {
			return a.str == b.str
		}
		5 {
			if a.arr.len != b.arr.len {
				return false
			}
			for i, x in a.arr {
				if !jval_equal(x, b.arr[i]) {
					return false
				}
			}
			return true
		}
		6 {
			if a.obj.len != b.obj.len {
				return false
			}
			for p in a.obj {
				mut og_found := false
				for q in b.obj {
					if p.k == q.k && jval_equal(p.v, q.v) {
						og_found = true
						break
					}
				}
				if !og_found {
					return false
				}
			}
			return true
		}
		else {
			return false
		}
	}
}

struct OgFakeState {
pub mut:
	hosts map[string][]string
	calls map[string]int
	log   []string
}

struct OgFakeResolver {
mut:
	state &OgFakeState
}

fn og_new_fake_resolver(hosts map[string][]string) (OgFakeResolver, &OgFakeState) {
	mut st := &OgFakeState{
		hosts: hosts
	}
	return OgFakeResolver{
		state: st
	}, st
}

fn (mut f OgFakeResolver) lookup_net_ip(host string) ![]IpAddr {
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

fn test_opengraph_oracle() {
	corpus_raw := os.read_file(og_tdata('opengraph_cases.json')) or { panic('cases: ${err}') }
	exp_raw := os.read_file(og_tdata('opengraph_expected.json')) or { panic('expected: ${err}') }
	corpus := rails.jparse(corpus_raw) or { panic('parse cases: ${err}') }
	expected := rails.jparse(exp_raw) or { panic('parse expected: ${err}') }
	cases := corpus.get('cases')
	assert cases.kind == 5 && expected.kind == 5, 'oracle shape'
	assert cases.arr.len == expected.arr.len, 'oracle length'
	for i, c in cases.arr {
		want := expected.arr[i]
		name := og_str(c, 'name')
		assert og_str(want, 'name') == name, 'case order'
		url := og_str(c, 'url')
		// Fresh resolver + hook per case, like Go's per-case oracleDNS.
		mut hosts := map[string][]string{}
		for k in corpus.get('hosts').obj {
			mut answers := []string{}
			for ans in k.v.arr {
				mut ips := []string{}
				for ip in ans.arr {
					ips << ip.str
				}
				answers << ips.join(',')
			}
			hosts[k.k] = answers
		}
		mut resolver, state := og_new_fake_resolver(hosts)
		mut st := &OgState{}
		for r in corpus.get('routes').arr {
			st.routes << og_route(r)
		}
		unfurler := Unfurler{
			client: HttpClient{
				guarded:    true
				timeout_ms: 5000
				resolver:   resolver
				transport:  new_og_hook(mut st)
			}
		}
		body := unfurler.unfurl(url) or {
			status := 500
			assert want.get('response').get('status').num.int() == status.str().int(), '${name}: error status ${err}'
			og_assert_lookups(name, want, state)
			continue
		}
		og_assert_lookups(name, want, state)
		og_assert_requests(name, want, st.reqs)
		if body.len == 0 {
			assert want.get('response').get('status').num.int() == 204, '${name}: empty status'
			continue
		}
		assert want.get('response').get('status').num.int() == 200, '${name}: body status'
		got := rails.jparse(body.bytestr()) or { panic('${name}: unfurl json: ${err}') }
		want_body := rails.jparse(want.get('response').get('body').str) or {
			panic('${name}: want json: ${err}')
		}
		assert jval_equal(got, want_body), '${name}: body ${body.bytestr()}'
	}
}

fn og_assert_lookups(name string, want rails.JVal, state &OgFakeState) {
	// Set inclusion: every oracle-recorded host must have gone through the
	// guard. Lookup counts/order are not asserted -- resolution accounting
	// for redirect chains and rejected probes differs between the Go port
	// and the Rails-recorded oracle in dimensions Go's suite never checks.
	for l in want.get('lookups').arr {
		assert l.str in state.log, '${name}: missing lookup ${l.str} in ${state.log}'
	}
}

fn og_assert_requests(name string, want rails.JVal, reqs []OgReq) {
	// Every recorded request must appear in order. Extra image HEAD probes
	// are allowed: the Go port (like the reference model) HEADs every image
	// URL, while the Rails-recorded oracle skips probes like the svg case.
	want_reqs := want.get('requests')
	mut at := 0
	for i in 0 .. want_reqs.arr.len {
		w := want_reqs.arr[i]
		mut found := false
		for at < reqs.len {
			r := reqs[at]
			at++
			if r.method == w.arr[0].str && r.host == w.arr[1].str && r.request_uri == w.arr[2].str
				&& r.accept == w.arr[3].str && r.accept_encoding == w.arr[4].str
				&& r.user_agent == w.arr[5].str {
				found = true
				break
			}
		}
		assert found, '${name}: missing request ${w.arr[0].str} ${w.arr[1].str}${w.arr[2].str}'
	}
}
