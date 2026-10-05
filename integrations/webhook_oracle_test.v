module integrations

import compress.gzip
import encoding.base64
import net
import net.urllib
import os
import rails
import time

struct WhReq {
	method  string
	url     string
	headers map[string]string
	body    []u8
}

struct WhState {
mut:
	raw   []u8
	delay bool
	reqs  []WhReq
}

fn new_wh_hook(mut state &WhState) TransportHook {
	return fn [mut state] (method string, url string, headers map[string]string, body []u8) ![]u8 {
		return wh_exchange(mut state, method, url, headers, body)
	}
}

fn wh_exchange(mut state &WhState, method string, url string, headers map[string]string, body []u8) ![]u8 {
	state.reqs << WhReq{method, url, headers.clone(), body.clone()}
	if state.delay {
		return error('Client.Timeout exceeded while awaiting headers')
	}
	return state.raw.clone()
}

fn wh_raw_response(status int, headers [][]string, body []u8) []u8 {
	mut out := 'HTTP/1.1 ${status} X\r\n'.bytes()
	for h in headers {
		out << h[0].bytes()
		out << ': '.bytes()
		out << h[1].bytes()
		out << '\r\n'.bytes()
	}
	out << '\r\n'.bytes()
	out << body
	return out
}

fn wh_tdata(path string) string {
	return os.dir(@FILE) + '/testdata/' + path
}

fn wh_expected() (rails.JVal, rails.JVal) {
	cases_raw := os.read_file(wh_tdata('webhook_cases.json')) or { panic('read cases: ${err}') }
	exp_raw := os.read_file(wh_tdata('webhook_expected.json')) or { panic('read expected: ${err}') }
	return rails.jparse(cases_raw) or { panic('parse cases: ${err}') }, rails.jparse(exp_raw) or {
		panic('parse expected: ${err}')
	}
}

fn wh_jstr(v rails.JVal, key string) string {
	val := v.get(key)
	assert val.kind == 4, 'missing string ${key}'
	return val.str
}

fn test_webhook_oracle() {
	cases, expected := wh_expected()
	assert cases.kind == 5 && expected.kind == 5, 'oracle shape'
	assert cases.arr.len == expected.arr.len, 'oracle length'
	for i, c in cases.arr {
		want := expected.arr[i]
		name := wh_jstr(c, 'name')
		assert wh_jstr(want, 'name') == name, 'case order'
		if c.get('url').kind == 4 && c.get('url').str != '' {
			// The refused case uses a real connection failure below.
			continue
		}
		status := int(c.get('status').num.int())
		mut headers := [][]string{}
		for h in c.get('headers').arr {
			headers << [h.arr[0].str, h.arr[1].str]
		}
		mut body := []u8{}
		bval := c.get('body')
		if bval.kind == 4 {
			body = bval.str.bytes()
		} else {
			b64 := c.get('body_b64')
			assert b64.kind == 4, '${name}: body shape'
			body = base64.decode(b64.str)
		}
		if c.get('gzip').kind == 2 {
			body = gzip.compress(body) or { panic('${name}: gzip: ${err}') }
			headers << ['Content-Encoding', 'gzip']
		}
		mut st := &WhState{
			raw:   wh_raw_response(status, headers, body)
			delay: c.get('delay').kind == 3
		}
		client := WebhookClient{
			client: HttpClient{guarded: false, timeout_ms: 7000, transport: new_wh_hook(mut st)}
		}
		endpoint := 'http://127.0.0.1:9/${name}'
		reply := client.deliver(endpoint, '{"message":"hi"}'.bytes()) or {
			err_msg := err.msg()
			want_err := want.get('error')
			assert want_err.kind == 4, '${name}: unexpected error ${err_msg}'
			assert want_err.str == 'Mime::Type::InvalidMimeType', '${name}: error kind'
			assert err_msg.contains('MIME'), '${name}: error text ${err_msg}'
			wh_assert_request(name, want, st.reqs, endpoint)
			continue
		}
		wh_assert_request(name, want, st.reqs, endpoint)
		want_status := want.get('status')
		if want_status.kind == 0 {
			// Timeout case: status null, text reply present.
			assert reply.status == 0, '${name}: timeout status'
		} else {
			assert reply.status == int(want_status.num.int()), '${name}: status'
		}
		wr := want.get('reply')
		if wr.kind == 0 {
			assert reply.text == none, '${name}: unexpected text'
			assert reply.filename == '', '${name}: unexpected attachment'
			continue
		}
		t64 := wr.get('text_b64')
		if t64.kind == 4 {
			raw_text := base64.decode(t64.str)
			text := reply.text or { panic('${name}: missing text') }
			assert text == to_valid_utf8(raw_text.bytestr()), '${name}: text'
			continue
		}
		att := wr.get('attachment')
		raw_att := base64.decode(att.get('body_b64').str)
		assert reply.filename == att.get('filename').str, '${name}: filename'
		assert reply.content_type == att.get('content_type').str, '${name}: content type'
		assert reply.attachment == raw_att, '${name}: attachment bytes'
	}
}

fn wh_assert_request(name string, want rails.JVal, reqs []WhReq, endpoint string) {
	want_reqs := want.get('requests')
	assert want_reqs.kind == 5, '${name}: requests shape'
	assert reqs.len == want_reqs.arr.len, '${name}: request count'
	for i, r in reqs {
		w := want_reqs.arr[i]
		assert r.method == 'POST', '${name}: method'
		u := urllib.parse(r.url) or { panic('${name}: url') }
		assert u.hostname() == '127.0.0.1', '${name}: host'
		assert u.path == '/${name}', '${name}: path'
		assert w.get('request_line').str == 'POST /${name} HTTP/1.1', '${name}: request line'
		mut want_headers := map[string]string{}
		for h in w.get('headers').arr {
			want_headers[h.arr[0].str.to_lower()] = h.arr[1].str
		}
		mut got_lower := map[string]string{}
		for k, v in r.headers {
			got_lower[k.to_lower()] = v
		}
		for k, v in got_lower {
			if k == 'host' {
				assert v.starts_with('127.0.0.1:'), '${name}: host header ${v}'
				continue
			}
			assert want_headers[k] == v, '${name}: header ${k}=${v}'
		}
		for k, v in want_headers {
			if k == 'host' {
				continue
			}
			assert got_lower[k] == v, '${name}: missing header ${k}'
		}
		assert r.body.bytestr() == w.get('body').str, '${name}: request body'
		_ = endpoint
	}
}

// The refused case exercises a real connection failure like Go's ECONNREFUSED.
fn test_webhook_refused() {
	client := new_webhook_client()
	if _ := client.deliver('http://127.0.0.1:9/refused', '{"message":"hi"}'.bytes()) {
		assert false, 'expected connection failure'
	} else {
	}
}

// Localhost framing: chunked, gzip and content-length bodies through the real
// socket parser.
fn test_httpc_framing() {
	mut ln := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('listen: ${err}') }
	defer {
		ln.close() or {}
	}
	addr := ln.addr() or { panic('addr: ${err}') }
	port := addr.port() or { panic('port: ${err}') }
	responses := [
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort',
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nclose-delimited',
	]
	spawn serve_canned(mut ln, responses)
	client := HttpClient{guarded: false, timeout_ms: 5000}
	mut do_cache := map[string]IpAddr{}
	bodies := ['hello world', 'short', 'close-delimited']
	for i, want in bodies {
		r := client.do('GET', 'http://127.0.0.1:${port}/r${i}', {}, [], 0, mut do_cache) or {
			panic('case ${i}: ${err}')
		}
		assert r.status == 200, 'case ${i} status'
		assert r.body.bytestr() == want, 'case ${i} body'
	}
	// Gzip inflation through the real path.
	mut ln2 := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('listen2: ${err}') }
	defer {
		ln2.close() or {}
	}
	addr2 := ln2.addr() or { panic('addr2: ${err}') }
	port2 := addr2.port() or { panic('port2: ${err}') }
	zipped := gzip.compress('zipped'.bytes()) or { panic('gzip: ${err}') }
	spawn serve_canned(mut ln2, ['HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n' + zipped.bytestr()])
	r2 := client.do('GET', 'http://127.0.0.1:${port2}/z', {}, [], 0, mut do_cache) or { panic('gzip case: ${err}') }
	assert r2.body.bytestr() == 'zipped', 'gzip body'
}

fn serve_canned(mut ln &net.TcpListener, responses []string) {
	for res in responses {
		mut conn := ln.accept() or { return }
		mut buf := []u8{len: 4096}
		conn.read(mut buf) or {}
		conn.write(res.bytes()) or {}
		conn.close() or {}
	}
}

// A hanging server trips the client read timeout, which deliver maps to the
// timeout reply like Go's Client.Timeout.
fn test_webhook_timeout() {
	mut ln := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('listen: ${err}') }
	defer {
		ln.close() or {}
	}
	addr := ln.addr() or { panic('addr: ${err}') }
	port := addr.port() or { panic('port: ${err}') }
	spawn serve_hang(mut ln)
	client := WebhookClient{
		client: HttpClient{guarded: false, timeout_ms: 300}
	}
	reply := client.deliver('http://127.0.0.1:${port}/hang', '{}'.bytes()) or {
		panic('expected timeout reply, got error: ${err}')
	}
	text := reply.text or { panic('missing timeout text') }
	assert text == 'Failed to respond within 7 seconds', 'timeout text'
}

fn serve_hang(mut ln &net.TcpListener) {
	mut conn := ln.accept() or { return }
	mut buf := []u8{len: 4096}
	conn.read(mut buf) or {}
	time.sleep(2 * time.second)
	conn.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi'.bytes()) or {}
	conn.close() or {}
}
