module database

import os
import time

// backup writes an online SQLite snapshot beside its destination, then
// atomically replaces the previous backup only after SQLite completes.
// VACUUM INTO plays the role of Go's online backup API call.
pub fn (mut d DB) backup(destination string) ! {
	os.mkdir_all(os.dir(destination))!
	tmp := os.join_path(os.dir(destination), '.backup-${time.now().unix_micro()}.sqlite3')
	d.wmu.lock()
	d.writer.exec("VACUUM INTO '" + tmp.replace("'", "''") + "';") or {
		d.wmu.unlock()
		return err
	}
	d.wmu.unlock()
	os.rename(tmp, destination)!
}
