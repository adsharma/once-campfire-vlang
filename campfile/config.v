// Package campfile is the V transpile of
// ../once-campfire-python/src/campfile (config.py, db.py, fq.py,
// queries.py, ops.py, state.py and __init__.py): the application layer
// that puts the pure domain in campfire/ and workload/ behind SQLite and
// HTTP.
//
// Layering (the point of this port):
//
//	campfire/    pure domain rules over an in-memory Store   (domain/campfire.py)
//	workload/    views, search index, seeder, hot paths      (domain/workload.py)
//	campfile/    SQLite persistence, auth, ops               (db.py, queries.py, ops.py)
//	campfile/routes/  HTTP handlers returning JSON            (routes/*.py)
//
// The domain packages import nothing from this one, and nothing here
// reaches back into them for rules: only the enum tables, the page size
// and the view structs are shared.
module campfile

import os

// Config mirrors ../once-campfire-python/src/campfile/config.py. V has no
// class attributes read from the environment at import time, so the values
// are resolved in `from_env` instead of at struct declaration.
pub struct Config {
pub:
	users         int
	messages      int
	seed          int
	db_url        string
	secret_key    string
	seed_password string
}

fn env_int(name string, fallback int) int {
	raw := os.getenv(name)
	if raw == '' {
		return fallback
	}
	return raw.int()
}

pub fn (cfg &Config) from_env() Config {
	return Config{
		users:         env_int('USERS', 60)
		messages:      env_int('MESSAGES', 3000)
		seed:          env_int('SEED', 42)
		db_url:        env_or('DB_URL', 'sqlite:///./campfile-bench.db')
		secret_key:    env_or('SECRET_KEY_BASE', 'dev')
		seed_password: env_or('SEED_PASSWORD', 'password')
	}
}

fn env_or(name string, fallback string) string {
	raw := os.getenv(name)
	if raw == '' {
		return fallback
	}
	return raw
}

// db_path turns `sqlite:///./campfile-bench.db` into a file path. Only the
// sqlite scheme exists in V (`db.sqlite`), so the URL form is kept for
// parity with the python config.
pub fn (cfg &Config) db_path() string {
	url := cfg.db_url
	if url.starts_with('sqlite:///') {
		return url[10..]
	}
	if url.starts_with('sqlite://') {
		return url[9..]
	}
	return url
}

// default_secret_key reports whether the app is running on the shipped
// development secret (python logs a warning in the same place).
pub fn (cfg &Config) default_secret_key() bool {
	return cfg.secret_key == '' || cfg.secret_key == 'dev'
}