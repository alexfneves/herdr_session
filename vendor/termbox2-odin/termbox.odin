package termbox2

// The archive is staged into lib/ by the package derivation (nix/package.nix);
// it is never committed to this repository.
foreign import tb2 "lib/libtermbox2.a"

// Must match the -DTB_OPT_ATTR_W 32 used to build libtermbox2.a (truecolor).
Attr :: u32

// Minimal surface for the Phase 0 link check. T1.1 completes this binding with
// tb_init/tb_shutdown/tb_poll_event/tb_set_cell/tb_present/tb_get_fds and the
// event/enum types.
@(default_calling_convention = "c")
foreign tb2 {
	tb_wcwidth :: proc(ch: u32) -> i32 ---
}
