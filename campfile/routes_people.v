// people.v is the V transpile of routes/people.py: profile, user pages,
// and push subscriptions. Delivery itself needs the native Web Push
// implementation and is out of scope (the outbox of integrations/webpush.v
// is the V port's delivery path).
module campfile

import json
import campfire as c
import database

pub struct ProfileView {
pub mut:
	id                 i64
	name               string
	bio                string
	email_address      string
	role               i64
	can_administer     bool
	shared_memberships []ProfileEntry
	direct_memberships []ProfileEntry
}

pub struct ProfileEntry {
pub mut:
	membership_id i64
	room_id       i64
	room_name     string
	room_kind     i64
	involvement   string
}

struct UserProfile {
pub mut:
	name          string
	bio           string
	email_address string
	password      string
}

struct ProfilePayload {
pub mut:
	name          string
	bio           string
	email_address string
	password      string
	user          UserProfile
}

// profile serves and patches the current-user profile.
pub fn profile(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mut me := user(mut db, uid) or { return err_resp('not found', 404) }
	if r.method == 'PATCH' || r.method == 'PUT' {
		payload := profile_payload(r)
		update_profile(mut db, uid, ProfilePatch{
			name:     payload.name
			has_name: r.body.contains('"name"')
			bio:      payload.bio
			has_bio:  r.body.contains('"bio"')
			email:    payload.email_address
			has_mail: r.body.contains('"email_address"')
			password: payload.password
		}, now_epoch()) or { return err_resp(err.msg(), 422) }
		me = user(mut db, uid) or { return err_resp('not found', 404) }
	}
	mem_params := [uid.str()]
	mems := db.query_all("SELECT id,room_id,coalesce(involvement,'mentions') FROM memberships WHERE user_id=?",
		mem_params) or { return err_resp('not found', 404) }
	mut room_ids := []i64{}
	for m in mems {
		room_ids << row_i64(m, 1)
	}
	mut room_names := map[i64]string{}
	mut room_types := map[i64]string{}
	if room_ids.len > 0 {
		statement :=
			"SELECT id,coalesce(name,''),type FROM rooms WHERE id IN (" + placeholders(room_ids.len) +
			')'
		room_rows := db.query_all(statement, id_params(room_ids)) or {
			return err_resp('rooms not found', 404)
		}
		for row in room_rows {
			room_names[row_i64(row, 0)] = row_str(row, 1)
			room_types[row_i64(row, 0)] = row_str(row, 2)
		}
	}
	mut shared_rooms := []ProfileEntry{}
	mut direct := []ProfileEntry{}
	for m in mems {
		rid := row_i64(m, 1)
		if rid !in room_types {
			continue
		}
		entry := ProfileEntry{
			membership_id: row_i64(m, 0)
			room_id:       rid
			room_name:     room_names[rid] or { '' }
			room_kind:     type_to_kind(room_types[rid])
			involvement:   row_str(m, 2)
		}
		if room_types[rid] == 'Rooms::Direct' {
			direct << entry
		} else {
			shared_rooms << entry
		}
	}
	return present(ProfileView{
		id:                 me.id
		name:               me.name
		bio:                me.bio
		email_address:      me.email_address
		role:               me.role
		can_administer:     me.role == c.role_admin
		shared_memberships: shared_rooms
		direct_memberships: direct
	})
}

fn profile_payload(r &Req) UserProfile {
	if r.body != '' {
		outer := json.decode(ProfilePayload, r.body) or { ProfilePayload{} }
		if outer.user.name != '' || outer.user.bio != '' || outer.user.email_address != '' {
			return outer.user
		}
		return UserProfile{
			name:          outer.name
			bio:           outer.bio
			email_address: outer.email_address
			password:      outer.password
		}
	}
	return UserProfile{}
}

pub struct UserShow {
pub mut:
	id             i64
	name           string
	bio            string
	role           i64
	can_administer bool
}

// user_show serves one user card.
pub fn user_show(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	me := user(mut db, uid)
	row := user(mut db, int_path_arg(r, 'id')) or { return err_resp('not found', 404) }
	return present(UserShow{
		id:             row.id
		name:           row.name
		bio:            row.bio
		role:           row.role
		can_administer: if admin := me {
			admin.role == c.role_admin
		} else {
			false
		}
	})
}

pub struct PushView {
pub mut:
	id         i64
	endpoint   string
	user_agent string
}

fn push_view(p PushRow) PushView {
	return PushView{
		id:         p.id
		endpoint:   p.endpoint
		user_agent: p.user_agent
	}
}

// push_list lists push subscriptions.
pub fn push_list(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mut out := []PushView{}
	for p in pushsub_list(mut db, uid) {
		out << push_view(p)
	}
	return present(out)
}

struct PushSub {
pub mut:
	endpoint   string
	p256dh_key string
	auth_key   string
}

struct PushPayload {
pub mut:
	endpoint          string
	p256dh_key        string
	auth_key          string
	push_subscription PushSub
}

// push_create upserts a push subscription.
pub fn push_create(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mut payload := PushSub{}
	if r.body != '' {
		outer := json.decode(PushPayload, r.body) or { PushPayload{} }
		if outer.push_subscription.endpoint != '' {
			payload = outer.push_subscription
		} else {
			payload = PushSub{
				endpoint:   outer.endpoint
				p256dh_key: outer.p256dh_key
				auth_key:   outer.auth_key
			}
		}
	}
	row := pushsub_upsert(mut db, uid, payload.endpoint, payload.p256dh_key, payload.auth_key, r.headers['User-Agent'] or {
		''
	}, now_epoch()) or { return err_resp('endpoint required', 422) }
	return present(PushView{ id: row.id, endpoint: row.endpoint })
}

// push_delete deletes a push subscription.
pub fn push_delete(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !pushsub_delete(mut db, uid, int_path_arg(r, 'id')) {
		return err_resp('not found', 404)
	}
	return present(new_deleted(int_path_arg(r, 'id')))
}

pub struct DeletedBody {
pub mut:
	deleted i64
}

// new_deleted builds a deletion body.
pub fn new_deleted(id i64) DeletedBody {
	return DeletedBody{
		deleted: id
	}
}

// push_test checks a subscription exists (delivery is out of scope).
pub fn push_test(mut db database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	mut found := false
	for p in pushsub_list(mut db, uid) {
		if p.id == int_path_arg(r, 'id') {
			found = true
		}
	}
	if !found {
		return err_resp('not found', 404)
	}
	// Delivery needs the native Web Push implementation (out of scope).
	return err_resp('push delivery not implemented', 501)
}
