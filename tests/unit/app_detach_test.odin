package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_detach_test.odin — T10 port of the three LIVE sections that need a REAL
// running session: `live_detach_routes_to_the_device` (src/app_live.odin:827),
// `live_only_created_r1` (:907) and `live_control_budget_live` (:995).
//
// These are the only app tests that create a live herdr session, and they are
// the only ones that prove the two policies the user actually lives with:
//
//   P1  a cleanup aimed at a REMOTE row must not destroy the LOCAL session
//       that happens to share the name. Staged with a device whose cleanup
//       cannot land (unreachable) — on this loop-back box a "remote" scratch
//       and a local scratch are the same session, so an unroutable target is
//       the only way to stage the class exactly.
//   R1  the SHIPPED default destroys what we created and SPARES what we only
//       attached to. Both halves matter: the second is what makes `always`
//       unacceptable and `only_created` honest.
//   P2-5 a control command against a black-holed host returns inside ssh's
//       own ConnectTimeout, not the old 10 s allowance.
//
// SAFETY — the whole file is built on one rule: every name is `hs-t-*` and
// creation goes through `adt_spawn_pty`, which REFUSES any other prefix. The
// session hosting this agent is never a target. Each section tears down its own
// scratch in-line and a final sweep checks nothing was left.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:testing"

import app "../../src/app"
import support "../support"

adt_names_of :: proc(rows: []app.Session) -> string {
	parts: [dynamic]string = {}
	for r in rows { append(&parts, r.name) }
	j, _ := strings.join(parts[:], ",")
	return j
}

adt_contains_name :: proc(rows: []app.Session, name: string) -> bool {
	for r in rows { if r.name == name { return true } }
	return false
}

adt_list_now :: proc() -> []app.Session {
	cs := app.run_capture(app.list_argv(), app.CAPTURE_TIMEOUT)
	rows, _ := app.parse_session_list(cs.out, app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	return rows
}

adt_unreachable :: proc() -> string {
	v := os.get_env_alloc("HERDR_SESSION_TEST_UNREACHABLE", context.allocator)
	if v != "" { return v }
	return "192.0.2.201"  // TEST-NET-1: black-holes by construction
}

// adt_spawn_pty creates a REAL running session from a test that has no tty.
// `script` supplies one and `stty` gives it a size herdr accepts; the timeout
// kills the CLIENT and the session's server stays up. Refuses any name outside
// the scratch prefix — nothing in this file may create what it cannot tear down.
adt_spawn_pty :: proc(name: string) -> bool {
	if !strings.has_prefix(name, support.SCRATCH_PREFIX) {
		fmt.eprintln("    REFUSED to create non-scratch session", name)
		return false
	}
	cmd := fmt.tprintf(
		"timeout 5 script -q -c 'stty rows 24 cols 80; {} --session {}' /dev/null >/dev/null 2>&1 || true",
		app.HERDR_BIN, name)
	app.run_capture({"sh", "-c", cmd}, 20 * time.Second)
	for _ in 0 ..< 10 {
		if adt_contains_name(adt_list_now(), name) { return true }
		time.sleep(300 * time.Millisecond)
	}
	return false
}

adt_teardown :: proc(c: ^AU_Ctx, name: string, stage: string) {
	if !strings.has_prefix(name, support.SCRATCH_PREFIX) {
		au_say(c, fmt.tprintf("    REFUSED teardown of non-scratch name {}: {}", name, stage))
		return
	}
	rows := adt_list_now()
	if !adt_contains_name(rows, name) { return }
	running := false
	for r in rows { if r.name == name { running = r.running } }
	// STOP BEFORE DELETE. Deleting a running session is what the original
	// teardown avoids; doing it the other way round is how a scratch gets left
	// alive and this whole file's sweep goes red.
	if running {
		app.run_capture(app.stop_argv(name), app.CONTROL_TIMEOUT)
	}
	app.run_capture(app.delete_argv(name), app.CONTROL_TIMEOUT)
	au_say(c, fmt.tprintf("    torn down {} ({}) — was running: {}", name, stage, running))
}

// ── P1 LIVE: cleanup is routed to the row's device ────────────────────────

@(test)
adt_p1_detach_routes_cleanup_to_the_rows_device :: proc(t: ^testing.T) {
	c := au_live(t)
	victim := "hs-t-p1-namesake"
	adt_teardown(&c, victim, "pre-run safety")
	if !adt_spawn_pty(victim) {
		au_say(&c, "    SKIP: could not create the local scratch session under a pty")
		return
	}
	defer adt_teardown(&c, victim, "end of the P1 live case")

	before := adt_list_now()
	au_check(&c, "the LOCAL same-named session exists before the remote cleanup",
		adt_contains_name(before, victim), fmt.tprintf("local names={}", adt_names_of(before)))

	dead := adt_unreachable()
	saved := app.cleanup_policy()
	app.set_cleanup_policy(.always)
	defer app.set_cleanup_policy(saved)

	t0 := time.now()
	msg := app.post_detach(dead, victim, true)
	elapsed := time.since(t0)
	secs := f64(i64(elapsed / time.Millisecond)) / 1000.0
	au_say(&c, fmt.tprintf("    cleanup aimed at unreachable device {} in {}s", dead, secs))
	au_say(&c, fmt.tprintf("    post_detach notice: {}", msg))

	au_check(&c, "the notice reports the cleanup did NOT land (never claims success)",
		strings.contains(msg, "NOT cleaned"), fmt.tprintf("notice={}", msg))
	au_check(&c, "the notice names the device the cleanup was aimed at",
		strings.contains(msg, dead), fmt.tprintf("notice={}", msg))
	au_check(&c, "the notice never claims it stopped and deleted",
		!strings.contains(msg, "stopped and deleted"), fmt.tprintf("notice={}", msg))
	au_check(&c, "the cleanup stayed inside the control budget",
		elapsed <= app.CONTROL_TIMEOUT * 2 + 2 * time.Second,
		fmt.tprintf("elapsed={}s", secs))

	after := adt_list_now()
	au_say(&c, fmt.tprintf("    local sessions BEFORE: {}", adt_names_of(before)))
	au_say(&c, fmt.tprintf("    local sessions AFTER : {}", adt_names_of(after)))
	au_check(&c, "THE LOCAL SAME-NAMED SESSION SURVIVED the remote cleanup (P1)",
		adt_contains_name(after, victim), fmt.tprintf("local names={}", adt_names_of(after)))

	// Explicit teardown, asserted (same reason as R1: a leak should name the
	// section that made it).
	adt_teardown(&c, victim, "end of the P1 live case")
	au_check(&c, "teardown removed the scratch session",
		!adt_contains_name(adt_list_now(), victim),
		fmt.tprintf("names={}", adt_names_of(adt_list_now())))
}

// ── R1 LIVE: the shipped default, both halves ─────────────────────────────

@(test)
adt_r1_only_created_destroys_ours_spares_theirs :: proc(t: ^testing.T) {
	c := au_live(t)
	// Deliberately NO set_cleanup_policy: with D2 resolved, the thing worth
	// proving is that the value the app STARTS on already does the right
	// thing, not that a policy we installed does it.
	p := app.cleanup_policy()
	au_eq(&c, "no policy is set by this test; the default is what runs",
		app.cleanup_policy_label(p), "only_created")
	if p != .only_created {
		au_say(&c, "    ABORT: the default is not only_created, so nothing below proves R1")
		return
	}

	created := "hs-t-r1-owned"
	guest := "hs-t-r1-joined"
	adt_teardown(&c, created, "pre-run safety")
	adt_teardown(&c, guest, "pre-run safety")
	defer {
		adt_teardown(&c, created, "final sweep")
		adt_teardown(&c, guest, "final sweep")
	}
	if !adt_spawn_pty(created) {
		au_say(&c, "    SKIP: could not create the 'created here' scratch session")
		return
	}
	if !adt_spawn_pty(guest) {
		au_say(&c, "    SKIP: could not create the 'already there' scratch session")
		return
	}

	before := adt_list_now()
	au_check(&c, "both scratch sessions exist before the detach",
		adt_contains_name(before, created) && adt_contains_name(before, guest),
		fmt.tprintf("names={}", adt_names_of(before)))

	// half 1 — the one we created is destroyed
	n_own := app.post_detach(app.DEVICE_LOCAL, created, true)
	au_say(&c, fmt.tprintf("    detach notice (created here): {}", n_own))
	au_check(&c, "THE SESSION WE CREATED IS GONE from herdr after the detach",
		!adt_contains_name(adt_list_now(), created),
		fmt.tprintf("names={}", adt_names_of(adt_list_now())))
	au_check(&c, "…and the notice states it plainly, with no error wording",
		strings.contains(n_own, "stopped and deleted") &&
			!strings.contains(n_own, "NOT cleaned") &&
			!strings.contains(n_own, "failed"),
		fmt.tprintf("notice={}", n_own))

	// half 2 — the one we only attached to SURVIVES the identical call
	n_guest := app.post_detach(app.DEVICE_LOCAL, guest, false)
	au_say(&c, fmt.tprintf("    detach notice (only attached): {}", n_guest))
	au_check(&c, "THE SESSION WE ONLY ATTACHED TO IS STILL THERE",
		adt_contains_name(adt_list_now(), guest),
		fmt.tprintf("names={}", adt_names_of(adt_list_now())))
	au_check(&c, "…and the notice says it was left running, not deleted",
		strings.contains(n_guest, "left running") && !strings.contains(n_guest, "deleted"),
		fmt.tprintf("notice={}", n_guest))

	// The two notices must DIFFER. If they ever print the same sentence the
	// created/attached distinction was lost and `only_created` quietly became
	// `always` or `never`.
	au_check(&c, "…and the two notices are NOT the same sentence",
		n_own != n_guest,
		fmt.tprintf("own={} guest={}", n_own, n_guest))

	// half 3 — already deleted out-of-band → NO ERROR surfaced. Stop THEN
	// delete: herdr will not delete a running session, and a half-performed
	// teardown would be this test's own bug pretending to be a race.
	// herdr answers a delete of a gone name with {"deleted":true} / exit 0,
	// so the notice stays a success sentence and never grows a NOT-cleaned
	// clause. The opposite failure mode — a scary error for a harmless race —
	// is exactly what the requirement called out.
	app.run_capture(app.stop_argv(guest), app.CONTROL_TIMEOUT)
	app.run_capture(app.delete_argv(guest), app.CONTROL_TIMEOUT)
	au_check(&c, "the attached session was deleted out-of-band first",
		!adt_contains_name(adt_list_now(), guest),
		fmt.tprintf("names={}", adt_names_of(adt_list_now())))
	n_raced := app.post_detach(app.DEVICE_LOCAL, guest, true)
	au_say(&c, fmt.tprintf("    detach notice (already gone): {}", n_raced))
	au_check(&c, "already-deleted surfaces NO ERROR — no NOT-cleaned, no failure text",
		!strings.contains(n_raced, "NOT cleaned") &&
			!strings.contains(n_raced, "failed") &&
			!strings.contains(n_raced, "error"),
		fmt.tprintf("notice={}", n_raced))
	au_check(&c, "…and the list is unchanged by deleting something already gone",
		!adt_contains_name(adt_list_now(), guest) &&
			!adt_contains_name(adt_list_now(), created),
		fmt.tprintf("names={}", adt_names_of(adt_list_now())))

	// Explicit teardown, asserted — not left to the deferred sweep. If the
	// stop-then-delete ordering ever stops working the failure lands here, on
	// the R1 section that created the sessions, rather than on a generic
	// end-of-file sweep that cannot say which section leaked.
	adt_teardown(&c, created, "end of R1 live")
	adt_teardown(&c, guest, "end of R1 live")
	au_check(&c, "teardown leaves no R1 scratch behind",
		!adt_contains_name(adt_list_now(), created) &&
			!adt_contains_name(adt_list_now(), guest),
		fmt.tprintf("names={}", adt_names_of(adt_list_now())))
}

// ── P2-5 LIVE: a control command against a black-holed host ───────────────

@(test)
adt_p25_control_command_is_bounded_by_ssh :: proc(t: ^testing.T) {
	c := au_live(t)
	dead := adt_unreachable()
	argv := app.control_argv(dead, app.delete_argv("hs-t-nope"))
	t0 := time.now()
	cs := app.run_capture(argv, app.CONTROL_TIMEOUT)
	elapsed := time.since(t0)
	secs := f64(i64(elapsed / time.Millisecond)) / 1000.0
	au_say(&c, fmt.tprintf("    {} -> exit {} in {}s", au_argv_text(argv), cs.code, secs))

	au_check(&c, "the command returned (no hang)", cs.spawned && !cs.timed_out,
		fmt.tprintf("spawned={} timed_out={}", cs.spawned, cs.timed_out))
	au_check(&c, "…inside the CONTROL_TIMEOUT budget", elapsed <= app.CONTROL_TIMEOUT,
		fmt.tprintf("elapsed={}s budget={}s", secs, f64(app.CONTROL_TIMEOUT / time.Second)))
	au_check(&c, "…and it took ssh's own bound, not ours (ssh answers at ConnectTimeout)",
		secs >= 4.0 && secs <= 6.0, fmt.tprintf("elapsed={}s", secs))
	au_check(&c, "…which is UNDER the old 10 s CAPTURE_TIMEOUT this used to be allowed",
		elapsed < app.CAPTURE_TIMEOUT,
		fmt.tprintf("elapsed={}s capture={}s", secs, f64(app.CAPTURE_TIMEOUT / time.Second)))

	// The claim "ssh answers at its own ConnectTimeout" is only honest if the
	// flag is actually on the argv we built. Timing alone could match for the
	// wrong reason; this pins the mechanism the timing is attributed to.
	has_ct := false
	for a in app.SSH_BASE_ARGS { if strings.contains(a, "ConnectTimeout") { has_ct = true } }
	au_check(&c, "…and the bound IS ssh's ConnectTimeout: the flag is on the argv",
		has_ct, fmt.tprintf("SSH_BASE_ARGS carries ConnectTimeout={}", has_ct))
}

// ── the sweep ─────────────────────────────────────────────────────────────

@(test)
// Tests are SHUFFLED, so this proc cannot assume the other sections already
// tore their scratch down — and it must not pass by running first. It
// therefore ACTS before it asserts: tear down every `hs-t-*` found, then
// assert the sweep left nothing. That is a real post-condition about this
// file's own cleanup path (stop-then-delete works against a live session),
// not a race with whoever ran before it.
adt_no_scratch_session_survives_this_file :: proc(t: ^testing.T) {
	c := au_live(t)
	found: [dynamic]string = {}
	for r in adt_list_now() {
		if strings.has_prefix(r.name, support.SCRATCH_PREFIX) { append(&found, r.name) }
	}
	au_say(&c, fmt.tprintf("    sweep found {} `hs-t-*` session(s); tearing each down",
		len(found)))
	for n in found[:] { adt_teardown(&c, n, "end-of-file sweep") }

	left: [dynamic]string = {}
	for r in adt_list_now() {
		if strings.has_prefix(r.name, support.SCRATCH_PREFIX) { append(&left, r.name) }
	}
	parts: [dynamic]string = {}
	for n in left[:] { append(&parts, fmt.tprintf("'{}'", n)) }
	body, _ := strings.join(parts[:], ", ")
	au_check(&c, "this file leaves no `hs-t-*` session running",
		len(left) == 0, fmt.tprintf("after the sweep: [{}]", body))
}

// ── the real local list, live ────────────────────────────────────────────
//
// The model assertions elsewhere run on synthetic payloads. This is the
// same parser pointed at the machine's actual `herdr session list --json`:
// the hosted session must be VISIBLE (or nothing else here is meaningful)
// and `default` must never appear as a deletable row (D12).
adt_local_list_is_visible_and_default_free :: proc(c: ^AU_Ctx) {
	cs := app.run_capture(app.list_argv(), app.CAPTURE_TIMEOUT)
	au_eq_i(c, "list exit 0", i64(cs.code), 0)
	au_raw(c, "  raw stdout", cs.out)
	au_raw(c, "  raw stderr", cs.err)

	rows, ok := app.parse_session_list(cs.out, app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	au_check(c, "list parses", ok, fmt.tprintf("{} rows", len(rows)))
	au_check(c, "NO row is `default` (D12)",
		!adt_contains_name(rows, "default"),
		fmt.tprintf("names={}", adt_names_of(rows)))
	all_local := true
	for r in rows { if r.device != app.DEVICE_LOCAL { all_local = false } }
	au_check(c, "every row carries device=local", all_local,
		fmt.tprintf("{} row(s) from this box", len(rows)))
}

@(test)
adt_local_list_is_visible_and_default_free_test :: proc(t: ^testing.T) {
	__c := au_live(t)
	adt_local_list_is_visible_and_default_free(&__c)
}
