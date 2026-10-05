module qrcode

import crypto.sha256

fn svg_sha(data string) (string, int, int) {
	out, ok := svg(data.bytes())
	if !ok {
		return '', 0, 0
	}
	mods, version := modules(data.bytes())
	return sha256.hexhash(out), version, mods.len
}

fn test_qr_go_vectors() {
	sha, version, dim := svg_sha('HELLO')
	assert version == 1
	assert dim == 21
	assert sha == 'fee6b9c40abad177ff8367af57a970ba114d62367c5cea50ddb52603079bb576'
	sha2, version2, dim2 := svg_sha('https://example.com/rooms/1')
	assert version2 == 4
	assert dim2 == 33
	assert sha2 == '6151c15cf3fc7ee6080702534ff61fc954813033f2d40691a816bbe80fa9b48f'
	sha3, version3, dim3 := svg_sha('0123456789')
	assert version3 == 1
	assert dim3 == 21
	assert sha3 == '5f16c593572fa0fae17c743b0224055d54d0187c1e165ce9544e9973038560e6'
	sha4, version4, dim4 := svg_sha('Hello, World!')
	assert version4 == 2
	assert dim4 == 25
	assert sha4 == '921567157659fe72d14c41b26595b8abe6989e34cfe74e2dfb86a422a939e081'
}
