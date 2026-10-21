package unit

// ─────────────────────────────────────────────────────────────────────────────
// state_machine_test.odin — T6 port of the `state-machine` case.
//
// Source: `case_state_machine` (src/state_cases.odin:240) driven by
// dev/state-smoke.sh section 1. 189 counted assertions in 17 sections, plus
// the transcript's printf guard = 190 counted here.
//
// WHY ONE @(test) PROC PER SECTION
//
// The old driver called all 17 sections inside one proc and carried a single
// `any_failed` flag across them, so a failure in section [3] and a failure in
// section [12] were indistinguishable and a careless `any_failed = false`
// could erase either. `core:testing`'s `error_count` is PER TEST, so splitting
// the sections gives the same isolation without the flag. The section list
// order is preserved so the transcript still reads as the same report.
//
// NOTHING IN THIS FILE TOUCHES A TERMINAL, A SOCKET, A CONFIG FILE OR A CHILD
// PROCESS. That is not a shortcut — `update(app, key) -> Command` performs no
// side effects, so the whole transition table is verifiable with nothing in
// front of it, and section [12] proves no child process was created to get
// here. The greps that say WHY live in state_surface_test.odin.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import support "../support"

@(test)
state_machine_keymap :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_keymap(&c)
}

@(test)
state_machine_matrix :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_matrix(&c)
}

@(test)
state_machine_reachability :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_reachability(&c)
}

@(test)
state_machine_two_step :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_two_step(&c)
}

@(test)
state_machine_empty_field_noop :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_empty_field_noop(&c)
}

@(test)
state_machine_no_selection_noop :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_no_selection_noop(&c)
}

@(test)
state_machine_ctrl_c_everywhere :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_ctrl_c_everywhere(&c)
}

@(test)
state_machine_esc_back :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_esc_back(&c)
}

@(test)
state_machine_identity_not_sliding :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_identity_not_sliding(&c)
}

@(test)
state_machine_r2_filter_owns_four_states :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_r2_filter_owns_four(&c)
}

@(test)
state_machine_r4_highlight_is_the_selection :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_r4_highlight(&c)
}

@(test)
state_machine_rch4_mode_selection_has_no_highlight :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_rch4_no_highlight(&c)
}

@(test)
state_machine_r3_delete_key_is_backspace :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_r3_delete_key(&c)
}

@(test)
state_machine_filter_agrees_with_the_view :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_filter_agrees(&c)
}

@(test)
state_machine_never_targets_default :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_never_default(&c)
}

@(test)
state_machine_empty_world :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_empty_world(&c)
}

@(test)
state_machine_created_no_child_process :: proc(t: ^testing.T) {
	c := st_live(t)
	st_sec_offline_proof(&c)
}

// ── the printf guard ──────────────────────────────────────────────────────
//
// `assert_formatted "state-machine" "$OUT/state-machine.log"` in
// dev/state-smoke.sh. It is ONE counted assertion, and it is a real one: it
// scans the full rendered text the battery produces (report header, fixture
// line, every section header, the whole (state x key) grid and every rule's
// evidence line) for Odin/Go printf fallout — `%!`, `%!(NO VERB)`, `%!(MISSING)`.
//
// The harness makes every one of those lines by `fmt.tprintf`-ing a detail
// string, which is exactly where a verb/argument mismatch appears. The gate
// ALSO sweeps the whole run log for `%!` (rule 7), so this is belt and braces:
// the guard lives in the suite that generates the text.
@(test)
state_machine_transcript_is_formatted :: proc(t: ^testing.T) {
	text := st_render_machine()
	support.check(t, "state-machine transcript — no printf fallout",
		!support.has_fallout(text),
		fmt.tprintf("scanned {} bytes of rendered battery output ({} lines)",
			len(text), st_count_lines(text)))
}

st_count_lines :: proc(s: string) -> int {
	if len(s) == 0 { return 0 }
	n := 1
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' { n += 1 }
	}
	return n
}
