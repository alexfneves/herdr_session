package unit

// ============================================================================
// caret_cursor_test.odin — the WIRE half of the caret, post-UIP-5 (RCH-10
// change 4, then the app-driven blink refinement).
//
// WHAT THIS FILE NOW PROVES
//
//   * the hardware cursor is HIDDEN (ESC[?25l) while a caret is on screen, and
//     no blink is delegated to the terminal any more (DECSCUSR / underline
//     style sequences never leave the process);
//   * the caret's glyph is still PAINTED in the frame — the app-driven blink
//     swaps COLOURS (the two pairs), never content, so the glyph cannot vanish
//     for half of every blink;
//   * the pair swap: phase ON -> the caret cell is the highlighted pair
//     (caret_fg on caret_bg); phase OFF -> the normal pair (fg on bg);
//   * all ten themes paint the highlighted pair and swap to the normal pair;
//   * the blink wait is finite while a caret owns the editor and -1 when it
//     does not;
//   * a keystroke resets the blink phase to ON.
//
// WHY THE HARDWARE CURSOR IS NOT THE CARET ANY MORE
//
// The caret used to be a terminal cursor (DECSCUSR `ESC[3 q` through tb_send).
// The UIP-5 refinement moved the blink into the app: the Edit owns the phase and
// the loop owns the wake-up, and the caret element paints through the two pairs.
// The real terminal cursor is therefore hidden for editable fields and never
// positioned — there is no positioning to keep in step and no blink to ask for.
// The only wire-level evidence left is "hide went out, no blink style went out".
//
// NOT ASSERTED (eyeball-only, recorded as a limitation): that the swap actually
// VISUALLY blinks (it is driven by the loop's poll deadline now, so timing is the
// loop's business, not this suite's) and perceived contrast. The phase arithmetic
// IS machine-testable here; the human eye is not.
// ============================================================================

import "core:fmt"
import "core:testing"
import "core:time"

import ui "../../src/ui"
import app "../../src/app"
import tb "../../vendor/termbox2-odin"
import support "../support"

// CARET_HIDE is what tb_hide_cursor emits on the wire: `ESC [ ? 2 5 l` (hide
// cursor). The blink is app-driven, so this is the only cursor-family sequence
// the caret path is allowed to produce.
CARET_HIDE :: "\x1b[?25l"
// DECSCUSR shapes are gone with the terminal-driven blink. `ESC[3 q` is the
// blinking block; `ESC[4 q` is the steady block; both are forbidden now — the
// app either paints the pair (and hides the hardware cursor) or does neither.
CARET_DECSCUSR_BLINK :: "\x1b[3 q"
CARET_DECSCUSR_STEADY :: "\x1b[4 q"

// caret_find is the first index of `needle` in `hay`, or -1.
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

// ── the hardware cursor is hidden; no blink sequence is delegated to the tty ──

@(test)
caret_cursor_hides_the_hardware_cursor_and_paints_the_pair :: proc(t: ^testing.T) {
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

	// THE PAIR: phase ON -> the highlighted pair (caret_fg on caret_bg).
	cell := render_cell_at(x, y)
	support.check(t, "phase ON: the caret cell is the highlighted pair (caret_fg on caret_bg)",
		cell.fg == caret_attr(pal.caret_fg) && cell.bg == caret_attr(pal.caret_bg),
		fmt.tprintf("fg=0x{:08X} want caret_fg=0x{:08X} bg=0x{:08X} want caret_bg=0x{:08X}",
			u32(cell.fg), u32(caret_attr(pal.caret_fg)), u32(cell.bg), u32(caret_attr(pal.caret_bg))))

	// THE SWAP: phase OFF -> the normal pair (bg=background, glyph=text). The
	// glyph is the same block, in the normal colours — content preserved, pair
	// swapped, no terminal inversion, no underline.
	e.blink_on = false
	caret_paint_row(&e, 40, &pal)
	cell_off := render_cell_at(x, y)
	support.check(t, "phase OFF: the caret cell is the normal pair (bg=background, glyph=text)",
		cell_off.fg == caret_attr(pal.fg) && cell_off.bg == caret_attr(pal.bg),
		fmt.tprintf("fg=0x{:08X} want fg=0x{:08X} bg=0x{:08X} want bg=0x{:08X}",
			u32(cell_off.fg), u32(caret_attr(pal.fg)), u32(cell_off.bg), u32(caret_attr(pal.bg))))
	support.check(t, "phase OFF keeps the glyph IN the cell (no blanking, no underline)",
		rune(cell_off.ch) == '█',
		fmt.tprintf("cell glyph={}", render_glyph_name(rune(cell_off.ch))))

	tb.tb_present()
	wire_capture(t, "caret-cursor")

	w := wire_bytes()
	support.check(t, "the hardware cursor is HIDDEN (ESC[?25l) while the caret is on screen",
		wire_count_occ(w, CARET_HIDE) >= 1,
		fmt.tprintf("hide hits={} in {} wire bytes", wire_count_occ(w, CARET_HIDE), len(w)))
	support.check(t, "no DECSCUSR blink sequence (ESC[3 q / ESC[4 q) ever left the process",
		wire_count_occ(w, CARET_DECSCUSR_BLINK) == 0 && wire_count_occ(w, CARET_DECSCUSR_STEADY) == 0,
		fmt.tprintf("DECSCUSR_blink={} DECSCUSR_steady={} in {} wire bytes",
			wire_count_occ(w, CARET_DECSCUSR_BLINK), wire_count_occ(w, CARET_DECSCUSR_STEADY), len(w)))

	// The frame still carries the glyph (phase ON -> highlighted), so the swap
	// has something to swap and the character is never left to the terminal.
	glyph_at := caret_find(w, "\xe2\x96\x88")
	support.check(t, "the caret's glyph is still painted in the frame (the swap keeps content)",
		glyph_at >= 0,
		fmt.tprintf("block glyph at {} in {} wire bytes", glyph_at, len(w)))
}

// ── the caret follows the caret (display columns, never byte offsets) ───────

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

	if !ok1 || !ok2 {
		support.check(t, "both caret positions reported cells", false,
			fmt.tprintf("first ok={} second ok={}", ok1, ok2))
		return
	}
	support.check(t, "the first caret cell's reported cell is its DERIVED column",
		x1 >= 0 && x1 < i32(40), fmt.tprintf("first=({},{})", x1, y1))
	support.check(t, "…and so is the second's, at a DIFFERENT coordinate",
		x2 >= 0 && x2 < i32(40) && (x1 != x2 || y1 != y2),
		fmt.tprintf("first=({},{}) second=({},{})", x1, y1, x2, y2))
	support.check(t, "the cursor moved by the rune's CELL width (2), not its byte length (4)",
		x1 - x2 == 2, fmt.tprintf("x1={} x2={} delta={} (bytes would be 4)", x1, x2, x1-x2))
}

// ── the blink wait: finite while a caret owns the editor, none when it does not ──

@(test)
caret_blink_wait_ms_is_finite_when_armed_and_blocked_when_not :: proc(t: ^testing.T) {
	e: ui.Edit
	ui.edit_init(&e)
	support.check(t, "an editor that never painted holds no caret blink (wait -1)",
		ui.edit_blink_wait_ms(&e) == -1, fmt.tprintf("ms={}", ui.edit_blink_wait_ms(&e)))

	if !render_session(t, "caret-blink-wait") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)
	e2: ui.Edit
	ui.edit_init(&e2)
	ui.edit_paste(&e2, "x")
	caret_paint_row(&e2, 40, &pal)
	ms := ui.edit_blink_wait_ms(&e2)
	support.check(t, "an editor whose caret was painted waits FINITE (until the next blink edge)",
		ms > 0, fmt.tprintf("ms={}", ms))
	support.check(t, "that finite wait is the blink period, not a spin", ms <= 530,
		fmt.tprintf("ms={} (period 530)", ms))
}

// ── exactly the two pairs, all ten themes, character in both phases ──────────

@(test)
caret_cursor_pair_swap_across_all_themes :: proc(t: ^testing.T) {
	if !render_session(t, "caret-cursor-sweep") { return }
	n := app.theme_count()
	support.check(t, "the sweep covers every shipped theme", n > 0, fmt.tprintf("app.theme_count() = {}", n))

	bad := 0
	detail := ""
	for i := 0; i < n; i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		e: ui.Edit
		ui.edit_init(&e)
		ui.edit_paste(&e, "a世") // caret at end -> solid block; left -> ON the CJK rune
		caret_paint_row(&e, 40, &pal)
		x, y, ok := ui.edit_caret_cell(&e)
		if !ok {
			bad += 1
			detail = fmt.tprintf("{}: no caret cell", detail)
			continue
		}
		c := render_cell_at(x, y)
		// Phase ON -> the highlighted pair, for the solid block (end of buffer).
		if c.fg != caret_attr(pal.caret_fg) || c.bg != caret_attr(pal.caret_bg) {
			bad += 1
			detail = fmt.tprintf("{}: phase ON block is not the highlighted pair", detail, th.name)
		}
		// Phase OFF -> the normal pair, for the same block.
		e.blink_on = false
		caret_paint_row(&e, 40, &pal)
		c2 := render_cell_at(x, y)
		if c2.fg != caret_attr(pal.fg) || c2.bg != caret_attr(pal.bg) {
			bad += 1
			detail = fmt.tprintf("{}: phase OFF block is not the normal pair", detail, th.name)
		}

		// Mid-field: the character under the caret is IN BOTH phases, in the pair
		// that phase names. Same two pairs, character preserved.
		ui.edit_left(&e) // end -> ON the 2-cell CJK rune
		caret_paint_row(&e, 40, &pal)
		mx, my, mok := ui.edit_caret_cell(&e)
		if !mok { bad += 1; detail = fmt.tprintf("{}: no mid-field caret cell", detail, th.name); continue }
		mc := render_cell_at(mx, my)
		if rune(mc.ch) != '世' {
			bad += 1
			detail = fmt.tprintf("{}: mid-field char not painted ('{}')", detail, th.name)
		}
		if mc.fg != caret_attr(pal.caret_fg) || mc.bg != caret_attr(pal.caret_bg) {
			bad += 1
			detail = fmt.tprintf("{}: phase ON mid-field is not the highlighted pair", detail, th.name)
		}
		e.blink_on = false
		caret_paint_row(&e, 40, &pal)
		mc2 := render_cell_at(mx, my)
		if rune(mc2.ch) != '世' {
			bad += 1
			detail = fmt.tprintf("{}: phase OFF mid-field lost the character", detail, th.name)
		}
		if mc2.fg != caret_attr(pal.fg) || mc2.bg != caret_attr(pal.bg) {
			bad += 1
			detail = fmt.tprintf("{}: phase OFF mid-field is not the normal pair", detail, th.name)
		}
	}
	support.check(t, "all themes paint the caret block in the highlighted pair, swap to the normal pair",
		bad == 0, fmt.tprintf("{} theme(s) wrong: {}", bad, detail))
}

// ── a keystroke resets the blink phase to ON ─────────────────────────────────

@(test)
caret_typing_resets_the_blink_phase_to_on :: proc(t: ^testing.T) {
	e: ui.Edit
	ui.edit_init(&e)
	ui.edit_blink_reset(&e)
	support.check(t, "the phase starts ON after the reset", e.blink_on, fmt.tprintf("on={}", e.blink_on))

	// Let the armed ON phase run out, then step -> the phase flips to OFF.
	time.sleep(ui.CARET_BLINK_PERIOD)
	flipped := ui.edit_blink_step(&e)
	support.check(t, "the armed phase flips OFF at its deadline", flipped, fmt.tprintf("flipped={}", flipped))
	support.check(t, "the phase is now OFF", !e.blink_on, fmt.tprintf("on={}", e.blink_on))

	// A keystroke inserts at the caret, which MOVES it -> the phase resets to ON.
	ok_ins := ui.edit_insert_rune(&e, 'x')
	support.check(t, "typing at the caret inserts", ok_ins, fmt.tprintf("ok={}", ok_ins))
	support.check(t, "a keystroke resets the blink phase to ON", e.blink_on,
		fmt.tprintf("on={}", e.blink_on))
}
