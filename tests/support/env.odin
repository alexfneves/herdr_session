package support

// ─────────────────────────────────────────────────────────────────────────────
// env.odin — what a child process is allowed to see.
//
// The rule the pre-migration drivers learned the hard way: HERDR_ENV,
// HERDR_SESSION and HERDR_SOCKET_PATH must NEVER reach a child. They are set by
// an outer herdr session on itself, and leaking them into a child makes the child
// believe it IS the outer session — it then attaches to, or worse destroys, the
// session that spawned it. `dev/tui_drive.py:416-427` strips them for exactly
// this reason; the product strips them too (`app.child_environment`). A test
// harness that forgets is a harness that eats the user's work.
//
// Everything here is pure string manipulation so the rule is assertable without
// spawning anything.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:testing"

// HERDR_NAMESPACE_PREFIX is the whole namespace, not the three keys the product
// happens to read today. Stripping the PREFIX rather than an enumerated list is
// the difference between a rule and a snapshot: when the product learns a fourth
// HERDR_* variable, an enumerated list silently stops covering it.
HERDR_NAMESPACE_PREFIX : []u8 = {'H', 'E', 'R', 'D', 'R', '_'}

// is_herdr_var is the predicate the scrub is built from.
is_herdr_var :: proc(key: string) -> bool {
	if len(key) < len(HERDR_NAMESPACE_PREFIX) { return false }
	for i in 0 ..< len(HERDR_NAMESPACE_PREFIX) {
		if key[i] != HERDR_NAMESPACE_PREFIX[i] { return false }
	}
	return true
}

// KV is one environment entry in the shape the spawner wants.
KV :: struct {
	key : string,
	val : string,
}

// scrub strips every HERDR_* entry from an env slice and keeps everything else
// in its original order. The original order is preserved on purpose: two entries
// with the same key resolve by "last wins" in execve, and reordering them would
// change which one the child actually sees.
scrub :: proc(env: []string) -> [dynamic]string {
	out : [dynamic]string = {}
	for e in env {
		eq_at := index_of(e, '=')
		key := e
		if eq_at >= 0 { key = e[:eq_at] }
		if is_herdr_var(key) { continue }
		append(&out, e)
	}
	return out
}

// base_env is the harness equivalent of dev/tui_drive.py:base_env.
//
//  1. start from the CURRENT environment,
//  2. drop every HERDR_* entry,
//  3. drop `scenario`'s own keys from the inherited copy so a scenario value
//     does not end up twice (execve takes the last, and an earlier stale value
//     surviving behind a later one is how a test passes against the wrong
//     configuration),
//  4. force TERM=xterm-256color when the caller did not set one.
//
// TERM is forced rather than inherited because a test that renders differently
// under a dumb terminal than the product does in a real one is testing nothing.
// The driver sets TERM explicitly to test the fallback, so the driver's value
// wins over the default.
base_env :: proc(scenario: []KV) -> [dynamic]string {
	inherited : [dynamic]string = {}
	base, err := os.environ(context.allocator)
	if err == nil {
		for e in base { append(&inherited, e) }
	}
	clean := scrub(inherited[:])

	out : [dynamic]string = {}
	for e in clean[:] {
		eq_at := index_of(e, '=')
		key := e
		if eq_at >= 0 { key = e[:eq_at] }
		skip_it := false
		for s in scenario {
			if s.key == key { skip_it = true; break }
		}
		if skip_it { continue }
		append(&out, e)
	}

	has_term := false
	for s in scenario {
		if s.key == "TERM" { has_term = true }
	}
	for s in scenario { append(&out, fmt.tprintf("{}={}", s.key, s.val)) }
	if !has_term { if !term_present(out[:]) { append(&out, "TERM=xterm-256color") } }
	return out
}

term_present :: proc(env: []string) -> bool {
	for e in env {
		if len(e) >= 4 { if e[:4] == "TERM" { return true } }
	}
	return false
}

//-----------------------------------------------------------------------------
// The fixture triple
//-----------------------------------------------------------------------------
//
// Three variables arm the remote fixture. They are READ, never defaulted to
// something plausible: a fixture that silently picks a default host is a fixture
// that tests whatever happens to be reachable, which is not the same test twice.

REMOTE_VAR       :: "HERDR_SESSION_TEST_REMOTE"
ALIAS_VAR      :: "HERDR_SESSION_TEST_REMOTE_ALIAS"
UNREACHABLE_VAR :: "HERDR_SESSION_TEST_UNREACHABLE"

env_get :: proc(key: string) -> string {
	v, found := os.lookup_env(key, context.allocator)
	if !found { return "" }
	return v
}

// armed reports whether the full triple is present. A partial fixture is NOT
// armed — half a fixture is the state in which a suite quietly degrades into
// asserting less.
armed :: proc() -> bool {
	a := env_get(REMOTE_VAR) != ""
	b := env_get(ALIAS_VAR) != ""
	c := env_get(UNREACHABLE_VAR) != ""
	if !a { return false }
	if !b { return false }
	if !c { return false }
	return true
}

remote       :: proc() -> string { return env_get(REMOTE_VAR) }
remote_alias :: proc() -> string { return env_get(ALIAS_VAR) }
unreachable  :: proc() -> string { return env_get(UNREACHABLE_VAR) }

// describe_missing names which of the three is absent. "fixture not armed" is
// not actionable; "ALIAS is unset" is.
describe_missing :: proc() -> string {
	missing : [dynamic]string = {}
	if env_get(REMOTE_VAR) == "" { append(&missing, REMOTE_VAR) }
	if env_get(ALIAS_VAR) == "" { append(&missing, ALIAS_VAR) }
	if env_get(UNREACHABLE_VAR) == "" { append(&missing, UNREACHABLE_VAR) }
	if len(missing) == 0 { return "all three present" }
	joined := ""
	for m, i in missing {
		if i > 0 { joined = fmt.tprintf("{} {}", joined, m) } else { joined = m }
	}
	return joined
}

//-----------------------------------------------------------------------------
// Counted assertions about the env rules
//-----------------------------------------------------------------------------

// check_scrub asserts the namespace rule holds for `env`, naming any leak. A
// leak reaching a child can destroy the session that spawned the suite, so this
// is not a hygiene check.
check_scrub :: proc(t: ^testing.T, label: string, env: []string) {
	leaked := ""
	n : int = 0
	for e in env {
		eq_at := index_of(e, '=')
		key := e
		if eq_at >= 0 { key = e[:eq_at] }
		if is_herdr_var(key) {
			n += 1
			if leaked == "" { leaked = key } else { leaked = fmt.tprintf("{}, {}", leaked, key) }
		}
	}
	check(t, fmt.tprintf("{} — no HERDR_* reached the child", label), n == 0,
		fmt.tprintf("{} leaked: {}", n, leaked))
}

index_of :: proc(s: string, b: u8) -> int {
	for i := 0; i < len(s); i += 1 {
		if s[i] == b { return i }
	}
	return -1
}
