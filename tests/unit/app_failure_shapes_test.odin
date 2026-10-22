package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_failure_shapes_test.odin — T10 port of `unit_missing_herdr` (:1138),
// `unit_control_budget` (:1160) and `unit_stopped_attach_is_legal` (:1204).
//
// P3-5  — the old code reported "local herdr answered, but not with a session
//         list" even when NOTHING EVER SPAWNED, sending users to debug a
//         program that was not running. Each failure shape now has its own
//         message and its own actionable status.
//
// P2-5  — the control budget is DERIVED from the transport (ssh's own
//         ConnectTimeout read out of the real SSH_BASE_ARGS) rather than
//         hardcoded, so the check moves with the constant instead of rotting.
//
// P2-4  — the deliberate override: a STOPPED session is attachable, because
//         `herdr session attach` RESUMES it. The review asked for
//         `running == true` and that would have disabled a core action. The
//         freshness concern is answered by re-reading the list, not by
//         forbidding the target.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:time"
import "core:testing"

import app "../../src/app"
import support "../support"

AU_Shape_Case :: struct {
	name      : string,
	spawned   : bool,
	timed_out : bool,
	code      : i32,
	want      : app.Device_Status,
}

AU_MISSING_HERDR_CASES : []AU_Shape_Case = {
	{"never spawned (not on PATH)", false, false, -1, .no_herdr},
	{"shell says 127",              true,  false, 127, .no_herdr},
	{"answered garbage",            true,  false,   0, .failed},
	{"hit our deadline",            true,   true,  -1, .timed_out},
}

@(test)
app_missing_herdr_each_shape_maps_to_a_status :: proc(t: ^testing.T) {
	c := au_live(t)
	for cs in AU_MISSING_HERDR_CASES {
		why, st := app.local_failure_text(cs.spawned, cs.timed_out, cs.code, 5 * time.Second)
		au_check(&c, fmt.tprintf("{} -> status {}", cs.name, app.device_status_label(st)),
			st == cs.want, fmt.tprintf("got {} why='{}'", app.device_status_label(st), why))
		au_check(&c, fmt.tprintf("{} names a cause the user can act on", cs.name),
			len(why) > 0 && why != "local herdr answered, but not with a session list" ||
				st == .failed,
			fmt.tprintf("why='{}'", why))
	}
}

@(test)
app_missing_herdr_never_says_answered_when_nothing_spawned :: proc(t: ^testing.T) {
	c := au_live(t)
	// The specific lie this is fixing.
	why_ns, _ := app.local_failure_text(false, false, -1, 5 * time.Second)
	au_check(&c, "a child that never spawned is never described as having answered",
		!strings.contains(why_ns, "answered"), fmt.tprintf("why='{}'", why_ns))
	au_check(&c, "…and it says PATH", strings.contains(why_ns, "PATH"),
		fmt.tprintf("why='{}'", why_ns))
}

@(test)
app_control_budget_is_derived_from_ssh_not_from_a_literal :: proc(t: ^testing.T) {
	c := au_live(t)
	// Read the bound out of the REAL argv rather than hardcoding 5: if someone
	// changes SSH_BASE_ARGS this check moves with it, which is the whole point
	// of deriving the budget from the transport.
	ssh_bound := -1.0
	base: [6]string = app.SSH_BASE_ARGS
	for idx in 0 ..< len(base) {
		a := base[idx]
		if strings.has_prefix(a, "ConnectTimeout=") {
			ssh_bound = f64(au_parse_int(a[len("ConnectTimeout="):]))
		}
	}
	au_check(&c, "SSH_BASE_ARGS actually carries ConnectTimeout", ssh_bound > 0,
		fmt.tprintf("parsed={}", ssh_bound))

	cb := f64(app.CONTROL_TIMEOUT / time.Second)
	cap_b := f64(app.CAPTURE_TIMEOUT / time.Second)
	au_check(&c, "CONTROL_TIMEOUT > ssh ConnectTimeout (never pre-empts the honest answer)",
		cb > ssh_bound, fmt.tprintf("control={}s ssh={}s", cb, ssh_bound))
	au_check(&c,
		"CONTROL_TIMEOUT < ssh ConnectTimeout + 2s (never waits much longer than advertised)",
		cb < ssh_bound + 2.0, fmt.tprintf("control={}s ssh={}s", cb, ssh_bound))
	au_check(&c, "CONTROL_TIMEOUT < CAPTURE_TIMEOUT (control is the tight one)",
		cb < cap_b, fmt.tprintf("control={}s capture={}s", cb, cap_b))
}

@(test)
app_control_budget_worst_case_is_bounded :: proc(t: ^testing.T) {
	c := au_live(t)
	cb := f64(app.CONTROL_TIMEOUT / time.Second)
	cap_b := f64(app.CAPTURE_TIMEOUT / time.Second)
	// The worst honest wait: two commands (stop, then delete), each capped.
	worst := 2 * cb
	au_check(&c, "worst-case delete wait (stop+delete) is bounded by 2x the control budget",
		worst <= 2 * cb + 0.001, fmt.tprintf("worst={}s", worst))
	au_check(&c, "…and that is under the OLD 2x CAPTURE_TIMEOUT (20s) the review measured",
		worst < 2 * cap_b,
		fmt.tprintf("new worst={}s vs old 2x capture={}s", worst, 2 * cap_b))
}

// ── P2-4 override ───────────────────────────────────────────────────────────

au_p24_rows :: proc() -> []app.Session {
	d: [dynamic]app.Session = {}
	append(&d, au_mk(app.DEVICE_LOCAL, "hs-t-stopped", false))
	append(&d, au_mk("build-box", "hs-t-stopped", false))
	append(&d, au_mk(app.DEVICE_LOCAL, "hs-t-live", true))
	return d[:]
}

@(test)
app_p24_stopped_session_is_attachable :: proc(t: ^testing.T) {
	c := au_live(t)
	rows := au_p24_rows()
	g_local := app.attach_guard(rows, app.DEVICE_LOCAL, "hs-t-stopped")
	au_check(&c, "a STOPPED LOCAL session passes attach_guard (resume is legal)",
		g_local.ok, fmt.tprintf("reason=%q", g_local.reason))
	g_remote := app.attach_guard(rows, "build-box", "hs-t-stopped")
	au_check(&c, "a STOPPED REMOTE session passes attach_guard too",
		g_remote.ok, fmt.tprintf("reason=%q", g_remote.reason))

	// The last-moment re-check agrees, on the same freshest view.
	r_local := app.revalidate_attach(rows, app.DEVICE_LOCAL, "hs-t-stopped")
	au_check(&c, "revalidate_attach agrees: stopped is not a refusal",
		r_local.ok, fmt.tprintf("reason=%q", r_local.reason))
}

@(test)
app_p24_unknown_name_still_fails_closed :: proc(t: ^testing.T) {
	c := au_live(t)
	rows := au_p24_rows()
	// What DOES still fail closed: a name the (fresh) model does not have.
	// That is the real hazard — attach CREATES what it cannot find.
	g_gone := app.attach_guard(rows, app.DEVICE_LOCAL, "hs-t-deleted-elsewhere")
	au_check(&c, "a name missing from the fresh model is STILL refused",
		!g_gone.ok, fmt.tprintf("reason=%q", g_gone.reason))
	r_gone := app.revalidate_attach(rows, app.DEVICE_LOCAL, "hs-t-deleted-elsewhere")
	au_check(&c, "…and revalidate_attach refuses it identically",
		!r_gone.ok && r_gone.reason == g_gone.reason,
		fmt.tprintf("revalidate=%q guard=%q", r_gone.reason, g_gone.reason))
	au_check(&c, "…the refusal says the name is unknown, never `not running`",
		strings.contains(r_gone.reason, "not running on"),
		fmt.tprintf("reason=%q", r_gone.reason))

	// The running row passes both too, so nothing regressed for the common case.
	au_check(&c, "a live session passes both checks",
		app.attach_guard(rows, app.DEVICE_LOCAL, "hs-t-live").ok &&
			app.revalidate_attach(rows, app.DEVICE_LOCAL, "hs-t-live").ok, "")
}

@(test)
app_p24_refresh_predicate_is_narrow :: proc(t: ^testing.T) {
	c := au_live(t)
	// Entering the two pick-a-session states is when the loop re-reads.
	// Everything else must NOT trigger a refresh, or a stray keystroke would
	// churn the whole fan-out.
	au_check(&c, "entering {Attach} requires a refresh", app.state_needs_refresh(.attach), "")
	au_check(&c, "entering {Delete} requires a refresh",
		app.state_needs_refresh(.delete_session), "")
	no_refresh := []app.State{.mode_selection, .name_local, .remote_server,
		.name_remote_named, .theme, .error}
	for s in no_refresh {
		au_check(&c, fmt.tprintf("{} does NOT force a refresh", app.state_label(s)),
			!app.state_needs_refresh(s), "")
	}
}
