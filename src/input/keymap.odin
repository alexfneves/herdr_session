package input

// ============================================================================
// input.keymap — tb_event -> our `Key` (T5.4 support layer)
//
// The state machine must switch on a small, stable vocabulary of *meanings*,
// not on terminal encoding details. This file is the only place in the program
// that knows how a terminal spells those meanings, so the machine never has to.
//
// ── WHY 0x03 IS A KEY AND NOT A SIGNAL (ISC-12 / plan D8) ──────────────────
// Startup uses `cfmakeraw`, which clears `ISIG`. With ISIG off the tty driver
// never turns Ctrl+C into SIGINT: the byte `0x03` arrives on the input stream
// like any other character, and termbox reports it as TB_KEY_CTRL_C. That is
// what makes "Ctrl+C quits from all 7 states" uniform — there is no per-state
// signal handler to install, and no race with a state that forgot to accept it.
// We map it here so "quit" is one Key kind, reachable from everywhere.
//
// ── NO KITTY PROTOCOL (ISC-A-4 / plan D10) ────────────────────────────────
// Escape is termbox2's LEGACY decoding: a lone ESC is reported as
// TB_KEY_ESC as soon as it arrives, with no "wait to see if it is the start of
// a longer sequence" timer. The machine therefore gets Esc-as-back with no
// timeout to inherit, and nothing in this file depends on the Kitty keyboard
// protocol (or on any escape-sequence parsing of our own).
//
// ── WHAT THIS FILE DOES NOT DO ─────────────────────────────────────────────
// No poll loop, no fd, no terminal calls. It is a pure translation of the four
// scalar fields of a `tb_event` (typ / key / ch / mod), which keeps this
// layer — and the machine above it — testable with nothing but literals.
// ============================================================================

import termbox2 "../../vendor/termbox2-odin"

Key_Kind :: enum {
	none,       // not something this app acts on (mouse, F-keys, unknown sequence)
	character,  // a printable rune — see `Key.r`
	enter,
	esc,
	backspace,
	tab,
	shift_tab,
	up,
	down,
	left,
	right,
	ctrl_c,   // byte 0x03, arriving as data because ISIG is off
}

// Key is one decoded keystroke. `r` is only meaningful for `.character`; every
// other kind is complete on its own, which is what lets the state machine
// `switch` on `kind` and never inspect raw bytes.
Key :: struct {
	kind : Key_Kind,
	r    : rune,
}

NO_KEY :: Key{kind = .none}

key_of :: proc(k: Key_Kind) -> Key {
	return Key{kind = k}
}

char_key :: proc(r: rune) -> Key {
	return Key{kind = .character, r = r}
}

// ── the code table ────────────────────────────────────────────────────────

// map_code translates one termbox key code into a Key_Kind.
//
// Written as a flat table rather than a range check so that a code termbox2
// changes spelling for shows up here as a missing case instead of silently
// landing in `.character`.
//
// NOTE: `KEY_ENTER` (0x0d) and `KEY_CTRL_J` (0x0a) are BOTH enter. Almost every
// terminal sends 0x0d for the Enter key, but a Ctrl+J from a hostile or
// mis-mapped terminal is the same action to a line editor, and treating them
// alike is what the user expects.
map_code :: proc(code: u16) -> Key_Kind {
	switch code {
	case termbox2.KEY_ENTER:      return .enter
	case termbox2.KEY_CTRL_J:    return .enter
	case termbox2.KEY_ESC:       return .esc
	case termbox2.KEY_BACKSPACE: return .backspace   // 0x08 (Ctrl+H)
	case termbox2.KEY_BACKSPACE2: return .backspace  // 0x7f — what terminals really send
	case termbox2.KEY_TAB:       return .tab
	case termbox2.KEY_BACK_TAB:  return .shift_tab   // CSI Z / Shift+Tab
	case termbox2.KEY_ARROW_UP:    return .up
	case termbox2.KEY_ARROW_DOWN:  return .down
	case termbox2.KEY_ARROW_LEFT:  return .left
	case termbox2.KEY_ARROW_RIGHT: return .right
	case termbox2.KEY_CTRL_C:     return .ctrl_c     // 0x03, data not signal
	}
	return .none
}

// control_byte_is_printable guards `.character`: everything below a space, plus
// DEL, is control and never user text. (Non-ASCII runes above 0x7f are fine;
// multi-byte UTF-8 arrives already decoded into `ch`.)
control_byte_is_printable :: proc(c: u32) -> bool {
	if c < 0x20 { return false }
	if c == 0x7f { return false }
	return true
}

// decode maps the four scalar fields of a tb_event to a Key.
//
// For EVENT_KEY, termbox fills exactly one of `key` / `ch`: `key` for control
// codes and the 0xffff-… specials, `ch` for a printable rune. Both are
// consulted (never `key` xor `ch` asserted) because a terminal that puts a
// control byte in `ch` should still decode as that control key, not as a
// printable character with a surprising codepoint.
decode :: proc(typ: u8, key: u16, ch: u32, mod: u8) -> Key {
	if typ != termbox2.EVENT_KEY { return NO_KEY }

	mapped := map_code(key)
	if mapped == .tab && (mod & termbox2.MOD_SHIFT) != 0 {
		return key_of(.shift_tab)  // a terminal that spells Shift+Tab as TAB+SHIFT
	}
	if mapped != .none { return key_of(mapped) }

	if ch == 0 { return NO_KEY }
	from_ch := map_code(u16(ch))
	if from_ch != .none { return key_of(from_ch) }
	if !control_byte_is_printable(ch) { return NO_KEY }
	return char_key(rune(ch))
}

// from_event is the convenience wrapper for the real event struct. This is the
// form T5.5's poll loop will call; keeping the field-level `decode` above is
// what lets these mappings be tested without a terminal, a pty or a live
// termbox2 context.
from_event :: proc(e: ^termbox2.Event) -> Key {
	return decode(e.typ, e.key, e.ch, e.mod)
}
