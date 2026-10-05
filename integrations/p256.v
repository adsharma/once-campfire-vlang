module integrations

import crypto.rand
import math.big

// Pure-V NIST P-256 for Web Push (ECDH key agreement and VAPID ES256
// signatures), mirroring Go's crypto/ecdh and crypto/ecdsa usage.

fn p256_p() big.Integer {
	return big.integer_from_bytes(bytes_from_hex('ffffffff00000001000000000000000000000000ffffffffffffffffffffffff'),
		signum: 1)
}

fn p256_n() big.Integer {
	return big.integer_from_bytes(bytes_from_hex('ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551'),
		signum: 1)
}

fn p256_gx() big.Integer {
	return big.integer_from_bytes(bytes_from_hex('6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296'),
		signum: 1)
}

fn p256_gy() big.Integer {
	return big.integer_from_bytes(bytes_from_hex('4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5'),
		signum: 1)
}

fn bytes_from_hex(s string) []u8 {
	mut out := []u8{cap: s.len / 2}
	mut i := 0
	for i < s.len {
		hi := hex_val(s[i])
		lo := hex_val(s[i + 1])
		out << u8(hi * 16 + lo)
		i += 2
	}
	return out
}

fn hex_val(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	return int(c - `A`) + 10
}

fn big_from_bytes(b []u8) big.Integer {
	return big.integer_from_bytes(b, signum: 1)
}

// big_eq compares integer VALUES. math.big's == also compares internal
// digit-array lengths, so reduced results can compare unequal to equal
// values; all P-256 comparisons must go through here.
fn big_eq(a big.Integer, b big.Integer) bool {
	if a.abs_cmp(b) != 0 {
		return false
	}
	if a.signum == b.signum {
		return true
	}
	return a.abs_cmp(big.integer_from_int(0)) == 0
}

fn big_is_zero(a big.Integer) bool {
	return a.abs_cmp(big.integer_from_int(0)) == 0
}

fn big_to_32(n big.Integer) []u8 {
	raw, _ := n.bytes()
	mut out := []u8{len: 32}
	if raw.len >= 32 {
		for i in 0 .. 32 {
			out[i] = raw[raw.len - 32 + i]
		}
	} else {
		for i in 0 .. raw.len {
			out[32 - raw.len + i] = raw[i]
		}
	}
	return out
}

fn fmod(a big.Integer, p big.Integer) big.Integer {
	return a.mod_euclid(p)
}

fn fadd(a big.Integer, b big.Integer, p big.Integer) big.Integer {
	return fmod(a + b, p)
}

fn fsub(a big.Integer, b big.Integer, p big.Integer) big.Integer {
	return fmod(a - b, p)
}

fn fmul(a big.Integer, b big.Integer, p big.Integer) big.Integer {
	return fmod(a * b, p)
}

fn fpow(base big.Integer, exp big.Integer, p big.Integer) big.Integer {
	one := big.integer_from_int(1)
	mut result := one
	mut b := fmod(base, p)
	mut e := exp
	two := big.integer_from_int(2)
	for !big_is_zero(e) {
		_, rem := e.div_mod(two)
		if !big_is_zero(rem) {
			result = fmul(result, b, p)
		}
		b = fmul(b, b, p)
		e = e / two
	}
	return result
}

struct P256Point {
	x        big.Integer
	y        big.Integer
	infinity bool
}

fn p256_add(p P256Point, q P256Point, mod big.Integer) P256Point {
	if p.infinity {
		return q
	}
	if q.infinity {
		return p
	}
	if big_eq(p.x, q.x) {
		if big_eq(p.y, q.y) {
			return p256_double(p, mod)
		}
		return P256Point{big.integer_from_int(0), big.integer_from_int(0), true}
	}
	// lambda = (qy - py) / (qx - px)
	num := fsub(q.y, p.y, mod)
	den := fsub(q.x, p.x, mod)
	lambda := fmul(num, fpow(den, mod - big.integer_from_int(2), mod), mod)
	x := fsub(fsub(fmul(lambda, lambda, mod), p.x, mod), q.x, mod)
	y := fsub(fmul(lambda, fsub(p.x, x, mod), mod), p.y, mod)
	return P256Point{x, y, false}
}

fn p256_double(p P256Point, mod big.Integer) P256Point {
	if p.infinity {
		return p
	}
	if big_is_zero(p.y) {
		return P256Point{big.integer_from_int(0), big.integer_from_int(0), true}
	}
	three := big.integer_from_int(3)
	two := big.integer_from_int(2)
	// lambda = (3x^2 + a) / 2y with a = -3: 3(x^2 - 1) / 2y
	x2 := fmul(p.x, p.x, mod)
	num := fmul(three, fsub(x2, big.integer_from_int(1), mod), mod)
	den := fmul(two, p.y, mod)
	lambda := fmul(num, fpow(den, mod - big.integer_from_int(2), mod), mod)
	x := fsub(fmul(lambda, lambda, mod), p.x + p.x, mod)
	y := fsub(fmul(lambda, fsub(p.x, x, mod), mod), p.y, mod)
	return P256Point{x, y, false}
}

fn p256_mul(scalar big.Integer, point P256Point, mod big.Integer) P256Point {
	mut out := P256Point{big.integer_from_int(0), big.integer_from_int(0), true}
	mut add := point
	mut k := scalar
	two := big.integer_from_int(2)
	for !big_is_zero(k) {
		_, rem := k.div_mod(two)
		if !big_is_zero(rem) {
			out = p256_add(out, add, mod)
		}
		add = p256_double(add, mod)
		k = k / two
	}
	return out
}

fn p256_base() P256Point {
	return P256Point{p256_gx(), p256_gy(), false}
}

// p256_pub parses an uncompressed (65-byte 0x04) or compressed (33-byte)
// P-256 point and validates it is on the curve.
fn p256_pub(raw []u8) !P256Point {
	mod := p256_p()
	if raw.len == 65 && raw[0] == 4 {
		x := big_from_bytes(raw[1..33])
		y := big_from_bytes(raw[33..65])
		// y^2 == x^3 - 3x + b
		lhs := fmul(y, y, mod)
		x2 := fmul(x, x, mod)
		x3 := fmul(x2, x, mod)
		b := big_from_bytes(bytes_from_hex('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b'))
		rhs := fadd(fsub(x3, fmul(big.integer_from_int(3), x, mod), mod), b, mod)
		if lhs != rhs {
			return error('invalid push subscription P-256 point')
		}
		return P256Point{x, y, false}
	}
	if raw.len == 33 && (raw[0] == 2 || raw[0] == 3) {
		x := big_from_bytes(raw[1..33])
		x2 := fmul(x, x, mod)
		x3 := fmul(x2, x, mod)
		b := big_from_bytes(bytes_from_hex('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b'))
		rhs := fadd(fsub(x3, fmul(big.integer_from_int(3), x, mod), mod), b, mod)
		// p == 3 mod 4, so sqrt = rhs^((p+1)/4)
		exp := (mod + big.integer_from_int(1)) / big.integer_from_int(4)
		mut y := fpow(rhs, exp, mod)
		if !big_eq(fmul(y, y, mod), rhs) {
			return error('invalid push subscription P-256 point')
		}
	odd := !big_is_zero(y.mod_euclid(big.integer_from_int(2)))
		if odd != (raw[0] == 3) {
			y = fsub(big.integer_from_int(0), y, mod)
		}
		return P256Point{x, y, false}
	}
	return error('invalid push subscription P-256 point')
}

fn p256_pub_bytes(p P256Point) []u8 {
	mut out := [u8(4)]
	out << big_to_32(p.x)
	out << big_to_32(p.y)
	return out
}

// p256_ecdh returns the x-coordinate of priv * peer.
fn p256_ecdh(priv []u8, peer P256Point) []u8 {
	mod := p256_p()
	agreed := p256_mul(big_from_bytes(priv), peer, mod)
	return big_to_32(agreed.x)
}

// p256_sign produces a raw 64-byte ES256 signature of a 32-byte hash.
fn p256_sign(hash []u8, priv []u8) ![]u8 {
	n := p256_n()
	e := big_from_bytes(hash)
	priv_n := big_from_bytes(priv)
	for {
		k_raw := rand.bytes(32)!
		k := big_from_bytes(k_raw)
		if big_is_zero(k) || !(k < n) {
			continue
		}
		rp := p256_mul(k, p256_base(), p256_p())
		if rp.infinity {
			continue
		}
		r := fmod(rp.x, n)
		if big_is_zero(r) {
			continue
		}
		kinv := fpow(k, n - big.integer_from_int(2), n)
		s := fmod(kinv * fmod(e + fmod(priv_n * r, n), n), n)
		if big_is_zero(s) {
			continue
		}
		mut out := big_to_32(r)
		out << big_to_32(s)
		return out
	}
	return error('p256_sign failed')
}

fn p256_generate() !(P256Point, []u8) {
	n := p256_n()
	for {
		priv := rand.bytes(32)!
		d := big_from_bytes(priv)
		if big_is_zero(d) || !(d < n) {
			continue
		}
		point := p256_mul(d, p256_base(), p256_p())
		return point, big_to_32(d)
	}
	return error('p256_generate failed')
}
