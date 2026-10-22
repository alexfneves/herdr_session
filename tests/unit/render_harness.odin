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
// THE 43-BYTE LEDGER — an openpty argument-order inversion, measured
// ─────────────────────────────────────────────────────────────────────────────
// This suite's wire test spent a long time capturing EXACTLY 43 bytes — termbox's
// init escapes and nothing else — while the cell-level tests over the same frame
// passed. Every theory pointed at the renderer (frame never presented, drain
// sampled too early, layout given no size). All three were false. The measurement
// that closed it, with strace on a failing run:
//
//   write(3, "\e[?1049h\e[22;0;0t\e[?1h\e=\e[?25l\e(B\e[m\e[H\e[2J", 43) = 43
//   write(3, "\e(B\e[m\e[38;2;255;60;60;48;2;16;20;28m\e[1;1H\342\224\214...", 1657) = 1657   ← the FRAME, painted
//   write(3, "\e[?12l\e[?25h...\e[?1049l...", 81) = 81                            ← termbox's exit codes
//   ioctl(4, FIONREAD, [0]) = 0                                                     ← NONE of it queued
//   close(3) → read(4) = -1 EIO                                                    ← drain ends with 43
//
// The frame WAS painted and DID reach the fd — `write` returned 1657 — and yet
// none of it was ever readable, and the drain sat blocked in read() the whole
// time without waking. Bytes going in one end and not coming out the other means
// the two ends are not the ends anyone thinks they are.
//
// They were swapped. `openpty`'s prototype is
//     int openpty(int *master, int *slave, ...)
// — MASTER FIRST. This file declared it as `(slave, master)`. Same arity, same
// types (`^FD`, `^FD`), so the compiler and the linker both said nothing. The
// result: `pw.slave` held the ptmx MASTER (termbox bound to it) and `pw.master`
// held the real SLAVE (the drain reading it). termbox's output was therefore
// injected into the slave's INPUT line discipline — which is canonical, line-
// buffered, 4 KiB-per-line, and echoing — instead of being read off the master's
// OUTPUT queue. The 43 init bytes squeezed through as one short line; the 1738
// bytes of frame sat behind a canonical read that never completed. That is the
// whole bug: not a race in the capture, and nothing to do with the renderer.
//
// Two consequences for anyone editing this file:
//
//   * An FFI declaration is a comment the compiler cannot check. Two arguments
//     of the same type in the wrong order is invisible here and fatal downstream.
//     Verify the prototype against the header, not against the variable names.
//
//   * The failure was FLAKY (43 / 1700 / 1781 bytes across runs), which made it
//     look like a timing bug. Line-discipline buffering can look like timing
//     through a pipe. Count the bytes, name them, and check what the queue says
//     at the moment of loss (`HS_WIRE_DUMP=1` prints the whole stream escaped).
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

// CLAY_CAPACITY is the size of the ONE static arena every Clay session in this
// process shares. Measured `clay.MinMemorySize()` = 5,785,280 bytes on this
// pin, so 8 MiB is ~2.4x the requirement; going over is a counted failure in
// render_clay_start rather than a silent overflow.
//
// Static and never freed, on purpose — see render_clay_down.
CLAY_CAPACITY :: 8 * 1024 * 1024

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
	// openpty(master, slave, name, termios, winsize). NULL name/termios is the
	// usual call: unnamed pty, default line discipline, size from winsize.
	//
	// THE ORDER OF THE FIRST TWO ARGUMENTS IS THE WHOLE CONTRACT, and it is not
	// what a reader might assume. glibc's prototype (pty.h, verified in the
	// 2.42-84 dev package this build links) is
	//     int openpty(int *master, int *slave, char *name,
	//               const struct termios *termios, const struct winsize *winp);
	// MASTER FIRST, slave second. This declaration previously read
	// (slave, master) — same arity, same types, compiles and links without a
	// murmur — and every fd downstream was inverted: termbox bound to the ptmx
	// MASTER and the capture drained the SLAVE. That inversion is the root
	// cause of the 43-byte wire recorded in this file's ledger; see the note in
	// wire_capture for the measurement.
	openpty :: proc(master: ^posix.FD, slave: ^posix.FD, name: rawptr, t: rawptr, ws: ^Win_Size) -> c.int ---
	// ioctl(fd, FIONREAD, &n) — bytes sitting in the pty queue, unread.
	// Named hs_ioctl_ because `ioctl` is already declared foreign by src/ui_cases.odin.
	@(link_name="ioctl")
	hs_ioctl_ :: proc(fd: c.int, request: c.ulong, arg: ^c.int) -> c.int ---
}

FIONREAD :: 0x541B  // TIOCINQ on Linux: bytes queued for the next read

// WIRE_CAPACITY caps the captured stream, and the reason it is a FIXED static
// buffer rather than a [dynamic]u8 is a use-after-free that was measured here.
//
// A thread's Odin context is inherited from whoever created it
// (`thread.init_context`), which in a test binary is THAT TEST'S leak-tracking
// allocator. So a drain thread appending into a `[dynamic]u8` writes through a
// test allocator that core:testing RECLAIMS when the test ends, while the
// buffer's backing block lives on in a process-global struct. The next render
// test starts a fresh drain against that stale block and segfaults inside the
// append — observed as a SIGSEGV attributed to whichever test happened to be
// running, in a file that contains no pointer arithmetic at all.
//
// A fixed static buffer means the drain allocates NOTHING, so the whole
// allocator-lifetime question cannot arise. 4 MiB is ~40x the largest stream
// this suite emits; going over is COUNTED in `lost` and said out loud in the
// capture note rather than silently truncating the evidence.
WIRE_CAPACITY :: 4 * 1024 * 1024

Pty_Wire :: struct {
	master    : posix.FD, // read end: the bytes termbox emitted come back here
	slave     : posix.FD, // termbox's rfd AND wfd; a real tty
	drain     : ^thread.Thread,
	started   : bool,     // set once the drain thread is parked in read()
	wire_buf  : [WIRE_CAPACITY]u8, // allocation-free capture target
	wire_len  : int,      // bytes captured (drain writes, test reads)
	wire_lost : int,      // bytes dropped for capacity — never silently
	captured  : bool,     // drain joined; the capture is final
	tb_live   : bool,     // termbox needs shutdown before the slave goes away
	up        : bool,
}

// STATIC and single-occupied under RENDER_TERM_LOCK. A heap-allocated pty
// handle handed to a cleanup outlives the test allocator that made it — the
// exact class of segfault the ledger documents for its own table.
pw : Pty_Wire = {}

// drain_proc reads the master until the slave is gone. It performs NO
// allocation, formats NOTHING and touches no Odin runtime facility that needs
// a live test allocator, because it can still be inside read() when the test
// that spawned it ends. See WIRE_CAPACITY.
drain_proc :: proc(th: ^thread.Thread) {
	w := cast(^Pty_Wire)(th.data)
	tmp : [16384]u8
	sync.atomic_store(&w.started, true)
	for {
		n := posix.read(w.master, &tmp[0], c.size_t(len(tmp)))
		if n <= 0 { break } // EIO once the last slave fd closes
		taken := int(n)
		off := sync.atomic_load(&w.wire_len)
		room := WIRE_CAPACITY - off
		if room <= 0 {
			sync.atomic_add(&w.wire_lost, taken)
			continue
		}
		if taken > room {
			sync.atomic_add(&w.wire_lost, taken - room)
			taken = room
		}
		for i := 0; i < taken; i += 1 {
			w.wire_buf[off+i] = tmp[i]
		}
		sync.atomic_store(&w.wire_len, off+taken)
	}
}

// wire_lock takes the whole-terminal mutex for the calling test and registers
// its release as a core:testing cleanup, so a faulting test cannot strand the
// lock (which would hang the next render test rather than fail it).
//
// Registered FIRST, therefore run LAST (cleanups are LIFO): anything a test
// registers after this still runs while the lock is held, which is what we want
// — no other test can be inside termbox meanwhile.
wire_lock :: proc(t: ^testing.T, loc := #caller_location) {
	sync.mutex_lock(&RENDER_TERM_LOCK)
	testing.cleanup(t, wire_unlock_cb, nil)
	_ = loc
}

// wire_unlock_cb releases the resources AND the lock, in that order.
//
// Both halves are mandatory. Releasing the lock without the teardown leaks a
// live termbox into the next test's fresh one; releasing the teardown without
// the lock is WORSE and was measured here — the first render test finished
// cleanly, and the NEXT one blocked forever inside `wire_lock` before even
// reaching openpty, turning the suite into a 5-minute hang with no failure
// line. A cleanup whose name promises an unlock has to perform the unlock.
wire_unlock_cb :: proc(_: rawptr) {
	wire_teardown()
	sync.mutex_unlock(&RENDER_TERM_LOCK)
}

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
	// Reset the capture window rather than free it: the buffer is static, so
	// there is nothing to free and no allocator lifetime to get wrong.
	sync.atomic_store(&pw.wire_len, 0)
	sync.atomic_store(&pw.wire_lost, 0)
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
	rc := openpty(&master, &slave, nil, nil, &ws)   // master FIRST — see the foreign block
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
	sync.atomic_store(&pw.wire_len, 0)
	sync.atomic_store(&pw.wire_lost, 0)
	// Reset the drain's "I am parked in read()" flag BEFORE starting it. The
	// handle is a process global reused across tests; a stale true from the
	// previous drain would let the spin below pass before this thread had even
	// reached its read, reopening exactly the lost-bytes window it exists to close.
	sync.atomic_store(&pw.started, false)

	pw.drain = thread.create(drain_proc, .Normal, "hs-render-wire-drain")
	pw.drain.data = &pw
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
// the capture too), wait for the drain to have taken every queued byte, drop
// the slave so the drain sees EIO, and join it. After this `wire_bytes()` is
// final. Idempotent.
//
// THE WAIT IS NOT OPTIONAL. Closing the last slave fd hangs up the pair, and
// whatever the kernel still holds in the pty queue at that moment is discarded,
// not delivered. termbox flushes synchronously, so in the common case there is
// nothing left to wait for — but "in the common case" is precisely how a
// capture ends up silently short by a frame while still looking like a stream.
// Draining to FIONREAD == 0 first makes loss impossible rather than unlikely.
wire_capture :: proc(t: ^testing.T, label: string, loc := #caller_location) {
	if !pw.up || pw.captured { return }
	if pw.tb_live {
		tb.tb_shutdown()
		pw.tb_live = false
	}

	// Spin until the master has nothing queued for the drain. Bounded, so a
	// wedged drain fails the capture instead of hanging the suite.
	pending : c.int = -1
	Drained : for _ in 0 ..< 200_000 {
		hs_ioctl_(c.int(pw.master), c.ulong(FIONREAD), &pending)
		if pending <= 0 { break Drained }
		thread.yield()
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
	support.note(t, fmt.tprintf("{} wire captured: {} bytes (capacity {}, dropped {})",
		label, sync.atomic_load(&pw.wire_len), WIRE_CAPACITY, sync.atomic_load(&pw.wire_lost)))
	if pending > 0 {
		support.note(t, fmt.tprintf("{} CAPTURE TRUNCATED: {} byte(s) still queued in the pty when the slave was dropped — the wire asserts below see a PARTIAL stream",
			label, int(pending)))
	}
	if sync.atomic_load(&pw.wire_lost) > 0 {
		support.note(t, fmt.tprintf("{} CAPTURE TRUNCATED: {} byte(s) exceeded WIRE_CAPACITY — the wire asserts below see a PARTIAL stream",
			label, sync.atomic_load(&pw.wire_lost)))
	}
	// HS_WIRE_DUMP=1 prints the captured stream with every escape spelled out.
	// Kept on purpose: "what actually left the process" is the one thing about
	// this harness that cannot be read off any struct, and being able to name
	// every byte is what turned the 43-byte bug below from a guess into a fact.
	if posix.getenv("HS_WIRE_DUMP") != nil {
		support.note_raw(t, fmt.tprintf("  WIRE-DUMP >>>{}<<<", render_escape(wire_bytes())))
	}
}

// wire_bytes is the captured stream as a read-only view. Only meaningful after
// wire_capture (or after teardown has joined the drain); before that the
// length is whatever the drain has written so far.
wire_bytes :: proc() -> []u8 {
	return pw.wire_buf[0:sync.atomic_load(&pw.wire_len)]
}

// render_escape renders bytes with escapes visible (debug aid for HS_WIRE_DUMP).
render_escape :: proc(b: []u8) -> string {
	buf : [dynamic]u8
	for c in b {
		if c == 0x1b {
			render_push_str(&buf, `\e`)
		} else if c >= 0x20 && c < 0x7f {
			append(&buf, byte(c))
		} else {
			render_push_str(&buf, fmt.tprintf("<{:02x}>", c))
		}
	}
	return string(buf[:])
}

//-----------------------------------------------------------------------------
// Clay session
//-----------------------------------------------------------------------------

// The one Clay arena. STATIC, sliced to the size Clay asked for, never freed.
clay_arena_mem : []u8 = nil
clay_arena_static : [CLAY_CAPACITY]u8 = {}

// render_clay_start brings up a Clay context wired to our measure function and
// our error handler, sized from Clay's own MinMemorySize rather than a guessed
// magic number. Callers hold RENDER_TERM_LOCK.
//
// Re-Initialising over the SAME arena on every test is what makes more than one
// Clay session possible in one process: the caller owns the arena's memory, and
// Clay rebuilds its context inside it.
render_clay_start :: proc(t: ^testing.T, label: string) -> bool {
	need := int(clay.MinMemorySize()) + CLAY_PAD
	if need > CLAY_CAPACITY {
		support.check(t, fmt.tprintf("{}: the Clay arena fits Clay's own reported minimum", label), false,
			fmt.tprintf("Clay reports MinMemorySize+pad = {} bytes, CLAY_CAPACITY is {} — raise CLAY_CAPACITY; do not shrink the arena and hope",
				need, CLAY_CAPACITY))
		return false
	}
	if len(clay_arena_mem) != need {
		clay_arena_mem = clay_arena_static[0:need]
	}
	arena := clay.CreateArenaWithCapacityAndMemory(c.size_t(len(clay_arena_mem)), raw_data(clay_arena_mem))
	ctx := clay.Initialize(arena, clay.Dimensions{width = RENDER_COLS, height = RENDER_ROWS},
		render.errors_handler_for())
	if ctx == nil {
		support.check(t, fmt.tprintf("{}: Clay context acquired", label), false,
			"clay.Initialize returned nil — no layout can be built, so nothing downstream is observable")
		return false
	}
	clay.SetMeasureTextFunction(render.measure_text, nil)
	return true
}

// render_clay_down releases the CLAY session, and pointedly NOT the arena.
//
// This was a `delete(render_clay_buf)` and it was wrong for a second render
// test in the same process. Clay keeps a THREAD-GLOBAL pointer to its context
// inside that arena and there is no Clay binding that clears it. Free the arena
// and the pointer dangles over memory the allocator hands back to the OS; the
// next Clay call then faults for it. Measured, on the second test in this
// binary:
//
//	SIGSEGV: address not mapped (fault address=0x7ffff5a66080)
//	frame #0: Clay_MinMemorySize + 98   ->  mov (%rax),%rax   ; rax = stale context
//
// — a crash three calls later, in a different file, from a free that looked
// perfectly hygienic. The arena is static, so nothing is freed, nothing
// dangles, and no per-test allocator is ever asked to own memory that outlives
// it.
render_clay_down :: proc() {
	clay_arena_mem = nil
}

// render_session brings up BOTH halves of a render test's world in one call:
// the pty-with-termbox AND Clay. They always travel together — a Clay with no
// terminal has nowhere to paint, a terminal with no Clay has nothing to paint
// — so acquiring them separately only creates a way to end up with half a
// session and assert against nothing. Returns false (with a counted failure
// behind it) rather than half-acquiring, so a test that cannot observe anything
// fails loudly instead of passing on an empty buffer.
render_session :: proc(t: ^testing.T, label: string, loc := #caller_location) -> bool {
	if !wire_open(t, label, loc=loc) { return false }
	if !render_clay_start(t, label) { return false }
	return true
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
//
// The FFI shape here is worth reading twice, because getting it wrong does not
// fail to compile — it writes through a nil pointer and segfaults inside C:
//
//	C:    int tb_get_cell(int x, int y, int back, struct tb_cell **cell);
//	Odin: tb_get_cell :: proc(x, y: i32, back: i32, cell: ^^Cell) -> i32
//
// `cell` is an OUT parameter of type `tb_cell**`. The caller owns a `^Cell`
// (one level) and passes its ADDRESS (`&ptr`, the second level). Declaring the
// local as `^^Cell` and passing it directly type-checks against `^^Cell` — and
// then the callee stores a cell pointer at address 0, because the local is nil.
// Measured: SIGSEGV on the first `render_cell_at` call, nowhere near the FFI
// declaration that caused it. This mirrors the pre-migration driver exactly
// (`Cell`/`cell_at` at src/render_cases.odin:152-171).
render_cell_at :: proc(x, y: i32) -> Render_Back_Cell {
	out := Render_Back_Cell{}
	ptr : ^tb.Cell = nil
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
