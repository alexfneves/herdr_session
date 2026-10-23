package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_spawn_test.odin — T10 port of the LOCAL (hermetic) half of
// `case_app_live` (src/app_live.odin:65).
//
// The old case was one binary section that mixed two very different things:
// probes that run against the real herdr on THIS box (hermetic — no network,
// no fixture), and probes that need the armed remote triple (fixture tier,
// T14's). Only the former is here. The 88 fixture assertions are reported as
// belonging to T14 and are deliberately NOT re-counted.
//
// SAFETY
//
// Every name this file can create is `hs-t-*` and every destructive call goes
// through the product's own argv builder so the device routing is the same one
// the UI uses. The session hosting this agent (`HERDR_SESSION`) is never a
// target: nothing here passes a name it did not mint, and the two names it
// mints are constants that cannot collide with a user's.
//
// THE POINT OF EACH SECTION, because "it spawns things" is not a purpose:
//   scrub  — what the CHILD sees, not what our map says
//   split  — stdout and stderr are never merged before a JSON parse (ISC-A-1)
//   exit   — the contract against a real process, not a synthetic Capture
//   gate   — the machine probe's answer agrees with the payload's own shape
//   clock  — our deadline ends a hung child, and the child is reaped
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:testing"

import app "../../src/app"
import support "../support"

// The one scratch name this file's probes touch. Deliberately a fixed
// constant: a name that cannot be user-supplied cannot be a user's session.
ALU_SCRATCH :: "hs-t-phase3-probe"
// A name that must never exist. Used to catch herdr's `delete`-lies.
ALU_SCRATCH_NEVER :: "hs-t-never-created-zz"

alu_list_now :: proc() -> []app.Session {
	c := app.run_capture(app.list_argv(), app.CAPTURE_TIMEOUT)
	rows, _ := app.parse_session_list(c.out, app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	return rows
}

alu_names_of :: proc(rows: []app.Session) -> string {
	parts: [dynamic]string = {}
	for r in rows { append(&parts, r.name) }
	j, _ := strings.join(parts[:], ",")
	return j
}

alu_contains_name :: proc(rows: []app.Session, name: string) -> bool {
	for r in rows { if r.name == name { return true } }
	return false
}

alu_first_line :: proc(s: string) -> string {
	idx := strings.index(s, "\n")
	if idx < 0 { return s }
	return s[:idx]
}

// ── ISC-2: the scrub, proven by asking the CHILD ───────────────────────────
//
// THE SENTINEL, AND WHY IT EXISTS
//
// "The child sees no HERDR_*" has two ways to pass: the scrub removed them,
// or there was nothing to remove. Only one of those is a test. The old
// version closed that hole by reading OUR OWN inherited `HERDR_ENV` — which
// worked from an interactive shell and was WRONG as a proof, because it made
// the non-vacuity of this assertion depend on how the binary happened to be
// launched. The gate strips the whole `HERDR_*` namespace before any suite
// runs (support.base_env — deliberately, since a leaked HERDR_SESSION makes
// a child believe it IS the developer's session), so an inherited-value
// guard fires red there for a reason that has nothing to do with the product.
//
// The fix is not to weaken the guard and not to un-strip the namespace. It is
// to stop borrowing the premise from the launcher and supply it ourselves:
// arm a sentinel HERDR_* value in this process, prove it is armed, and then
// show the spawn did not carry it. Both halves can fail:
//
//   * arm a HERDR_* that the scrub then reaches the child with  -> leaked=[..]
//   * fail to arm (set_env refused, wrong name)                -> "armed" red
//
// The armed value is `hs-t-…`, the scratch prefix (support.SCRATCH_PREFIX):
// a string that is never a real session name, so if the scrub ever DID fail
// the worst a child could be pointed at is a name this suite never creates.
// The prior values are restored on every exit path, including the difference
// between "unset" and "set but empty", which a sloppy restore flattens.

ALU_PROBE_ENV :: "HERDR_ENV"
ALU_PROBE_ENV_VALUE :: "1"
ALU_PROBE_SESSION :: "HERDR_SESSION"
ALU_PROBE_SESSION_VALUE :: "hs-t-scrub-probe"

Alu_Probe :: struct {
	env_prev  : string,
	env_had   : bool,
	sess_prev : string,
	sess_had  : bool,
	armed     : bool,
}

// alu_probe_arm puts two HERDR_* variables into THIS process and reads them
// back. `armed` is the read-back, not the return code: a set_env that
// reported success but did not land would otherwise let the whole test pass
// on a premise that is not true.
alu_probe_arm :: proc(p: ^Alu_Probe) {
	p.env_prev, p.env_had = os.lookup_env(ALU_PROBE_ENV, context.allocator)
	p.sess_prev, p.sess_had = os.lookup_env(ALU_PROBE_SESSION, context.allocator)

	if e := os.set_env(ALU_PROBE_ENV, ALU_PROBE_ENV_VALUE); e != nil {
		alu_probe_disarm(p)
		return
	}
	if e := os.set_env(ALU_PROBE_SESSION, ALU_PROBE_SESSION_VALUE); e != nil {
		alu_probe_disarm(p)
		return
	}

	got_env, env_ok := os.lookup_env(ALU_PROBE_ENV, context.allocator)
	got_sess, sess_ok := os.lookup_env(ALU_PROBE_SESSION, context.allocator)
	p.armed = env_ok && sess_ok &&
		got_env == ALU_PROBE_ENV_VALUE &&
		got_sess == ALU_PROBE_SESSION_VALUE
}

// alu_probe_disarm puts back EXACTLY what was there. Restoring "was unset"
// as "" would leave a HERDR_SESSION the suite never had and every later test
// in this binary would read a session that does not exist.
alu_probe_disarm :: proc(p: ^Alu_Probe) {
	if p.env_had { os.set_env(ALU_PROBE_ENV, p.env_prev) } else { os.unset_env(ALU_PROBE_ENV) }
	if p.sess_had { os.set_env(ALU_PROBE_SESSION, p.sess_prev) } else { os.unset_env(ALU_PROBE_SESSION) }
	p.armed = false
}

app_spawn_battery_alu_child_sees_no_herdr_namespace :: proc(c: ^AU_Ctx) {
	probe := Alu_Probe{}
	alu_probe_arm(&probe)
	defer alu_probe_disarm(&probe)

	au_say(c, fmt.tprintf("  armed sentinel: %s=%q %s=%q  (inherited beforehand: %s=%q %s=%q)",
		ALU_PROBE_ENV, ALU_PROBE_ENV_VALUE, ALU_PROBE_SESSION, ALU_PROBE_SESSION_VALUE,
		ALU_PROBE_ENV, probe.env_prev, ALU_PROBE_SESSION, probe.sess_prev))

	// HALF 1 — the premise. Without this, HALF 2 could be "nothing was ever
	// there to scrub" and still be green.
	au_check(c, "the HERDR_* sentinel is armed in OUR OWN env before spawning",
		probe.armed,
		fmt.tprintf("{}={} {}={} — both must be set HERE, or the child check below proves nothing",
			ALU_PROBE_ENV, ALU_PROBE_ENV_VALUE, ALU_PROBE_SESSION, ALU_PROBE_SESSION_VALUE))

	// `env` is /usr/bin/env — not herdr, but the SAME run_capture path, so
	// the environment we build is exactly the one herdr would get.
	cs := app.run_capture({"env"}, 5 * time.Second)
	au_eq_i(c, "env child exit 0", i64(cs.code), 0)

	lines, _ := strings.split(string(cs.out), "\n")
	leaked: [dynamic]string = {}
	saw_child_env := false
	had_term := false
	term_val := ""
	for l in lines {
		eq_pos := strings.index(l, "=")
		if eq_pos < 0 { continue }
		saw_child_env = true
		k := l[:eq_pos]
		if app.env_is_herdr_namespace(k) { append(&leaked, k) }
		if k == "TERM" { had_term = true; term_val = l[eq_pos+1:] }
	}

	// HALF 2 — the verdict. The sentinel armed above is what makes "leaked=[]"
	// a measurement rather than an absence of evidence.
	au_check(c, "child sees NO HERDR_* variable", len(leaked) == 0,
		fmt.tprintf("leaked={}", leaked[:]))
	// …and the child env has to be a real env for that to mean anything: an
	// empty capture would satisfy `leaked == []` without scrubbing a thing.
	au_check(c, "the child env was captured at all (leaked=[] over nothing is not evidence)",
		saw_child_env && len(cs.out) > 0,
		fmt.tprintf("{} bytes of `env` output", len(cs.out)))
	au_check(c, "child still has TERM", had_term, fmt.tprintf("TERM={}", term_val))

	// HALF 3 — the launcher-independence claim, stated as a check. Whether
	// this process started inside herdr or under a stripped gate environment,
	// the SENTINEL is what is tested, and it did not cross.
	au_say(c, fmt.tprintf("  ambient HERDR_ENV before the arm was %q — the proof above does not depend on it",
		probe.env_prev))
}
@(test)
alu_child_sees_no_herdr_namespace :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_spawn_battery_alu_child_sees_no_herdr_namespace(&__c)
}

app_spawn_battery_alu_streams_stay_split :: proc(c: ^AU_Ctx) {
	// A child that writes a distinct marker to EACH stream. If anything merged
	// the two, this is where it shows.
	cs := app.run_capture({"sh", "-c", "printf 'STDOUT_ONLY\\n'; printf 'STDERR_ONLY\\n' >&2"},
		5 * time.Second)
	au_eq_i(c, "split child exit 0", i64(cs.code), 0)
	au_raw(c, "  captured stdout", cs.out)
	au_raw(c, "  captured stderr", cs.err)
	au_check(c, "stdout holds ONLY the stdout marker",
		strings.contains(string(cs.out), "STDOUT_ONLY") &&
			!strings.contains(string(cs.out), "STDERR_ONLY"),
		fmt.tprintf("stdout={}", string(cs.out)))
	au_check(c, "stderr holds ONLY the stderr marker",
		strings.contains(string(cs.err), "STDERR_ONLY") &&
			!strings.contains(string(cs.err), "STDOUT_ONLY"),
		fmt.tprintf("stderr={}", string(cs.err)))

	// Same shape with a non-zero exit: exit != 0 must read STDERR and only STDERR.
	c2 := app.run_capture({"sh", "-c",
		"printf 'STDOUT_NOISE\\n'; printf 'errjson' >&2; exit 1"}, 5 * time.Second)
	kind, payload, _ := app.outcome(&c2)
	au_eq(c, "exit 1 child maps to a herdr error", app.outcome_label(kind), "herdr error")
	au_check(c, "payload came from stderr, not stdout",
		string(payload) == "errjson" && !strings.contains(string(payload), "STDOUT_NOISE"),
		fmt.tprintf("payload={}", string(payload)))
}
@(test)
alu_streams_stay_split :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_spawn_battery_alu_streams_stay_split(&__c)
}

app_spawn_battery_alu_real_exit_codes_contract :: proc(c: ^AU_Ctx) {
	// exit 1 + stderr JSON: stopping a session that is not running / does not
	// exist. SCRATCH_NEVER is never created, so this destroys nothing.
	missing := app.stop_argv(ALU_SCRATCH_NEVER)
	cs := app.run_capture(missing, app.CAPTURE_TIMEOUT)
	au_say(c, fmt.tprintf("  `herdr session stop --json {}` → exit {}", ALU_SCRATCH_NEVER, cs.code))
	au_raw(c, "    stdout", cs.out)
	au_raw(c, "    stderr", cs.err)
	kind, payload, herr := app.outcome(&cs)
	au_eq_i(c, "stop-missing exits 1", i64(cs.code), 1)
	au_eq(c, "mapped to a herdr error", app.outcome_label(kind), "herdr error")
	au_check(c, "stderr is EMPTY on stdout side", len(cs.out) == 0,
		fmt.tprintf("{} bytes on stdout", len(cs.out)))
	au_check(c, "error envelope parsed from stderr", herr.present,
		fmt.tprintf("code={} message={}", herr.code, herr.message))
	_ = payload

	// exit 2: an unknown herdr subcommand is CLI-level, not a herdr error.
	c2 := app.run_capture({app.HERDR_BIN, "definitely-not-a-subcommand"}, 5 * time.Second)
	kind2, _, _ := app.outcome(&c2)
	au_say(c, fmt.tprintf("  unknown subcommand → exit {} stderr={}", c2.code, string(c2.err)))
	au_eq_i(c, "unknown subcommand exits 2", i64(c2.code), 2)
	au_eq(c, "mapped to a CLI-level error", app.outcome_label(kind2), "bad command line")
}
@(test)
alu_real_exit_codes_contract :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_spawn_battery_alu_real_exit_codes_contract(&__c)
}

app_spawn_battery_alu_unspawnable_and_ssh_failure :: proc(c: ^AU_Ctx) {
	// exit 127: nothing to spawn. Locally reproducible, and the SAME code a
	// remote `herdr: command not found` produces — which is how "no herdr
	// there" is read.
	c3 := app.run_capture({"hs-definitely-not-a-real-binary"}, 2 * time.Second)
	kind3, _, _ := app.outcome(&c3)
	au_check(c, "unspawnable program reports not-spawned", !c3.spawned, "spawned=false")
	au_eq(c, "mapped to herdr not found", app.outcome_label(kind3), "herdr not found")

	// exit 255: ssh transport failure. An unroutable RFC 5737 address fails
	// fast and is unmistakable — and it is NOT the fixture host, so this runs
	// with no fixture armed.
	c4 := app.run_capture(app.remote_list_argv("192.0.2.201"), 8 * time.Second)
	kind4, _, _ := app.outcome(&c4)
	au_say(c, fmt.tprintf("  ssh to an unreachable host → exit {}", c4.code))
	au_eq_i(c, "unreachable ssh exits 255", i64(c4.code), 255)
	au_eq(c, "mapped to an ssh transport failure", app.outcome_label(kind4), "ssh failed")
}
@(test)
alu_unspawnable_and_ssh_failure :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_spawn_battery_alu_unspawnable_and_ssh_failure(&__c)
}

app_spawn_battery_alu_herdr_delete_lies_our_model_refuses :: proc(c: ^AU_Ctx) {
	// THE EVIDENCE: herdr answers `deleted:true` with EXIT 0 for a session
	// that was never created. Any code that trusts it reports success on a
	// typo. SCRATCH_NEVER is never created, so nothing is destroyed either
	// way — but the refusal is what we own.
	cs := app.run_capture(app.delete_argv(ALU_SCRATCH_NEVER), app.CAPTURE_TIMEOUT)
	au_say(c, fmt.tprintf("  `herdr session delete --json {}` (never created) → exit {}",
		ALU_SCRATCH_NEVER, cs.code))
	au_raw(c, "    stdout", cs.out)
	au_check(c, "herdr LIES: exit 0 for a session that never existed", cs.code == 0,
		fmt.tprintf("exit={}", cs.code))
	au_check(c, "herdr's stdout says deleted:true",
		strings.contains(string(cs.out), `"deleted":true`),
		fmt.tprintf("stdout={}", string(cs.out)))
	au_check(c, "and it still is not in the real list",
		!alu_contains_name(alu_list_now(), ALU_SCRATCH_NEVER), "confirmed absent")

	// OUR behaviour: the model refuses, so the lie never reaches the user.
	res := app.delete_session(alu_list_now(), app.DEVICE_LOCAL, ALU_SCRATCH_NEVER,
		app.CAPTURE_TIMEOUT)
	au_check(c, "delete_session REFUSES the never-created name",
		res.refused && !res.deleted && !res.existed,
		fmt.tprintf("refused={} deleted={} existed={} reason={}",
			res.refused, res.deleted, res.existed, res.reason))

	// `default` is refused by name before anything else (D12).
	dres := app.delete_session(alu_list_now(), app.DEVICE_LOCAL, "default", app.CAPTURE_TIMEOUT)
	au_check(c, "delete_session REFUSES `default`", dres.refused && !dres.deleted,
		fmt.tprintf("reason={}", dres.reason))
}

// ── the machine gate against the REAL payload ──────────────────────────────

// alu_says_registry answers the same question as the product's gate but from
// the RAW BYTES alone: first non-whitespace character, and whether the
// payload mentions `machines` at all. It deliberately does NOT call
// `machine_registry_available`, because a check that re-calls the function
// under test can never fail. Two independent paths to the same answer is the
// only version of "it read the payload correctly" worth printing.
alu_says_registry :: proc(payload: []byte) -> bool {
	if len(payload) == 0 { return false }
	first: byte = 0
	for b in payload {
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' { continue }
		first = b
		break
	}
	if first == '[' { return true }
	if first != '{' { return false }
	text := string(payload)
	return strings.contains(text, "\"machines\"") || strings.contains(text, "machines")
}

alu_devices_of :: proc(rs: []app.Remote) -> string {
	parts: [dynamic]string = {}
	for r in rs { append(&parts, r.device) }
	j, _ := strings.join(parts[:], " ")
	return j
}
@(test)
alu_herdr_delete_lies_our_model_refuses :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_spawn_battery_alu_herdr_delete_lies_our_model_refuses(&__c)
}

app_spawn_battery_alu_machine_gate_probe_agrees_with_its_payload :: proc(c: ^AU_Ctx) {
	cs := app.run_capture(app.machine_probe_argv(), app.CAPTURE_TIMEOUT)
	au_say(c, fmt.tprintf("  `herdr machine list --json` → exit {}", cs.code))
	au_raw(c, "    stdout", cs.out)
	au_raw(c, "    stderr", cs.err)

	available := app.machine_registry_available(cs.out)
	says_registry := alu_says_registry(cs.out)
	au_check(c, "the machine probe spawned a child that answered (not a silent no-op)",
		cs.spawned && len(cs.out) > 0,
		fmt.tprintf("spawned={} stdout={} bytes", cs.spawned, len(cs.out)))
	au_check(c, "the gate's answer agrees with the payload's shape (gate never invents one)",
		available == says_registry,
		fmt.tprintf("gate said {}; the payload starts as {}", available, says_registry))
	au_check(c, "gate decision is made on shape, independent of the exit code",
		app.machine_registry_available(cs.out) == available,
		fmt.tprintf("exit={} shape={}", cs.code, available))
}
@(test)
alu_machine_gate_probe_agrees_with_its_payload :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_spawn_battery_alu_machine_gate_probe_agrees_with_its_payload(&__c)
}

app_spawn_battery_alu_o13_real_registry_never_drops_the_configured_remote :: proc(c: ^AU_Ctx) {
	cs := app.run_capture(app.machine_probe_argv(), app.CAPTURE_TIMEOUT)
	// O13 against the REAL payload rather than a fixture. `[]` is exactly
	// what 0.9.5 prints on a box with no machines, so this is not a
	// hypothetical: the merge below is the difference between "the
	// configured host is on screen" and "the device list is quietly one
	// shorter".
	cfg: [dynamic]app.Remote = {}
	append(&cfg, app.Remote{device = "configured.example", label = "Configured"})
	d := app.discover_resolved(cs.out, cfg[:])
	au_say(c, fmt.tprintf("    discovery source: {} · from_registry={} from_config={} · {} remote(s): {}",
		app.machine_source_label(d.source), d.from_registry, d.from_config, len(d.remotes),
		alu_devices_of(d.remotes)))
	au_check(c, "O13: whatever the registry said, the configured remote is present",
		au_contains_device(d.remotes, "configured.example"),
		fmt.tprintf("remotes={} (registry said {} bytes)", alu_devices_of(d.remotes), len(cs.out)))
	au_check(c, "O13: and nothing in the merge was silently dropped",
		len(d.remotes) == d.from_registry + d.from_config,
		fmt.tprintf("{} != {} + {}", len(d.remotes), d.from_registry, d.from_config))
	if len(app.machine_array_of(cs.out)) == 0 {
		au_check(c, "O13: an EMPTY registry (this box) still leaves the configured remote",
			len(d.remotes) >= 1,
			fmt.tprintf("registry empty, {} remote(s) survive: {}", len(d.remotes),
				alu_devices_of(d.remotes)))
	}
}
@(test)
alu_o13_real_registry_never_drops_the_configured_remote :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_spawn_battery_alu_o13_real_registry_never_drops_the_configured_remote(&__c)
}

app_spawn_battery_alu_our_timeout_kills_and_reaps :: proc(c: ^AU_Ctx) {
	started := time.now()
	cs := app.run_capture({"sleep", "30"}, 400 * time.Millisecond)
	elapsed := time.duration_milliseconds(time.since(started))
	kind, _, _ := app.outcome(&cs)
	au_say(c, fmt.tprintf("  sleep 30 under a 400 ms budget → exit {} after {} ms",
		cs.code, elapsed))
	au_eq_i(c, "timeout reports our own code 124", i64(cs.code), 124)
	au_check(c, "timed_out flag is set", cs.timed_out, "we killed it")
	au_eq(c, "mapped to timed_out", app.outcome_label(kind), "timed out")
	au_check(c, "it actually returned within the budget (+ slack)", elapsed < 3000,
		fmt.tprintf("{} ms", elapsed))
	au_check(c, "the killed child is reaped (no zombie we left behind)",
		cs.spawned, fmt.tprintf("spawned={}", cs.spawned))
}
@(test)
alu_our_timeout_kills_and_reaps :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_spawn_battery_alu_our_timeout_kills_and_reaps(&__c)
}

