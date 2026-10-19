package main

// PHASE 4 UNIT DRIVER — the fan-out's decision logic and T4.2's identity rules,
// proven without a single subprocess.
//
// Why split this from the live case: every rule below is deterministic and must
// stay deterministic. The live case depends on ssh, a fixture host, and the wall
// clock; if the identity rules were only proven there, a slow or unreachable
// fixture would take the *proof* of the data model down with it.
//
//   fetch-unit  merge identity, isolation, ordering, selection-by-identity,
//               exit-code -> per-host status mapping, fetch lifecycle against a
//               local stand-in command (no ssh, no network).
//
// The "two devices, same session name" case here is the offline half of the
// discriminator the plan says a single-host suite can never satisfy; the live
// half (two real ssh target strings reaching byte-identical sessions) is in
// `fetch-live`.

import app "./app"

import "core:fmt"
import "core:strings"
import "core:time"

// The two stand-in devices for the offline identity work. Deliberately NOT
// host-shaped names that could be mistaken for a fixture: these never touch a
// network, they are just two distinct identity namespaces.
U_HOST_A :: "unit-host-a"
U_HOST_B :: "unit-host-b"

// shared_name is the name that exists under BOTH devices. Names collide across
// hosts by design, so this is the pair of rows a name-keyed model would collapse.
shared_name :: "api-2026-10-18-20-30-45-123"

case_fetch_unit :: proc() -> bool {
	say("case fetch-unit — merge identity, isolation, selection, status mapping")

	unit_merge_identity()
	unit_merge_isolation()
	unit_merge_reinsert()
	unit_ordering()
	unit_selection_identity()
	unit_status_mapping()
	unit_failed_fetch_merges_nothing()
	unit_registry_lifecycle()
	unit_deadline_policy()

	return !any_failed
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

u_session :: proc(device, name: string, running: bool) -> app.Session {
	return app.Session{
		device  = device,
		label   = device,
		name    = name,
		running = running,
		ts      = app.ts_from_name(name),
	}
}

// rows_fingerprint is everything that identifies a row *and* its state, in the
// order the table holds it. Two fingerprints equal means no row was added,
// dropped, renamed, retagged, reordered or had its running flag touched.
rows_fingerprint :: proc(rows: []app.Session) -> string {
	parts := make([dynamic]string, 0, len(rows))
	for r in rows {
		append(&parts, fmt.tprintf("{}|{}|{}", r.device, r.name, r.running))
	}
	joined, _ := strings.join(parts[:], " ;; ")
	delete(parts)
	return joined
}

u_table_with :: proc(devices: []string) -> ^app.Table {
	t := new(app.Table)
	devs := make([dynamic]app.Device, 0, len(devices))
	for d in devices {
		append(&devs, app.Device{target = d, label = d, status = .pending})
	}
	app.table_reset_devices(t, devs[:])
	delete(devs)
	return t
}

// ---------------------------------------------------------------------------
// T4.2 — the key is the pair, not the name
// ---------------------------------------------------------------------------

unit_merge_identity :: proc() {
	say("  — identity is (device, name)")

	t := u_table_with({U_HOST_A, U_HOST_B})

	// The same session name under two devices. herdr scopes names per
	// (host, unix-user), and its `session list --json` carries no host field at
	// all, so two hosts owning `api-…` is normal, not an error.
	a := []app.Session{u_session(U_HOST_A, shared_name, true)}
	b := []app.Session{u_session(U_HOST_B, shared_name, true)}

	ra := app.merge(t, U_HOST_A, a)
	rb := app.merge(t, U_HOST_B, b)

	eq_int("same name under two devices -> two rows", len(t.rows), 2)
	check("neither row was collapsed onto the name",
		app.index_of_identity(t.rows[:], U_HOST_A, shared_name) >= 0 &&
		app.index_of_identity(t.rows[:], U_HOST_B, shared_name) >= 0,
		fmt.tprintf("A@{} B@{}",
			app.index_of_identity(t.rows[:], U_HOST_A, shared_name),
			app.index_of_identity(t.rows[:], U_HOST_B, shared_name)))
	eq_int("host A reported 1 added", ra.added, 1)
	eq_int("host B reported 1 added", rb.added, 1)
	say(fmt.tprintf("    %s", rows_fingerprint(t.rows[:])))

	// Both groups are still individually addressable after the second merge —
	// which is what attach/delete actually need.
	sa, ok_a := app.selection_session(t.rows[:],
		app.Selection{device = U_HOST_A, name = shared_name, valid = true})
	sb, ok_b := app.selection_session(t.rows[:],
		app.Selection{device = U_HOST_B, name = shared_name, valid = true})
	check("each identity resolves to its OWN row",
		ok_a && ok_b && sa.device == U_HOST_A && sb.device == U_HOST_B,
		fmt.tprintf("a.device={} b.device={}", sa.device, sb.device))
	check("the two rows are NOT the same row", sa != sb,
		fmt.tprintf("a_ptr={} b_ptr={}", sa, sb))

	app.table_destroy(t)
}

// ---------------------------------------------------------------------------
// T4.2 / ISC-15 — refreshing A does not disturb B
// ---------------------------------------------------------------------------

unit_merge_isolation :: proc() {
	say("  — updating host A never disturbs host B's rows")

	t := u_table_with({U_HOST_A, U_HOST_B})

	// Seed both groups.
	app.merge(t, U_HOST_A, {
		u_session(U_HOST_A, "a-one-2026-10-18-01-00-00-000", true),
		u_session(U_HOST_A, "a-two-2026-10-18-02-00-00-000", false),
	})
	app.merge(t, U_HOST_B, {
		u_session(U_HOST_B, "b-one-2026-10-18-03-00-00-000", true),
		u_session(U_HOST_B, "b-two-2026-10-18-04-00-00-000", true),
	})

	// Snapshot only B's rows, but as a fingerprint of the WHOLE table with
	// A's rows removed — that is what "B untouched" means when a sort may
	// legitimately have moved things.
	snapshot_b :: proc(tbl: ^app.Table) -> string {
		parts := make([dynamic]string, 0, 8)
		for r in tbl.rows {
			if r.device != U_HOST_B { continue }
			append(&parts, fmt.tprintf("{}|{}|{}", r.device, r.name, r.running))
		}
		j, _ := strings.join(parts[:], " ;; ")
		delete(parts)
		return j
	}

	b_before := snapshot_b(t)

	// A refresh of A: one row goes away, one changes state, one is new.
	rep := app.merge(t, U_HOST_A, {
		u_session(U_HOST_A, "a-one-2026-10-18-01-00-00-000", false),  // state flip
		u_session(U_HOST_A, "a-new-2026-10-18-09-00-00-000", true),   // added
																	// a-two dropped
	})
	eq_int("refresh added 1", rep.added, 1)
	eq_int("refresh updated 1", rep.updated, 1)
	eq_int("refresh removed 1", rep.removed, 1)
	eq_int("carried through 2 foreign rows", rep.carried, 2)

	b_after := snapshot_b(t)
	eq("host B's rows are byte-identical after A's refresh", b_after, b_before)
	say(fmt.tprintf("    B unchanged: %s", b_after))
	say(fmt.tprintf("    table now:   %s", rows_fingerprint(t.rows[:])))

	// And the carried count is exactly what B contributed.
	// Note `carried` is "rows of other devices preserved", not "rows returned".
	check("carried counts only OTHER devices' rows", rep.carried == 2 && rep.total == 4,
		fmt.tprintf("carried={} total={}", rep.carried, rep.total))

	app.table_destroy(t)
}

// ---------------------------------------------------------------------------
// Deleting and re-adding is identity-correct
// ---------------------------------------------------------------------------

unit_merge_reinsert :: proc() {
	say("  — delete / re-add keeps the identity correct")

	t := u_table_with({U_HOST_A})
	name := "db-2026-10-18-11-00-00-000"

	app.merge(t, U_HOST_A, {u_session(U_HOST_A, name, true)})
	check("present after add",
		app.is_known_session(t.rows[:], U_HOST_A, name), "1 row")

	// Empty list = the session is gone on the host.
	rep := app.merge(t, U_HOST_A, {})
	eq_int("empty refresh removes the row", rep.removed, 1)
	check("gone after delete", !app.is_known_session(t.rows[:], U_HOST_A, name), "0 rows")

	// Re-add: same identity, and no duplicate left behind from the first pass.
	app.merge(t, U_HOST_A, {u_session(U_HOST_A, name, false)})
	eq_int("re-add yields exactly one row", len(t.rows), 1)
	check("re-added row is found by the SAME identity",
		app.is_known_session(t.rows[:], U_HOST_A, name), "identity stable across delete/re-add")

	// The *state* came back fresh (was running=true, now false), so the table is
	// not serving a stale row from the first add.
	idx := app.index_of_identity(t.rows[:], U_HOST_A, name)
	check("re-added row carries the NEW state, not the old one",
		idx >= 0 && !t.rows[idx].running,
		fmt.tprintf("running={}", t.rows[idx].running))

	app.table_destroy(t)
}

// ---------------------------------------------------------------------------
// Ordering survives a merge
// ---------------------------------------------------------------------------

unit_ordering :: proc() {
	say("  — ordering: local first, then device, then timestamp")

	t := u_table_with({app.DEVICE_LOCAL, U_HOST_A, "aaa-host"})

	// Deliberately merged out of order: remote first, local last.
	app.merge(t, U_HOST_A, {
		u_session(U_HOST_A, "late-2026-10-18-23-00-00-000", true),
		u_session(U_HOST_A, "early-2026-10-18-01-00-00-000", true),
		u_session(U_HOST_A, "no-ts", true),
	})
	app.merge(t, "aaa-host", {u_session("aaa-host", "x-2026-10-18-12-00-00-000", true)})
	app.merge(t, app.DEVICE_LOCAL, {
		u_session(app.DEVICE_LOCAL, "z-2026-10-18-22-00-00-000", true),
		u_session(app.DEVICE_LOCAL, "a-2026-10-18-05-00-00-000", true),
	})

	order := device_order(t.rows[:])
	say(fmt.tprintf("    device order: {}", order))
	eq("local group first, then alphabetical host, then unit-host-a", order,
	   fmt.tprintf("{},aaa-host,{}", app.DEVICE_LOCAL, U_HOST_A))

	check("local rows contiguous (never interleaved)", groups_contiguous(t.rows[:]),
		fmt.tprintf("order={}", order))

	// Inside one device: ts ascending, unknown LAST (the I64_MAX sentinel).
	inside := names_of_device(t.rows[:], U_HOST_A)
	say(fmt.tprintf("    inside {}: {}", U_HOST_A, inside))
	eq("timestamps ascending, 'no ts' last", inside,
	   "early-2026-10-18-01-00-00-000,late-2026-10-18-23-00-00-000,no-ts")
}

device_order :: proc(rows: []app.Session) -> string {
	parts := make([dynamic]string, 0, len(rows))
	last := ""
	for r in rows {
		if r.device == last { continue }
		last = r.device
		append(&parts, r.device)
	}
	j, _ := strings.join(parts[:], ",")
	delete(parts)
	return j
}

names_of_device :: proc(rows: []app.Session, device: string) -> string {
	parts := make([dynamic]string, 0, 8)
	for r in rows {
		if r.device != device { continue }
		append(&parts, r.name)
	}
	j, _ := strings.join(parts[:], ",")
	delete(parts)
	return j
}

groups_contiguous :: proc(rows: []app.Session) -> bool {
	seen := make(map[string]bool)
	last := ""
	for r in rows {
		if r.device != last {
			if seen[r.device] { return false } // a group we already closed re-opened
			seen[r.device] = true
			last = r.device
		}
	}
	delete(seen)
	return true
}

// ---------------------------------------------------------------------------
// T4.2 rule 1 — selection is identity, never index
// ---------------------------------------------------------------------------

unit_selection_identity :: proc() {
	say("  — selection is tracked by identity, not index")

	t := u_table_with({U_HOST_A, "aaa-host"})
	app.merge(t, U_HOST_A, {
		u_session(U_HOST_A, "pick-2026-10-18-10-00-00-000", true),
	})

	// The user highlights row 0.
	held := app.selection_from_index(t.rows[:], 0)
	check("held identity is the picked session",
		held.valid && held.name == "pick-2026-10-18-10-00-00-000",
		fmt.tprintf("held={}@{}", held.name, held.device))
	idx_before := app.selection_index(t.rows[:], held)
	eq_int("resolves to index 0 before the merge", idx_before, 0)

	// A remote fetch lands THREE rows. `aaa-host` sorts before unit-host-a, so
	// every one of them is inserted ABOVE the highlighted row.
	app.merge(t, "aaa-host", {
		u_session("aaa-host", "n1-2026-10-18-06-00-00-000", true),
		u_session("aaa-host", "n2-2026-10-18-07-00-00-000", true),
		u_session("aaa-host", "n3-2026-10-18-08-00-00-000", true),
	})

	idx_after := app.selection_index(t.rows[:], held)
	say(fmt.tprintf("    index moved {} -> {} while the identity stayed put",
		idx_before, idx_after))
	check("the index MOVED (3 rows inserted above)", idx_after > idx_before,
		fmt.tprintf("{} -> {}", idx_before, idx_after))

	// …and what the identity resolves to is still the session the user picked.
	sess, ok := app.selection_session(t.rows[:], held)
	check("…and it is STILL the session the user picked",
		ok && sess.name == "pick-2026-10-18-10-00-00-000" &&
		sess.device == U_HOST_A,
		fmt.tprintf("resolved={}@{}", sess.name, sess.device))

	// The counterfactual, stated so the next reader knows what is being bought:
	// an index-carrying selection would now point at index 0, which is aaa-host's
	// n1 — a different session on a different machine. Enter would attach that.
	would_be := t.rows[0]
	check("an index-based selection WOULD have landed on a different session",
		would_be.device == "aaa-host" && would_be.name != held.name,
		fmt.tprintf("index-0 would be {}@{}", would_be.name, would_be.device))

	// Gone session: -1, not a fallback to some index.
	app.merge(t, U_HOST_A, {})
	eq_int("a vanished identity resolves to -1 (never to a stand-in index)",
		app.selection_index(t.rows[:], held), -1)
	_, ok2 := app.selection_session(t.rows[:], held)
	check("resolving a vanished identity yields no session, not a wrong one",
		!ok2, "caller must handle the absence")

	app.table_destroy(t)
}

// ---------------------------------------------------------------------------
// Exit-code contract -> per-host status (the mapping ISC-15 turns on)
// ---------------------------------------------------------------------------

unit_status_mapping :: proc() {
	say("  — transport outcome -> per-host Device_Status")

	// 255 covers BOTH "could not connect" and "would not let us in". The split
	// is ours to make, and it is made by reading ssh's own words. Both strings
	// below are verbatim from this box (see fetch-live / the header notes).
	eq("255 + 'Connection timed out' -> unreachable",
		app.device_status_label(app.ssh_failure_status(
			"ssh: connect to host 10.255.255.1 port 22: Connection timed out")),
		"unreachable")
	eq("255 + 'Permission denied' -> auth",
		app.device_status_label(app.ssh_failure_status(
			"nosuchuser@127.0.0.1: Permission denied (publickey,password,keyboard-interactive).")),
		"auth")
	eq("255 + 'Too many authentication failures' -> auth",
		app.device_status_label(app.ssh_failure_status(
			"Too many authentication failures for user")),
		"auth")
	eq("255 + 'Connection refused' -> unreachable (NOT auth)",
		app.device_status_label(app.ssh_failure_status(
			"ssh: connect to host box port 22: Connection refused")),
		"unreachable")
	eq("255 + 'Host key verification failed' -> unreachable (NOT auth)",
		app.device_status_label(app.ssh_failure_status(
			"Host key verification failed.")),
		"unreachable")

	// `no_herdr` must be reachable at all, and distinct from `unreachable`.
	codes := []app.Device_Status{.ok, .timed_out, .unreachable, .no_herdr, .auth_failed, .failed}
	eq_int("all six device statuses are distinct labels",
		distinct_labels(codes), 6)
	eq("no_herdr reads 'no herdr'", app.device_status_label(.no_herdr), "no herdr")
	check("no_herdr != unreachable",
		app.device_status_label(.no_herdr) != app.device_status_label(.unreachable),
		fmt.tprintf("{} vs {}", app.device_status_label(.no_herdr),
			app.device_status_label(.unreachable)))

	// The Outcome_Kind -> status map, table-style.
	eq("outcome .timed_out -> timeout",
		app.device_status_label(app.device_status_of(.timed_out, "")), "timeout")
	eq("outcome .no_herdr -> no herdr",
		app.device_status_label(app.device_status_of(.no_herdr, "zsh:1: command not found: herdr")),
		"no herdr")
	eq("outcome .ok -> ok",
		app.device_status_label(app.device_status_of(.ok, "")), "ok")
	eq("outcome .herdr_error -> failed",
		app.device_status_label(app.device_status_of(.herdr_error, "")), "failed")
	eq("outcome .tty_panic -> failed",
		app.device_status_label(app.device_status_of(.tty_panic, "")), "failed")
}

distinct_labels :: proc(cs: []app.Device_Status) -> int {
	seen := make(map[string]bool)
	n := 0
	for c in cs {
		l := app.device_status_label(c)
		if seen[l] { continue }
		seen[l] = true
		n += 1
	}
	delete(seen)
	return n
}

// ---------------------------------------------------------------------------
// A failed fetch must not touch the table
// ---------------------------------------------------------------------------

unit_failed_fetch_merges_nothing :: proc() {
	say("  — a failed fetch degrades ONLY its own host")

	t := u_table_with({U_HOST_A, U_HOST_B})
	// Host B is healthy: applied through `apply`, which is the path that sets a
	// device status AND merges rows. Merging rows by hand would leave the status
	// pending and make this test prove nothing about health surviving a peer's
	// failure.
	fb := new(app.Fetch)
	fb.device = U_HOST_B
	fb.label = U_HOST_B
	fb.status = .ok
	fb.settled = true
	fb.rows = {u_session(U_HOST_B, "keep-2026-10-18-12-00-00-000", true)}
	app.apply(t, fb)
	before := rows_fingerprint(t.rows[:])

	// Host A settles unreachable, holding zero rows.
	fa := new(app.Fetch)
	fa.device = U_HOST_A
	fa.label = U_HOST_A
	fa.status = .unreachable
	fa.detail = "ssh: connect to host 10.255.255.1 port 22: Connection timed out"
	fa.settled = true
	fa.exit_code = 255

	rep := app.apply(t, fa)
	eq_int("a failed fetch merges ZERO rows", rep.added, 0)
	eq("the other host's rows are untouched", rows_fingerprint(t.rows[:]), before)

	d := app.table_device(t, U_HOST_A)
	check("the FAILED host carries the failure",
		d != nil && d.status == .unreachable,
		fmt.tprintf("status={}", app.device_status_label(d.status)))
	db := app.table_device(t, U_HOST_B)
	check("the HEALTHY host is still 'ok' after the other one failed",
		db != nil && db.status == .ok,
		fmt.tprintf("status={}", app.device_status_label(db.status)))

	// The failed host's row group is not *cleared* either: blanketing a host on
	// a network blip is its own lie. It keeps whatever we last actually got
	// (nothing here) under a status that says we could not refresh.
	eq_int("table still holds exactly the healthy host's row", len(t.rows), 1)

	app.table_destroy(t)
}

// ---------------------------------------------------------------------------
// Fetch lifecycle against a local stand-in (exercises spawn/drain/reap/settle
// without ssh or a network)
// ---------------------------------------------------------------------------

unit_registry_lifecycle :: proc() {
	say("  — spawn / drain / reap / settle (local stand-in, no ssh)")

	reg : app.Registry = {}
	defer app.registry_free(&reg)

	// ok: writes a real session-list JSON to stdout, nothing to stderr.
	app.registry_add(&reg, app.spawn_fetch("unit-ok", "unit-ok", .local, {
		"sh", "-c",
		`printf '{"sessions":[{"default":true,"name":"default","running":false},{"default":false,"name":"s-2026-10-18-10-00-00-000","running":true}]}'`,
	}, 5 * time.Second))

	// error: writes NOTHING to stdout and a 127-shaped "command not found" to
	// stderr — the exact shape a remote without herdr produces.
	app.registry_add(&reg, app.spawn_fetch("unit-noherdr", "unit-noherdr", .local, {
		"sh", "-c", `echo "sh: 1: herdr-not-here: not found" >&2; exit 127`,
	}, 5 * time.Second))

	// slow: silent for 30 s. Only our deadline can end this one.
	app.registry_add(&reg, app.spawn_fetch("unit-hang", "unit-hang", .local, {
		"sh", "-c", `sleep 30`,
	}, 400 * time.Millisecond))

	eq_int("three fetches registered live", app.registry_pending(&reg), 3)

	ok := app.registry_wait_all(&reg, 8 * time.Second)
	check("the fan-out settled within the overall budget", ok,
		fmt.tprintf("pending={}", app.registry_pending(&reg)))
	eq_int("all three settled", app.registry_pending(&reg), 0)

	st, detail, rows := app.registry_status_for(&reg, "unit-ok")
	eq("ok host -> ok", app.device_status_label(st), "ok")
	eq_int("ok host parsed 1 session (default filtered)", len(rows), 1)
	if len(rows) > 0 {
		eq("the session is the non-default one", rows[0].name, "s-2026-10-18-10-00-00-000")
		eq("and it is tagged with THIS device", rows[0].device, "unit-ok")
	}
	say(fmt.tprintf("    unit-ok: %s / %d row(s)", detail, len(rows)))

	st2, detail2, rows2 := app.registry_status_for(&reg, "unit-noherdr")
	eq("127 host -> no herdr", app.device_status_label(st2), "no herdr")
	eq_int("127 host merged zero rows", len(rows2), 0)
	say(fmt.tprintf("    unit-noherdr: %s", detail2))

	st3, detail3, _ := app.registry_status_for(&reg, "unit-hang")
	eq("hanging host -> timeout (our deadline, not ssh's)",
		app.device_status_label(st3), "timeout")
	check("…and we killed it", hang_killed(&reg), "killed flag set")
	say(fmt.tprintf("    unit-hang: %s (kills={})", detail3, reg.kills))
	eq_int("exactly one child needed killing", reg.kills, 1)
}

hang_killed :: proc(r: ^app.Registry) -> bool {
	for f in r.items {
		if f.device == "unit-hang" { return f.killed }
	}
	return false
}

// ---------------------------------------------------------------------------
// Deadline policy — the ordering that makes ssh's bound the first line
// ---------------------------------------------------------------------------

unit_deadline_policy :: proc() {
	say("  — our deadline sits ABOVE ssh's ConnectTimeout")

	// ssh's own ConnectTimeout=5 is what usually ends a black-holed fetch
	// (measured 5.01 s -> exit 255). Our backstop must be larger, or we would
	// SIGKILL the child *before* ssh ever got to report the honest reason.
	check("FETCH_DEADLINE (13 s) > ssh ConnectTimeout (5 s)",
		app.FETCH_DEADLINE > 5 * time.Second,
		fmt.tprintf("deadline={} s", time.duration_seconds(app.FETCH_DEADLINE)))
	check("the gap is large enough for ssh to report but small enough to matter",
		app.FETCH_DEADLINE <= 20 * time.Second,
		fmt.tprintf("deadline={} s", time.duration_seconds(app.FETCH_DEADLINE)))
	check("the LOCAL deadline is tight (a local list is ~3 ms)",
		app.LOCAL_FETCH_DEADLINE <= 5 * time.Second,
		fmt.tprintf("local={} s", time.duration_seconds(app.LOCAL_FETCH_DEADLINE)))
	check("POLL_SLICE keeps a single sleep short enough to stay honest",
		app.POLL_SLICE <= 100 * time.Millisecond,
		fmt.tprintf("slice={}", time.duration_milliseconds(app.POLL_SLICE)))

	// The mandatory ssh args must survive the refactor into the fetch path:
	// `spawn_remote_fetch` goes through `remote_list_argv`, so assert the argv
	// it will actually run.
	argv := app.remote_list_argv("some.host.example")
	joined := argv_join(argv)
	eq("the fetch argv is exactly the mandatory ssh form", joined,
	   "ssh -T -o BatchMode=yes -o ConnectTimeout=5 some.host.example herdr session list --json")
	check("…contains -T (NOT -t: no pty, no chatter)",
		strings.contains(joined, " -T ") && !strings.contains(joined, " -t "),
		joined)
	check("…BatchMode=yes (auth fast-fails instead of prompting)",
		strings.contains(joined, "BatchMode=yes"), joined)
	check("…ConnectTimeout=5 (a black hole costs 5 s, not 133 s)",
		strings.contains(joined, "ConnectTimeout=5"), joined)
	check("…never -tt (that is the interactive attach seam, not a fetch)",
		!strings.contains(joined, "-tt"), joined)
}
