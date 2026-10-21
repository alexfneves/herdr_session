package unit

// ─────────────────────────────────────────────────────────────────────────────
// theme_home.odin — the XDG scratch home, AND the guard that makes "the real
// ~/.config was untouched" a PROOF instead of a promise.
//
// WHY THIS IS A GUARD AND NOT AN END-OF-RUN TEST
//
// The bash suite fingerprinted the real config once BEFORE the run and once
// AFTER it. That makes the proof depend on run order: REAL_BEFORE … cases …
// REAL_AFTER. Under `core:testing` a test may fail, be reordered, or be
// filtered out, so "a bracket around the run" is not a stable unit of proof.
//
// Here the fingerprint is taken by the SAME helper that performs the dangerous
// operation. Every test that swaps XDG_CONFIG_HOME swaps it through `swap_in`,
// and every `swap_out` emits a counted assertion:
//
//     real ~/.config/herdr_session.json unchanged across this swap
//
// N swaps == N proofs, each local to the code that could have broken it.
//
// WHY THE SWAP IS DANGEROUS ENOUGH TO GUARD
//
// `config_load` resolves through `os.user_config_dir()`, which reads
// $XDG_CONFIG_HOME. Point that at a temp dir and the developer's real config is
// out of the picture; forget to point it and a suite that saves a theme has
// edited the developer's machine. The old suite's own header calls that "not
// paranoia".
//
// AND the trap this migration already paid for once (RCH-3, commit 5e84fae):
// moving XDG_CONFIG_HOME also moves **herdr's own state dir**, which makes
// `herdr session list` come back empty and produces a convincing false failure.
// Nothing in this file touches a live herdr session — it writes only into /tmp
// scratch it created itself — but this is why the live/herdr-dependent suites
// live separately under `tests/it/live_*`, and why the fixture must never aim
// XDG_CONFIG_HOME around a live-session assertion. Recorded here so nobody
// "simplifies" the two back together.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import md5 "core:crypto/legacy/md5"

import app "../../src/app"
import support "../support"

// Scratch lives under /tmp with an explicit prefix, never inside $HOME. A
// scratch directory inside the home directory is the one thing this suite must
// never create.
SCRATCH_ROOT   :: "/tmp"
SCRATCH_PREFIX :: "hs-t9-theme-"

// Fingerprint is an observation of the developer's real config file.
Fingerprint :: struct {
	path   : string, // the real file, resolved from $HOME (NOT via user_config_dir)
	state  : string, // "present" | "absent" | "unreadable"
	digest : string, // lowercase hex, or "ABSENT" / "UNREADABLE"
	err    : string,
}

// Home is one XDG swap: the scratch we made, the prior env we must restore
// exactly, and the real-config fingerprint taken BEFORE the swap.
Home :: struct {
	dir      : string,
	had_xdg  : string,
	had_set  : bool, // false == XDG_CONFIG_HOME was unset (not merely empty)
	real     : Fingerprint,
}

//-----------------------------------------------------------------------------
// The fingerprint
//-----------------------------------------------------------------------------

// fingerprint_real_config reads ~/.config/herdr_session.json directly from
// $HOME. It deliberately does NOT use os.user_config_dir(): while the swap is
// in effect the resolver points at our scratch dir, so a guard that used it
// would fingerprint the scratch copy and then declare the real file untouched
// without ever having looked at it. A guard that cannot see what it guards is
// worse than no guard, because it reports green.
fingerprint_real_config :: proc() -> Fingerprint {
	f : Fingerprint = {}
	home, ok := os.lookup_env("HOME", context.allocator)
	if !ok || len(home) == 0 {
		f.path = "<no HOME>"
		f.state = "unreadable"
		f.digest = "UNREADABLE"
		f.err = "HOME is unset, so the real config path cannot be resolved"
		return f
	}
	f.path = fmt.tprintf("%s/.config/%s", home, app.CONFIG_FILE_NAME)
	if !os.is_file(f.path) {
		f.state = "absent"
		f.digest = "ABSENT"
		return f
	}
	data, err := os.read_entire_file_from_path(f.path, context.allocator)
	if err != nil {
		f.state = "unreadable"
		f.digest = "UNREADABLE"
		f.err = fmt.tprintf("{}", err)
		return f
	}
	f.state = "present"
	f.digest = md5_hex(data)
	delete(data)
	return f
}

// md5_hex prints the digest the way `md5sum` does, so a reviewer can diff the
// number this test reports against a shell fingerprint of the same file.
md5_hex :: proc(data: []u8) -> string {
	digest : [16]u8
	ctx : md5.Context
	md5.init(&ctx)
	md5.update(&ctx, data)
	md5.final(&ctx, digest[:])
	digits := "0123456789abcdef"
	out := make([]u8, len(digest)*2)
	for i := 0; i < len(digest); i += 1 {
		out[i*2]   = digits[uint(digest[i] >> 4)]
		out[i*2+1] = digits[uint(digest[i] & 0x0f)]
	}
	return string(out)
}

//-----------------------------------------------------------------------------
// The swap
//-----------------------------------------------------------------------------

// scratch_dir makes a throwaway XDG_CONFIG_HOME.
//
// The directory is created with app.CONFIG_DIR_MODE, which includes +x. That
// execute bit is not decoration: a directory created read/write-only cannot be
// traversed, so EVERY write inside it fails with EACCES — the exact bug the
// product's own CONFIG_DIR_MODE comment records. A scratch dir that silently
// rejects writes turns every downstream "did it save?" proof into a lie.
scratch_dir :: proc(tag: string) -> string {
	return fmt.tprintf("{}/{}{}-{}", SCRATCH_ROOT, SCRATCH_PREFIX, tag, int(os.get_pid()))
}

// swap_in points XDG_CONFIG_HOME at a fresh scratch dir and returns the prior
// state so `swap_out` can restore it exactly — including the difference
// between "was set to empty" and "was unset", which a naive restore flattens.
swap_in :: proc(tag: string) -> (Home, os.Error) {
	h : Home = {}
	h.dir = scratch_dir(tag)
	if err := os.mkdir_all(h.dir, app.CONFIG_DIR_MODE); err != nil {
		return h, err
	}
	h.real = fingerprint_real_config()
	h.had_xdg, h.had_set = os.lookup_env("XDG_CONFIG_HOME", context.allocator)
	if err := os.set_env("XDG_CONFIG_HOME", h.dir); err != nil {
		return h, err
	}
	count_guarded_swap()
	return h, nil
}

// swap_out restores XDG_CONFIG_HOME to exactly what it was, then asserts the
// two halves of the XDG discipline invariant:
//
//   1. the developer's real config file is byte-identical to the fingerprint
//      taken before the swap (RCH-18), and
//   2. the swap did not leak — the process now sees the same XDG_CONFIG_HOME
//      it saw before the swap.
swap_out :: proc(t: ^testing.T, label: string, h: ^Home) {
	// Unset is restored as unset. Empty-but-set would leave later tests
	// resolving against "" instead of $HOME/.config.
	if h^.had_set {
		os.set_env("XDG_CONFIG_HOME", h^.had_xdg)
	} else {
		os.unset_env("XDG_CONFIG_HOME")
	}

	after := fingerprint_real_config()

	// (1) THE REAL-CONFIG PROOF — counted, per swap.
	//
	// "unreadable" on either side is a FAILURE, not a pass. An unreadable real
	// file means the guard never saw the thing it guards, and a guard that saw
	// nothing must not report green. Same for a present/absent flip: the file
	// appeared or vanished, which is exactly the change we are guarding.
	untouched := h^.real.state == after.state && h^.real.digest == after.digest &&
		h^.real.state != "unreadable"
	support.check(t, fmt.tprintf("{}: real ~/.config/{} untouched", label, app.CONFIG_FILE_NAME),
		untouched,
		fmt.tprintf("before={} digest={}  after={} digest={}  path={}{}",
			h^.real.state, h^.real.digest, after.state, after.digest, after.path,
			err_note(after.err)))

	// (2) THE NON-LEAK PROOF.
	now, now_set := os.lookup_env("XDG_CONFIG_HOME", context.allocator)
	leaked := now_set != h^.had_set
	if now_set && h^.had_set && now != h^.had_xdg { leaked = true }
	support.check(t, fmt.tprintf("{}: XDG_CONFIG_HOME did not leak into the caller", label),
		!leaked,
		fmt.tprintf("before='{}' (set={})  after='{}' (set={})",
			h^.had_xdg, h^.had_set, now, now_set))
}

err_note :: proc(e: string) -> string {
	if len(e) == 0 { return "" }
	return fmt.tprintf("  err={}", e)
}

//-----------------------------------------------------------------------------
// Cross-test counters the hygiene test reads
//-----------------------------------------------------------------------------
//
// STATIC on purpose. A heap-allocated shared ledger gets allocated against
// whichever test's context allocator ran first and is freed when that test
// ends, leaving every later reader with a dangling pointer — a segfault that
// was actually hit earlier in this migration. A zero-initialised global has
// process lifetime, cannot leak, and costs nothing.

Counter_Mutex  : sync.Mutex = {}
SWAPS_GUARDED  : int = 0

count_guarded_swap :: proc() {
	sync.mutex_lock(&Counter_Mutex)
	SWAPS_GUARDED += 1
	sync.mutex_unlock(&Counter_Mutex)
}

guarded_swaps :: proc() -> int {
	sync.mutex_lock(&Counter_Mutex)
	defer sync.mutex_unlock(&Counter_Mutex)
	return SWAPS_GUARDED
}

//-----------------------------------------------------------------------------
// config-file helpers shared by the save/live cases
//-----------------------------------------------------------------------------
//
// Every one of these is checked rather than silently discarded where it writes.
// A fixture write that fails quietly shows up later as "the merge rule is
// broken", which is an expensive thing to chase; stated here it shows up as
// "the disk refused", which is not.

// new_scratch creates a scratch directory without touching the environment.
// The save cases pass explicit paths and do not need a swap; the live cases do,
// and they use swap_in instead.
new_scratch :: proc(t: ^testing.T, tag: string) -> string {
	dir := scratch_dir(tag)
	if err := os.mkdir_all(dir, app.CONFIG_DIR_MODE); err != nil {
		support.check(t, fmt.tprintf("scratch create {}", dir), false, fmt.tprintf("{}", err))
	}
	return dir
}

cfg_file :: proc(dir: string) -> string {
	return fmt.tprintf("{}/{}", dir, app.CONFIG_FILE_NAME)
}

read_cfg :: proc(dir: string) -> string {
	data, err := os.read_entire_file_from_path(cfg_file(dir), context.allocator)
	if err != nil || data == nil { return "" }
	return string(data)
}

write_cfg_text :: proc(t: ^testing.T, path: string, body: string) {
	if err := os.write_entire_file_from_string(path, body); err != nil {
		support.check(t, fmt.tprintf("fixture: write {}", path), false, fmt.tprintf("{}", err))
	}
}

config_inode :: proc(path: string) -> u128 {
	fi, err := os.stat(path, context.allocator)
	if err != nil { return 0 }
	return fi.inode
}

file_exists :: proc(path: string) -> bool {
	if _, err := os.stat(path, context.allocator); err != nil { return false }
	return true
}

count_tmp :: proc(dir: string) -> int {
	f, err := os.open(dir)
	if err != nil { return -1 }
	defer os.close(f)
	infos, derr := os.read_directory(f, -1, context.allocator)
	if derr != nil { return -1 }
	n := 0
	for fi in infos {
		// "." and ".." are not .tmp; suffix test alone is enough but a stray
		// directory named "*.tmp" would also count, which is what we want.
		if len(fi.name) >= 4 && fi.name[len(fi.name)-4:] == ".tmp" { n += 1 }
	}
	return n
}

delete_tree :: proc(dir: string) {
	// The scratch interlock: refuse anything that is not one of ours, BEFORE
	// any recursive removal. A guard that runs after the walk is a guard that
	// already deleted something.
	if !strings.has_prefix(dir, fmt.tprintf("{}/{}", SCRATCH_ROOT, SCRATCH_PREFIX)) {
		fmt.printfln("[HS] TRAP refusing to delete a non-scratch path: {}", dir)
		support.trap()
	}
	f, err := os.open(dir)
	if err != nil { return }
	infos, derr := os.read_directory(f, -1, context.allocator)
	os.close(f)
	// A directory we cannot read must NOT be recursively removed blind: a
	// partial listing plus rm is how the wrong tree disappears.
	if derr != nil {
		os.remove(dir)
		return
	}
	for fi in infos {
		if fi.name == "." || fi.name == ".." { continue }
		child := fmt.tprintf("{}/{}", dir, fi.name)
		if fi.type == .Directory {
			delete_tree(child)
		} else {
			// A mode-000 file inside the scratch would otherwise block removal.
			os.chmod(child, os.Permissions_Read_Write_All)
			os.remove(child)
		}
	}
	os.remove(dir)
}

//-----------------------------------------------------------------------------
// swap_theme_cfg — the one call the live cases use
//-----------------------------------------------------------------------------
//
// Wraps swap_in/swap_out with a core:testing CLEANUP rather than a trailing
// statement or a `defer`, for two reasons this migration already learned the
// hard way:
//
//   1. `@fini` does NOT run under `-build-mode:test`, so a fini-based
//      restore silently never happens;
//   2. an assertion that fails BEFORE a trailing restore leaves XDG_CONFIG_HOME
//      pointing at a scratch dir for every later test in the same process,
//      which makes the next test read the wrong file and report a pass that
//      proves nothing.
//
// The Home struct is heap-allocated here and freed by the cleanup itself. That
// is deliberate: the LEDGER globals stay static (a heap-allocated shared ledger
// segfaults, see the counter note above), but a per-test struct with a
// well-defined owner is fine and is freed exactly once.

swap_theme_cfg :: proc(t: ^testing.T, tag: string) -> string {
	h, err := swap_in(tag)
	if err != nil {
		support.check(t, fmt.tprintf("swap_in({})", tag), false, fmt.tprintf("{}", err))
		return h.dir
	}
	// t is not available inside the cleanup proc, so the label is carried with
	// the struct. The cleanup MUST NOT fail in the same way the test might:
	// it only restores env and verifies the real config, asserting through the
	// ledger which is safe outside a test body.
	idx := claim_home_slot()
	HOME_POOL[idx] = h
	testing.cleanup(t, proc(raw: rawptr) {
		i := int(int(rawptr_to_int(raw)))
		swap_out_no_t(&HOME_POOL[i])
		release_home_slot(i)
	}, int_to_rawptr(idx))
	return h.dir
}

// swap_out_no_t is swap_out without a ^testing.T, for the cleanup path where
// one is not available. It keeps the same guarantees and prints the same
// evidence; a violation is still loud.
swap_out_no_t :: proc(h: ^Home) {
	if h^.had_set {
		os.set_env("XDG_CONFIG_HOME", h^.had_xdg)
	} else {
		os.unset_env("XDG_CONFIG_HOME")
	}
	after := fingerprint_real_config()
	untouched := h^.real.state == after.state && h^.real.digest == after.digest &&
		h^.real.state != "unreadable"
	now, now_set := os.lookup_env("XDG_CONFIG_HOME", context.allocator)
	leaked := now_set != h^.had_set
	if now_set && h^.had_set && now != h^.had_xdg { leaked = true }
	if !untouched || leaked {
		fmt.printfln(
		    "[HS] SWAP CLEANUP VIOLATION tag={} untouched={} leaked={} before={} {} after={} {}",
		    h^.dir, untouched, leaked, h^.real.state, h^.real.digest, after.state, after.digest)
	}
	record_swap_results(untouched, leaked, h^.real.digest, after.digest)
	delete_tree(h^.dir)
}

// Aggregate recorders read by theme_hygiene_test. Static, atomic, and
// deliberately NOT a counted assertion: the counted proof is emitted once by
// the hygiene test over the WHOLE battery (see theme_hygiene_test.odin), so
// the same property is not double-counted across every case that happens to
// swap. The per-swap result is what makes the aggregate meaningful: N swaps
// verified, and any single failure makes the aggregate red.
Swap_Aggregate :: struct {
	n : int,
	bad_untouched : int,
	bad_leak : int,
	before_digest : string,
	last_digest : string,
}
AGG : Swap_Aggregate = {}

record_swap_results :: proc(untouched: bool, leaked: bool, before_digest: string, after_digest: string) {
	sync.mutex_lock(&Counter_Mutex)
	AGG.n += 1
	if !untouched { AGG.bad_untouched += 1 }
	if leaked { AGG.bad_leak += 1 }
	AGG.last_digest = after_digest
	if len(AGG.before_digest) == 0 { AGG.before_digest = before_digest }
	sync.mutex_unlock(&Counter_Mutex)
}

//-----------------------------------------------------------------------------
// Static Home pool
//-----------------------------------------------------------------------------
//
// The cleanup callback core:testing hands you is `proc(rawptr)` — no context,
// no ^testing.T. Anything it touches must therefore be valid at that moment
// regardless of which allocator ran when. Heap-allocating the Home in the
// test body and freeing it in the cleanup is exactly the mismatch that bites
// here; a process-lifetime array is not.
//
// 64 slots, indexed atomically, released back to the pool when the cleanup
// runs. The suite uses ~10 concurrent swaps at most; if the pool is ever
// exhausted the swap refuses rather than silently reusing a live slot.
HOME_POOL_SIZE :: 64
HOME_POOL : [HOME_POOL_SIZE]Home = {}
// All slots start free. `for`-initialised rather than a literal so the array
// length stays the single source of truth.
HOME_FREE_BITS : [HOME_POOL_SIZE]bool = {}
HOME_CLAIM_IDX : int = 0
HOME_POOL_MU : sync.Mutex = {}
HOME_BITS_INIT : bool = false

free_all_home_slots :: proc() {
	for i in 0 ..< HOME_POOL_SIZE { HOME_FREE_BITS[i] = true }
	HOME_BITS_INIT = true
}

claim_home_slot :: proc() -> int {
	sync.mutex_lock(&HOME_POOL_MU)
	defer sync.mutex_unlock(&HOME_POOL_MU)
	if !HOME_BITS_INIT { free_all_home_slots() }
	for i := 0; i < HOME_POOL_SIZE; i += 1 {
		if HOME_FREE_BITS[i] {
			HOME_FREE_BITS[i] = false
			return i
		}
	}
	fmt.printfln("[HS] TRAP Home pool exhausted ({} slots)", HOME_POOL_SIZE)
	support.trap()
	return -1
}

release_home_slot :: proc(i: int) {
	sync.mutex_lock(&HOME_POOL_MU)
	defer sync.mutex_unlock(&HOME_POOL_MU)
	if i >= 0 && i < HOME_POOL_SIZE { HOME_FREE_BITS[i] = true }
}

// core:testing's cleanup hands back a rawptr. Carrying a small int through it
// avoids allocating, and these two helpers keep the cast in ONE place.
int_to_rawptr :: proc(i: int) -> rawptr { return transmute(rawptr)(i) }
rawptr_to_int :: proc(p: rawptr) -> i64 { return transmute(i64)(p) }
