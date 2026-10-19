package app

// -----------------------------------------------------------------------------
// T5.5 — THE EXECUTOR
//
// `state.update` decides; this file *does*. It is the only place in the program
// where a Command turns into a process, a deletion, a theme change or an exit, and
// that concentration is the design: one choke point where the safety rules can be
// read, audited and tested in one screen, instead of seven call sites each
// remembering a slightly different subset of them.
//
// The rules that live here, and why each one is a rule and not a preference:
//
//  1. **Validate against the loaded model before spawning an attach.**
//     `herdr session attach <name>` is create-or-attach. An attach aimed at a name
//     we never saw running does not fail — it CREATES a session. The user asked to
//     look at something and we left a live thing behind. That is the orphan rule
//     (ISC-17) and it is the single most expensive mistake available here.
//
//  2. **Never target `default`** (D12). It is herdr's own workspace.
//
//  3. **A delete must have a row.** herdr answers `{"deleted":true}` to names
//     that never existed, so an unguarded delete reports success about a thing
//     that was never there. The model decides, not herdr (ISC-16).
//
//  4. **The device is part of the argv.** A delete/attach aimed at a remote row
//     has to reach that host — `control_argv` wraps it in our own ssh, because
//     `herdr --remote X session delete` is not a thing herdr accepts.
//
//  5. **The terminal leaves us and comes back through one door.** `handoff_run`
//     shuts termbox down, runs the child on the real tty in our own foreground
//     process group, and re-enters with a forced full repaint. The env scrub, the
//     `$HOME` cwd and the SIGINT/SIGQUIT dance all live in T2 and are reused
//     verbatim — the executor adds no terminal logic of its own.
//
//  6. **Cleanup is policy, not reflex.** D2 is parked at `never`, so after a
//     detach we destroy nothing. The seam is still wired, so when D2 lands the
//     answer changes in one place (see `post_detach`).
//
// Nothing here reads the keyboard, paints a cell, or knows the poll loop exists.
// Effect :: exec — that is the whole contract.
// -----------------------------------------------------------------------------

import "core:fmt"
import "core:time"

import terminal "../terminal"

// Effect_Kind is what the executor actually did. The poll loop maps these onto UI
// consequences (repaint, error pane, exit) and nothing else.
Effect_Kind :: enum {
	none,     // nothing to perform (filter/field clearing)
	child,    // the terminal went to a child and came back
	deleted,  // a session we verified existed is gone
	refused,  // we said no — and, critically, spawned NOTHING
	applied,  // an in-process change took effect (theme)
	quit,     // the app should exit
}

// Effect is the full answer to one Command.
//
// `argv` is always filled — even for a refusal — so the log can show the command
// we did NOT run, which is the difference between "we refused" and "we never got
// that key".
Effect :: struct {
	kind    : Effect_Kind,
	argv    : []string,
	message : string,         // one honest human line for the pane / log
	handoff : terminal.Handoff,
	refresh : bool,          // the model went stale: re-fetch local + remotes
	theme   : string,        // set when kind == .applied
}

// -----------------------------------------------------------------------------
// Pre-spawn guards (pure — no process can escape them)
// -----------------------------------------------------------------------------

Guard :: struct {
	ok     : bool,
	reason : string,
}

// attach_guard is the orphan gate. It is a pure function over the model so it can
// be tested with no terminal, no child and no side effect — and so the executor
// cannot "forget" to consult it.
//
// The check is the IDENTITY (device, name), never the name alone: a name that is
// running on `local` says nothing about the same name on a remote host.
attach_guard :: proc(rows: []Session, device: string, name: string) -> Guard {
	if is_default_session_name(name) {
		return Guard{ok = false,
			reason = "'default' is herdr's own workspace and is never attached (D12)"}
	}
	if v := validate_name(name); !v.ok {
		return Guard{ok = false, reason = fmt.tprintf("bad session name: {}", v.reason)}
	}
	if !is_known_session(rows, device, name) {
		return Guard{ok = false, reason = fmt.tprintf(
			"{} is not running on {} — attach refused (attaching an unknown name would CREATE it)",
			name, device)}
	}
	return Guard{ok = true}
}

// delete_guard mirrors the model's answer before we ask herdr anything. The
// wording matters: "nothing was deleted" is the truth for a name we never saw,
// where herdr would have said "deleted".
delete_guard :: proc(rows: []Session, device: string, name: string) -> Guard {
	if is_default_session_name(name) {
		return Guard{ok = false,
			reason = "'default' is herdr's own workspace and is never deleted (D12)"}
	}
	if v := validate_name(name); !v.ok {
		return Guard{ok = false, reason = fmt.tprintf("bad session name: {}", v.reason)}
	}
	if !is_known_session(rows, device, name) {
		return Guard{ok = false, reason = fmt.tprintf(
			"{} is not in our list for {} — nothing was deleted", name, device)}
	}
	return Guard{ok = true}
}

// -----------------------------------------------------------------------------
// The one entry point
// -----------------------------------------------------------------------------

// execute performs `cmd` against the CURRENT model `rows`, running any child with
// cwd `home` and a per-command capture budget.
//
// `rows` must be the freshest view of the world: every guard below is only as
// good as the model it is handed, which is why the poll loop passes its live
// table rather than a snapshot taken at startup.
execute :: proc(cmd: Command, rows: []Session, home: string,
               budget: time.Duration) -> Effect {
	switch cmd.kind {
	case .none, .clear_filter, .clear_field:
		return Effect{kind = .none}

	case .show_error:
		// The machine already parked itself in {Error}; the executor just echoes
		// the line so nothing is silently swallowed at this layer either.
		return Effect{kind = .refused, message = cmd.value}

	case .quit:
		return Effect{kind = .quit}

	case .launch_local, .launch_remote:
		return do_launch(cmd, home)

	case .attach:
		return do_attach(cmd, rows, home)

	case .delete:
		return do_delete(cmd, rows, budget)

	case .set_theme:
		return do_theme(cmd)
	}
	return Effect{kind = .none}
}

// -----------------------------------------------------------------------------
// launch — create-or-attach, local or remote
// -----------------------------------------------------------------------------

// A launch needs no existence pre-check: the machine generated the name and
// already proved it free on that device (`new_session_command` checks
// `names_for_device`). What we DO check is the charset, via `launch_argv`, and
// that the resulting child gets the device verbatim.
do_launch :: proc(cmd: Command, home: string) -> Effect {
	argv, ok := launch_argv(cmd.device, cmd.name)
	if !ok {
		return Effect{kind = .refused,
			message = fmt.tprintf("refused to launch {}: invalid session name", cmd.name)}
	}
	eff := run_child(argv, home)
	eff.refresh = true
	// We asked for this name to exist, so it is the one candidate for cleanup
	// once the child is gone. Under the parked policy this is a no-op sentence.
	if eff.kind == .child {
		eff.message = fmt.tprintf("{} — {}", eff.message, post_detach(cmd.name, true))
	}
	return eff
}

// -----------------------------------------------------------------------------
// attach — guarded, because attach CREATES
// -----------------------------------------------------------------------------

do_attach :: proc(cmd: Command, rows: []Session, home: string) -> Effect {
	g := attach_guard(rows, cmd.device, cmd.name)
	if !g.ok {
		// No argv is built and no process is spawned. `argv` stays empty, which
		// is the evidence.
		return Effect{kind = .refused, message = g.reason}
	}

	// Local attaches through `herdr session attach` (the named subcommand);
	// remote goes through `herdr --remote <device> --session <name>`, because
	// herdr forwards nothing else over --remote (verbatim rule 11). Either way
	// the device travels verbatim.
	argv : []string
	if is_local_device(cmd.device) {
		a, ok := attach_argv(cmd.name)
		if !ok {
			return Effect{kind = .refused,
				message = fmt.tprintf("refused to attach {}: invalid session name", cmd.name)}
		}
		argv = a
	} else {
		a, ok := launch_argv(cmd.device, cmd.name)
		if !ok {
			return Effect{kind = .refused,
				message = fmt.tprintf("refused to attach {}: invalid session name", cmd.name)}
		}
		argv = a
	}

	eff := run_child(argv, home)
	eff.refresh = true
	// The user's own session: `only_created` must never touch it, and `never`
	// touches nothing. Passing we_created = false is what makes that distinction
	// real rather than assumed.
	if eff.kind == .child {
		eff.message = fmt.tprintf("{} — {}", eff.message, post_detach(cmd.name, false))
	}
	return eff
}

// -----------------------------------------------------------------------------
// delete — stop if running, then delete, and never claim more than we knew
// -----------------------------------------------------------------------------

do_delete :: proc(cmd: Command, rows: []Session, budget: time.Duration) -> Effect {
	// The guard runs first so an unknown name never even reaches herdr.
	// `delete_session` re-checks internally (defence in depth) and refuses the
	// same way; both layers must agree, and `app-unit` pins that.
	g := delete_guard(rows, cmd.device, cmd.name)
	if !g.ok {
		return Effect{kind = .refused, message = g.reason}
	}

	r := delete_session(rows, cmd.device, cmd.name, budget)
	if r.refused {
		return Effect{kind = .refused, message = r.reason}
	}
	note := fmt.tprintf("{} deleted from {}", cmd.name, cmd.device)
	if r.was_running {
		note = fmt.tprintf("{} was running: stopped, then deleted from {}", cmd.name, cmd.device)
	}
	return Effect{kind = .deleted, message = note, refresh = true}
}

// -----------------------------------------------------------------------------
// theme — apply now; persisting is T6.1's job, not ours
// -----------------------------------------------------------------------------

do_theme :: proc(cmd: Command) -> Effect {
	// APPLYING means the palette behind the next frame. T6.2 owns the palette set;
	// until then there is exactly one palette and applying is recording the name.
	// PERSISTING means the config writer, which is T6.1 and does not exist yet —
	// so we say that out loud instead of silently dropping the request.
	return Effect{
		kind    = .applied,
		theme   = cmd.value,
		message = fmt.tprintf(
			"theme '{}' applied for this run (config persistence arrives with T6.1)", cmd.value),
	}
}

// -----------------------------------------------------------------------------
// The single door out to a child and back
// -----------------------------------------------------------------------------

// run_child is the ONLY call to handoff_run in the program. Everything about
// owning/releasing the terminal, the scrubbed env and the `$HOME` cwd is T2's
// and is reused untouched.
run_child :: proc(argv: []string, home: string) -> Effect {
	h := terminal.handoff_run(argv, home)
	eff := Effect{kind = .child, argv = argv, handoff = h}
	if !h.ok {
		// We could not get the screen back. handoff_run already told the user to
		// run `reset`; the loop must still not repaint into a screen we do not
		// own, so this arrives as a refusal and the caller exits.
		eff.kind = .refused
		eff.message = fmt.tprintf(
			"could not re-acquire the terminal after {} (tb_init -> {}). Run `reset` if the screen looks wrong.",
			argv[0], h.err)
		return eff
	}
	eff.message = fmt.tprintf("{} exited with code {}", argv[0], h.exit)
	return eff
}

// -----------------------------------------------------------------------------
// The D2 seam — wired, not invented
// -----------------------------------------------------------------------------

// post_detach runs right after a handoff returns, and asks the policy whether the
// session we just left should be destroyed. With D2 parked at `never` it destroys
// nothing and reports that, which is the point: the seam is exercised on every
// detach so the day D2 is decided it is one constant, not a code hunt.
post_detach :: proc(name: string, we_created: bool) -> string {
	p := cleanup_policy()
	if !cleanup_should_run(p, name, we_created) {
		return fmt.tprintf("cleanup_policy={}: {} left running",
			cleanup_policy_label(p), name)
	}
	run_capture(stop_argv(name), CAPTURE_TIMEOUT)
	run_capture(delete_argv(name), CAPTURE_TIMEOUT)
	return fmt.tprintf("cleanup_policy={}: {} stopped and deleted", cleanup_policy_label(p), name)
}

cleanup_policy_label :: proc(p: Cleanup_Policy) -> string {
	switch p {
	case .never:        return "never"
	case .only_created: return "only_created"
	case .always:       return "always"
	}
	return "?"
}
