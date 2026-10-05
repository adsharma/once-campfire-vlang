module database

import time

pub const push_columns = "p.id,p.user_id,coalesce(p.endpoint,''),coalesce(p.p256dh_key,''),coalesce(p.auth_key,''),coalesce(p.user_agent,'')"

fn scan_push(vals []string) PushSubscription {
	return PushSubscription{
		id:         vals[0].i64()
		user_id:    vals[1].i64()
		endpoint:   vals[2]
		key:        vals[3]
		auth:       vals[4]
		user_agent: vals[5]
	}
}

pub fn (mut d DB) push_subscription(user_id i64, id i64) !PushSubscription {
	row := d.query_one('SELECT ' + push_columns +
		' FROM push_subscriptions p WHERE p.user_id=? AND p.id=?', [
		user_id.str(), id.str()])!
	return scan_push(row.vals)
}

pub fn (mut d DB) push_subscriptions(user_id i64) ![]PushSubscription {
	return d.push_query('SELECT ' + push_columns + ' FROM push_subscriptions p WHERE p.user_id=?', [
		user_id.str(),
	])
}

fn (mut d DB) push_query(query string, args []string) ![]PushSubscription {
	rows := d.query_all(query, args)!
	mut list := []PushSubscription{}
	for r in rows {
		list << scan_push(r.vals)
	}
	return list
}

pub fn (mut d DB) find_push_subscription(user_id i64, attrs map[string]?string) !PushSubscription {
	mut query := 'SELECT ' + push_columns + ' FROM push_subscriptions p WHERE p.user_id=?'
	mut args := [user_id.str()]
	for key in ['endpoint', 'p256dh_key', 'auth_key'] {
		if key in attrs {
			value := attrs[key] or { ?string(none) }
			if v := value {
				query += ' AND p.' + key + '=?'
				args << v
			} else {
				query += ' AND p.' + key + ' IS NULL'
			}
		}
	}
	row := d.query_one(query + ' LIMIT 1', args)!
	return scan_push(row.vals)
}

pub fn (mut d DB) save_push_subscription(user_id i64, attrs map[string]?string, agent string) ! {
	now := stamp(d.now())
	mut vals := [user_id.str()]
	for key in ['endpoint', 'p256dh_key', 'auth_key'] {
		if key in attrs {
			value := attrs[key] or { ?string(none) }
			if v := value {
				vals << v
				continue
			}
		}
		vals << ''
	}
	// NULL attributes round-trip as '' here; find_push_subscription callers
	// pass explicit none for NULL matching.
	vals << agent
	vals << now
	vals << now
	d.exec_none('INSERT INTO push_subscriptions(user_id,endpoint,p256dh_key,auth_key,user_agent,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',
		vals)!
}

pub fn (mut d DB) touch_push_subscription(id i64) ! {
	d.exec_none('UPDATE push_subscriptions SET updated_at=? WHERE id=?', [
		stamp(d.now()),
		id.str(),
	])!
}

pub fn (mut d DB) delete_push_subscription(user_id i64, id i64) ! {
	d.exec_none('DELETE FROM push_subscriptions WHERE user_id=? AND id=?', [
		user_id.str(), id.str()])!
}

pub fn (mut d DB) unread_count(user_id i64) !i64 {
	return d.query_int('SELECT count(*) FROM memberships WHERE user_id=? AND unread_at IS NOT NULL', [
		user_id.str(),
	])
}

pub fn (mut d DB) push_recipients(room i64, creator i64, mentioned []i64) ![]PushSubscription {
	mut query := 'SELECT ' + push_columns +
		" FROM push_subscriptions p JOIN users u ON u.id=p.user_id JOIN memberships m ON m.user_id=u.id WHERE m.room_id=? AND m.user_id!=? AND (m.connected_at IS NULL OR m.connected_at<?) AND (m.involvement='everything'"
	mut args := [room.str(), creator.str(), stamp(d.now().add(-time.minute))]
	if mentioned.len > 0 {
		mut marks := []string{}
		for id in mentioned {
			marks << '?'
			args << id.str()
		}
		query += " OR (m.involvement='mentions' AND m.user_id IN (" + marks.join(',') + '))'
	}
	return d.push_query(query + ") ORDER BY CASE m.involvement WHEN 'everything' THEN 0 ELSE 1 END",
		args)
}

pub fn (mut d DB) room_member_ids(room i64) ![]i64 {
	rows := d.query_all('SELECT user_id FROM memberships WHERE room_id=?', [
		room.str()])!
	mut ids := []i64{}
	for r in rows {
		ids << r.vals[0].i64()
	}
	return ids
}
