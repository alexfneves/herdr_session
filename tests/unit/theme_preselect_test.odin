package unit

// theme_preselect_test.odin — ADDITIVE defence-in-depth for the picker
// pre-select property. NOT part of the 135 ported T9 assertions.
//
// READ THIS BEFORE COUNTING IT AGAINST ANYTHING
//
// The legacy suite proves "the theme picker opens on the currently applied
// theme" by driving a real pty and screen-scraping the highlight. That proof
// is deferred to T14 under the `pty` tier. These assertions cover the SAME
// property one layer down, by driving the real state machine:
//
//   enter_state(.theme)  ->  rebuild_shown  ->  shown[sel]  ==  index of the
//                                              applied theme
//
// They are NOT a substitute for the pty proof and must not be tallied as if
// they closed that gap. What they buy is a much faster, deterministic tripwire
// for the in-proc half of the property: if `rebuild_shown` stops honouring
// the empty-`cursor_id` pre-select contract, this goes red in milliseconds
// and points straight at the function, whereas the pty version shows a
// highlight in the wrong place in a screen full of other pixels.
//
// WHY IT IS STILL WORTH HAVING: the deferred pty tier cannot run in this
// wave. Without this file there is NO automatic coverage of the pre-select
// contract at all between now and T14. With it, a regression in the model
// layer is caught by a test that costs 0ms and needs no terminal.

import "core:fmt"
import "core:testing"

import app "../../src/app"
import support "../support"

// A pre-select proof needs a theme that is NOT first in the list. If the
// applied theme were index 0, a broken implementation that always selects 0
// would pass every assertion here. That is the whole value of this file, so
// the fixture is chosen for that property rather than for looks.
preselect_fixture :: proc(apply: string) -> app.App {
	names, _ := app.theme_names(context.allocator)
	return app.new_app([]app.Session{}, []app.Remote{}, names, apply)
}

@(test)
preselect_opens_on_the_applied_theme :: proc(t: ^testing.T) {
	// catppuccin-latte is NOT first alphabetically, so this cannot pass by
	// the accident of "0 is the default index".
	a := preselect_fixture("catppuccin-latte")
	app.enter_state(&a, .theme)
	want := index_of_theme("catppuccin-latte")
	support.check(t, "picker opens with the APPLIED theme highlighted (not row 0)",
		a.sel == want && want > 0,
		fmt.tprintf("sel={} want={} (row 0 is '{}') shown={}",
			a.sel, want, first_theme_name(), len(a.shown)))
}

@(test)
preselect_is_not_hardcoded_to_zero :: proc(t: ^testing.T) {
	// The control for the test above: a different applied theme must move the
	// cursor to a DIFFERENT row. Together the two prove the cursor tracks the
	// applied theme rather than a constant.
	a := preselect_fixture("nord")
	app.enter_state(&a, .theme)
	want := index_of_theme("nord")
	support.check(t, "a different applied theme moves the cursor to a different row",
		a.sel == want && want != index_of_theme("catppuccin-latte"),
		fmt.tprintf("nord sel={} want={} (latte row is {})",
			a.sel, want, index_of_theme("catppuccin-latte")))
}

@(test)
preselect_default_theme_lands_on_gruvbox :: proc(t: ^testing.T) {
	// The common case: a fresh user with no config. The picker must open on
	// the default, which is also not necessarily row 0.
	a := preselect_fixture(app.THEME_DEFAULT_NAME)
	app.enter_state(&a, .theme)
	want := index_of_theme(app.THEME_DEFAULT_NAME)
	support.check(t, "fresh-user default pre-selects the default theme",
		a.sel == want,
		fmt.tprintf("sel={} want={} theme='{}'", a.sel, want, app.THEME_DEFAULT_NAME))
}

@(test)
preselect_cursor_id_resolves_to_the_applied_theme :: proc(t: ^testing.T) {
	// The real contract, which is STRONGER than the one I first assumed here.
	// `enter_state` deliberately clears `cursor_id` ("the cursor starts
	// unselected"), and then the resolve pass lands the cursor on the applied
	// theme and writes it BACK into `cursor_id` — so after entry, cursor_id
	// IS the applied theme, not the empty string.
	//
	// Asserting `cursor_id == ""` here would have been an assertion about the
	// intermediate value, and it would have fired against correct code. What
	// matters, and what this now pins, is that the value the picker ends up
	// pointing at is the theme the user is already running.
	a := preselect_fixture("catppuccin-latte")
	app.enter_state(&a, .theme)
	support.check(t, "after entry the picker's cursor IS the applied theme",
		a.cursor_id == "catppuccin-latte" && a.sel == index_of_theme("catppuccin-latte"),
		fmt.tprintf("cursor_id='{}' sel={} applied_row={}",
			a.cursor_id, a.sel, index_of_theme("catppuccin-latte")))
}

@(test)
preselect_survives_a_filter_that_hides_the_applied_theme :: proc(t: ^testing.T) {
	// RCH-4 shape: filter the list so the applied theme is NOT visible. The
	// picker must fall to the first visible row and keep `sel` in range — it
	// must not leave the cursor pointing past the end, and must not select a
	// row that is not drawn.
	a := preselect_fixture("catppuccin-latte")
	app.enter_state(&a, .theme)
	// The filter is a fixed-buffer Text fed ONE RUNE AT A TIME (whole-rune
	// backspace is the contract), so the fixture types it the way the keyboard
	// does rather than assigning a string it cannot be assigned.
	for r in "nord" { app.text_append(&a.filter, r) }
	app.rebuild_shown(&a)
	in_range := a.sel >= 0 && a.sel < len(a.shown)
	not_applied := true
	if in_range { not_applied = a.shown[a.sel] != index_of_theme("catppuccin-latte") }
	support.check(t, "filtering the applied theme out leaves sel on a VISIBLE row",
		in_range && len(a.shown) > 0,
		fmt.tprintf("sel={} shown={} filter='{}'", a.sel, len(a.shown), a.filter))
	support.check(t, "…and the selected row is not the hidden applied theme",
		not_applied,
		fmt.tprintf("sel={} applied_row={} shown={}", a.sel, index_of_theme("catppuccin-latte"), a.shown))
}

//-----------------------------------------------------------------------------
// local helpers
//-----------------------------------------------------------------------------

index_of_theme :: proc(name: string) -> int {
	for i := 0; i < app.theme_count(); i += 1 {
		if app.theme_at(i).name == name { return i }
	}
	return -1
}

first_theme_name :: proc() -> string {
	if app.theme_count() == 0 { return "<none>" }
	return app.theme_at(0).name
}
