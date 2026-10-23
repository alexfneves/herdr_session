package evidence

// ─────────────────────────────────────────────────────────────────────────────
// evidence.odin — the channel the T11 handoff suite reads its facts through.
//
// The handoff suite cannot assert in-process: the whole point of a handoff is
// that the process making the assertions is NOT the process that owns the
// terminal while the child runs. A forked child's counters die with its copy of
// the ledger (DECISIONS "Finding 2") and the terminal owner cannot be the
// tester, because it has to give the tty away.
//
// So the app-role and child-probe roles report *facts about themselves* and the
// test process that owns the pty makes every counted `support.check` call.
//
// A fact is one `key=value` line appended to the file named by $HS_EVIDENCE,
// opened, written and CLOSED the moment it is known. A process that is killed
// mid-flight therefore still leaves everything it already reported, which is
// what makes the SIGINT/SIGTERM scenarios readable at all.
//
// $HS_EVIDENCE is deliberately NOT a HERDR_* name: the product scrubs HERDR_*
// from handoff children and that scrub is itself under test here, so a probe
// that used a name inside the scrubbed namespace could not find its own channel
// — and "the probe reported nothing" would be indistinguishable from "the
// scrub leaked".
//
// READ SIDE: `load` folds the file into a map with LAST-WINS semantics, because
// a key may legitimately be reported twice (before/after a handoff) by two
// different roles sharing one channel. Callers that need the first value must
// use a distinct key, not rely on ordering.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

DEFAULT_ENV :: "HS_EVIDENCE"

// path_for returns the channel path, or "" when the suite did not configure one.
path_for :: proc(env_var: string = DEFAULT_ENV) -> string {
	return os.get_env_alloc(env_var, context.allocator)
}

// report appends `key=value` and closes. A no-op with no channel configured, so
// a probe run by hand outside the suite just prints and does nothing else.
report :: proc(key: string, value: string, env_var: string = DEFAULT_ENV) {
	p := path_for(env_var)
	if len(p) == 0 { return }
	// Open/append/close per fact rather than holding one handle: a process that
	// dies mid-scenario still leaves what it already wrote, and the append is
	// atomic enough at these sizes that two roles sharing a channel cannot
	// interleave inside one line.
	f, err := os.open(p, os.File_Flags{.Write, .Append, .Create}, os.Permissions_Default_File)
	if err != nil {
		fmt.eprintf("evidence: cannot open {} — {} ({} lost)\n", p, err, key)
		return
	}
	defer os.close(f)
	fmt.fprintf(f, "{}={}\n", key, value)
}

report_i64 :: proc(key: string, value: i64, env_var: string = DEFAULT_ENV) {
	report(key, fmt.tprintf("{}", value), env_var)
}

report_bool :: proc(key: string, value: bool, env_var: string = DEFAULT_ENV) {
	report(key, fmt.tprintf("{}", value), env_var)
}

// say writes to OUR stdout — which in every scenario here is the tty this
// process inherited. The tty copy is the ground truth for "this process really
// had that terminal"; the file copy is what the test parses without scraping
// escape sequences off a screen.
//
// It takes a finished string rather than a format string + args on purpose:
// forwarding a variadic into another variadic in Odin does NOT splice (it
// renders the slice), and a helper that silently prints
// `hello [1, "x"] %!(MISSING ARGUMENT)` is a helper that will be believed.
// Callers pass fmt.tprintf(...) explicitly.
say :: proc(msg: string) {
	fmt.print(msg)
}

// ─────────────────────────────────────────────────────────────────────────────
// Read side
// ─────────────────────────────────────────────────────────────────────────────

// load folds the evidence file into a map (last value for a repeated key wins).
// A missing/unreadable file yields an EMPTY map rather than an error: callers
// ask for a key and get "absent", which the test reports as "the role never
// reported it" — a more useful failure than "could not open".
load :: proc(path: string, alloc: mem.Allocator = context.allocator) -> map[string]string {
	m := make(map[string]string, 64, alloc)
	if len(path) == 0 { return m }
	data, err := os.read_entire_file(path, alloc)
	if err != nil { return m }
	defer delete(data)
	parse_into(&m, string(data[:]))
	return m
}

// parse_into splits `key=value` lines. Splitting is done on BYTE INDICES, not
// with a rune loop: a `for a, b in s` in Odin yields a=VALUE, b=INDEX, and a
// value/index mix-up here silently corrupts every key.
parse_into :: proc(m: ^map[string]string, text: string) {
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i == len(text) || text[i] == '\n' {
			if i > start { fold_line(m, text[start:i]) }
			start = i + 1
		}
	}
}

fold_line :: proc(m: ^map[string]string, line: string) {
	// First '=' splits: values may contain '=' (paths, argv, "K=V" blobs).
	for i := 0; i < len(line); i += 1 {
		if line[i] != '=' { continue }
		key := line[:i]
		val := line[i+1:]
		if len(key) == 0 { return }
		// CLONE both halves. Odin's string slicing does not copy: without this
		// the map would hold views into the file buffer that `load` frees the
		// moment it returns. Map lookups hash the needle you pass and then
		// compare against that freed memory, which produces the signature this
		// bug was found by: a key is "present" for one moment, then reads back
		// as absent one statement later, in the same test, on the same map.
		m^[strings.clone(key, context.allocator)] = strings.clone(val, context.allocator)
		return
	}
}
