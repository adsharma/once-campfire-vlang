module integrations

import crypto.aes
import encoding.base64
import os
import rails
import time

fn tdata(path string) string {
	return os.dir(@FILE) + '/testdata/' + path
}

fn must_decode64(s string) []u8 {
	return push_decode64(s) or { panic('bad b64 ${s}: ${err}') }
}

// RFC 8291 appendix vector, ported from the Go port's TestWebPushRFC8291.
fn test_rfc8291_vector() {
	priv := must_decode64('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw')
	salt := must_decode64('DGv6ra1nlYgDCS1FRnbzlw')
	msg := must_decode64('V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24')
	frame := encrypt_push_with(msg, 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', 'BTBZMqHH6r4Tts7J_aSIgg', priv, salt, [
		u8(2),
	], 4096) or { panic('encrypt: ${err}') }
	want := 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN'
	assert push_encode64(frame) == want
}

fn web_push_expected() rails.JVal {
	raw := os.read_file(tdata('web_push_expected.json')) or { panic('read oracle: ${err}') }
	return rails.jparse(raw) or { panic('parse oracle: ${err}') }
}

// Decrypt the reference ciphertext with the receiver key, mirroring the Go
// port's TestDecryptReferenceWebPush "reference" branch.
fn test_web_push_reference_decrypt() {
	v := web_push_expected()
	str := fn [v] (key string) string {
		val := v.get(key)
		assert val.kind == 4, 'missing string ${key}'
		return val.str
	}
	msg := str('message')
	priv := must_decode64(str('receiver_private_key'))
	body := must_decode64(str('ciphertext'))
	salt := body[..16]
	n := int(body[20])
	server_raw := body[21..21 + n]
	server := p256_pub(server_raw) or { panic('server key: ${err}') }
	// The receiver "public key" for key derivation is derived from the
	// private scalar, like Go's receiver.PublicKey().Bytes().
	peer_self := p256_mul(big_from_bytes(priv), p256_base(), p256_p())
	agreed := p256_ecdh(priv, server)
	key, nonce := push_keys(agreed, p256_pub_bytes(peer_self), server_raw, must_decode64(str('auth')), salt) or {
		panic('keys: ${err}')
	}
	gcm := aes.new_aes_gcm(key) or { panic('gcm: ${err}') }
	plain := gcm.decrypt(body[21 + n..], nonce, []u8{}) or { panic('open: ${err}') }
	mut want := msg.bytes()
	want << u8(2)
	want << u8(0)
	assert plain == want
}

// The oracle pins the deterministic JWT segments: assert byte equality for
// the header and claims, and structural validity for the signature.
fn test_vapid_segments() {
	v := web_push_expected()
	str := fn [v] (key string) string {
		val := v.get(key)
		assert val.kind == 4, 'missing string ${key}'
		return val.str
	}
	// A fixed VAPID key is not shipped in the oracle; generate one and check
	// the deterministic segments against freshly built claims.
	point, priv := p256_generate() or { panic('generate: ${err}') }
	pub_raw := p256_pub_bytes(point)
	vapid := new_vapid(str('vapid_subject'), push_encode64(pub_raw), push_encode64(priv)) or {
		panic('new_vapid: ${err}')
	}
	auth := vapid.authorization('https://fcm.googleapis.com', time.unix(1700000000)) or {
		panic('authorization: ${err}')
	}
	assert auth.starts_with('vapid t=')
	rest := auth[8..]
	ksep := rest.last_index(',k=') or { panic('missing k=') }
	jwt := rest[..ksep]
	// The k parameter carries this key's uncompressed point in RawURLEncoding,
	// like Go's encode64 (the padded PublicKey accessor is separate).
	assert rest[ksep + 3..] == push_encode64(vapid.public)
	parts := jwt.split('.')
	assert parts.len == 3
	assert parts[0] == str('jwt_header_segment')
	assert parts[1] == str('jwt_payload_segment')
	sig := base64.url_decode(parts[2])
	assert sig.len == 64
}

fn test_webhook_mime_table() {
	// (content-type, want symbol, want registered)
	cases := [
		['image/jpeg', 'jpeg', 'image/jpeg'],
		['application/json', 'json', 'application/json'],
		['text/x-json', 'json', 'application/json'],
		['audio/mp4', 'm4a', 'audio/aac'],
		['application/x-foo', '', 'application/x-foo'],
		['Text/Plain', '', 'Text/Plain'],
	]
	for c in cases {
		sym, reg := webhook_mime(c[0]) or { panic('mime ${c[0]}: ${err}') }
		assert sym == c[1], 'symbol for ${c[0]}'
		assert reg == c[2], 'registered for ${c[0]}'
	}
	for bad in ['image', '', 'image/', '/json', '*/json'] {
		// Success always echoes a non-empty registered type, so an empty
		// pair marks the expected rejection.
		sym0, reg0 := webhook_mime(bad) or { '', '' }
		assert sym0 == '' && reg0 == '', 'expected mime rejection: ${bad}'
	}
	// Wildcards are accepted like Go's Mime::Type lookup fallback.
	sym, _ := webhook_mime('*/*') or { panic('wildcard: ${err}') }
	assert sym == ''
}
