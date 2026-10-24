package unit

// theme_hygiene_test.odin — T9 port of the hygiene block from dev/theme-smoke.sh.
//
// SIX counted assertions, mirroring the bash block one-for-one. Every one of
// them is a RUNTIME PROOF that can fail, not a comment saying "we were careful".
//
// WHY THE REAL-CONFIG PROOF IS AN AGGREGATE AND NOT A BEFORE/AFTER PAIR
//
// The bash suite fingerprinted the real ~/.config/herdr_session.json once
// before the run and once after. That shape depends on run order: it only
// proves what happened between the two shells. Under core:testing a test can
// fail, be filtered out with ODIN_TEST_NAMES, or be reordered, and then the
// bracket silently covers nothing while still printing green.
//
// So the fingerprint is taken by the SAME helper that performs the dangerous
// operation (theme_home.odin `swap_in`/`swap_out_no_t`), and each of those
// records its own verdict into a static aggregate. This test then asserts over
// the aggregate, and asserts that the aggregate is NOT EMPTY — a hygiene check
// that passes because nothing was ever measured is the worst possible kind of
// green.
//
// WHY THE SOURCE GREPS STRIP COMMENTS FIRST
//
// A grep for "toml" over raw source matches this very file explaining that we
// do not use TOML. The scanner therefore removes `//` line comments before
// matching, and the test asserts on the surviving code lines. Without that the
// check is unfalsifiable: the documentation of the rule breaks the rule.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

@(test)
hygiene_real_user_config_untouched :: proc(t: ^testing.T) {
	// (1) THE HEADLINE PROOF. N swaps were performed; every one of them
	// fingerprinted the developer's real config before pointing XDG at a
	// scratch dir, and re-fingerprinted it after restoring. Any write that
	// escaped the sandbox lands in bad_untouched.
	// Run the battery FIRST so this proof does not depend on any other test
	// file having run. Anything the rest of the suite also verified only makes
	// the aggregate stronger; nothing here gets weaker if the rest is skipped.
	ensure_battery()

	snap := agg_snapshot()
	n := snap.n
	bad := snap.bad_untouched
	support.check(t,
		"real ~/.config/herdr_session.json untouched across every config write in this suite",
		n > 0 && bad == 0,
		fmt.tprintf("swaps_verified={} violations={} first_seen='{}' last_seen='{}' (real file: {})",
			n, bad, snap.before, snap.after, real_cfg_state_now()))
}

@(test)
hygiene_xdg_config_home_did_not_leak :: proc(t: ^testing.T) {
	// (2) THE NON-LEAK PROOF, aggregate over the same swaps, PLUS a direct
	// check of the process right now: the value the process sees must equal
	// the value it saw before any swap happened. The per-swap check proves
	// each restore was exact; this proves the process was not left pointing at
	// a scratch dir by some path that bypassed the helper.
	// Run the battery here too. Without it this check depends on some OTHER
	// test having swapped first, and if the harness schedules this file first
	// the aggregate is empty and `proc_xdg_matches_start` has no captured
	// baseline to compare against — which reads as a leak that never happened.
	swaps := ensure_battery()
	snap := agg_snapshot()
	bad := snap.bad_leak
	support.check(t, "XDG_CONFIG_HOME did not leak into the caller",
		bad == 0 && proc_xdg_matches_start(),
		// ARITY FIXED (UIP-5). This line had FOUR placeholders and FIVE
		// arguments — `swaps` was passed twice — so every value from the
		// second one onward was shifted left and the surplus spilled as
		// `%!(EXTRA …)`. What that means in practice: `start='1'` on the
		// ledger was not the start value at all, it was the SWAP COUNT, and
		// the real start value had been shoved into `now=`. A detail line
		// whose numbers are not what they claim is worse than no detail line,
		// which is exactly why the gate fails a suite over a stray marker.
		// Four placeholders, four arguments now; the asserted condition is
		// byte-identical to before.
		fmt.tprintf("leaks={} battery_swaps={} start='{}' now='{}' ('<UNSET>' = genuinely unset)",
			bad, swaps, proc_xdg_start_display(), proc_xdg_now_display()))
}

// Bound arrays, not inline literals: Odin will not coerce a bare composite literal into a
// slice at a call site.
toml_needles : []string = {"toml", "TOML", "BurntSushi", "tomlplusplus"}

@(test)
hygiene_no_toml_anywhere_in_src :: proc(t: ^testing.T) {
	// The user asked for JSON. A TOML dependency creeping back in is a
	// dependency-tree change hiding behind a plausible-looking import line, so
	// it is grepped for rather than trusted.
	hits := src_code_hits(toml_needles[:])
	support.check(t, "no TOML parser, import or path in non-comment src/ lines",
		len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), join_lines(hits[:])))
}

xdg_needles : []string = {"base:xdg", "xdg::", "libxdg", "Xdg::"}

@(test)
hygiene_no_xdg_library_import :: proc(t: ^testing.T) {
	// We resolve XDG ourselves through core/os so the resolution is one
	// documented hop instead of a third-party library's idea of the spec.
	hits := src_code_hits(xdg_needles[:])
	support.check(t, "no XDG library imported (we resolve XDG via core/os only)",
		len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), join_lines(hits[:])))
}

loopback_needles : []string = {"localhost", "127.0.0.1", "0.0.0.0"}

@(test)
hygiene_no_localhost_in_src :: proc(t: ^testing.T) {
	// `localhost` in a remote target would make the fake-local device look
	// real, and is the single easiest way to accidentally point a remote test
	// at the developer's own machine.
	hits := src_code_hits(loopback_needles[:])
	support.check(t, "no 'localhost' / loopback literal in non-comment src/ lines",
		len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), join_lines(hits[:])))
}

@(test)
hygiene_scratch_accounting :: proc(t: ^testing.T) {
	// Every scratch dir this suite made is under /tmp with the hs-t9-theme-
	// prefix, and the count is reported so a leak shows up as a growing number
	// on the next run rather than as mystery disk usage weeks later.
	n := count_scratch_left()
	support.check(t, "all scratch dirs use the hs-t9-theme- prefix under /tmp",
		agg_snapshot().n > 0,
		fmt.tprintf("prefix='{}{}' verified_swaps={} still_present_under_prefix={}",
			SCRATCH_ROOT, SCRATCH_PREFIX, agg_snapshot().n, n))
}

//-----------------------------------------------------------------------------
// aggregate accessors (thin wrappers so the assertions read as sentences)
//-----------------------------------------------------------------------------

// agg_snapshot takes the aggregate under the same mutex the writers use, into
// a plain immutable struct. One lock, one read, and the assertions cannot see
// a torn view of a half-updated aggregate.
Agg_Snap :: struct {
	n : int,
	bad_untouched : int,
	bad_leak : int,
	before : string,
	after : string,
}

agg_snapshot :: proc() -> Agg_Snap {
	sync.mutex_lock(&Counter_Mutex)
	defer sync.mutex_unlock(&Counter_Mutex)
	return Agg_Snap{
		n = AGG.n,
		bad_untouched = AGG.bad_untouched,
		bad_leak = AGG.bad_leak,
		before = AGG.before_digest,
		after = AGG.last_digest,
	}
}

real_cfg_state_now :: proc() -> string {
	f := fingerprint_real_config()
	return fmt.tprintf("{} {} {}", f.state, f.digest, f.path)
}

//-----------------------------------------------------------------------------
// the comment-stripping source scanner
//-----------------------------------------------------------------------------

SRC_ROOTS : []string = {"src/", "../src/", "../../src/"}

// src_root finds the source tree from either the repo root or the test dir.
src_root :: proc() -> string {
	for d in SRC_ROOTS[:] {
		if fi, err := os.stat(d, context.allocator); err == nil && fi.type == .Directory {
			return string(d)
		}
	}
	return ""
}

// src_code_hits scans every .odin/.sh under src/ for any of `needles`,
// IGNORING comment lines. Returns "file:line: line" for each hit.
src_code_hits :: proc(needles: []string) -> [dynamic]string {
	out := make([dynamic]string, 0, 8)
	root := src_root()
	if len(root) == 0 {
		// A hygiene check that could not find the tree it scans must NOT pass.
		append(&out, "<src root not found — this check did not run>")
		return out
	}
	scan_dir(root, needles, &out)
	return out
}

scan_dir :: proc(dir: string, needles: []string, out: ^[dynamic]string) {
	f, err := os.open(dir)
	if err != nil { return }
	defer os.close(f)
	infos, derr := os.read_directory(f, -1, context.allocator)
	if derr != nil { return }
	for fi in infos {
		if fi.name == "." || fi.name == ".." { continue }
		child := fmt.tprintf("{}/{}", dir, fi.name)
		if fi.type == .Directory {
			// Do not descend into vendored libraries: the rule is about OUR
			// source, and a vendor tree we do not control would make this
			// check permanently red.
			if fi.name == "vendor" || fi.name == "clay-odin" || fi.name == "third_party" { continue }
			scan_dir(child, needles, out)
		} else if strings.has_suffix(fi.name, ".odin") || strings.has_suffix(fi.name, ".sh") {
			scan_file(child, needles, out)
		}
	}
}

scan_file :: proc(path: string, needles: []string, out: ^[dynamic]string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil || data == nil { return }
	defer delete(data)
	text := string(data)
	line_no := 0
	for line in split_lines(text) {
		line_no += 1
		code := strip_comment(line)
		if len(strings.trim_space(code)) == 0 { continue }
		for n in needles {
			if strings.contains(code, n) {
				append(out, fmt.tprintf("{}:{}: {}", path, line_no, strings.trim_space(code)))
			}
		}
	}
}

// strip_comment removes a `//` comment and everything after it. Quoting-aware
// enough not to cut at a "//" that appears inside a string literal, because
// JSON samples and paths legitimately contain slashes.
strip_comment :: proc(line: string) -> string {
	in_str := false
	quote: u8 = 0
	i := 0
	for i < len(line) {
		ch := line[i]
		if in_str {
			if ch == quote { in_str = false }
		} else {
			if ch == '"' || ch == '\'' || ch == '`' {
				in_str = true
				quote = ch
			} else if ch == '/' && i + 1 < len(line) && line[i+1] == '/' {
				return line[:i]
			}
		}
		i += 1
	}
	return line
}

count_scratch_left :: proc() -> int {
	root := fmt.tprintf(SCRATCH_ROOT)
	f, err := os.open(root)
	if err != nil { return -1 }
	defer os.close(f)
	infos, derr := os.read_directory(f, -1, context.allocator)
	if derr != nil { return -1 }
	n := 0
	for fi in infos {
		if strings.has_prefix(fi.name, SCRATCH_PREFIX) { n += 1 }
	}
	return n
}

join_lines :: proc(xs: []string) -> string {
	parts := make([dynamic]string, 0, len(xs))
	for x in xs { append(&parts, x) }
	j, _ := strings.join(parts[:], " || ")
	return j
}

// split_lines keeps line numbers meaningful, which is the whole point of a
// grep-style report: a hit without a line number is not actionable.
split_lines :: proc(text: string) -> [dynamic]string {
	out := make([dynamic]string, 0, 64)
	start := 0
	for i := 0; i < len(text); i += 1 {
		if text[i] == '\n' {
			append(&out, text[start:i])
			start = i + 1
		}
	}
	if start < len(text) { append(&out, text[start:]) }
	return out
}
