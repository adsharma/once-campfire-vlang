module database

// attachment_blob_ids is called inside the transaction that removes the
// attachment rows; its result is dispatched only after that transaction commits.
pub fn (mut d DB) attachment_blob_ids(condition string, args []string) ![]i64 {
	rows := d.tx_all('SELECT DISTINCT blob_id FROM active_storage_attachments WHERE ' + condition,
		args)!
	mut ids := []i64{}
	for r in rows {
		ids << r.vals[0].i64()
	}
	return ids
}

pub fn (mut d DB) purge_detached(ids []i64) {
	if ids.len > 0 {
		if f := d.purge_blobs {
			f(ids)
		}
	}
}

pub fn (mut d DB) messages_by_creator(user i64) ![]Message {
	rows := d.query_all(message_select + 'WHERE m.creator_id=? ORDER BY m.id', [user.str()])!
	return scan_message_rows(rows)
}
