package unit

// ─────────────────────────────────────────────────────────────────────────────
// state_surface_test.odin — T6 port of dev/state-smoke.sh section 3.
//
// THIRTEEN counted assertions: twelve `grep_absent` checks over
// src/app/state.odin and src/input/keymap.odin, plus the ISC-A-3 sweep of the
// whole of src/.
//
// WHY THE RUNTIME PROOF IS NOT ENOUGH
//
// Section [12] of the machine battery proves this RUN created no child
// process. These greps prove why it COULD NOT: the machine's import list holds
// nothing that could spawn one, write a file, open a socket or touch a
// terminal. A runtime proof covers one execution; an import list covers every
// execution that can ever be compiled from this source.
//
// WHY COMMENTS ARE STRIPPED FIRST
//
// The machine's own doc comments talk about forking, spawning, `os.read` and
// Escape timeouts all day long — they explain the rules these greps enforce.
// Matching them would flag the prose instead of the code, which makes the
// check unfalsifiable the moment anyone documents anything. dev/state-smoke.sh
// strips with `sed 's,//.*,,'`; this mirrors that exactly: everything from the
// first `//` on a line is removed before matching.
//
// A check that could not find the tree it scans FAILS rather than passing — the
// same rule `src_code_hits` follows in the theme port.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import support "../support"

ST_STATE_SRC   :: "app/state.odin"
ST_KEYMAP_SRC  :: "input/keymap.odin"

st_src_root :: proc() -> string {
	ST_SRC_DIRS : []string = {"src/", "../src/", "../../src/"}
	for d in ST_SRC_DIRS[:] {
		if fi, err := os.stat(d, context.allocator); err == nil && fi.type == .Directory {
			return string(d)
		}
	}
	return ""
}

// st_strip_comment removes a `//` line comment and everything after it — the
// exact behaviour of `sed 's,//.*,,'` that dev/state-smoke.sh uses. It is a
// BLIND strip on purpose: matching the old harness is what makes this port's
// count comparable, and the machine's source has no `//` inside a string
// literal for the difference to show up in.
st_strip_comment :: proc(line: string) -> string {
	for i := 0; i + 1 < len(line); i += 1 {
		if line[i] == '/' && line[i+1] == '/' {
			return line[:i]
		}
	}
	return line
}

// st_absent_lines returns the "line_no: code" of every line in `file` whose
// comment-stripped text contains any needle. Empty means the rule holds.
st_absent_lines :: proc(rel: string, needles: []string) -> [dynamic]string {
	out := make([dynamic]string, 0, 4)
	root := st_src_root()
	if len(root) == 0 {
		append(&out, "<no src/ tree found from this cwd — this check did not run>")
		return out
	}
	path := fmt.tprintf("{}/{}", root, rel)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil || data == nil {
		append(&out, fmt.tprintf("{}: unreadable — this check did not run", path))
		return out
	}
	defer delete(data)

	text := string(data)
	line_no := 0
	for start := 0; start <= len(text); {
		nl := strings.index(text[start:], "\n")
		line := text[start:]
		next := len(text)
		if nl >= 0 {
			line = text[start : start+nl]
			next = start + nl + 1
		}
		line_no += 1
		code := strings.trim_space(st_strip_comment(line))
		if len(code) > 0 {
			for n in needles {
				if strings.contains(code, n) {
					shown := code
					if len(shown) > 100 { shown = shown[:100] }
					append(&out, fmt.tprintf("{}: {}", line_no, shown))
					break
				}
			}
		}
		if nl < 0 { break }
		start = next
	}
	return out
}

// st_absent is the counted `grep_absent`.
st_absent :: proc(t: ^testing.T, label: string, rel: string, needles: []string) {
	hits := st_absent_lines(rel, needles[:])
	if len(hits) == 0 {
		support.check(t, label, true, fmt.tprintf("0 hits in {} (comments stripped)", rel))
		return
	}
	first := hits[0]
	if len(first) > 140 { first = first[:140] }
	support.check(t, label, false,
		fmt.tprintf("{} hit(s) in {}; first: {}", len(hits), rel, first))
}

// st_tree_hits walks the whole tree for a literal needle, raw bytes — the
// `grep -rn localhost src/` shape, which deliberately reads comments too: a
// loopback host name in a comment is still a loopback host name in src/.
st_tree_hits :: proc(needle: string) -> [dynamic]string {
	out := make([dynamic]string, 0, 4)
	root := st_src_root()
	if len(root) == 0 {
		append(&out, "<no src/ tree found from this cwd — this check did not run>")
		return out
	}
	st_tree_walk(root, needle, &out)
	return out
}

st_tree_walk :: proc(dir: string, needle: string, out: ^[dynamic]string) {
	f, err := os.open(dir)
	if err != nil { return }
	defer os.close(f)
	infos, derr := os.read_directory(f, -1, context.allocator)
	if derr != nil { return }
	for fi in infos {
		if fi.name == "." || fi.name == ".." { continue }
		child := fmt.tprintf("{}/{}", dir, fi.name)
		if fi.type == .Directory {
			st_tree_walk(child, needle, out)
		} else {
			data, rerr := os.read_entire_file_from_path(child, context.allocator)
			if rerr != nil || data == nil { continue }
			text := string(data)
			defer delete(data)
			if strings.contains(text, needle) {
				append(out, child)
			}
		}
	}
}

//-----------------------------------------------------------------------------
// The twelve grep_absent checks
//-----------------------------------------------------------------------------

@(test)
state_surface_no_os_module :: proc(t: ^testing.T) {
	// No files, no env, no process.
	st_absent(t, "no os module (no files, no env, no process) in state.odin",
		ST_STATE_SRC, []string{"core:os"})
}

@(test)
state_surface_no_posix :: proc(t: ^testing.T) {
	// No fork/exec/pipe/signal.
	st_absent(t, "no posix (no fork/exec/pipe/signal) in state.odin",
		ST_STATE_SRC, []string{"core:sys/posix"})
}

@(test)
state_surface_no_net :: proc(t: ^testing.T) {
	st_absent(t, "no net (no sockets) in state.odin",
		ST_STATE_SRC, []string{"core:net"})
}

@(test)
state_surface_no_terminal_module :: proc(t: ^testing.T) {
	st_absent(t, "no terminal module in state.odin",
		ST_STATE_SRC, []string{"terminal"})
}

@(test)
state_surface_never_paints :: proc(t: ^testing.T) {
	st_absent(t, "no clay/termbox in state.odin (it never paints)",
		ST_STATE_SRC, []string{"clay", "termbox"})
}

@(test)
state_surface_no_escape_timeout :: proc(t: ^testing.T) {
	// ISC-11: with no time module there is no Escape timeout — Escape is one
	// code, handled immediately, never a sequence-wait timer.
	st_absent(t, "no time module / sleep / event peek in state.odin => no Escape timeout exists (ISC-11)",
		ST_STATE_SRC, []string{"core:time", "time.", "sleep", "peek_event"})
}

@(test)
state_surface_no_spawn_call :: proc(t: ^testing.T) {
	st_absent(t, "no exec/fork/spawn/system call in state.odin",
		ST_STATE_SRC, []string{"execv", "fork(", "spawn(", "system("})
}

@(test)
state_surface_uses_tagged_struct_not_union :: proc(t: ^testing.T) {
	// Decision O10: Command is a tagged struct, not a union.
	st_absent(t, "no union for Command — decision O10's tagged struct is used",
		ST_STATE_SRC, []string{"union {"})
}

@(test)
state_surface_keymap_has_no_kitty_protocol :: proc(t: ^testing.T) {
	// ISC-A-4: no Kitty keyboard protocol in the keymap.
	st_absent(t, "no Kitty keyboard protocol in the keymap (ISC-A-4)",
		ST_KEYMAP_SRC, []string{"kitty", "[>1u", "[u"})
}

@(test)
state_surface_keymap_has_no_fixture_hosts :: proc(t: ^testing.T) {
	st_absent(t, "no fixture host names in the keymap (ISC-A-3)",
		ST_KEYMAP_SRC, []string{"localhost", "127.0.0.1"})
}

@(test)
state_surface_state_has_no_fixture_hosts :: proc(t: ^testing.T) {
	st_absent(t, "no fixture host names in state.odin (ISC-A-3)",
		ST_STATE_SRC, []string{"localhost", "127.0.0.1"})
}

@(test)
state_surface_no_side_effect_call_shape :: proc(t: ^testing.T) {
	// The machine must not reach the outside world under any alias.
	st_absent(t, "no os./posix./net./open()/read()/write() call shape in state.odin",
		ST_STATE_SRC, []string{"os.", "posix.", "net.", "open(", "read(", "write("})
}

@(test)
state_surface_no_localhost_anywhere_in_src :: proc(t: ^testing.T) {
	// ISC-A-3 across the whole of src/, including the driver and the keymap.
	hits := st_tree_hits("localhost")
	shown := ""
	count := 0
	for h in hits {
		if count >= 3 { break }
		if len(shown) > 0 { shown = fmt.tprintf("{}; {}", shown, h) } else { shown = h }
		count += 1
	}
	support.check(t, "grep -rn localhost src/ is empty (ISC-A-3)",
		len(hits) == 0,
		fmt.tprintf("{} file(s) in src/ contain `localhost`: {}", len(hits), shown))
}
