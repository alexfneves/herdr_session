package unit

// ============================================================================
// caret_machine_test.odin — UIP-4 / RCH-10 change 4: the MACHINE owns the
// caret, and the arrow keys drive it in both editable fields.
//
// WHY THIS IS TESTED IN THE MACHINE AND NOT IN THE VIEW
//
// `app.update` is the only door the UI is allowed to push keys through. If the
// caret lived in the view, a key press would move something the machine had
// never heard of, and the one-way sync (machine -> view) would snap it back on
// the next frame. So the caret is `Text.caret`, and this file proves it moves
// for `case .left:` / `case .right:` in BOTH `consume_edit_key` (the name
// field) and `filter_navigate` (every filter state) — the two procs that own
// the two fields. Testing one of them would leave the other free to regress.
//
// WHAT EACH ASSERTION COULD FAIL ON (D-E)
//
//   * arrow keys wired to the wrong field — a `.left` that moved `field` while
//     the user was in a filter state is caught by asserting on the FILTER's
//     caret here, and vice versa.
//   * caret steps a byte instead of a rune — caught by stepping over CJK (3
//     bytes) and an astral emoji (4 bytes) and asserting the caret lands on the
//     BYTE LENGTH of the prefix left behind, not `len-1`.
//   * an arrow key rebuilding the filtered list — a `.left` that called
//     `rebuild_shown` would move the caret AND drag the selection; the
//     selection-unchanged assertion goes red for that, and only for that.
//   * end-of-line behaviour — an unclamped mover would run the caret off the
//     buffer (negative or past `len`), which is exactly what the two end-of-line
//     checks pin down.
//   * the caret leaking into the VALUE — a caret that became part of the name
//     would change the launch command; the Enter check proves the value is the
//     text with the caret parked mid-field, and nothing more.
//
// WHY NO TERMINAL IS NEEDED
//
// This is state, not pixels: `app.update` takes a decoded `input.Key` and
// returns a `Command`. Nothing here touches termbox or Clay, so the suite runs
// with no pty and no render lock (see tests/unit/state_harness.odin for why a
// /dev/tty-based harness cannot work in this sandbox).
//
// DEMONSTRATED FALSIFIABLE: `text_caret_left` was mutated to step ONE BYTE
// instead of one whole rune and this file was rebuilt and re-run — 9 assertions
// went red, starting at the first step over the astral rune
// (`Left step 2 lands on the rune boundary at byte 5 — caret=8 want=5`). The
// byte-vs-rune distinction these tests pin down is load-bearing, not decorative.
// ============================================================================

import "core:fmt"
import "core:testing"

import app "../../src/app"
import input "../../src/input"
import support "../support"

// Arrow keys arrive already decoded (KEY_ARROW_LEFT -> .left, per
// src/input/keymap.odin:100-101); nothing new is plumbed for this feature.
cm_left  :: input.Key{kind = .left}
cm_right :: input.Key{kind = .right}
cm_bs    :: input.Key{kind = .backspace}

// The mixed-width probe string every caret test walks: ASCII (1 cell), CJK (2
// cells / 3 bytes) and an astral emoji (2 cells / 4 bytes).
CM_PROBE :: "a世b😀c"

cm_new :: proc(s: app.State) -> app.App {
	a := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&a, st_prefix_for(s))
	return a
}

cm_drive_keys :: proc(a: ^app.App, s: string) {
	for r in s {
		app.update(a, st_kc(r))
	}
}

// cm_caret_is asserts the caret sits at a specific BYTE index and that the text
// was not disturbed on the way there.
cm_caret_is :: proc(t: ^testing.T, what: string, fld: ^app.Text, want_bytes: int) {
	support.check(t, what, fld.caret == want_bytes && fld.caret >= 0 && fld.caret <= fld.len,
		fmt.tprintf("caret={} len={} text='{}' want caret={}", fld.caret, fld.len, app.text_of(fld), want_bytes))
}

// ── the NAME field ─────────────────────────────────────────────────────────

@(test)
caret_machine_name_field_arrow_keys :: proc(t: ^testing.T) {
	a := cm_new(.name_local)
	support.check(t, "the fixture reaches {Name local} through a key", a.state == .name_local,
		fmt.tprintf("state={}", app.state_label(a.state)))

	cm_drive_keys(&a, "ab")
	cm_caret_is(t, "typing 'ab' parks the caret at the end (2 bytes)", &a.field, 2)

	// LEFT one whole rune: caret sits between 'a' and 'b'.
	app.update(&a, cm_left)
	cm_caret_is(t, "Left moves the caret one rune left (mid-field)", &a.field, 1)

	// The caret DRIVES insertion: typing lands where the caret is, not at the end.
	app.update(&a, st_kc('X'))
	support.check(t, "typing at a parked caret inserts AT the caret",
		app.text_of(&a.field) == "aXb" && a.field.caret == 2,
		fmt.tprintf("text='{}' caret={}", app.text_of(&a.field), a.field.caret))

	// LEFT to the very front, then LEFT again: blocked, not negative.
	app.update(&a, cm_left)
	app.update(&a, cm_left)
	cm_caret_is(t, "Left walks to the front of the field", &a.field, 0)
	app.update(&a, cm_left)
	cm_caret_is(t, "Left at the front is a NO-OP (caret never goes negative)", &a.field, 0)

	// RIGHT back to the end, then RIGHT again: blocked, never past len.
	for i := 0; i < 3; i += 1 { app.update(&a, cm_right) }
	cm_caret_is(t, "Right walks to the end of the field", &a.field, 3)
	app.update(&a, cm_right)
	cm_caret_is(t, "Right at the end is a NO-OP (caret never passes len)", &a.field, 3)

	// Whole-rune BACKSPACE with the caret parked MID-FIELD: the rune before the
	// caret goes and the text after it survives — which is exactly what a
	// "trim the last byte" backspace could not do.
	app.update(&a, cm_left) // caret before the 'b'
	app.update(&a, cm_bs)
	support.check(t, "Backspace deletes the rune BEFORE the caret, not the end of the line",
		app.text_of(&a.field) == "ab" && a.field.caret == 1,
		fmt.tprintf("text='{}' caret={}", app.text_of(&a.field), a.field.caret))
}

@(test)
caret_machine_name_value_ignores_the_caret :: proc(t: ^testing.T) {
	a := cm_new(.name_local)
	// Typed as "as", then the caret steps left one rune, then "pi" is typed.
	// The field must read "apis": the characters went WHERE THE CARET WAS, and
	// the value is the text and nothing else.
	cm_drive_keys(&a, "as")
	app.update(&a, cm_left)
	cm_drive_keys(&a, "pi")
	support.check(t, "the field reads 'apis' with the caret parked mid-field",
		app.text_of(&a.field) == "apis", fmt.tprintf("text='{}' caret={}", app.text_of(&a.field), a.field.caret))

	cmd := app.update(&a, st_enter)
	support.check(t, "Enter carries the TEXT as the name prefix — the caret is not part of the value",
		cmd.kind == .launch_local && len(cmd.name) >= 4 && cmd.name[0:4] == "apis",
		fmt.tprintf("kind={} name='{}'", app.cmd_kind_label(cmd.kind), cmd.name))
}

@(test)
caret_machine_arrow_keys_in_the_filter :: proc(t: ^testing.T) {
	a := cm_new(.attach)
	support.check(t, "the fixture reaches {Attach} through a key", a.state == .attach,
		fmt.tprintf("state={}", app.state_label(a.state)))
	support.check(t, "and {Attach} really does expose an editable filter",
		app.state_filter_is_editable(a.state), fmt.tprintf("editable={}", app.state_filter_is_editable(a.state)))

	cm_drive_keys(&a, CM_PROBE)
	support.check(t, "the whole mixed-width string landed in the filter",
		app.text_of(&a.filter) == CM_PROBE, fmt.tprintf("filter='{}'", app.text_of(&a.filter)))

	// Selection and shown-list snapshot BEFORE any arrow key.
	sel_before := a.sel
	shown_before := len(a.shown)

	// Step LEFT across every rune. Each step must land on the BYTE LENGTH of the
	// prefix left behind — never `len-1`, which is what a byte-stepping caret
	// would produce across a 3-byte CJK rune and a 4-byte emoji.
	// The exact byte positions the caret must pass through, computed from the
	// fixture's own rune lengths rather than assumed: start at the end and
	// subtract the byte length of each rune walked over.
	want_bytes := [5]int{0, 0, 0, 0, 0}
	want_bytes[0] = len(CM_PROBE) - len("c")  // over 'c'
	want_bytes[1] = want_bytes[0] - len("😀") // over the astral rune (4 bytes, 2 cells)
	want_bytes[2] = want_bytes[1] - len("b")
	want_bytes[3] = want_bytes[2] - len("世") // over the CJK rune (3 bytes, 2 cells)
	want_bytes[4] = want_bytes[3] - len("a")

	for i := 0; i < len(want_bytes); i += 1 {
		app.update(&a, cm_left)
		want := want_bytes[i]
		support.check(t, fmt.tprintf("Left step {} lands on the rune boundary at byte {}", i+1, want),
			a.filter.caret == want && a.filter.caret >= 0,
			fmt.tprintf("caret={} want={} text='{}'", a.filter.caret, want, app.text_of(&a.filter)))
	}

	app.update(&a, cm_left)
	cm_caret_is(t, "Left at the front of the filter is a NO-OP", &a.filter, 0)

	// The whole trip back, on the SAME rune boundaries, computed forward this
	// time: 0 -> a(1) -> 世(3) -> b(1) -> 😀(4) -> c(1) = 10 bytes.
	back := [5]int{
		len("a"),
		len("a") + len("世"),
		len("a世b"),
		len("a世b😀"),
		len(CM_PROBE),
	}
	for i := 0; i < len(back); i += 1 {
		app.update(&a, cm_right)
		want := back[i]
		support.check(t, fmt.tprintf("Right step {} lands on the rune boundary at byte {}", i+1, want),
			a.filter.caret == want, fmt.tprintf("caret={} want={}", a.filter.caret, want))
	}
	app.update(&a, cm_right)
	cm_caret_is(t, "Right at the end of the filter is a NO-OP", &a.filter, len(CM_PROBE))

	// THE FILTER-SPECIFIC HALF: every arrow key above moved the CARET only. The
	// filter's text is untouched, the list was never rebuilt, and the selection
	// never slid.
	support.check(t, "arrow keys never touched the filter's TEXT",
		app.text_of(&a.filter) == CM_PROBE, fmt.tprintf("filter='{}'", app.text_of(&a.filter)))
	support.check(t, "arrow keys never rebuilt the shown list",
		len(a.shown) == shown_before, fmt.tprintf("shown now={} was={}", len(a.shown), shown_before))
	support.check(t, "arrow keys never moved the selection",
		a.sel == sel_before, fmt.tprintf("sel now={} was={}", a.sel, sel_before))
}

@(test)
caret_machine_fields_do_not_share_a_caret :: proc(t: ^testing.T) {
	// Both fields live in one machine; moving one caret must not move the other.
	// A single shared caret would pass every single-field test and still put the
	// cursor in the wrong place the moment a user had typed in both.
	a := cm_new(.attach)
	cm_drive_keys(&a, "ab")
	app.update(&a, cm_left) // filter caret -> 1
	support.check(t, "the filter caret moved while the name field's caret stayed at 0",
		a.filter.caret == 1 && a.field.caret == 0 && app.text_of(&a.filter) == "ab",
		fmt.tprintf("filter='{}' caret={} field='{}' caret={}",
			app.text_of(&a.filter), a.filter.caret, app.text_of(&a.field), a.field.caret))

	// Leaving the state clears the filter — and a caret can never outlive the
	// text it points into. A caret left behind at index 1 over an empty buffer is
	// the kind of desync that later reads back as a crash or a phantom cursor.
	app.update(&a, st_esc)
	support.check(t, "the filter's caret is cleared along with its text",
		a.filter.len == 0 && a.filter.caret == 0,
		fmt.tprintf("filter len={} caret={}", a.filter.len, a.filter.caret))

	// And the name field takes its own caret-driven insert without touching the
	// filter, which is still empty.
	app.update(&a, st_kc('n'))
	cm_drive_keys(&a, "km")
	app.update(&a, cm_left)
	app.update(&a, st_kc('j'))
	support.check(t, "the name field drives its own caret-driven insert",
		app.text_of(&a.field) == "kjm" && a.field.caret == 2,
		fmt.tprintf("field='{}' caret={}", app.text_of(&a.field), a.field.caret))
	support.check(t, "and the filter is untouched by the other field's caret",
		a.filter.len == 0 && a.filter.caret == 0,
		fmt.tprintf("filter len={} caret={}", a.filter.len, a.filter.caret))
}

@(test)
caret_machine_empty_field_arrow_is_a_noop :: proc(t: ^testing.T) {
	a := cm_new(.name_local)
	support.check(t, "the name field starts empty", app.text_empty(&a.field),
		fmt.tprintf("len={} caret={}", a.field.len, a.field.caret))
	app.update(&a, cm_left)
	app.update(&a, cm_right)
	app.update(&a, cm_left)
	support.check(t, "arrowing an empty field changes nothing at all",
		a.field.len == 0 && a.field.caret == 0,
		fmt.tprintf("len={} caret={}", a.field.len, a.field.caret))
}
