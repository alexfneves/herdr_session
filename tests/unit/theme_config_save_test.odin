package unit

// theme_config_save_test.odin — T9 port of the `config-save` case.
//
// Source: src/theme_cases.odin `case_config_save` (27 counted assertions).
// Everything is written under a THROWAWAY XDG_CONFIG_HOME (or, here, an explicit
// temp path), so the developer's real ~/.config/herdr_session.json is never in
// the path of a write. The whole-suite real-config proof lives in
// theme_hygiene_test.odin; this file's job is the merge rule.
//
// THE LOAD-BEARING PROOF IS B: HAND-ADDED KEYS SURVIVE A SAVE. A save is a
// read-modify-write of the parsed document, not a marshal of our own struct.
// `json.Object` IS the parsed document, so marshalling it back carries every key
// we do not understand. If a future refactor wrote `Config` out directly instead
// of merging, this is the test that eats it — and it eats it loudly, on a key
// the app has never heard of, which is precisely the key that would be lost.
//
// ASSERT ON THE BYTES, NOT THE RETURN VALUE. Every one of the silent
// key-eating bugs this project found returned `true`. The file contents are the
// ground truth; `ok` is only whether the write syscall was happy.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

// The hand-edited document the merge proofs are run against. ONE copy, because
// four near-identical literals in four tests is four things that can drift
// apart, and the drift shows up as a merge bug that is really a fixture typo.
HAND_EDITED :: `{
  "hand_added_note": "do not eat this",
  "theme": "catppuccin-latte",
  "future_key": {"nested": [1, 2, 3]},
  "remotes": ["my-host"]
}`

@(test)
config_save_into_a_missing_file_creates_it :: proc(t: ^testing.T) {
	dir := new_scratch(t, "save-a")
	defer delete_tree(dir)
	path := cfg_file(dir)

	ok1, err1 := app.config_save_theme(path, "catppuccin-latte")
	support.check(t, "save into a missing file succeeds", ok1, fmt.tprintf("err='{}'", err1))
	body_a := read_cfg(dir)
	support.check(t, "…the file now holds the theme",
		strings.contains(body_a, `"theme": "catppuccin-latte"`), body_a)
}

@(test)
config_save_preserves_hand_added_keys :: proc(t: ^testing.T) {
	dir := new_scratch(t, "save-b")
	defer delete_tree(dir)
	path := cfg_file(dir)

	hand := HAND_EDITED
	write_cfg_text(t, path, hand)

	ok2, err2 := app.config_save_theme(path, "nord")
	body_b := read_cfg(dir)
	support.check(t, "save over a hand-edited file succeeds", ok2, fmt.tprintf("err='{}'", err2))
	support.check(t, "…the new theme was written",
		strings.contains(body_b, `"theme": "nord"`), body_b)
	support.check(t, "…the hand-added STRING key SURVIVED",
		strings.contains(body_b, "hand_added_note") &&
		strings.contains(body_b, "do not eat this"), body_b)
	support.check(t, "…the hand-added NESTED OBJECT survived",
		strings.contains(body_b, "future_key") && strings.contains(body_b, "nested"), body_b)
	support.check(t, "…a remotes list the app did not write survived a THEME save",
		strings.contains(body_b, "my-host"), body_b)
}

@(test)
config_save_round_trips_through_the_parser :: proc(t: ^testing.T) {
	// Writing is worthless if the read disagrees — that is the ISC-7 loop
	// closed. A file we cannot re-read is a file that breaks the next boot.
	dir := new_scratch(t, "save-c")
	defer delete_tree(dir)
	path := cfg_file(dir)

	hand := `{
  "hand_added_note": "do not eat this",
  "theme": "catppuccin-latte",
  "future_key": {"nested": [1, 2, 3]},
  "remotes": ["my-host"]
}`
	if werr := os.write_entire_file_from_string(path, hand); werr != nil {
		support.check(t, "fixture write", false, fmt.tprintf("{}", werr))
		return
	}
	app.config_save_theme(path, "nord")
	body_b := read_cfg(dir)

	re := app.config_parse_json(body_b, path)
	support.check(t, "the saved file re-reads to the saved theme", re.theme == "nord",
		fmt.tprintf("re-read theme='{}'", re.theme))
	support.check(t, "…with no warnings (a save must not produce a file that warns)",
		len(re.warnings) == 0, warn_join(re))
}

@(test)
config_save_remotes_and_cleanup_keep_everything_else :: proc(t: ^testing.T) {
	dir := new_scratch(t, "save-d")
	defer delete_tree(dir)
	path := cfg_file(dir)

	hand := HAND_EDITED
	write_cfg_text(t, path, hand)
	app.config_save_theme(path, "nord")

	hosts := []app.Remote{
		app.Remote{device = "alpha.example"},
		app.Remote{device = "beta.example"},
	}
	ok3, e3 := app.config_save_remotes(path, hosts)
	support.check(t, "config_save_remotes succeeds", ok3, fmt.tprintf("err='{}'", e3))
	body_d := read_cfg(dir)
	support.check(t, "…both verbatim targets are on disk",
		strings.contains(body_d, "alpha.example") && strings.contains(body_d, "beta.example"),
		body_d)
	support.check(t, "…the hand-added note STILL survives (third write)",
		strings.contains(body_d, "hand_added_note"), body_d)

	ok4, e4 := app.config_save_cleanup(path, "only_created")
	body_e := read_cfg(dir)
	support.check(t, "config_save_cleanup writes its key and keeps everything else",
		ok4 && strings.contains(body_e, `"cleanup_policy": "only_created"`) &&
		strings.contains(body_e, "hand_added_note") &&
		strings.contains(body_e, "alpha.example"),
		fmt.tprintf("ok={} err='{}'\n{}", ok4, e4, body_e))
}

@(test)
config_save_replaces_by_rename_not_truncate :: proc(t: ^testing.T) {
	// HONEST SCOPE OF THIS CHECK. The crash window itself cannot be reproduced
	// in a single-process test without a fault-injection hook into write_doc, so
	// what is asserted here is the surrounding rename semantics:
	//   * a replace produces a NEW inode (a rename, not an in-place truncate —
	//     a truncate is visible to a concurrent reader as a short file),
	//   * the temp never survives the call,
	//   * and the file is present the instant the save returns, with no retry.
	// What is NOT machine-proven here is "a SIGKILL in the middle leaves the old
	// file"; that rests on the rename syscall's guarantee, which is exactly why
	// the code uses the rename alone and nothing else.
	dir := new_scratch(t, "save-e")
	defer delete_tree(dir)
	path := cfg_file(dir)

	app.config_save_theme(path, "nord")
	before := config_inode(path)
	ok_at, err_at := app.config_save_theme(path, "gruvbox-dark")
	after := config_inode(path)

	support.check(t, "a save over an existing config succeeds", ok_at,
		fmt.tprintf("err='{}'", err_at))
	support.check(t, "…the replaced file is a NEW inode (rename, not truncate-in-place)",
		before != 0 && after != 0 && before != after,
		fmt.tprintf("before={} after={}", before, after))
	support.check(t, "…and no .tmp file was left behind",
		!file_exists(fmt.tprintf("{}.tmp", path)), "a leftover tmp means the rename did not happen")
	support.check(t, "…the config is on disk immediately after the save returns",
		file_exists(path), fmt.tprintf("path={}", path))
}

@(test)
config_save_write_doc_never_unlinks_the_live_file :: proc(t: ^testing.T) {
	// The structural half of the atomicity fix, checked structurally because
	// the temporal half is not reproducible in-process. The previous version
	// unlinked the live file before renaming, which opened exactly the window
	// this function exists to close.
	src := read_source_file("src/app/config.odin")
	in_wd := between(src, "write_doc :: proc", "\n// path_dir")
	support.check(t, "…and write_doc never unlinks the live config",
		!strings.contains(in_wd, "os.remove(path)") && strings.contains(in_wd, "os.rename(tmp, path)"),
		fmt.tprintf("write_doc body mentions remove={} rename={}",
			strings.contains(in_wd, "os.remove(path)"),
			strings.contains(in_wd, "os.rename(tmp, path)")))
}

@(test)
config_save_over_a_corrupt_file_stays_usable :: proc(t: ^testing.T) {
	// An unparseable file cannot be preserved, and the code says so by keeping
	// the app usable rather than refusing to start. The warning already told
	// the user the file was invalid; a save then replaces it with something
	// that parses.
	dir := new_scratch(t, "save-f")
	defer delete_tree(dir)
	path := cfg_file(dir)

	write_cfg_text(t, path, "{ broken {{{")
	ok5, e5 := app.config_save_theme(path, "nord")
	body_f := read_cfg(dir)
	support.check(t, "save over a CORRUPT file still succeeds (stay usable)", ok5,
		fmt.tprintf("err='{}'", e5))
	support.check(t, "…the replaced file is valid and carries the theme",
		strings.contains(body_f, `"theme": "nord"`) &&
		!app.config_parse_json(body_f, path).corrupt, body_f)
}

@(test)
config_save_leaves_no_tmp_litter :: proc(t: ^testing.T) {
	dir := new_scratch(t, "save-g")
	defer delete_tree(dir)
	path := cfg_file(dir)
	write_cfg_text(t, path, `{"theme":"nord"}`)
	app.config_save_theme(path, "nord")
	app.config_save_remotes(path, []app.Remote{app.Remote{device = "x.example"}})
	app.config_save_cleanup(path, "always")
	support.check(t, "no *.tmp litter left in the config dir", count_tmp(dir) == 0,
		fmt.tprintf("{} tmp file(s) left in {}", count_tmp(dir), dir))
}

@(test)
config_save_is_pretty_and_key_sorted :: proc(t: ^testing.T) {
	// The file is the user's record. If it cannot be diffed by eye it will not
	// be edited by eye, and a config nobody will touch is a config whose
	// hand-added keys eventually get eaten anyway.
	dir := new_scratch(t, "save-h")
	defer delete_tree(dir)
	path := cfg_file(dir)
	write_cfg_text(t, path, `{"theme":"nord"}`)
	app.config_save_cleanup(path, "only_created")
	app.config_save_remotes(path, []app.Remote{app.Remote{device = "a.example"}})
	body_e := read_cfg(dir)

	support.check(t, "output is pretty-printed (indented, multi-line)",
		strings.contains(body_e, "\n  \""), body_e)
	i_clean := index_of_str(body_e, "\"cleanup_policy\"")
	i_rem := index_of_str(body_e, "\"remotes\"")
	support.check(t, "keys are sorted so the file is diffable",
		i_clean >= 0 && i_rem >= 0 && i_clean < i_rem,
		fmt.tprintf("cleanup_policy at {}, remotes at {}", i_clean, i_rem))
}

@(test)
config_save_cleanup_policy_enum_round_trip :: proc(t: ^testing.T) {
	// The config<->enum mapping must agree with the executor's own labels, or
	// the file re-serialises into a value its own parser rejects.
	pols := [3]string{"never", "only_created", "always"}
	for pol in pols {
		e := app.cleanup_policy_from_name(pol)
		back := app.cleanup_policy_config_label(e)
		support.check(t, fmt.tprintf("cleanup_policy '{}' round-trips through the enum", pol),
			back == pol && app.cleanup_policy_valid(pol),
			fmt.tprintf("'{}' -> enum -> '{}'", pol, back))
	}
	support.check(t, "an unknown policy maps to the SAFE one (.never)",
		app.cleanup_policy_from_name("yolo") == app.Cleanup_Policy.never,
		fmt.tprintf("yolo -> {}",
			app.cleanup_policy_config_label(app.cleanup_policy_from_name("yolo"))))
}

//-----------------------------------------------------------------------------
// local file helpers
//-----------------------------------------------------------------------------

index_of_str :: proc(hay: string, needle: string) -> int {
	if len(needle) == 0 || len(hay) == 0 { return -1 }
	for i in 0 ..= (len(hay) - len(needle)) {
		if hay[i:i+len(needle)] == needle { return i }
	}
	return -1
}

// read_source_file / between — a structural check over the project's own
// source. Used ONLY where the property is temporal (a crash window) and
// therefore not reproducible in-process, so the guard is "the dangerous call
// is not in the function at all".
SRC_SEARCH : []string = {"", "../", "../../"}

read_source_file :: proc(rel: string) -> string {
	for dir in SRC_SEARCH {
		p := fmt.tprintf("{}{}", dir, rel)
		if b, ok := os.read_entire_file(p, context.allocator); ok == nil && b != nil {
			return string(b)
		}
	}
	return ""
}

between :: proc(s: string, start, end: string) -> string {
	i := strings.index(s, start)
	if i < 0 { return "" }
	j := strings.index(s[i:], end)
	if j < 0 { return s[i:] }
	return s[i : i+j]
}

// write_cfg_text places a config file for a fixture. The result is checked
// rather than discarded: a silently-failed fixture write shows up as "the merge
// rule is broken" instead of "the disk refused", which is a much more expensive
// thing to debug at 1am.
