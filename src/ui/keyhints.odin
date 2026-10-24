package ui

import app "../app"

// ─────────────────────────────────────────────────────────────────────────────
// keyhints.odin — the footer's hint tables, per machine state.
//
// Re-homed out of `package main` (was src/main.odin:1142-1215) in Task 2. Like
// `diag_head`, these were unreachable from `tests/` while they lived in `main`,
// and the footer-width proofs that depend on them would otherwise have been
// deleted rather than ported.
//
// The tables are the SINGLE source. `main`'s `KEYS_*` are now references to
// these (not copies), so the pre-migration suites that still say `KEYS_MODE[:]`
// read the very same memory this module owns — one table, one truth. See
// src/main.odin.
//
// `Key_Hint` is already ui's type (frame.odin). The dispatcher keys off
// `app.State`, which is what `main.tui_keys` was reading out of the global
// `tui.machine.state`; taking it as a parameter is what makes it testable.
//
// DESCRIPTIONS ARE DISPLAY STRINGS, NOT STATE LABELS (AD-2). Every hint below
// carries its OWN display string, written to read as `Description: key`
// (frame.odin inverts the pair and joins units with ` | `). They are
// deliberately NOT derived from RCH-9's `state_label`, which answers "where
// am I" ("Name remote session") rather than "what does this key do".
// Deriving one from the other would make every hint inside a state read the
// same, which is worse than useless in a footer whose whole job is telling
// eight keys apart at a glance. The three the plan pins by name:
//
//	`r`  New remote        — reached from .remote_server
//	`s`  New named remote  — reached from .name_remote_named
//	`a`  Attach            — reached from .attach
//
// and the same rule applies to every other row in all seven tables. The one
// row that resists the shape is flagged where it sits.
//
// ORDER IS CONTRACT, NOT STYLE. `keys_line` keeps the exit hint and fills from
// the exit-hint side, cutting from the front when the footer runs out of room
// (frame.odin). So the LAST entry of every table is "how you get out", and the
// tests below pin it. Reordering a table is a product change to what survives a
// narrow terminal.
// ─────────────────────────────────────────────────────────────────────────────

KEYS_MODE : [8]Key_Hint = {
	Key_Hint{"enter", "New local session"},
	Key_Hint{"n", "New named local"},
	Key_Hint{"r", "New remote"},
	Key_Hint{"s", "New named remote"},
	Key_Hint{"a", "Attach"},
	Key_Hint{"d", "Delete"},
	Key_Hint{"t", "Theme"},
	Key_Hint{"esc", "Quit"},
}

KEYS_ATTACH : [5]Key_Hint = {
	Key_Hint{"up/down", "Select"},
	Key_Hint{"type", "Filter"},
	Key_Hint{"enter", "Attach existing"},
	Key_Hint{"esc", "Back"},
	Key_Hint{"ctrl-c", "Quit"},
}

KEYS_DELETE : [5]Key_Hint = {
	Key_Hint{"up/down", "Select"},
	Key_Hint{"type", "Filter"},
	Key_Hint{"enter", "Stop + delete"},
	Key_Hint{"esc", "Back"},
	Key_Hint{"ctrl-c", "Quit"},
}

KEYS_NAME : [4]Key_Hint = {
	Key_Hint{"type", "Name with A-Z a-z 0-9 . _ -"},
	Key_Hint{"enter", "Create"},
	Key_Hint{"esc", "Back"},
	Key_Hint{"ctrl-c", "Quit"},
}

KEYS_PICK : [5]Key_Hint = {
	Key_Hint{"up/down", "Select"},
	Key_Hint{"type", "Filter"},
	Key_Hint{"enter", "Choose"},
	Key_Hint{"esc", "Back"},
	Key_Hint{"ctrl-c", "Quit"},
}

KEYS_THEME : [5]Key_Hint = {
	Key_Hint{"up/down", "Select"},
	Key_Hint{"type", "Filter"},
	Key_Hint{"enter", "Apply theme"},
	Key_Hint{"esc", "Back"},
	Key_Hint{"ctrl-c", "Quit"},
}

KEYS_ERROR : [3]Key_Hint = {
	Key_Hint{"enter", "Dismiss"},
	Key_Hint{"esc", "Dismiss"},
	Key_Hint{"ctrl-c", "Quit"},
}

// ALL_HINTS is every table in the module, paired with the state it belongs to.
// It exists so a test can iterate ALL states rather than the handful someone
// remembered to write a case for. A table that is not reachable through this
// list is a table nothing asserts about.
State_Hints :: struct {
	state : app.State,
	name  : string,
	 hints : []Key_Hint,
}

all_hint_tables :: proc() -> [dynamic]State_Hints {
	out : [dynamic]State_Hints = {}
	append(&out, State_Hints{state = .mode_selection, name = "KEYS_MODE",  hints = KEYS_MODE[:]})
	append(&out, State_Hints{state = .attach,          name = "KEYS_ATTACH", hints = KEYS_ATTACH[:]})
	append(&out, State_Hints{state = .delete_session,  name = "KEYS_DELETE", hints = KEYS_DELETE[:]})
	append(&out, State_Hints{state = .name_local,      name = "KEYS_NAME",   hints = KEYS_NAME[:]})
	append(&out, State_Hints{state = .name_remote_named, name = "KEYS_NAME", hints = KEYS_NAME[:]})
	append(&out, State_Hints{state = .remote_server,   name = "KEYS_PICK",   hints = KEYS_PICK[:]})
	append(&out, State_Hints{state = .theme,           name = "KEYS_THEME",  hints = KEYS_THEME[:]})
	append(&out, State_Hints{state = .error,           name = "KEYS_ERROR",  hints = KEYS_ERROR[:]})
	return out
}

// key_hints_for is the footer's honest list of what works RIGHT NOW. Anything
// not listed does nothing, which is what makes the footer a contract instead of
// decoration.
//
// The fallback at the end is deliberately KEYS_MODE and not an empty slice: an
// unknown state must still tell the user how to get out. The switch below is
// #partial, so a new app.State is a build error here rather than a silent walk
// into that fallback — which is the point of keeping it a switch.
key_hints_for :: proc(state: app.State) -> []Key_Hint {
	#partial switch state {
	case .mode_selection:
		return KEYS_MODE[:]
	case .attach:
		return KEYS_ATTACH[:]
	case .delete_session:
		return KEYS_DELETE[:]
	case .name_local, .name_remote_named:
		return KEYS_NAME[:]
	case .remote_server:
		return KEYS_PICK[:]
	case .theme:
		return KEYS_THEME[:]
	case .error:
		return KEYS_ERROR[:]
	}
	return KEYS_MODE[:]
}
