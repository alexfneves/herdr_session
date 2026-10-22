package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_fetch_status_test.odin — T10 port of the second half of `case_fetch_unit`
// (src/fetch_cases.odin:438-689): status mapping, failed-fetch isolation, the
// spawn/drain/reap lifecycle against a LOCAL `sh -c` stand-in, the P2-6 reap
// debt, and the deadline ordering.
//
// NO NETWORK, NO SSH. The stand-ins are local shells; the deadlines are tested
// against our own timer, not a black-holed host. What this CANNOT prove here —
// that ssh actually answers at ConnectTimeout, that the fan-out is actually
// concurrent, that a real remote's zombie is really ours — is fetch-live's,
// and is T14's fixture tier.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:testing"

import app "../../src/app"
import support "../support"

app_fetch_status_battery_afu_ssh_failure_status_reads_ssh_own_words :: proc(c: ^AU_Ctx) {
	// 255 covers BOTH "could not connect" and "would not let us in". The
	// split is ours to make, and it is made by reading ssh's own words. Both
	// strings below are verbatim from this box.
	au_eq(c, "255 + 'Connection timed out' -> unreachable",
		app.device_status_label(app.ssh_failure_status(
			"ssh: connect to host 10.255.255.1 port 22: Connection timed out")),
		"unreachable")
	au_eq(c, "255 + 'Permission denied' -> auth",
		app.device_status_label(app.ssh_failure_status(
			"nosuchuser@203.0.113.9: Permission denied (publickey,password,keyboard-interactive).")),
		"auth")
	au_eq(c, "255 + 'Too many authentication failures' -> auth",
		app.device_status_label(app.ssh_failure_status(
			"Too many authentication failures for user")),
		"auth")
	au_eq(c, "255 + 'Connection refused' -> unreachable (NOT auth)",
		app.device_status_label(app.ssh_failure_status(
			"ssh: connect to host box port 22: Connection refused")),
		"unreachable")
	au_eq(c, "255 + 'Host key verification failed' -> unreachable (NOT auth)",
		app.device_status_label(app.ssh_failure_status("Host key verification failed.")),
		"unreachable")
}

afu_distinct_labels :: proc(cs: []app.Device_Status) -> int {
	seen := make(map[string]bool)
	n := 0
	for cc in cs {
		l := app.device_status_label(cc)
		if seen[l] { continue }
		seen[l] = true
		n += 1
	}
	delete(seen)
	return n
}
@(test)
afu_ssh_failure_status_reads_ssh_own_words :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_status_battery_afu_ssh_failure_status_reads_ssh_own_words(&__c)
}

app_fetch_status_battery_afu_device_status_labels_are_all_distinct :: proc(c: ^AU_Ctx) {
	// `no_herdr` must be reachable at all, and distinct from `unreachable`.
	codes := []app.Device_Status{.ok, .timed_out, .unreachable, .no_herdr, .auth_failed, .failed}
	au_eq_int(c, "all six device statuses are distinct labels",
		afu_distinct_labels(codes), 6)
	au_eq(c, "no_herdr reads 'no herdr'", app.device_status_label(.no_herdr), "no herdr")
	au_check(c, "no_herdr != unreachable",
		app.device_status_label(.no_herdr) != app.device_status_label(.unreachable),
		fmt.tprintf("{} vs {}", app.device_status_label(.no_herdr),
			app.device_status_label(.unreachable)))
}
@(test)
afu_device_status_labels_are_all_distinct :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_status_battery_afu_device_status_labels_are_all_distinct(&__c)
}

app_fetch_status_battery_afu_outcome_kind_maps_to_status :: proc(c: ^AU_Ctx) {
	au_eq(c, "outcome .timed_out -> timeout",
		app.device_status_label(app.device_status_of(.timed_out, "")), "timeout")
	au_eq(c, "outcome .no_herdr -> no herdr",
		app.device_status_label(app.device_status_of(.no_herdr,
			"zsh:1: command not found: herdr")), "no herdr")
	au_eq(c, "outcome .ok -> ok",
		app.device_status_label(app.device_status_of(.ok, "")), "ok")
	au_eq(c, "outcome .herdr_error -> failed",
		app.device_status_label(app.device_status_of(.herdr_error, "")), "failed")
	au_eq(c, "outcome .tty_panic -> failed",
		app.device_status_label(app.device_status_of(.tty_panic, "")), "failed")
}
@(test)
afu_outcome_kind_maps_to_status :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_status_battery_afu_outcome_kind_maps_to_status(&__c)
}

app_fetch_status_battery_afu_failed_fetch_degrades_only_its_own_host :: proc(c: ^AU_Ctx) {
	tb := afu_table_with({AFU_HOST_A, AFU_HOST_B})
	// Host B is healthy: applied through `apply`, which is the path that sets
	// a device status AND merges rows. Merging rows by hand would leave the
	// status pending and make this prove nothing about health surviving a
	// peer's failure.
	fb := new(app.Fetch)
	fb.device = AFU_HOST_B
	fb.label = AFU_HOST_B
	fb.status = .ok
	fb.settled = true
	fb.rows = {afu_session(AFU_HOST_B, "keep-2026-10-18-12-00-00-000", true)}
	app.apply(tb, fb)
	before := afu_fingerprint(tb.rows[:])

	// Host A settles unreachable, holding zero rows.
	fa := new(app.Fetch)
	fa.device = AFU_HOST_A
	fa.label = AFU_HOST_A
	fa.status = .unreachable
	fa.detail = "ssh: connect to host 10.255.255.1 port 22: Connection timed out"
	fa.settled = true
	fa.exit_code = 255

	rep := app.apply(tb, fa)
	au_eq_int(c, "a failed fetch merges ZERO rows", rep.added, 0)
	au_eq(c, "the other host's rows are untouched", afu_fingerprint(tb.rows[:]), before)

	d := app.table_device(tb, AFU_HOST_A)
	au_check(c, "the FAILED host carries the failure",
		d != nil && d.status == .unreachable,
		fmt.tprintf("status={}", app.device_status_label(d.status)))
	db := app.table_device(tb, AFU_HOST_B)
	au_check(c, "the HEALTHY host is still 'ok' after the other one failed",
		db != nil && db.status == .ok,
		fmt.tprintf("status={}", app.device_status_label(db.status)))

	// The failed host's row group is not *cleared* either: blanketing a host
	// on a network blip is its own lie. It keeps whatever we last actually
	// got (nothing here) under a status that says we could not refresh.
	au_eq_int(c, "table still holds exactly the healthy host's row", len(tb.rows), 1)
	app.table_destroy(tb)
}
@(test)
afu_failed_fetch_degrades_only_its_own_host :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_status_battery_afu_failed_fetch_degrades_only_its_own_host(&__c)
}

app_fetch_status_battery_afu_registry_lifecycle_local_standins :: proc(c: ^AU_Ctx) {
	reg: app.Registry = {}
	defer app.registry_free(&reg)

	// ok: a real session-list JSON on stdout, nothing on stderr.
	app.registry_add(&reg, app.spawn_fetch("unit-ok", "unit-ok", .local, {
		"sh", "-c",
		`printf '{"sessions":[{"default":true,"name":"default","running":false},{"default":false,"name":"s-2026-10-18-10-00-00-000","running":true}]}'`,
	}, 5 * time.Second))

	// error: NOTHING on stdout and a 127-shaped "command not found" on stderr
	// — the exact shape a remote without herdr produces.
	app.registry_add(&reg, app.spawn_fetch("unit-noherdr", "unit-noherdr", .local, {
		"sh", "-c", `echo "sh: 1: herdr-not-here: not found" >&2; exit 127`,
	}, 5 * time.Second))

	// slow: silent for 30 s. Only our deadline can end this one.
	app.registry_add(&reg, app.spawn_fetch("unit-hang", "unit-hang", .local, {
		"sh", "-c", `sleep 30`,
	}, 400 * time.Millisecond))

	au_eq_int(c, "three fetches registered live", app.registry_pending(&reg), 3)

	ok := app.registry_wait_all(&reg, 8 * time.Second)
	au_check(c, "the fan-out settled within the overall budget", ok,
		fmt.tprintf("pending={}", app.registry_pending(&reg)))
	au_eq_int(c, "all three settled", app.registry_pending(&reg), 0)

	st, detail, rows := app.registry_status_for(&reg, "unit-ok")
	au_eq(c, "ok host -> ok", app.device_status_label(st), "ok")
	au_eq_int(c, "ok host parsed 1 session (default filtered)", len(rows), 1)
	if len(rows) > 0 {
		au_eq(c, "the session is the non-default one", rows[0].name,
			"s-2026-10-18-10-00-00-000")
		au_eq(c, "and it is tagged with THIS device", rows[0].device, "unit-ok")
	}
	au_say(c, fmt.tprintf("    unit-ok: %s / %d row(s)", detail, len(rows)))

	st2, detail2, rows2 := app.registry_status_for(&reg, "unit-noherdr")
	au_eq(c, "127 host -> no herdr", app.device_status_label(st2), "no herdr")
	au_eq_int(c, "127 host merged zero rows", len(rows2), 0)
	au_say(c, fmt.tprintf("    unit-noherdr: %s", detail2))

	st3, detail3, _ := app.registry_status_for(&reg, "unit-hang")
	au_eq(c, "hanging host -> timeout (our deadline, not ssh's)",
		app.device_status_label(st3), "timeout")
	au_check(c, "…and we killed it", afu_hang_killed(&reg), "killed flag set")
	au_say(c, fmt.tprintf("    unit-hang: %s (kills={})", detail3, reg.kills))
	au_eq_int(c, "exactly one child needed killing", reg.kills, 1)
}

afu_hang_killed :: proc(r: ^app.Registry) -> bool {
	for f in r.items {
		if f.device == "unit-hang" { return f.killed }
	}
	return false
}
@(test)
afu_registry_lifecycle_local_standins :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_status_battery_afu_registry_lifecycle_local_standins(&__c)
}

app_fetch_status_battery_afu_reap_debt_is_repaid_by_the_real_reaper :: proc(c: ^AU_Ctx) {
	f := app.spawn_fetch("debt-probe", "debt-probe", .local,
		{"sh", "-c", `printf '{"sessions":[{"default":true,"name":"default","running":false}]}'`},
		5 * time.Second)
	au_check(c, "the debt child spawned", f != nil && f.spawned, "")
	if f == nil || !f.spawned { return }
	pid := int(f.pid)

	// Drain to EOF: the child has certainly finished writing. Then settle the
	// verdict WITHOUT collecting the child, which is precisely the state the
	// kill path leaves behind when its budget expires.
	for _ in 0 ..< 400 {
		app.fetch_drain(f)
		if app.fetch_drained(f) { break }
		time.sleep(5 * time.Millisecond)
	}
	app.settle_exit(f, 0)
	f.reaped = false

	au_check(c, "…the fetch is SETTLED", f.settled, "")
	au_check(c, "…and NOT reaped — the debt is open", !f.reaped, "")
	au_check(c, "…and the kernel still holds the child as OUR zombie (exited, uncollected)",
		afu_wait_zombie(pid), fmt.tprintf("pid={} state={}", pid, afu_proc_state(pid)))

	reg: app.Registry = {}
	defer app.registry_free(&reg)
	app.registry_add(&reg, f)

	au_eq_int(c, "registry_unreaped sees the debt", app.registry_unreaped(&reg), 1)

	// The repayment. Under the old guard this call changed nothing at all.
	app.registry_reap_debts(&reg)

	au_check(c, "registry_reap_debts REPAID it: fetch.reaped is now true", f.reaped,
		fmt.tprintf("settled={} reaped={}", f.settled, f.reaped))
	au_eq_int(c, "registry_unreaped is now clean", app.registry_unreaped(&reg), 0)
	au_check(c, "…and the kernel agrees: our zombie is gone, we collected our own child",
		afu_proc_state(pid) == 0, fmt.tprintf("pid={} state={}", pid, afu_proc_state(pid)))
	au_check(c, "…the settled verdict survived the repayment (no re-settle, no lost verdict)",
		f.settled && f.status == .ok,
		fmt.tprintf("settled={} status={}", f.settled, app.device_status_label(f.status)))

	// A second sweep must be a no-op rather than a second waitpid on a pid we
	// no longer own. Idempotence is what makes it safe to call every frame.
	app.registry_reap_debts(&reg)
	au_eq_int(c, "a second sweep changes nothing", app.registry_unreaped(&reg), 0)
	au_check(c, "…and reaped stays true", f.reaped, "")
}

// afu_proc_state reads the state field of /proc/<pid>/stat: 'R' running, 'S'
// sleeping, 'Z' zombie, 0 when there is no such process.
//
// /proc and NOT waitpid on purpose: waitpid would COLLECT the child and
// destroy the very debt under test. The comm field may contain spaces and
// parens, so the state is taken after the LAST ')' on the line — the only
// unambiguous split.
afu_proc_state :: proc(pid: int) -> u8 {
	path := fmt.tprintf("/proc/{}/stat", pid)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil || len(data) == 0 { return 0 }
	last_close := -1
	for i in 0 ..< len(data) {
		if data[i] == byte(')') { last_close = i }
	}
	// +1 skips the ')' itself, +2 skips the single space before the state byte.
	if last_close < 0 || last_close + 2 >= len(data) { return 0 }
	return data[last_close+2]
}

// afu_wait_zombie parks until the kernel holds the child as a zombie (exited
// and uncollected), or gives up after ~1 s.
afu_wait_zombie :: proc(pid: int) -> bool {
	for _ in 0 ..< 200 {
		if afu_proc_state(pid) == byte('Z') { return true }
		time.sleep(5 * time.Millisecond)
	}
	return false
}
@(test)
afu_reap_debt_is_repaid_by_the_real_reaper :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_status_battery_afu_reap_debt_is_repaid_by_the_real_reaper(&__c)
}

app_fetch_status_battery_afu_deadline_ordering_ssh_bound_is_the_first_line :: proc(c: ^AU_Ctx) {
	// ssh's own ConnectTimeout=5 is what usually ends a black-holed fetch
	// (measured 5.01 s -> exit 255). Our backstop must be larger, or we
	// would SIGKILL the child *before* ssh ever got to report the honest
	// reason.
	au_check(c, "FETCH_DEADLINE (13 s) > ssh ConnectTimeout (5 s)",
		app.FETCH_DEADLINE > 5 * time.Second,
		fmt.tprintf("deadline={} s", time.duration_seconds(app.FETCH_DEADLINE)))
	au_check(c, "the gap is large enough for ssh to report but small enough to matter",
		app.FETCH_DEADLINE <= 20 * time.Second,
		fmt.tprintf("deadline={} s", time.duration_seconds(app.FETCH_DEADLINE)))
	au_check(c, "the LOCAL deadline is tight (a local list is ~3 ms)",
		app.LOCAL_FETCH_DEADLINE <= 5 * time.Second,
		fmt.tprintf("local={} s", time.duration_seconds(app.LOCAL_FETCH_DEADLINE)))
	au_check(c, "POLL_SLICE keeps a single sleep short enough to stay honest",
		app.POLL_SLICE <= 100 * time.Millisecond,
		fmt.tprintf("slice={}", time.duration_milliseconds(app.POLL_SLICE)))
}
@(test)
afu_deadline_ordering_ssh_bound_is_the_first_line :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_status_battery_afu_deadline_ordering_ssh_bound_is_the_first_line(&__c)
}

app_fetch_status_battery_afu_fetch_argv_is_the_mandatory_ssh_form :: proc(c: ^AU_Ctx) {
	// The mandatory ssh args must survive the refactor into the fetch path:
	// `spawn_remote_fetch` goes through `remote_list_argv`, so assert the
	// argv it will actually run. The `--` before the host is part of the
	// mandatory form now (P2-7).
	argv := app.remote_list_argv("some.host.example")
	joined := afu_argv_join(argv)
	au_eq(c, "the fetch argv is exactly the mandatory ssh form", joined,
		"ssh -T -o BatchMode=yes -o ConnectTimeout=5 -- some.host.example herdr session list --json")
	au_check(c, "…contains -T (NOT -t: no pty, no chatter)",
		strings.contains(joined, " -T ") && !strings.contains(joined, " -t "), joined)
	au_check(c, "…BatchMode=yes (auth fast-fails instead of prompting)",
		strings.contains(joined, "BatchMode=yes"), joined)
	au_check(c, "…ConnectTimeout=5 (a black hole costs 5 s, not 133 s)",
		strings.contains(joined, "ConnectTimeout=5"), joined)
	au_check(c, "…never -tt (that is the interactive attach seam, not a fetch)",
		!strings.contains(joined, "-tt"), joined)
}
@(test)
afu_fetch_argv_is_the_mandatory_ssh_form :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_status_battery_afu_fetch_argv_is_the_mandatory_ssh_form(&__c)
}

