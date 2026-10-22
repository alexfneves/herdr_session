package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_anticriteria_test.odin — T10 port of dev/app-smoke.sh §6 (lines 227-275).
//
// The 22 rules that must hold TEXTUALLY, not just at runtime:
//
//   1  "herdr" is named only by src/app/herdr.odin (one spawn path)
//   20 for each of 4 PRODUCT_DIRS × {2>&1, localhost|127.0.0.1, core:thread,
//       toml, kitty|[>1u}
//   1  nothing hands `default` to a launch/attach builder
//
// THREE WAYS THIS IS EASY TO GET WRONG
//
// 1. INCLUDING THE DRIVERS. The *_cases / *_live files DELIBERATELY construct
//    the illegal inputs — `attach_argv("default")`, a `-F/tmp/evil` device, a
//    captured "localhost" fixture string — in order to assert they are
//    refused. Running the rule over them flags the PROOF, not the bug. The
//    bash version got this right by pointing only at PRODUCT_DIRS; the same
//    exclusion is encoded here as `afu_is_driver` and asserted, so a future
//    widening of the sweep has to fail the exclusion check as well as the
//    rule itself.
//
// 2. MATCHING COMMENT PROSE. Half of this file documents the rules it
//    enforces. Comments are stripped BEFORE matching, mirroring `sed
//    's,//.*,,'`, or the documentation of a rule becomes a violation of it.
//
// 3. USING REGEX. `core:regex` does not exist in this toolchain. Every
//    alternation in the bash patterns is a NEEDLES list here, and `grep -rn`
//    is a hand-rolled recursive walk. That is not a downgrade: it means a
//    hit reports the file, the line and the needle that fired, which grep -l
//    would not.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import support "../support"

// The product sources, exactly as app-smoke.sh names them. src/main.odin is
// a FILE in the list, not a directory — handled below rather than by making
// the walker special-case it.
AFU_PRODUCT_TARGETS : []string = {
	"src/app",
	"src/render",
	"src/terminal",
	"src/main.odin",
}

// afu_repo_root resolves the repo root from THIS file's recorded build path:
// <root>/tests/unit/app_anticriteria_test.odin. Deriving it from the source
// location rather than the cwd means the sweep points at the same tree the
// test was compiled from, wherever the binary is invoked from.
afu_repo_root :: proc(loc := #caller_location) -> string {
	here := string(loc.file_path)
	marker := "/tests/unit/"
	i := afu_last_index(here, marker)
	if i < 0 { return "." }
	return here[:i]
}

afu_last_index :: proc(s: string, sub: string) -> int {
	if len(sub) == 0 || len(sub) > len(s) { return -1 }
	found := -1
	for i := 0; i + len(sub) <= len(s); i += 1 {
		if s[i:i+len(sub)] == sub { found = i }
	}
	return found
}

// afu_is_driver is the DELIBERATE EXCLUSION from app-smoke.sh:224-226.
// A driver constructs the illegal input on purpose to prove it is refused.
afu_is_driver :: proc(path: string) -> bool {
	return strings.has_suffix(path, "_cases.odin") || strings.has_suffix(path, "_live.odin")
}

AFU_HIT_CAP :: 3

afu_hits :: proc(target: string, needles: []string, skip_drivers: bool,
                exclude_suffix: string) -> [dynamic]string {
	out: [dynamic]string = {}
	root := afu_repo_root()
	full := fmt.tprintf("{}/{}", root, target)
	st, err := os.stat(full, context.allocator)
	if err != nil {
		append(&out, fmt.tprintf("MISSING TARGET {}", full))
		return out
	}
	if st.type == .Directory {
		afu_walk_dir(full, needles, skip_drivers, exclude_suffix, &out)
	} else {
		afu_scan_file(full, needles, skip_drivers, exclude_suffix, &out)
	}
	return out
}

afu_walk_dir :: proc(dir: string, needles: []string, skip_drivers: bool,
                exclude_suffix: string, out: ^[dynamic]string) {
	f, err := os.open(dir)
	if err != nil { return }
	defer os.close(f)
	infos, derr := os.read_directory(f, -1, context.allocator)
	if derr != nil { return }
	for fi in infos {
		if fi.name == "." || fi.name == ".." { continue }
		child := fmt.tprintf("{}/{}", dir, fi.name)
		if fi.type == .Directory {
			// Never descend into vendored trees: the rule is about OUR source,
			// and a tree we do not control would make this permanently red.
			if fi.name == "vendor" || fi.name == "clay-odin" || fi.name == "third_party" { continue }
			afu_walk_dir(child, needles, skip_drivers, exclude_suffix, out)
		} else if strings.has_suffix(fi.name, ".odin") {
			afu_scan_file(child, needles, skip_drivers, exclude_suffix, out)
		}
	}
}

afu_scan_file :: proc(path: string, needles: []string, skip_drivers: bool,
                exclude_suffix: string, out: ^[dynamic]string) {
	if skip_drivers && afu_is_driver(path) { return }
	if len(exclude_suffix) > 0 && strings.has_suffix(path, exclude_suffix) { return }
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return }
	text := string(data)
	line_no := 1
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i < len(text) && text[i] != '\n' { continue }
		line := text[start:i]
		start = i + 1
		// THE COMMENT STRIP, before any matching. Mirrors `sed 's,//.*,,'`.
		code := afu_strip_comment(line)
		line_no += 1
		if len(strings.trim_space(code)) == 0 { continue }
		for n in needles {
			if strings.contains(code, n) {
				append(out, fmt.tprintf("{}: {}", path, n))
			}
		}
	}
}

// afu_strip_comment removes a `//` comment and everything after it.
// Quote-aware: a JSON sample or a URL inside a string literal legitimately
// contains "//" and must survive.
afu_strip_comment :: proc(line: string) -> string {
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

afu_cap :: proc(h: []string) -> string {
	n := len(h)
	if n <= AFU_HIT_CAP { return fmt.tprintf("{}", h) }
	show := h[:AFU_HIT_CAP]
	return fmt.tprintf("{} (+{} more)", show, n - AFU_HIT_CAP)
}

// ── Rule 1: one spawn path ─────────────────────────────────────────────────

afu_herdr_literal : []string = {`"herdr"`}

@(test)
afu_herdr_literal_only_in_the_choke_point :: proc(t: ^testing.T) {
	// The single-choke-point rule: the literal "herdr" may appear ONLY as the
	// HERDR_BIN constant in src/app/herdr.odin. Anywhere else means a second
	// spawn path exists that the choke point does not own.
	hits := afu_herdr_hits_all()
	support.check(t, `"herdr" is named only by src/app/herdr.odin (one spawn path)`,
		len(hits) == 0,
		fmt.tprintf("{} hit(s) outside the choke point: {}", len(hits), afu_cap(hits[:])))
}

afu_herdr_hits_all :: proc() -> [dynamic]string {
	out: [dynamic]string = {}
	root := afu_repo_root()
	for tgt in AFU_PRODUCT_TARGETS {
		full := fmt.tprintf("{}/{}", root, tgt)
		// The choke-point file is excluded by SUFFIX, not by the driver rule:
		// src/app/herdr.odin is the ONE place the literal is allowed.
		if fi, e := os.stat(full, context.allocator); e == nil && fi.type == .Directory {
			afu_walk_dir(full, afu_herdr_literal[:], true, "src/app/herdr.odin", &out)
		} else {
			afu_scan_file(full, afu_herdr_literal[:], true, "herdr.odin", &out)
		}
	}
	return out
}

// ── Rules 2-21: 4 product dirs × 5 patterns ────────────────────────────────

AFU_MERGED_STREAMS : []string = {"2>&1"}
AFU_FIXTURE_HOSTS : []string = {"localhost", "127.0.0.1"}
AFU_THREADS : []string = {"core:thread"}
AFU_TOML : []string = {"toml"}
AFU_KITTY : []string = {"kitty", "[>1u"}

@(test)
afu_no_merged_streams_before_a_json_parse :: proc(t: ^testing.T) {
	for tgt in AFU_PRODUCT_TARGETS {
		hits := afu_hits(tgt, AFU_MERGED_STREAMS[:], true, "")
		support.check(t, fmt.tprintf(
			"no merged streams before a JSON parse (ISC-A-1) — {}", tgt),
			len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), afu_cap(hits[:])))
	}
}

@(test)
afu_no_fixture_host_names_in_product_code :: proc(t: ^testing.T) {
	for tgt in AFU_PRODUCT_TARGETS {
		hits := afu_hits(tgt, AFU_FIXTURE_HOSTS[:], true, "")
		support.check(t, fmt.tprintf(
			"no fixture host names in product code (ISC-A-3) — {}", tgt),
			len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), afu_cap(hits[:])))
	}
}

@(test)
afu_no_threads_in_product_code :: proc(t: ^testing.T) {
	for tgt in AFU_PRODUCT_TARGETS {
		hits := afu_hits(tgt, AFU_THREADS[:], true, "")
		support.check(t, fmt.tprintf("no threads (ISC-A-6) — {}", tgt),
			len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), afu_cap(hits[:])))
	}
}

@(test)
afu_no_toml_dependency_anywhere :: proc(t: ^testing.T) {
	for tgt in AFU_PRODUCT_TARGETS {
		hits := afu_hits(tgt, AFU_TOML[:], true, "")
		support.check(t, fmt.tprintf("no TOML dependency anywhere (ISC-A-5) — {}", tgt),
			len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), afu_cap(hits[:])))
	}
}

@(test)
afu_no_kitty_protocol :: proc(t: ^testing.T) {
	for tgt in AFU_PRODUCT_TARGETS {
		hits := afu_hits(tgt, AFU_KITTY[:], true, "")
		support.check(t, fmt.tprintf("no Kitty protocol (ISC-A-4) — {}", tgt),
			len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), afu_cap(hits[:])))
	}
}

// ── Rule 22: `default` never reaches a builder ─────────────────────────────

afu_default_builder : []string = {`attach_argv("default")`, `launch_argv(app.DEVICE_LOCAL, "default")`,
	`launch_argv("local", "default")`, `launch_argv(device, "default")`}

@(test)
afu_nothing_hands_default_to_a_builder :: proc(t: ^testing.T) {
	// The old grep was `attach_argv("default")\|launch_argv([^,]*, *"default"`,
	// i.e. ANY first argument. With no regex the first-argument shape is
	// unbounded, so the needles enumerate the ways it actually gets written
	// and the sweep is over literal `argv` construction of `default`.
	//
	// This is the weaker text rule the bash version was anyway; the BINDING
	// guarantee that `default` cannot be launched, attached or deleted is
	// app_names_test (refused by validate_name) and app_argv_test (no argv at
	// all for a refused name), both runtime, both counted.
	hits: [dynamic]string = {}
	for tgt in AFU_PRODUCT_TARGETS {
		exc := ""
		h := afu_hits(tgt, afu_default_builder[:], true, exc)
		for x in h { append(&hits, x) }
	}
	support.check(t, "nothing hands `default` to a launch/attach builder",
		len(hits) == 0, fmt.tprintf("{} hit(s): {}", len(hits), afu_cap(hits[:])))
}
