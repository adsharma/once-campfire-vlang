// search.v is the V transpile of routes/search.py: full-text search plus
// the recent-searches history. The query is sanitized to word characters,
// exactly like the python `_clean` does before it reaches FTS5.
module campfile

import json
import workload as w
import database

pub struct SearchView {
pub mut:
	query    string
	messages []w.MessageView
	recent   []string
}

struct SearchQuery {
pub mut:
	q string
}

// searches searches and returns recent history.
pub fn searches(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	query := clean_query(r.query['q'] or { '' })
	res := search_page(mut db, uid, query, 100)
	if !res.ok {
		return err_resp(res.error, 404)
	}
	mut views := []w.MessageView{}
	for hit in res.value {
		views << hit.message
	}
	return present(SearchView{
		query:    query
		messages: views
		recent:   recent_searches(mut db, uid)
	})
}

// searches_record records a search query.
pub fn searches_record(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mut raw := r.query['q'] or { '' }
	if r.body != '' {
		payload := json.decode(SearchQuery, r.body) or { SearchQuery{} }
		if payload.q != '' {
			raw = payload.q
		}
	}
	query := clean_query(raw)
	if query != '' {
		record_search(mut db, uid, query, now_epoch()) or {}
	}
	return present(SearchView{
		query:  query
		recent: recent_searches(mut db, uid)
	})
}

// searches_clear clears search history.
pub fn searches_clear(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	clear_searches(mut db, uid)
	return present(SearchView{ recent: []string{} })
}
