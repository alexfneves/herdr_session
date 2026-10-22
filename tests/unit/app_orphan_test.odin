package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_orphan_test.odin — T10 port of `live_orphan_rule` (src/app_live.odin:380)
// and `live_nesting_differential` (:134). 23 assertions.
//
// WHY THE ASSERTIONS SIT ON THE GUARD AND NOT THE HAZZARD
//
// The three things this used to assert were properties of herdr 0.8.2. RCH-2
// moved the ground: 0.9.5 got a clean terminal check and stopped orphaning on
// an aborted launch. Asserting on the hazard therefore means the suite goes
// red the day someone upgrades — and a suite that goes red on an upgrade stops
// being evidence about US.
//
//   BEFORE (pinned to 0.8.2)            AFTER (version-tolerant, O11/O12)
//   ----------------------------        -----------------------------------
//   exit must be 101                    exit must be 101 OR 1-with-a-clean-
//                                     message — outcome_needs_terminal
//   the aborted launch must still       the GUARD must refuse an unknown name,
//   leave a live session (the hazard)   and must fork NOTHING at all
//   a baseline of KNOWN session names   a baseline read LIVE, by prefix
//
// "Whether upstream orphans" is not our contract. "We never hand an
// unvalidated name to herdr" is, and it holds on 0.8.2, 0.9.5, and anything
// between.
//
// WHAT prove_no_fork BUYS
//
// A guard that returns false only proves what the function SAID about
// itself. `waitpid(-1, WNOHANG)` answering ECHILD proves there is no child in
// THIS process at all, so the guard cannot have spawned one on its way out.
// That is the difference between "the code says no" and "nothing happened".
// ─────────────────────────────────────────────────────────────────────────────

import cc "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:sys/posix"
import "core:testing"

import app "../../src/app"
import support "../support"

AOR_SCRATCH :: "hs-t-phase3-probe"
AOR_SCRATCH_NEVER :: "hs-t-never-created-zz"

aor_list_now :: proc() -> []app.Session {
	cs := app.run_capture(app.list_argv(), app.CAPTURE_TIMEOUT)
	rows, _ := app.parse_session_list(cs.out, app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	return rows
}

aor_contains_name :: proc(rows: []app.Session, name: string) -> bool {
	for r in rows { if r.name == name { return true } }
	return false
}

aor_names_of :: proc(rows: []app.Session) -> string {
	parts: [dynamic]string = {}
	for r in rows { append(&parts, r.name) }
	j, _ := strings.join(parts[:], ",")
	return j
}

aor_scratch_names_now :: proc() -> [dynamic]string {
	out: [dynamic]string = {}
	for r in aor_list_now() {
		if strings.has_prefix(r.name, support.SCRATCH_PREFIX) { append(&out, r.name) }
	}
	return out
}

aor_joined :: proc(names: []string) -> string {
	parts: [dynamic]string = {}
	for n in names { append(&parts, fmt.tprintf("'{}'", n)) }
	body, _ := strings.join(parts[:], ", ")
	return fmt.tprintf("[{}]", body)
}

// aor_prove_no_fork is the evidence half of a guard assertion: ECHILD from
// waitpid(-1, WNOHANG) means this process has no child to reap, so nothing
// was spawned. It is called IMMEDIATELY after the guard, before any other
// proc in this test can create one.
aor_prove_no_fork :: proc(c: ^AU_Ctx, label: string) {
	st := cc.int(0)
	kid := posix.waitpid(-1, &st, {.NOHANG})
	er := int(posix.errno())
	au_check(c, fmt.tprintf("{} forked nothing", label),
		kid == -1 && er == 10,
		fmt.tprintf("waitpid(-1,WNOHANG) = {} errno={} (10 = ECHILD)", kid, er))
}

// ── the nesting differential ───────────────────────────────────────────────

@(test)
aor_scrub_is_load_bearing_nesting_differential :: proc(t: ^testing.T) {
	c := au_live(t)
	// The same command, once through our scrubbed environment and once with
	// HERDR_ENV re-injected by the child itself.
	//
	//   Scrubbed  → the nesting check never fires (the run proceeds and dies
	//              later on the absent tty).
	//   Injected  → herdr refuses at the door, "nested herdr is disabled".
	//
	// That pair is the evidence the scrub is load-bearing: remove it and every
	// create/attach from inside a herdr pane hits the second line.
	scrubbed := app.run_capture({app.HERDR_BIN, "--session", AOR_SCRATCH}, 20 * time.Second)
	au_say(&c, fmt.tprintf("  scrubbed   `{} --session {}` → exit {}",
		app.HERDR_BIN, AOR_SCRATCH, scrubbed.code))
	au_check(&c, "scrubbed launch is NOT refused as nested",
		!strings.contains(string(scrubbed.err), "nested herdr is disabled"),
		fmt.tprintf("exit={} stderr={}", scrubbed.code, aor_first(scrubbed.err)))

	injected := app.run_capture(
		{"sh", "-c", fmt.tprintf("{}=1 exec {} --session {}", "HERDR_ENV",
			app.HERDR_BIN, AOR_SCRATCH)}, 20 * time.Second)
	au_say(&c, fmt.tprintf("  injected   HERDR_ENV=1 `{} --session {}` → exit {}",
		app.HERDR_BIN, AOR_SCRATCH, injected.code))
	au_check(&c, "HERDR_ENV present → herdr refuses with the nesting error",
		strings.contains(string(injected.err), "nested herdr is disabled"),
		fmt.tprintf("exit={} stderr={}", injected.code, aor_first(injected.err)))
	au_eq_i(&c, "the nesting refusal is the documented exit 1 (herdr error)",
		i64(injected.code), 1)
}

aor_first :: proc(b: []byte) -> string {
	s := string(b)
	idx := strings.index(s, "\n")
	if idx < 0 { return s }
	return s[:idx]
}

// ── the guard, not the hazard ──────────────────────────────────────────────

@(test)
aor_baseline_is_read_live_by_prefix :: proc(t: ^testing.T) {
	c := au_live(t)
	// Dynamic baseline: what `hs-t-*` sessions already exist. Nothing named
	// this way is legitimately there, so a non-empty baseline is itself a
	// finding — and, unlike a hard-coded list, this one cannot be quietly
	// invalidated by the user creating or removing their own sessions.
	baseline := aor_scratch_names_now()
	au_check(&c, "baseline is read live, not recalled from a plan (O12.3)",
		len(baseline) == 0,
		fmt.tprintf("{} pre-existing `hs-t-*` session(s): {}", len(baseline),
			aor_joined(baseline[:])))
}

@(test)
aor_no_terminal_launch_is_a_verdict_not_an_error :: proc(t: ^testing.T) {
	c := au_live(t)
	// The hazard itself, REPORTED and never asserted-on. Built by hand ON
	// PURPOSE (not via launch_argv): this reproduces the raw create-or-attach
	// failure so we can see what the installed herdr does, and nothing else.
	orphan_argv: [dynamic]string = {}
	append(&orphan_argv, app.HERDR_BIN, "--session")
	append(&orphan_argv, AOR_SCRATCH)
	cs := app.run_capture(orphan_argv[:], 20 * time.Second)
	kind, _, _ := app.outcome(&cs)
	au_say(&c, fmt.tprintf("    raw `{} --session {}` with no tty -> exit {} · {} · {} B of stderr",
		app.HERDR_BIN, AOR_SCRATCH, cs.code, app.outcome_label(kind), len(cs.err)))

	// THE version-tolerant half. `outcome_needs_terminal` is true for 101
	// (the panic 0.8.2 produces) and for 1-with-a-clean-message (0.9.3+).
	// Which one the user has is not our business; that BOTH answer it is.
	au_check(&c, "a launch with no terminal is recognised as such on EITHER herdr (O12.1)",
		app.outcome_needs_terminal(kind),
		fmt.tprintf("exit={} -> {}", cs.code, app.outcome_label(kind)))

	// Was, before this was fixed: `kind != .herdr_error ||
	// !outcome_needs_terminal(kind)` — a TAUTOLOGY.
	// outcome_needs_terminal(.herdr_error) is false by definition, so the
	// second operand was true whenever the first was false and the check
	// could never fail. It is now the assertion the label always claimed: a
	// no-terminal launch must be a TTY verdict, never a parsed herdr error.
	// If the envelope parser ever became eager enough to grab panic text,
	// THIS fails.
	au_check(&c, "…and the no-terminal verdict is a TTY shape, never a parsed herdr error",
		kind != .herdr_error && (kind == .tty_panic || kind == .tty_unavailable),
		fmt.tprintf("kind={} (must be .tty_panic or .tty_unavailable)",
			app.outcome_label(kind)))

	// Whether the aborted launch orphaned a session is REPORTED, not
	// asserted: 0.8.2 said yes, 0.9.5 says no.
	left_it := aor_contains_name(aor_list_now(), AOR_SCRATCH)
	au_say(&c, fmt.tprintf("    this herdr's hazard answer: aborted launch left a live session = {}",
		left_it))
	au_say(&c, "      (reported only — 0.8.2 true, 0.9.5 false; the GUARD is the contract)")
}

@(test)
aor_guards_refuse_and_fork_nothing :: proc(t: ^testing.T) {
	c := au_live(t)
	// Attaching an unvalidated name is refused before an argv exists. The
	// boolean is half the proof; ECHILD is the other half.
	rows := aor_list_now()
	unknown := "hs-t-not-in-the-model"
	g := app.attach_guard(rows, app.DEVICE_LOCAL, unknown)
	aor_prove_no_fork(&c, "attach_guard(unknown)")
	au_check(&c, "attach_guard still refuses an unvalidated name (O11: never attached)",
		!g.ok, fmt.tprintf("{}", g.reason))
	au_check(&c, "…and the reason names the consequence, not just the rule",
		strings.contains(g.reason, "CREATE"), fmt.tprintf("\"{}\"", g.reason))

	dg := app.delete_guard(rows, app.DEVICE_LOCAL, AOR_SCRATCH_NEVER)
	aor_prove_no_fork(&c, "delete_guard(never-created)")
	au_check(&c, "delete_guard still refuses a name it never saw (O11: pre-check kept)",
		!dg.ok, fmt.tprintf("{}", dg.reason))
	au_check(&c, "…and says nothing was destroyed where herdr would have said 'deleted'",
		strings.contains(dg.reason, "nothing was deleted"), fmt.tprintf("\"{}\"", dg.reason))

	// The argv builders refuse too, so even a caller that skipped the guard
	// has nothing to spawn. Two independent doors, both shut.
	_, bad_launch := app.launch_argv(app.DEVICE_LOCAL, "bad name")
	_, bad_attach := app.attach_argv("default")
	au_check(&c, "our launch/attach produce NO argv for an invalid or default name",
		!bad_launch && !bad_attach, fmt.tprintf("launch_ok={} attach_ok={}", bad_launch, bad_attach))
	au_check(&c, "attaching an unknown name is refused in-app (ISC-17)",
		!app.is_known_session(rows, app.DEVICE_LOCAL, unknown),
		"the model is the gate, not herdr's answer")
}

@(test)
aor_run_leaves_no_scratch_behind :: proc(t: ^testing.T) {
	c := au_live(t)
	// The same prefix sweep that started at zero must end at zero —
	// whoever created the leftovers.
	leftover := aor_scratch_names_now()
	au_check(&c, fmt.tprintf("this run leaves no `{}*` session behind, by prefix",
		support.SCRATCH_PREFIX),
		len(leftover) == 0,
		fmt.tprintf("{} left: {}", len(leftover), aor_joined(leftover[:])))
}
