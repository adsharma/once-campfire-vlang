// Package database uses the existing Rails SQLite schema and explicit SQL.
module database

import db.sqlite
import os
import sync
import time

const migrations = ['20231215043540', '20231220143106', '20240110071740', '20240115124901',
	'20240130003150', '20240130213001', '20240131105830', '20240209110503', '20250825100957',
	'20250825100958', '20250825100959', '20251126092013', '20251126115722', '20251126130131',
	'20251212154340']

const schema_sql = $embed_file('schema.sql')

// A single writer prevents pool starvation while WAL readers proceed independently.
pub struct DB {
mut:
	writer   &sqlite.DB
	readers  []&sqlite.DB
	rmu      &sync.Mutex
	wmu      &sync.Mutex
	read_idx int
	frozen   ?time.Time
pub mut:
	reset_connections     ?fn (i64)
	purge_blobs           ?fn ([]i64)
	remove_banned_content ?fn (i64)
}

pub fn open(path string, readers int) !&DB {
	if readers < 1 {
		return error('database readers must be positive')
	}
	abs := os.real_path(path)
	os.mkdir_all(os.dir(abs))!
	mut writer := sqlite.connect(abs)!
	writer.exec('PRAGMA busy_timeout=5000;')!
	writer.exec('PRAGMA foreign_keys=ON;')!
	writer.exec('PRAGMA journal_mode=WAL;')!
	writer.exec('PRAGMA synchronous=NORMAL;')!
	prepare(mut writer)!
	mut rds := []&sqlite.DB{}
	for _ in 0 .. readers {
		mut r := sqlite.connect(abs)!
		r.exec('PRAGMA busy_timeout=5000;')!
		r.exec('PRAGMA foreign_keys=ON;')!
		rds << &r
	}
	mut frozen := ?time.Time(none)
	frozen_raw := os.getenv('CAMPFIRE_FROZEN_TIME')
	if frozen_raw != '' {
		frozen = parse_rfc3339(frozen_raw)!
	}
	return &DB{
		writer:  &writer
		readers: rds
		rmu:     sync.new_mutex()
		wmu:     sync.new_mutex()
		frozen:  frozen
	}
}

pub fn (mut d DB) close() ! {
	for mut r in d.readers {
		r.close()!
	}
	d.writer.close()!
}

pub fn (d &DB) now() time.Time {
	if f := d.frozen {
		return f
	}
	return time.now()
}

pub fn stamp(t time.Time) string {
	u := t.as_utc()
	ms := u.nanosecond / 1000
	return '${pad4(u.year)}-${pad2(u.month)}-${pad2(u.day)} ${pad2(u.hour)}:${pad2(u.minute)}:${pad2(u.second)}.${pad6(ms)}'
}

fn pad2(n int) string {
	if n < 10 {
		return '0${n}'
	}
	return n.str()
}

fn pad4(n int) string {
	mut s := n.str()
	for s.len < 4 {
		s = '0' + s
	}
	return s
}

fn pad6(n int) string {
	mut s := n.str()
	for s.len < 6 {
		s = '0' + s
	}
	return s
}

pub fn parse_stamp(s string) !time.Time {
	// Accepts "2006-01-02 15:04:05.000000", with optional timezone/ISO variants.
	mut rest := s.trim_space().replace('T', ' ')
	date_time := rest.split(' ')
	if date_time.len < 2 {
		return error('invalid timestamp ${s}')
	}
	d := date_time[0].split('-')
	t := date_time[1].split(':')
	if d.len != 3 || t.len != 3 {
		return error('invalid timestamp ${s}')
	}
	sec_frac := t[2].split('.')
	sec := sec_frac[0].int()
	mut micro := 0
	mut offset_min := 0
	if sec_frac.len > 1 {
		mut frac := sec_frac[1]
		mut cut := -1
		for i, c in frac.bytes() {
			if c == `+` || c == `-` || c == `Z` {
				cut = i
				break
			}
		}
		if cut >= 0 {
			tz := frac[cut..]
			frac = frac[..cut]
			if tz != 'Z' && tz.len >= 3 {
				sign := if tz[0] == `-` { -1 } else { 1 }
				off := tz[1..].replace(':', '')
				if off.len >= 4 {
					offset_min = sign * (off[..2].int() * 60 + off[2..4].int())
				}
			}
		}
		for frac.len < 6 {
			frac += '0'
		}
		micro = frac[..6].int()
	}
	mut hour := t[0].int()
	mut minute := t[1].int() - offset_min
	for minute < 0 {
		minute += 60
		hour--
	}
	for minute >= 60 {
		minute -= 60
		hour++
	}
	return time.Time{
		year:       d[0].int()
		month:      d[1].int()
		day:        d[2].int()
		hour:       hour
		minute:     minute
		second:     sec
		nanosecond: micro * 1000
	}
}

fn parse_rfc3339(s string) !time.Time {
	mut rest := s.trim_space()
	if rest.ends_with('Z') {
		rest = rest[..rest.len - 1]
	}
	return parse_stamp(rest.replace('T', ' '))
}

fn prepare(mut db sqlite.DB) ! {
	count :=
		db.q_int("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations'")!
	if count == 0 {
		other :=
			db.q_int("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")!
		if other != 0 {
			return error('refusing to initialize a nonempty database without schema_migrations')
		}
		for stmt in schema_sql.to_string().split(';') {
			if stmt.trim_space() == '' {
				continue
			}
			db.exec(stmt)!
		}
		for i := migrations.len - 1; i >= 0; i-- {
			db.exec_param_many('INSERT INTO schema_migrations(version) VALUES (?)', [
				migrations[i],
			])!
		}
		now := stamp(time.now())
		for pair in [['environment', 'production'],
			['schema_sha1', 'f75da8dad38bfb179ffd757bd7a7c2b3f818bc29']] {
			db.exec_param_many('INSERT INTO ar_internal_metadata(key,value,created_at,updated_at) VALUES (?,?,?,?)', [
				pair[0],
				pair[1],
				now,
				now,
			])!
		}
	}
	for v in migrations {
		rows := db.exec_param_many('SELECT count(*) AS c FROM schema_migrations WHERE version=?', [
			v,
		])!
		if rows.len == 0 || rows[0].vals[0] != '1' {
			return error('pending migration ${v}: migrate with the reference app before starting')
		}
	}
	db.exec('CREATE INDEX IF NOT EXISTS index_messages_on_room_id_and_created_at ON messages(room_id,created_at)')!
}

// exec_none runs a write through the single writer connection.
pub fn (mut d DB) exec_none(query string, params []string) ! {
	d.wmu.lock()
	defer {
		d.wmu.unlock()
	}
	d.writer.exec_param_many(query, params)!
}

// last_id runs a write and returns the inserted rowid.
pub fn (mut d DB) insert(query string, params []string) !i64 {
	d.wmu.lock()
	defer {
		d.wmu.unlock()
	}
	d.writer.exec_param_many(query, params)!
	return d.writer.last_insert_rowid()
}

pub fn (mut d DB) affected(query string, params []string) !int {
	d.wmu.lock()
	defer {
		d.wmu.unlock()
	}
	d.writer.exec_param_many(query, params)!
	return d.writer.get_affected_rows_count()
}

// query_all runs a read on the pool.
pub fn (mut d DB) query_all(query string, params []string) ![]sqlite.Row {
	d.rmu.lock()
	defer {
		d.rmu.unlock()
	}
	h := d.readers[d.read_idx % d.readers.len]
	d.read_idx++
	return h.exec_param_many(query, params)
}

pub fn (mut d DB) query_one(query string, params []string) !sqlite.Row {
	rows := d.query_all(query, params)!
	if rows.len == 0 {
		return err_no_rows()
	}
	return rows[0]
}

pub fn (mut d DB) query_int(query string, params []string) !i64 {
	row := d.query_one(query, params)!
	return row.vals[0].i64()
}

// manual_begin locks the writer and opens an immediate transaction for callers
// that stage files inside the transaction (record_with_upload, messages).
pub fn (mut d DB) manual_begin() ! {
	d.wmu.lock()
	d.writer.exec('BEGIN IMMEDIATE;') or {
		d.wmu.unlock()
		return err
	}
}

pub fn (mut d DB) manual_commit() ! {
	d.writer.commit() or {
		d.writer.rollback() or {}
		d.wmu.unlock()
		return err
	}
	d.wmu.unlock()
}

pub fn (mut d DB) manual_rollback() {
	d.writer.rollback() or {}
	d.wmu.unlock()
}

// transaction serializes fn on the single writer connection, like Go's Transaction.
// transaction_with_result serializes a value-producing closure on the writer.
pub fn transaction_with_result[T](mut d DB, f fn (mut DB) !T) !T {
	d.wmu.lock()
	defer {
		d.wmu.unlock()
	}
	d.writer.exec('BEGIN IMMEDIATE;')!
	out := f(mut d) or {
		d.writer.rollback() or {}
		return err
	}
	d.writer.commit()!
	return out
}

pub fn (mut d DB) transaction(f fn (mut DB) !) ! {
	d.wmu.lock()
	defer {
		d.wmu.unlock()
	}
	d.writer.exec('BEGIN IMMEDIATE;')!
	f(mut d) or {
		d.writer.rollback() or {}
		return err
	}
	d.writer.commit()!
}

// tx_exec runs a write assuming the writer lock is already held by transaction.
pub fn (mut d DB) tx_exec(query string, params []string) ! {
	d.writer.exec_param_many(query, params)!
}

pub fn (mut d DB) tx_one(query string, params []string) !sqlite.Row {
	rows := d.writer.exec_param_many(query, params)!
	if rows.len == 0 {
		return err_no_rows()
	}
	return rows[0]
}

pub fn (mut d DB) affected_count() int {
	return d.writer.get_affected_rows_count()
}

pub fn (mut d DB) last_id() i64 {
	return d.writer.last_insert_rowid()
}

pub fn (mut d DB) tx_all(query string, params []string) ![]sqlite.Row {
	return d.writer.exec_param_many(query, params)
}
