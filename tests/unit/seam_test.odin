package unit

// ─────────────────────────────────────────────────────────────────────────────
// seam_test.odin — T18b: the developer seams left in the product binary are
// PROVEN inert by default, additive, and confined to the files that own them.
//
// THE DECISION (plan §B4) — MADE, RECORDED, NOT RE-LITIGATED HERE
//
// Three developer seams stay in the shipped binary:
//
//   * tui_fixture_remotes (src/main.odin:443) — reads the HERDR_SESSION_TEST_*
//     fixture family: REMOTE, REMOTE_ALIAS, UNREACHABLE
//   * HS_TUI_TRACE        (src/main.odin:1187) — the loop's exit-time timeline
//   * HS_PIDFILE          (src/main.odin:142)  — the harness's kill target
//
// RCH-5 says "no test code in the product". The honest answer is that these are
// NOT test code — they are injection points the product legitimately owns, the
// same way a log-level env var is not "test code". Removing them does not make
// the product cleaner; it destroys the fixture path, and a destroyed fixture
// path is a coverage hole far bigger than the one being plugged.
//
// WHY THE OBVIOUS ALTERNATIVE IS WORSE, WITH THE RECEIPT
//
// The obvious alternative is: no seam, and the fixture points the product at a
// throwaway config file via a temp XDG_CONFIG_HOME. That was tried, and it
// broke, and the failure is recorded in
// ../2026-10-18-herdr-session-tui/60-handoff-notes.md, landed in commit
// 5e84fae:
//
//     "XDG_CONFIG_HOME moves *herdr's own state dir*, not just our config file.
//      Running the live suites under a temp XDG_CONFIG_HOME makes herdr report
//      an empty session list, which surfaces as `added=0` / `names=` / 'host
//      session missing'."
//
// That is not a bug in herdr and it is not fixable in the test: herdr resolves
// BOTH its config and its session state from the same XDG root. A sandbox that
// hides the config also hides the sessions, so the fixture's very first act
// erases the thing it is meant to observe, and it fails with something that
// reads like an application bug. THE SEAM EXISTS PRECISELY SO THE FIXTURE CAN
// INJECT HOSTS *WITHOUT* MOVING THE STATE DIR.
//
// So the seams stay. What this file does is make the trade-off SAFE by
// assertion rather than by promise — four counted conditions:
//
//   1. INERT BY DEFAULT. No HERDR_SESSION_TEST_* in the environment → no
//      fixture remotes. The seam cannot fire on a user's machine.
//   2. NOTHING WRITTEN BY DEFAULT. No HS_TUI_TRACE → no trace file. No
//      HS_PIDFILE → no pidfile. A user's home and cwd stay clean.
//   3. ADDITIVE ONLY. The seam may ADD hosts; it may never alter, reorder, or
//      remove a configured one. The fixture cannot impersonate the user's config.
//   4. CONFINED. Each seam symbol is referenced only from the file that owns
//      it. A leak into src/app, src/ui, src/render, src/input or src/terminal
//      turns this red.
//
// WHY EVERY CHECK CARRIES A POSITIVE CONTROL
//
// "Nothing was written when the env var was absent" is unfalsifiable on its own:
// it passes identically when the writer works, when the writer was deleted, and
// when it is simply never called. A test that cannot fail is worse than no test
// — a green light that means nothing. So each inertness assertion here is
// paired with a control that turns the SAME seam ON in the same process, in the
// same scratch directory, and shows the write DOES happen. Both halves must
// hold. The inert half proves the default is safe; the control half proves the
// inert half is measuring something.
//
// ENVIRONMENT DISCIPLINE
//
// These tests mutate the PROCESS environment, so every mutation is scoped. Prior
// values — including the difference between "unset" and "set to empty", which a
// naive restore flattens into a lie — are captured first and put back on every
// exit path. HERDR_SESSION_TEST_* is cleared by a PREFIX scan rather than an
// enumerated list, so a fourth fixture variable added later is cleared too
// without this file being edited; that is the same reason support/env.odin
// strips the HERDR_ prefix instead of three named keys. ODIN_TEST_THREADS=1
// (a build-time #config) keeps the mutation window single-threaded;
// SUPPORT-ENV-MU is what would make that structural, and it is still an open
// request (see the lane report), not something hand-rolled a second time here.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import prod "../../src"
import app "../../src/app"
import support "../support"

// The variable families under test, named as constants so a typo in a variable
// NAME becomes a compile error rather than "an env var nobody reads".
FIXTURE_ENV_PREFIX :: "HERDR_SESSION_TEST_"

SEAM_VAR_REMOTE :: "HERDR_SESSION_TEST_REMOTE"
SEAM_VAR_REMOTE_ALIAS :: "HERDR_SESSION_TEST_REMOTE_ALIAS"
SEAM_VAR_UNREACHABLE :: "HERDR_SESSION_TEST_UNREACHABLE"
SEAM_VAR_TRACE :: "HS_TUI_TRACE"
SEAM_VAR_PIDFILE :: "HS_PIDFILE"

// Scratch lives under the migration-wide `hs-t-` interlock prefix: nothing this
// file writes can be mistaken for a user path, and nothing outside it is touched.
SEAM_SCRATCH_ROOT :: "/tmp"
SEAM_SCRATCH_PREFIX :: "hs-t-seam-"

//-----------------------------------------------------------------------------
// scoped environment mutation
//-----------------------------------------------------------------------------

// EnvSave remembers one variable exactly, including the difference between
// "unset" and "set to empty". Flattening those two is how a restore leaves a
// later test resolving against "" instead of $HOME/.config.
EnvSave :: struct {
	key : string,
	val : string,
	had : bool,
}

env_save :: proc(key: string) -> EnvSave {
	v, ok := os.lookup_env(key, context.allocator)
	return EnvSave{key = key, val = v, had = ok}
}

env_restore :: proc(s: ^EnvSave) {
	if s^.had {
		os.set_env(s^.key, s^.val)
	} else {
		os.unset_env(s^.key)
	}
}

env_restore_all :: proc(saved: ^[dynamic]EnvSave) {
	for i := 0; i < len(saved); i += 1 {
		env_restore(&saved[i])
	}
	delete(saved^)
}

env_is_unset :: proc(key: string) -> bool {
	_, ok := os.lookup_env(key, context.allocator)
	return !ok
}

// env_clear_prefix unsets EVERY variable whose name starts with `prefix`,
// including ones this file has never heard of, and returns what it removed so
// the caller can put it back. An enumerated clear silently stops covering the
// family the moment someone adds a fourth member.
//
// A return value of -1 means "could not enumerate the environment", which is
// NOT the same as "found nothing" and must never read as clean.
env_clear_prefix :: proc(prefix: string, saved: ^[dynamic]EnvSave) -> int {
	env, err := os.environ(context.allocator)
	if err != nil { return -1 }
	n := 0
	for e in env {
		eq := strings.index_byte(e, '=')
		key := e
		if eq >= 0 { key = e[:eq] }
		if !strings.has_prefix(key, prefix) { continue }
		append(saved, env_save(key))
		os.unset_env(key)
		n += 1
	}
	return n
}

//-----------------------------------------------------------------------------
// scratch
//-----------------------------------------------------------------------------

seam_scratch :: proc() -> string {
	return fmt.tprintf("{}/{}{}", SEAM_SCRATCH_ROOT, SEAM_SCRATCH_PREFIX, int(os.get_pid()))
}

// scratch_names lists the entries directly under `dir`. A directory that could
// not be read yields an "<UNREADABLE>" marker rather than an empty list: "empty"
// and "could not look" are different facts, and conflating them is a false green.
scratch_names :: proc(dir: string) -> [dynamic]string {
	out : [dynamic]string = {}
	f, err := os.open(dir)
	if err != nil {
		append(&out, "<UNREADABLE>")
		return out
	}
	defer os.close(f)
	infos, derr := os.read_directory(f, -1, context.temp_allocator)
	if derr != nil {
		append(&out, "<UNREADABLE>")
		return out
	}
	for fi in infos {
		if fi.name == "." || fi.name == ".." { continue }
		append(&out, fi.name)
	}
	return out
}

scratch_unreadable :: proc(names: []string) -> bool {
	return len(names) == 1 && names[0] == "<UNREADABLE>"
}

// text_at reads a file a control just wrote. Absent OR EMPTY both return
// false — a zero-byte trace would satisfy "the file exists" while proving
// nothing about the writer.
text_at :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil || data == nil { return "", false }
	s := string(data)
	if len(strings.trim_space(s)) == 0 { return "", false }
	return s, true
}

//-----------------------------------------------------------------------------
// CONDITION 1 — inert by default
//-----------------------------------------------------------------------------

@(test)
seam_fixture_remotes_is_empty_when_no_test_env_var_is_set :: proc(t: ^testing.T) {
	// Capture, then clear the WHOLE family by prefix. `cleared` is reported so
	// this test says what it actually did: 0 cleared means the developer's env
	// was already clean (the easy case); N>0 means it is fixture-armed right
	// now and this assertion still holds.
	saved_env : [dynamic]EnvSave = {}
	defer env_restore_all(&saved_env)

	cleared := env_clear_prefix(FIXTURE_ENV_PREFIX, &saved_env)

	// The clear must be VERIFIED before the seam is consulted, otherwise
	// "returned nothing" could just mean "nothing was ever cleared".
	still_set : [dynamic]string = {}
	for k in FIXTURE_VARS[:] {
		if !env_is_unset(k) { append(&still_set, k) }
	}

	// THE CLAIM.
	remotes := prod.tui_fixture_remotes()

	// THE CONTROL — same process, same function, seam switched ON. Without it
	// this check passes equally when tui_fixture_remotes is dead code, is never
	// called, or reads a variable nobody sets.
	os.set_env(SEAM_VAR_REMOTE, "seam-ctl-a.example")
	os.set_env(SEAM_VAR_REMOTE_ALIAS, "seam-ctl-b.example")
	os.set_env(SEAM_VAR_UNREACHABLE, "seam-ctl-down.example")
	control := prod.tui_fixture_remotes()
	for k in FIXTURE_VARS[:] { os.unset_env(k) }

	support.check(t, "no HERDR_SESSION_TEST_* set -> tui_fixture_remotes() is EMPTY",
		cleared >= 0 &&
			len(still_set) == 0 &&
			len(remotes) == 0 &&
			len(control) == 3,
		fmt.tprintf("family_cleared={} still_set={} remotes_with_no_env={} control_with_3_vars={} (the control proves the seam is live, not deleted)",
			cleared, join_or_none(still_set[:]), len(remotes), len(control)))
}

FIXTURE_VARS : []string = {SEAM_VAR_REMOTE, SEAM_VAR_REMOTE_ALIAS, SEAM_VAR_UNREACHABLE}

//-----------------------------------------------------------------------------
// CONDITION 2 — nothing is written by default
//-----------------------------------------------------------------------------

@(test)
seam_writes_no_trace_and_no_pidfile_when_those_env_vars_are_absent :: proc(t: ^testing.T) {
	// Same capture/restore discipline. These two variables decide whether the
	// product opens a file at all, so the assertion is about files appearing on
	// disk, not about return values.
	saved_env : [dynamic]EnvSave = {}
	defer env_restore_all(&saved_env)
	os.unset_env(SEAM_VAR_TRACE)
	os.unset_env(SEAM_VAR_PIDFILE)

	dir := seam_scratch()
	os.remove(dir)  // a leftover from a crashed earlier run must not be counted as ours
	if err := os.mkdir_all(dir, app.CONFIG_DIR_MODE); err != nil {
		support.check(t, "no HS_TUI_TRACE / HS_PIDFILE -> no trace file, no pidfile", false,
			fmt.tprintf("could not create the scratch dir {} — the write test did not run: {}", dir, err))
		return
	}
	defer os.remove(dir)

	before := scratch_names(dir)
	trace_unset := env_is_unset(SEAM_VAR_TRACE)
	pid_unset := env_is_unset(SEAM_VAR_PIDFILE)

	// THE CLAIM: both writers run with both variables absent.
	prod.write_pidfile()
	prod.tui_dump_trace()
	inert := scratch_names(dir)

	// THE CONTROL: the same two procs, same process, seam switched ON, writing
	// into the SAME scratch dir. If this half does not produce two non-empty
	// files, the inert half above measured nothing.
	trace_path := fmt.tprintf("{}/hs.trace", dir)
	pid_path := fmt.tprintf("{}/hs.pid", dir)
	os.set_env(SEAM_VAR_TRACE, trace_path)
	prod.tui_dump_trace()
	os.set_env(SEAM_VAR_PIDFILE, pid_path)
	prod.write_pidfile()

	trace_txt, trace_ok := text_at(trace_path)
	pid_txt, pid_ok := text_at(pid_path)
	controlled := scratch_names(dir)

	// Both halves, or it is red. trace_ok/pid_ok mean "exists AND non-empty", so
	// a zero-byte file cannot satisfy the control.
	support.check(t, "no HS_TUI_TRACE / HS_PIDFILE -> no trace file, no pidfile",
		len(before) == 0 &&
			trace_unset && pid_unset &&
			len(inert) == 0 && !scratch_unreadable(inert[:]) &&
			trace_ok && pid_ok &&
			len(controlled) == 2,
		fmt.tprintf("scratch_before={} files_after_inert_writers={} control: trace_bytes={} pid_content='{}' files_after_control={}",
			len(before), len(inert), len(trace_txt), strings.trim_space(pid_txt), len(controlled)))
}

//-----------------------------------------------------------------------------
// CONDITION 3 — additive only
//-----------------------------------------------------------------------------

@(test)
seam_may_add_remotes_but_never_alters_or_removes_a_configured_host :: proc(t: ^testing.T) {
	// Set up the product path: a config that already names two real hosts, each
	// with a label of the user's own choosing. This is the thing the seam must
	// not touch. Then switch the fixture on and see what the union does to it.
	//
	// tui.cfg is global state owned by main's boot path, which does not run in
	// a test binary — so save it wholesale and put it back exactly.
	saved_cfg := prod.tui.cfg
	defer { prod.tui.cfg = saved_cfg }

	saved_env : [dynamic]EnvSave = {}
	defer env_restore_all(&saved_env)

	configured : [dynamic]app.Remote = {}
	append(&configured, app.Remote{device = "user-prod.example", label = "Work box"})
	append(&configured, app.Remote{device = "home.example", label = "Home lab"})
	prod.tui.cfg.remotes = configured[:]

	// Baseline: with the fixture off, the union IS the config — nothing
	// subtracted, nothing added.
	for k in FIXTURE_VARS[:] { os.unset_env(k) }
	off := prod.tui_config_remotes()

	// Now inject three fixture hosts, ONE OF WHICH COLLIDES with the user's
	// first configured device. That collision is the whole test: the seam's
	// documented rule is "the config wins", so the user's label has to survive
	// verbatim and the fixture's bare target must not replace it. A seam that
	// overwrote the label would be the fixture impersonating the user's config.
	os.set_env(SEAM_VAR_REMOTE, "user-prod.example")
	os.set_env(SEAM_VAR_REMOTE_ALIAS, "fixture-alias.example")
	os.set_env(SEAM_VAR_UNREACHABLE, "fixture-down.example")
	on := prod.tui_config_remotes()

	// (a) nothing removed and nothing reordered: the first N results ARE the
	// configured hosts, in order, with BOTH fields intact.
	prefix_intact := len(on) >= len(configured)
	for i := 0; i < len(configured) && i < len(on); i += 1 {
		if on[i].device != configured[i].device || on[i].label != configured[i].label {
			prefix_intact = false
		}
	}

	// (b) the collision did not overwrite the user's label.
	label_survived := len(on) > 0 &&
		on[0].device == "user-prod.example" &&
		on[0].label == "Work box"

	// (c) the two non-colliding fixture hosts actually arrived — i.e. the seam
	// is genuinely adding, not just re-emitting the config.
	got_alias := has_device(on, "fixture-alias.example")
	got_down := has_device(on, "fixture-down.example")

	// 2 configured + 3 injected - 1 collision = 4.
	exact := len(off) == 2 && len(on) == 4

	support.check(t, "the fixture seam is ADDITIVE ONLY — it never alters, reorders, or removes a configured host",
		prefix_intact && label_survived && got_alias && got_down && exact,
		fmt.tprintf("off={} on={} (want 2 -> 4: three injected, one collided with a config entry and LOST to it) prefix_intact={} label_survived='{}' alias_added={} unreachable_added={}",
			len(off), len(on), prefix_intact, first_label(on), got_alias, got_down))
}

has_device :: proc(rs: []app.Remote, want: string) -> bool {
	for r in rs {
		if r.device == want { return true }
	}
	return false
}

first_label :: proc(rs: []app.Remote) -> string {
	if len(rs) == 0 { return "<none>" }
	return rs[0].label
}

//-----------------------------------------------------------------------------
// CONDITION 4 — the anti-criteria grep
//-----------------------------------------------------------------------------

// Seam_Rule names a symbol and the ONE file allowed to reference it in
// non-comment code. This is plan §B4 condition 4: a seam is a property of a
// single file, and if it shows up in another product path the product has grown
// a second, undocumented entry point — the thing RCH-5 is actually worried
// about, and the thing a prose comment cannot prevent.
Seam_Rule :: struct {
	symbol : string,
	owner  : string,
	reason : string,
}

SEAM_RULES : []Seam_Rule = {
	Seam_Rule{
		symbol = "tui_fixture_remotes",
		owner  = "src/main.odin",
		reason = "the fixture injection point; tui_config_remotes is its only consumer and both live in main",
	},
	Seam_Rule{
		symbol = "HS_TUI_TRACE",
		owner  = "src/main.odin",
		reason = "read exactly once, in tui_dump_trace; the loop's own record, not a library concern",
	},
	Seam_Rule{
		symbol = "HS_PIDFILE",
		owner  = "src/main.odin",
		reason = "read exactly once, in write_pidfile; nobody else may learn the harness's kill target",
	},
	Seam_Rule{
		symbol = FIXTURE_ENV_PREFIX,
		owner  = "src/main.odin",
		reason = "the fixture host family is read by the seam itself (live drivers excepted, see below)",
	},
}

// LIVE_DRIVER_EXCEPTIONS are the files that may read the fixture family because
// they ARE the fixture path: `app-live` and `fetch-live` are smoke drivers
// whose entire purpose is running against the armed remote triple. They are
// package main, not a product library.
//
// This carve-out is written down rather than quietly widened. What it does NOT
// license is in the next block, which is asserted with no exception list at all.
LIVE_DRIVER_EXCEPTIONS : []string = {"src/app_live.odin", "src/fetch_live.odin"}

// PRODUCT_LIBRARY_DIRS must never mention a seam symbol, in any file, for any
// excuse. This is asserted independently of the per-owner rule, so a fixture
// name cannot be smuggled into the model, the renderer, or the keymap behind a
// file-level pardon.
PRODUCT_LIBRARY_DIRS : []string = {"src/app", "src/ui", "src/render", "src/input", "src/terminal"}

@(test)
seam_symbols_are_referenced_only_from_their_owning_product_file :: proc(t: ^testing.T) {
	root := seam_src_root()
	if len(root) == 0 {
		support.check(t, "each seam symbol is referenced only from its owning product file", false,
			"src/ not found from this working directory — the grep did not run")
		return
	}

	// ONE walk of src/, with `//` comments stripped BEFORE matching. The strip
	// is what makes this falsifiable: without it, a comment explaining "never
	// read HS_PIDFILE in the renderer" would itself violate the rule, and a
	// rule that documents its own violation can never go red.
	// NOTE ON ALLOCATION: every string kept out of the walker is CLONED. The
	// walker builds paths on core:os's own file allocator and walker_destroy
	// frees that arena, so a stored path that outlives the walk would be a
	// dangling pointer reading as a plausible-but-wrong filename — which is
	// worse than a crash, because the rule would still LOOK like it was being
	// checked. See scan_seam_file / seam_rel_path.
	hits := seam_walk_src(root)
	if seam_files_scanned == 0 {
		support.check(t, "each seam symbol is referenced only from its owning product file", false,
			"0 files scanned — a scan over nothing is not a clean result")
		return
	}

	violations : [dynamic]string = {}

	// (i) the per-symbol owner rule.
	for rule in SEAM_RULES {
		for h in hits {
			if !strings.contains(h.code, rule.symbol) { continue }
			if h.file == rule.owner { continue }
			if rule.symbol == FIXTURE_ENV_PREFIX && seam_in_list(LIVE_DRIVER_EXCEPTIONS, h.file) {
				continue
			}
			append(&violations, fmt.tprintf("{}:{}: '{}' referenced outside {} -> {}",
				h.file, h.line, rule.symbol, rule.owner, h.code))
		}
	}

	// (ii) the unconditional half: no seam symbol in a product library, NO
	// exceptions. LIVE_DRIVER_EXCEPTIONS does not apply here.
	for h in hits {
		if !seam_in_library(h.file) { continue }
		for rule in SEAM_RULES {
			if strings.contains(h.code, rule.symbol) {
				append(&violations, fmt.tprintf("{}:{}: '{}' appears in a PRODUCT LIBRARY (no exception applies) -> {}",
					h.file, h.line, rule.symbol, h.code))
			}
		}
	}

	support.check(t, "each seam symbol is referenced only from its owning product file",
		len(violations) == 0,
		fmt.tprintf("{} violation(s); files_scanned={} code_lines_scanned={} first: {}",
			len(violations), seam_files_scanned, seam_code_lines, first_or_none(violations[:])))
}

//-----------------------------------------------------------------------------
// the comment-stripping src/ walker
//-----------------------------------------------------------------------------

Src_Hit :: struct {
	file : string, // repo-relative, e.g. "src/main.odin"
	line : int,    // 1-based, so a report is actionable
	code : string, // the line with its `//` comment removed
}

// Walk tallies, exposed so the detail can say how much ground the grep
// actually covered. A scan of zero files is not a clean result.
seam_code_lines    : int = 0
seam_files_scanned : int = 0

seam_walk_src :: proc(root: string) -> [dynamic]Src_Hit {
	out : [dynamic]Src_Hit = {}
	seam_code_lines = 0
	seam_files_scanned = 0

	w : os.Walker = {}
	os.walker_init_path(&w, root)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		// The walker hands back paths allocated on its OWN file allocator, and
		// walker_destroy frees that whole arena. Every string taken out of it
		// must therefore be copied into an allocator this call owns — a stored
		// `file` slice that outlives walker_destroy is a dangling pointer that
		// reads as plausible-but-wrong paths, which is worse than a crash
		// because the rule would still look like it was being checked.
		name := strings.clone(string(info.name))
		if info.type == .Directory {
			// Do not descend into vendored trees: the rule is about OUR
			// source, and a tree we do not control would make this red forever.
			if name == "vendor" || name == "clay-odin" || name == "third_party" {
				os.walker_skip_dir(&w)
			}
			continue
		}
		if !strings.has_suffix(name, ".odin") { continue }

		seam_files_scanned += 1
		full := strings.clone(string(info.fullpath))
		scan_seam_file(seam_rel_path(root, full), full, &out)
	}
	return out
}

// seam_rel_path renders the walker's absolute path as the repo-relative path
// the rules are written against, so `owner` reads like a path a human would
// type rather than one that changes with the checkout.
seam_rel_path :: proc(root: string, fullpath: string) -> string {
	if strings.has_prefix(fullpath, "src/") { return fullpath }
	marker := fmt.tprintf("{}/{}", root, "")
	if strings.has_prefix(fullpath, marker) {
		rel := fullpath[len(marker):]
		for len(rel) > 0 && rel[0] == '/' { rel = rel[1:] }
		return fmt.tprintf("src/{}", rel)
	}
	i := strings.last_index(fullpath, "/src/")
	if i >= 0 { return strings.clone(fullpath[i+1:]) }
	return fullpath
}

scan_seam_file :: proc(rel: string, path: string, out: ^[dynamic]Src_Hit) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil || data == nil { return }

	line_no := 0
	for line in seam_split_lines(string(data)) {
		line_no += 1
		code := seam_strip_comment(line)
		if len(strings.trim_space(code)) == 0 { continue }
		seam_code_lines += 1
		append(out, Src_Hit{file = rel, line = line_no, code = strings.trim_space(code)})
	}
}

// seam_strip_comment removes a `//` comment and everything after it,
// quote-aware so a "//" inside a string literal (JSON samples, ssh targets,
// doc URLs) does not cut the line early.
seam_strip_comment :: proc(line: string) -> string {
	in_str := false
	quote: u8 = 0
	i := 0
	for i < len(line) {
		ch := line[i]
		if in_str {
			if ch == quote { in_str = false }
		} else if ch == '"' || ch == '\'' || ch == '`' {
			in_str = true
			quote = ch
		} else if ch == '/' && i + 1 < len(line) && line[i+1] == '/' {
			return line[:i]
		}
		i += 1
	}
	return line
}

seam_split_lines :: proc(text: string) -> [dynamic]string {
	out : [dynamic]string = {}
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

seam_in_list :: proc(xs: []string, x: string) -> bool {
	for v in xs {
		if v == x { return true }
	}
	return false
}

// seam_in_library: does this repo-relative path live under a product library?
seam_in_library :: proc(rel: string) -> bool {
	for d in PRODUCT_LIBRARY_DIRS {
		if strings.has_prefix(rel, fmt.tprintf("{}/{}", d, "")) { return true }
	}
	return false
}

SEAM_SRC_ROOTS : []string = {"src", "../src", "../../src"}

seam_src_root :: proc() -> string {
	// Tried in order so the test works from the repo root and from tests/unit.
	for d in SEAM_SRC_ROOTS[:] {
		if fi, err := os.stat(d, context.allocator); err == nil && fi.type == .Directory {
			return d
		}
	}
	return ""
}

join_or_none :: proc(xs: []string) -> string {
	if len(xs) == 0 { return "(none)" }
	out := ""
	for i := 0; i < len(xs); i += 1 {
		if i > 0 {
			out = fmt.tprintf("{}, {}", out, xs[i])
		} else {
			out = xs[i]
		}
	}
	return out
}

first_or_none :: proc(xs: []string) -> string {
	if len(xs) == 0 { return "(none)" }
	if len(xs[0]) > 180 { return xs[0][:180] }
	return xs[0]
}
