package unit

// ─────────────────────────────────────────────────────────────────────────────
// state_harness.odin — shared fixture + driver for the T6 `state` suite.
//
// Ported from `src/state_cases.odin` (the old `case_state_machine` /
// `case_state_offline` driver) and `dev/state-smoke.sh`. NOTHING here is a
// `@(test)` proc: the sections are plain procs that the test files in
// `state_machine_test.odin` / `state_offline_test.odin` drive, so the SAME
// battery can run both against the ledger (for the count the gate enforces)
// and as a pure render (for the transcript's printf guard).
//
// WHY A RENDER MODE EXISTS
//
// The old harness printed every rule into a log file and then ran
// `assert_formatted` over that file. Under `core:testing` the log is whatever
// the runner prints, so "scan the run's own text for printf fallout" needs a
// piece of text we own. `st_render_*` runs the battery with no ledger at all
// and returns exactly the lines the battery would have printed. That makes the
// two `%!` guards real assertions over the battery's own evidence rather than
// a comment saying we looked at the console.
//
// WHY `Ctx.loc` EXISTS
//
// The ledger derives its group from `#caller_location` of the `check` call. The
// battery's assertions are made HERE, but they must be tallied under the TEST
// FILE that invoked the battery, or every section would land in one group and
// the per-suite count in parity.tsv would stop meaning anything. The location
// is therefore captured once, when the Ctx is built inside the `@(test)` proc,
// and forwarded through every helper.
// ─────────────────────────────────────────────────────────────────────────────

import cc "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "base:runtime"

import termbox2 "../../vendor/termbox2-odin"

import app "../../src/app"
import input "../../src/input"
import support "../support"
import ui "../../src/ui"

//-----------------------------------------------------------------------------
// The run context
//-----------------------------------------------------------------------------

Ctx :: struct {
	t   : ^testing.T,          // nil in render mode — nothing reaches the ledger
	tr  : ^strings.Builder,    // the transcript sink (always present)
	loc : runtime.Source_Code_Location,
}

// st_live builds a context that asserts into the ledger and renders nothing.
// It MUST be called from inside the @(test) proc so `loc` is that file, which
// is what makes the ledger tally land on the test file and not on this
// harness. The transcript is deliberately NOT accumulated here: the printf
// guard gets its text from st_render_machine/st_render_offline, which own
// their builder inside one proc instead of handing out a pointer to a local.
st_live :: proc(t: ^testing.T, loc := #caller_location) -> Ctx {
	return Ctx{t = t, tr = nil, loc = loc}
}

// st_render builds a context that only renders: no ledger, no tally, no
// `expectf`. Used by st_render_machine / st_render_offline to produce the
// text the printf guard scans.
st_render :: proc(tr: ^strings.Builder, loc := #caller_location) -> Ctx {
	return Ctx{t = nil, tr = tr, loc = loc}
}

// st_text drains the context's transcript into one string.
st_text :: proc(c: ^Ctx) -> string {
	return strings.to_string(c.tr^)
}

// st_say is the old `say()`.
st_say :: proc(c: ^Ctx, msg: string) {
	if c.t != nil {
		support.note(c.t, msg, loc = c.loc)
	}
	if c.tr != nil {
		strings.write_string(c.tr, msg)
		strings.write_byte(c.tr, '\n')
	}
}

// st_check is the old `check()`: one counted assertion, plus the same line in
// the transcript so the printf guard sees the text the rule actually produced.
st_check :: proc(c: ^Ctx, name: string, cond: bool, detail: string) {
	if c.t != nil {
		support.check(c.t, name, cond, detail, loc = c.loc)
	}
	if c.tr != nil {
		verdict := "FAIL"
		if cond { verdict = "PASS" }
		if len(detail) == 0 {
			strings.write_string(c.tr, fmt.tprintf("[{}] {}", verdict, name))
		} else {
			strings.write_string(c.tr, fmt.tprintf("[{}] {} — {}", verdict, name, detail))
		}
		strings.write_byte(c.tr, '\n')
	}
}

//-----------------------------------------------------------------------------
// Fixture data
//
// ISC-A-3: no loopback fixture string appears in src/ at all, so the fixture
// hosts here are inert example domains. `Deploy@lab.example` is deliberately
// mixed-case so any accidental normalisation of the device string shows up as
// a failed equality check.
//-----------------------------------------------------------------------------

SM_TS         :: "2026-10-19-10-00-00-000"
SM_DEV_LAB    :: "lab.example"
SM_DEV_DEPLOY :: "Deploy@lab.example"
SM_DEV_BUILD  :: "build.example"
SM_DEFAULT_THEME :: "gruvbox-dark"

st_sessions :: proc() -> []app.Session {
	out: [dynamic]app.Session
	append(&out, app.Session{device = app.DEVICE_LOCAL, label = "local",
		name = fmt.tprintf("api-{}", SM_TS), running = true})
	append(&out, app.Session{device = app.DEVICE_LOCAL, label = "local",
		name = fmt.tprintf("db-{}", SM_TS), running = false})
	append(&out, app.Session{device = SM_DEV_LAB, label = "lab",
		name = fmt.tprintf("worker-{}", SM_TS), running = true})
	append(&out, app.Session{device = SM_DEV_DEPLOY, label = "deploy",
		name = fmt.tprintf("build-{}", SM_TS), running = false})
	return out[:]
}

// st_sessions_with_default is the ADVERSARIAL fixture: a producer that failed
// to filter `default` (D12) hands it to the machine anyway. The machine must
// still never issue a Command that targets it.
st_sessions_with_default :: proc() -> []app.Session {
	out: [dynamic]app.Session
	append(&out, app.Session{device = app.DEVICE_LOCAL, label = "local",
		name = fmt.tprintf("api-{}", SM_TS), running = true})
	append(&out, app.Session{device = app.DEVICE_LOCAL, label = "local",
		name = app.DEFAULT_SESSION_NAME, running = true})
	append(&out, app.Session{device = SM_DEV_LAB, label = "lab",
		name = fmt.tprintf("worker-{}", SM_TS), running = true})
	return out[:]
}

st_remotes :: proc() -> []app.Remote {
	out: [dynamic]app.Remote
	append(&out, app.Remote{device = SM_DEV_LAB, label = "lab"})
	append(&out, app.Remote{device = SM_DEV_DEPLOY, label = "deploy"})
	append(&out, app.Remote{device = SM_DEV_BUILD, label = ""})
	return out[:]
}

st_themes :: proc() -> []string {
	out: [dynamic]string
	append(&out, "gruvbox-dark")
	append(&out, "catppuccin-latte")
	append(&out, "solarized-dark")
	return out[:]
}

//-----------------------------------------------------------------------------
// Key construction + driving
//-----------------------------------------------------------------------------

st_kc     :: proc(ch: rune) -> input.Key { return input.char_key(ch) }
st_enter  :: input.Key{kind = .enter}
st_esc    :: input.Key{kind = .esc}
st_bsp    :: input.Key{kind = .backspace}
st_tab    :: input.Key{kind = .tab}
st_stab   :: input.Key{kind = .shift_tab}
st_up     :: input.Key{kind = .up}
st_down   :: input.Key{kind = .down}
st_ctrlc  :: input.Key{kind = .ctrl_c}

st_keys_of :: proc(word: string) -> []input.Key {
	out: [dynamic]input.Key
	for r in word { append(&out, st_kc(r)) }
	return out[:]
}

// st_drive feeds a key sequence and returns the LAST command issued.
st_drive :: proc(a: ^app.App, keys: []input.Key) -> app.Command {
	last := app.no_cmd()
	for k in keys {
		last = app.update(a, k)
	}
	return last
}

// st_prefix_for reaches `s` the way a USER would — through key presses from
// {Mode selection}, never by poking the struct. If a prefix does not land in
// `s`, that itself is the reachability failure and the caller reports it.
st_prefix_for :: proc(s: app.State) -> []input.Key {
	out: [dynamic]input.Key
	#partial switch s {
	case .mode_selection:
		// already there
	case .name_local:
		append(&out, st_kc('n'))
	case .remote_server:
		append(&out, st_kc('r'))
	case .name_remote_named:
		append(&out, st_kc('s'))
	case .attach:
		append(&out, st_kc('a'))
	case .delete_session:
		append(&out, st_kc('d'))
	case .theme:
		append(&out, st_kc('t'))
	case .error:
		append(&out, st_kc('n'))
		append(&out, ..st_keys_of("default"))
		append(&out, st_enter)
	}
	return out[:]
}

// st_new builds a fixture machine in state `s`, with a live selection when the
// state has a list. Everything — the state AND the selection — arrives through
// keys, so a cell of the matrix is "what the user's fingers would cause".
//
// The `a.sel < 0` guard is RCH-3/R4: entering a state with a non-empty list
// now HIGHLIGHTS THE FIRST ROW, so a selection already exists and the driver
// must not press Down on top of it.
st_new :: proc(s: app.State, select_item: bool) -> app.App {
	a := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&a, st_prefix_for(s))
	if select_item && app.state_is_filter_view(a.state) && a.sel < 0 {
		app.update(&a, st_down)
	}
	return a
}

//-----------------------------------------------------------------------------
// Little reporting helpers
//-----------------------------------------------------------------------------

st_code :: proc(s: app.State) -> string {
	#partial switch s {
	case .mode_selection:    return "MS"
	case .name_local:        return "NL"
	case .remote_server:     return "RS"
	case .name_remote_named: return "NR"
	case .attach:            return "AT"
	case .delete_session:    return "DL"
	case .theme:             return "TH"
	case .error:             return "ER"
	}
	return "?"
}

st_cmd_code :: proc(k: app.Cmd_Kind) -> string {
	#partial switch k {
	case .none:          return "-"
	case .launch_local:   return "loc"
	case .launch_remote:  return "rem"
	case .attach:        return "att"
	case .delete:        return "del"
	case .set_theme:     return "thm"
	case .show_error:    return "err"
	case .clear_filter:  return "cf"
	case .clear_field:   return "cd"
	case .quit:          return "quit"
	}
	return "?"
}

// st_pad right-pads by hand: Odin's fmt has no `{:6}` width spec, and `string
// + string` is illegal, so every pad is a fresh tprintf.
st_pad :: proc(s: string, w: int) -> string {
	out := s
	for i := len(s); i < w; i += 1 {
		out = fmt.tprintf("{} ", out)
	}
	return out
}

// st_expect_state checks the machine landed exactly where the spec says.
st_expect_state :: proc(c: ^Ctx, what: string, got, want: app.State, extra: string) {
	st_check(c, what, got == want, fmt.tprintf("reached {} want {}   {}",
		app.state_label(got), app.state_label(want), extra))
}

st_expect_cmd :: proc(c: ^Ctx, what: string, got: app.Command, want: app.Cmd_Kind, extra: string) {
	st_check(c, what, got.kind == want, fmt.tprintf("cmd {} want {}   {}",
		app.cmd_kind_label(got.kind), app.cmd_kind_label(want), extra))
}

// st_expect_noop is the spec's "pressing the key does nothing", asserted as
// BOTH halves: no command AND no state change.
st_expect_noop :: proc(c: ^Ctx, what: string, cmd: app.Command, state_now: app.State, was: app.State) {
	st_check(c, what, cmd.kind == .none && state_now == was,
		fmt.tprintf("cmd={} state={} (want none/{} unchanged)",
			app.cmd_kind_label(cmd.kind), app.state_label(state_now), app.state_label(was)))
}

// st_expect_cell re-probes one (state, key) pair and asserts state + command.
st_expect_cell :: proc(c: ^Ctx, from: app.State, select_item: bool, k: input.Key, label: string,
                     want: app.State, want_cmd: app.Cmd_Kind) {
	m := st_new(from, select_item)
	cmd := app.update(&m, k)
	st_check(c, fmt.tprintf("  [{}]+{} -> {} {}", app.state_label(from), label,
		app.state_label(want), app.cmd_kind_label(want_cmd)),
		m.state == want && cmd.kind == want_cmd,
		fmt.tprintf("got {}/{}", app.state_label(m.state), app.cmd_kind_label(cmd.kind)))
}

// st_contains_session_name is a membership probe over the fixture, used to
// prove a generated name is genuinely new rather than a row the user was
// looking at.
st_contains_session_name :: proc(rows: []app.Session, name: string) -> bool {
	for r in rows {
		if r.name == name { return true }
	}
	return false
}

//-----------------------------------------------------------------------------
// [1] keymap — tb_event fields -> Key
//-----------------------------------------------------------------------------

st_sec_keymap :: proc(c: ^Ctx) {
	st_say(c, "  [1] keymap — tb_event fields -> Key")

	// Ctrl+C is byte 0x03. cfmakeraw cleared ISIG, so it is DATA, and it must
	// arrive as a Key rather than as a signal we could miss.
	kk := input.decode(termbox2.EVENT_KEY, termbox2.KEY_CTRL_C, 0, 0)
	st_check(c, "0x03 decodes to ctrl_c (ISIG is off, so it is data)",
		kk.kind == .ctrl_c, fmt.tprintf("kind={}", kk.kind))
	kb := input.decode(termbox2.EVENT_KEY, 0x03, 0, 0)
	st_check(c, "the raw byte 0x03 in `key` decodes to ctrl_c too",
		kb.kind == .ctrl_c, fmt.tprintf("kind={}", kb.kind))

	// Legacy ESC: one code, immediate, no sequence-wait timer involved.
	ke := input.decode(termbox2.EVENT_KEY, termbox2.KEY_ESC, 0, 0)
	st_check(c, "TB_KEY_ESC decodes to esc (legacy, no timeout)", ke.kind == .esc,
		fmt.tprintf("kind={}", ke.kind))

	st_check(c, "TAB decodes to tab",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_TAB, 0, 0).kind == .tab, "")
	st_check(c, "TAB + MOD_SHIFT decodes to shift_tab",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_TAB, 0, termbox2.MOD_SHIFT).kind == .shift_tab,
		fmt.tprintf("kind={}", input.decode(termbox2.EVENT_KEY, termbox2.KEY_TAB, 0, termbox2.MOD_SHIFT).kind))
	st_check(c, "BACK_TAB (CSI Z) decodes to shift_tab",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_BACK_TAB, 0, 0).kind == .shift_tab, "")
	st_check(c, "CR decodes to enter",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_ENTER, 0, 0).kind == .enter, "")
	st_check(c, "LF decodes to enter as well",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_CTRL_J, 0, 0).kind == .enter, "")
	st_check(c, "0x7f decodes to backspace",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_BACKSPACE2, 0, 0).kind == .backspace, "")
	st_check(c, "0x08 (Ctrl-H) decodes to backspace",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_BACKSPACE, 0, 0).kind == .backspace, "")

	// KEY_DELETE (`CSI 3 ~` — the Del key, fn+Delete on a Mac) is RCH-3/R3.
	// It used to fall through to `.none`, `ch == 0`, and decode to NO_KEY: the
	// keypress was silently dropped and the filter never shortened.
	kd := input.decode(termbox2.EVENT_KEY, termbox2.KEY_DELETE, 0, 0)
	st_check(c, "KEY_DELETE (CSI 3 ~) decodes to backspace (R3)", kd.kind == .backspace,
		fmt.tprintf("kind={} code=0x{}", kd.kind, fmt.tprintf("%04X", termbox2.KEY_DELETE)))
	st_check(c, "…and it is NOT the no-key it used to be", kd.kind != .none, "")

	// The codes this file DELIBERATELY leaves unmapped, so "we checked for other
	// dropped edit keys" is a recorded decision and not a guess.
	st_check(c, "KEY_INSERT stays a deliberate no-op (no overwrite mode exists)",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_INSERT, 0, 0).kind == .none, "")
	st_check(c, "KEY_HOME stays a deliberate no-op (no caret-in-the-middle model)",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_HOME, 0, 0).kind == .none, "")
	st_check(c, "KEY_END stays a deliberate no-op (same reason)",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_END, 0, 0).kind == .none, "")
	st_check(c, "arrow down decodes to down",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_ARROW_DOWN, 0, 0).kind == .down, "")

	ka := input.decode(termbox2.EVENT_KEY, 0, 'a', 0)
	st_check(c, "'a' decodes to character 'a'", ka.kind == .character && ka.r == 'a',
		fmt.tprintf("kind={} r={}", ka.kind, ka.r))
	kcjk := input.decode(termbox2.EVENT_KEY, 0, 0x4E16, 0)
	st_check(c, "a multi-byte rune arrives decoded in `ch` (世)",
		kcjk.kind == .character && kcjk.r == 0x4E16,
		fmt.tprintf("kind={} r=U+{}", kcjk.kind, fmt.tprintf("%04X", kcjk.r)))
	st_check(c, "a control byte in `ch` is never user text (BEL)",
		input.decode(termbox2.EVENT_KEY, 0, 0x07, 0).kind == .none, "")
	st_check(c, "a RESIZE event produces no key",
		input.decode(termbox2.EVENT_RESIZE, 0, 0, 0).kind == .none, "")

	ev := termbox2.Event{typ = termbox2.EVENT_KEY, key = termbox2.KEY_CTRL_C}
	st_check(c, "from_event reads the struct fields, not a copy of them",
		input.from_event(&ev).kind == .ctrl_c, "")
}

//-----------------------------------------------------------------------------
// [2] the matrix
//-----------------------------------------------------------------------------

St_Key_Cell :: struct {
	label : string,
	k     : input.Key,
}

st_states :: proc() -> []app.State {
	out: [dynamic]app.State
	append(&out, app.State.mode_selection, app.State.name_local,
		app.State.remote_server, app.State.name_remote_named)
	append(&out, app.State.attach, app.State.delete_session,
		app.State.theme, app.State.error)
	return out[:]
}

// st_print_grid runs EVERY (state, key) pair through a fresh machine and prints
// the cell as `state_reached/command_issued`. Nothing here asserts: the grid is
// the evidence (ISC-3), st_spec_cells below is the contract.
st_print_grid :: proc(c: ^Ctx, title: string, states: []app.State, cols: []St_Key_Cell) {
	st_say(c, fmt.tprintf("    {}", title))
	line := st_pad("    state", 22)
	for col in cols {
		line = fmt.tprintf("{}{}", line, st_pad(col.label, 10))
	}
	st_say(c, line)
	for s in states {
		row := st_pad(fmt.tprintf("    {}", app.state_label(s)), 22)
		for col in cols {
			m := st_new(s, true)
			cmd := app.update(&m, col.k)
			row = fmt.tprintf("{}{}", row, st_pad(fmt.tprintf("{}/{}",
				st_code(m.state), st_cmd_code(cmd.kind)), 10))
		}
		st_say(c, row)
	}
}

st_sec_matrix :: proc(c: ^Ctx) {
	st_say(c, "  [2] full (state x key) grid — state reached / command issued")

	states := st_states()
	spec_keys := []St_Key_Cell{
		{"enter", st_enter}, {"n", st_kc('n')}, {"r", st_kc('r')}, {"s", st_kc('s')},
		{"a", st_kc('a')}, {"d", st_kc('d')}, {"t", st_kc('t')}, {"esc", st_esc}, {"^C", st_ctrlc},
	}
	list_keys := []St_Key_Cell{
		{"down", st_down}, {"up", st_up}, {"tab", st_tab}, {"s-tab", st_stab},
		{"bs", st_bsp}, {"'x'", st_kc('x')},
	}

	st_print_grid(c, "spec keys:", states, spec_keys)
	st_print_grid(c, "list / edit keys (each row entered from {Mode selection} by its key, then one item selected):",
		states, list_keys)
	st_say(c, "    legend: MS mode_selection · NL name_local · RS remote_server · NR name_remote_named")
	st_say(c, "            AT attach · DL delete_session · TH theme · ER error")
	st_say(c, "            loc launch_local · rem launch_remote · att attach · del delete · thm set_theme")
	st_say(c, "            err show_error · cf clear_filter · cd clear_field · quit quit · - no command")

	st_sec_spec_cells(c)
}

// st_sec_spec_cells is the transition table of plan §State transitions,
// asserted cell by cell against a fresh machine per cell. 17 assertions.
st_sec_spec_cells :: proc(c: ^Ctx) {
	st_say(c, "    spec assertions (plan §State transitions):")

	// {Mode selection}
	st_expect_cell(c, .mode_selection, false, st_enter, "Enter", .mode_selection, .launch_local)
	st_expect_cell(c, .mode_selection, false, st_kc('n'), "n", .name_local, .none)
	st_expect_cell(c, .mode_selection, false, st_kc('r'), "r", .remote_server, .none)
	st_expect_cell(c, .mode_selection, false, st_kc('s'), "s", .name_remote_named, .none)
	st_expect_cell(c, .mode_selection, false, st_kc('a'), "a", .attach, .none)
	st_expect_cell(c, .mode_selection, false, st_kc('d'), "d", .delete_session, .none)
	st_expect_cell(c, .mode_selection, false, st_kc('t'), "t", .theme, .none)
	st_expect_cell(c, .mode_selection, false, st_esc, "Esc", .mode_selection, .quit)

	// {Select name of new local session} — with a name typed.
	{
		m := st_new(.name_local, false)
		st_drive(&m, st_keys_of("api"))
		cmd := app.update(&m, st_enter)
		st_check(c, "  [name_local]+Enter -> launch_local \"<typed>-<ts>\"",
			cmd.kind == .launch_local && strings.has_prefix(cmd.name, "api-") &&
				m.state == .mode_selection,
			fmt.tprintf("cmd={} name={} state={}",
				app.cmd_kind_label(cmd.kind), cmd.name, app.state_label(m.state)))
	}

	// {Select remote server…} with a host selected.
	st_expect_cell(c, .remote_server, true, st_enter, "Enter", .mode_selection, .launch_remote)

	// {Select session to attach} with a row selected.
	st_expect_cell(c, .attach, true, st_enter, "Enter", .mode_selection, .attach)

	// {Select session to delete}: the delete is issued and the user STAYS — the
	// list refreshes under them and they keep cleaning up.
	st_expect_cell(c, .delete_session, true, st_enter, "Enter", .delete_session, .delete)

	// {Select theme}: Enter applies AND clears the filter AND returns.
	{
		m := st_new(.theme, true)
		picked := ""
		if idx, ok := app.active_index(&m); ok && idx < len(st_themes()) {
			picked = st_themes()[idx]
		}
		cmd := app.update(&m, st_enter)
		st_check(c, "  [theme]+Enter -> set_theme + mode_selection + filter cleared",
			cmd.kind == .set_theme && cmd.value == picked && m.state == .mode_selection &&
				m.filter.len == 0 && m.theme == picked,
			fmt.tprintf("cmd={} value={} theme={} state={} filter={}",
				app.cmd_kind_label(cmd.kind), cmd.value, m.theme,
				app.state_label(m.state), m.filter.len))
	}

	// {Error}
	st_expect_cell(c, .error, false, st_enter, "Enter", .mode_selection, .none)
	st_expect_cell(c, .error, false, st_esc, "Esc", .mode_selection, .none)

	// The edit states' Escape semantics (clears the field, returns to the root).
	{
		m := st_new(.name_local, false)
		st_drive(&m, st_keys_of("api"))
		cmd := app.update(&m, st_esc)
		st_check(c, "  [name_local]+Esc -> clear_field + mode_selection",
			cmd.kind == .clear_field && m.state == .mode_selection && m.field.len == 0,
			fmt.tprintf("cmd={} state={} field={}",
				app.cmd_kind_label(cmd.kind), app.state_label(m.state), m.field.len))
	}

	// Leaving a filtered state clears the filter.
	{
		m := st_new(.attach, true)
		st_drive(&m, st_keys_of("api"))
		cmd := app.update(&m, st_esc)
		st_check(c, "  [attach]+Esc -> clear_filter + mode_selection",
			cmd.kind == .clear_filter && m.state == .mode_selection && m.filter.len == 0,
			fmt.tprintf("cmd={} state={} filter={}",
				app.cmd_kind_label(cmd.kind), app.state_label(m.state), m.filter.len))
	}
}

//-----------------------------------------------------------------------------
// [3] reachability (ISC-3)
//-----------------------------------------------------------------------------

St_Reach :: struct {
	key  : rune,
	want : app.State,
}

st_sec_reachability :: proc(c: ^Ctx) {
	st_say(c, "  [3] every state is reachable from {Mode selection} with the spec's key")

	reach := []St_Reach{
		{'n', .name_local},
		{'r', .remote_server},
		{'s', .name_remote_named},
		{'a', .attach},
		{'d', .delete_session},
		{'t', .theme},
	}
	for r in reach {
		a := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
		cmd := app.update(&a, st_kc(r.key))
		st_check(c, fmt.tprintf("[{}] reaches {}", r.key, app.state_label(r.want)),
			a.state == r.want && cmd.kind == .none,
			fmt.tprintf("reached {} cmd={}", app.state_label(a.state), app.cmd_kind_label(cmd.kind)))
	}

	// The root state itself, and {Error} via a failing action.
	root := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_check(c, "mode_selection is the start state", root.state == .mode_selection,
		fmt.tprintf("started in {}", app.state_label(root.state)))

	bad := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&bad, st_keys_of("n"))
	st_drive(&bad, st_keys_of("default"))
	enter_cmd := app.update(&bad, st_enter)
	st_check(c, "error is reachable (n + 'default' + Enter is refused into {Error})",
		bad.state == .error && enter_cmd.kind == .show_error,
		fmt.tprintf("reached {} cmd={}", app.state_label(bad.state), app.cmd_kind_label(enter_cmd.kind)))
	st_check(c, "the error message says why",
		strings.contains(enter_cmd.value, "default"),
		fmt.tprintf("message = %q", enter_cmd.value))
}

//-----------------------------------------------------------------------------
// [4] the resolved [s] two-step
//-----------------------------------------------------------------------------

st_sec_two_step :: proc(c: ^Ctx) {
	st_say(c, "  [4] the [s] two-step, end to end (name first, THEN the server)")

	// Step-by-step, with the machine inspected between every key, because the
	// whole risk of this path is the name being lost or mangled at the hop.
	a := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)

	st_drive(&a, []input.Key{st_kc('s')})
	st_expect_state(c, "[s] opens {name_remote_named}", a.state, .name_remote_named, "1/4")

	st_drive(&a, st_keys_of("api"))
	st_check(c, "  typed name is in the field", app.text_of(&a.field) == "api",
		fmt.tprintf("field = %q", app.text_of(&a.field)))

	cmd := app.update(&a, st_enter)
	st_expect_state(c, "  [Enter] carries the name into {remote_server}", a.state, .remote_server, "2/4")
	st_check(c, "  the name was carried (not dropped, not consumed)", a.carried_name == "api",
		fmt.tprintf("carried_name = %q", a.carried_name))
	st_check(c, "  no launch happened yet at the hop", cmd.kind == .none,
		fmt.tprintf("cmd = {}", app.cmd_kind_label(cmd.kind)))

	// RCH-3/R4: entering {remote_server} now highlights the FIRST host, so the
	// pick is already made — no Down needed. Which row the cursor is on is
	// exactly what decides which device gets launched.
	st_check(c, "  [entry] highlights the FIRST host (R4: something is always highlighted)",
		a.sel == 0 && app.shown_count(&a) == 3 && a.cursor_id == SM_DEV_LAB,
		fmt.tprintf("sel={} shown={} cursor_id=%q", a.sel, app.shown_count(&a), a.cursor_id))

	cmd = app.update(&a, st_enter)
	st_expect_state(c, "  [Enter] leaves for the launch", a.state, .mode_selection, "4/4")
	st_expect_cmd(c, "  the command is launch_remote", cmd, .launch_remote, "")
	st_check(c, "  it carries BOTH the carried name and the device",
		cmd.device == SM_DEV_LAB && strings.has_prefix(cmd.name, "api-"),
		fmt.tprintf("device=%q name=%q", cmd.device, cmd.name))
	st_check(c, "  the name kept the cycle-timestamp shape (D11)",
		app.ts_is_known(app.ts_from_name(cmd.name)),
		fmt.tprintf("name=%q ts parses=%v", cmd.name, app.ts_is_known(app.ts_from_name(cmd.name))))
	st_check(c, "  the device is VERBATIM, not normalised (ISC-4)",
		cmd.device == "lab.example",
		fmt.tprintf("device=%q", cmd.device))

	// Same path, but the host is found by filtering — and to a target string with
	// MIXED CASE, so a lowercase-everything shortcut cannot pass.
	b := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&b, []input.Key{st_kc('s')})
	st_drive(&b, st_keys_of("web"))
	app.update(&b, st_enter)
	st_drive(&b, st_keys_of("deploy@"))
	matched := app.shown_count(&b)
	st_check(c, "  the filter narrows the host list to 1", matched == 1,
		fmt.tprintf("shown={} (filter=%q)", matched, app.text_of(&b.filter)))
	app.update(&b, st_down)
	cmd = app.update(&b, st_enter)
	st_expect_cmd(c, "  filtered pick still launches remote", cmd, .launch_remote, "")
	st_check(c, "  device survives the round trip EXACTLY as configured",
		cmd.device == "Deploy@lab.example",
		fmt.tprintf("device=%q want %q", cmd.device, "Deploy@lab.example"))
	st_check(c, "  and the typed name is what got carried",
		strings.has_prefix(cmd.name, "web-"),
		fmt.tprintf("name=%q", cmd.name))

	// The unnamed remote path ([r]) must still work with no carried name.
	d := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&d, []input.Key{st_kc('r')})
	cmd = app.update(&d, st_enter)
	st_expect_cmd(c, "  [r] (unnamed remote) launches with a timestamp-only name", cmd, .launch_remote, "")
	st_check(c, "  no carried name leaked into the [r] path",
		d.carried_name == "" && app.ts_is_known(app.ts_from_name(cmd.name)),
		fmt.tprintf("carried=%q name=%q", d.carried_name, cmd.name))
}

//-----------------------------------------------------------------------------
// [5] empty-field Enter is a no-op
//-----------------------------------------------------------------------------

st_sec_empty_field_noop :: proc(c: ^Ctx) {
	st_say(c, "  [5] empty edit field + Enter does nothing (spec: 'pressing the key does nothing')")

	a := st_new(.name_local, false)
	cmd := app.update(&a, st_enter)
	st_expect_noop(c, "name_local: empty field + Enter", cmd, a.state, .name_local)

	// Type then erase: empty is empty whether it started that way or not.
	st_drive(&a, st_keys_of("ab"))
	app.update(&a, st_bsp)
	app.update(&a, st_bsp)
	st_check(c, "  field is empty again after two backspaces", app.text_of(&a.field) == "",
		fmt.tprintf("field=%q", app.text_of(&a.field)))
	cmd = app.update(&a, st_enter)
	st_expect_noop(c, "name_local: typed-then-erased + Enter", cmd, a.state, .name_local)

	// Same rule on the named-remote edit: nothing typed = nothing to carry.
	bare := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	app.update(&bare, st_kc('s'))
	cmd = app.update(&bare, st_enter)
	st_expect_noop(c, "name_remote_named: empty field + Enter", cmd, bare.state, .name_remote_named)
	st_check(c, "  and nothing was carried", bare.carried_name == "",
		fmt.tprintf("carried=%q", bare.carried_name))

	// Whole-rune backspace, so "erased" means erased and not "one broken byte left".
	e := st_new(.name_local, false)
	st_drive(&e, st_keys_of("a世b😀"))
	st_check(c, "  non-charset runes are rejected at input (names are [A-Za-z0-9._-])",
		app.text_of(&e.field) == "ab",
		fmt.tprintf("field=%q", app.text_of(&e.field)))
	st_check(c, "  a rejected rune leaves the field byte-exact", app.text_of(&e.field) == "ab",
		fmt.tprintf("field=%q len={}", app.text_of(&e.field), e.field.len))
	app.update(&e, st_bsp)
	st_check(c, "  backspace removes exactly the LAST rune, not a byte",
		app.text_of(&e.field) == "a",
		fmt.tprintf("field=%q len={}", app.text_of(&e.field), e.field.len))

	// Whole-rune backspace where multi-byte runes actually live: the FILTER line
	// (name fields reject non-ASCII, filters do not). One backspace must remove
	// all THREE bytes of a CJK rune; a one-byte delete would leave continuation
	// bytes that render as garbage.
	f := st_new(.attach, false)
	st_drive(&f, st_keys_of("a世"))
	st_check(c, "  the filter accepted the multi-byte rune", f.filter.len == 4,
		fmt.tprintf("filter=%q bytes={}", app.text_of(&f.filter), f.filter.len))
	app.update(&f, st_bsp)
	st_check(c, "  one backspace removed the WHOLE 3-byte rune", f.filter.len == 1,
		fmt.tprintf("filter=%q bytes={}", app.text_of(&f.filter), f.filter.len))
	app.update(&f, st_bsp)
	st_check(c, "  and the filter is truly empty — no dangling continuation byte",
		f.filter.len == 0 && app.text_of(&f.filter) == "",
		fmt.tprintf("filter=%q bytes={}", app.text_of(&f.filter), f.filter.len))
}

//-----------------------------------------------------------------------------
// [6] no-selection Enter is a no-op
//-----------------------------------------------------------------------------

st_sec_no_selection_noop :: proc(c: ^Ctx) {
	st_say(c, "  [6] Enter with NOTHING selected does nothing, in every list state")

	list_states := []app.State{.remote_server, .attach, .delete_session, .theme}
	for s in list_states {
		// Enter straight away: the machine entered the state with no selection.
		m := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
		st_drive(&m, st_prefix_for(s))
		// The theme picker pre-selects the live theme (spec), so filter it away
		// first to reach a genuinely unselected state in every case.
		st_drive(&m, st_keys_of("zzzznomatch"))
		st_check(c, fmt.tprintf("  {} starts with no selection", app.state_label(s)),
			m.sel == -1 && app.shown_count(&m) == 0,
			fmt.tprintf("sel={} shown={}", m.sel, app.shown_count(&m)))
		cmd := app.update(&m, st_enter)
		st_expect_noop(c, fmt.tprintf("{}: Enter with no selection", app.state_label(s)),
			cmd, m.state, s)
	}
}

//-----------------------------------------------------------------------------
// [7] Ctrl+C from everywhere (ISC-12)
//-----------------------------------------------------------------------------

st_sec_ctrl_c_everywhere :: proc(c: ^Ctx) {
	st_say(c, "  [7] Ctrl+C -> quit from every state (ISC-12)")

	all := []app.State{
		.mode_selection, .name_local, .remote_server, .name_remote_named,
		.attach, .delete_session, .theme, .error,
	}
	quit_count := 0
	for s in all {
		m := st_new(s, true)
		cmd := app.update(&m, st_ctrlc)
		quit := cmd.kind == .quit
		if quit { quit_count += 1 }
		st_check(c, fmt.tprintf("  {} + ^C -> quit", app.state_label(s)), quit,
			fmt.tprintf("cmd={}", app.cmd_kind_label(cmd.kind)))
	}
	st_check(c, "  all 8 states answered quit", quit_count == len(all),
		fmt.tprintf("{}/{} quit", quit_count, len(all)))
}

//-----------------------------------------------------------------------------
// [8] Esc is back
//-----------------------------------------------------------------------------

st_sec_esc_back :: proc(c: ^Ctx) {
	st_say(c, "  [8] Esc is back-to-{Mode selection}, and leaves nothing dirty")

	back_states := []app.State{.name_local, .name_remote_named, .remote_server,
		.attach, .delete_session, .theme, .error}
	// The uniform clearing rule (see the header of app/state.odin): leaving an
	// EDIT state reports `clear_field`, leaving a FILTER state reports
	// `clear_filter`, and {Error} reports nothing because it owns neither.
	want_kind := proc(s: app.State) -> app.Cmd_Kind {
		if app.state_is_edit_view(s) { return .clear_field }
		if app.state_is_filter_view(s) { return .clear_filter }
		return .none
	}
	for s in back_states {
		// Enter with SOME text/selection in place, so "cleared" is a real claim.
		m := st_new(s, true)
		cmd := app.update(&m, st_esc)
		st_check(c, fmt.tprintf("  {} + Esc -> mode_selection", app.state_label(s)),
			m.state == .mode_selection,
			fmt.tprintf("reached {} cmd={}", app.state_label(m.state), app.cmd_kind_label(cmd.kind)))
		st_check(c, fmt.tprintf("    and reports %s for the text it owns",
			app.cmd_kind_label(want_kind(s))),
			cmd.kind == want_kind(s),
			fmt.tprintf("cmd={}", app.cmd_kind_label(cmd.kind)))
		st_check(c, "    filter and field are both empty after the way back",
			m.filter.len == 0 && m.field.len == 0 && m.carried_name == "",
			fmt.tprintf("filter={} field={} carried=%q", m.filter.len, m.field.len, m.carried_name))
	}

	// The root has no back — Esc there is the exit key.
	root := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_check(c, "  mode_selection + Esc -> quit (no back from the root)",
		app.update(&root, st_esc).kind == .quit, "")
}

//-----------------------------------------------------------------------------
// [9] the selection identity does not slide
//-----------------------------------------------------------------------------

st_sec_identity_not_sliding :: proc(c: ^Ctx) {
	st_say(c, "  [9] a filtered-out selection DROPS, it never slides onto a neighbour")

	// In {Select session to attach}: select the `api` row, then filter it away.
	m := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&m, []input.Key{st_kc('a')})
	st_drive(&m, st_keys_of("api-"))
	app.update(&m, st_down)
	st_check(c, "  holding api-… (local)",
		m.held.valid && m.held.name == fmt.tprintf("api-{}", SM_TS),
		fmt.tprintf("held=%s/%s", m.held.device, m.held.name))

	st_drive(&m, st_keys_of("zz")) // filter no longer matches the held row
	st_check(c, "  after the filter drops the held row, the selection is EMPTY, not moved",
		m.held == app.NO_SELECTION || !m.held.valid,
		fmt.tprintf("held.valid={} held.name={}", m.held.valid, m.held.name))
	cmd := app.update(&m, st_enter)
	st_expect_noop(c, "  Enter on that dropped selection is a no-op", cmd, m.state, .attach)

	// Widen the filter again: the identity is re-resolved, not guessed.
	app.update(&m, st_bsp)
	app.update(&m, st_bsp)
	kept := app.shown_count(&m)
	st_check(c, "  erasing the extra chars brings the row back into view", kept == 1,
		fmt.tprintf("shown={} (filter=%q)", kept, app.text_of(&m.filter)))
	app.update(&m, st_down)
	cmd = app.update(&m, st_enter)
	st_check(c, "  and picking it attaches the SAME identity that came back",
		cmd.kind == .attach && cmd.name == fmt.tprintf("api-{}", SM_TS),
		fmt.tprintf("cmd={} name={}", app.cmd_kind_label(cmd.kind), cmd.name))

	// The command's device must be the row's OWN device string, never inferred
	// from a label, a hostname, or the session name.
	p := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&p, []input.Key{st_kc('a')})
	st_drive(&p, st_keys_of("@"))
	st_check(c, "  '@' narrows the sessions to the single mixed-case remote row",
		app.shown_count(&p) == 1, fmt.tprintf("shown={}", app.shown_count(&p)))
	app.update(&p, st_down)
	cmd = app.update(&p, st_enter)
	st_check(c, "  attach carries the FILTERED row's verbatim device",
		cmd.kind == .attach && cmd.device == SM_DEV_DEPLOY &&
			cmd.name == fmt.tprintf("build-{}", SM_TS),
		fmt.tprintf("cmd={} device=%q name=%q",
			app.cmd_kind_label(cmd.kind), cmd.device, cmd.name))
}

//-----------------------------------------------------------------------------
// [9b] R2: the filter belongs to EXACTLY FOUR states — THE INVERTED TEST
//-----------------------------------------------------------------------------

st_sec_r2_filter_owns_four :: proc(c: ^Ctx) {
	st_say(c, "  [9b] R2: filter typing is bound in FOUR states, and NOT in {Mode selection}")

	// The predicate is the single source of truth for the four-state rule, so the
	// spec list and the code cannot drift apart silently.
	editable := []app.State{.remote_server, .attach, .delete_session, .theme}
	for s in editable {
		st_check(c, fmt.tprintf("  {} OWNS the filter-typing binding", app.state_label(s)),
			app.state_filter_is_editable(s), "")
	}
	non_editable := []app.State{.mode_selection, .name_local, .name_remote_named, .error}
	for s in non_editable {
		st_check(c, fmt.tprintf("  {} does NOT own it", app.state_label(s)),
			!app.state_filter_is_editable(s), "")
	}

	// THE INVERTED BEHAVIOUR CHECK. In {Mode selection} an unclaimed printable
	// key must leave the filter empty and the visible list untouched. "x" is
	// deliberately not a mode key.
	m := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	app.rebuild_shown(&m)
	before := app.shown_count(&m)
	stray := "xq/_.1234567890 "
	changed := 0
	issued := 0
	for r in stray {
		if app.update(&m, st_kc(r)).kind != .none { issued += 1 }
		if m.filter.len != 0 { changed += 1 }
	}
	st_check(c, "  typing 16 unclaimed keys in [Mode selection] leaves the filter EMPTY",
		changed == 0 && m.filter.len == 0,
		fmt.tprintf("{} of {} keys touched the filter; filter=%q",
			changed, len(stray), app.text_of(&m.filter)))
	st_check(c, "  …and none of them issued a Command or moved the visible list",
		issued == 0 && app.shown_count(&m) == before && before == len(st_sessions()),
		fmt.tprintf("commands issued={} shown={} sessions={}",
			issued, app.shown_count(&m), len(st_sessions())))

	// …while the SIX mode keys still work from the same machine, immediately
	// after the stray typing, with no residue.
	modes := []St_Reach{
		{'n', .name_local}, {'r', .remote_server}, {'s', .name_remote_named},
		{'a', .attach}, {'d', .delete_session}, {'t', .theme},
	}
	for m2 in modes {
		x := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
		st_drive(&x, st_keys_of(stray))
		cmd := app.update(&x, st_kc(m2.key))
		st_check(c, fmt.tprintf("  [{}] still reaches {} after stray typing",
			m2.key, app.state_label(m2.want)),
			x.state == m2.want && cmd.kind == .none && x.filter.len == 0,
			fmt.tprintf("state={} cmd={} filter=%q", app.state_label(x.state),
				app.cmd_kind_label(cmd.kind), app.text_of(&x.filter)))
	}

	// And in each of the FOUR filter states the SAME typed character DOES filter.
	for s in editable {
		f := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
		st_drive(&f, st_prefix_for(s))
		total := app.shown_count(&f)
		probe := st_filter_probe_for(s)
		for r in probe { app.update(&f, st_kc(r)) }
		after := app.shown_count(&f)
		st_check(c, fmt.tprintf("  typing %q in {} narrows {} rows -> {} rows",
			probe, app.state_label(s), total, after),
			after < total && len(app.text_of(&f.filter)) == len(probe),
			fmt.tprintf("filter=%q shown {} -> {}", app.text_of(&f.filter), total, after))
	}
}

// st_filter_probe_for picks a substring that narrows the ACTIVE list of `s`
// without emptying it, so "it filters" and "it filters to nothing" stay
// distinguishable.
st_filter_probe_for :: proc(s: app.State) -> string {
	#partial switch s {
	case .remote_server:  return "lab"
	case .attach:         return "lab"
	case .delete_session: return "local"
	case .theme:         return "cat"
	}
	return ""
}

//-----------------------------------------------------------------------------
// [9c] R4: the highlighted row IS the selection
//-----------------------------------------------------------------------------

st_sec_r4_highlight :: proc(c: ^Ctx) {
	st_say(c, "  [9c] R4: a non-empty list is ALWAYS highlighted, and the highlight IS the selection")

	// (1) Entering a PICKER highlights the FIRST row. Scoped to the picker
	//     states by RCH-4: {Mode selection} is deliberately NOT in this list
	//     and is asserted to be the OPPOSITE in st_sec_rch4.
	session_views := []app.State{.attach, .delete_session}
	for s in session_views {
		m := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
		st_drive(&m, st_prefix_for(s))
		first := m.sessions[m.shown[0]]
		st_check(c, fmt.tprintf("  entering {} highlights row 0 and held == it",
			app.state_label(s)),
			m.sel == 0 && m.held.valid && m.held.device == first.device &&
				m.held.name == first.name,
			fmt.tprintf("sel={} held={}/{} first={}/{}",
				m.sel, m.held.device, m.held.name, first.device, first.name))
	}

	// (2) The remote picker highlights the first host on entry.
	r := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&r, []input.Key{st_kc('r')})
	st_check(c, "  entering {remote_server} highlights the first host and cursor_id == it",
		r.sel == 0 && r.cursor_id == r.remotes[r.shown[0]].device,
		fmt.tprintf("sel={} cursor_id=%q first=%q",
			r.sel, r.cursor_id, r.remotes[r.shown[0]].device))

	// (3) The THEME picker opens on the APPLIED theme, not on row 0. The fixture
	//     default theme is "gruvbox-dark" (index 0), so the theme list is walked
	//     from a NON-zero-theme default to prove it is identity, not position.
	t := app.new_app(st_sessions(), st_remotes(), st_themes(), "solarized-dark")
	app.update(&t, st_kc('t'))
	st_check(c, "  the theme picker opens on the APPLIED theme (not row 0)",
		t.sel == 2 && t.themes[t.shown[t.sel]] == "solarized-dark",
		fmt.tprintf("sel={} shown@sel={}", t.sel, t.themes[t.shown[t.sel]]))

	// (4) A filter that EXCLUDES the applied theme falls back to the first
	//     visible row, and the selection moves with it.
	app.update(&t, st_kc('c'))
	st_check(c, "  a filter excluding the applied theme keeps a highlight (sel >= 0)",
		t.sel >= 0 && app.shown_count(&t) > 0 &&
			t.themes[t.shown[t.sel]] != "solarized-dark",
		fmt.tprintf("sel={} shown={} @sel={}", t.sel, app.shown_count(&t),
			t.themes[t.shown[t.sel]]))
	st_check(c, "  …and cursor_id re-synced to the HIGHLIGHTED theme, not the gone one",
		t.cursor_id == t.themes[t.shown[t.sel]] && t.cursor_id != "solarized-dark",
		fmt.tprintf("cursor_id=%q @sel=%q", t.cursor_id, t.themes[t.shown[t.sel]]))

	// (5) THE PHANTOM-ROW GUARD. Filter away the held row in {Attach} while a
	//     second row survives, then press Enter: the command MUST name the row
	//     that is highlighted, never the row that was filtered away.
	g := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&g, []input.Key{st_kc('a')})
	held_before := g.held.name
	high_before := g.sessions[g.shown[g.sel]].name
	st_check(c, "  starting state: the highlight and held agree",
		held_before == high_before && g.sel == 0,
		fmt.tprintf("held=%q highlighted=%q sel={}", held_before, high_before, g.sel))

	// Narrow so the held row (api-…) is GONE and a different row survives.
	st_drive(&g, st_keys_of("worker"))
	survivor := g.sessions[g.shown[g.sel]]
	st_check(c, "  the filter removes the held row and leaves another visible",
		app.shown_count(&g) == 1 && survivor.name != held_before && g.sel == 0,
		fmt.tprintf("shown={} survivor=%q was-held=%q sel={}",
			app.shown_count(&g), survivor.name, held_before, g.sel))
	st_check(c, "  …the highlight moved to the survivor AND held moved with it",
		g.held.valid && g.held.name == survivor.name && g.held.device == survivor.device,
		fmt.tprintf("held={}/{} highlighted={}/{}",
			g.held.device, g.held.name, survivor.device, survivor.name))

	cmd := app.update(&g, st_enter)
	st_check(c, "  Enter acts on EXACTLY the highlighted row — never the filtered-away one",
		cmd.kind == .attach && cmd.name == survivor.name && cmd.device == survivor.device,
		fmt.tprintf("cmd={} name=%q device=%q (highlighted %q/%q, filtered-away %q)",
			app.cmd_kind_label(cmd.kind), cmd.name, cmd.device,
			survivor.name, survivor.device, held_before))

	// (6) EMPTY list -> no highlight, held invalid, Enter is a no-op
	//     (spec: "If nothing was selected, pressing the key does nothing").
	e := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&e, []input.Key{st_kc('a')})
	st_drive(&e, st_keys_of("zzzznothingmatches"))
	ecmd := app.update(&e, st_enter)
	st_check(c, "  an empty list has no highlight and Enter is a no-op",
		e.sel == -1 && app.shown_count(&e) == 0 && !e.held.valid &&
			ecmd.kind == .none && e.state == .attach,
		fmt.tprintf("sel={} shown={} held.valid={} cmd={}",
			e.sel, app.shown_count(&e), e.held.valid, app.cmd_kind_label(ecmd.kind)))
	// …and the highlight COMES BACK when the filter is erased, still row 0.
	for _ in 0 ..< 18 { app.update(&e, st_bsp) }
	st_check(c, "  erasing the filter restores the first-row highlight, held in step",
		e.sel == 0 && app.shown_count(&e) == len(st_sessions()) &&
			e.held.name == e.sessions[e.shown[0]].name,
		fmt.tprintf("sel={} shown={} held=%q", e.sel, app.shown_count(&e), e.held.name))
}

//-----------------------------------------------------------------------------
// [9d] R3: the Del key edits text, it is not a dropped key
//-----------------------------------------------------------------------------

st_sec_r3_delete_key :: proc(c: ^Ctx) {
	st_say(c, "  [9d] R3: Del removes the last rune in every filter AND edit state")
	kd := input.key_of(.backspace) // what KEY_DELETE decodes to (see st_sec_keymap)

	// The filter, in a state that owns it.
	f := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&f, []input.Key{st_kc('a')})
	st_drive(&f, st_keys_of("api"))
	st_check(c, "  the filter holds 3 chars before Del", f.filter.len == 3,
		fmt.tprintf("filter=%q", app.text_of(&f.filter)))
	app.update(&f, kd)
	st_check(c, "  Del shortens it to 2", f.filter.len == 2 && app.text_of(&f.filter) == "ap",
		fmt.tprintf("filter=%q", app.text_of(&f.filter)))
	app.update(&f, kd)
	app.update(&f, kd)
	st_check(c, "  …to 1 …then to empty", f.filter.len == 0,
		fmt.tprintf("filter=%q", app.text_of(&f.filter)))
	app.update(&f, kd) // Del on an empty filter must not go negative
	st_check(c, "  Del on an empty filter is harmless (len stays 0)", f.filter.len == 0,
		fmt.tprintf("filter.len={}", f.filter.len))

	// The whole-rune rule on the filter: 世 is THREE bytes. A one-byte delete
	// would leave continuation bytes that render as garbage.
	g := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&g, []input.Key{st_kc('a')})
	st_drive(&g, st_keys_of("a世😀"))
	st_check(c, "  the filter holds an ASCII + 3-byte CJK + 4-byte emoji rune",
		g.filter.len == 1 + 3 + 4, fmt.tprintf("bytes={}", g.filter.len))
	app.update(&g, kd)
	st_check(c, "  Del removed the WHOLE 4-byte emoji, not one byte of it",
		g.filter.len == 4 && app.text_of(&g.filter) == "a世",
		fmt.tprintf("filter=%q bytes={}", app.text_of(&g.filter), g.filter.len))
	app.update(&g, kd)
	st_check(c, "  …and the WHOLE 3-byte CJK rune next",
		g.filter.len == 1 && app.text_of(&g.filter) == "a",
		fmt.tprintf("filter=%q bytes={}", app.text_of(&g.filter), g.filter.len))

	// The single-edit states use the same key for the same verb.
	n := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&n, []input.Key{st_kc('n')})
	st_drive(&n, st_keys_of("api"))
	app.update(&n, kd)
	st_check(c, "  Del removes a character from the name field too",
		app.text_of(&n.field) == "ap", fmt.tprintf("field=%q", app.text_of(&n.field)))
	app.update(&n, kd)
	app.update(&n, kd)
	st_check(c, "  …and erases it completely, leaving Enter a no-op",
		app.text_of(&n.field) == "" && app.update(&n, st_enter).kind == .none,
		fmt.tprintf("field=%q", app.text_of(&n.field)))

	// And Del in a filter state still RE-NARROWS the list, not just shortens the
	// string — that is the visible effect the user asked for.
	rn := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&rn, []input.Key{st_kc('a')})
	st_drive(&rn, st_keys_of("bu")) // matches only `build-…`
	narrowed := app.shown_count(&rn)
	app.update(&rn, kd) // "b" — matches `db-…` AND `build-…`
	widened := app.shown_count(&rn)
	st_check(c, "  Del re-widens the list (filter shortened => more rows visible)",
		narrowed == 1 && widened > narrowed,
		fmt.tprintf("{} row at \"bu\" -> {} rows at \"b\"", narrowed, widened))
}

//-----------------------------------------------------------------------------
// [9e] RCH-4: {Mode selection} has NO highlight
//-----------------------------------------------------------------------------

st_sec_rch4_no_highlight :: proc(c: ^Ctx) {
	st_say(c, "  [9e] RCH-4: {Mode selection} points at NOTHING — Enter creates, it does not target")

	// (1) Landing on a NON-EMPTY list and still highlighting nothing. This is
	//     the whole correction: emptiness is not why there is no highlight here.
	m := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	app.rebuild_shown(&m)
	st_check(c, "  {Mode selection} has rows to show but no highlight",
		app.shown_count(&m) == len(st_sessions()) && m.sel == -1,
		fmt.tprintf("shown={} sel={}", app.shown_count(&m), m.sel))
	st_check(c, "  …and held is invalid, not a stale row",
		!m.held.valid && m.held == app.NO_SELECTION,
		fmt.tprintf("held.valid={} held={}/{}", m.held.valid, m.held.device, m.held.name))

	// (2) RETURNING from a picker clears both the selection and the filter.
	//     This is the case that would otherwise leave a highlight pointing at a
	//     row the user picked two screens ago.
	rt := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&rt, []input.Key{st_kc('a')})
	st_drive(&rt, st_keys_of("worker"))
	st_check(c, "  setup: filtering to one row leaves exactly that row visible",
		app.shown_count(&rt) == 1 && rt.sel == 0 && rt.held.valid,
		fmt.tprintf("shown={} sel={} held.valid={}",
			app.shown_count(&rt), rt.sel, rt.held.valid))
	back := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&back, []input.Key{st_kc('a')})
	held_in_picker := back.held.name
	st_drive(&back, st_keys_of("worker"))
	st_check(c, "  in {Attach}: a selection exists and the filter is set",
		back.sel >= 0 && back.held.valid && back.filter.len > 0,
		fmt.tprintf("sel={} held=%q filter=%q", back.sel, held_in_picker,
			app.text_of(&back.filter)))
	app.update(&back, st_esc)
	st_check(c, "  back in {Mode selection}: selection CLEARED (no carried-over row)",
		back.state == .mode_selection && back.sel == -1 && !back.held.valid,
		fmt.tprintf("state={} sel={} held.valid={} (picker had %q)",
			app.state_label(back.state), back.sel, back.held.valid, held_in_picker))
	st_check(c, "  …and the filter was cleared too",
		back.filter.len == 0, fmt.tprintf("filter=%q", app.text_of(&back.filter)))
	st_check(c, "  …but the list is still fully populated (only the cursor was withheld)",
		app.shown_count(&back) == len(st_sessions()),
		fmt.tprintf("shown={}", app.shown_count(&back)))

	// (3) Enter in {Mode selection} CREATES, with no selection to act on. It
	//     must not degrade into a no-op just because nothing is highlighted, and
	//     must not target a row. This is the R1 path staying independent of R4.
	cm := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	app.rebuild_shown(&cm)

	cmd := app.update(&cm, st_enter)
	st_check(c, "  Enter with NO highlight still CREATES a new local session",
		cmd.kind == .launch_local && cmd.name != "" && cmd.device == app.DEVICE_LOCAL,
		fmt.tprintf("cmd={} name=%q device=%q sel={}",
			app.cmd_kind_label(cmd.kind), cmd.name, cmd.device, cm.sel))
	st_check(c, "  …and it names a NEW session, not any row that was on screen",
		!st_contains_session_name(st_sessions(), cmd.name),
		fmt.tprintf("new name=%q is not an existing row", cmd.name))

	// (4) The sharpened invariant across the whole machine: where there IS a
	//     highlight, `held` names exactly the highlighted row; where there is
	//     none, Enter never carries a row identity with it.
	machine_states := [5]app.State{.mode_selection, .attach, .delete_session,
		.remote_server, .theme}
	for s in machine_states {
		x := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
		st_drive(&x, st_prefix_for(s))
		has_hl := x.sel >= 0 && x.sel < app.shown_count(&x)
		if has_hl {
			ok_hl := true
			#partial switch s {
			case .attach, .delete_session:
				ok_hl = x.held.valid &&
					x.held.name == x.sessions[x.shown[x.sel]].name
			case .remote_server:
				ok_hl = x.cursor_id == x.remotes[x.shown[x.sel]].device
			case .theme:
				ok_hl = x.cursor_id == x.themes[x.shown[x.sel]]
			case .mode_selection:
				ok_hl = false // must never reach here with a highlight
			}
			st_check(c, fmt.tprintf("  {}: highlight present and == what Enter acts on",
				app.state_label(s)), ok_hl,
				fmt.tprintf("sel={} cursor_id=%q held.valid={}", x.sel, x.cursor_id, x.held.valid))
		} else {
			st_check(c, fmt.tprintf("  {}: no highlight => no row identity carried",
				app.state_label(s)),
				s == .mode_selection || app.shown_count(&x) == 0 || x.sel == -1,
				fmt.tprintf("sel={} shown={}", x.sel, app.shown_count(&x)))
		}
	}
}

//-----------------------------------------------------------------------------
// [9f] the machine's filter == the view's filter
//-----------------------------------------------------------------------------

st_sec_filter_agrees :: proc(c: ^Ctx) {
	st_say(c, "  [9f] the machine's filter is the SAME predicate the view paints with")

	filters := []string{"", "a", "API", "api-", "LOCAL", "lab", "@", "deploy",
		"worker", "zzz", "-", "2026"}
	mismatches := 0
	checked := 0
	for f in filters {
		for sess in st_sessions() {
			mine := app.machine_session_matches(sess, f)
			theirs := ui.sessions_match(sess, f)
			checked += 1
			if mine != theirs {
				mismatches += 1
				st_say(c, fmt.tprintf("    MISMATCH filter=%q session={}/{} mine={} ui={}",
					f, sess.device, sess.name, mine, theirs))
			}
		}
	}
	st_check(c, "machine_session_matches == ui.sessions_match over every row x filter",
		mismatches == 0, fmt.tprintf("{} mismatch(es) across {} pairs", mismatches, checked))
}

//-----------------------------------------------------------------------------
// [10] nothing ever targets `default` (D12 / ISC-18)
//-----------------------------------------------------------------------------

st_sec_never_default :: proc(c: ^Ctx) {
	st_say(c, "  [10] no Command ever targets `default`, even handed a dirty list")

	all := []app.State{
		.mode_selection, .name_local, .remote_server, .name_remote_named,
		.attach, .delete_session, .theme, .error,
	}
	keys := []input.Key{st_enter, st_esc, st_down, st_up, st_tab, st_stab, st_bsp,
		st_kc('n'), st_kc('r'), st_kc('s'), st_kc('a'), st_kc('d'), st_kc('t'),
		st_kc('x'), st_kc('1'), st_kc('.')}

	// Adversarial: `default` IS in the list. Try to aim at it from every state.
	offenders := 0
	tried := 0
	for s in all {
		for k in keys {
			m := app.new_app(st_sessions_with_default(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
			st_drive(&m, st_prefix_for(s))
			cmd := app.update(&m, k)
			tried += 1
			if cmd.name == app.DEFAULT_SESSION_NAME ||
				strings.contains(cmd.name, app.DEFAULT_SESSION_NAME) {
				offenders += 1
				st_say(c, fmt.tprintf("    offender: {} + {} -> {} name=%q",
					app.state_label(s), k.kind, app.cmd_kind_label(cmd.kind), cmd.name))
			}
		}
	}
	st_check(c, "no Command from any (state, key) names `default`",
		offenders == 0, fmt.tprintf("{} offender(s) in {} probes", offenders, tried))

	// And the explicit aim: filter down to `default` in attach, press Enter.
	a := app.new_app(st_sessions_with_default(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&a, []input.Key{st_kc('a')})
	st_drive(&a, st_keys_of("default"))
	app.update(&a, st_down)
	aimed := app.update(&a, st_enter)
	st_check(c, "aiming `attach` at default is REFUSED (show_error, never attach)",
		aimed.kind == .show_error && aimed.name == "" && aimed.device == "",
		fmt.tprintf("cmd={} name=%q device=%q msg=%q",
			app.cmd_kind_label(aimed.kind), aimed.name, aimed.device, aimed.value))
	st_check(c, "  and the machine parked in {Error}", a.state == .error,
		fmt.tprintf("state={}", app.state_label(a.state)))

	d := app.new_app(st_sessions_with_default(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&d, []input.Key{st_kc('d')})
	st_drive(&d, st_keys_of("default"))
	app.update(&d, st_down)
	aimed = app.update(&d, st_enter)
	st_check(c, "aiming `delete` at default is REFUSED too (never a delete command)",
		aimed.kind == .show_error && aimed.name == "" && aimed.device == "",
		fmt.tprintf("cmd={} name=%q device=%q msg=%q",
			app.cmd_kind_label(aimed.kind), aimed.name, aimed.device, aimed.value))

	// Typing the word "default" as a NEW session name must not launch either.
	n := app.new_app(st_sessions(), st_remotes(), st_themes(), SM_DEFAULT_THEME)
	st_drive(&n, st_keys_of("n"))
	st_drive(&n, st_keys_of("default"))
	typed := app.update(&n, st_enter)
	st_check(c, "typing `default` as a new name is refused into {Error}",
		typed.kind == .show_error && n.state == .error,
		fmt.tprintf("cmd={} state={}", app.cmd_kind_label(typed.kind), app.state_label(n.state)))
}

//-----------------------------------------------------------------------------
// [11] an empty world
//-----------------------------------------------------------------------------

st_sec_empty_world :: proc(c: ^Ctx) {
	// No sessions, no remotes, no themes: exactly what a machine with no herdr,
	// no registry and no config looks like. Transitions must still be sound.
	st_say(c, "  [11] the machine runs with NOTHING loaded (no sessions/remotes/themes)")

	e := app.new_app(nil, nil, nil, "")
	st_drive(&e, []input.Key{st_kc('a')})
	cmd := app.update(&e, st_enter)
	st_expect_noop(c, "attach with no sessions at all", cmd, e.state, .attach)

	r := app.new_app(nil, nil, nil, "")
	st_drive(&r, []input.Key{st_kc('r')})
	cmd = app.update(&r, st_enter)
	st_expect_noop(c, "remote pick with no remotes at all", cmd, r.state, .remote_server)

	t := app.new_app(nil, nil, nil, "")
	st_drive(&t, []input.Key{st_kc('t')})
	cmd = app.update(&t, st_enter)
	st_expect_noop(c, "theme pick with no themes at all", cmd, t.state, .theme)

	// Down/Tab on an empty list must not crash nor invent a row.
	app.update(&t, st_down)
	app.update(&t, st_tab)
	app.update(&t, st_stab)
	app.update(&t, st_up)
	st_check(c, "movement on an empty list leaves no selection",
		t.sel == -1 && app.shown_count(&t) == 0,
		fmt.tprintf("sel={} shown={}", t.sel, app.shown_count(&t)))

	// Local launch does not need ANY list to be loaded.
	l := app.new_app(nil, nil, nil, "")
	cmd = app.update(&l, st_enter)
	st_check(c, "Enter with no list loaded still yields a timestamped local launch",
		cmd.kind == .launch_local && app.ts_is_known(app.ts_from_name(cmd.name)),
		fmt.tprintf("cmd={} name={}", app.cmd_kind_label(cmd.kind), cmd.name))
}

//-----------------------------------------------------------------------------
// [12] offline proof — zero child processes created for the whole run
//-----------------------------------------------------------------------------

st_sec_offline_proof :: proc(c: ^Ctx) {
	st_say(c, "  [12] offline proof — the run created ZERO child processes")

	// `update` cannot spawn, and this proves it was never asked to: a process
	// wait with WNOHANG over ALL our children must find nothing to reap. ECHILD
	// (-1) is the answer that means "you have no children at all".
	status : cc.int = 0
	got := posix.waitpid(-1, &status, {.NOHANG})
	code := posix.errno()
	st_check(c, "no child process exists to be reaped (waitpid -> ECHILD)",
		got == -1 && code == posix.Errno.ECHILD,
		fmt.tprintf("waitpid(-1, WNOHANG) = {} errno={}", got, int(code)))

	// And the whole case ran with the environment it was given — no config file,
	// no herdr on PATH needed. The offline half of this suite makes that
	// concrete by re-running the battery with NOTHING in the environment.
	env_count := 0
	if env, err := os.environ(context.allocator); err == nil {
		env_count = len(env)
	}
	st_say(c, fmt.tprintf("    env variables visible to this run: {} (the stripped re-run has 3)", env_count))
}

//-----------------------------------------------------------------------------
// The batteries
//-----------------------------------------------------------------------------

// st_battery_machine is the full `case_state_machine` section list (189
// assertions when run against the ledger).
st_battery_machine :: proc(c: ^Ctx) {
	st_say(c, "case state-machine — (state, key) -> Command, with no side effects")
	st_say(c, fmt.tprintf("  fixture: {} sessions · {} remotes · {} themes · theme={}",
		len(st_sessions()), len(st_remotes()), len(st_themes()), SM_DEFAULT_THEME))

	st_sec_keymap(c)
	st_sec_matrix(c)
	st_sec_reachability(c)
	st_sec_two_step(c)
	st_sec_empty_field_noop(c)
	st_sec_no_selection_noop(c)
	st_sec_ctrl_c_everywhere(c)
	st_sec_esc_back(c)
	st_sec_identity_not_sliding(c)
	st_sec_r2_filter_owns_four(c)
	st_sec_r4_highlight(c)
	st_sec_rch4_no_highlight(c)
	st_sec_r3_delete_key(c)
	st_sec_filter_agrees(c)
	st_sec_never_default(c)
	st_sec_empty_world(c)
	st_sec_offline_proof(c)
}

// st_battery_offline_sections is the 7-sub-battery list the old
// `case_state_offline` re-ran under `env -i` (54 assertions).
st_offline_sections :: []proc(c: ^Ctx) {
	st_sec_reachability,
	st_sec_two_step,
	st_sec_no_selection_noop,
	st_sec_ctrl_c_everywhere,
	st_sec_never_default,
	st_sec_empty_world,
	st_sec_offline_proof,
}

st_battery_offline :: proc(c: ^Ctx) {
	st_say(c, "case state-offline — the whole state-machine battery, environment-free")
	for p in st_offline_sections {
		p(c)
	}
}

//-----------------------------------------------------------------------------
// The render entry points (what the printf guard scans)
//-----------------------------------------------------------------------------

// st_render_machine renders the FULL machine battery with no ledger and returns
// the text. The printf guard (`assert_formatted` in dev/state-smoke.sh) scanned
// the whole state-machine log; this is the same body of generated text, and the
// gate's own `%!` sweep of the run log covers everything this misses.
st_render_machine :: proc() -> string {
	b := strings.builder_make_len(0, context.allocator)
	c := st_render(&b)
	st_battery_machine(&c)
	return strings.to_string(b)
}

// st_render_offline renders the offline battery only — the text the old
// `state-offline` log carried.
st_render_offline :: proc() -> string {
	b := strings.builder_make_len(0, context.allocator)
	c := st_render(&b)
	st_battery_offline(&c)
	return strings.to_string(b)
}
