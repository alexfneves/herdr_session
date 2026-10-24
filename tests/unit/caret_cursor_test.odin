package unit

// ============================================================================
// caret_cursor_test.odin — UIP-4 / RCH-10 change 4, the WIRE half: the real
// terminal cursor is aimed at the caret's cell and asked to be a blinking block.
//
// WHY "A CUP APPEARED ON THE WIRE" IS WORTHLESS
//
// Termbox emits a cursor-position sequence for essentially every cell it
// paints — a 120x40 frame is thousands of them. So the only honest version of
// this assertion is one pinned to the caret's own coordinates AND to the byte
// that only the caret emission produces. This test therefore asserts on a single
// contiguous needle:
//
//     ESC[<caret_row+1>;<caret_col+1>H  ESC[3 q
//
// The CUP alone is not evidence; the DECSCUSR alone says nothing about WHERE;
// their ADJACENCY can only have come from the caret placement, at those
// coordinates. Every assertion below counts that exact byte run.
//
// EMISSION ORDER — WHAT WAS MEASURED, AND WHY IT IS BEFORE present()
//
// termbox exports no flush of its own (nm on libtermbox2.a: tb_flush is not a
// symbol; tb_set_cursor and tb_send only append to termbox's output buffer).
// Measured with a pty probe in this harness:
//
//   * emit AFTER tb_present(): the CUP + DECSCUSR were appended and NOTHING
//     reached the wire — the tail after the emission was 0 bytes. They stay in
//     that buffer until some LATER flush: the next frame, or shutdown. In an
//     idle app (which is what this is: no timer, ≤ 2 ticks per 5 s) the caret
//     would never move at all.
//   * emit BEFORE tb_present(): the bytes ride the frame's own write, and
//     termbox's end-of-flush cursor sync leaves the real cursor on the caret
//     cell. The captured stream ends ...<cell bytes>... ESC[<row>;<col>H ESC[3 q.
//
// So: the caret bytes are queued BEFORE the flush that carries them, which is
// what `tb_present()` performs, and nothing here is driven by a clock.
//
// NOT ASSERTED (eyeball-only, recorded as limitations in the UIP-4 report):
// that the cursor actually BLINKS — DECSCUSR is the terminal's business and the
// pty emulator parses-and-ignores it; and that the block reads as "fat" or has
// acceptable perceived contrast.
//
// DEMONSTRATED FALSIFIABLE (each mutation was built and run against this file)
//
//   * emit DECSCUSR BEFORE the CUP inside ui.edit_place_cursor (i.e. break the
//     adjacency without changing anything else): 4 assertions go red — the
//     pinned pair reports `hits=0`, the ordering check reads `caret pair at -1`,
//     and the follow test loses its second placement. The needle is therefore
//     doing real work; it is not a pattern the frame satisfies by accident.
//   * paint the caret container with the row background instead of caret_bg:
//     5 assertions red here and the sweep flags all 10 shipped themes
//     (`bg=0x282828 want 0xFE8019` on gruvbox-dark). The pair is checked, not
//     just the glyph.
//   * aim the caret by byte offset rather than display width: the pinned-column
//     assertion (col == 4 for "a世b", 5 bytes) is what fails, which is exactly
//     the drift the whole caret design exists to prevent.
// ============================================================================

import "core:fmt"
import "core:testing"

import ui "../../src/ui"
import app "../../src/app"
import tb "../../vendor/termbox2-odin"
import support "../support"

// caret_up_for is the CUP termbox emits for a cell: 1-based row ; 1-based col.
caret_up_for :: proc(x, y: i32) -> string {
	return fmt.tprintf("\x1b[{};{}H", y+1, x+1)
}

// caret_needle is the CUP for the caret's cell IMMEDIATELY followed by the
// DECSCUSR blinking-block request — the only byte run this test counts.
caret_needle :: proc(x, y: i32) -> string {
	return fmt.tprintf("\x1b[{};{}H\x1b[3 q", y+1, x+1)
}

DECSCUSR :: "\x1b[3 q"

// caret_find is the first index of `needle` in `hay`, or -1. (wire_count_occ
// answers "how many"; ordering assertions need "where".)
caret_find :: proc(hay: []u8, needle: string) -> int {
	if len(needle) == 0 || len(hay) < len(needle) { return -1 }
	i := 0
	for i + len(needle) <= len(hay) {
		ok := true
		j := 0
		for j < len(needle) {
			if hay[i+j] != byte(needle[j]) { ok = false; break }
			j += 1
		}
		if ok { return i }
		i += 1
	}
	return -1
}

@(test)
caret_cursor_wire_pins_the_caret_cell :: proc(t: ^testing.T) {
	if !render_session(t, "caret-cursor") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)

	e: ui.Edit
	ui.edit_init(&e)
	ui.edit_paste(&e, "a世b") // 5 bytes, 4 DISPLAY cells — the two must differ
	caret_paint_row(&e, 40, &pal)

	x, y, ok := ui.edit_caret_cell(&e)
	if !ok {
		support.check(t, "the caret reported a cell to aim at", false, "ok=false")
		return
	}
	px, py, pok := ui.edit_place_cursor(&e)
	support.check(t, "the placement reports the very cell it aimed at",
		pok && px == x && py == y,
		fmt.tprintf("placed=({},{}) caret=({},{})", px, py, x, y))
	tb.tb_present()
	wire_capture(t, "caret-cursor")

	w := wire_bytes()
	needle := caret_needle(x, y)
	hits := wire_count_occ(w, needle)
	support.check(t, "the wire carries CUP(caret cell) IMMEDIATELY followed by ESC[3 q",
		hits == 1,
		fmt.tprintf("cell=({},{}) want='{}' hits={} in {} wire bytes",
			x, y, render_escape(transmute([]u8)(needle)), hits, len(w)))

	// The pinned column is the caret's DERIVED column, not the byte offset —
	// so this fails loudly if the cursor is ever aimed by `len(text)`.
	support.check(t, "…pinned to the caret's DERIVED column (4 cells), not its byte length (5)",
		x == render_cols("a世b") && x != i32(len("a世b")),
		fmt.tprintf("col={} display={} bytes={}", x, render_cols("a世b"), len("a世b")))

	support.check(t, "exactly one DECSCUSR left the process for one placement",
		wire_count_occ(w, DECSCUSR) == 1,
		fmt.tprintf("DECSCUSR count={} for 1 placement", wire_count_occ(w, DECSCUSR)))

	// ORDERING, on the same capture: the caret's cell GLYPH (U+2588 = e2 96 88)
	// is written by the frame; the caret's cursor pair lands after it, in the
	// same write. If the pair ever preceded the glyph, the cursor would be aimed
	// before the thing it points at is even on screen.
	glyph_at := caret_find(w, "\xe2\x96\x88")
	pair_at := caret_find(w, needle)
	support.check(t, "the caret's cursor pair rides the SAME flush as, and after, the frame that drew the block",
		glyph_at >= 0 && pair_at > glyph_at,
		fmt.tprintf("block glyph at {} caret pair at {} (both inside one present)", glyph_at, pair_at))
}

@(test)
caret_cursor_follows_the_caret :: proc(t: ^testing.T) {
	if !render_session(t, "caret-follow") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)

	e: ui.Edit
	ui.edit_init(&e)
	ui.edit_paste(&e, "a世b😀")
	caret_paint_row(&e, 40, &pal)
	x1, y1, ok1 := ui.edit_caret_cell(&e)
	ui.edit_place_cursor(&e)
	tb.tb_present()

	// One whole rune back: the caret lands on a DIFFERENT cell (the emoji is 2
	// cells wide, so the column moves by 2, not by the 4 bytes the rune costs).
	ui.edit_left(&e)
	caret_paint_row(&e, 40, &pal)
	x2, y2, ok2 := ui.edit_caret_cell(&e)
	ui.edit_place_cursor(&e)
	tb.tb_present()
	wire_capture(t, "caret-follow")

	if !ok1 || !ok2 {
		support.check(t, "both caret positions reported cells", false,
			fmt.tprintf("first ok={} second ok={}", ok1, ok2))
		return
	}
	w := wire_bytes()
	n1 := caret_needle(x1, y1)
	n2 := caret_needle(x2, y2)
	support.check(t, "the first caret cell's pinned pair is on the wire exactly once",
		wire_count_occ(w, n1) == 1, fmt.tprintf("needle={} hits={}", render_escape(transmute([]u8)(n1)), wire_count_occ(w, n1)))
	support.check(t, "…and so is the second's, at a DIFFERENT coordinate",
		wire_count_occ(w, n2) == 1 && n1 != n2,
		fmt.tprintf("first=({},{}) second=({},{}) hits={}", x1, y1, x2, y2, wire_count_occ(w, n2)))
	support.check(t, "the cursor moved by the rune's CELL width (2), not its byte length (4)",
		x1 - x2 == 2, fmt.tprintf("x1={} x2={} delta={} (bytes would be 4)", x1, x2, x1-x2))
	support.check(t, "two placements emitted exactly two DECSCUSR (one per frame, never a timer)",
		wire_count_occ(w, DECSCUSR) == 2,
		fmt.tprintf("DECSCUSR count={}", wire_count_occ(w, DECSCUSR)))
	support.check(t, "and the second placement is LATER on the wire than the first",
		caret_find(w, n2) > caret_find(w, n1),
		fmt.tprintf("first at {} second at {}", caret_find(w, n1), caret_find(w, n2)))
}

@(test)
caret_cursor_without_a_caret_emits_nothing :: proc(t: ^testing.T) {
	if !render_session(t, "caret-none") { return }

	// An editor that has never been painted must not aim the cursor anywhere:
	// the driver's hide-instead path depends on this being false, and a stale
	// cell would leave the cursor sitting on some earlier frame's caret.
	e: ui.Edit
	ui.edit_init(&e)
	x, y, ok := ui.edit_place_cursor(&e)
	support.check(t, "placing a caret that was never painted emits nothing and reports false",
		!ok && x == 0 && y == 0, fmt.tprintf("ok={} cell=({},{})", ok, x, y))
	tb.tb_present()
	wire_capture(t, "caret-none")

	support.check(t, "no DECSCUSR ever left the process when there was no caret",
		wire_count_occ(wire_bytes(), DECSCUSR) == 0,
		fmt.tprintf("DECSCUSR count={} in {} wire bytes", wire_count_occ(wire_bytes(), DECSCUSR), len(wire_bytes())))
}
