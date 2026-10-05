module database

import time

pub fn (mut d DB) user(id i64) !User {
	row := d.query_one('SELECT ' + user_columns + ' FROM users u WHERE u.id=?', [id.str()])!
	return scan_user(row.vals)
}

pub fn (mut d DB) users(room i64, bots_only bool) ![]User {
	mut query := 'SELECT ' + user_columns + ' FROM users u '
	mut args := []string{}
	if room != 0 {
		query += 'JOIN memberships m ON m.user_id=u.id AND m.room_id=? '
		args << room.str()
	}
	query += 'WHERE u.status=0 '
	if bots_only {
		query += 'AND u.role=2 '
	}
	return d.scan_users(d.query_all(query + 'ORDER BY lower(u.name)', args)!)
}

pub fn (mut d DB) setup(name string, email string, password_digest string, uploads []BlobStager) !User {
	if name.trim_space() == '' || email.trim_space() == '' || password_digest == '' {
		return err_validation()
	}
	mut uid := i64(0)
	d.record_with_upload('User', &uid, uploads, fn [name, email, password_digest] (mut tx DB) !i64 {
		n := tx.query_int('SELECT count(*) FROM accounts', [])!
		if n != 0 {
			return err_forbidden()
		}
		now := stamp(tx.now())
		tx.tx_exec("INSERT INTO accounts(name,join_code,settings,created_at,updated_at) VALUES (?,?,?,?,?)",
			['Campfire', token(), '{}', now, now])!
		tx.tx_exec('INSERT INTO users(name,email_address,password_digest,role,status,created_at,updated_at) VALUES (?,?,?,1,0,?,?)',
			[name, email, password_digest, now, now])!
		id := tx.writer.last_insert_rowid()
		tx.tx_exec("INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES (?,'Rooms::Open',?,?,?)",
			['All Talk', id.str(), now, now])!
		room := tx.writer.last_insert_rowid()
		tx.tx_exec('INSERT INTO memberships(room_id,user_id,created_at,updated_at) VALUES (?,?,?,?)',
			[room.str(), id.str(), now, now])!
		return id
	})!
	return User{
		id:         uid
		name:       name
		email:      email
		role:       1
		updated_at: d.now()
	}
}

pub fn (mut d DB) create_user(name string, email string, password string, bio string, role int, webhook ?string, uploads []BlobStager) !User {
	mut uid := i64(0)
	mut bot_token := ''
	d.record_with_upload('User', &uid, uploads, fn [name, email, password, bio, role, webhook] (mut tx DB) !i64 {
		now := stamp(tx.now())
		is_bot := role == 2
		mut token_str := ''
		if is_bot {
			token_str = random_token(12)
			tx.tx_exec('INSERT INTO users(name,email_address,password_digest,bio,role,status,bot_token,created_at,updated_at) VALUES (?,NULL,NULL,?,?,0,?,?,?)',
				[name, bio, role.str(), token_str, now, now])!
		} else {
			tx.tx_exec('INSERT INTO users(name,email_address,password_digest,bio,role,status,bot_token,created_at,updated_at) VALUES (?,?,?,?,?,0,NULL,?,?)',
				[name, email, password, bio, role.str(), now, now])!
		}
		id := tx.writer.last_insert_rowid()
		tx.tx_exec("INSERT INTO memberships(room_id,user_id,created_at,updated_at) SELECT id,?,?,? FROM rooms WHERE type='Rooms::Open'",
			[id.str(), now, now])!
		if is_bot {
			if hook := webhook {
				tx.tx_exec('INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES (?,?,?,?)',
					[id.str(), hook, now, now])!
			}
		}
		return id
	})!
	if role == 2 {
		row := d.query_one('SELECT coalesce(bot_token,\'\') FROM users WHERE id=?', [uid.str()])!
		bot_token = row.vals[0]
	}
	return User{
		id:         uid
		name:       name
		email:      email
		password:   password
		role:       role
		bio:        bio
		bot_token:  bot_token
		updated_at: d.now()
	}
}

pub fn (mut d DB) update_user(id i64, attributes map[string]string, webhook ?string, uploads []BlobStager) ! {
	mut uid := id
	d.record_with_upload('User', &uid, uploads, fn [id, attributes, webhook] (mut tx DB) !i64 {
		mut sets := ['updated_at=?']
		mut args := [stamp(tx.now())]
		for key in ['name', 'email_address', 'password_digest', 'bio', 'role', 'bot_token'] {
			if value := attributes[key] {
				sets << key + '=?'
				args << value
			}
		}
		args << id.str()
		tx.tx_exec('UPDATE users SET ' + sets.join(',') + ' WHERE id=?', args)!
		if tx.writer.get_affected_rows_count() == 0 {
			return err_no_rows()
		}
		if hook := webhook {
			now := stamp(tx.now())
			if hook.trim_space() == '' {
				tx.tx_exec('DELETE FROM webhooks WHERE user_id=?', [id.str()])!
			} else {
				exists := tx.tx_one('SELECT count(*) FROM webhooks WHERE user_id=?', [id.str()])!
				if exists.vals[0] != '0' {
					tx.tx_exec('UPDATE webhooks SET url=?,updated_at=? WHERE user_id=?',
						[hook, now, id.str()])!
				} else {
					tx.tx_exec('INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES (?,?,?,?)',
						[id.str(), hook, now, now])!
				}
			}
		}
		return id
	})!
}

pub fn (mut d DB) bot(key string) !User {
	cut := key.index('-') or { return err_no_rows() }
	id := key[..cut]
	tok := key[cut + 1..]
	if id == '' || tok == '' {
		return err_no_rows()
	}
	row := d.query_one('SELECT ' + user_columns + ' FROM users u WHERE u.id=? AND u.bot_token=? AND u.role=2 AND u.status=0',
		[id, tok])!
	return scan_user(row.vals)
}

pub fn (mut d DB) deactivate_user(id i64) ! {
	d.transaction(fn [id] (mut tx DB) ! {
		now := stamp(tx.now())
		row := tx.tx_one('SELECT email_address IS NULL,coalesce(email_address,\'\') FROM users WHERE id=?',
			[id.str()])!
		if row.vals.len == 0 {
			return err_no_rows()
		}
		if row.vals[0] == '1' {
			tx.tx_exec('UPDATE users SET status=1,email_address=NULL,updated_at=? WHERE id=?',
				[now, id.str()])!
		} else {
			addr := row.vals[1].replace('@', '-deactivated-' + uuid() + '@')
			tx.tx_exec('UPDATE users SET status=1,email_address=?,updated_at=? WHERE id=?',
				[addr, now, id.str()])!
		}
		for table in ['push_subscriptions', 'searches', 'sessions'] {
			tx.tx_exec('DELETE FROM ' + table + ' WHERE user_id=?', [id.str()])!
		}
		tx.tx_exec("DELETE FROM memberships WHERE user_id=? AND room_id IN (SELECT id FROM rooms WHERE type!='Rooms::Direct')",
			[id.str()])!
	})!
}

pub fn (mut d DB) ban_user(id i64, ban bool) ! {
	d.transaction(fn [id, ban] (mut tx DB) ! {
		now := stamp(tx.now())
		status := if ban { '2' } else { '0' }
		if ban {
			tx.tx_exec("INSERT INTO bans(user_id,ip_address,created_at,updated_at) SELECT DISTINCT user_id,ip_address,?,? FROM sessions WHERE user_id=? AND ip_address IS NOT NULL AND trim(ip_address)!=''",
				[now, now, id.str()])!
			tx.tx_exec('DELETE FROM sessions WHERE user_id=?', [id.str()])!
		} else {
			tx.tx_exec('DELETE FROM bans WHERE user_id=?', [id.str()])!
		}
		tx.tx_exec('UPDATE users SET status=?,updated_at=? WHERE id=?', [status, now, id.str()])!
	})!
	if ban {
		if f := d.remove_banned_content {
			f(id)
		}
	}
}

pub fn (mut d DB) banned_ip(ip string) !bool {
	n := d.query_int('SELECT count(*) FROM bans WHERE ip_address=?', [ip])!
	return n > 0
}

pub fn (mut d DB) refresh_session(tok string, agent string, ip string) !bool {
	now := d.now()
	row := d.query_one('SELECT last_active_at FROM sessions WHERE token=?', [tok])!
	active := parse_stamp(row.vals[0])!
	if active.unix() >= now.add(-time.hour).unix() {
		return false
	}
	n := d.affected('UPDATE sessions SET last_active_at=?,updated_at=?,user_agent=?,ip_address=? WHERE token=? AND last_active_at<?',
		[stamp(now), stamp(now), agent, ip, tok, stamp(now.add(-time.hour))])!
	return n > 0
}

pub fn (mut d DB) user_by_email(email string) !User {
	row := d.query_one('SELECT ' + user_columns + ' FROM users u WHERE u.email_address=? AND u.status=0',
		[email])!
	return scan_user(row.vals)
}

pub fn (mut d DB) session_user(tok string) !User {
	row := d.query_one('SELECT ' + user_columns + ' FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.token=? AND u.status=0',
		[tok])!
	return scan_user(row.vals)
}

pub fn (mut d DB) start_session(user_id i64, agent string, ip string) !string {
	tok := token()
	now := stamp(d.now())
	d.exec_none('INSERT INTO sessions(token,user_id,user_agent,ip_address,last_active_at,created_at,updated_at) VALUES (?,?,?,?,?,?,?)',
		[tok, user_id.str(), agent, ip, now, now, now])!
	return tok
}

pub fn (mut d DB) account_users(include_banned bool) ![]User {
	status := if include_banned { 'u.status IN (0,2)' } else { 'u.status=0' }
	return d.scan_users(d.query_all('SELECT ' + user_columns + ' FROM users u WHERE ' + status + ' AND u.role != 2 ORDER BY lower(u.name)',
		[])!)
}

pub fn (mut d DB) room_members(room i64) ![]User {
	return d.scan_users(d.query_all('SELECT ' + user_columns + ' FROM users u JOIN memberships m ON m.user_id=u.id WHERE m.room_id=?',
		[room.str()])!)
}

pub fn (mut d DB) direct_placeholders(user_id i64) ![]User {
	rows := d.query_all("SELECT DISTINCT user_id FROM memberships WHERE room_id IN (SELECT r.id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE r.type='Rooms::Direct' AND m.user_id=?)",
		[user_id.str()])!
	mut ids := []string{}
	for r in rows {
		ids << r.vals[0]
	}
	ids << user_id.str()
	mut marks := []string{len: ids.len, init: '?'}
	limit := if 20 - ids.len > 0 { 20 - ids.len } else { 0 }
	return d.scan_users(d.query_all('SELECT ' + user_columns + ' FROM users u WHERE u.status=0 AND u.id NOT IN (' + marks.join(',') + ') ORDER BY u.created_at ASC LIMIT ' + limit.str(),
		ids)!)
}
