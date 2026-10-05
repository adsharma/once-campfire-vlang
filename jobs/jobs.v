// Package jobs runs the bounded, independent queues used by the Rust port.
module jobs

import sync
import time

pub type Work = fn () !

const queue_depth = 1024

pub struct Runner {
mut:
	mu      &sync.Mutex
	closed  bool
	pending int
	done    chan bool
	queues  map[string]chan Work
}

fn worker(queue chan Work, done chan bool, kind string) {
	for {
		work := <-queue or { break }
		work() or { eprintln('background job failed kind=${kind} err=${err}') }
		done <- true
	}
}

// new_runner starts concurrency workers per named kind, like Go's New.
pub fn new_runner(concurrency int, kinds ...string) &Runner {
	mut r := &Runner{
		mu:     sync.new_mutex()
		done:   chan bool{cap: queue_depth * kinds.len}
		queues: {}
	}
	n := if concurrency > 1 { concurrency } else { 1 }
	for kind in kinds {
		queue := chan Work{cap: queue_depth}
		r.queues[kind] = queue
		for _ in 0 .. n {
			spawn worker(queue, r.done, kind)
		}
	}
	return r
}

pub fn (mut r Runner) enqueue(kind string, work Work) bool {
	queue := r.queues[kind] or { panic('unregistered job kind: ' + kind) }
	r.mu.lock()
	if r.closed {
		r.mu.unlock()
		return false
	}
	r.pending++
	r.mu.unlock()
	select {
		queue <- work {
			return true
		}
		else {
			r.mu.lock()
			r.pending--
			r.mu.unlock()
			eprintln('background job queue full; job dropped kind=${kind}')
			return false
		}
	}
}

// close drains queued work like the Go port: the HTTP server stops accepting
// requests first, and queued work may still enqueue dependent work.
pub fn (mut r Runner) close(timeout time.Duration) {
	deadline_ms := time.now().unix_milli() + timeout.milliseconds()
	for {
		r.mu.lock()
		if r.closed {
			r.mu.unlock()
			return
		}
		if r.pending == 0 {
			r.closed = true
			for _, q in r.queues {
				q.close()
			}
			r.mu.unlock()
			return
		}
		r.mu.unlock()
		select {
			_ := <-r.done {
				r.mu.lock()
				r.pending--
				r.mu.unlock()
			}
			else {
				if time.now().unix_milli() >= deadline_ms {
					r.mu.lock()
					r.closed = true
					r.mu.unlock()
					eprintln('background jobs abandoned at shutdown')
					return
				}
				time.sleep(5 * time.millisecond)
			}
		}
	}
}
