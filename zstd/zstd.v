// Package zstd exposes libzstd's bounded streaming encoder, mirroring the
// Go port's cgo binding. Requires libzstd at build time (`-lzstd`), the same
// native dependency as the Go port.
module zstd

import io

#flag -lzstd
#include <zstd.h>

struct C.ZSTD_CCtx {}

fn C.ZSTD_createCCtx() &C.ZSTD_CCtx
fn C.ZSTD_freeCCtx(&C.ZSTD_CCtx) usize
fn C.ZSTD_CCtx_setParameter(&C.ZSTD_CCtx, int, int) usize
fn C.ZSTD_isError(usize) u32
fn C.ZSTD_getErrorName(usize) &char
fn C.ZSTD_compressStream2(&C.ZSTD_CCtx, &C.ZSTD_outBuffer, &C.ZSTD_inBuffer, int) usize
fn C.ZSTD_CStreamOutSize() usize

struct C.ZSTD_inBuffer {
	src  voidptr
	size usize
	pos  usize
}

struct C.ZSTD_outBuffer {
	dst  voidptr
	size usize
	pos  usize
}

const zstd_end_continue = 0
const zstd_end_flush = 1
const zstd_end_end = 2

pub struct Writer {
mut:
	ctx    &C.ZSTD_CCtx
	output io.Writer
	buffer []u8
	err    string
	closed bool
}

fn zstd_error_name(code usize) string {
	return unsafe { cstring_to_vstring(C.ZSTD_getErrorName(code)) }
}

pub fn new_writer(output io.Writer) !Writer {
	ctx := C.ZSTD_createCCtx()
	if ctx == unsafe { nil } {
		return error('zstd context allocation failed')
	}
	// C.ZSTD_c_compressionLevel == 100.
	code := C.ZSTD_CCtx_setParameter(ctx, 100, 1)
	if C.ZSTD_isError(code) != 0 {
		msg := zstd_error_name(code)
		C.ZSTD_freeCCtx(ctx)
		return error(msg)
	}
	return Writer{
		ctx:    ctx
		output: output
		buffer: []u8{len: int(C.ZSTD_CStreamOutSize())}
	}
}

// step feeds p through the stream and flushes produced bytes. It returns the
// bytes consumed and whether the stream is fully flushed.
fn (mut w Writer) step(p []u8, mode int) !(int, bool) {
	mut inp := C.ZSTD_inBuffer{
		src:  if p.len > 0 { p.data } else { unsafe { nil } }
		size: usize(p.len)
	}
	mut outp := C.ZSTD_outBuffer{
		dst:  w.buffer.data
		size: usize(w.buffer.len)
	}
	code := C.ZSTD_compressStream2(w.ctx, &outp, &inp, mode)
	if C.ZSTD_isError(code) != 0 {
		return error(zstd_error_name(code))
	}
	if outp.pos > 0 {
		produced := w.buffer[..int(outp.pos)]
		mut written := 0
		for written < produced.len {
			n := w.output.write(produced[written..])!
			written += n
		}
	}
	return int(inp.pos), code == 0
}

pub fn (mut w Writer) write(p []u8) !int {
	if w.closed {
		return error('write to closed zstd writer')
	}
	if w.err != '' {
		return error(w.err)
	}
	mut consumed := 0
	for consumed < p.len {
		n, _ := w.step(p[consumed..], zstd_end_continue) or {
			w.err = err.msg()
			return error(w.err)
		}
		consumed += n
		if n == 0 {
			break
		}
	}
	return consumed
}

pub fn (mut w Writer) flush() ! {
	if w.closed {
		return error('flush of closed zstd writer')
	}
	if w.err != '' {
		return error(w.err)
	}
	for {
		_, done := w.step([]u8{}, zstd_end_flush) or {
			w.err = err.msg()
			return error(w.err)
		}
		if done {
			return
		}
	}
}

pub fn (mut w Writer) close() ! {
	if w.closed {
		if w.err != '' {
			return error(w.err)
		}
		return
	}
	w.closed = true
	defer {
		C.ZSTD_freeCCtx(w.ctx)
	}
	if w.err != '' {
		return error(w.err)
	}
	for {
		_, done := w.step([]u8{}, zstd_end_end) or {
			w.err = err.msg()
			return error(w.err)
		}
		if done {
			return
		}
	}
}
