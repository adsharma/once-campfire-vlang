module richtext

import compress.gzip
import json
import os
import rails

struct OracleOutcome {
	ok      string @[raw]
	err_msg string @[json: 'error']
}

struct OracleUser {
	id              i64
	name            string
	title           string
	attachable_sgid string
	user_path       string
	avatar_path     string
}

struct OracleSigned {
	sgid   string
	model  string
	id     i64
	exists bool
}

struct OracleCase {
	name         string
	body         string
	host         string
	presentation OracleOutcome
	editable     OracleOutcome
	filtered     OracleOutcome
	mentioned    OracleOutcome
	plain_text   OracleOutcome
	body_html    OracleOutcome
}

struct OracleCorpus {
	users  []OracleUser
	signed []OracleSigned
	cases  []OracleCase
}

fn load_corpus() OracleCorpus {
	raw := os.read_bytes('richtext/testdata/rust.json.gz') or {
		os.read_bytes('testdata/rust.json.gz') or { panic('cannot read oracle corpus') }
	}
	data := gzip.decompress(raw) or { panic('cannot decompress oracle corpus: ${err}') }
	// V's cjson decoder truncates strings at NUL. Raw NULs are deleted in text
	// but become U+FFFD in tags/attributes, so stand them in with U+E000 (which
	// the tokenizer maps per position) instead of decoding them away.
	normalized := data.bytestr().replace('\\u0000', '\\ue000')
	return json.decode(OracleCorpus, normalized) or {
		panic('cannot decode oracle corpus: ${err}')
	}
}

// same_json_text compares a corpus ok payload (JSON string or null) with a
// computed string, mirroring Go's DeepEqual after unmarshalling.
fn same_json_text(want_raw string, got string) bool {
	// A missing ok payload decodes to nil in Go and matches empty output.
	if want_raw == '' || want_raw == 'null' {
		return got == ''
	}
	w := rails.jparse(want_raw) or { return false }
	if w.kind != 4 {
		return false
	}
	return w.str == got
}

fn same_json_ints(want_raw string, got []i64) bool {
	if want_raw == 'null' {
		return got.len == 0
	}
	w := rails.jparse(want_raw) or { return false }
	if w.kind != 5 {
		return false
	}
	if w.arr.len != got.len {
		return false
	}
	for i, v in w.arr {
		if v.kind != 3 || v.num.i64() != got[i] {
			return false
		}
	}
	return true
}

fn test_rust_oracle() {
	corpus := load_corpus()
	mut users := map[i64]Mention{}
	for u in corpus.users {
		users[u.id] = Mention{
			id:     u.id
			name:   u.name
			title:  u.title
			sgid:   u.attachable_sgid
			path:   u.user_path
			avatar: u.avatar_path
		}
	}
	resolve := fn [users, corpus] (sgid string, verified bool) !(Mention, bool) {
		if verified {
			for s in corpus.signed {
				if s.sgid == sgid && s.model == 'User' && s.exists {
					if u := users[s.id] {
						return u, true
					}
					return Mention{}, false
				}
			}
			return Mention{}, false
		}
		gid := rails.unverified_user_gid(sgid) or { return err }
		if gid == '' {
			return Mention{}, false
		}
		parts := gid.split('?')[0].split('/')
		if parts.len < 2 || parts[parts.len - 2] != 'User' {
			return Mention{}, false
		}
		id := parts[parts.len - 1].i64()
		if u := users[id] {
			return u, true
		}
		return Mention{}, false
	}
	mut totals := map[string]int{}
	mut matched := map[string]int{}
	mut failures := 0
	for c in corpus.cases {
		cctx := Context{host: c.host, resolve: resolve}
		result := process(c.body, cctx) or { RichResult{} }
		// Focused entry points must agree with the full pipeline.
		disp := display(c.body, cctx) or { RichResult{} }
		if disp.presentation != result.presentation || disp.plain != result.plain {
			println('FOCUSDISP ${c.name}')
			failures++
		}
		ids := mention_ids(c.body, cctx) or { []i64{} }
		if ids != result.mentioned {
			println('FOCUSMENT ${c.name}: ${ids} vs ${result.mentioned}')
			failures++
		}
		edited := editable(c.body, cctx) or { '' }
		if edited != result.editable {
			println('FOCUSEDIT ${c.name}')
			failures++
		}
		mut plain := ''
		mut plain_failed := false
		plain = plain_text(c.body, cctx) or {
			plain_failed = true
			''
		}
		if plain != result.plain {
			println('FOCUSPLAIN ${c.name}')
			failures++
		}
		if plain_failed != ('plain' in result.errors) {
			println('FOCUSPLAINERR ${c.name}')
			failures++
		}
		checks := [
			['presentation', c.presentation.ok, c.presentation.err_msg, result.presentation],
			['plain', c.plain_text.ok, c.plain_text.err_msg, result.plain],
			['filtered', c.filtered.ok, c.filtered.err_msg, result.filtered],
			['body_html', c.body_html.ok, c.body_html.err_msg, result.body_html],
			['editable', c.editable.ok, c.editable.err_msg, result.editable],
		]
		for ch in checks {
			totals[ch[0]]++
			want_err := ch[2] != ''
			got_err := ch[0] in result.errors
			if want_err && got_err {
				matched[ch[0]]++
				continue
			}
			if !want_err && !got_err && same_json_text(ch[1], ch[3]) {
				matched[ch[0]]++
				continue
			}
			// A missing ok payload with empty output matches like Go's
			// nil-want check, regardless of recorded errors elsewhere.
			if ch[1] == '' && ch[3] == '' {
				matched[ch[0]]++
				continue
			}
			failures++
			if failures <= 10 {
				println('DIFF ${c.name} / ${ch[0]}:\n  got  ${ch[3]}\n  want ${ch[1]}')
			}
		}
		totals['mentioned']++
		want_merr := c.mentioned.err_msg != ''
		got_merr := 'mentioned' in result.errors
		if want_merr && got_merr {
			matched['mentioned']++
		} else if !want_merr && !got_merr && same_json_ints(c.mentioned.ok, result.mentioned) {
			matched['mentioned']++
		} else {
			failures++
			if failures <= 10 {
				println('DIFF ${c.name} / mentioned:\n  got  ${result.mentioned}\n  want ${c.mentioned.ok}')
			}
		}
	}
	for field, total in totals {
		println('${field}: ${matched[field]}/${total}')
	}
	assert failures == 0, '${failures} rich-text differences'
}
