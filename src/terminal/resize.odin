package termhandoff

// ============================================================================
// terminal.resize — the resize POLICY (T6.5)
//
// The resize *mechanism* is not this file: termbox2 owns SIGWINCH, its own
// self-pipe, the cellbuf resize and the forced clear. What lives here is the
// two things the app decides for itself, isolated from both Clay and termbox so
// each one can be asserted without a terminal:
//
//   1. WHAT IS TOO SMALL   — `too_small(cols, rows)` and the one message that
//                            replaces the UI when the terminal cannot hold it.
//   2. WHAT COALESCED      — `Coalescer`, the counter that turns "we drained N
//                            resize events into one layout pass" from a claim
//                            into a number a test can read.
//
// # WHY THE THRESHOLD IS 40x10
//
// RCH-1 (no outer border) returned 2 columns and 2 rows to the content, so the
// threshold was re-derived rather than inherited from the bordered layout:
//
//   rows 10  = header 1 + rule/gap 2 + main 4 + rule/gap 2 + footer 1
//              → the main section still has 4 rows, enough for the filter line,
//                the column header and one visible session row.
//   cols 40  = the point where the four table columns (device/timestamp/state/
//              name) can still be laid out with the name column cut to a
//              readable width instead of collapsing to one cell.
//
// Below either number the honest answer is "this screen cannot show you a
// session list", and saying that IS the feature. At exactly 40x10 the normal UI
// renders, so the boundary is `< 40 || < 10`, not `<=`.
//
// # WHY THE NOTICE REPLACES THE FRAME RATHER THAN JOINING IT
//
// `frame_layout` clamps `main_rows` at 0, and a 0-row main section still gets
// painted over by the header rule and the footer — that is precisely the
// garbling this path exists to prevent. So the notice is drawn INSTEAD of the
// spine, through the same Clay -> render.paint path (see `ui.paint_notice`),
// and never alongside it.
//
// # WHY A Coalescer AND NOT A DEBOUNCE TIMER
//
// A debounce timer would delay the FIRST resize, and ISC-13 requires the first
// resize to reach the screen within one frame. So we never defer: we drain
// every resize that has already arrived and paint once. That is coalescing with
// zero added latency, and it is exactly what the loop's "drain, then paint"
// shape already does. The Coalescer's job is to make that shape *auditable* —
// max_run is the longest run of resize events that collapsed into a single
// layout pass, and it is printed in the HS_TUI_TRACE dump.
// ============================================================================

import "core:fmt"

// MIN_COLS / MIN_ROWS are the smallest terminal that can show a session list.
// A terminal narrower than MIN_COLS or shorter than MIN_ROWS is "too small".
MIN_COLS :: 40
MIN_ROWS :: 10

// too_small is the whole gate. True means: do not lay out the spine this frame,
// paint the notice instead.
too_small :: proc(cols, rows: i32) -> bool {
	return cols < MIN_COLS || rows < MIN_ROWS
}

// too_small_message names both numbers the user has to act on: what they have
// and what they need. The current size is included because "too small" without
// a measurement is not actionable when a drag stops mid-way.
too_small_message :: proc(cols, rows: i32) -> string {
	return fmt.tprintf(
		"terminal too small: {}x{} - enlarge to at least {}x{}",
		cols, rows, MIN_COLS, MIN_ROWS)
}

// ── coalescing accounting ────────────────────────────────────────────────

// Coalescer counts what happened between "a SIGWINCH landed" and "the screen
// was repainted", which is the only place coalescing can be observed.
//
// It is deliberately passive: NOTHING in here decides when to paint. The loop
// owns that. What the Coalescer does is record the run lengths so the smoke
// suite can prove a border-drag flood produced ~1 layout pass and not one per
// resize event. A counter that drove the repaint would be a second source of
// truth about frames, and two sources of truth about frames is how you get a
// test that passes while the screen lies.
Coalescer :: struct {
	// resize_events is every TB_EVENT_RESIZE that reached us.
	resize_events: int,
	// passes counts the repaints that were triggered by at least one pending
	// resize event. `passes <= resize_events` always; the gap between them IS
	// the coalescing.
	passes: int,
	// max_run is the longest single run collapsed into one pass. 1 would mean
	// no coalescing at all; a border drag should make it jump.
	max_run: int,
	// run is the resize events seen since the last counted pass.
	run: int,
	// last_cols/last_rows record the size that was actually laid out last, so
	// a test can confirm the notice and the layout agreed on one size.
	last_cols: i32,
	last_rows: i32,
	// too_small_paints counts frames that rendered the notice instead of the
	// spine. Its transitions (0 -> n -> back) are the "recovers when enlarged"
	// proof.
	too_small_paints: int,
	// eintr counts poll() wakes that came back EINTR. They are NOT failures —
	// see the loop's comment — and counting them is what proves the loop kept
	// going instead of erroring out.
	eintr: int,
}

// note_resize records one TB_EVENT_RESIZE arriving.
note_resize :: proc(c: ^Coalescer) {
	c.resize_events += 1
	c.run += 1
}

// note_paint records that a layout pass just ran. If resize events were
// pending, this pass is a coalescing pass and the run ends here.
//
// Returns true when the pass carried at least one resize, so the caller can
// count "frames caused by resize" without re-deriving it.
note_paint :: proc(c: ^Coalescer) -> bool {
	if c.run == 0 { return false }
	c.passes += 1
	if c.run > c.max_run { c.max_run = c.run }
	c.run = 0
	return true
}

// pending is true when resize events have arrived that no paint has consumed
// yet. Nothing in the app branches on this today; it exists so a test can
// assert the invariant "the loop never blocks with pending resizes" without
// reaching into the run counter.
pending :: proc(c: ^Coalescer) -> bool {
	return c.run > 0
}

// record_size stamps the geometry the current frame was laid out for.
record_size :: proc(c: ^Coalescer, cols, rows: i32) {
	c.last_cols = cols
	c.last_rows = rows
}

// too_small_paint records a frame that rendered the notice instead of the
// spine. Two transitions matter to the tests: 0 -> n (we went too small) and
// n -> stopped growing (we recovered when the window was enlarged).
too_small_paint :: proc(c: ^Coalescer) {
	c.too_small_paints += 1
}

// note_eintr records a poll() that came back EINTR. Handled by looping, never
// by failing; the count is the proof.
note_eintr :: proc(c: ^Coalescer) {
	c.eintr += 1
}

// too_small_now reports whether the last recorded size was under the floor.
// A test uses this to confirm the notice and the geometry agreed.
too_small_now :: proc(c: ^Coalescer) -> bool {
	return too_small(c.last_cols, c.last_rows)
}

// summary is the one-line form the trace dump writes.
//
// TRAP: this is an ALL-`%` format string on purpose. Odin's `{}` and `%` verbs
// cannot be mixed in one format string — `{}` consumes positionally and the `%`
// verbs then land in the wrong slots (verified: `{:.1}` renders as
// `%!(NO VERB)` in this very toolchain). One verb family per string, always.
summary :: proc(c: ^Coalescer) -> string {
	ratio := 0.0
	if c.passes > 0 {
		ratio = f64(c.resize_events) / f64(c.passes)
	}
	return fmt.tprintf(
		"resizes=%d passes=%d max_run=%d ratio=%.1f too_small_paints=%d eintr=%d",
		c.resize_events, c.passes, c.max_run, ratio, c.too_small_paints, c.eintr)
}
