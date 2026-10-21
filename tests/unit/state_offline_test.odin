package unit

// ─────────────────────────────────────────────────────────────────────────────
// state_offline_test.odin — T6 port of the `state-offline` case.
//
// Source: `case_state_offline` (src/state_cases.odin:1347), which
// dev/state-smoke.sh:96 ran as
//
//     env -i PATH=/nonexistent HERDR_ENV=1 HERDR_SESSION=2026-08-11-23-37-41-812 \
//         "$BIN" state-offline
//
// WHAT THAT RUN WAS PROOF OF
//
// The same seven sub-batteries that pass with a full developer environment —
// PATH full of tools, SSH_AUTH_SOCK pointing at a live agent, XDG_CONFIG_HOME
// pointing at a real config, a herdr binary on PATH — must ALSO pass with NONE
// of it. A state machine that read a config file, resolved a host or shelled
// out to something would fail here, or silently change. 54 assertions.
//
// WHY THE ENVIRONMENT IS SWAPPED IN-PROCESS RATHER THAN IN A CHILD
//
// A child of this binary cannot reuse the ledger: its `HS_TALLY` lines are its
// own, and the gate reads the parent's, so the offline battery's 54 assertions
// would vanish from the suite's count. Re-execing this binary under a filtered
// `env -i` hits the same wall — the child tallies and the parent is silent.
//
// So the swap happens here, in the process that owns the ledger, and it is
// guarded hard, because a process-global environment swap in a shared test
// binary is a genuinely dangerous thing to do:
//
//   1. Every variable is snapshotted into STATIC storage before anything is
//      touched, and if the snapshot cannot hold the environment the swap is
//      REFUSED and the offline tests go red. We never partially clear.
//   2. Each sub-battery makes its own counted check that the window it ran in
//      really was stripped. The offline proof is per-test, so no test can
//      claim "offline" on another test's window; and if the window was not
//      real, the battery is NOT run — a red window beats a green lie.
//   3. The swap is restored on the same thread the moment the battery ends,
//      and the restoration is verified key-by-key in
//      state_offline_env_round_trip_is_exact().
//
// THE WINDOW IS NARROW AND LOCKED, BUT A SHARED LOCK IS STILL WANTED
//
// Every swap here holds ST_ENV_MU, which serialises these tests against each
// other. That is NOT enough on its own against another suite reading the
// environment inside the window (a theme test resolving XDG_CONFIG_HOME while
// HOME is unset would target the real config), so two things are true:
//
//   * this suite is single-threaded in practice, per the plan's mandated
//     -define:ODIN_TEST_THREADS=1 for the whole unit binary; and
//   * a mutex that lives in tests/support and is taken by EVERY environment
//     mutation in every suite is filed as a support request (SUPPORT-ENV-MU).
//     A per-file mutex serialises the files that remember to take it, which is
//     not a contract — the theme suite's own XDG_WRITE_MU is the same shape
//     and for the same reason, and the two cannot see each other from
//     separate per-suite builds. See the note in tests/parity.tsv.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import support "../support"

//-----------------------------------------------------------------------------
// Small environment helpers
//-----------------------------------------------------------------------------

ST_ENV_MU : sync.Mutex = {}

// ST_ENV_MU_LOCK / ST_ENV_MU_UNLOCK wrap the one mutex that keeps two offline
// windows from overlapping. Named rather than inline so the whole suite reads as
// "the window is entered and left in pairs".
ST_ENV_MU_LOCK :: proc() { sync.mutex_lock(&ST_ENV_MU) }
ST_ENV_MU_UNLOCK :: proc() { sync.mutex_unlock(&ST_ENV_MU) }

// st_getenv reads one variable. `os.get_env` needs an allocator; the value is
// only ever compared or printed inside the window, so temp storage suffices.
st_getenv :: proc(key: string) -> string {
	return os.get_env(key, context.temp_allocator)
}

// st_env_key / st_env_val split "KEY=VALUE" on the FIRST '=' only. A value
// containing '=' is normal (DIRENV_DIFF is a base64 blob); a key never does.
st_env_key :: proc(kv: string) -> string {
	eq := strings.index(kv, "=")
	if eq < 0 { return kv }
	return kv[:eq]
}

st_env_val :: proc(kv: string) -> string {
	eq := strings.index(kv, "=")
	if eq < 0 { return "" }
	return kv[eq+1:]
}

// st_env_distinct_keys counts DISTINCT keys in the live environment.
//
// DISTINCT, not raw entries, because core:os's `_environ` on this toolchain
// hands back a duplicated leading entry (observed: n=180 over an environment
// whose first key appears twice). A raw-entry count is then a number that
// cannot be reconciled with anything, and an assertion built on it would be
// wrong in a way that looks like the environment's fault. Key identity is what
// an environment actually IS, so that is what gets counted and compared.
st_env_distinct_keys :: proc() -> int {
	cur, err := os.environ(context.temp_allocator)
	if err != nil { return -1 }
	keys: [dynamic]string
	for kv in cur {
		k := st_env_key(kv)
		seen := false
		for k2 in keys {
			if k2 == k { seen = true; break }
		}
		if !seen { append(&keys, k) }
	}
	n := len(keys)
	delete(keys)
	return n
}

//-----------------------------------------------------------------------------
// The static environment snapshot
//
// STATIC on purpose. A snapshot that lives in the wrong allocator's memory is
// a snapshot that restores garbage into a process that outlives the test. A
// byte pool in .bss has no such problem: its only reader is os.set_env.
//-----------------------------------------------------------------------------

ST_ENV_POOL_CAP :: 1 << 20 // 1 MiB; the developer environment measured ~250 KB
ST_ENV_MAX     :: 1024

st_env_pool : [ST_ENV_POOL_CAP]u8 = {}
st_env_off  : [ST_ENV_MAX]int = {}
st_env_len  : [ST_ENV_MAX]int = {}
st_env_n    : int = 0

st_env_saved_entry :: proc(i: int) -> string {
	return string(st_env_pool[st_env_off[i] : st_env_off[i]+st_env_len[i]])
}

// st_env_capture snapshots every DISTINCT "KEY=VALUE" pair. Returns false —
// having touched NOTHING — if it cannot hold the environment. The safe failure
// is "refuse to swap", never "clear part of it and hope".
st_env_capture :: proc() -> bool {
	cur, err := os.environ(context.temp_allocator)
	if err != nil { return false }
	if len(cur) > ST_ENV_MAX { return false }

	pos := 0
	n := 0
	for kv in cur {
		dup := false
		for j := 0; j < n; j += 1 {
			if st_env_key(st_env_saved_entry(j)) == st_env_key(kv) {
				dup = true
				break
			}
		}
		if dup { continue }
		if pos + len(kv) > ST_ENV_POOL_CAP { return false }
		for j := 0; j < len(kv); j += 1 {
			st_env_pool[pos+j] = kv[j]
		}
		st_env_off[n] = pos
		st_env_len[n] = len(kv)
		pos += len(kv)
		n += 1
	}
	st_env_n = n
	return true
}

Offline_Window :: struct {
	stripped : bool, // the window really was the 3-var environment
	restored : bool, // exit() put the environment back exactly
	saved_n  : int,  // DISTINCT keys held in the snapshot
	got_n    : int,  // DISTINCT keys inside the window
	path_now : string,
	reason   : string,
}

// st_offline_enter swaps the process environment for `env -i`'s equivalent.
// ALL-OR-NOTHING: on any failure the environment is left untouched and
// `stripped` reads false, which makes the calling test red instead of quietly
// running the "offline" battery online.
st_offline_enter :: proc() -> Offline_Window {
	w := Offline_Window{reason = ""}
	w.saved_n = st_env_distinct_keys()

	if !st_env_capture() {
		w.reason = "the environment did not fit the snapshot pool — REFUSING to strip it"
		return w
	}

	os.clear_env()
	if e := os.set_env("PATH", "/nonexistent"); e != nil {
		w.reason = "PATH could not be set after clear_env"
		return w
	}
	if e := os.set_env("HERDR_ENV", "1"); e != nil {
		w.reason = "HERDR_ENV could not be set after clear_env"
		return w
	}
	if e := os.set_env("HERDR_SESSION", "2026-08-11-23-37-41-812"); e != nil {
		w.reason = "HERDR_SESSION could not be set after clear_env"
		return w
	}

	w.got_n = st_env_distinct_keys()
	w.path_now = st_getenv("PATH")
	w.stripped = w.got_n == 3 &&
		w.path_now == "/nonexistent" &&
		st_getenv("HERDR_ENV") == "1" &&
		len(st_getenv("HERDR_SESSION")) > 0
	if !w.stripped {
		w.reason = fmt.tprintf("inside the window: {} distinct variable(s), want exactly 3", w.got_n)
	}
	return w
}

// st_offline_exit restores the snapshot: clear, then re-set every saved pair.
// Clearing first is what removes the three variables we injected.
st_offline_exit :: proc(w: ^Offline_Window) {
	os.clear_env()
	for i := 0; i < st_env_n; i += 1 {
		saved := st_env_saved_entry(i)
		os.set_env(st_env_key(saved), st_env_val(saved))
	}
	w.restored = st_env_matches_snapshot()
}

// st_env_matches_snapshot compares the live environment against the snapshot
// as a SET: same number of DISTINCT keys, and every saved key present with its
// saved value. A positional byte-comparison would turn a re-ordered environment
// into a false failure, which is the kind of flake that gets an assertion
// deleted instead of fixed.
st_env_matches_snapshot :: proc() -> bool {
	if st_env_distinct_keys() != st_env_n { return false }
	for i := 0; i < st_env_n; i += 1 {
		saved := st_env_saved_entry(i)
		if st_getenv(st_env_key(saved)) != st_env_val(saved) { return false }
	}
	return true
}

//-----------------------------------------------------------------------------
// The seven sub-batteries, run with nothing in the environment
//-----------------------------------------------------------------------------

// st_offline_run is the shared shape: take the lock, enter the window, prove
// the window, run the battery, restore, release.
//
// The window proof is COUNTED because "this battery ran offline" is exactly the
// claim the section makes, and a claim nobody checks is the kind that stops
// being true. If the window is not real the battery is NOT run: the check above
// is already red, and running it anyway would let an ONLINE run report itself
// as the offline case.
st_offline_run :: proc(t: ^testing.T, label: string, battery: proc(c: ^Ctx)) {
	// The same mutex the theme suite serialises its XDG_CONFIG_HOME swaps with.
	// Neither this window nor a theme swap may be live at the same time.
	ST_ENV_MU_LOCK()
	defer ST_ENV_MU_UNLOCK()

	c := st_live(t)
	w := st_offline_enter()
	support.check(t,
		fmt.tprintf("{} ran with NO environment: env -i PATH=/nonexistent HERDR_ENV=1", label),
		w.stripped,
		fmt.tprintf("distinct vars in window={} (snapshot held {}) PATH=%q HERDR_ENV=%q %s",
			w.got_n, w.saved_n, w.path_now, st_getenv("HERDR_ENV"), w.reason))
	if !w.stripped {
		st_offline_exit(&w)
		return
	}
	battery(&c)
	st_offline_exit(&w)
	support.note(t, fmt.tprintf("{}: environment restored intact={}", label, w.restored))
}

@(test)
state_offline_reachability :: proc(t: ^testing.T) {
	st_offline_run(t, "state-offline reachability", st_sec_reachability)
}

@(test)
state_offline_two_step :: proc(t: ^testing.T) {
	st_offline_run(t, "state-offline two-step", st_sec_two_step)
}

@(test)
state_offline_no_selection_noop :: proc(t: ^testing.T) {
	st_offline_run(t, "state-offline no-selection", st_sec_no_selection_noop)
}

@(test)
state_offline_ctrl_c_everywhere :: proc(t: ^testing.T) {
	st_offline_run(t, "state-offline ctrl-c", st_sec_ctrl_c_everywhere)
}

@(test)
state_offline_never_default :: proc(t: ^testing.T) {
	st_offline_run(t, "state-offline never-default", st_sec_never_default)
}

@(test)
state_offline_empty_world :: proc(t: ^testing.T) {
	st_offline_run(t, "state-offline empty-world", st_sec_empty_world)
}

@(test)
state_offline_no_children_created :: proc(t: ^testing.T) {
	st_offline_run(t, "state-offline offline-proof", st_sec_offline_proof)
}

//-----------------------------------------------------------------------------
// ADDITIVE — the swap is a checked operation, not a trusted one.
//
// These are NOT part of the 259. They exist because mutating the process
// environment is dangerous enough that "we restored it" must itself be a
// measured claim rather than a line of code someone hopes ran.
//-----------------------------------------------------------------------------

@(test)
state_offline_env_round_trip_is_exact :: proc(t: ^testing.T) {
	ST_ENV_MU_LOCK()
	defer ST_ENV_MU_UNLOCK()

	w := st_offline_enter()
	support.check(t, "ADDITIVE: the strip leaves only PATH + HERDR_ENV + HERDR_SESSION",
		w.stripped,
		fmt.tprintf("distinct vars in window={} (snapshot held {}) PATH=%q HERDR_ENV=%q HERDR_SESSION=%q %s",
			w.got_n, w.saved_n, w.path_now, st_getenv("HERDR_ENV"),
			st_getenv("HERDR_SESSION"), w.reason))
	st_offline_exit(&w)
	support.check(t, "ADDITIVE: the developer environment is identical after the swap",
		w.restored,
		fmt.tprintf("saved {} distinct keys, live now {} — a lost variable here would follow this process out into the shell",
			w.saved_n, st_env_distinct_keys()))
}

// `env -i` has no TERM either, so the old stripped run also proved there was
// nothing here that could be painted at. Checked as part of the window.
@(test)
state_offline_window_carries_no_terminal :: proc(t: ^testing.T) {
	ST_ENV_MU_LOCK()
	defer ST_ENV_MU_UNLOCK()

	w := st_offline_enter()
	term := st_getenv("TERM")
	tty := st_getenv("TTY")
	terminfo := st_getenv("TERMINFO")
	st_offline_exit(&w)
	support.check(t,
		"ADDITIVE: the offline window carries no TERM/TTY/TERMINFO — nothing could paint even if it wanted to",
		w.stripped && len(term) == 0 && len(tty) == 0 && len(terminfo) == 0,
		fmt.tprintf("stripped={} TERM=%q TTY=%q TERMINFO=%q", w.stripped, term, tty, terminfo))
}

// The printf guard for the offline transcript (`assert_formatted "state-offline"`
// in dev/state-smoke.sh), rendered inside a stripped window so the text scanned
// IS the text the offline run produces.
@(test)
state_offline_transcript_is_formatted :: proc(t: ^testing.T) {
	ST_ENV_MU_LOCK()
	defer ST_ENV_MU_UNLOCK()

	w := st_offline_enter()
	text := st_render_offline()
	st_offline_exit(&w)
	support.check(t, "state-offline transcript — no printf fallout",
		w.stripped && !support.has_fallout(text),
		fmt.tprintf("rendered under a stripped env={}; scanned {} bytes ({} lines)",
			w.stripped, len(text), st_count_lines(text)))
}
