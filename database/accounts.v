module database

import db.sqlite

pub const user_columns = "u.id,u.name,coalesce(u.email_address,''),coalesce(u.password_digest,''),u.role,u.status,coalesce(u.bio,''),u.updated_at,coalesce(u.bot_token,'')"

fn scan_user(vals []string) !User {
	return User{
		id:         vals[0].i64()
		name:       vals[1]
		email:      vals[2]
		password:   vals[3]
		role:       vals[4].int()
		status:     vals[5].int()
		bio:        vals[6]
		updated_at: parse_stamp(vals[7])!
		bot_token:  vals[8]
	}
}

fn (mut d DB) scan_users(rows []sqlite.Row) ![]User {
	mut users := []User{}
	for r in rows {
		users << scan_user(r.vals)!
	}
	return users
}

pub fn (mut d DB) account() !Account {
	row :=
		d.query_one("SELECT id,name,join_code,coalesce(custom_styles,''),coalesce(settings,'{}'),updated_at,EXISTS(SELECT 1 FROM active_storage_attachments WHERE record_type='Account' AND record_id=accounts.id AND name='logo') FROM accounts ORDER BY id LIMIT 1", [])!
	return Account{
		id:            row.vals[0].i64()
		name:          row.vals[1]
		join_code:     row.vals[2]
		custom_styles: row.vals[3]
		settings:      row.vals[4]
		updated_at:    parse_stamp(row.vals[5])!
		has_logo:      row.vals[6] != '0' && row.vals[6] != ''
	}
}

fn set_restrict(settings string, restrict bool) string {
	val := if restrict { 'true' } else { 'false' }
	key := '"restrict_room_creation_to_administrators"'
	idx := settings.index(key) or {
		inner := settings.trim_space()
		if inner == '' || inner == '{}' {
			return '{"restrict_room_creation_to_administrators":' + val + '}'
		}
		if inner.ends_with('}') {
			return inner[..inner.len - 1] + ',"restrict_room_creation_to_administrators":' + val +
				'}'
		}
		return inner
	}
	after_key := idx + key.len
	rest := settings[after_key..]
	colon := rest.index(':') or { return settings }
	mut j := colon + 1
	for j < rest.len && (rest[j] == ` ` || rest[j] == `\t`) {
		j++
	}
	mut k := j
	for k < rest.len && rest[k] != `,` && rest[k] != `}` {
		k++
	}
	return settings[..after_key] + rest[..colon + 1] + val + rest[k..]
}

pub fn (mut d DB) update_account(name ?string, styles ?string, restrict ?bool, reset_join bool, uploads []BlobStager) ! {
	mut acc_id := i64(0)
	d.record_with_upload('Account', &acc_id, uploads, fn [name, styles, restrict, reset_join] (mut tx DB) !i64 {
		row := tx.tx_one("SELECT id,coalesce(settings,'{}') FROM accounts ORDER BY id LIMIT 1", [])!
		id := row.vals[0]
		settings := row.vals[1]
		mut sets := ['updated_at=?']
		mut args := [stamp(tx.now())]
		if n := name {
			sets << 'name=?'
			args << n
		}
		if st := styles {
			sets << 'custom_styles=?'
			args << st
		}
		if r := restrict {
			sets << 'settings=?'
			args << set_restrict(settings, r)
		}
		if reset_join {
			sets << 'join_code=?'
			args << random_token(24)
		}
		args << id
		tx.tx_exec('UPDATE accounts SET ' + sets.join(',') + ' WHERE id=?', args)!
		return id.i64()
	})!
}
