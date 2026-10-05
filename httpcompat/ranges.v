// ByteRanges follows Rack 3.2's permissive parser. A nil return means a full
// response; an allocated empty slice means unsatisfiable. Bounds are inclusive.
module httpcompat

import math

fn i64_min(a i64, b i64) i64 {
	if a < b {
		return a
	}
	return b
}

fn i64_max(a i64, b i64) i64 {
	if a > b {
		return a
	}
	return b
}

pub fn byte_ranges(header string, size i64) ?[][]i64 {
	if size == 0 {
		return none
	}
	mut spec := ''
	mut offset := 0
	for offset < header.len {
		index := header[offset..].index('bytes=') or { break }
		offset += index + 6
		end := header[offset..].index(';') or { -1 }
		mut stop := header.len - offset
		if end >= 0 {
			stop = end
		}
		if stop > 0 {
			spec = header[offset..offset + stop]
			break
		}
	}
	if spec == '' || spec.count(',') >= 100 {
		return none
	}
	mut split := spec.split(',')
	for i in 1 .. split.len {
		split[i] = split[i].trim_left(' \t')
	}
	for split.len > 0 && split[split.len - 1] == '' {
		split = split[..split.len - 1]
	}
	mut ranges := [][]i64{}
	mut total := i64(0)
	for value in split {
		if !value.contains('-') {
			return none
		}
		mut parts := value.split('-')
		for parts.len > 0 && parts[parts.len - 1] == '' {
			parts = parts[..parts.len - 1]
		}
		mut start := i64(0)
		mut end := i64(0)
		if parts.len == 0 || parts[0] == '' {
			if parts.len < 2 {
				return none
			}
			start = i64_max(i64(0), size - decimal_prefix(parts[1]))
			end = size - 1
		} else {
			start = decimal_prefix(parts[0])
			end = size - 1
			if parts.len > 1 {
				last := decimal_prefix(parts[1])
				if last < start {
					return none
				}
				end = i64_min(last, size - 1)
			}
		}
		if start <= end {
			length := end - start + 1
			if total > size - length {
				return [][]i64{}
			}
			total += length
			ranges << [start, end]
		}
	}
	return ranges
}

fn decimal_prefix(text string) i64 {
	mut t := text.trim_left(' \t\n\r\x0b\x0c')
	if t.starts_with('+') {
		t = t[1..]
	}
	if t.starts_with('0d') || t.starts_with('0D') {
		t = t[2..]
	}
	mut n := i64(0)
	bs := t.bytes()
	for i in 0 .. bs.len {
		c := bs[i]
		if c == `_` && i > 0 && i + 1 < bs.len && bs[i - 1] >= `0` && bs[i - 1] <= `9` && bs[i + 1] >= `0` && bs[i + 1] <= `9` {
			continue
		}
		if c < `0` || c > `9` {
			break
		}
		digit := i64(c - `0`)
		if n > (i64(9223372036854775807) - digit) / 10 {
			return i64(9223372036854775807)
		}
		n = n * 10 + digit
	}
	return n
}
