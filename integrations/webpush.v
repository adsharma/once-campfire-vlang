module integrations

import crypto.aes
import crypto.hmac
import crypto.rand
import crypto.sha256
import encoding.base64
import time

fn push_decode64(s string) ![]u8 {
	mut t := s.replace('-', '+').replace('_', '/')
	for t.ends_with('=') {
		t = t[..t.len - 1]
	}
	for t.len % 4 != 0 {
		t += '='
	}
	return base64.decode(t)
}

fn push_encode64(b []u8) string {
	mut s := base64.url_encode(b)
	for s.ends_with('=') {
		s = s[..s.len - 1]
	}
	return s
}

fn hkdf_extract(salt []u8, ikm []u8) []u8 {
	mut key := salt.clone()
	if key.len == 0 {
		key = []u8{len: 32}
	}
	return hmac.new(key, ikm, sha256.sum, 64)
}

fn hkdf_derive(salt []u8, key []u8, info []u8, n int) []u8 {
	prk := hkdf_extract(salt, key)
	mut out := []u8{}
	mut prev := []u8{}
	mut counter := u8(1)
	for out.len < n {
		mut h := prev.clone()
		h << info
		h << counter
		prev = hmac.new(prk, h, sha256.sum, 64)
		out << prev
		counter++
	}
	return out[..n]
}

fn push_keys(agreed []u8, client_public []u8, server_public []u8, auth []u8, salt []u8) !([]u8, []u8) {
	mut info := 'WebPush: info\x00'.bytes()
	info << client_public
	info << server_public
	prk := hkdf_derive(auth, agreed, info, 32)
	key := hkdf_derive(salt, prk, 'Content-Encoding: aes128gcm\x00'.bytes(), 16)
	nonce := hkdf_derive(salt, prk, 'Content-Encoding: nonce\x00'.bytes(), 12)
	return key, nonce
}

pub fn encrypt_push_with(message []u8, p256dh string, auth string, server_priv []u8, salt []u8, padding []u8, record_size u32) ![]u8 {
	if message.len == 0 || p256dh == '' || auth == '' {
		return error('blank push encryption argument')
	}
	if message.len + padding.len + 16 > 4096 {
		return error('encrypted payload is too big')
	}
	client_bytes := push_decode64(p256dh)!
	mut point_bytes := client_bytes.clone()
	// Strip leading zeros like Go's TrimLeft, then decompress if needed.
	mut start := 0
	for start < point_bytes.len && point_bytes[start] == 0 {
		start++
	}
	point_bytes = point_bytes[start..].clone()
	if point_bytes.len == 33 {
		peer := p256_pub(point_bytes)!
		point_bytes = p256_pub_bytes(peer)
	}
	peer := p256_pub(point_bytes)!
	secret := push_decode64(auth)!
	agreed := p256_ecdh(server_priv, peer)
	server_pub := p256_pub_bytes(p256_mul(big_from_bytes(server_priv), p256_base(), p256_p()))
	key, nonce := push_keys(agreed, point_bytes, server_pub, secret, salt)!
	gcm := aes.new_aes_gcm(key)!
	mut plain := message.clone()
	plain << padding
	encrypted := gcm.encrypt(plain, nonce, []u8{})!
	mut size := record_size
	if size == 0 {
		size = u32(encrypted.len)
	}
	mut out := salt.clone()
	out << u8(size >> 24)
	out << u8((size >> 16) & 0xff)
	out << u8((size >> 8) & 0xff)
	out << u8(size & 0xff)
	out << u8(server_pub.len)
	out << server_pub
	out << encrypted
	return out
}

pub fn encrypt_push(message []u8, p256dh string, auth string) ![]u8 {
	_, priv := p256_generate()!
	salt := rand.bytes(16)!
	mut pad := []u8{}
	pad << u8(2)
	pad << u8(0)
	return encrypt_push_with(message, p256dh, auth, priv, salt, pad, 0)
}

pub struct Vapid {
pub mut:
	subject string
	priv    []u8
	public  []u8
}

pub fn new_vapid(subject string, public string, private string) !Vapid {
	raw := push_decode64(private)!
	if raw.len > 32 {
		return error('invalid VAPID private key')
	}
	mut scalar := []u8{len: 32}
	for i in 0 .. raw.len {
		scalar[32 - raw.len + i] = raw[i]
	}
	d := big_from_bytes(scalar)
	if big_is_zero(d) || !(d < p256_n()) {
		return error('invalid VAPID private key')
	}
	pub_raw := push_decode64(public)!
	peer := p256_pub(pub_raw)!
	expect := p256_mul(d, p256_base(), p256_p())
	ex, ey := expect.xy()
	px, py := peer.xy()
	if !big_eq(ex, px) || !big_eq(ey, py) {
		return error('VAPID keys do not match')
	}
	return Vapid{subject, scalar, p256_pub_bytes(expect)}
}

pub fn (v &Vapid) authorization(audience string, now time.Time) !string {
	exp := now.unix() + 12 * 3600
	claims := '{"aud":${json_quote(audience)},"exp":${exp},"sub":${json_quote(v.subject)}}'
	signing := push_encode64('{"typ":"JWT","alg":"ES256"}'.bytes()) + '.' + push_encode64(claims.bytes())
	hash := sha256.sum(signing.bytes())
	sig := p256_sign(hash, v.priv)!
	return 'vapid t=' + signing + '.' + push_encode64(sig) + ',k=' + push_encode64(v.public)
}

pub fn (v &Vapid) public_key() string {
	mut s := base64.url_encode(v.public)
	for s.ends_with('=') {
		s = s[..s.len - 1]
	}
	// Go uses padded URLEncoding here.
	for s.len % 4 != 0 {
		s += '='
	}
	return s
}

fn json_quote(s string) string {
	// Like Go's encoding/json: quotes, backslashes, controls and HTML
	// metacharacters are escaped.
	mut out := []u8{}
	out << `"`
	hex_digits := '0123456789abcdef'
	for c in s.bytes() {
		if c == `"` {
			out << `\\`
			out << `"`
		} else if c == `\\` {
			out << `\\`
			out << `\\`
		} else if c == `<` {
			out << '\\u003c'.bytes()
		} else if c == `>` {
			out << '\\u003e'.bytes()
		} else if c == `&` {
			out << '\\u0026'.bytes()
		} else if c < 0x20 {
			out << `\\`
			out << `u`
			out << `0`
			out << `0`
			out << hex_digits[int(c) >> 4]
			out << hex_digits[int(c) & 15]
		} else {
			out << c
		}
	}
	out << `"`
	return out.bytestr()
}


