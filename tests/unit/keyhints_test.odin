package unit

// keyhints_test.odin — the footer hint tables' contract, now reachable.
//
// T2 re-homed the seven KEYS_* tables and the state dispatcher out of
// `package main` into src/ui/keyhints.odin. Same reason as diag_head: while
// they lived in main they were unreachable from tests/, and the footer-width
// proofs that depend on them would otherwise have been deleted rather than
// ported.
//
// THE ORDER OF A TABLE IS CONTRACT, NOT STYLE. `ui.keys_line` keeps the exit
// hint and fills from the exit-hint side, cutting from the front when the
// footer runs out of room. So the LAST entry of every table is "how you get
// out", and these tests pin that. Reordering a table is a product change to
// what survives a narrow terminal, and it should fail here rather than quietly
// strand a user in a state they cannot leave.

import "core:fmt"
import "core:testing"

import app "../../src/app"
import ui "../../src/ui"
import support "../support"

// every state dispatches to a non-empty table
@(test)
keyhints_every_state_returns_a_nonempty_table :: proc(t: ^testing.T) {
	tables := ui.all_hint_tables()
	empty := ""
	n : int = 0
	for th in tables {
		n += 1
		if len(th.hints) == 0 {
			if empty == "" { empty = th.name } else { empty = fmt.tprintf("{}, {}", empty, th.name) }
		}
	}
	support.check(t, "every state's hint table is non-empty", n > 0 && empty == "",
		fmt.tprintf("{} tables checked, empty: '{}'", n, empty))
}

// the dispatcher agrees with the declared table for every state
@(test)
keyhints_dispatcher_matches_the_declared_table :: proc(t: ^testing.T) {
	mismatch := ""
	n : int = 0
	for th in ui.all_hint_tables() {
		n += 1
		got := ui.key_hints_for(th.state)
		if len(got) != len(th.hints) {
			mismatch = fmt.tprintf("{} len {} vs {}", th.name, len(got), len(th.hints))
			break
		}
		for i in 0 ..< len(got) {
			if got[i].key != th.hints[i].key || got[i].action != th.hints[i].action {
				mismatch = fmt.tprintf("{}[{}]={}/{} declared {}/{}",
					th.name, i, got[i].key, got[i].action,
					th.hints[i].key, th.hints[i].action)
				break
			}
		}
	}
	support.check(t, "key_hints_for returns exactly the declared table, per state",
		n > 0 && mismatch == "",
		fmt.tprintf("{} states checked, first mismatch: '{}'", n, mismatch))
}

// no table lists the same key twice: two rows for one key means the footer
// advertises two different actions for a single press.
@(test)
keyhints_no_duplicate_key_label :: proc(t: ^testing.T) {
	dups := ""
	for th in ui.all_hint_tables() {
		for i := 0; i < len(th.hints); i += 1 {
			for j := i + 1; j < len(th.hints); j += 1 {
				if th.hints[i].key == th.hints[j].key {
					dup := fmt.tprintf("{}: '{}' twice", th.name, th.hints[i].key)
					if dups == "" { dups = dup } else { dups = fmt.tprintf("{}, {}", dups, dup) }
				}
			}
		}
	}
	support.check(t, "no table advertises the same key twice", dups == "",
		fmt.tprintf("duplicates: '{}'", dups))
}

// THE ORDER CONTRACT: the last hint is always the exit/quit hint.
@(test)
keyhints_exit_hint_is_last_in_every_table :: proc(t: ^testing.T) {
	bad := ""
	for th in ui.all_hint_tables() {
		if len(th.hints) == 0 { continue }
		last := th.hints[len(th.hints)-1]
		if !is_exit_action(last.action) {
			d := fmt.tprintf("{} last='{} {}'", th.name, last.key, last.action)
			if bad == "" { bad = d } else { bad = fmt.tprintf("; {}", bad, d) }
		}
	}
	support.check(t,
		"every table's LAST hint is an exit/back/quit action (keys_line fills from that side)",
		bad == "", fmt.tprintf("offenders: '{}'", bad))
}

// THE WIDTH CONTRACT, re-homed from src/ui_cases.odin:505-532.
//
// KEYS_MODE is 8 hints / ~102 columns, so at 80 or 100 columns the footer
// MUST cut. What must survive the cut is the exit hint and `t theme`, and what
// must never happen is a hint cut in half.
@(test)
keyhints_mode_table_survives_the_width_sweep :: proc(t: ^testing.T) {
	widths : [8]int = {120, 100, 80, 60, 40, 30, 20, 10}
	for w in widths {
		ks := ui.KEYS_MODE[:]
		line := ui.keys_line(ks, i32(w))
		n := int(ui.text_cols(line))

		// the exit hint is what you are promised last and must be kept first
		support.check(t, fmt.tprintf("KEYS_MODE at {} cols still shows the exit hint", w),
			strings_contains(line, "esc quit"),
			fmt.tprintf("footer = '{}'", line))

		// `t theme` is guarded by its own width plus the exit hint's width
		need := int(ui.text_cols("t theme") + 2 + ui.text_cols("esc quit"))
		support.check(t, fmt.tprintf("KEYS_MODE at {} cols still shows `t theme`", w),
			w < need || strings_contains(line, "t theme"),
			fmt.tprintf("need={} got='{}'", need, line))

		support.check(t, fmt.tprintf("KEYS_MODE at {} cols never overflows", w),
			n <= w, fmt.tprintf("cols={} line='{}'", n, line))

		support.check(t, fmt.tprintf("KEYS_MODE at {} cols cuts no hint in half", w),
			no_half_hint(line, ks),
			fmt.tprintf("partial line='{}'", line))

		support.check(t, fmt.tprintf("KEYS_MODE at {} cols is not blank", w),
			line != "", fmt.tprintf("footer = '{}'", line))
	}
}

//-----------------------------------------------------------------------------
// local predicates
//-----------------------------------------------------------------------------

is_exit_action :: proc(a: string) -> bool {
	return strings_contains(a, "quit") || strings_contains(a, "back") ||
		strings_contains(a, "dismiss")
}

strings_contains :: proc(hay, needle: string) -> bool {
	if len(needle) == 0 { return true }
	if len(needle) > len(hay) { return false }
	for i := 0; i + len(needle) <= len(hay); i += 1 {
		match := true
		for k := 0; k < len(needle); k += 1 {
			if hay[i+k] != needle[k] { match = false; break }
		}
		if match { return true }
	}
	return false
}

// no_half_hint: every whitespace-delimited word of the rendered footer must be
// a whole action verb from some declared hint. A truncated "delete" arriving as
// "delet" is the failure this catches — it reads as a real key binding.
no_half_hint :: proc(line: string, ks: []ui.Key_Hint) -> bool {
	words := split_ws(line)
	for wd in words {
		if wd == "…" || len(wd) == 0 { continue }
		if !hint_contains_action_word(wd, ks) { return false }
	}
	return true
}

hint_contains_action_word :: proc(w: string, ks: []ui.Key_Hint) -> bool {
	for k in ks {
		for wd in split_ws(k.action) {
			if wd == w { return true }
		}
		for wd in split_ws(k.key) {
			if wd == w { return true }
		}
	}
	return false
}

split_ws :: proc(s: string) -> [dynamic]string {
	out : [dynamic]string = {}
	i := 0
	for i < len(s) {
		if s[i] == ' ' || s[i] == '\t' { i += 1; continue }
		j := i
		for j < len(s) { if s[j] == ' ' || s[j] == '\t' { break }; j += 1 }
		append(&out, s[i:j])
		i = j
	}
	return out
}
