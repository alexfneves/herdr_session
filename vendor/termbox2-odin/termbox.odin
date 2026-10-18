// Package termbox2 is a hand-written Odin foreign binding to termbox2
// (https://github.com/termbox/termbox2), a single-header terminal renderer (MIT).
//
// The archive is built in-derivation with `#define TB_IMPL` and
// `#define TB_OPT_ATTR_W 32` (see nix/termbox2.nix) and staged into lib/ by
// nix/package.nix; it is never committed to this repository.
//
// EVERY signature, struct layout and constant below was verified against the
// pinned upstream header (rev 48cda6f83a4a1a98d3546beafe55b31a5861c21d,
// 4312 lines) — not from memory. Line references in comments point into that file.
//
// ABI facts that are easy to get wrong (all verified):
//
//   * `uintattr_t` is `uint32_t` at TB_OPT_ATTR_W == 32          (termbox2.h:395-401)
//   * `struct tb_event` is {u8,u8,u16,u32,i32,i32,i32,i32}     (termbox2.h:453-462)
//     == 24 bytes, 4-byte aligned. `ch` is 32-bit and w/h/x/y are i32.
//   * TB_OPT_EGC is NOT defined, so `struct tb_cell` is exactly
//     {u32 ch, uintattr_t fg, uintattr_t bg} == 12 bytes         (termbox2.h:428-437)
//   * At 32-bit attr width the style bits live in the HIGH half of the word, e.g.
//     TB_BOLD == 0x01000000                                     (termbox2.h:279-287)
//   * TB_STRIKEOUT / TB_UNDERLINE_2 / TB_OVERLINE / TB_INVISIBLE only exist at
//     TB_OPT_ATTR_W == 64 (they need bits above 0xffffffff) and are therefore
//     NOT bindable here.                                          (termbox2.h:294-300)
//   * `size_t` in this Odin is spelled `c.size_t` (there is no `size_t` builtin).
package termbox2

import "core:c"

foreign import tb2 "lib/libtermbox2.a"

//-----------------------------------------------------------------------------
// Types
//-----------------------------------------------------------------------------

// Attr is termbox2's `uintattr_t` at TB_OPT_ATTR_W == 32: 24-bit colour plus the
// style bits in the high byte. Must match how the archive was compiled, or every
// colour is silently quantised.
Attr :: u32

// Cell mirrors `struct tb_cell` (no TB_OPT_EGC). Only read via tb_get_cell; the
// library owns the memory and may invalidate it on the next call.
Cell :: struct {
	ch : u32, // Unicode codepoint
	fg : Attr, // bitwise foreground attributes
	bg : Attr, // bitwise background attributes
}

// Event mirrors `struct tb_event` (termbox2.h:453-462).
//
// Depending on `typ`:
//   TB_EVENT_KEY    -> `key` xor `ch` (one is zero), plus `mod`
//   TB_EVENT_RESIZE -> `w`, `h`
//   TB_EVENT_MOUSE  -> `key` (TB_KEY_MOUSE_*), `x`, `y`, `mod`
//
// NOTE: upstream names this field `type`; it is `typ` here because the C keyword
// cannot be used as an Odin field name in a binding we want to read literally.
// The offsets are identical either way — see the #assert below.
Event :: struct {
	typ : u8, // one of EVENT_* / TB_EVENT_*
	mod : u8, // bitwise MOD_* / TB_MOD_*
	key : u16, // one of KEY_* / TB_KEY_*
	ch  : u32, // Unicode codepoint

	w, h : i32, // TB_EVENT_RESIZE
	x, y : i32, // TB_EVENT_MOUSE
}

#assert(size_of(Event) == 24, "struct tb_event ABI drift")
#assert(size_of(Cell) == 12, "struct tb_cell ABI drift")
#assert(size_of(Attr) == 4, "TB_OPT_ATTR_W must be 32 in nix/termbox2.nix")

//-----------------------------------------------------------------------------
// Event types  (termbox2.h:303-310)
//-----------------------------------------------------------------------------

TB_EVENT_KEY    :: 1
TB_EVENT_RESIZE :: 2
TB_EVENT_MOUSE  :: 3

EVENT_KEY    :: TB_EVENT_KEY
EVENT_RESIZE :: TB_EVENT_RESIZE
EVENT_MOUSE  :: TB_EVENT_MOUSE

//-----------------------------------------------------------------------------
// Key modifiers (bitwise)  (termbox2.h:312-316)
//-----------------------------------------------------------------------------

TB_MOD_ALT    :: 1
TB_MOD_CTRL   :: 2
TB_MOD_SHIFT  :: 4
TB_MOD_MOTION :: 8

MOD_ALT    :: TB_MOD_ALT
MOD_CTRL   :: TB_MOD_CTRL
MOD_SHIFT  :: TB_MOD_SHIFT
MOD_MOTION :: TB_MOD_MOTION

//-----------------------------------------------------------------------------
// Input modes (bitwise)  (termbox2.h:318-323)
//-----------------------------------------------------------------------------

TB_INPUT_CURRENT :: 0
TB_INPUT_ESC     :: 1
TB_INPUT_ALT     :: 2
TB_INPUT_MOUSE   :: 4

//-----------------------------------------------------------------------------
// Output modes  (termbox2.h:325-328)
//-----------------------------------------------------------------------------

TB_OUTPUT_CURRENT   :: 0
TB_OUTPUT_NORMAL    :: 1
TB_OUTPUT_256       :: 2
TB_OUTPUT_216       :: 3
TB_OUTPUT_GRAYSCALE :: 4
TB_OUTPUT_TRUECOLOR :: 5

OUTPUT_CURRENT   :: TB_OUTPUT_CURRENT
OUTPUT_NORMAL    :: TB_OUTPUT_NORMAL
OUTPUT_256       :: TB_OUTPUT_256
OUTPUT_216       :: TB_OUTPUT_216
OUTPUT_GRAYSCALE :: TB_OUTPUT_GRAYSCALE
OUTPUT_TRUECOLOR :: TB_OUTPUT_TRUECOLOR

//-----------------------------------------------------------------------------
// Return codes  (termbox2.h:330-357)
//-----------------------------------------------------------------------------

TB_OK     :: 0
TB_ERR    :: -1
TB_ERR_NEED_MORE        :: -2
TB_ERR_INIT_ALREADY     :: -3
TB_ERR_INIT_OPEN        :: -4
TB_ERR_MEM              :: -5
TB_ERR_NO_EVENT         :: -6
TB_ERR_NO_TERM          :: -7
TB_ERR_NOT_INIT         :: -8
TB_ERR_OUT_OF_BOUNDS    :: -9
TB_ERR_READ             :: -10
TB_ERR_RESIZE_IOCTL     :: -11
TB_ERR_RESIZE_PIPE      :: -12
TB_ERR_RESIZE_SIGACTION :: -13
TB_ERR_POLL             :: -14
TB_ERR_TCGETATTR        :: -15
TB_ERR_TCSETATTR        :: -16
TB_ERR_UNSUPPORTED_TERM :: -17
TB_ERR_RESIZE_WRITE     :: -18
TB_ERR_RESIZE_POLL      :: -19
TB_ERR_RESIZE_READ      :: -20
TB_ERR_RESIZE_SSCANF    :: -21
TB_ERR_CAP_COLLISION    :: -22

//-----------------------------------------------------------------------------
// Keys  (termbox2.h:126-206)
//-----------------------------------------------------------------------------

KEY_CTRL_TILDE :: 0x00
KEY_CTRL_A     :: 0x01
KEY_CTRL_B     :: 0x02
KEY_CTRL_C     :: 0x03
KEY_CTRL_D     :: 0x04
KEY_CTRL_E     :: 0x05
KEY_CTRL_F     :: 0x06
KEY_CTRL_G     :: 0x07
KEY_BACKSPACE  :: 0x08
KEY_TAB        :: 0x09
KEY_CTRL_J     :: 0x0a
KEY_CTRL_K     :: 0x0b
KEY_CTRL_L     :: 0x0c
KEY_ENTER      :: 0x0d
KEY_CTRL_N     :: 0x0e
KEY_CTRL_O     :: 0x0f
KEY_CTRL_P     :: 0x10
KEY_CTRL_Q     :: 0x11
KEY_CTRL_R     :: 0x12
KEY_CTRL_S     :: 0x13
KEY_CTRL_T     :: 0x14
KEY_CTRL_U     :: 0x15
KEY_CTRL_V     :: 0x16
KEY_CTRL_W     :: 0x17
KEY_CTRL_X     :: 0x18
KEY_CTRL_Y     :: 0x19
KEY_CTRL_Z     :: 0x1a
KEY_ESC        :: 0x1b
KEY_CTRL_4     :: 0x1c
KEY_CTRL_5     :: 0x1d
KEY_CTRL_6     :: 0x1e
KEY_CTRL_7     :: 0x1f
KEY_SPACE      :: 0x20
KEY_BACKSPACE2 :: 0x7f

KEY_F1               :: 0xffff - 0
KEY_F2               :: 0xffff - 1
KEY_F3               :: 0xffff - 2
KEY_F4               :: 0xffff - 3
KEY_F5               :: 0xffff - 4
KEY_F6               :: 0xffff - 5
KEY_F7               :: 0xffff - 6
KEY_F8               :: 0xffff - 7
KEY_F9               :: 0xffff - 8
KEY_F10              :: 0xffff - 9
KEY_F11              :: 0xffff - 10
KEY_F12              :: 0xffff - 11
KEY_INSERT           :: 0xffff - 12
KEY_DELETE           :: 0xffff - 13
KEY_HOME             :: 0xffff - 14
KEY_END              :: 0xffff - 15
KEY_PGUP             :: 0xffff - 16
KEY_PGDN             :: 0xffff - 17
KEY_ARROW_UP         :: 0xffff - 18
KEY_ARROW_DOWN       :: 0xffff - 19
KEY_ARROW_LEFT       :: 0xffff - 20
KEY_ARROW_RIGHT      :: 0xffff - 21
KEY_BACK_TAB         :: 0xffff - 22
KEY_MOUSE_LEFT       :: 0xffff - 23
KEY_MOUSE_RIGHT      :: 0xffff - 24
KEY_MOUSE_MIDDLE     :: 0xffff - 25
KEY_MOUSE_RELEASE    :: 0xffff - 26
KEY_MOUSE_WHEEL_UP   :: 0xffff - 27
KEY_MOUSE_WHEEL_DOWN :: 0xffff - 28

// TB_KEY_CTRL_2, TB_KEY_CTRL_H, TB_KEY_CTRL_I, TB_KEY_CTRL_M, TB_KEY_CTRL_LSQ_BRACKET,
// TB_KEY_CTRL_3, TB_KEY_CTRL_BACKSLASH, TB_KEY_CTRL_RSQ_BRACKET, TB_KEY_CTRL_SLASH and
// TB_KEY_CTRL_UNDERSCORE deliberately alias other keys upstream (the header marks them
// with "// clash with ..."). Bind the distinct codes only; aliasing them here would
// make a `switch` ambiguous.

//-----------------------------------------------------------------------------
// Colours + style attributes  (termbox2.h:257-287)
//-----------------------------------------------------------------------------

TB_DEFAULT :: 0x0000 // skip sending a colour code
TB_BLACK   :: 0x0001
TB_RED     :: 0x0002
TB_GREEN   :: 0x0003
TB_YELLOW  :: 0x0004
TB_BLUE    :: 0x0005
TB_MAGENTA :: 0x0006
TB_CYAN    :: 0x0007
TB_WHITE   :: 0x0008

// Style bits (TB_OPT_ATTR_W == 32 layout — high half of the word).
TB_BOLD      :: 0x01000000
TB_UNDERLINE :: 0x02000000
TB_REVERSE   :: 0x04000000
TB_ITALIC    :: 0x08000000
TB_BLINK     :: 0x10000000
TB_HI_BLACK  :: 0x20000000 // real black in 256/truecolor modes
TB_BRIGHT    :: 0x40000000
TB_DIM       :: 0x80000000

//-----------------------------------------------------------------------------
// Foreign procedures
//
// Verified against the declarations at termbox2.h:469-747. Not bound on purpose:
//   tb_printf / tb_printf_ex / tb_sendf  — variadic C; we format in Odin instead
//   tb_set_func                          — deprecated ("will be removed in 3.x")
//   tb_cell_buffer                       — deprecated in the header itself
//-----------------------------------------------------------------------------

@(default_calling_convention = "c")
foreign tb2 {
	// Lifecycle (termbox2.h:469-473)
	tb_init        :: proc() -> i32 ---
	tb_init_file   :: proc(path: cstring) -> i32 ---
	tb_init_fd     :: proc(ttyfd: i32) -> i32 ---
	tb_init_rwfd   :: proc(rfd, wfd: i32) -> i32 ---
	tb_shutdown    :: proc() -> i32 ---

	// Geometry (termbox2.h:480-481)
	tb_width  :: proc() -> i32 ---
	tb_height :: proc() -> i32 ---

	// Buffers (termbox2.h:486-496)
	tb_clear            :: proc() -> i32 ---
	tb_set_clear_attrs  :: proc(fg, bg: Attr) -> i32 ---
	tb_present          :: proc() -> i32 ---
	tb_invalidate       :: proc() -> i32 ---

	// Cursor (termbox2.h:499-500)
	tb_set_cursor  :: proc(cx, cy: i32) -> i32 ---
	tb_hide_cursor :: proc() -> i32 ---

	// Cells (termbox2.h:515-518, 537)
	tb_set_cell     :: proc(x, y: i32, ch: u32, fg, bg: Attr) -> i32 ---
	tb_set_cell_ex  :: proc(x, y: i32, ch: ^u32, nch: c.size_t, fg, bg: Attr) -> i32 ---
	tb_extend_cell  :: proc(x, y: i32, ch: u32) -> i32 ---
	tb_get_cell     :: proc(x, y: i32, back: i32, cell: ^^Cell) -> i32 ---

	// Modes (termbox2.h:561, 654)
	tb_set_input_mode  :: proc(mode: i32) -> i32 ---
	tb_set_output_mode :: proc(mode: i32) -> i32 ---

	// Events (termbox2.h:663-672)
	//
	// GOTCHA (verified in wait_event, termbox2.h:3461-3522): the return value is a
	// TB_* status code, NOT the event type. TB_OK means "ev is populated"; the kind
	// of event is ev.typ (EVENT_KEY / EVENT_RESIZE / EVENT_MOUSE). A timeout is
	// TB_ERR_NO_EVENT, and TB_ERR_POLL/TB_ERR_READ should be retried, not fatal.
	// tb_poll_event is tb_peek_event with timeout == -1.

	tb_peek_event  :: proc(ev: ^Event, timeout_ms: i32) -> i32 ---
	tb_poll_event  :: proc(ev: ^Event) -> i32 ---
	tb_get_fds     :: proc(ttyfd, resizefd: ^i32) -> i32 ---

	// Direct output (termbox2.h:693, 701)
	tb_print :: proc(x, y: i32, fg, bg: Attr, str: cstring) -> i32 ---
	tb_send  :: proc(buf: rawptr, nbuf: c.size_t) -> i32 ---

	// UTF-8 helpers (termbox2.h:718-736)
	tb_utf8_char_length       :: proc(c: c.char) -> i32 ---
	tb_utf8_char_to_unicode  :: proc(out: ^u32, c: cstring) -> i32 ---
	tb_utf8_unicode_to_char   :: proc(out: ^c.char, c: u32) -> i32 ---

	// Utilities (termbox2.h:739-747)
	tb_last_errno     :: proc() -> i32 ---
	tb_strerror       :: proc(err: i32) -> cstring ---
	tb_has_truecolor  :: proc() -> i32 ---
	tb_has_egc        :: proc() -> i32 ---
	tb_attr_width     :: proc() -> i32 ---
	tb_version        :: proc() -> cstring ---
	tb_iswprint       :: proc(ch: u32) -> i32 ---
	tb_wcwidth        :: proc(ch: u32) -> i32 ---
}
