package unit

// ─────────────────────────────────────────────────────────────────────────────
// fetch_unit_test.odin — T10 port of `case_fetch_unit` (src/fetch_cases.odin:37).
//
// The fan-out's data model, proven with no subprocess in the identity sections
// and a LOCAL `sh -c` stand-in in the lifecycle ones. The live half — real ssh,
// real concurrency, measured wall times, real zombies — is fetch-live and is
// T14's fixture tier. What lives here is everything that must hold regardless
// of whether a network exists.
//
// U_HOST_A / U_HOST_B are identity namespaces, not hosts. They are
// deliberately NOT loopback-shaped: a name that looks like a fixture invites a
// later reader to "helpfully" point it at localhost, which would make the
// (device,name) proof depend on a machine.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

AFU_HOST_A :: "unit-host-a"
AFU_HOST_B :: "unit-host-b"

// The name that exists under BOTH devices. Names collide across hosts by
// design, so this is the pair of rows a name-keyed model would collapse.
AFU_SHARED :: "api-2026-10-18-20-30-45-123"

afu_session :: proc(device, name: string, running: bool) -> app.Session {
	return app.Session{
		device = device, label = device, name = name, running = running,
		ts = app.ts_from_name(name),
	}
}

afu_table_with :: proc(devices: []string) -> ^app.Table {
	t := new(app.Table)
	devs := make([dynamic]app.Device, 0, len(devices))
	for d in devices {
		append(&devs, app.Device{target = d, label = d, status = .pending})
	}
	app.table_reset_devices(t, devs[:])
	delete(devs)
	return t
}

// afu_fingerprint is everything that identifies a row AND its state, in the
// order the table holds it. Two fingerprints equal means no row was added,
// dropped, renamed, retagged, reordered or had its running flag touched.
afu_fingerprint :: proc(rows: []app.Session) -> string {
	parts := make([dynamic]string, 0, len(rows))
	for r in rows {
		append(&parts, fmt.tprintf("{}|{}|{}", r.device, r.name, r.running))
	}
	joined, _ := strings.join(parts[:], " ;; ")
	delete(parts)
	return joined
}

afu_device_order :: proc(rows: []app.Session) -> string {
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

afu_names_of_device :: proc(rows: []app.Session, device: string) -> string {
	parts := make([dynamic]string, 0, 8)
	for r in rows {
		if r.device != device { continue }
		append(&parts, r.name)
	}
	j, _ := strings.join(parts[:], ",")
	delete(parts)
	return j
}

afu_groups_contiguous :: proc(rows: []app.Session) -> bool {
	seen := make(map[string]bool)
	last := ""
	for r in rows {
		if r.device != last {
			if seen[r.device] { return false }  // a group we already closed re-opened
			seen[r.device] = true
			last = r.device
		}
	}
	delete(seen)
	return true
}

afu_argv_join :: proc(argv: []string) -> string {
	j, _ := strings.join(argv, " ")
	return j
}

// ── identity is (device, name) ──────────────────────────────────────────────

app_fetch_identity_battery_afu_merge_identity_is_the_pair :: proc(c: ^AU_Ctx) {
	tb := afu_table_with({AFU_HOST_A, AFU_HOST_B})

	// The same session name under two devices. herdr scopes names per
	// (host, unix-user) and its `session list --json` carries no host field at
	// all, so two hosts owning `api-…` is normal, not an error.
	a := []app.Session{afu_session(AFU_HOST_A, AFU_SHARED, true)}
	b := []app.Session{afu_session(AFU_HOST_B, AFU_SHARED, true)}

	ra := app.merge(tb, AFU_HOST_A, a)
	rb := app.merge(tb, AFU_HOST_B, b)

	au_eq_int(c, "same name under two devices -> two rows", len(tb.rows), 2)
	au_check(c, "neither row was collapsed onto the name",
		app.index_of_identity(tb.rows[:], AFU_HOST_A, AFU_SHARED) >= 0 &&
			app.index_of_identity(tb.rows[:], AFU_HOST_B, AFU_SHARED) >= 0,
		fmt.tprintf("A@{} B@{}",
			app.index_of_identity(tb.rows[:], AFU_HOST_A, AFU_SHARED),
			app.index_of_identity(tb.rows[:], AFU_HOST_B, AFU_SHARED)))
	au_eq_int(c, "host A reported 1 added", ra.added, 1)
	au_eq_int(c, "host B reported 1 added", rb.added, 1)
	au_say(c, fmt.tprintf("    %s", afu_fingerprint(tb.rows[:])))

	// Both groups are still individually addressable after the second merge —
	// which is what attach/delete actually need.
	sa, ok_a := app.selection_session(tb.rows[:],
		app.Selection{device = AFU_HOST_A, name = AFU_SHARED, valid = true})
	sb, ok_b := app.selection_session(tb.rows[:],
		app.Selection{device = AFU_HOST_B, name = AFU_SHARED, valid = true})
	au_check(c, "each identity resolves to its OWN row",
		ok_a && ok_b && sa.device == AFU_HOST_A && sb.device == AFU_HOST_B,
		fmt.tprintf("a.device={} b.device={}", sa.device, sb.device))
	au_check(c, "the two rows are NOT the same row", sa != sb,
		fmt.tprintf("a_ptr={} b_ptr={}", sa, sb))

	app.table_destroy(tb)
}

// ── refreshing A does not disturb B (ISC-15) ───────────────────────────────

afu_snapshot_b :: proc(tbl: ^app.Table) -> string {
	parts := make([dynamic]string, 0, 8)
	for r in tbl.rows {
		if r.device != AFU_HOST_B { continue }
		append(&parts, fmt.tprintf("{}|{}|{}", r.device, r.name, r.running))
	}
	j, _ := strings.join(parts[:], " ;; ")
	delete(parts)
	return j
}
@(test)
afu_merge_identity_is_the_pair :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_identity_battery_afu_merge_identity_is_the_pair(&__c)
}

app_fetch_identity_battery_afu_merge_isolation_refreshing_a_leaves_b :: proc(c: ^AU_Ctx) {
	tb := afu_table_with({AFU_HOST_A, AFU_HOST_B})

	app.merge(tb, AFU_HOST_A, {
		afu_session(AFU_HOST_A, "a-one-2026-10-18-01-00-00-000", true),
		afu_session(AFU_HOST_A, "a-two-2026-10-18-02-00-00-000", false),
	})
	app.merge(tb, AFU_HOST_B, {
		afu_session(AFU_HOST_B, "b-one-2026-10-18-03-00-00-000", true),
		afu_session(AFU_HOST_B, "b-two-2026-10-18-04-00-00-000", true),
	})
	b_before := afu_snapshot_b(tb)

	// A refresh of A: one row goes away, one changes state, one is new.
	rep := app.merge(tb, AFU_HOST_A, {
		afu_session(AFU_HOST_A, "a-one-2026-10-18-01-00-00-000", false),  // state flip
		afu_session(AFU_HOST_A, "a-new-2026-10-18-09-00-00-000", true),   // added
																	   // a-two dropped
	})
	au_eq_int(c, "refresh added 1", rep.added, 1)
	au_eq_int(c, "refresh updated 1", rep.updated, 1)
	au_eq_int(c, "refresh removed 1", rep.removed, 1)
	au_eq_int(c, "carried through 2 foreign rows", rep.carried, 2)

	b_after := afu_snapshot_b(tb)
	au_eq(c, "host B's rows are byte-identical after A's refresh", b_after, b_before)
	au_say(c, fmt.tprintf("    B unchanged: %s", b_after))
	au_say(c, fmt.tprintf("    table now:   %s", afu_fingerprint(tb.rows[:])))

	// `carried` is "rows of OTHER devices preserved", not "rows returned".
	au_check(c, "carried counts only OTHER devices' rows",
		rep.carried == 2 && rep.total == 4,
		fmt.tprintf("carried={} total={}", rep.carried, rep.total))

	app.table_destroy(tb)
}
@(test)
afu_merge_isolation_refreshing_a_leaves_b :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_identity_battery_afu_merge_isolation_refreshing_a_leaves_b(&__c)
}

app_fetch_identity_battery_afu_merge_reinsert_keeps_identity :: proc(c: ^AU_Ctx) {
	tb := afu_table_with({AFU_HOST_A})
	name := "db-2026-10-18-11-00-00-000"

	app.merge(tb, AFU_HOST_A, {afu_session(AFU_HOST_A, name, true)})
	au_check(c, "present after add",
		app.is_known_session(tb.rows[:], AFU_HOST_A, name), "1 row")

	// Empty list = the session is gone on the host.
	rep := app.merge(tb, AFU_HOST_A, {})
	au_eq_int(c, "empty refresh removes the row", rep.removed, 1)
	au_check(c, "gone after delete",
		!app.is_known_session(tb.rows[:], AFU_HOST_A, name), "0 rows")

	app.merge(tb, AFU_HOST_A, {afu_session(AFU_HOST_A, name, false)})
	au_eq_int(c, "re-add yields exactly one row", len(tb.rows), 1)
	au_check(c, "re-added row is found by the SAME identity",
		app.is_known_session(tb.rows[:], AFU_HOST_A, name),
		"identity stable across delete/re-add")

	// The STATE came back fresh (was running=true, now false), so the table is
	// not serving a stale row from the first add.
	idx := app.index_of_identity(tb.rows[:], AFU_HOST_A, name)
	au_check(c, "re-added row carries the NEW state, not the old one",
		idx >= 0 && !tb.rows[idx].running, fmt.tprintf("running={}", tb.rows[idx].running))

	app.table_destroy(tb)
}
@(test)
afu_merge_reinsert_keeps_identity :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_identity_battery_afu_merge_reinsert_keeps_identity(&__c)
}

app_fetch_identity_battery_afu_merge_order_local_first_then_device_then_ts :: proc(c: ^AU_Ctx) {
	tb := afu_table_with({app.DEVICE_LOCAL, AFU_HOST_A, "aaa-host"})

	// Deliberately merged out of order: remote first, local last.
	app.merge(tb, AFU_HOST_A, {
		afu_session(AFU_HOST_A, "late-2026-10-18-23-00-00-000", true),
		afu_session(AFU_HOST_A, "early-2026-10-18-01-00-00-000", true),
		afu_session(AFU_HOST_A, "no-ts", true),
	})
	app.merge(tb, "aaa-host", {afu_session("aaa-host", "x-2026-10-18-12-00-00-000", true)})
	app.merge(tb, app.DEVICE_LOCAL, {
		afu_session(app.DEVICE_LOCAL, "z-2026-10-18-22-00-00-000", true),
		afu_session(app.DEVICE_LOCAL, "a-2026-10-18-05-00-00-000", true),
	})

	order := afu_device_order(tb.rows[:])
	au_say(c, fmt.tprintf("    device order: {}", order))
	au_eq(c, "local group first, then alphabetical host, then unit-host-a", order,
		fmt.tprintf("{},aaa-host,{}", app.DEVICE_LOCAL, AFU_HOST_A))
	au_check(c, "local rows contiguous (never interleaved)",
		afu_groups_contiguous(tb.rows[:]), fmt.tprintf("order={}", order))

	// Inside one device: ts ascending, unknown LAST (the I64_MAX sentinel).
	inside := afu_names_of_device(tb.rows[:], AFU_HOST_A)
	au_say(c, fmt.tprintf("    inside {}: {}", AFU_HOST_A, inside))
	au_eq(c, "timestamps ascending, 'no ts' last", inside,
		"early-2026-10-18-01-00-00-000,late-2026-10-18-23-00-00-000,no-ts")
	app.table_destroy(tb)
}
@(test)
afu_merge_order_local_first_then_device_then_ts :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_identity_battery_afu_merge_order_local_first_then_device_then_ts(&__c)
}

app_fetch_identity_battery_afu_selection_tracks_identity_not_index :: proc(c: ^AU_Ctx) {
	tb := afu_table_with({AFU_HOST_A, "aaa-host"})
	app.merge(tb, AFU_HOST_A, {
		afu_session(AFU_HOST_A, "pick-2026-10-18-10-00-00-000", true),
	})

	// The user highlights row 0.
	held := app.selection_from_index(tb.rows[:], 0)
	au_check(c, "held identity is the picked session",
		held.valid && held.name == "pick-2026-10-18-10-00-00-000",
		fmt.tprintf("held={}@{}", held.name, held.device))
	idx_before := app.selection_index(tb.rows[:], held)
	au_eq_int(c, "resolves to index 0 before the merge", idx_before, 0)

	// A remote fetch lands THREE rows. `aaa-host` sorts before unit-host-a, so
	// every one of them is inserted ABOVE the highlighted row.
	app.merge(tb, "aaa-host", {
		afu_session("aaa-host", "n1-2026-10-18-06-00-00-000", true),
		afu_session("aaa-host", "n2-2026-10-18-07-00-00-000", true),
		afu_session("aaa-host", "n3-2026-10-18-08-00-00-000", true),
	})
	idx_after := app.selection_index(tb.rows[:], held)
	au_say(c, fmt.tprintf("    index moved {} -> {} while the identity stayed put",
		idx_before, idx_after))
	au_check(c, "the index MOVED (3 rows inserted above)", idx_after > idx_before,
		fmt.tprintf("{} -> {}", idx_before, idx_after))

	sess, ok := app.selection_session(tb.rows[:], held)
	au_check(c, "…and it is STILL the session the user picked",
		ok && sess.name == "pick-2026-10-18-10-00-00-000" && sess.device == AFU_HOST_A,
		fmt.tprintf("resolved={}@{}", sess.name, sess.device))

	// The counterfactual, stated so the next reader knows what is being
	// bought: an index-carrying selection would now point at index 0 —
	// aaa-host's n1, a different session on a different machine. Enter
	// would attach THAT.
	would_be := tb.rows[0]
	au_check(c, "an index-based selection WOULD have landed on a different session",
		would_be.device == "aaa-host" && would_be.name != held.name,
		fmt.tprintf("index-0 would be {}@{}", would_be.name, would_be.device))

	// Gone session: -1, not a fallback to some index.
	app.merge(tb, AFU_HOST_A, {})
	au_eq_int(c, "a vanished identity resolves to -1 (never to a stand-in index)",
		app.selection_index(tb.rows[:], held), -1)
	_, ok2 := app.selection_session(tb.rows[:], held)
	au_check(c, "resolving a vanished identity yields no session, not a wrong one",
		!ok2, "caller must handle the absence")

	app.table_destroy(tb)
}
@(test)
afu_selection_tracks_identity_not_index :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_fetch_identity_battery_afu_selection_tracks_identity_not_index(&__c)
}

