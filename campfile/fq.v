// fq.v replaces ../once-campfire-python/src/campfile/fq.py in the V port.
//
// python builds queries with fquery.sqlmodel, a small DSL that compiles a
// query tree to parameterized SQL over a sqlmodel Session. V has no ORM and
// no equivalent DSL in its standard library, so this module is the whole
// query layer: parameter binding, `IN (...)` list rendering, and row
// decoding. Every statement below is still parameterized (`?` placeholders,
// never interpolated text), exactly like the python queries it replaces.
module campfile

// id_params binds the same ids for the placeholder list.
pub fn id_params(ids []i64) []string {
	return ids.map(it.str())
}

// placeholders renders `?,?,?` for n bound parameters.
pub fn placeholders(n int) string {
	mut out := []u8{}
	for i in 0 .. n {
		if i > 0 {
			out << `,`
		}
		out << `?`
	}
	return out.bytestr()
}

// is_digits matches python's str.isdigit() for the `?as=` bench backdoor and
// the bot anchor arguments.
pub fn is_digits(text string) bool {
	if text.len == 0 {
		return false
	}
	for ch in text {
		if ch < `0` || ch > `9` {
			return false
		}
	}
	return true
}