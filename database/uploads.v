module database

// BlobStager keeps file copying outside the SQLite writer while committing the
// blob and its owning record together. storage.Staged implements it.
pub interface BlobStager {
mut:
	insert(mut d DB) !i64
	keep()
	discard()
}

// transaction_ret is transaction for closures that produce a value.
pub fn (mut d DB) transaction_ret(f fn (mut DB) !i64) !i64 {
	d.wmu.lock()
	defer {
		d.wmu.unlock()
	}
	d.writer.exec('BEGIN IMMEDIATE;')!
	new_id := f(mut d) or {
		d.writer.rollback() or {}
		return err
	}
	d.writer.commit()!
	return new_id
}

// record_with_upload commits the record and its avatar/logo together. Files
// staged before the transaction are removed on failure; old blobs are purged
// after commit. The update closure returns the owning record id.
pub fn (mut d DB) record_with_upload(kind string, id &i64, uploads []BlobStager, update fn (mut DB) !i64) ! {
	if uploads.len == 0 {
		new_id := d.transaction_ret(update)!
		unsafe {
			*id = new_id
		}
		return
	}
	mut staged := uploads[0]
	name := if kind == 'Account' {
		'logo'
	} else if kind == 'User' {
		'avatar'
	} else {
		return error('invalid upload record type "${kind}"')
	}
	mut purged := []i64{}
	d.manual_begin() or {
		staged.discard()
		return err
	}
	mut failed := true
	defer {
		if failed {
			d.manual_rollback()
			staged.discard()
		}
	}
	new_id := update(mut d) or {
		return err
	}
	unsafe {
		*id = new_id
	}
	blob := staged.insert(mut d) or {
		return err
	}
	purged = d.attachment_blob_ids('record_type=? AND record_id=? AND name=?', [
		kind,
		new_id.str(),
		name,
	]) or {
		return err
	}
	d.tx_exec('DELETE FROM active_storage_attachments WHERE record_type=? AND record_id=? AND name=?',
		[kind, new_id.str(), name]) or {
		return err
	}
	if blob != 0 {
		d.tx_exec('INSERT INTO active_storage_attachments(blob_id,record_type,record_id,name,created_at) VALUES (?,?,?,?,?)',
			[blob.str(), kind, new_id.str(), name, stamp(d.now())]) or {
			return err
		}
	}
	d.manual_commit() or {
		return err
	}
	failed = false
	staged.keep()
	d.purge_detached(purged)
}
