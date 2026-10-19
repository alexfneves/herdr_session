package app

// ============================================================================
// app.state — the 7-state machine (T5.4)
//
//   Key ──► update(app, key) ──► Command ──► executor (T5.5) ──► the world
//
// # THE ONE RULE: no side effects
//
// `update` touches NOTHING outside this file's own state. No I/O, no spawn, no
// filesystem, no terminal call, no `os`, no `posix`, no `terminal`, no herdr.
// It reads a `Key` and a read-mostly view of the model, mutates the machine's
// own fields (which state we are in, the filter text, the edit field, the
// selection) and RETURNS a `Command` describing what the outside world is being
// asked to do. Only T5.5's executor acts on it.
//
// That is not stylistic. It is what makes the transition table testable with no
// herdr binary, no terminal and no network present — see `state_cases.odin`,
// which drives every state offline and proves no child process is ever created.
// The only clock read is `new_session_name`'s timestamp, which is a value, not
// an effect.
//
// # WHY A TAGGED STRUCT AND NOT A UNION (decision O10)
//
// The plan sketched `Command :: union { None, LaunchLocal : LaunchSpec, … }`.
// That form is a **syntax error** in this Odin, and the closest valid form has a
// silent trap: a union's zero value is a NULL union that does **not** match
// `case None:` and falls to the default branch. In a state machine the default
// branch is exactly where a "do nothing" command must be answered correctly, so
// the union turns `Command{}` into a bug that only shows at runtime.
//
// The tagged struct below gives an explicit, matchable `.none`:
//     Command{}.kind == Cmd_Kind.none   // true, always
// and keeps `switch` exhaustive. The union was a sketch; the *requirement* is
// "side-effect-free, returns a Command", which this satisfies exactly.
//
// # STATE NAMING
//
// The seven states the spec names, plus `{Error}`, which is reached by a failed
// action rather than by a key from mode selection. `error` is in the enum for
// the same reason the others are: it has its own key handling (Enter/Esc back to
// mode selection), so it is a state, not a flag.
//
// # THE RESOLVED `[s]` TWO-STEP (plan §State transitions)
//
// The requirements doc's arrow for `[s]` ("→ {Select remote server for new
// named remote session}") contradicts the state it defines there
// ("{Select name for new named remote session}: [Enter] → {Select remote
// server…}"). Resolution: **the name is collected first, then the server.**
//
//     s → name_remote_named → (type a name) → Enter → remote_server
//       → (pick a host) → Enter → Command{launch_remote, name: <carried>,
//                                        device: <verbatim target>}
//
// The carried name lives in `App.carried_name` across the hop, and the device is
// whatever the picked `Remote.device` holds — verbatim, never normalised.
//
// # ESC AND CTRL-C
//
// * `Ctrl+C` is checked FIRST, before the per-state dispatch, so it quits from
//   all 7 states (ISC-12) and cannot be swallowed by any future state. It
//   arrives as byte 0x03 (ISIG is off — see `input/keymap.odin`), as data.
// * `Esc` is "back", answered immediately from the legacy `TB_KEY_ESC` code —
//   no timeout, no Kitty protocol (ISC-11, ISC-A-4).
//
// # CLEARING ON THE WAY OUT (documented decision, uniform rule)
//
// The spec names the clearing explicitly for two states (NameLocal's `[Escape]
// Clears the edit field`, Attach/Theme's `Clears the filter`). Rather than
// implement the asymmetry that leaves every other filtered/edit state silently
// holding stale text, this machine applies one rule:
//
//   leaving an EDIT state  → the field is cleared and `clear_field` is returned
//   leaving a FILTER state → the filter is cleared and `clear_filter` is returned
//   an action that already carries its own command (Enter → set_theme, launch,
//   attach) performs the same clearing internally and returns that action's
//   command, because a keypress yields exactly one Command.
//
// Nothing observable depends on the difference — the text is cleared either way;
// the returned kind is what the UI may use to repaint the filter/field line.
// ============================================================================

import input "../input"

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

//-----------------------------------------------------------------------------
// States
//-----------------------------------------------------------------------------

State :: enum {
	mode_selection,    // Sessions table. The root state.
	name_local,        // Single edit — name for a new LOCAL session
	remote_server,   // Filtered list — which ssh target to create on
	name_remote_named, // Single edit — name for a new NAMED REMOTE session (BEFORE the host pick)
	attach,            // Sessions — pick a session to attach to
	delete_session,  // Sessions — pick a session to delete
	theme,           // Filtered list — pick a theme
	error,             // Single text — the last failure
}

state_label :: proc(s: State) -> string {
	switch s {
	case .mode_selection:    return "mode_selection"
	case .name_local:        return "name_local"
	case .remote_server:     return "remote_server"
	case .name_remote_named: return "name_remote_named"
	case .attach:            return "attach"
	case .delete_session:    return "delete_session"
	case .theme:             return "theme"
	case .error:             return "error"
	}
	return "?"
}

// state_is_session_view: the states whose main content is the Sessions table.
// Their selection is a session IDENTITY, which is the whole point of `held`.
state_is_session_view :: proc(s: State) -> bool {
	return s == .mode_selection || s == .attach || s == .delete_session
}

// state_is_filter_view: the states where typed characters narrow a list.
state_is_filter_view :: proc(s: State) -> bool {
	return s == .mode_selection || s == .remote_server ||
		s == .attach || s == .delete_session || s == .theme
}

// state_is_edit_view: the states whose main content is a single editable line.
state_is_edit_view :: proc(s: State) -> bool {
	return s == .name_local || s == .name_remote_named
}

//-----------------------------------------------------------------------------
// Commands
//-----------------------------------------------------------------------------

Cmd_Kind :: enum {
	none,          // the keypress changed machine state and asked for nothing
	launch_local,  // create/attach a local session (herdr owns create-or-attach)
	launch_remote, // same, on `device` verbatim
	attach,        // attach to an already-validated (device, name)
	delete,        // stop-if-running then delete the (device, name)
	set_theme,     // apply + persist `value`
	show_error,    // surface `value` in the {Error} state
	clear_filter,  // the filter line must go empty in the UI too
	clear_field,   // the edit field must go empty in the UI too
	quit,          // exit the program (terminal restore is the executor's job)
}

// Command is the machine's entire output. `device` is "local" or the VERBATIM
// ssh target (never normalised — the same string has to travel back out into
// `herdr --remote <device>`). `name` is the session name, `value` the theme
// name or the error message.
Command :: struct {
	kind   : Cmd_Kind,
	device : string,
	name   : string,
	value  : string,
}

cmd_kind_label :: proc(k: Cmd_Kind) -> string {
	switch k {
	case .none:         return "none"
	case .launch_local: return "launch_local"
	case .launch_remote: return "launch_remote"
	case .attach:       return "attach"
	case .delete:      return "delete"
	case .set_theme:   return "set_theme"
	case .show_error:  return "show_error"
	case .clear_filter: return "clear_filter"
	case .clear_field: return "clear_field"
	case .quit:        return "quit"
	}
	return "?"
}

no_cmd :: proc() -> Command { return Command{kind = .none} }
quit_cmd :: proc() -> Command { return Command{kind = .quit} }

cmd_launch_local :: proc(name: string) -> Command {
	return Command{kind = .launch_local, device = DEVICE_LOCAL, name = name}
}
cmd_launch_remote :: proc(device: string, name: string) -> Command {
	return Command{kind = .launch_remote, device = device, name = name}
}
cmd_attach :: proc(device: string, name: string) -> Command {
	return Command{kind = .attach, device = device, name = name}
}
cmd_delete :: proc(device: string, name: string) -> Command {
	return Command{kind = .delete, device = device, name = name}
}
cmd_set_theme :: proc(theme: string) -> Command {
	return Command{kind = .set_theme, value = theme}
}
cmd_clear_filter :: proc() -> Command { return Command{kind = .clear_filter} }
cmd_clear_field :: proc() -> Command { return Command{kind = .clear_field} }
cmd_show_error :: proc(msg: string) -> Command {
	return Command{kind = .show_error, value = msg}
}

//-----------------------------------------------------------------------------
// Text fields
//-----------------------------------------------------------------------------

// NAME_PREFIX_MAX bounds what may be typed before the timestamp is appended, so
// the generated name can never exceed NAME_MAX_LEN by typing alone.
NAME_PREFIX_MAX :: NAME_MAX_LEN - TS_SUFFIX_LEN - 1 // 64 - 23 - 1 = 40

// FILTER_MAX bounds the filter line. Filters are not validated against any
// charset (they match arbitrary text), but they must not grow without bound.
FILTER_MAX :: 128

// TEXT_MAX is the absolute cap on either field, so no input path can grow a
// buffer without limit.
TEXT_MAX :: 256

// Text is the machine's own single-line buffer: a FIXED array plus a length.
//
// Fixed rather than `[dynamic]byte`, for three reasons that all bit this repo:
//  * a dynamic array is SHARED by every copy of the struct, so copying an `App`
//    (which the transition probes do constantly) aliases — and a later
//    grow-on-append leaves the copy pointing at freed memory;
//  * this toolchain has no range-delete for dynamic arrays at all (verified:
//    `delete_range` is undeclared), and truncating a tail is exactly what
//    backspace does — `len -= n` is the whole operation;
//  * it bounds what a held-down key can put in a buffer with no allocator on
//    the hot path. Same shape as `ui.Edit`, for the same reasons.
Text :: struct {
	buf : [TEXT_MAX]u8,
	len : int,
}

// text_of returns the buffer's contents. The returned string ALIASES the
// buffer: anything kept beyond the current call must be cloned.
text_of :: proc(t: ^Text) -> string {
	if t.len <= 0 { return "" }
	return string(t.buf[0:t.len])
}

text_empty :: proc(t: ^Text) -> bool {
	return t.len == 0
}

text_clear :: proc(t: ^Text) {
	t.len = 0
}

// text_append appends ONE WHOLE RUNE as its UTF-8 bytes. Keys arrive decoded,
// so multi-byte input can never be split at this layer.
text_append :: proc(t: ^Text, r: rune) -> bool {
	tmp, n := utf8.encode_rune(r)
	if n <= 0 || t.len+n > TEXT_MAX { return false }
	for i in 0..<n {
		t.buf[t.len+i] = tmp[i]
	}
	t.len += n
	return true
}

// text_backspace removes the WHOLE rune at the end. Deleting one byte of a
// 3-byte rune would leave a dangling continuation byte that renders as garbage.
text_backspace :: proc(t: ^Text) -> bool {
	if t.len == 0 { return false }
	_, n := utf8.decode_last_rune_in_string(string(t.buf[0:t.len]))
	if n <= 0 { n = 1 } // undecodable tail: drop one byte so the field stays usable
	if n > t.len { n = t.len }
	t.len -= n
	return true
}

//-----------------------------------------------------------------------------
// The machine
//-----------------------------------------------------------------------------

// App is the machine's view of the world plus its own mutable UI state.
//
// `sessions`, `remotes` and `themes` are READ: `update` never writes through
// them, never re-sorts them, never filters them in place. Everything `update`
// mutates is below them — the state, the two text fields, the cursor, and the
// carried name.
App :: struct {
	state : State,

	// ── owned text (rune-appended, whole-rune backspace) ──
	field  : Text, // the single-line edit in the two edit states
	filter : Text, // the live filter in every filter state

	// ── read-mostly inputs ──
	sessions : []Session,
	remotes  : []Remote,
	themes   : []string,

	// ── selection ──
	shown : [dynamic]int, // indices into the ACTIVE item list that pass the filter
	sel   : int,          // index into `shown`; -1 == nothing selected
	held  : Selection,    // in the session views: the IDENTITY behind `sel`
	cursor_id : string,   // in the pickers: what the cursor points at (device / theme)

	// ── carried / current ──
	carried_name : string, // the [s] two-step's name, carried into remote_server
	theme        : string, // the theme currently applied (pre-selected in the picker)
	last_error   : string, // the {Error} state's single text
}

// new_app builds a machine in {Mode selection}. No fetch, no config read: the
// caller hands in whatever is known, which is exactly why this runs offline.
new_app :: proc(sessions: []Session, remotes: []Remote, themes: []string, theme: string) -> App {
	return App{
		state      = .mode_selection,
		sessions   = sessions,
		remotes    = remotes,
		themes     = themes,
		theme      = theme,
		sel        = -1,
		held       = NO_SELECTION,
	}
}

app_free :: proc(a: ^App) {
	delete(a.shown)
}

// ── the active item list ──────────────────────────────────────────────────

// shown_count is how many items the active list currently displays.
shown_count :: proc(a: ^App) -> int {
	return len(a.shown)
}

// active_index resolves the cursor into the active item slice.
// Returns (-1, false) when nothing is selected — every Enter handler treats
// that as a NO-OP rather than picking item 0.
active_index :: proc(a: ^App) -> (int, bool) {
	if a.sel < 0 || a.sel >= len(a.shown) { return -1, false }
	idx := a.shown[a.sel]
	if idx < 0 { return -1, false }
	return idx, true
}

// machine_session_matches mirrors `ui.sessions_match`. Keeping both means the
// row Enter acts on and the row that is PAINTED as selected come from the same
// predicate; `state_cases.odin` asserts the two agree over a matrix of rows
// and filters, so they cannot drift apart unnoticed.
machine_session_matches :: proc(s: Session, filter: string) -> bool {
	if len(filter) == 0 { return true }
	return contains_ci(s.name, filter) ||
		contains_ci(s.device, filter) ||
		contains_ci(s.label, filter)
}

contains_ci :: proc(haystack, needle: string) -> bool {
	h := strings.to_lower(haystack, context.allocator)
	n := strings.to_lower(needle, context.allocator)
	return strings.contains(h, n)
}

remote_matches :: proc(r: Remote, filter: string) -> bool {
	if len(filter) == 0 { return true }
	return contains_ci(r.device, filter) || contains_ci(r.label, filter)
}

theme_matches :: proc(name: string, filter: string) -> bool {
	if len(filter) == 0 { return true }
	return contains_ci(name, filter)
}

// rebuild_shown recomputes `shown` for the ACTIVE state and re-places the
// cursor on the SAME IDENTITY / SAME ITEM if it survived the filter.
//
// The "same identity" step is load-bearing: if the selected row is filtered
// out, the cursor must drop to -1, NOT slide onto whatever row shifted into
// its slot. Sliding is how Enter ends up acting on a row the user never
// pointed at.
rebuild_shown :: proc(a: ^App) {
	filter := text_of(&a.filter)
	keep := a.held

	clear(&a.shown)
	a.sel = -1

	#partial switch a.state {
	case .mode_selection, .attach, .delete_session:
		for s, i in a.sessions {
			if machine_session_matches(s, filter) { append(&a.shown, i) }
		}
		if keep.valid {
			found := false
			for idx, pos in a.shown {
				if a.sessions[idx].device == keep.device && a.sessions[idx].name == keep.name {
					a.sel = pos
					found = true
					break
				}
			}
			// A selection the filter removed is GONE. Leaving `held` valid would
			// let Enter act on a row that is no longer on screen — and `held` is
			// what the Command is built from, so it must mean "visible selection".
			if !found { a.held = NO_SELECTION }
		}

	case .remote_server:
		for r, i in a.remotes {
			if remote_matches(r, filter) { append(&a.shown, i) }
		}
		if a.cursor_id != "" {
			for idx, pos in a.shown {
				if a.remotes[idx].device == a.cursor_id {
					a.sel = pos
					break
				}
			}
		}

	case .theme:
		for t, i in a.themes {
			if theme_matches(t, filter) { append(&a.shown, i) }
		}
		// "The theme selected by default is the theme currently being applied."
		// `cursor_id` is empty on entry, so the cursor lands on the live theme;
		// after the user moves it lands back on wherever the user pointed.
		focus := a.cursor_id
		if focus == "" { focus = a.theme }
		if focus != "" {
			for idx, pos in a.shown {
				if a.themes[idx] == focus {
					a.sel = pos
					break
				}
			}
		}

	case:
		// Edit states and {Error} show no list; nothing to rebuild.
	}
}

// ── cursor movement ───────────────────────────────────────────────────────

// move_index is the shared clamp: from no selection, `down` selects the first
// row and `up` the last; out-of-range moves stick at the ends; an empty list
// stays at -1 (no crash, no phantom row).
move_index :: proc(cur, count, delta: int) -> int {
	if count <= 0 { return -1 }
	if cur < 0 {
		if delta < 0 { return count - 1 }
		return 0
	}
	next := cur + delta
	if next < 0 { next = 0 }
	if next > count-1 { next = count - 1 }
	return next
}

// sync_cursors records what the cursor is now pointing at, in the forms the
// pickers need (session identity / remote device / theme name).
sync_cursors :: proc(a: ^App) {
	idx, ok := active_index(a)
	if !ok {
		a.held = NO_SELECTION
		return
	}
	#partial switch a.state {
	case .mode_selection, .attach, .delete_session:
		a.held = selection_from_index(a.sessions, idx)
	case .remote_server:
		a.held = NO_SELECTION
		if idx < len(a.remotes) { a.cursor_id = a.remotes[idx].device }
	case .theme:
		a.held = NO_SELECTION
		if idx < len(a.themes) { a.cursor_id = a.themes[idx] }
	case:
		a.held = NO_SELECTION
	}
}

move_shown :: proc(a: ^App, delta: int) {
	a.sel = move_index(a.sel, len(a.shown), delta)
	sync_cursors(a)
}

// ── state transitions of the machine itself ───────────────────────────────

// enter_state moves to `s` with that state's starting conditions: the filter
// line starts EMPTY (spec: "a line for the filter (it starts empty)"), the
// cursor starts unselected, and the previous state's leftovers are dropped.
enter_state :: proc(a: ^App, s: State) {
	a.state = s
	text_clear(&a.filter)
	text_clear(&a.field)
	clear(&a.shown)
	a.sel = -1
	a.held = NO_SELECTION
	a.cursor_id = ""
	if s != .remote_server { a.carried_name = "" }
	rebuild_shown(a)
}

// back_to_selection is "Escape reached {Mode selection}". It returns the
// command that describes what was cleared, so the UI can clear its own copy of
// the same text.
back_to_selection :: proc(a: ^App, cleared: Command) -> Command {
	enter_state(a, .mode_selection)
	return cleared
}

// to_error parks the machine in {Error} with a message.
to_error :: proc(a: ^App, msg: string) -> Command {
	a.state = .error
	text_clear(&a.filter)
	text_clear(&a.field)
	clear(&a.shown)
	a.sel = -1
	a.held = NO_SELECTION
	a.cursor_id = ""
	a.carried_name = ""
	a.last_error = strings.clone(msg, context.allocator)
	return cmd_show_error(msg)
}

//-----------------------------------------------------------------------------
// update — the whole machine
//-----------------------------------------------------------------------------

// update is the only entry point. (state, key) → Command. See the file header
// for the no-side-effects rule this function exists to enforce.
update :: proc(a: ^App, k: input.Key) -> Command {
	// ISC-12: Ctrl+C quits from EVERY state. Checked before the dispatch so a
	// new state cannot accidentally swallow it, and so "all 7 states" is one
	// line rather than seven.
	if k.kind == .ctrl_c {
		return quit_cmd()
	}

	#partial switch a.state {
	case .mode_selection:    return at_mode_selection(a, k)
	case .name_local:         return at_name_local(a, k)
	case .remote_server:     return at_remote_server(a, k)
	case .name_remote_named: return at_name_remote_named(a, k)
	case .attach:            return at_attach(a, k)
	case .delete_session:    return at_delete(a, k)
	case .theme:             return at_theme(a, k)
	case .error:             return at_error(a, k)
	}
	return no_cmd()
}

// ── {Mode selection} ──────────────────────────────────────────────────────

at_mode_selection :: proc(a: ^App, k: input.Key) -> Command {
	if k.kind == .esc {
		return quit_cmd()  // spec: [Escape, CTRL+C] Exit the program
	}
	if k.kind == .enter {
		// [Enter] New session with a timestamped name (D11).
		return new_session_command(a, DEVICE_LOCAL, "")
	}
	if k.kind == .character {
		switch k.r {
		case 'n': enter_state(a, .name_local); return no_cmd()
		case 'r': enter_state(a, .remote_server); return no_cmd()
		case 's': enter_state(a, .name_remote_named); return no_cmd()
		case 'a': enter_state(a, .attach); return no_cmd()
		case 'd': enter_state(a, .delete_session); return no_cmd()
		case 't': enter_state(a, .theme); return no_cmd()
		}
		// Every other printable key filters the Sessions table. The six mode keys
		// above returned already, so this only ever sees unclaimed characters —
		// which is what keeps the spec's filter line usable in the Sessions view
		// without colliding with a mode binding.
		if a.filter.len >= FILTER_MAX { return no_cmd() }
		text_append(&a.filter, k.r)
		rebuild_shown(a)
	}
	return no_cmd()
}

// ── {Select name of new local session} ────────────────────────────────────

at_name_local :: proc(a: ^App, k: input.Key) -> Command {
	if k.kind == .esc {
		return back_to_selection(a, cmd_clear_field())
	}
	if k.kind == .enter {
		prefix := text_of(&a.field)
		// Empty field + Enter is a NO-OP (spec: "If nothing was selected,
		// pressing the key does nothing"). Staying put is the whole answer:
		// no command, no state change, no half-built session name.
		if len(prefix) == 0 { return no_cmd() }
		if v := validate_name(prefix); !v.ok {
			return to_error(a, fmt.tprintf("bad session name: {}", v.reason))
		}
		return new_session_command(a, DEVICE_LOCAL, prefix)
	}
	consume_edit_key(a, k)
	return no_cmd()
}

// ── {Select name for new named remote session} ────────────────────────────

at_name_remote_named :: proc(a: ^App, k: input.Key) -> Command {
	if k.kind == .esc {
		return back_to_selection(a, cmd_clear_field())
	}
	if k.kind == .enter {
		prefix := text_of(&a.field)
		// Same convention as the local name entry: nothing typed → nothing to
		// carry, and this is the NAMED path, so no name means no step forward.
		// (The unnamed remote path is `[r]`, which skips this state entirely.)
		if len(prefix) == 0 { return no_cmd() }
		if v := validate_name(prefix); !v.ok {
			return to_error(a, fmt.tprintf("bad session name: {}", v.reason))
		}
		carried := strings.clone(prefix, context.allocator)
		enter_state(a, .remote_server)
		a.carried_name = carried  // cloned: the field buffer gets reused underneath
		return no_cmd()
	}
	consume_edit_key(a, k)
	return no_cmd()
}

// consume_edit_key applies the shared single-line-edit keys to `field`.
//
// Characters outside the herdr name charset are REJECTED AT INPUT (plan §Edge
// cases: "names are [A-Za-z0-9._-] only"). Rejecting here — before the name can
// reach `validate_name`, let alone an argv — is what keeps a stray paste from
// ever becoming an argument.
consume_edit_key :: proc(a: ^App, k: input.Key) {
	#partial switch k.kind {
	case .backspace:
		text_backspace(&a.field)
	case .character:
		if k.r > 0x7f { return }  // non-ASCII can never be a legal name byte
		if !name_is_valid_character(byte(k.r)) { return }
		if a.field.len >= NAME_PREFIX_MAX { return }
		text_append(&a.field, k.r)
	}
}

// ── {Select remote server…} ───────────────────────────────────────────────

at_remote_server :: proc(a: ^App, k: input.Key) -> Command {
	if k.kind == .esc {
		return back_to_selection(a, cmd_clear_filter())
	}
	if k.kind == .enter {
		idx, ok := active_index(a)
		if !ok { return no_cmd() }  // nothing selected → NO-OP
		if idx >= len(a.remotes) { return no_cmd() }
		// VERBATIM: the Command carries `Remote.device` exactly as configured.
		// No lower-casing, no alias resolution, no FQDN substitution — the same
		// string has to go back out through `herdr --remote <device>`.
		device := a.remotes[idx].device
		name := a.carried_name
		return new_session_command(a, device, name)
	}
	filter_navigate(a, k)
	return no_cmd()
}

// ── {Select session to attach} ────────────────────────────────────────────

at_attach :: proc(a: ^App, k: input.Key) -> Command {
	if k.kind == .esc {
		return back_to_selection(a, cmd_clear_filter())
	}
	if k.kind == .enter {
		if !a.held.valid { return no_cmd() }  // nothing selected → NO-OP
		row, ok := selection_session(a.sessions, a.held)
		if !ok {
			// The identity is not in the model. Refusing here is the orphan
			// guard (ISC-17): `herdr session attach` CREATES what it cannot
			// find, so an unvalidated name would leave a live session behind.
			return to_error(a, fmt.tprintf("{} is not a known session — attach refused",
				a.held.name))
		}
		if is_default_session_name(row.name) {
			return to_error(a, "'default' is herdr's own workspace and is never attached")
		}
		if v := validate_name(row.name); !v.ok {
			return to_error(a, fmt.tprintf("bad session name: {}", v.reason))
		}
		cmd := cmd_attach(row.device, row.name)
		enter_state(a, .mode_selection)
		return cmd
	}
	filter_navigate(a, k)
	return no_cmd()
}

// ── {Select session to delete} ────────────────────────────────────────────

at_delete :: proc(a: ^App, k: input.Key) -> Command {
	if k.kind == .esc {
		return back_to_selection(a, cmd_clear_filter())
	}
	if k.kind == .enter {
		if !a.held.valid { return no_cmd() }
		row, ok := selection_session(a.sessions, a.held)
		if !ok {
			// The existence pre-check (ISC-16) starts here: no row, no delete
			// request — herdr answers `deleted:true` to names that never
			// existed, so this machine never asks.
			return to_error(a, fmt.tprintf("{} is not a known session — nothing to delete",
				a.held.name))
		}
		if is_default_session_name(row.name) {
			return to_error(a, "'default' is herdr's own workspace and is never deleted")
		}
		if v := validate_name(row.name); !v.ok {
			return to_error(a, fmt.tprintf("bad session name: {}", v.reason))
		}
		// Deleting does not leave the app: the list refreshes and the user stays
		// in {Select session to delete} to keep cleaning up.
		return cmd_delete(row.device, row.name)
	}
	filter_navigate(a, k)
	return no_cmd()
}

// ── {Select theme} ────────────────────────────────────────────────────────

at_theme :: proc(a: ^App, k: input.Key) -> Command {
	if k.kind == .esc {
		return back_to_selection(a, cmd_clear_filter())
	}
	if k.kind == .enter {
		idx, ok := active_index(a)
		if !ok { return no_cmd() }
		if idx >= len(a.themes) { return no_cmd() }
		name := a.themes[idx]
		a.theme = name
		enter_state(a, .mode_selection)  // Enter applies the theme AND clears the filter
		return cmd_set_theme(name)
	}
	filter_navigate(a, k)
	return no_cmd()
}

// ── {Error} ───────────────────────────────────────────────────────────────

at_error :: proc(a: ^App, k: input.Key) -> Command {
	if k.kind == .enter || k.kind == .esc {
		a.last_error = ""
		enter_state(a, .mode_selection)
		return no_cmd()
	}
	return no_cmd()
}

// ── the shared filtered-list keys ─────────────────────────────────────────

// filter_navigate handles Up/Down/Tab/Shift-Tab/Backspace/typed-chars for
// every filtered state. Movement and filtering are ONE code path for the
// sessions table, the remote picker and the theme picker, so the three can
// never disagree about what "down" or "type a letter" means.
filter_navigate :: proc(a: ^App, k: input.Key) {
	#partial switch k.kind {
	case .up:
		move_shown(a, -1)
	case .down:
		move_shown(a, 1)
	case .tab:
		move_shown(a, 1)
	case .shift_tab:
		move_shown(a, -1)
	case .backspace:
		if text_backspace(&a.filter) { rebuild_shown(a) }
	case .character:
		if a.filter.len >= FILTER_MAX { return }
		text_append(&a.filter, k.r)
		rebuild_shown(a)
	}
}

//-----------------------------------------------------------------------------
// Session-name generation for a launch
//-----------------------------------------------------------------------------

// new_session_command builds the launch command for a create-or-attach on
// `device`, with `prefix` + the cycle timestamp as the name (D11).
//
// The collision check is per-DEVICE: a name free on `local` may be taken on a
// remote host, which is the identity rule showing up in the name generator.
new_session_command :: proc(a: ^App, device: string, prefix: string) -> Command {
	taken := names_for_device(a.sessions, device)
	name, ok := new_session_name(prefix, taken)
	if !ok {
		return to_error(a, "could not generate a free session name")
	}
	if v := validate_name(name); !v.ok {
		return to_error(a, fmt.tprintf("bad session name: {}", v.reason))
	}
	cmd := Command{kind = .launch_remote, device = device, name = name}
	if is_local_device(device) { cmd.kind = .launch_local }
	enter_state(a, .mode_selection)
	return cmd
}
