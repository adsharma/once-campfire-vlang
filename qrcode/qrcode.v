// Package qrcode preserves rqrcode_core 2.1.0's segment, capacity and mask
// choices and rqrcode 3.2.0's SVG output. See the pinned Rust qr_code/rqrcode.rs.
module qrcode

import math.bits

const alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:'

fn int_min(a int, b int) int {
	if a < b {
		return a
	}
	return b
}

fn int_max(a int, b int) int {
	if a > b {
		return a
	}
	return b
}

struct Segment {
	data []u8
	mode int
}

fn new_segment(data []u8) Segment {
	mut mode := 1
	for b in data {
		if b < `0` || b > `9` {
			mode = 2
			break
		}
	}
	if mode == 2 {
		for b in data {
			if alphabet.index(b.ascii_str()) or { -1 } < 0 {
				mode = 4
				break
			}
		}
	}
	return Segment{data, mode}
}

fn (s Segment) length_bits(version int) int {
	mut group := 0
	if version >= 10 {
		group = 1
	}
	if version >= 27 {
		group = 2
	}
	if s.mode == 1 {
		return [10, 12, 14][group]
	} else if s.mode == 2 {
		return [9, 11, 13][group]
	}
	return [8, 16, 16][group]
}

fn (s Segment) size(version int) int {
	n := s.data.len
	mut content := n * 8
	if s.mode == 1 {
		content = n / 3 * 10 + [0, 4, 7][n % 3]
	} else if s.mode == 2 {
		content = n / 2 * 11 + n % 2 * 6
	}
	return 4 + s.length_bits(version) + content
}

struct BitBuffer {
mut:
	data []u8
	n    int
}

fn (mut b BitBuffer) put(value int, n int) {
	for i := n - 1; i >= 0; i-- {
		index := b.n / 8
		for b.data.len <= index {
			b.data << u8(0)
		}
		if (value >> i) & 1 != 0 {
			b.data[index] |= u8(0x80 >> (b.n % 8))
		}
		b.n++
	}
}

fn (s Segment) write(mut b BitBuffer, version int) {
	b.put(s.mode, 4)
	b.put(s.data.len, s.length_bits(version))
	if s.mode == 1 {
		mut i := 0
		for i < s.data.len {
			end := int_min(i + 3, s.data.len)
			part := s.data[i..end]
			mut v := 0
			for c in part {
				v = v * 10 + int(c - `0`)
			}
			b.put(v, [0, 4, 7, 10][part.len])
			i += 3
		}
	} else if s.mode == 2 {
		mut i := 0
		for i < s.data.len {
			mut v := alphabet.index(s.data[i].ascii_str()) or { 0 }
			mut n := 6
			if i + 1 < s.data.len {
				v = v * 45 + (alphabet.index(s.data[i + 1].ascii_str()) or { 0 })
				n = 11
			}
			b.put(v, n)
			i += 2
		}
	} else {
		for c in s.data {
			b.put(int(c), 8)
		}
	}
}

fn gf_tables() ([]int, []int) {
	mut exp := []int{len: 256}
	mut log := []int{len: 256}
	for i in 0 .. 8 {
		exp[i] = 1 << i
	}
	for i in 8 .. 256 {
		exp[i] = exp[i - 4] ^ exp[i - 5] ^ exp[i - 6] ^ exp[i - 8]
	}
	for i in 0 .. 255 {
		log[exp[i]] = i
	}
	return exp, log
}

fn gexp(exp []int, n int) int {
	mut m := n
	for m < 0 {
		m += 255
	}
	for m >= 256 {
		m -= 255
	}
	return exp[m]
}

fn polynomial(values []int, shift int) []int {
	mut offset := 0
	for offset < values.len && values[offset] == 0 {
		offset++
	}
	mut out := values[offset..].clone()
	for _ in 0 .. shift {
		out << 0
	}
	return out
}

fn multiply(a []int, b []int, exp []int, log []int) []int {
	mut out := []int{len: a.len + b.len - 1}
	for i, x in a {
		for j, y in b {
			out[i + j] ^= gexp(exp, log[x] + log[y])
		}
	}
	return polynomial(out, 0)
}

fn modulo(a []int, b []int, exp []int, log []int) []int {
	mut cur := a.clone()
	for cur.len >= b.len {
		ratio := log[cur[0]] - log[b[0]]
		mut next := cur.clone()
		for i, x in b {
			next[i] ^= gexp(exp, log[x] + ratio)
		}
		cur = polynomial(next, 0)
	}
	return cur
}

struct Block {
	total int
	data  int
}

fn codewords(s Segment, version int, exp []int, log []int) []u8 {
	table := blocks[version - 1]
	mut groups := []Block{}
	mut capacity := 0
	mut i := 0
	for i < table.len {
		for _ in 0 .. table[i] {
			groups << Block{table[i + 1], table[i + 2]}
			capacity += table[i + 2] * 8
		}
		i += 3
	}
	mut b := BitBuffer{}
	s.write(mut b, version)
	if b.n + 4 <= capacity {
		b.put(0, 4)
	}
	for b.n % 8 != 0 {
		b.put(0, 1)
	}
	for b.n < capacity {
		b.put(0xec, 8)
		if b.n < capacity {
			b.put(0x11, 8)
		}
	}
	mut dc := [][]int{}
	mut ec := [][]int{}
	mut offset := 0
	for group in groups {
		mut data := []int{len: group.data}
		for k in 0 .. group.data {
			data[k] = int(b.data[offset + k])
		}
		offset += group.data
		count := group.total - group.data
		mut poly := [1]
		for k in 0 .. count {
			poly = multiply(poly, [1, gexp(exp, k)], exp, log)
		}
		remainder := modulo(polynomial(data, count), poly, exp, log)
		mut error_words := []int{len: count}
		for k, w in remainder {
			error_words[count - remainder.len + k] = w
		}
		dc << data
		ec << error_words
	}
	mut result := []u8{}
	for _, part in [dc, ec] {
		mut longest := 0
		for g in part {
			if g.len > longest {
				longest = g.len
			}
		}
		for k in 0 .. longest {
			for g in part {
				if k < g.len {
					result << u8(g[k])
				}
			}
		}
	}
	return result
}

fn mask(pattern int, row int, col int) bool {
	match pattern {
		0 {
			return (row + col) % 2 == 0
		}
		1 {
			return row % 2 == 0
		}
		2 {
			return col % 3 == 0
		}
		3 {
			return (row + col) % 3 == 0
		}
		4 {
			return (row / 2 + col / 3) % 2 == 0
		}
		5 {
			return (row * col) % 2 + (row * col) % 3 == 0
		}
		6 {
			return ((row * col) % 2 + (row * col) % 3) % 2 == 0
		}
		else {
			return ((row * col) % 3 + (row + col) % 2) % 2 == 0
		}
	}
}

fn bit_len(x int) int {
	if x <= 0 {
		return 0
	}
	return 64 - bits.leading_zeros_64(u64(x))
}

fn bch(data int, shift int, generator int) int {
	mut d := data << shift
	for bit_len(d) >= bit_len(generator) {
		d ^= generator << (bit_len(d) - bit_len(generator))
	}
	return (data << shift) | d
}

struct Grid {
mut:
	cells [][]i8
}

fn new_grid(n int) Grid {
	mut cells := [][]i8{len: n}
	for i in 0 .. n {
		cells[i] = []i8{len: n, init: -1}
	}
	return Grid{cells}
}

fn grid_size(g Grid) int {
	return g.cells.len
}

fn (mut g Grid) set(y int, x int, dark bool) {
	g.cells[y][x] = if dark { i8(1) } else { i8(0) }
}

fn (mut g Grid) probe(row int, col int) {
	n := grid_size(g)
	for r in -1 .. 8 {
		for c in -1 .. 8 {
			y := row + r
			x := col + c
			if y < 0 || y >= n || x < 0 || x >= n {
				continue
			}
			g.set(y, x, (r >= 0 && r <= 6 && (c == 0 || c == 6)) || (c >= 0 && c <= 6 && (r == 0 || r == 6)) || (r >= 2 && r <= 4 && c >= 2 && c <= 4))
		}
	}
}

fn (mut g Grid) format(pattern int, test bool) {
	n := grid_size(g)
	value := bch(2 << 3 | pattern, 10, 0x537) ^ 0x5412
	for i in 0 .. 15 {
		dark := !test && (value >> i) & 1 != 0
		mut row := n - 15 + i
		if i < 6 {
			row = i
		} else if i < 8 {
			row = i + 1
		}
		g.set(row, 8, dark)
		mut col := 15 - i - 1
		if i < 8 {
			col = n - i - 1
		} else if i < 9 {
			col = 15 - i
		}
		g.set(8, col, dark)
	}
	g.set(n - 8, 8, !test)
}

fn (mut g Grid) version(version int, test bool) {
	n := grid_size(g)
	value := bch(version, 12, 0x1f25)
	for i in 0 .. 18 {
		dark := !test && (value >> i) & 1 != 0
		g.set(i / 3, i % 3 + n - 11, dark)
		g.set(i % 3 + n - 11, i / 3, dark)
	}
}

fn (mut g Grid) map_data(data []u8, pattern int) {
	n := grid_size(g)
	mut inc := -1
	mut row := n - 1
	mut bit := 7
	mut index := 0
	mut col := n - 1
	for col >= 1 {
		mut c0 := col
		if col <= 6 {
			c0--
		}
		for {
			for c in 0 .. 2 {
				x := c0 - c
				if g.cells[row][x] < 0 {
					mut dark := index < data.len && (int(data[index]) >> bit) & 1 != 0
					if mask(pattern, row, x) {
						dark = !dark
					}
					g.set(row, x, dark)
					bit--
					if bit < 0 {
						index++
						bit = 7
					}
				}
			}
			row += inc
			if row < 0 || row >= n {
				row -= inc
				inc = -inc
				break
			}
		}
		col -= 2
	}
}

fn lost_points(g Grid) f64 {
	n := grid_size(g)
	mut points := 0
	mut dark := 0
	for row in 0 .. n {
		for col in 0 .. n {
			v := g.cells[row][col]
			if v == 1 {
				dark++
			}
			mut same := 0
			for y in int_max(0, row - 1) .. int_min(n - 1, row + 1) + 1 {
				for x in int_max(0, col - 1) .. int_min(n - 1, col + 1) + 1 {
					if (y != row || x != col) && g.cells[y][x] == v {
						same++
					}
				}
			}
			if same > 5 {
				points += 3 + same - 5
			}
			if row + 1 < n && col + 1 < n && g.cells[row + 1][col] == v && g.cells[row][col + 1] == v && g.cells[row + 1][col + 1] == v {
				points += 3
			}
		}
	}
	finder := fn (a i8, b i8, c i8, d i8, e i8, f i8, h i8) bool {
		return a == 1 && b == 0 && c == 1 && d == 1 && e == 1 && f == 0 && h == 1
	}
	for start in 0 .. n - 6 {
		for line in 0 .. n {
			r := g.cells[line]
			if finder(r[start], r[start + 1], r[start + 2], r[start + 3], r[start + 4], r[start + 5],
				r[start + 6]) {
				points += 40
			}
			if finder(g.cells[start][line], g.cells[start + 1][line], g.cells[start + 2][line],
				g.cells[start + 3][line], g.cells[start + 4][line], g.cells[start + 5][line], g.cells[start +
				6][line]) {
				points += 40
			}
		}
	}
	dev := f64(dark) * 100.0 / f64(n * n) - 50.0
	if dev < 0 {
		return f64(points) + (-dev) / 5 * 10
	}
	return f64(points) + dev / 5 * 10
}

pub fn modules(data []u8) ([][]bool, int) {
	s := new_segment(data)
	exp, log := gf_tables()
	mut version := 0
	for i, capacity in capacities {
		if s.size(i + 1) < capacity {
			version = i + 1
			break
		}
	}
	if version == 0 {
		return [][]bool{}, 0
	}
	n := version * 4 + 17
	mut common := new_grid(n)
	common.probe(0, 0)
	common.probe(n - 7, 0)
	common.probe(0, n - 7)
	for _, row in positions[version - 1] {
		for _, col in positions[version - 1] {
			if common.cells[row][col] >= 0 {
				continue
			}
			for r in -2 .. 3 {
				for c in -2 .. 3 {
					common.set(row + r, col + c, r == -2 || r == 2 || c == -2 || c == 2 || (r == 0 && c == 0))
				}
			}
		}
	}
	for i in 8 .. n - 8 {
		common.set(i, 6, i % 2 == 0)
		common.set(6, i, i % 2 == 0)
	}
	words := codewords(s, version, exp, log)
	best := best_pattern(common, words, n, version)
	g := make_grid(common, words, n, version, best, false)
	mut out := [][]bool{len: n}
	for i in 0 .. n {
		out[i] = []bool{len: n}
		for j in 0 .. n {
			out[i][j] = g.cells[i][j] == 1
		}
	}
	return out, version
}

fn make_grid(common Grid, words []u8, n int, version int, pattern int, test bool) Grid {
	mut g := new_grid(n)
	for i in 0 .. n {
		for j in 0 .. n {
			g.cells[i][j] = common.cells[i][j]
		}
	}
	g.format(pattern, test)
	if version >= 7 {
		g.version(version, test)
	}
	g.map_data(words, pattern)
	return g
}

fn best_pattern(common Grid, words []u8, n int, version int) int {
	mut best := 0
	mut score := 1e300
	for pattern in 0 .. 8 {
		points := lost_points(make_grid(common, words, n, version, pattern, true))
		if points < score {
			best = pattern
			score = points
		}
	}
	return best
}

pub fn svg(data []u8) (string, bool) {
	mods, _ := modules(data)
	if mods.len == 0 {
		return '', false
	}
	dimension := mods.len * 11
	mut out := '<?xml version="1.0" standalone="yes"?>'
	out += '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events" viewBox="0 0 ${dimension} ${dimension}" shape-rendering="crispEdges"><rect width="${dimension}" height="${dimension}" x="0" y="0" fill="white"/>'
	for row, cells in mods {
		for col, dark in cells {
			if dark {
				out += '<rect width="11" height="11" x="${col * 11}" y="${row * 11}" fill="black"/>'
			}
		}
	}
	out += '</svg>'
	return out, true
}
