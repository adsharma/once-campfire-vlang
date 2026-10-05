module database

pub fn (mut d DB) autocomplete_users(room i64, query string) ![]User {
	mut query_str := 'SELECT ' + user_columns + ' FROM users u '
	mut args := []string{}
	if room != 0 {
		query_str += 'JOIN memberships m ON m.user_id=u.id AND m.room_id=? '
		args << room.str()
	}
	query_str += 'WHERE u.status=0'
	if query != '' {
		query_str += ' AND u.name LIKE ?'
		args << '%' + query + '%'
	}
	query_str += ' ORDER BY lower(u.name)'
	return d.scan_users(d.query_all(query_str, args)!)
}
