package support

// terminal.odin — the test harness's terminal acquisition.
//
// The `enter_terminal` / `leave_terminal` pair the render and ui suites use
// (four pairs in render_cases, and ui_cases' `bring_up`). They lived in
// `package main` and were unreachable from `tests/`.
//
// They live HERE, not in `src/ui`, because they are test scaffolding, not
// product. The product acquires the terminal as part of its own run; this is a
// test deciding to put the terminal into the state the product expects so it
// can assert on what gets painted. Promoting it into `ui` would make the
// product own a capability it does not use, purely for a test's convenience —
// which is how product code accumulates test-shaped holes.
//
// ⚠️ These open the REAL controlling terminal. A test that calls
// `enter_terminal` and faults without `leave_terminal` leaves the developer's
// tty in a raw, cursor-hidden state. `with_terminal` exists so the exit is
// structural rather than a discipline the test has to remember.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import tb "../../vendor/termbox2-odin"

// enter_terminal acquires the terminal exactly the way the product does.
// Anything divergent here means the render/ui suites are asserting against a
// terminal configuration the product never actually runs in.
enter_terminal :: proc() -> bool {
	rv := tb.tb_init()
	if rv != tb.TB_OK {
		fmt.printfln("[HS] FAIL terminal.enter — tb_init -> {} ({})", rv, tb.tb_strerror(rv))
		return false
	}
	// TRUECOLOR first, cursor hidden second: the same order the product uses,
	// because the colour mode affects what the painter emits and a test that
	// sets it after painting has already made a colour decision asserts nothing.
	tb.tb_set_output_mode(tb.OUTPUT_TRUECOLOR)
	tb.tb_hide_cursor()
	return true
}

// leave_terminal releases it.
leave_terminal :: proc() {
	tb.tb_shutdown()
}

// with_terminal runs `body` with the terminal acquired and ALWAYS releases it,
// through a core:testing cleanup so the release happens on the fault path too.
//
// Why this exists rather than telling tests to pair the calls themselves: a
// test that faults between enter and leave leaves the developer's terminal in a
// raw, cursor-hidden state, and a suite that does that is a suite nobody wants
// to run. Making the pairing structural is the only version that holds.
with_terminal :: proc(t: ^testing.T, label: string, body: proc(t: ^testing.T)) {
	if !enter_terminal() {
		check(t, fmt.tprintf("{}: tb_init acquired the terminal", label), false,
			"tb_init did not return TB_OK — nothing downstream can be observed")
		return
	}
	// Registered only after a successful init, so we never shut down a terminal
	// we never opened.
	testing.cleanup(t, leave_terminal_cb, nil)
	check(t, fmt.tprintf("{}: terminal acquired (truecolor, cursor hidden)", label), true,
		"tb_init OK")
	body(t)
}

leave_terminal_cb :: proc(_: rawptr) {
	leave_terminal()
}
