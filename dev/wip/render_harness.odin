package unit

// render_harness.odin — the pty the `render` and `wire` suites actually need.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY THIS IS NOT tests/support/terminal.odin's `enter_terminal`
// ─────────────────────────────────────────────────────────────────────────────
// `enter_terminal` calls `tb_init()`, which opens `/dev/tty`. That is what the
// PRODUCT does — it is wrong for a test binary in two separate ways:
//
//   1. `/dev/tty` needs a CONTROLLING TERMINAL. Under a nix sandbox, under CI,
//      and under this repo's own gate (`spawn_and_capture` points stdout/stderr
//      at FILES and never allocates a tty), there is none. `tb_init` returns
//      TB_ERR_INIT_OPEN (-4 / ENXIO). Measured here:
//          tb_init(/dev/tty) -> -4  No such device or address
//      A render suite built on it cannot be run by the gate at all.
//
//   2. Even where `/dev/tty` DOES exist, it is the developer's screen, and
//      nothing reads the emitted bytes back — so the WIRE-level proof the old
//      `script` typescript supplied could not be made against it. `tb_init`
//      swallows the stream into the terminal; there is no buffer to assert on.
//
// So the render suite brings its own pty: `openpty(3)`, sized to the same
// 120x40 the old harness set with `stty rows 40 cols 120`, termbox bound to
// the SLAVE with `tb_init_rwfd(slave, slave)`. Termbox is then talking to a
// real tty (it is one), and every byte it emits comes back out of the MASTER
// end. That stream IS the wire — the same bytes a terminal emulator would
// parse — captured rather than assumed.
//
// ─────────────────────────────────────────────────────────────────────────────
// The drain thread is not optional
// ─────────────────────────────────────────────────────────────────────────────
// A pty buffer is small (4 KiB on Linux). A full 120x40 repaint emits far
// more than that, so with nobody reading the master, `tb_present()` blocks in
// write() and the test hangs. The drain thread reads the master until the slave
// is closed, at which point read() returns EIO and the thread exits by itself.
// There is deliberately NO stop flag: a stop flag has to be checked between
// reads, which cannot happen while the thread is parked inside one, and the
// "fix" for that is a sleep — which is a race with a timeout on it.
//
// `pw_started` is awaited before `pty_open` returns so the first read is
// definitely parked before anything is presented. Without it there is a window
// where the drain has not yet reached read() and the master's data could be
// missed; it is cheap and it makes the capture total rather than probable.
//
// ─────────────────────────────────────────────────────────────────────────────
// Single occupancy
// ─────────────────────────────────────────────────────────────────────────────
// termbox and Clay are both PROCESS-WIDE SINGLETONS, and `core:testing` runs
// tests on a thread pool by default (ODIN_TEST_THREADS=0 → core count). Two
// render tests running at once would be two `tb_init`s racing for one global.
// Every test that touches the terminal takes RENDER_TERM_LOCK for its whole
// body, so exactly one holds it regardless of how the runner is threaded.
// ─────────────────────────────────────────────────────────────────────────────

import "core:c"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"

import clay "../../clay-odin"
import render "../../src/render"
import tb "../../vendor/termbox2-odin"
import support "../support"

import posix "core:sys/posix"

// The old harness pinned the pty with `stty rows 40 cols 120`. Same size here:
// a render test whose terminal size drifted would be asserting against a
// geometry nobody ever painted.
RENDER_ROWS :: 40
RENDER_COLS :: 120

// Clay arena slack over MinMemorySize, so the arena is never the limit.
CLAY_PAD :: 64 * 1024

// RENDER_TERM_LOCK serialises everything that touches a termbox or Clay global.
// A plain sync.Mutex, statically allocated: the lock has to outlive every test.
RENDER_TERM_LOCK : sync.Mutex = {}

//-----------------------------------------------------------------------------
// The pty
//-----------------------------------------------------------------------------

// Win_Size mirrors struct winsize (termios.h) for openpty's fourth argument.
Win_Size :: struct {
	rows   : u16,
	cols   : u16,
	xpixel : u16,
	ypixel : u16,
}

foreign import odin_c "system:c"

@(default_calling_convention = "c")
foreign odin_c {
	// openpty(slave, master, name, termios, winsize). NULL name/termios is the
	// usual call: unnamed pty, default line discipline, size from winsize.
	openpty :: proc(slave: ^posix.FD, master: ^posix.FD, name: rawptr, t: rawptr, ws: ^Win_Size) -> c.int ---
}

Pty_Wire :: struct {
	master   : posix.FD, // read end: the bytes termbox emitted come back here
	slave    : posix.FD, // termbox's rfd AND wfd; a real tty
	drain    : ^thread.Thread,
	started  : bool,     // set once the drain thread is parked in read()
	wire     : [dynamic]u8,
	captured : bool,     // drain joined; `wire` is final
	tb_live  : bool,     // termbox needs shutdown before the slave goes away
	up       : bool,
}

// STATIC and single-occupied under RENDER_TERM_LOCK. A heap-allocated pty
// handle handed to a cleanup outlives the test allocator that made it — the
// exact class of segfault the ledger documents for its own table.
pw : Pty_Wire = {}

drain_proc :: proc(th: ^thread.Thread) {
	w := transmute(^Pty_Wire)(th.data)
	tmp : [16384]u8
	sync.atomic_store(&w.started, true)
	for {
		n := posix.read(w.master, &tmp[0], c.size_t(len(tmp)))
		if n <= 0 { break } // EIO once the last slave fd closes
		for i := 0; i < int(n); i += 1 { append(&w.wire, tmp[i]) }
	}
}

// wire_lock takes the whole-terminal mutex for the calling test and registers
// its release as a core:testing cleanup, so a faulting test cannot strand the
// lock (which would hang the next render test rather than fail it).
wire_lock :: proc(t: ^testing.T, loc := #caller_location) {
	sync.mutex_lock(&RENDER_TERM_LOCK)
	testing.cleanup(t, wire_unlock_cb, nil)
	_ = loc
}

wire_unlock_cb :: proc(_: rawptr) { wire_teardown() }

// wire_teardown is idempotent: cleanup may run after the test already closed
// everything deliberately.
wire_teardown :: proc() {
	if !pw.up { return }
	if pw.tb_live {
		tb.tb_shutdown()
		pw.tb_live = false
	}
	if pw.drain != nil {
		if pw.slave != -1 {
			posix.close(pw.slave)
			pw.slave = -1
		}
		if !pw.captured {
			thread.join(pw.drain)
			thread.destroy(pw.drain)
			pw.drain = nil
			pw.captured = true
		}
	}
	if pw.master != -1 {
		posix.close(pw.master)
		pw.master = -1
	}
	clear(&pw.wire)
	render_clay_down()
	pw.up = false
}

// wire_open brings up the pty, binds termbox to it, and starts the drain.
// It does NOT render anything — that is the caller's job — so the same
// acquisition serves cell-level and wire-level suites alike.
wire_open :: proc(t: ^testing.T, label: string, loc := #caller_location) -> bool {
	wire_lock(t, loc=loc)

	master : posix.FD = -1
	slave : posix.FD = -1
	ws := Win_Size{rows=RENDER_ROWS, cols=RENDER_COLS}
	rc := openpty(&slave, &master, nil, nil, &ws)
	if rc != 0 {
		support.check(t, fmt.tprintf("{}: openpty allocated a pty", label), false,
			fmt.tprintf("openpty -> {} (errno={})", rc, posix.get_errno()))
		return false
	}
	pw.master = master
	pw.slave = slave
	pw.captured = false
	pw.tb_live = false
	pw.up = true
	clear(&pw.wire)

	pw.drain = thread.create(drain_proc, .Normal, "hs-render-wire-drain")
	pw.drain.data = pw
	thread.start(pw.drain)

	// Wait for the drain to be parked in read() before anything can be emitted,
	// so no byte can be lost to a thread that has not reached its read yet.
Spin : for _ in 0 ..< 200_000 {
		if sync.atomic_load(&pw.started) { break Spin }
		thread.yield()
	}
	if !sync.atomic_load(&pw.started) {
		support.check(t, fmt.tprintf("{}: wire drain thread started", label), false,
			"drain never reached its first read — capture would be partial")
		return false
	}

	// rfd == wfd == slave. isatty(rfd) is true, so termbox takes the tty path
	// (raw mode, real size) rather than the piped-stdout fallback.
	rv := tb.tb_init_rwfd(i32(slave), i32(slave))
	if rv != tb.TB_OK {
		support.check(t, fmt.tprintf("{}: termbox bound to the pty", label), false,
			fmt.tprintf("tb_init_rwfd -> {} ({})", rv, tb.tb_strerror(rv)))
		return false
	}
	pw.tb_live = true

	// TRUECOLOR first, cursor hidden second: the product's order, because the
	// colour mode decides what the painter emits and setting it after painting
	// asserts nothing about what was emitted.
	tb.tb_set_output_mode(tb.OUTPUT_TRUECOLOR)
	tb.tb_hide_cursor()

	support.note(t, fmt.tprintf("{}: pty up, termbox on slave {} master {}, {}x{}",
		label, i64(slave), i64(master), tb.tb_width(), tb.tb_height()))
	return true
}

// wire_capture finishes the stream: shut termbox down (so its exit codes are in
// the capture too), drop the slave so the drain sees EIO, and join it. After
// this `wire_bytes()` is final. Idempotent.
wire_capture :: proc(t: ^testing.T, label: string, loc := #caller_location) {
	if !pw.up || pw.captured { return }
	if pw.tb_live {
		tb.tb_shutdown()
		pw.tb_live = false
	}
	if pw.slave != -1 {
		posix.close(pw.slave)
		pw.slave = -1
	}
	if pw.drain != nil {
		thread.join(pw.drain)
		thread.destroy(pw.drain)
		pw.drain = nil
	}
	pw.captured = true
	support.note(t, fmt.tprintf("{} wire captured: {} bytes", label, len(pw.wire)))
}

wire_bytes :: proc() -> []u8 { return pw.wire[:] }

//-----------------------------------------------------------------------------
// Clay session
//-----------------------------------------------------------------------------

render_clay_buf : []u8 = nil

// render_clay_start brings up a Clay context wired to our measure function and
// our error handler, sized from Clay's own MinMemorySize rather than a guessed
// magic number. Callers hold RENDER_TERM_LOCK.
render_clay_start :: proc() -> bool {
	need := int(clay.MinMemorySize()) + CLAY_PAD
	if len(render_clay_buf) < need {
		if len(render_clay_buf) > 0 { delete(render_clay_buf) }
		render_clay_buf = make([]u8, need)
	}
	arena := clay.CreateArenaWithCapacityAndMemory(c.size_t(len(render_clay_buf)), raw_data(render_clay_buf))
	ctx := clay.Initialize(arena, clay.Dimensions{width = RENDER_COLS, height = RENDER_ROWS},
		render.errors_handler_for())
	if ctx == nil { return false }
	clay.SetMeasureTextFunction(render.measure_text, nil)
	return true
}

// render_clay_down releases the arena. Called from teardown so the suite's
// allocator accounts for it rather than leaking.
render_clay_down :: proc() {
	if len(render_clay_buf) > 0 {
		delete(render_clay_buf)
		render_clay_buf = nil
	}
}

render_cols :: proc(s: string) -> i32 {
	return render.text_columns(transmute([]u8)(s))
}

//-----------------------------------------------------------------------------
// Back-buffer probing
//-----------------------------------------------------------------------------

Render_Back_Cell :: struct {
	ch : u32,
	fg : tb.Attr,
	bg : tb.Attr,
}

// render_cell_at reads a cell back out of termbox's BACK buffer. This is the
// assertion surface: what the renderer decided to paint, not what we asked it
// to paint.
render_cell_at :: proc(x, y: i32) -> Render_Back_Cell {
	out := Render_Back_Cell{}
	ptr : ^^tb.Cell = nil
	if tb.tb_get_cell(x, y, 1, &ptr) == tb.TB_OK && ptr != nil {
		out.ch = ptr^.ch
		out.fg = ptr^.fg
		out.bg = ptr^.bg
	}
	return out
}

render_glyph_at :: proc(x, y: i32) -> rune {
	return rune(render_cell_at(x, y).ch)
}

render_glyph_name :: proc(ch: rune) -> string {
	return fmt.tprintf("U+{:04X} '{}'", u32(ch), ch)
}

// render_dump_rows prints a band of the back buffer as plain text.
//
// LOAD-BEARING, DELIBERATELY KEPT. `core:testing` prints one line per FAILURE
// and no grid at all. Without these bands a future reader cannot tell what was
// on screen when a geometry assertion went red, and "re-run it and look" is not
// an option for a suite that runs inside a sandbox with no screen. The frames
// are ASCII; everything inside is what the renderer actually put there.
render_dump_rows :: proc(t: ^testing.T, label: string, x0, y0, w, h: i32) {
	support.note_raw(t, fmt.tprintf("  .{} {}.", render_repeat_str("-", max(2, 62 - len(label))), label))
	buf : [dynamic]u8
	y : i32 = 0
	for y < h {
		clear(&buf)
		x : i32 = 0
		for x < w {
			render_push_str(&buf, fmt.tprintf("{}", render_glyph_at(x0 + x, y0 + y)))
			x += 1
		}
		support.note_raw(t, fmt.tprintf("  |{}|", string(buf[:])))
		y += 1
	}
	support.note_raw(t, fmt.tprintf("  `{}'", render_repeat_str("-", int(w) + 2)))
}

render_push_str :: proc(out: ^[dynamic]u8, s: string) {
	i := 0
	for i < len(s) {
		append(out, s[i])
		i += 1
	}
}

render_repeat_str :: proc(s: string, n: int) -> string {
	buf : [dynamic]u8
	i := 0
	for i < n {
		render_push_str(&buf, s)
		i += 1
	}
	return string(buf[:])
}

// render_paint_cmds pushes an already-computed command stream through the
// renderer and onto the wire.
render_paint_cmds :: proc(cmds: clay.ClayArray(clay.RenderCommand)) -> render.Stats {
	view := render.Renderer{}
	stats := render.render_frame(&view, cmds)
	tb.tb_present()
	return stats
}

// render_and_present lays out `build`, paints it and pushes it out.
render_and_present :: proc(build: proc()) -> render.Stats {
	clay.BeginLayout()
	build()
	return render_paint_cmds(clay.EndLayout(0))
}

render_cmd_text :: proc(cmds: clay.ClayArray(clay.RenderCommand), i: int) -> string {
	t := cmds.internalArray[i].renderData.text
	return string(mem.byte_slice(t.stringContents.chars, int(t.stringContents.length)))
}

// render_find_text_loc returns the index and snapped box of the first TEXT
// command whose contents equal `want`. Tests assert against *Clay's* own
// geometry rather than hand-computed rows, so a Clay that lays out differently
// fails loudly instead of silently retargeting the assertion.
render_find_text_loc :: proc(cmds: clay.ClayArray(clay.RenderCommand), want: string) -> (int, render.Rect) {
	i := 0
	for i < int(cmds.length) {
		c := cmds.internalArray[i]
		if c.commandType == .Text && render_cmd_text(cmds, i) == want {
			return i, render.snap_box(c.boundingBox)
		}
		i += 1
	}
	return -1, render.Rect{}
}

//-----------------------------------------------------------------------------
// Wire-level assertion
//-----------------------------------------------------------------------------

// wire_count_occ counts non-overlapping occurrences of `needle` in `hay`.
// Hand-rolled because there is no regex here and `strings.contains` cannot
// report HOW MANY times the truecolour SGR landed — the count is the evidence
// that the pattern is structural and not a one-off coincidence.
wire_count_occ :: proc(hay: []u8, needle: string) -> int {
	if len(needle) == 0 { return 0 }
	n := 0
	i := 0
	for i + len(needle) <= len(hay) {
		ok := true
		j := 0
		for j < len(needle) {
			if hay[i+j] != byte(needle[j]) { ok = false; break }
			j += 1
		}
		if ok { n += 1; i += len(needle); continue }
		i += 1
	}
	return n
}

// expect_wire asserts that a byte pattern REACHED THE WIRE.
//
// This is the assertion struct-field checks cannot make. A `clay.Color{255,60,60}`
// sitting in a struct proves the value was stored; it does not prove a truecolour
// SGR left the process. `38;2;255;60;60` in the pty stream does.
expect_wire :: proc(t: ^testing.T, label: string, pattern: string, loc := #caller_location) {
	raw := wire_bytes()
	hits := wire_count_occ(raw, pattern)
	support.check(t, label, hits >= 1,
		fmt.tprintf("pattern '{}' hit {} time(s) in {} wire bytes", pattern, hits, len(raw)), loc=loc)
}

// expect_wire_absent is the negative half: a pattern that must NOT appear.
// An `ESC[38;5;` here would mean termbox fell back to the 8-bit/16-colour
// palette — colours preserved as *something*, truecolour not used end to end.
expect_wire_absent :: proc(t: ^testing.T, label: string, pattern: string, loc := #caller_location) {
	raw := wire_bytes()
	hits := wire_count_occ(raw, pattern)
	support.check(t, label, hits == 0,
		fmt.tprintf("pattern '{}' must not appear; found {} time(s) in {} wire bytes",
			pattern, hits, len(raw)), loc=loc)
}
