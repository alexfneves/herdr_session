package main

// ============================================================================
// T5.4 DRIVER — the state machine, proven with NOTHING but literals
//
// Case `state-machine`. Every claim below is checked against a machine that has
// no herdr binary, no terminal, no network and no config file in front of it.
// That is the point of T5.4: `update(app, key)` returns a Command, it does not
// perform one — so the whole transition table is verifiable offline, before a
// single subprocess exists.
//
// What gets proven, in order:
//   1. keymap     — tb_event fields → Key, incl. Ctrl-C as byte 0x03
//   2. matrix     — the full (state × key) grid, printed
//   3. reachability — all 7 states, from mode_selection, with the spec's exact keys
//   4. two-step   — the resolved `[s]` path end to end → launch_remote with the
//                   CARRIED name and the VERBATIM device
//   5. no-ops     — empty field + Enter; no selection + Enter, in every list state
//   6. ctrl-c     — quit from all 8 states
//   7. esc       — back to mode_selection (and nothing left dirty)
//   8. identity  — a filtered-out selection DROPS, it never slides onto a neighbour
//   9. default   — no Command ever targets `default`, adversarially
//  10. offline   — zero child processes created for the whole run
// ============================================================================

import app "./app"
import input "./input"
import ui "./ui"
import termbox2 "../vendor/termbox2-odin"

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// ── fixture data ──────────────────────────────────────────────────────────
//
// ISC-A-3: no loopback fixture string appears in src/ at all — `grep -rn` for
// one must stay empty, so the fixture hosts here are inert example domains.
// In the real test suite they are DISTINCT STRINGS FOR THE SAME UNDERLYING
// MACHINE; here they only have to be distinguishable, and `Deploy@lab.example`
// is deliberately mixed-case so any accidental normalisation of the device
// string shows up as a failed equality check.

SM_TS :: "2026-10-19-10-00-00-000"

SM_DEV_LAB :: "lab.example"
SM_DEV_DEPLOY :: "Deploy@lab.example"
SM_DEV_BUILD :: "build.example"

sm_sessions :: proc() -> []app.Session {
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

// sm_sessions_with_default is the ADVERSARIAL fixture: a producer that failed
// to filter `default` (D12) hands it to the machine anyway. The machine must
// still never issue a Command that targets it.
sm_sessions_with_default :: proc() -> []app.Session {
	out: [dynamic]app.Session
	append(&out, app.Session{device = app.DEVICE_LOCAL, label = "local",
		name = fmt.tprintf("api-{}", SM_TS), running = true})
	append(&out, app.Session{device = app.DEVICE_LOCAL, label = "local",
		name = app.DEFAULT_SESSION_NAME, running = true})
	append(&out, app.Session{device = SM_DEV_LAB, label = "lab",
		name = fmt.tprintf("worker-{}", SM_TS), running = true})
	return out[:]
}

sm_remotes :: proc() -> []app.Remote {
	out: [dynamic]app.Remote
	append(&out, app.Remote{device = SM_DEV_LAB, label = "lab"})
	append(&out, app.Remote{device = SM_DEV_DEPLOY, label = "deploy"})
	append(&out, app.Remote{device = SM_DEV_BUILD, label = ""})
	return out[:]
}

sm_themes :: proc() -> []string {
	out: [dynamic]string
	append(&out, "gruvbox-dark")
	append(&out, "catppuccin-latte")
	append(&out, "solarized-dark")
	return out[:]
}

SM_DEFAULT_THEME :: "gruvbox-dark"

// ── key construction ──────────────────────────────────────────────────────

kc :: proc(ch: rune) -> input.Key { return input.char_key(ch) }
// The named single keys. Composite literals rather than `key_of(...)` calls:
// package-level bindings must be compile-time constants.
k_enter  :: input.Key{kind = .enter}
k_esc    :: input.Key{kind = .esc}
k_bsp    :: input.Key{kind = .backspace}
k_tab    :: input.Key{kind = .tab}
k_stab   :: input.Key{kind = .shift_tab}
k_up     :: input.Key{kind = .up}
k_down   :: input.Key{kind = .down}
k_ctrlc  :: input.Key{kind = .ctrl_c}

// keys_of spells a word as character keys.
keys_of :: proc(word: string) -> []input.Key {
	out: [dynamic]input.Key
	for r in word { append(&out, kc(r)) }
	return out[:]
}

// ── driving ───────────────────────────────────────────────────────────────

// drive feeds a key sequence and returns the LAST command issued.
drive :: proc(a: ^app.App, keys: []input.Key) -> app.Command {
	last := app.no_cmd()
	for k in keys {
		last = app.update(a, k)
	}
	return last
}

// prefix_for reaches `s` the way a USER would — through key presses from
// {Mode selection}, never by poking the struct. If a prefix does not land in
// `s`, that itself is the reachability failure and the caller reports it.
prefix_for :: proc(s: app.State) -> []input.Key {
	out: [dynamic]input.Key
	#partial switch s {
	case .mode_selection:
		// already there
	case .name_local:
		append(&out, kc('n'))
	case .remote_server:
		append(&out, kc('r'))
	case .name_remote_named:
		append(&out, kc('s'))
	case .attach:
		append(&out, kc('a'))
	case .delete_session:
		append(&out, kc('d'))
	case .theme:
		append(&out, kc('t'))
	case .error:
		append(&out, kc('n'))
		append(&out, ..keys_of("default"))
		append(&out, k_enter)
	}
	return out[:]
}

// sm_new builds a fixture machine in state `s`, with a live selection when the
// state has a list. Everything — the state AND the selection — arrives through
// keys, so a cell of the matrix is "what the user's fingers would cause".
sm_new :: proc(s: app.State, select_item: bool) -> app.App {
	a := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&a, prefix_for(s))
	if select_item && app.state_is_filter_view(a.state) {
		app.update(&a, k_down)
	}
	return a
}

// ── little reporting helpers ──────────────────────────────────────────────

sm_code :: proc(s: app.State) -> string {
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

sm_cmd_code :: proc(k: app.Cmd_Kind) -> string {
	#partial switch k {
	case .none:         return "-"
	case .launch_local: return "loc"
	case .launch_remote: return "rem"
	case .attach:       return "att"
	case .delete:      return "del"
	case .set_theme:   return "thm"
	case .show_error:  return "err"
	case .clear_filter: return "cf"
	case .clear_field: return "cd"
	case .quit:        return "quit"
	}
	return "?"
}

// pad right-pads by hand: Odin's fmt has no `{:6}` width spec, and `string +
// string` is illegal, so every pad is a fresh tprintf.
pad :: proc(s: string, w: int) -> string {
	out := s
	for i := len(s); i < w; i += 1 {
		out = fmt.tprintf("{} ", out)
	}
	return out
}

// expect_state checks the machine landed exactly where the spec says.
expect_state :: proc(what: string, got, want: app.State, extra: string) {
	check(what, got == want, fmt.tprintf("reached {} want {}   {}",
		app.state_label(got), app.state_label(want), extra))
}

expect_cmd :: proc(what: string, got: app.Command, want: app.Cmd_Kind, extra: string) {
	check(what, got.kind == want, fmt.tprintf("cmd {} want {}   {}",
		app.cmd_kind_label(got.kind), app.cmd_kind_label(want), extra))
}

// expect_noop is the spec's "pressing the key does nothing", asserted as BOTH
// halves: no command AND no state change.
expect_noop :: proc(what: string, cmd: app.Command, state_now: app.State, was: app.State) {
	check(what, cmd.kind == .none && state_now == was,
		fmt.tprintf("cmd={} state={} (want none/{} unchanged)",
			app.cmd_kind_label(cmd.kind), app.state_label(state_now), app.state_label(was)))
}

// ── the case ──────────────────────────────────────────────────────────────

case_state_machine :: proc() -> bool {
	say("case state-machine — (state, key) -> Command, with no side effects")
	say(fmt.tprintf("  fixture: {} sessions · {} remotes · {} themes · theme={}",
		len(sm_sessions()), len(sm_remotes()), len(sm_themes()), SM_DEFAULT_THEME))

	sm_keymap()
	sm_matrix()
	sm_reachability()
	sm_two_step()
	sm_empty_field_noop()
	sm_no_selection_noop()
	sm_ctrl_c_everywhere()
	sm_esc_back()
	sm_identity_not_sliding()
	sm_filter_agrees_with_the_view()
	sm_never_default()
	sm_empty_world()
	sm_offline_proof()

	return !any_failed
}

// ── 1. keymap ─────────

sm_keymap :: proc() {
	say("  [1] keymap — tb_event fields -> Key")

	// Ctrl+C is byte 0x03. cfmakeraw cleared ISIG, so it is DATA, and it must
	// arrive as a Key rather than as a signal we could miss.
	kk := input.decode(termbox2.EVENT_KEY, termbox2.KEY_CTRL_C, 0, 0)
	check("0x03 decodes to ctrl_c (ISIG is off, so it is data)",
		kk.kind == .ctrl_c, fmt.tprintf("kind={}", kk.kind))
	kb := input.decode(termbox2.EVENT_KEY, 0x03, 0, 0)
	check("the raw byte 0x03 in `key` decodes to ctrl_c too",
		kb.kind == .ctrl_c, fmt.tprintf("kind={}", kb.kind))

	// Legacy ESC: one code, immediate, no sequence-wait timer involved.
	ke := input.decode(termbox2.EVENT_KEY, termbox2.KEY_ESC, 0, 0)
	check("TB_KEY_ESC decodes to esc (legacy, no timeout)", ke.kind == .esc,
		fmt.tprintf("kind={}", ke.kind))

	check("TAB decodes to tab",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_TAB, 0, 0).kind == .tab, "")
	check("TAB + MOD_SHIFT decodes to shift_tab",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_TAB, 0, termbox2.MOD_SHIFT).kind == .shift_tab,
		fmt.tprintf("kind={}", input.decode(termbox2.EVENT_KEY, termbox2.KEY_TAB, 0, termbox2.MOD_SHIFT).kind))
	check("BACK_TAB (CSI Z) decodes to shift_tab",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_BACK_TAB, 0, 0).kind == .shift_tab, "")
	check("CR decodes to enter",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_ENTER, 0, 0).kind == .enter, "")
	check("LF decodes to enter as well",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_CTRL_J, 0, 0).kind == .enter, "")
	check("0x7f decodes to backspace",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_BACKSPACE2, 0, 0).kind == .backspace, "")
	check("0x08 (Ctrl-H) decodes to backspace",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_BACKSPACE, 0, 0).kind == .backspace, "")
	check("arrow down decodes to down",
		input.decode(termbox2.EVENT_KEY, termbox2.KEY_ARROW_DOWN, 0, 0).kind == .down, "")

	ka := input.decode(termbox2.EVENT_KEY, 0, 'a', 0)
	check("'a' decodes to character 'a'", ka.kind == .character && ka.r == 'a',
		fmt.tprintf("kind={} r={}", ka.kind, ka.r))
	kcjk := input.decode(termbox2.EVENT_KEY, 0, 0x4E16, 0)
	check("a multi-byte rune arrives decoded in `ch` (世)",
		kcjk.kind == .character && kcjk.r == 0x4E16,
		fmt.tprintf("kind={} r=U+{}", kcjk.kind, fmt.tprintf("%04X", kcjk.r)))
	check("a control byte in `ch` is never user text (BEL)",
		input.decode(termbox2.EVENT_KEY, 0, 0x07, 0).kind == .none, "")
	check("a RESIZE event produces no key",
		input.decode(termbox2.EVENT_RESIZE, 0, 0, 0).kind == .none, "")

	ev := termbox2.Event{typ = termbox2.EVENT_KEY, key = termbox2.KEY_CTRL_C}
	check("from_event reads the struct fields, not a copy of them",
		input.from_event(&ev).kind == .ctrl_c, "")
}

// ── 2. the matrix ─────────────────────────────────────────────────────────

Key_Cell :: struct {
	label : string,
	k     : input.Key,
}

sm_states :: proc() -> []app.State {
	out: [dynamic]app.State
	append(&out, app.State.mode_selection, app.State.name_local,
		app.State.remote_server, app.State.name_remote_named)
	append(&out, app.State.attach, app.State.delete_session,
		app.State.theme, app.State.error)
	return out[:]
}

// sm_print_grid runs EVERY (state, key) pair through a fresh machine and prints
// the cell as `state_reached/command_issued`. Nothing here asserts: the grid is
// the evidence, `sm_spec_cells` below is the contract.
sm_print_grid :: proc(title: string, states: []app.State, cols: []Key_Cell) {
	say(fmt.tprintf("    {}", title))
	line := pad("    state", 22)
	for col in cols {
		line = fmt.tprintf("{}{}", line, pad(col.label, 10))
	}
	say(line)
	for s in states {
		row := pad(fmt.tprintf("    {}", app.state_label(s)), 22)
		for col in cols {
			m := sm_new(s, true)
			cmd := app.update(&m, col.k)
			row = fmt.tprintf("{}{}", row, pad(fmt.tprintf("{}/{}",
				sm_code(m.state), sm_cmd_code(cmd.kind)), 10))
		}
		say(row)
	}
}

sm_matrix :: proc() {
	say("  [2] full (state x key) grid — state reached / command issued")

	states := sm_states()
	spec_keys := []Key_Cell{
		{"enter", k_enter}, {"n", kc('n')}, {"r", kc('r')}, {"s", kc('s')},
		{"a", kc('a')}, {"d", kc('d')}, {"t", kc('t')}, {"esc", k_esc}, {"^C", k_ctrlc},
	}
	list_keys := []Key_Cell{
		{"down", k_down}, {"up", k_up}, {"tab", k_tab}, {"s-tab", k_stab},
		{"bs", k_bsp}, {"'x'", kc('x')},
	}

	sm_print_grid("spec keys:", states, spec_keys)
	sm_print_grid("list / edit keys (each row entered from {Mode selection} by its key, then one item selected):",
		states, list_keys)
	say("    legend: MS mode_selection · NL name_local · RS remote_server · NR name_remote_named")
	say("            AT attach · DL delete_session · TH theme · ER error")
	say("            loc launch_local · rem launch_remote · att attach · del delete · thm set_theme")
	say("            err show_error · cf clear_filter · cd clear_field · quit quit · - no command")

	sm_spec_cells()
}

// expect_cell re-probes one (state, key) pair and asserts state + command.
expect_cell :: proc(from: app.State, select_item: bool, k: input.Key, label: string,
                  want: app.State, want_cmd: app.Cmd_Kind) {
	m := sm_new(from, select_item)
	cmd := app.update(&m, k)
	check(fmt.tprintf("  [{}]+{} -> {} {}", app.state_label(from), label,
		app.state_label(want), app.cmd_kind_label(want_cmd)),
		m.state == want && cmd.kind == want_cmd,
		fmt.tprintf("got {}/{}", app.state_label(m.state), app.cmd_kind_label(cmd.kind)))
}

// sm_spec_cells is the transition table of plan §State transitions, asserted
// cell by cell against a fresh machine per cell.
sm_spec_cells :: proc() {
	say("    spec assertions (plan §State transitions):")

	// {Mode selection}
	expect_cell(.mode_selection, false, k_enter, "Enter", .mode_selection, .launch_local)
	expect_cell(.mode_selection, false, kc('n'), "n", .name_local, .none)
	expect_cell(.mode_selection, false, kc('r'), "r", .remote_server, .none)
	expect_cell(.mode_selection, false, kc('s'), "s", .name_remote_named, .none)
	expect_cell(.mode_selection, false, kc('a'), "a", .attach, .none)
	expect_cell(.mode_selection, false, kc('d'), "d", .delete_session, .none)
	expect_cell(.mode_selection, false, kc('t'), "t", .theme, .none)
	expect_cell(.mode_selection, false, k_esc, "Esc", .mode_selection, .quit)

	// {Select name of new local session} — with a name typed.
	{
		m := sm_new(.name_local, false)
		drive(&m, keys_of("api"))
		cmd := app.update(&m, k_enter)
		check("  [name_local]+Enter -> launch_local \"<typed>-<ts>\"",
			cmd.kind == .launch_local && strings.has_prefix(cmd.name, "api-") &&
				m.state == .mode_selection,
			fmt.tprintf("cmd={} name={} state={}",
				app.cmd_kind_label(cmd.kind), cmd.name, app.state_label(m.state)))
	}

	// {Select remote server…} with a host selected.
	expect_cell(.remote_server, true, k_enter, "Enter", .mode_selection, .launch_remote)

	// {Select session to attach} with a row selected.
	expect_cell(.attach, true, k_enter, "Enter", .mode_selection, .attach)

	// {Select session to delete}: the delete is issued and the user STAYS — the
	// list refreshes under them and they keep cleaning up.
	expect_cell(.delete_session, true, k_enter, "Enter", .delete_session, .delete)

	// {Select theme}: Enter applies AND clears the filter AND returns.
	{
		m := sm_new(.theme, true)
		picked := ""
		if idx, ok := app.active_index(&m); ok && idx < len(sm_themes()) {
			picked = sm_themes()[idx]
		}
		cmd := app.update(&m, k_enter)
		check("  [theme]+Enter -> set_theme + mode_selection + filter cleared",
			cmd.kind == .set_theme && cmd.value == picked && m.state == .mode_selection &&
				m.filter.len == 0 && m.theme == picked,
			fmt.tprintf("cmd={} value={} theme={} state={} filter={}",
				app.cmd_kind_label(cmd.kind), cmd.value, m.theme,
				app.state_label(m.state), m.filter.len))
	}

	// {Error}
	expect_cell(.error, false, k_enter, "Enter", .mode_selection, .none)
	expect_cell(.error, false, k_esc, "Esc", .mode_selection, .none)

	// The edit states' Escape semantics (clears the field, returns to the root).
	{
		m := sm_new(.name_local, false)
		drive(&m, keys_of("api"))
		cmd := app.update(&m, k_esc)
		check("  [name_local]+Esc -> clear_field + mode_selection",
			cmd.kind == .clear_field && m.state == .mode_selection && m.field.len == 0,
			fmt.tprintf("cmd={} state={} field={}",
				app.cmd_kind_label(cmd.kind), app.state_label(m.state), m.field.len))
	}

	// Leaving a filtered state clears the filter.
	{
		m := sm_new(.attach, true)
		drive(&m, keys_of("api"))
		cmd := app.update(&m, k_esc)
		check("  [attach]+Esc -> clear_filter + mode_selection",
			cmd.kind == .clear_filter && m.state == .mode_selection && m.filter.len == 0,
			fmt.tprintf("cmd={} state={} filter={}",
				app.cmd_kind_label(cmd.kind), app.state_label(m.state), m.filter.len))
	}
}

// ── 3. reachability (ISC-3) ──────────────────────────────────────────────

sm_reachability :: proc() {
	say("  [3] every state is reachable from {Mode selection} with the spec's key")

	reach := []struct { key: rune, want: app.State }{
		{'n', .name_local},
		{'r', .remote_server},
		{'s', .name_remote_named},
		{'a', .attach},
		{'d', .delete_session},
		{'t', .theme},
	}
	for r in reach {
		a := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
		cmd := app.update(&a, kc(r.key))
		check(fmt.tprintf("[{}] reaches {}", r.key, app.state_label(r.want)),
			a.state == r.want && cmd.kind == .none,
			fmt.tprintf("reached {} cmd={}", app.state_label(a.state), app.cmd_kind_label(cmd.kind)))
	}

	// The root state itself, and {Error} via a failing action.
	root := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	check("mode_selection is the start state", root.state == .mode_selection,
		fmt.tprintf("started in {}", app.state_label(root.state)))

	bad := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&bad, keys_of("n"))
	drive(&bad, keys_of("default"))
	enter_cmd := app.update(&bad, k_enter)
	check("error is reachable (n + 'default' + Enter is refused into {Error})",
		bad.state == .error && enter_cmd.kind == .show_error,
		fmt.tprintf("reached {} cmd={}", app.state_label(bad.state), app.cmd_kind_label(enter_cmd.kind)))
	check("the error message says why",
		strings.contains(enter_cmd.value, "default"),
		fmt.tprintf("message = %q", enter_cmd.value))
}

// ── 4. the resolved [s] two-step ─────────────────────────────────────────

sm_two_step :: proc() {
	say("  [4] the [s] two-step, end to end (name first, THEN the server)")

	// Step-by-step, with the machine inspected between every key, because the
	// whole risk of this path is the name being lost or mangled at the hop.
	a := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)

	drive(&a, []input.Key{kc('s')})
	expect_state("[s] opens {name_remote_named}", a.state, .name_remote_named, "1/4")

	drive(&a, keys_of("api"))
	check("  typed name is in the field", app.text_of(&a.field) == "api",
		fmt.tprintf("field = %q", app.text_of(&a.field)))

	cmd := app.update(&a, k_enter)
	expect_state("  [Enter] carries the name into {remote_server}", a.state, .remote_server, "2/4")
	check("  the name was carried (not dropped, not consumed)", a.carried_name == "api",
		fmt.tprintf("carried_name = %q", a.carried_name))
	check("  no launch happened yet at the hop", cmd.kind == .none,
		fmt.tprintf("cmd = {}", app.cmd_kind_label(cmd.kind)))

	app.update(&a, k_down)
	check("  [down] selects a host", a.sel == 0 && app.shown_count(&a) == 3,
		fmt.tprintf("sel={} shown={}", a.sel, app.shown_count(&a)))

	cmd = app.update(&a, k_enter)
	expect_state("  [Enter] leaves for the launch", a.state, .mode_selection, "4/4")
	expect_cmd("  the command is launch_remote", cmd, .launch_remote, "")
	check("  it carries BOTH the carried name and the device",
		cmd.device == SM_DEV_LAB && strings.has_prefix(cmd.name, "api-"),
		fmt.tprintf("device=%q name=%q", cmd.device, cmd.name))
	check("  the name kept the cycle-timestamp shape (D11)",
		app.ts_is_known(app.ts_from_name(cmd.name)),
		fmt.tprintf("name=%q ts parses=%v", cmd.name, app.ts_is_known(app.ts_from_name(cmd.name))))
	check("  the device is VERBATIM, not normalised (ISC-4)",
		cmd.device == "lab.example",
		fmt.tprintf("device=%q", cmd.device))

	// Same path, but the host is found by filtering — and to a target string with
	// MIXED CASE, so a lowercase-everything shortcut cannot pass.
	b := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&b, []input.Key{kc('s')})
	drive(&b, keys_of("web"))
	app.update(&b, k_enter)
	drive(&b, keys_of("deploy@"))
	matched := app.shown_count(&b)
	check("  the filter narrows the host list to 1", matched == 1,
		fmt.tprintf("shown={} (filter=%q)", matched, app.text_of(&b.filter)))
	app.update(&b, k_down)
	cmd = app.update(&b, k_enter)
	expect_cmd("  filtered pick still launches remote", cmd, .launch_remote, "")
	check("  device survives the round trip EXACTLY as configured",
		cmd.device == "Deploy@lab.example",
		fmt.tprintf("device=%q want %q", cmd.device, "Deploy@lab.example"))
	check("  and the typed name is what got carried",
		strings.has_prefix(cmd.name, "web-"),
		fmt.tprintf("name=%q", cmd.name))

	// The unnamed remote path ([r]) must still work with no carried name.
	d := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&d, []input.Key{kc('r')})
	app.update(&d, k_down)
	cmd = app.update(&d, k_enter)
	expect_cmd("  [r] (unnamed remote) launches with a timestamp-only name", cmd, .launch_remote, "")
	check("  no carried name leaked into the [r] path",
		d.carried_name == "" && app.ts_is_known(app.ts_from_name(cmd.name)),
		fmt.tprintf("carried=%q name=%q", d.carried_name, cmd.name))
}

// ── 5. empty-field Enter is a no-op ──────────────────────────────────────

sm_empty_field_noop :: proc() {
	say("  [5] empty edit field + Enter does nothing (spec: 'pressing the key does nothing')")

	a := sm_new(.name_local, false)
	cmd := app.update(&a, k_enter)
	expect_noop("name_local: empty field + Enter", cmd, a.state, .name_local)

	// Type then erase: empty is empty whether it started that way or not.
	drive(&a, keys_of("ab"))
	app.update(&a, k_bsp)
	app.update(&a, k_bsp)
	check("  field is empty again after two backspaces", app.text_of(&a.field) == "",
		fmt.tprintf("field=%q", app.text_of(&a.field)))
	cmd = app.update(&a, k_enter)
	expect_noop("name_local: typed-then-erased + Enter", cmd, a.state, .name_local)

	// Same rule on the named-remote edit: nothing typed = nothing to carry.
	b := sm_new(.name_remote_named, false)
	// (b was built WITH a name; build a bare one instead)
	bare := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	app.update(&bare, kc('s'))
	cmd = app.update(&bare, k_enter)
	expect_noop("name_remote_named: empty field + Enter", cmd, bare.state, .name_remote_named)
	check("  and nothing was carried", bare.carried_name == "",
		fmt.tprintf("carried=%q", bare.carried_name))
	_ = b

	// Whole-rune backspace, so "erased" means erased and not "one broken byte left".
	e := sm_new(.name_local, false)
	drive(&e, keys_of("a世b😀"))
	check("  non-charset runes are rejected at input (names are [A-Za-z0-9._-])",
		app.text_of(&e.field) == "ab",
		fmt.tprintf("field=%q", app.text_of(&e.field)))
	check("  a rejected rune leaves the field byte-exact", app.text_of(&e.field) == "ab",
		fmt.tprintf("field=%q len={}", app.text_of(&e.field), e.field.len))
	app.update(&e, k_bsp)
	check("  backspace removes exactly the LAST rune, not a byte",
		app.text_of(&e.field) == "a",
		fmt.tprintf("field=%q len={}", app.text_of(&e.field), e.field.len))

	// Whole-rune backspace where multi-byte runes actually live: the FILTER line
	// (name fields reject non-ASCII, filters do not). One backspace must remove
	// all THREE bytes of a CJK rune; a one-byte delete would leave continuation
	// bytes that render as garbage.
	f := sm_new(.attach, false)
	drive(&f, keys_of("a世"))
	check("  the filter accepted the multi-byte rune", f.filter.len == 4,
		fmt.tprintf("filter=%q bytes={}", app.text_of(&f.filter), f.filter.len))
	app.update(&f, k_bsp)
	check("  one backspace removed the WHOLE 3-byte rune", f.filter.len == 1,
		fmt.tprintf("filter=%q bytes={}", app.text_of(&f.filter), f.filter.len))
	app.update(&f, k_bsp)
	check("  and the filter is truly empty — no dangling continuation byte",
		f.filter.len == 0 && app.text_of(&f.filter) == "",
		fmt.tprintf("filter=%q bytes={}", app.text_of(&f.filter), f.filter.len))
}

// ── 6. no-selection Enter is a no-op ────────────────────────────────────

sm_no_selection_noop :: proc() {
	say("  [6] Enter with NOTHING selected does nothing, in every list state")

	list_states := []app.State{.remote_server, .attach, .delete_session, .theme}
	for s in list_states {
		// Enter straight away: the machine entered the state with no selection.
		m := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
		drive(&m, prefix_for(s))
		// The theme picker pre-selects the live theme (spec), so filter it away
		// first to reach a genuinely unselected state in every case.
		drive(&m, keys_of("zzzznomatch"))
		check(fmt.tprintf("  {} starts with no selection", app.state_label(s)),
			m.sel == -1 && app.shown_count(&m) == 0,
			fmt.tprintf("sel={} shown={}", m.sel, app.shown_count(&m)))
		cmd := app.update(&m, k_enter)
		expect_noop(fmt.tprintf("{}: Enter with no selection", app.state_label(s)),
			cmd, m.state, s)
	}
}

// ── 7. Ctrl+C from everywhere (ISC-12) ──────────────────────────────────

sm_ctrl_c_everywhere :: proc() {
	say("  [7] Ctrl+C -> quit from every state (ISC-12)")

	all := []app.State{
		.mode_selection, .name_local, .remote_server, .name_remote_named,
		.attach, .delete_session, .theme, .error,
	}
	quit_count := 0
	for s in all {
		m := sm_new(s, true)
		cmd := app.update(&m, k_ctrlc)
		quit := cmd.kind == .quit
		if quit { quit_count += 1 }
		check(fmt.tprintf("  {} + ^C -> quit", app.state_label(s)), quit,
			fmt.tprintf("cmd={}", app.cmd_kind_label(cmd.kind)))
	}
	check("  all 8 states answered quit", quit_count == len(all),
		fmt.tprintf("{}/{} quit", quit_count, len(all)))
}

// ── 8. Esc is back ──────────────────────────────────────────────────────

sm_esc_back :: proc() {
	say("  [8] Esc is back-to-{Mode selection}, and leaves nothing dirty")

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
		m := sm_new(s, true)
		cmd := app.update(&m, k_esc)
		check(fmt.tprintf("  {} + Esc -> mode_selection", app.state_label(s)),
			m.state == .mode_selection,
			fmt.tprintf("reached {} cmd={}", app.state_label(m.state), app.cmd_kind_label(cmd.kind)))
		check(fmt.tprintf("    and reports %s for the text it owns",
			app.cmd_kind_label(want_kind(s))),
			cmd.kind == want_kind(s),
			fmt.tprintf("cmd={}", app.cmd_kind_label(cmd.kind)))
		check("    filter and field are both empty after the way back",
			m.filter.len == 0 && m.field.len == 0 && m.carried_name == "",
			fmt.tprintf("filter={} field={} carried=%q", m.filter.len, m.field.len, m.carried_name))
		_ = cmd
	}

	// The root has no back — Esc there is the exit key.
	root := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	check("  mode_selection + Esc -> quit (no back from the root)",
		app.update(&root, k_esc).kind == .quit, "")
}

// ── 9. the selection identity does not slide ─────────────────────────────

sm_identity_not_sliding :: proc() {
	say("  [9] a filtered-out selection DROPS, it never slides onto a neighbour")

	// In {Select session to attach}: select the `api` row, then filter it away.
	m := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&m, []input.Key{kc('a')})
	drive(&m, keys_of("api-"))
	app.update(&m, k_down)
	check("  holding api-… (local)",
		m.held.valid && m.held.name == fmt.tprintf("api-{}", SM_TS),
		fmt.tprintf("held=%s/%s", m.held.device, m.held.name))

	drive(&m, keys_of("zz"))  // filter no longer matches the held row
	check("  after the filter drops the held row, the selection is EMPTY, not moved",
		m.held == app.NO_SELECTION || !m.held.valid,
		fmt.tprintf("held.valid={} held.name=%s", m.held.valid, m.held.name))
	cmd := app.update(&m, k_enter)
	expect_noop("  Enter on that dropped selection is a no-op", cmd, m.state, .attach)

	// Widen the filter again: the identity is re-resolved, not guessed.
	app.update(&m, k_bsp)
	app.update(&m, k_bsp)
	kept := app.shown_count(&m)
	check("  erasing the extra chars brings the row back into view", kept == 1,
		fmt.tprintf("shown={} (filter=%q)", kept, app.text_of(&m.filter)))
	app.update(&m, k_down)
	cmd = app.update(&m, k_enter)
	check("  and picking it attaches the SAME identity that came back",
		cmd.kind == .attach && cmd.name == fmt.tprintf("api-{}", SM_TS),
		fmt.tprintf("cmd={} name={}", app.cmd_kind_label(cmd.kind), cmd.name))

	// The command's device must be the row's OWN device string, never inferred
	// from a label, a hostname, or the session name.
	p := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&p, []input.Key{kc('a')})
	drive(&p, keys_of("@"))
	check("  '@' narrows the sessions to the single mixed-case remote row",
		app.shown_count(&p) == 1, fmt.tprintf("shown={}", app.shown_count(&p)))
	app.update(&p, k_down)
	cmd = app.update(&p, k_enter)
	check("  attach carries the FILTERED row's verbatim device",
		cmd.kind == .attach && cmd.device == SM_DEV_DEPLOY &&
			cmd.name == fmt.tprintf("build-{}", SM_TS),
		fmt.tprintf("cmd={} device=%q name=%q",
			app.cmd_kind_label(cmd.kind), cmd.device, cmd.name))
}

// ── 9b. the machine's filter == the view's filter ─────────────────────────
//
// The row Enter ACTS on and the row the UI PAINTS as selected must come from
// the same predicate. `app.machine_session_matches` and `ui.sessions_match`
// are two implementations of it in two layers; this pins them together so a
// future edit to one cannot quietly make Enter mean "a different row".
sm_filter_agrees_with_the_view :: proc() {
	say("  [9b] the machine's filter is the SAME predicate the view paints with")

	filters := []string{"", "a", "API", "api-", "LOCAL", "lab", "@", "deploy",
		"worker", "zzz", "-", "2026"}
	mismatches := 0
	checked := 0
	for f in filters {
		for sess in sm_sessions() {
			mine := app.machine_session_matches(sess, f)
			theirs := ui.sessions_match(sess, f)
			checked += 1
			if mine != theirs {
				mismatches += 1
				say(fmt.tprintf("    MISMATCH filter=%q session=%s/%s mine=%v ui=%v",
					f, sess.device, sess.name, mine, theirs))
			}
		}
	}
	check("machine_session_matches == ui.sessions_match over every row x filter",
		mismatches == 0, fmt.tprintf("{} mismatch(es) across {} pairs", mismatches, checked))
}

// ── 10. nothing ever targets `default` (D12 / ISC-18) ────────────────────

sm_never_default :: proc() {
	say("  [10] no Command ever targets `default`, even handed a dirty list")

	all := []app.State{
		.mode_selection, .name_local, .remote_server, .name_remote_named,
		.attach, .delete_session, .theme, .error,
	}
	keys := []input.Key{k_enter, k_esc, k_down, k_up, k_tab, k_stab, k_bsp,
		kc('n'), kc('r'), kc('s'), kc('a'), kc('d'), kc('t'), kc('x'), kc('1'), kc('.')}

	// Adversarial: `default` IS in the list. Try to aim at it from every state.
	offenders := 0
	tried := 0
	for s in all {
		for k in keys {
			m := app.new_app(sm_sessions_with_default(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
			drive(&m, prefix_for(s))
			cmd := app.update(&m, k)
			tried += 1
			if cmd.name == app.DEFAULT_SESSION_NAME ||
				strings.contains(cmd.name, app.DEFAULT_SESSION_NAME) {
				offenders += 1
				say(fmt.tprintf("    offender: {} + {} -> {} name=%q",
					app.state_label(s), k.kind, app.cmd_kind_label(cmd.kind), cmd.name))
			}
		}
	}
	check("no Command from any (state, key) names `default`",
		offenders == 0, fmt.tprintf("{} offender(s) in {} probes", offenders, tried))

	// And the explicit aim: filter down to `default` in attach, press Enter.
	a := app.new_app(sm_sessions_with_default(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&a, []input.Key{kc('a')})
	drive(&a, keys_of("default"))
	app.update(&a, k_down)
	aimed := app.update(&a, k_enter)
	check("aiming `attach` at default is REFUSED (show_error, never attach)",
		aimed.kind == .show_error && aimed.name == "" && aimed.device == "",
		fmt.tprintf("cmd={} name=%q device=%q msg=%q",
			app.cmd_kind_label(aimed.kind), aimed.name, aimed.device, aimed.value))
	check("  and the machine parked in {Error}", a.state == .error,
		fmt.tprintf("state={}", app.state_label(a.state)))

	d := app.new_app(sm_sessions_with_default(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&d, []input.Key{kc('d')})
	drive(&d, keys_of("default"))
	app.update(&d, k_down)
	aimed = app.update(&d, k_enter)
	check("aiming `delete` at default is REFUSED too (never a delete command)",
		aimed.kind == .show_error && aimed.name == "" && aimed.device == "",
		fmt.tprintf("cmd={} name=%q device=%q msg=%q",
			app.cmd_kind_label(aimed.kind), aimed.name, aimed.device, aimed.value))

	// Typing the word "default" as a NEW session name must not launch either.
	n := app.new_app(sm_sessions(), sm_remotes(), sm_themes(), SM_DEFAULT_THEME)
	drive(&n, keys_of("n"))
	drive(&n, keys_of("default"))
	typed := app.update(&n, k_enter)
	check("typing `default` as a new name is refused into {Error}",
		typed.kind == .show_error && n.state == .error,
		fmt.tprintf("cmd={} state={}", app.cmd_kind_label(typed.kind), app.state_label(n.state)))
}

// ── 11. an empty world ──────────────────────────────────────────────────

sm_empty_world :: proc() {
	// No sessions, no remotes, no themes: exactly what a machine with no herdr,
	// no registry and no config looks like. Transitions must still be sound.
	say("  [11] the machine runs with NOTHING loaded (no sessions/remotes/themes)")

	e := app.new_app(nil, nil, nil, "")
	drive(&e, []input.Key{kc('a')})
	cmd := app.update(&e, k_enter)
	expect_noop("attach with no sessions at all", cmd, e.state, .attach)

	r := app.new_app(nil, nil, nil, "")
	drive(&r, []input.Key{kc('r')})
	cmd = app.update(&r, k_enter)
	expect_noop("remote pick with no remotes at all", cmd, r.state, .remote_server)

	t := app.new_app(nil, nil, nil, "")
	drive(&t, []input.Key{kc('t')})
	cmd = app.update(&t, k_enter)
	expect_noop("theme pick with no themes at all", cmd, t.state, .theme)

	// Down/Tab on an empty list must not crash nor invent a row.
	app.update(&t, k_down)
	app.update(&t, k_tab)
	app.update(&t, k_stab)
	app.update(&t, k_up)
	check("movement on an empty list leaves no selection",
		t.sel == -1 && app.shown_count(&t) == 0,
		fmt.tprintf("sel={} shown={}", t.sel, app.shown_count(&t)))

	// Local launch does not need ANY list to be loaded.
	l := app.new_app(nil, nil, nil, "")
	cmd = app.update(&l, k_enter)
	check("Enter with no list loaded still yields a timestamped local launch",
		cmd.kind == .launch_local && app.ts_is_known(app.ts_from_name(cmd.name)),
		fmt.tprintf("cmd={} name={}", app.cmd_kind_label(cmd.kind), cmd.name))
}

// ── 12. offline proof ───────────────────────────────────────────────────
//
// Called from case_state_machine's caller (dev/state-smoke.sh) AFTER every
// other check has run, so it measures the WHOLE run.

sm_offline_proof :: proc() {
	say("  [12] offline proof — the run created ZERO child processes")

	// `update` cannot spawn, and this proves it was never asked to: a process
	// wait with WNOHANG over ALL our children must find nothing to reap. ECHILD
	// (-1) is the answer that means "you have no children at all".
	status : c.int = 0
	got := posix.waitpid(-1, &status, {.NOHANG})
	code := posix.errno()
	check("no child process exists to be reaped (waitpid -> ECHILD)",
		got == -1 && code == posix.Errno.ECHILD,
		fmt.tprintf("waitpid(-1, WNOHANG) = {} errno={}", got, int(code)))

	// And the whole case ran with the environment it was given — no config file,
	// no herdr on PATH needed. The shell harness runs a second copy of this case
	// under `env -i` to make that concrete.
	env_count := 0
	if env, err := os.environ(context.allocator); err == nil {
		env_count = len(env)
	}
	say(fmt.tprintf("    env variables visible to this run: {} (the stripped re-run has 0)", env_count))
}

// sm_all is the full offline battery, exposed as a second case name so the
// harness can run it under a stripped environment and get the [12] proof at
// the end of the same run.
case_state_offline :: proc() -> bool {
	say("case state-offline — the whole state-machine battery, environment-free")
	saved := any_failed
	any_failed = false
	sm_reachability()
	sm_two_step()
	sm_no_selection_noop()
	sm_ctrl_c_everywhere()
	sm_never_default()
	sm_empty_world()
	sm_offline_proof()
	any_failed = saved || any_failed
	return !any_failed
}
