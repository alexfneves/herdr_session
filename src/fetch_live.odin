package main

// PHASE 4 LIVE DRIVER — the parallel fan-out against real ssh children.
//
// This is where the no-threads design is either true or not. The unit case
// proves what the merge does; only real processes can prove that:
//
//   * N hosts really do cost ~max(host) and not ~N x host,
//   * a host that never answers cannot stall the loop,
//   * our children are always reaped (no zombies),
//   * our pipes are always closed (no fd leak),
//   * local rows exist before a remote fd has been read.
//
// Fixture: `HERDR_SESSION_TEST_REMOTE` + `HERDR_SESSION_TEST_REMOTE_ALIAS`
// (+ `HERDR_SESSION_TEST_UNREACHABLE` for the timeout/black-hole case). NOTHING
// here is hard-coded into product code; unset the variables and the remote half
// of this file declines to run. Which is exactly why the runner must be armed —
// an unarmed run is green and proves almost nothing (learned in Phase 3).
//
// SAFETY: this driver runs READ-ONLY commands (`session list`). It never
// creates, attaches or deletes a session, so there is no scratch herdr state to
// leave behind. The pre/post session-list proof in dev/fetch-smoke.sh is belt
// and braces for that claim, not the mechanism.

import app "./app"

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// ---------------------------------------------------------------------------
// Fixture access
// ---------------------------------------------------------------------------

fx_remote :: proc() -> string {
	return os.get_env_alloc("HERDR_SESSION_TEST_REMOTE", context.allocator)
}
fx_alias :: proc() -> string {
	return os.get_env_alloc("HERDR_SESSION_TEST_REMOTE_ALIAS", context.allocator)
}
fx_unreachable :: proc() -> string {
	v := os.get_env_alloc("HERDR_SESSION_TEST_UNREACHABLE", context.allocator)
	if v != "" { return v }
	// RFC 5737 TEST-NET-1: not routable, guaranteed to black-hole. This is a
	// *test* default, in a driver, not a product default and not the fixture —
	// the fixture is what the env vars name.
	return "192.0.2.201"
}

ms :: proc(d: time.Duration) -> f64 {
	return time.duration_milliseconds(d)
}

case_fetch_live :: proc() -> bool {
	say("case fetch-live — the parallel fan-out, against real ssh children")

	remote := fx_remote()
	alias := fx_alias()
	if remote == "" {
		say("  SKIP: HERDR_SESSION_TEST_REMOTE unset — the whole live fan-out needs")
		say("        a ssh fixture. Re-run ARMED (see dev/fetch-smoke.sh); an")
		say("        unarmed pass of this case proves nothing.")
		check("live fan-out actually ran", false, "fixture not armed")
		return false
	}

	// 1. Concurrency, not serialization.
	live_concurrency(remote, alias)
	// 2. Local paints before any remote fd is read.
	live_local_first(remote)
	// 3. Timeout bounded, and the loop stayed responsive.
	live_timeout_bounded()
	// 4. No zombies after normal completion, after timeout, after error.
	live_no_zombies(remote)
	// 5. Per-host isolation.
	live_per_host_isolation(remote)
	// 6. Identity-preserving merge with two REAL target strings.
	if alias != "" && alias != remote {
		live_identity_two_targets(remote, alias)
	} else {
		say("  SKIP discriminator: need HERDR_SESSION_TEST_REMOTE_ALIAS too")
	}
	// 7. no_herdr is distinct from unreachable.
	live_no_herdr_vs_unreachable(remote)
	// 8. Stress: many hosts, no fd leak, all settle.
	live_stress(remote, alias)

	return !any_failed
}

// ---------------------------------------------------------------------------
// 1. Concurrency, not serialization
// ---------------------------------------------------------------------------

// live_concurrency is the ISC-6/plan headline: two hosts fetched concurrently
// finish in about ONE host's time, not two. The serial baseline is the same two
// hosts fetched with the blocking `run_capture`, so the comparison is
// apples-to-apples on the same network and the same commands.
live_concurrency :: proc(primary, second: string) {
	say("  [1] concurrency, not serialization")

	// Both arms use the SAME non-blocking registry mechanism and the SAME ssh
	// commands; the only difference is whether the two children overlap. That
	// isolates "is the loop concurrent" from "is async cheaper than blocking",
	// which are different claims, and it keeps the ssh spawn cost identical on
	// both sides of the comparison (an important property when the fixture is
	// one local machine, where N sshd spawns contend for CPU and inflate
	// everyone's numbers equally).
	devices := make([dynamic]string, 0, 4)
	defer delete(devices)
	append(&devices, primary)
	if second != "" && second != primary { append(&devices, second) }

	// --- arm A: strictly one child at a time, same loop.
	// Inlined rather than wrapped in a nested proc because Odin has no implicit
	// closure capture, and threading an explicit capture through added nothing.
	serial := time.Duration(0)
	serial_latencies := make([dynamic]time.Duration, 0, 4)
	defer delete(serial_latencies)
	for d in devices {
		sreg : app.Registry = {}
		st := time.now()
		app.registry_add(&sreg, app.spawn_remote_fetch(app.Remote{device = d, label = d}, 20 * time.Second))
		ok := app.registry_wait_all(&sreg, 25 * time.Second)
		cost := time.since(st)
		for f in sreg.items {
			append(&serial_latencies, time.diff(f.started_at, f.settled_at))
		}
		pending_after := app.registry_pending(&sreg)
		app.registry_free(&sreg)
		check(fmt.tprintf("one-at-a-time fetch of {} completed", d),
			ok && pending_after == 0, fmt.tprintf("pending={} cost={:.0f} ms", pending_after, ms(cost)))
		serial += cost
	}
	serial_sum := time.Duration(0)
	for l in serial_latencies { serial_sum += l }
	say(fmt.tprintf("    one at a time  wall={:.0f} ms  (children sum={:.0f} ms, wall/sum={:.2f})",
		ms(serial), ms(serial_sum), ms(serial_sum) > 0 ? ms(serial) / ms(serial_sum) : 0.0))
	if len(serial_latencies) >= 2 {
		check("CONTROL: the serialized arm sits AT its children's sum (>0.8)",
			ms(serial) > ms(serial_sum) * 0.8,
			fmt.tprintf("wall={:.0f} ms vs sum={:.0f} ms (ratio {:.2f}) — serialized IS the sum",
				ms(serial), ms(serial_sum), ms(serial_sum) > 0 ? ms(serial) / ms(serial_sum) : 0.0))
	}

	// --- arm B: all children in flight at once, one poll loop.
	con_t0 := time.now()
	reg : app.Registry = {}
	defer app.registry_free(&reg)
	for d in devices {
		app.registry_add(&reg, app.spawn_remote_fetch(app.Remote{device = d, label = d}, 20 * time.Second))
	}
	check("all children are in flight simultaneously",
		app.registry_pending(&reg) == len(devices),
		fmt.tprintf("pending={} devices={}", app.registry_pending(&reg), len(devices)))
	done := app.registry_wait_all(&reg, 25 * time.Second)
	concurrent := time.since(con_t0)
	for f in reg.items {
		say(fmt.tprintf("      {} settled {:.0f} ms after its own spawn",
			f.device, ms(time.diff(f.started_at, f.settled_at))))
	}
	say(fmt.tprintf("    fan-out          wall={:.0f} ms  (loops={} wakeups={})",
		ms(concurrent), reg.loops, reg.wakeups))
	check("every fan-out fetch completed", done && app.registry_pending(&reg) == 0,
		fmt.tprintf("pending={}", app.registry_pending(&reg)))

	// THE headline assertion — measured INSIDE the fan-out arm.
	//
	// ⚠️ The obvious version of this compares the fan-out wall against the
	// serial arm's wall. That is unsound on a real box: per-host ssh cost here
	// swings between ~100 ms and ~240 ms run to run (sshd auth contention), so
	// a serial arm can measure 255 ms while the very next fan-out sees one host
	// take 238 ms on its own. The two arms did not measure the same costs, and
	// the ratio blamed the loop for the fixture.
	//
	// The per-child latencies are recorded by the SAME clock in the SAME arm, so
	// comparing the fan-out wall against their SUM is self-contained: if the
	// loop were secretly serialized, the wall WOULD be the sum, and the 0.8 bar
	// cannot be met. Comparing against the MAX proves it is max-bound rather
	// than sum-bound.
	sum_lat := time.Duration(0)
	max_lat := time.Duration(0)
	for f in reg.items {
		lat := time.diff(f.started_at, f.settled_at)
		sum_lat += lat
		if lat > max_lat { max_lat = lat }
	}
	say(fmt.tprintf("      children: sum={:.0f} ms  slowest={:.0f} ms  fan-out wall={:.0f} ms (ratio vs sum {:.2f})",
		ms(sum_lat), ms(max_lat), ms(concurrent),
		ms(sum_lat) > 0 ? ms(concurrent) / ms(sum_lat) : 0.0))
	check("fan-out wall is well under the SUM of its own children's latencies",
		ms(concurrent) < ms(sum_lat) * 0.8,
		fmt.tprintf("wall={:.0f} ms vs sum={:.0f} ms (ratio {:.2f}, want <0.80 — serialized would BE the sum)",
			ms(concurrent), ms(sum_lat), ms(sum_lat) > 0 ? ms(concurrent) / ms(sum_lat) : 0.0))
	// SPAWN_SLACK covers our own fork + pipe setup + the poll granularity between
	// the slowest child finishing and us noticing. It is a floor on the
	// measurement, not on the concurrency, so it is added rather than scaled.
	SPAWN_SLACK_MS :: 120.0
	check("fan-out wall is bounded by the SLOWEST child, not by their number",
		ms(concurrent) <= ms(max_lat) + SPAWN_SLACK_MS,
		fmt.tprintf("wall={:.0f} ms vs slowest={:.0f} ms (+{:.0f} ms spawn/poll slack)",
			ms(concurrent), ms(max_lat), SPAWN_SLACK_MS))
	// The serial arm is kept as CONTEXT in the transcript, not as the pass/fail
	// baseline: it shows what the same two hosts cost one-at-a-time through the
	// same loop right now, which is what the reader wants to see next to the
	// fan-out number. It is not asserted against the fan-out for the variance
	// reason above.
	if ms(serial) > 40 {
		say(fmt.tprintf("      (context) same loop, one at a time: {:.0f} ms vs fan-out {:.0f} ms",
			ms(serial), ms(concurrent)))
	}
}

// ---------------------------------------------------------------------------
// 2. Local paints before any remote fd is read
// ---------------------------------------------------------------------------

live_local_first :: proc(remote: string) {
	say("  [2] local paints before any remote fetch completes (ISC-6)")

	t : app.Table = {}
	defer app.table_free(&t)
	app.table_reset_devices(&t, {app.Device{target = app.DEVICE_LOCAL, label = "local", status = .pending}})

	// Start the remote FIRST — if local still wins the race with the remote
	// already in flight, the ordering is real and not just a matter of when we
	// chose to start things.
	reg : app.Registry = {}
	defer app.registry_free(&reg)
	f := app.spawn_remote_fetch(app.Remote{device = remote, label = remote}, 20 * time.Second)
	app.registry_add(&reg, f)

	loc_t0 := time.now()
	mrep, cap := app.local_snapshot(&t, 5 * time.Second)
	loc := time.since(loc_t0)

	say(fmt.tprintf("    local fetch: exit={} rows={} wall={:.2f} ms",
		cap.code, mrep.added, ms(loc)))
	check("local rows are in the model", mrep.added >= 1,
		fmt.tprintf("added={}", mrep.added))
	check("…in well under one remote round-trip", ms(loc) < 50,
		fmt.tprintf("{:.2f} ms", ms(loc)))

	// The ordering proof: at this instant the remote's fd has not been drained
	// at all, so nothing remote could have been painted.
	check("remote has delivered ZERO bytes so far (no read attempted)",
		len(f.out) == 0 && len(f.err) == 0,
		fmt.tprintf("out={} B err={} B", len(f.out), len(f.err)))
	check("remote is still pending", f.settled == false, "settled=false")
	check("local group is already ok while remote is pending",
		app.table_device(&t, app.DEVICE_LOCAL).status == .ok,
		fmt.tprintf("local={}", app.device_status_label(app.table_device(&t, app.DEVICE_LOCAL).status)))

	// And the remote DOES arrive, proving the zero above is ordering and not a
	// dead pipe.
	ok := app.registry_wait_all(&reg, 25 * time.Second)
	check("the remote then completes", ok, fmt.tprintf("status={}", app.device_status_label(f.status)))
	check("…and its fd WAS read (so the earlier zero was timing, not silence)",
		len(f.out) > 0, fmt.tprintf("out={} B", len(f.out)))
	say(fmt.tprintf("    remote arrived at {:.0f} ms after local; local painted {:.0f} ms earlier",
		ms(time.since(loc_t0)), ms(loc)))

	// The paint-order invariant, as the view will read it: local rows sort first.
	app.apply(&t, f)
	if len(t.rows) > 0 {
		check("local rows are STILL first after the remote merges in",
			t.rows[0].device == app.DEVICE_LOCAL,
			fmt.tprintf("first={}", t.rows[0].device))
	}
}

// ---------------------------------------------------------------------------
// 3. Timeout bounded
// ---------------------------------------------------------------------------

// live_timeout_bounded proves two separate bounds, because they are two separate
// mechanisms and conflating them is how you end up thinking you have a timeout
// you do not:
//
//   (a) ssh's own ConnectTimeout — a black-holed host exits 255 at ~5 s, and
//       our loop reports `unreachable` without blocking.
//   (b) our OWN deadline — a child that neither writes nor exits is SIGKILLed
//       at our budget, reaped, and reported `timeout`.
live_timeout_bounded :: proc() {
	say("  [3] timeout bounded + the loop never blocked")

	// ---- (b) our own deadline, on a child that hangs forever.
	hang_argv := []string{"sh", "-c", "sleep 300"}
	budget := 500 * time.Millisecond
	reg : app.Registry = {}
	defer app.registry_free(&reg)

	t0 := time.now()
	f := app.spawn_fetch("blackhole-local", "blackhole-local", .remote, hang_argv, budget)
	app.registry_add(&reg, f)

	// Drive it with a frame counter: a frame is one registry_step, i.e. one
	// opportunity to paint. If the loop were blocked we would get ~1 frame for
	// the whole wait instead of many.
	frames := 0
	for app.registry_pending(&reg) > 0 {
		if time.since(t0) > 5 * time.Second { break }
		app.registry_step(&reg, 20 * time.Millisecond)
		frames += 1
	}
	elapsed := time.since(t0)
	say(fmt.tprintf("    our deadline: budget={:.0f} ms  elapsed={:.0f} ms  frames={}  killed={}  status={}",
		ms(budget), ms(elapsed), frames, f.killed, app.device_status_label(f.status)))
	eq("a hung child ends as timeout", app.device_status_label(f.status), "timeout")
	check("…by killing, not by waiting it out", f.killed, "killed=true")
	check("…inside the budget (+ polling slack, never the 300 s sleep)",
		ms(elapsed) >= ms(budget) - 50 && ms(elapsed) < 2000,
		fmt.tprintf("{:.0f} ms vs budget {:.0f} ms", ms(elapsed), ms(budget)))
	check("the UI thread got MANY frames during the wait (never blocked)",
		frames >= 10,
		fmt.tprintf("frames={} over {:.0f} ms -> one frame every {:.1f} ms",
			frames, ms(elapsed), frames > 0 ? ms(elapsed) / f64(frames) : 0.0))

	// ---- (a) ssh's own ConnectTimeout on a real black-holed address.
	bh := fx_unreachable()
	say(fmt.tprintf("    ssh ConnectTimeout against {} (unroutable TEST-NET)", bh))
	reg2 : app.Registry = {}
	defer app.registry_free(&reg2)
	t1 := time.now()
	app.registry_add(&reg2, app.spawn_remote_fetch(app.Remote{device = bh, label = bh}, app.FETCH_DEADLINE))
	ssh_frames := 0
	for app.registry_pending(&reg2) > 0 {
		if time.since(t1) > 20 * time.Second { break }
		app.registry_step(&reg2, 50 * time.Millisecond)
		ssh_frames += 1
	}
	ssh_elapsed := time.since(t1)
	st2, detail2, _ := app.registry_status_for(&reg2, bh)
	say(fmt.tprintf("    ssh black hole: status={} after {:.0f} ms ({} frames) detail={}",
		app.device_status_label(st2), ms(ssh_elapsed), ssh_frames, detail2))
	eq("black-holed host reports unreachable (ssh's bound, not ours)",
		app.device_status_label(st2), "unreachable")
	check("…bounded at ~ssh's ConnectTimeout, far under the 133 s no-timeout case",
		ms(ssh_elapsed) < 12000, fmt.tprintf("{:.0f} ms", ms(ssh_elapsed)))
	check("…and we did NOT have to kill it (ssh answered its own deadline)",
		ssh_killed_count(&reg2) == 0, fmt.tprintf("kills={}", reg2.kills))
	check("…with many loop iterations (still responsive the whole 5 s)",
		ssh_frames >= 20, fmt.tprintf("frames={}", ssh_frames))
}

ssh_killed_count :: proc(r: ^app.Registry) -> int {
	n := 0
	for f in r.items {
		if f.killed { n += 1 }
	}
	return n
}

// ---------------------------------------------------------------------------
// 4. No zombies
// ---------------------------------------------------------------------------

live_no_zombies :: proc(remote: string) {
	say("  [4] no zombie processes, after normal / timeout / error")

	// Every child we have spawned is recorded here so the child count is exact
	// rather than "whatever ps happens to show".
	reg : app.Registry = {}
	defer app.registry_free(&reg)

	app.registry_add(&reg, app.spawn_remote_fetch(app.Remote{device = remote, label = remote}, 20 * time.Second))
	app.registry_add(&reg, app.spawn_fetch("zombie-hang", "zombie-hang", .remote,
		[]string{"sh", "-c", "sleep 300"}, 400 * time.Millisecond))
	app.registry_add(&reg, app.spawn_fetch("zombie-err", "zombie-err", .remote,
		[]string{"sh", "-c", "echo boom >&2; exit 255"}, 20 * time.Second))

	ok := app.registry_wait_all(&reg, 25 * time.Second)
	check("all three settled (normal + timeout + error)", ok,
		fmt.tprintf("pending={}", app.registry_pending(&reg)))

	// Now the OS-level proof. Three angles, because a single one can lie:
	//
	//   1. our reap claimed every child,
	//   2. a non-blocking waitpid on OUR pid finds nothing left to reap,
	//   3. /proc reports zero zombie children of us.
	z := zombie_children_of_self()
	say(fmt.tprintf("    zombie children of us: {}  (settled={} kills={})",
		z, app.registry_settled(&reg), reg.kills))
	eq_int("zero zombie children of this process", z, 0)

	// The strongest single check: waitpid(-1, WNOHANG) must return 0 (no child
	// has exited unwaited-for) or -1/ECHILD (no children at all). A zombie we
	// created would come back as a positive pid here.
	status : c.int = 0
	r := posix.waitpid(-1, &status, {.NOHANG})
	check("waitpid(-1, WNOHANG) finds no unreaped child", r <= 0,
		fmt.tprintf("waitpid -> {} (any positive pid would be a leftover)", int(r)))

	// And per-fetch: every spawned child is reaped in its own record.
	unreaped := 0
	for f in reg.items {
		if f.spawned && !f.settled { unreaped += 1 }
	}
	eq_int("every spawned fetch is settled", unreaped, 0)

	// Spawn a fresh batch and check AGAIN — zombies are cumulative, so one
	// clean pass can hide a leak that started earlier.
	reg_b : app.Registry = {}
	defer app.registry_free(&reg_b)
	for i in 0..<4 {
		name := fmt.tprintf("zombie-batch-{}", i)
		app.registry_add(&reg_b, app.spawn_fetch(name, name, .local,
			[]string{"sh", "-c", "printf '{\"sessions\":[]}'"}, 5 * time.Second))
	}
	app.registry_wait_all(&reg_b, 20 * time.Second)
	z2 := zombie_children_of_self()
	say(fmt.tprintf("    after a second batch of 4: zombie children = {}", z2))
	eq_int("still zero zombies after a second batch", z2, 0)
}

// zombie_children_of_self counts Z-state processes whose PPid is us, straight
// out of /proc. Deliberately not a `ps` pipe: that would add a child of its own
// and make the count depend on the shell, which is exactly the kind of thing a
// leak check must not do.
zombie_children_of_self :: proc() -> int {
	self := int(posix.getpid())
	entries, err := os.read_all_directory_by_path("/proc", context.allocator)
	if err != nil { return -1 }
	n := 0
	for e in entries {
		pid := parse_int_or(e.name, -1)
		if pid < 0 { continue } // only numeric dirs are pids
		data, derr := os.read_entire_file_from_path(
			strings.concatenate({"/proc/", e.name, "/status"}, context.allocator),
			context.allocator)
		if derr != nil { continue }
		txt := string(data)
		if strings.contains(txt, "State:\tZ") {
			idx := strings.index(txt, "PPid:")
			if idx >= 0 {
				tail := strings.trim_left(txt[idx + 5:], " \t")
				if parse_int_or(tail, -1) == self { n += 1 }
			}
		}
		delete(data)
	}
	delete(entries)
	return n
}

// parse_int_or reads the leading ASCII integer out of a string. /proc fields are
// "Key:\tvalue\n", so trimming the key leaves the number and a trailing
// newline we deliberately do not care about.
parse_int_or :: proc(s: string, fallback: int) -> int {
	n := 0
	digits := 0
	for b in transmute([]byte)(s) {
		if b < '0' || b > '9' { break }
		n = n * 10 + int(b - '0')
		digits += 1
	}
	if digits == 0 { return fallback }
	return n
}

// ---------------------------------------------------------------------------
// 5. Per-host isolation
// ---------------------------------------------------------------------------

live_per_host_isolation :: proc(remote: string) {
	say("  [5] one host errors, the other still merges (ISC-15)")

	t : app.Table = {}
	defer app.table_free(&t)
	reg : app.Registry = {}
	defer app.registry_free(&reg)

	broken := fx_unreachable()
	app.registry_add(&reg, app.spawn_remote_fetch(app.Remote{device = broken, label = "broken"}, app.FETCH_DEADLINE))
	app.registry_add(&reg, app.spawn_remote_fetch(app.Remote{device = remote, label = "healthy"}, 20 * time.Second))

	ok := app.registry_wait_all(&reg, 25 * time.Second)
	check("the fan-out settled with one broken host", ok,
		fmt.tprintf("pending={}", app.registry_pending(&reg)))

	for f in reg.items {
		app.apply(&t, f)
	}

	s := app.table_device(&t, remote)
	b := app.table_device(&t, broken)
	eq("healthy host status = ok", app.device_status_label(s.status), "ok")
	// Was `check("healthy host has rows", true, ...)`: the label promised rows and
	// the operand was a literal `true`, so `grep 'healthy host has rows'` read
	// like coverage of something that was never asserted. Now it asserts the thing
	// its own name claims, and it CAN fail — if the fixture's healthy host came
	// back with an empty session list, this is the line that says so.
	check("healthy host has rows", count_device_rows(&t, remote) > 0,
		fmt.tprintf("rows for {} = {} (must be > 0)", remote, count_device_rows(&t, remote)))
	eq("broken host status = unreachable", app.device_status_label(b.status), "unreachable")
	eq_int("broken host contributed ZERO rows", count_device_rows(&t, broken), 0)
	check("the healthy host's rows are all that is in the table",
		count_device_rows(&t, remote) == len(t.rows),
		fmt.tprintf("total={} healthy={}", len(t.rows), count_device_rows(&t, remote)))
	say(fmt.tprintf("    table: {} rows, all under {}", len(t.rows), remote))

	// …and the app did not "fail": the table is populated and the failure is a
	// per-row-group status, not a global condition.
	check("the app as a whole has a usable table", len(t.rows) > 0,
		fmt.tprintf("{} rows", len(t.rows)))
}

count_device_rows :: proc(t: ^app.Table, device: string) -> int {
	n := 0
	for r in t.rows { if r.device == device { n += 1 } }
	return n
}

// ---------------------------------------------------------------------------
// 6. Identity-preserving merge, two real target strings
// ---------------------------------------------------------------------------

live_identity_two_targets :: proc(primary, alias: string) {
	say("  [6] identity-preserving merge, two REAL ssh target strings")

	reg : app.Registry = {}
	defer app.registry_free(&reg)
	app.registry_add(&reg, app.spawn_remote_fetch(app.Remote{device = primary, label = primary}, 20 * time.Second))
	app.registry_add(&reg, app.spawn_remote_fetch(app.Remote{device = alias, label = alias}, 20 * time.Second))
	ok := app.registry_wait_all(&reg, 25 * time.Second)
	if !ok {
		check("both target strings completed", false, "timeout waiting")
		return
	}

	_, _, rows_p := app.registry_status_for(&reg, primary)
	_, _, rows_a := app.registry_status_for(&reg, alias)
	say(fmt.tprintf("    {} -> {} session(s); {} -> {} session(s)",
		primary, len(rows_p), alias, len(rows_a)))
	if len(rows_p) == 0 {
		check("primary target returned sessions to test with", false, "0 rows")
		return
	}

	t : app.Table = {}
	defer app.table_free(&t)
	app.merge(&t, primary, rows_p)
	app.merge(&t, alias, rows_a)

	// The same machine under two target strings yields byte-identical session
	// names. A name-keyed model would collapse the whole set down to one host's
	// worth of rows.
	eq_int("no rows collapsed: total == sum of both groups",
		len(t.rows), len(rows_p) + len(rows_a))
	eq_int("each group keeps its own count",
		count_device_rows(&t, primary) + count_device_rows(&t, alias),
		len(rows_p) + len(rows_a))
	say(fmt.tprintf("    combined table: {} rows ({} + {})", len(t.rows),
		count_device_rows(&t, primary), count_device_rows(&t, alias)))

	// Deleting one identity must leave the other's identical name present.
	if len(rows_p) > 0 {
		name := rows_p[0].name
		held_p := app.Selection{device = primary, name = name, valid = true}
		check("identity is resolvable under BOTH targets before the delete",
			app.is_known_session(t.rows[:], primary, name) &&
			app.is_known_session(t.rows[:], alias, name),
			fmt.tprintf("name={} p={} a={}", name,
				app.is_known_session(t.rows[:], primary, name),
				app.is_known_session(t.rows[:], alias, name)))

		// Refresh the alias group with everything EXCEPT that name.
		trimmed := make([dynamic]app.Session, 0, len(rows_a))
		for r in rows_a {
			if r.name == name { continue }
			append(&trimmed, r)
		}
		app.merge(&t, alias, trimmed[:])
		check("dropping it from ONE target leaves it on the other",
			app.is_known_session(t.rows[:], primary, name) &&
			!app.is_known_session(t.rows[:], alias, name),
			fmt.tprintf("still-under-primary={} still-under-alias={}",
				app.is_known_session(t.rows[:], primary, name),
				app.is_known_session(t.rows[:], alias, name)))
		delete(trimmed)

		// And the selection the user was holding never moved.
		sess, sok := app.selection_session(t.rows[:], held_p)
		check("a selection held across that merge still resolves to the same session",
			sok && sess.device == primary && sess.name == name,
			fmt.tprintf("resolved={}@{}", sok, name))

		// The round-trip: that identity still produces the VERBATIM target in
		// the launch argv, which is what the device string is ultimately for.
		la, lok := app.launch_argv(sess.device, sess.name)
		check("…and launching with it keeps the target string verbatim",
			lok && argv_contains(la, primary), argv_join(la))
	}
}

// ---------------------------------------------------------------------------
// 7. no_herdr vs unreachable
// ---------------------------------------------------------------------------

live_no_herdr_vs_unreachable :: proc(remote: string) {
	say("  [7] `no herdr` is a DISTINCT state from `unreachable`")

	// Both hosts are reached over real ssh. One has no `herdr` in its
	// non-interactive PATH; the other is not reachable at all. The exit codes
	// differ (127 vs 255) and the user-facing state must differ too — "your
	// host is down" and "your host has no herdr" call for different fixes, and
	// flattening them is the classic useless error.
	reg : app.Registry = {}
	defer app.registry_free(&reg)

	// `bash -lc` with a PATH that has no herdr in it reproduces the real
	// condition exactly: the shell reports 127 and ssh propagates it.
	app.registry_add(&reg, app.spawn_fetch("no-herdr-host", "no-herdr-host", .remote, {
		"ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", remote,
		"env PATH=/nonexistent-r7k1 herdr session list --json",
	}, 20 * time.Second))
	app.registry_add(&reg, app.spawn_remote_fetch(
		app.Remote{device = fx_unreachable(), label = "unreachable-host"}, app.FETCH_DEADLINE))

	ok := app.registry_wait_all(&reg, 25 * time.Second)
	check("both settled", ok, fmt.tprintf("pending={}", app.registry_pending(&reg)))

	st1, d1, rows1 := app.registry_status_for(&reg, "no-herdr-host")
	st2, d2, _ := app.registry_status_for(&reg, fx_unreachable())
	say(fmt.tprintf("    no-herdr-host: status={} exit={} detail={}",
		app.device_status_label(st1), find_status_code(&reg, "no-herdr-host"), d1))
	say(fmt.tprintf("    unreachable-host: status={} exit={} detail={}",
		app.device_status_label(st2), find_status_code(&reg, fx_unreachable()), d2))

	eq("missing herdr on the remote -> 'no herdr'", app.device_status_label(st1), "no herdr")
	eq("unroutable host -> 'unreachable'", app.device_status_label(st2), "unreachable")
	check("THE TWO ARE NOT THE SAME STATE",
		app.device_status_label(st1) != app.device_status_label(st2),
		fmt.tprintf("{} vs {}", app.device_status_label(st1), app.device_status_label(st2)))
	eq_int("no-herdr host merged no rows", len(rows1), 0)
}

find_status_code :: proc(r: ^app.Registry, device: string) -> i32 {
	for f in r.items { if f.device == device { return f.exit_code } }
	return -9999
}

// ---------------------------------------------------------------------------
// 8. Stress: many hosts at once, no fd leak, all settle
// ---------------------------------------------------------------------------

live_stress :: proc(primary, alias: string) {
	say("  [8] stress: many concurrent children, no fd leak, all settle")

	// fd baseline BEFORE touching anything.
	fd_before := open_fd_count()
	threads_before := thread_count()

	reg : app.Registry = {}
	defer app.registry_free(&reg)

	// A deliberately mixed 8-host fan-out: real remote fetches, a couple of
	// hangs that only our deadline can end, and error paths. Each real ssh
	// child costs us two pipe fds, so this is also an fd-count exercise.
	HOSTS := 8
	for i in 0..<HOSTS {
		dev := primary
		if alias != "" && i % 2 == 1 { dev = alias }
		label := fmt.tprintf("stress-{}-{}", i, dev)
		select := i % 4
		if select == 2 {
			// hangs forever — our deadline is the only thing that ends it
			app.registry_add(&reg, app.spawn_fetch(label, label, .remote,
				[]string{"sh", "-c", "sleep 600"}, 900 * time.Millisecond))
		} else if select == 3 {
			// writes a little then fails
			app.registry_add(&reg, app.spawn_fetch(label, label, .remote, {
				"sh", "-c", "printf '{\"sessions\":[]}'; echo kaboom >&2; exit 1",
			}, 10 * time.Second))
		} else {
			app.registry_add(&reg, app.spawn_remote_fetch(
				app.Remote{device = dev, label = label}, 20 * time.Second))
		}
	}
	eq_int("8 children in flight at once", len(reg.items), HOSTS)

	t0 := time.now()
	ok := app.registry_wait_all(&reg, 30 * time.Second)
	elapsed := time.since(t0)
	say(fmt.tprintf("    all 8 settled={} in {:.0f} ms (loops={} wakeups={} idle={} kills={})",
		ok, ms(elapsed), reg.loops, reg.wakeups, reg.idle_wakes, reg.kills))
	check("every one of them settled", ok && app.registry_pending(&reg) == 0,
		fmt.tprintf("pending={}", app.registry_pending(&reg)))
	check("…bounded well under the sum of their individual worst cases",
		ms(elapsed) < 12000, fmt.tprintf("{:.0f} ms", ms(elapsed)))
	check("…and the loop iterated rather than blocked once",
		reg.loops > HOSTS, fmt.tprintf("loops={}", reg.loops))

	// Now close everything out and compare the fd count. This is the fd leak
	// check: fetch_close must have run for every child, including the ones we
	// killed.
	for f in reg.items { app.fetch_close(f) }
	fd_after := open_fd_count()
	say(fmt.tprintf("    fds: before={} after={} delta={}",
		fd_before, fd_after, fd_after - fd_before))
	eq_int("no fd leak across 8 concurrent fetches (2 pipes each)",
		fd_after, fd_before)
	eq_int("no thread leak either (the design has none)", threads_before, thread_count())

	// Close-out is idempotent — a second pass must not double-close.
	for f in reg.items { app.fetch_close(f) }
	eq_int("idempotent close: fd count unchanged after a second pass",
		open_fd_count(), fd_after)

	// Nothing alive left over.
	eq_int("no zombie children after the stress pass", zombie_children_of_self(), 0)
}

// ---------------------------------------------------------------------------
// /proc readers for the leak checks
// ---------------------------------------------------------------------------

open_fd_count :: proc() -> int {
	entries, err := os.read_all_directory_by_path("/proc/self/fd", context.allocator)
	if err != nil { return -1 }
	n := len(entries)
	delete(entries)
	return n
}

thread_count :: proc() -> int {
	entries, err := os.read_all_directory_by_path("/proc/self/task", context.allocator)
	if err != nil { return -1 }
	n := len(entries)
	delete(entries)
	return n
}
