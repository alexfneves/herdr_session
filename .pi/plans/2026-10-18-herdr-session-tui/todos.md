# TODOS — `herdr-session`

**Plan artifact:** `.pi/plans/2026-10-18-herdr-session-tui/plan.md` ← **read this first, always**
**Tag:** `herdr-session-tui`
**Repo:** `/home/alexfneves/gits/herdr_session`

> Every todo is self-contained: it repeats the constraints a worker needs. Do not assume the worker has
> read the plan prose — the decision-relevant facts are inlined.
>
> **Ground rules for all tasks**
> - Odin is `pkgs.odin` (`dev-2026-09`). `..` range is **removed** → use `..<` / `..=`. Output flag is
>   **`-out:`** (`-o:` is optimization mode). `proc "c"` has **no Odin context** → no allocation / `fmt` inside.
> - Renderer decision is **B2**: `clay.odin` for layout + our own Clay→cell renderer on **termbox2**.
> - **Never copy `~/gits/tui_experiment/main.odin`'s loop.** It is anti-pattern reference only.
> - Every phase must leave `nix build` green.

---

# PHASE 0 — Retire the toolchain risk first

*Nothing feature-level until `nix run .` renders something.*

---

### T0.1 — Vendor clay + termbox2 as flake inputs and build both archives in-derivation

> **STATUS: ✅ DONE (2026-10-19).** Both inputs pinned in `flake.lock` (`clay@e6cc3694`,
> `termbox2@48cda6f8`, both `flake = false`). Verified:
> `nix build .#clayLib` → `libclay.a` (`ar t` = `clay_impl.o`);
> `nix build .#termbox2Lib` → `libtermbox2.a` (`ar t` = `tb_impl.o`), and
> `objdump -d --disassemble=tb_attr_width` returns `mov $0x20,%eax` = **32**, so truecolor is real.
> **Correction to the sketch:** `-Werror` is omitted as instructed; also omit it for termbox2, which warns
> on ignored `write()`/`read()` results in its `SIGWINCH` self-pipe handler.

**Create:** `flake.nix` (edit existing), `nix/clay.nix`, `nix/termbox2.nix`

**Do now, in `flake.nix` inputs** — both upstreams have **no flake**, so `flake = false`:
```nix
inputs = {
  nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
  systems.url = "github:nix-systems/default";
  devenv.url  = "github:cachix/devenv";
  devenv.inputs.nixpkgs.follows = "nixpkgs";

  clay     = { url = "github:nicbarker/clay/e6cc36941ab2af5d81107617039d6f527a1c660b"; flake = false; };
  termbox2 = { url = "github:termbox/termbox2/master"; flake = false; };
};
```

**`nix/termbox2.nix`** — MIT, single header, `#define TB_IMPL`. **`TB_OPT_ATTR_W 32` is mandatory for
truecolor** (default 16 would silently quantise every theme colour):
```nix
{ lib, stdenv, termbox2-src }:
stdenv.mkDerivation {
  pname = "termbox2"; version = "0-unreleased-master";
  src = termbox2-src;
  phases = [ "buildPhase" "installPhase" ];
  buildPhase = ''
    printf '#define TB_IMPL\n#define TB_OPT_ATTR_W 32\n#include "termbox2.h"\n' > tb_impl.c
    cp $src/termbox2.h .
    $CC -c -std=c99 -O2 -fPIC -o tb_impl.o tb_impl.c
    ar rcs libtermbox2.a tb_impl.o
  '';
  installPhase = ''install -Dm644 libtermbox2.a $out/lib/libtermbox2.a'';
  meta.license = lib.licenses.mit;
}
```
⚠️ **Do NOT use `-Werror`.** Clay emits unused-variable warnings under `-Wall`.

**Acceptance:** `nix-build -A clayLib` and `nix-build -A termbox2Lib` produce `.a` files;
`ar t result/lib/libtermbox2.a` lists `tb_impl.o`.

---

### T0.2 — Odin package that lays the archives at the paths the bindings hard-code, and builds

> **STATUS: ✅ DONE (2026-10-19).** **ISC-1 satisfied** — `nix run .` executes:
> ```
> herdr-session: toolchain OK
>   clay.MinMemorySize() = 5785280 bytes
>   tb_wcwidth('A')      = 1
>   tb_wcwidth(U+4E00)   = 2
> ```
> **Three corrections to the sketch, all verified the hard way — do not re-apply the old forms:**
> 1. `-mode:release` **does not exist** in `pkgs.odin dev-2026-09` (`Unknown flag: 'mode'`).
>    The optimisation flag is **`-o:speed`** (`-build-mode:` replaces the old `-mode:`).
> 2. Odin foreign blocks require modern `name :: proc(args) -> ret`; the C-style
>    `name(args) : ret` in the sketch is a syntax error. Comments are `//`, not `#`.
> 3. **The blocker that mattered:** Odin emits staged archives as `-l:<absolute path>` with a bare
>    `-L/`. GNU ld resolves `-l:` by *joining* search dirs to the name, so it needs `/` in the search
>    path — and **the nix `cc` wrapper silently drops a bare `-L/`**, so every link failed with
>    `cannot find -l:/build/source/...`. Fix: pass the long option form
>    **`-extra-linker-flags=-Wl,--library-path,/`**. Measured: `-L/`→FAIL, `-Wl,-L/`→FAIL,
>    `-Wl,--library-path,/`→OK, `NIX_LDFLAGS=-L/`→FAIL, `LIBRARY_PATH=/`→FAIL.
> 4. `lib.fileset` is unusable here (it demands git-tracked files and the flake must evaluate before
>    commit); use `lib.cleanSourceWith` with an explicit `src`/`vendor` prefix filter.
>
> **Note for T1.1:** `tb_last_errno` **does** exist (`termbox2.h:739`) — keep it in the binding.

**Create:** `nix/package.nix`, `vendor/termbox2-odin/termbox.odin`, `src/main.odin`

The Clay Odin binding resolves `foreign import Clay "linux/clay.a"` **relative to `clay.odin` itself** —
so the `clay-odin/<platform>/` layout must be reproduced exactly. Zero patching.
```nix
# nix/package.nix
{ lib, stdenv, odin, clay, clay-src, termbox2 }:
stdenv.mkDerivation {
  pname = "herdr-session"; version = "0.1.0";
  src = ../.;
  nativeBuildInputs = [ odin ];
  phases = [ "unpackPhase" "patchPhase" "buildPhase" "installPhase" ];
  patchPhase = ''
    mkdir -p clay-odin/linux
    cp ${clay-src}/bindings/odin/clay-odin/clay.odin clay-odin/clay.odin
    cp ${clay}/lib/libclay.a                     clay-odin/linux/clay.a
    mkdir -p vendor/termbox2-odin/lib
    cp ${termbox2}/lib/libtermbox2.a             vendor/termbox2-odin/lib/libtermbox2.a
  '';
  buildPhase  = 'odin build src -out:herdr-session -mode:release';
  installPhase = 'install -Dm755 herdr-session $out/bin/herdr-session';
  meta = { license = lib.licenses.asl20; mainProgram = "herdr-session"; };
}
```

**Add to `flake.nix` — Linux only (D6), and the package must be devenv-independent:**
```nix
packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system:
  let pkgs = import nixpkgs { inherit system; };
  in {
    default     = pkgs.callPackage ./nix/package.nix {
      clay        = pkgs.callPackage ./nix/clay.nix      { clay-src = inputs.clay; };
      clay-src    = inputs.clay;
      termbox2    = pkgs.callPackage ./nix/termbox2.nix { termbox2-src = inputs.termbox2; };
    };
    termbox2Lib = pkgs.callPackage ./nix/termbox2.nix { termbox2-src = inputs.termbox2; };
    clayLib     = pkgs.callPackage ./nix/clay.nix       { clay-src = inputs.clay; };
  });
```

**⚠️ Known trap:** `nix develop` / `nix flake show` **fail without `--no-pure-eval`** in this repo. The
package derivation must not touch devenv. Re-run `nix run .` after wiring this.

**Acceptance:**
- `nix build .#termbox2Lib` ✔
- `nix build .` produces a binary ✔
- `nix run .` executes it (any output — even immediate exit) ✔ ← *ISC-1*
- `nix flake show .` **fails** ⇒ the package must not be coupled to devenv; verify `nix build` still works

---

# PHASE 1 — Terminal layer + the handoff

*The handoff is the riskiest unverified assumption in the project. Do it here, with a dummy child,
long before herdr is involved.*

---

### T1.1 — termbox2 Odin foreign bindings

> **STATUS: ✅ DONE (2026-10-19).** `vendor/termbox2-odin/termbox.odin` is the real, complete binding.
> Every signature and constant was read out of the **pinned header in the nix store**
> (`/nix/store/…-source/termbox2.h`, rev `48cda6f8`, 4312 lines) — not from memory; line refs are in
> the file. **Risk-A1-adjacent ABI proof** (case 1 of `dev/handoff-smoke.sh`):
> ```
> [PASS] tb_wcwidth('A') == 1     got 1
> [PASS] tb_wcwidth(U+4E00) == 2  got 2
> [PASS] tb_attr_width() == 32    got 32 (TB_OPT_ATTR_W really built in)
> [PASS] tb_has_truecolor() == 1  got 1
> [PASS] Event struct is 24 bytes size_of(termbox2.Event) = 24
> ```
> **Confirmed upstream:** `typ/mod` u8 · `key` u16 · `ch` u32 · `w/h/x/y` i32 · `uintattr_t` is
> `uint32_t` at `TB_OPT_ATTR_W==32` (`:395-401`) · `TB_OUTPUT_TRUECOLOR == 5` (`:327`) ·
> `TB_KEY_ARROW_UP == 0xffff-18` (`:196`) · `TB_KEY_BACK_TAB == 0xffff-22` (`:200`) · `TB_MOD_*` =
> 1/2/4/8 (`:312-316`) · `tb_last_errno` **does** exist (`:739`) and is kept. Style bits live in the
> **high half** of the 32-bit word (`TB_BOLD == 0x01000000`); `TB_STRIKEOUT/UNDERLINE_2/OVERLINE/
> INVISIBLE` need bits above `0xffffffff`, so they exist only at attr width 64 and are **not bindable
> here**. No `TB_OPT_EGC` ⇒ `Cell` is 12 bytes.
>
> **Corrections to the sketch — each one learned by running it:**
> 1. ⚠️ **`tb_poll_event` / `tb_peek_event` return a `TB_*` status code, NOT the event type.**
>    `TB_OK` means "*`ev` is populated*"; the kind of event is `ev.typ`. (`wait_event`,
>    `termbox2.h:3461-3522`.) The sketch's `if rv == EVENT_KEY` can **never** be true — and it fails
>    silently, because a real key still fills the struct. Timeout is `TB_ERR_NO_EVENT`; `TB_ERR_POLL` and
>    `TB_ERR_READ` are retryable, not fatal. Documented at the declaration.
> 2. The sketch's `NAME : u8 = 1` is a **mutable variable** in Odin, not a constant — and it is then
>    unusable as a `switch` case or in `#assert`. Typed constants need `NAME :: u8(1)`; this binding
>    uses **plain untyped constants** (`KEY_ESC :: 0x1b`) for `#define` fidelity: they assign into
>    `u8`/`u16`/`i32` and compare against any width without a cast. `Attr` stays a typed alias because
>    colour arithmetic needs a definite width.
> 3. `size_t` is **not** a builtin in `pkgs.odin dev-2026-09` → `c.size_t` (`core:c`). Same for
>    `char` → `c.char`.
> 4. Upstream calls the field `type`; it is **`typ`** here. Offsets are identical and asserted
>    (`#assert(size_of(Event) == 24)`), so a layout drift breaks the build rather than garbling input.
> 5. Deliberately **not** bound: `tb_printf` / `tb_printf_ex` / `tb_sendf` (variadic C — we format in
>    Odin) and the header's own deprecated `tb_set_func` / `tb_cell_buffer`.
> 6. Build hygiene: `-vet` is now part of the package build (`nix/package.nix`) — it caught an unused
>    import that the default build passed silently.

**Create:** `vendor/termbox2-odin/termbox.odin`

**Exact ABI, verified from `termbox2.h` (do not guess — `ch` is 32-bit and `w/h/x/y` are `i32`):**
```odin
package termbox2

foreign import tb2 "lib/libtermbox2.a"

pub Event :: struct {
    typ : u8,     // TB_EVENT_*
    mod : u8,     // TB_MOD_*
    key : u16,    // TB_KEY_*
    ch  : u32,    // Unicode codepoint
    w, h : i32,   // resize
    x, y : i32,   // mouse
}

ATTR_W :: 32   // must match the -DTB_OPT_ATTR_W 32 used to build the .a
Attr   :: u32

EVENT_KEY    : u8 = 1
EVENT_RESIZE : u8 = 2
EVENT_MOUSE  : u8 = 3

KEY_CTRL_C    : u16 = 0x03
KEY_TAB       : u16 = 0x09
KEY_ESC       : u16 = 0x1b
KEY_ARROW_UP  : u16 = 0xffff - 18
KEY_BACK_TAB  : u16 = 0xffff - 22
OUTPUT_TRUECOLOR : i32 = 5

@(default_calling_convention = "c")
foreign tb2 {
    tb_init()             : i32 ---
    tb_shutdown()         : i32 ---
    tb_width()            : i32 ---
    tb_height()           : i32 ---
    tb_clear()            : i32 ---
    tb_present()          : i32 ---
    tb_hide_cursor()      : i32 ---
    tb_set_output_mode(mode: i32) : i32 ---
    tb_set_cell(x, y: i32, ch: u32, fg, bg: Attr) : i32 ---
    tb_peek_event(ev: ^Event, timeout_ms: i32) : i32 ---
    tb_poll_event(ev: ^Event) : i32 ---
    tb_get_fds(ttyfd, resizefd: ^i32) : i32 ---
    tb_wcwidth(ch: u32) : i32 ---
    tb_last_errno() : i32 ---
}
```
**Verify each against `/tmp/tb2_master.h` (or re-fetch upstream) before finalising** — signatures for
`tb_set_output_mode` (`:654`), `tb_set_cell` (`:515`), `tb_peek_event` (`:663`), `tb_get_fds` (`:672`).
Confirm `tb_last_errno` exists; if not, drop it and use `errno` from `core:sys/linux`.

**Acceptance:** compiles under `odin build`. `tb_wcwidth('A')==1`, `tb_wcwidth(0x4e00)==2` (print in a
throwaway `main` to prove the ABI isn't garbled).

---

### T1.2 — Handoff: leave the screen, run a child, come back, repaint

> **STATUS: ✅ DONE (2026-10-19) — risk A1 is retired empirically.** `src/terminal/handoff.odin`
> implements plan §Terminal handoff literally (steps 2-6; step 1 is the caller's contract, documented
> in the file header). Everything below was **run on a real pty**, captured by
> `BIN=… ./dev/handoff-smoke.sh` → **28 PASS / 0 FAIL**, typescripts kept under `/tmp/hs-smoke/`.
> ```
> 1 handoff -> sleep 2        child exit == 0, terminal reacquired, forced repaint ran (FRAMES_PAINTED=1)
>                           stty -a before == after: IDENTICAL  (termios round-tripped)
> 2 post-handoff input       a keypress is readable after the handoff: ch=106 (U+006A = 'j')
> 3 exit-code propagation   child `sh -c 'exit 7'`  ->  CHILD exit=7 killed_by=0
> 4 double round-trip       2x init/shutdown clean; 2nd init = TB_ERR_INIT_ALREADY (-3);
>                           2nd shutdown = TB_ERR_NOT_INIT (-8)
> 5 env scrub               our env: 7 HERDR_* vars  ->  child env: HERDR_VARS=0
>                           child kept TERM=xterm-256color COLORTERM=truecolor  (SemanticFrame intact)
> 6 no setsid / fg pgroup   SELF pid=547191 pgid=547188 sid=547188
>                           CHILD pid=547192 pgid=547188 sid=547188   (same pgid AND sid)
>                           child pwd=/home/alexfneves (explicit cwd, not our repo dir)
>                           child stdin=/dev/pts/15  (stdio INHERITED, still a tty)
> 7 SIGINT during the child's lifetime  (group-killed: `kill -INT -<pgid>`, exactly what the tty does)
>                           PARENT SigBlk=0x6  <- SIGINT|SIGQUIT blocked for us
>                           CHILD  SigBlk=0x0  <- cleared for the child
>                           CHILD_GOT_SIGNAL=2 -> child ran its handler, exit=42, we survived, stty IDENTICAL
> 8 SIGTERM / SIGHUP        exit=143 / exit=129, alt-screen-leave sequence reached the tty,
>                           stty before/after IDENTICAL  (our handler, not termbox2, did the restore)
> ```
> **Ordered pty byte stream** during a handoff (`dev/stream_order.py`) — proof that nothing of ours
> renders while the child owns the screen:
> ```
>        0  ENTER alt screen
>     1748  LEAVE alt screen  (terminal handed over to the child)
>     1958  child output while it owns the screen
>     2029  ENTER alt screen
>     2497  forced full repaint after re-entry
>     3798  LEAVE alt screen  (final shutdown)
> ```
> **Corrections / gotchas discovered — the next worker must respect these:**
> 1. ⚠️ **termbox2's `init_term_attrs` calls `cfmakeraw` (`termbox2.h:2910-2932`), which clears
>    `ISIG`.** So while termbox is up the tty produces **no SIGINT at all** — Ctrl-C arrives as byte
>    `0x03` → `TB_KEY_CTRL_C`. SIGINT only becomes a *signal* in the window after `tb_shutdown()`,
>    which is exactly what the block covers. Consequence: **ISC-12 ("Ctrl-C exits from all 7 states") is
>    a keymap job, not a signal handler** — do not go adding a SIGINT handler to get Ctrl-C.
> 2. **The child must have SIGINT/SIGQUIT explicitly un-blocked before `execve`.** The signal mask
>    survives *both* fork and execve, so blocking in the parent and forgetting the child side hands the
>    child a Ctrl-C-dead process. `child_pre_exec` clears exactly `HANDOFF_SIGNALS`.
> 3. **We cannot use `execvp()`.** It resolves PATH from the *inherited* `environ`, not our scrubbed
>    array — silently defeating the whole scrub. So `resolve_program()` does the PATH walk in the parent
>    and we call `execve()` with the scrubbed `envp`.
> 4. **`posix.execve` wants `[^]cstring`** — a pointer to the array. `out[0]` is the first *string*,
>    `&out[0]` is the argv. The type system catches this; worth knowing before you chase a segfault.
> 5. **Odin dynamic arrays are `[dynamic]T`** — `[..]T` is a hard syntax error in `dev-2026-09`.
>    `make([dynamic]cstring, n)` / `make([dynamic]T, 0, cap)` + `append` both work.
> 6. **Constant arrays are not addressable**: `HANDOFF_SIGNALS[:]` fails with "value is not addressable".
>    Take a stack copy (`owned := HANDOFF_SIGNALS`) and slice that — safe in the child too.
> 7. posix typing: `posix.errno()` is the `posix.Errno` enum (`posix.Errno.EINTR`, not `posix.EINTR`);
>    `result`-typed returns (`access`, `sigprocmask`, `raise`) compare against **`nil`** for success,
>    not `0`; signal members are `posix.Signal.SIGINT` / `.SIGQUIT` / `.SIGTERM` / `.SIGHUP`.
> 8. `os`: there is **no `os.getenv`** (`os.get_env_alloc(key, allocator)`), **no `os.write_file`**
>    (`os.open(path, {.Write,.Create,.Trunc})` + `os.write_string`), and the flag is `.Trunc` not
>    `.Truncate`.
> 9. Language surface hits (also apply to every later phase): **no `if x then a else b` expression**,
>    **`not` is not an operator** (use `!`), **no `var` keyword**, and `fmt` uses `{}`/`%v` — `{s}` and
>    `{v}` are printed literally, and mixing a `%X` verb into a `{}` string scrambles the argument order
>    (pre-format the hex separately).
> 10. ⚠️ **Nix landmine (bit us for ~15 min):** `nix build .` copies the **git tree** — HEAD plus the
>     *tracked*-dirty diff — so **untracked files are invisible to the build**. Symptom: the file is
>     plainly there in the editor, yet the build dies with
>     `Syntax Error: Path does not exist: ./terminal`, and the drv hash does not even change.
>     **`git add` new source files before `nix build`.** `lib.cleanSourceWith` cannot fix this: the
>     flake-self copy happens before our filter runs. (Same family as Phase 0's "fileset needs git-tracked
>     files" note.)
> 11. `odin build <some-package-dir>` fails with "Undefined entry point procedure 'main'" and this Odin has
>     **no `-build-library`** flag — build the whole `src` (or use `odin check`).
> 12. Step 6 is **enforced, not remembered**: `handoff_run` calls the installed `full_repaint` hook
>     itself, so a caller cannot forget it. `FRAMES_PAINTED` counts the calls, which is how the test
>     distinguishes "the rule is enforced" from "the rule is documented".

**Create:** `src/terminal/handoff.odin`

This is **plan §Terminal handoff** implemented literally. Test it with `sleep 2` before herdr exists.
```odin
package terminal

// Runs `child` with INHERITED stdio in the SAME foreground pgroup, then restores us.
// NO setsid — the child needs our controlling tty.
// NO self-SIGSTOP — a self-stopped process is not resumed by SIGCHLD.
handoff_run :: proc(argv: []string, cwd: string) -> (exit: i32, ok: bool) {
    // 1. stop rendering, then fully release the terminal
    termbox2.tb_shutdown()          // SGR0+CLEAR+?1049l+exit keypad/mouse+restore termios

    // 2. block signals that would reach us via the shared foreground pgroup
    unblock_int_quit_for_handoff()  // our own sigprocmask helper

    // 3. fork/exec with inherited stdio + explicit cwd
    pid = spawn_inherited(argv, cwd)  // posix.fork + execvp; child: chdir(cwd), dup2 of OUR 0/1/2

    // 4. wait
    status = posix.waitpid(pid, 0)
    exit   = extract_exit_code(status)

    // 5. re-acquire the terminal; FORCE full repaint (panic path skips resets)
    assert(termbox2.tb_init() == 0)             // reopens /dev/tty, tb_reset(), re-enters alt screen
    termbox2.tb_set_output_mode(termbox2.OUTPUT_TRUECOLOR)
    termbox2.tb_hide_cursor()
    resize_and_relayout()                       // re-read tb_width/height → clay.SetLayoutDimensions
    force_full_repaint = true

    restore_signals_after_handoff()
    return exit, true
}
```
**Required child env** (see plan §Verbatim rules 1): scrub `HERDR_ENV`, `HERDR_SOCKET_PATH`,
`HERDR_CLIENT_SOCKET_PATH`, `HERDR_SESSION`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`.
**Keep `TERM` and `COLORTERM`** (dropping them downgrades herdr to `TerminalAnsi` rendering).
Set child `cwd` explicitly to `$HOME` — a created session's `identity_cwd` is the spawner's cwd.

**Do this test manually and record the output** — A1 in the premortem is about exactly this:
```
1. start the app; it paints a box
2. press 'x' → handoff_run(["sleep","2"], $HOME)
3. during the 2s the app must not render
4. after: box is fully restored, no ghosting, no scrollback pollution, cursor hidden
5. also test: handoff_run(["false"]) → exit=1;  handoff_run(["kill","-TERM","<pid>","...]) → still restored
```

**Acceptance:** *ISC-9*, *ISC-10* pass with `sleep` as the dummy child, including the signal-killed path.
**This is the highest-value de-risking step in the whole project — do not defer it.**

---

# PHASE 2 — Renderer (Clay → cells)

*≈158 lines we own. This is where the two experiment defects that termbox2 can't fix get fixed.*

---

### T2.1 — `measure_text` backed by `tb_wcwidth`

> **STATUS: ✅ DONE (2026-10-19) — `src/render/measure.odin`.** 13 assertions in
> `BIN=… ./dev/render-smoke.sh` (case `measure`), **13 PASS / 0 FAIL**. Display
> columns, not bytes, not runes:
> ```
> "hello"        5 bytes,  5 runes ->  5 columns
> "hello world" 11 bytes, 11 runes -> 11 columns
> "世界"          6 bytes,  2 runes ->  4 columns   (East Asian Wide)
> "中a文b"       8 bytes,  4 runes ->  6 columns   (mixed)
> "é" (e+U+0301) 3 bytes, 2 runes ->  1 column    (combining mark is zero-width)
> "é̂n" (+U+0302) 6 bytes, 4 runes ->  2 columns   (stacking marks)
> "😀"           4 bytes,  1 rune  ->  2 columns   (emoji presentation)
> "a😀b"         6 bytes,  2 runes ->  4 columns
> ""             0 bytes,  0 runes ->  0 columns
> height == 1 cell per line;  glyph_columns == tb_wcwidth on all 22 sampled runes
> ```
> **Key decisions / gotchas:**
> 1. **1 Clay unit == 1 terminal cell.** `SetLayoutDimensions(cols, rows)` plus a
>    measurement fn that answers in columns/lines, so Clay's float boxes land on
>    the cell grid and the renderer only rounds, never scales.
> 2. **Height must be exactly 1.** Clay multiplies our height by its own wrapped-line
>    count (`Clay__CalculateWrappedText`); returning anything else inflates every
>    line of text in the layout.
> 3. Width is the **widest line**, not the total, so a multi-line slice doesn't
>    measure as all its lines laid end to end.
> 4. Width comes from `tb_wcwidth` — the *same table* `tb_present()` lays glyphs
>    out with. Measuring with anything else is how columns drift.
> 5. `proc "c"` here must be allocation-free: `utf8.decode_rune` + the helpers are
>    marked `proc "contextless"`, which makes the compiler reject any accidental
>    context/allocator use.
> 6. Combining marks measure 0 and are **not drawable** (termbox2 built without
>    `TB_OPT_EGC`); the renderer drops them, which keeps column arithmetic honest.

**Original task text (kept for reference):**

**Create:** `src/render/measure.odin`

```odin
package render

// Clay measure fn. Units = 1 terminal cell. MUST decode UTF-8 and sum DISPLAY width.
measure_text :: proc "c" (s: clay.StringSlice, cfg: ^clay.TextElementConfig, ud: rawptr) -> clay.Dimensions {
    w := i32(0)
    for _, r in utf8.decode_iterator(s.str) {
        cw := termbox2.tb_wcwidth(r)
        if cw < 0 { cw = termbox2.tb_wcwidth(0xFFFD) }   // non-printable → U+FFFD width
        w += cw
    }
    return clay.Dimensions{ f32(w), 1.0 }
}
```
**ANTI-PATTERN — do not repeat** (`tui_experiment/main.odin:202`):
```odin
return clay.Dimensions{ width = f32(text_slice.length), height = 1.0 }   // BYTES — wrong
```
Note `proc "c"` has **no Odin context** → no allocation inside. Decode-only, no `fmt`, no `strings.*` that allocates.

---

### T2.2 — Clay render-command → `tb_set_cell`

> **STATUS: ✅ DONE (2026-10-19) — `src/render/renderer.odin`.** 26 cell-level
> assertions + 11 wire-level assertions in `dev/render-smoke.sh` (cases `render`,
> `clip`), **37 PASS / 0 FAIL**. The driver reads termbox's **back buffer** back
> with `tb_get_cell(x, y, back=1, ..)` and asserts glyph + fg + bg against the
> geometry *Clay itself reported*.
> ```
> ┌──────────────────────────────────────────┐
> │HEADER                                    │   left at Clay's (1,1)
> │                                          │
> │──────────────────────────────────────────│   betweenChildren rule
> │              Body 中 😀 mix               │   centred + wide glyphs
> │                                          │
> │──────────────────────────────────────────│   betweenChildren rule
> │                                    FOOTER│   right-aligned
> └──────────────────────────────────────────┘
> border sides top=42/42 bottom=42/42 left=10/10 right=10/10
> clay centred x=15==want 15; right-aligned x=37==want 37
> wide glyph claimed its trailing cell (col 21, 25) with the glyph's own fg/bg; stats.claimed=3
> scissor: 75-col text in a 14-col box -> 0/318 cells painted past the right edge,
>          0/4440 painted below, col 13 painted / col 14 untouched
> wire: 38;2;255;60;60 · 38;2;220;220;220 · 38;2;60;200;120 · 48;2;16;20;28 and
>       NO 38;5; indexed-colour fallback anywhere in the pty typescript
> ```
> **Key discoveries — these were not predictable from the header:**
> 1. ⚠️ **`betweenChildren` is not geometry.** `BorderRenderData.width.betweenChildren`
>    only says a container *has* dividers. Clay emits each divider **later**, as its
>    own thin `Rectangle` command carrying the border's colour (clay.h:2852-2890).
>    So the Border handler registers a `Rule_Source{attr, thickness, interior}` and
>    the Rectangle handler recognises the thin rect and draws a ruled glyph instead
>    of a solid band. Dumping the stream first is what made this visible:
>    `Border (…) betweenChildren=1` then `Rectangle (0,3) 44x1`, `Rectangle (0,6) 44x1`.
> 2. ⚠️ **Those divider rectangles span the container's full width and erase the
>    border's own `│` glyphs.** Found by rendering: left/right sides came back
>    `─` at every divider row. Fix: `Rule_Source.interior` = the container box
>    inset by its own border lines, and the divider is clipped to it.
> 3. ⚠️ **`childGap` must be >= 2 for a 1-cell `betweenChildren` rule to land in
>    the gap.** With `childGap = 1` the rule lands on the *following child's row*
>    and paints over its text (observed: children at rows 0/2/4, dividers at 2/4).
>    The frame in Phase 5 must use `childGap >= 2`.
> 4. ⚠️ **`TextElementConfig.textAlignment` alone does not move x** — a TEXT
>    element fits its content, so there is nothing to align within. Alignment in a
>    cell grid comes from the **parent's `childAlignment`**, which then bakes a
>    *fractional* x (10.5, 14.5) into the command. One `round_cell`
>    (`floor(x+0.5)`) is used everywhere, or borders and text disagree about cell
>    boundaries.
> 5. **`Clay_Color` is 0..255 on all four channels, alpha included** (upstream
>    examples pass `a = 255`). Normalising to 0..1 paints the whole UI black.
> 6. **termbox2 truecolour: an attr with low-24-bits == 0 and no `TB_HI_BLACK`
>    means "terminal default"** (termbox2.h:3883). So literal black needs
>    `TB_HI_BLACK` or it silently renders as the default colour.
> 7. **`tb_clear()` fills cells with `' '` (0x20) and the current clear attrs, not
>    NUL** (termbox2.h:4113-4121). "Untouched cell" therefore cannot be tested as
>    `ch == 0`; the probe sets `tb_set_clear_attrs(sentinel_fg, sentinel_bg)` and
>    compares attrs.
> 8. **The scissor is one funnel.** Every write goes through `paint()`, which
>    enforces the clip; `ScissorStart/End` push/pop an intersected rect. Wide
>    glyphs may not straddle the clip's right edge (`col+width > clip.x+clip.w`).
> 9. Dispatch is a **total switch** (all ten command types listed, including the
>    explicit no-ops for `Image`/`OverlayColor*`/`Custom`/`None`), each with a
>    reason in the code, so a future Clay that adds a type fails the build instead
>    of dropping commands silently.
> 10. Overlay blending is **deliberately not implemented yet** (counted in
>    `stats.overlays`): hover/selection tinting is Phase 5's policy call, and the
>    place it lands is `paint()`, the same funnel.

**Original task text (kept for reference):**

**Create:** `src/render/renderer.odin`

**Must handle these command types — a `#partial switch` that silently ignores the rest is anti-pattern
`main.odin:842`:**

| `RenderCommandType` | Action |
|---|---|
| `Rectangle` | fill bounding box with the colour |
| `Border` | draw box-drawing glyphs from `BorderRenderData{color, cornerRadius, width}` — **including `width.betweenChildren`**, which is the spec's section-separator rule |
| `Text` | one TEXT command == one terminal row; `boundingBox.x` is the start column (Clay already wrapped) |
| `ScissorStart` / `ScissorEnd` | push/pop a clip rect. **Every draw must respect the clip stack.** Ignoring these paints clipped containers outside their bounds |
| `Image`, `OverlayColorStart/End`, `Custom`, `None` | no-op **explicitly** (documented, not accidental) |

**Selection / caret / truncation are app state, not Clay's** — pass them in via the frame struct; Clay
knows nothing about "selected".

**Wide-cell rule:** a 2-cell glyph must also claim the following cell (blank placeholder) or all column math
desyncs downstream.

**Acceptance:** a test tree of header/main/footer with `border = clay.BorderElementConfig{ width = clay.BorderAll(1) }`
renders the ruled lines described in the spec. *ISC-1* visually.

---

### T2.3 — Install a real Clay error handler

> **STATUS: ✅ DONE (2026-10-19) — implemented in `src/render/errors.odin`**
> (the plan named this `clay_error.odin`; it lives in `errors.odin` beside the
> rest of the render layer, so the "error" surface of `package render` is one
> file — rename only if that ever hurts). 13 assertions in `dev/render-smoke.sh`
> (case `clay-error`), **13 PASS / 0 FAIL**.
> ```
> before the frame                     total=0
> duplicate sibling id (clay.ID("dup-id") declared twice)
>   -> reported: "An element with this ID was already previously declared during this layout."
>      len=75, retained=2, kind=DuplicateId (mapped from ordinal 4)
> oversized message (672 bytes)        -> truncated to 211 <= cap 224, truncated=true, still readable
> unmapped ordinal (200)               -> kind=UnknownError  (degrades, does not mislabel or trap)
> unbalanced open (2x OpenElement, 0x CloseElement)
>   -> "There were still open layout elements when EndLayout was called…"  kind=UnbalancedOpenClose
> 40 further duplicate frames          -> retained=8 (window is 8), total=81, dropped=73
> ```
> **Key decisions / gotchas:**
> 1. **Clay's default handler is literally `(void) errorText;`** — every layout bug
>    is silently discarded. Installing ours is the whole point of this task.
> 2. **`proc "c"` = no Odin context = no allocator.** The handler composes
>    `"Kind: message"` byte-by-byte into a **static** fixed-size store and returns;
>    it is marked `proc "contextless"` so the compiler rejects any accidental
>    allocation/formatting. Draining (`errors_latest`, `errors_records`,
>    `errors_messages`) hands back *views* of that buffer — also allocation-free.
> 3. ⚠️ **`clay.odin`'s `ErrorType` enum is missing `clay.h`'s 10th member**
>    `CLAY_ERROR_TYPE_HASH_MAP_CAPACITY_EXCEEDED`. Switching on the *enum* would
>    mean handling a value the binding cannot name, so we keep the raw ordinal and
>    switch on `int` — unmapped values degrade to `UnknownError`.
> 4. **Retention is a bounded shift-left window** (`ERROR_RING_CAPACITY = 8`) with
>    `total`/`dropped` counters, so an error storm cannot grow memory *and* loss is
>    visible. (Bug caught while testing this: the shift forgot to decrement
>    `filled`, so the first eviction indexed past the array — now covered by the
>    "40 more frames" assertion.)
> 5. The store is `offset`/`length` based rather than holding string views, so
>    shifting records by value can never dangle.
> 6. **The unbalanced-open case needs TWO opens**: `Clay_EndLayout` closes one
>    element itself before checking `openLayoutElementStack.length > 1`
>    (clay.h:4448-4457), so a single leaked `OpenElement` is silently absorbed.

**Original task text (kept for reference):**

**Create:** `src/render/clay_error.odin`

`clay.Initialize(..., {})` installs a **no-op** handler, so duplicate ids / arena overflow / unbalanced
open-close are **silently swallowed** and the layout silently degrades. In a TUI you cannot `fmt` to
stderr (it corrupts the screen), and `proc "c"` cannot allocate — so write to a fixed buffer and surface later.
```odin
ClayErr :: struct {
    count    : int,
    last_msg : [256]u8,
    last_len : int,
}
clay_error_handler :: proc "c" (code: clay.ErrorType, desc: rawptr) {
    // NO allocation, NO fmt — proc "c" has no Odin context
    g.clay_err.count += 1
    copy(g.clay_err.last_msg[:], mem: string_to_bytes(desc))  // bounded copy
}
// ... clay.Initialize(arena, dims, clay.ErrorHandlerFunction{ clay_error_handler })
```
Surface `clay_err.count > 0` in the footer debug line and in `{Error}`.
**Budget the arena from `clay.MinMemorySize()` = 5,785,280 bytes (~5.5 MiB).**

**Acceptance:** deliberately open an element without closing it → the error is reported in-app, not silent.

---

# PHASE 3 — herdr integration

---

### T3.1 — `app/herdr.odin`: the single choke point

**Create:** `src/app/herdr.odin`

**Nothing else in the codebase may spawn herdr.** This file owns:

**a) env scrub** — *the launch-blocking requirement:*
```odin
SCRUB :: []string{ "HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH",
                  "HERDR_SESSION", "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID" }
// We run INSIDE herdr. Unscrubbed, EVERY create/attach fails:
//   "nested herdr is disabled by default" (exit 1).
// HERDR_ENV=0 is NOT a bypass — the PRESENCE is the trigger.
// KEEP TERM and COLORTERM — dropping them downgrades render encoding to TerminalAnsi.
scrub_env :: proc(base: map[string]string) -> map[string]string
```

**b) capture with stdout/stderr kept SEPARATE.** *Never* merge:
```odin
// exit 0  → parse STDOUT
// exit !=0 → parse STDERR for {"error":{"code","message"}}
// NEVER `2>&1` before a JSON parse — the Rust panic path also writes to stderr.
Capture :: struct { code: i32, out: []u8, err: []u8 }
run_capture :: proc(argv: []string, timeout: duration) -> Capture
```

**Exit-code contract:** `0` ok · `1` herdr error (stderr JSON) · `2` CLI syntax/validation ·
`101` tty-init panic (Rust panic, **not** JSON) · `124` our timeout · `127` no herdr on remote ·
`255` ssh transport/auth. Map each to a distinct `{Error}` string.

**c) name validation** — `^[A-Za-z0-9._-]+$`, non-empty, not `.`/`..`, never `default`.

**d) `cleanup_policy` seam (D2 PARKED):**
```odin
CleanupPolicy :: enum { never, only_created, always }
DEFAULT_CLEANUP: CleanupPolicy = .never   // PARKED pending latest-herdr behaviour. Nothing destroyed.
// Rationale: `prefix+q` only DETACHES — the server and panes keep running. Auto-destroying a session
// the user merely peeked at is data loss. Revisit when the user's box runs latest herdr.
```

**Acceptance:** unit-testable outside the TUI. `scrub_env` on the real `os.environ` returns a map with
**no `HERDR_*` keys but with `TERM` present**. *ISC-2*.

---

### T3.2 — Timestamp parsed from the session name (D3)

**Create:** in `src/app/model.odin`

```odin
// herdr provides NO timestamp anywhere — verified: not in `session list --json`, not in session.json.
// Our created names follow herdr-cycle's format (herdr-cycle.sh:28,137):
//   bare new session : %Y-%m-%d-%H-%M-%S-%3N
//   named new session: "<typed>-<timestamp>"
parse_ts_from_name :: proc(name: string) -> ?time.Time
// match the trailing  YYYY-MM-DD-HH-MM-SS-mmm  group
// non-matching name  →  null  →  display "—"  →  sorted LAST within its device group
```
This gives us the timestamp column with **zero extra stat / ssh round-trips**.

**Acceptance:** `"api-2026-10-18-20-30-45-123"` → parses; `"mydb"` → null → `—`.

---

### T3.3 — Local session list → model

**Create:** `src/app/model.odin`

```odin
Session :: struct {
    device : string,   // "local", or the VERBATIM configured ssh target string
    name   : string,
    running: bool,     // from --json: a LIVE socket connect-probe, not a file check
    ts     : ?time.Time,
    label  : string,   // device display label
}
// Identity is (device, name) — NEVER name alone. Names are scoped per (host, unix-user)
// and herdr output has NO host field.
Key :: proc(s: ^Session) -> (string, string) { return (s.device, s.name) }

// Parse `herdr session list --json` → {"sessions":[{default,name,running,session_dir,socket_path}]}
// NEVER parse the plain-text form — its columns are misaligned.
// FILTER OUT default:true entirely (D12 — herdr refuses to delete it).
```
**Acceptance:** running from inside this herdr pane, `local` rows appear for the two live sessions
(`2026-08-11-…`, `2026-08-30-…`) and **`default` is absent**. *ISC-18*.

---

### T3.4 — Remotes from `herdr machine list --json`, with fallback (D1)

**Create:** `src/app/remotes.odin`

```odin
// herdr 0.9.x only. Our TUI ONLY READS the registry — `machine add` needs an interactive
// terminal and stays the user's job.
Remote :: struct { id: string, label: string, ssh_target: string }
// device  = ssh_target VERBATIM. Normalising to FQDN/hostname BREAKS the --remote return path.
// display = label (else the ssh target)

// ⚠️ FEATURE DETECTION MUST NOT USE THE EXIT CODE.
// On herdr 0.8.2, `herdr machine list` prints the help banner with EXIT 0.
// Gate on JSON SHAPE instead:
detect_machine_list :: proc() -> bool {
    c := herdr.run_capture([...]string{"herdr","machine","list","--json"}, 5*time.Second)
    if c.code != 0 { return false }
    return parses_as_expected_shape(c.out)   // object with a machine array
}
// Fallback chain: machine registry  →  our config `remotes = [...]`  →  ~/.ssh/config Host stanzas
```
**Note:** `--machine` does **not** forward `session` commands, and `herdr --remote X session list` is
exit 2. Remote session enumeration is always our own `ssh -T` (T4.1).

**Acceptance:** on this box (0.8.2, no `machine` verb) the shape gate correctly returns `false` and the
config fallback supplies the list. *ISC-20*. Footer debug line shows **which path was taken**.

---

# PHASE 4 — Parallel fetch fan-out (no threads)

---

### T4.1 — ssh children as the async mechanism

**Create:** `src/app/fetch.odin`

**There is no thread pool and no `core:thread` in this design.** Every fetch is already an OS process;
the ssh child's stdout becoming readable **is** the async wake event.
```odin
DeviceState :: union {
    Pending,
    Ok,
    TimedOut, Unreachable, NoHerdr, AuthFailed, Unknown,
}

Fetch :: struct {
    device   : string,   // verbatim ssh target
    pid      : posix.pid_t,
    pipe_fd  : i32,      // read end, O_NONBLOCK — added to poll()
    buf      : []u8,
    deadline : time.Time, // ConnectTimeout + 8s backstop
}

// spawn: ssh -T -o BatchMode=yes -o ConnectTimeout=5 <device> 'herdr session list --json'
//   -T  (NOT -t): ~20ms faster, no stderr chatter, stdout stays pure JSON
//   ConnectTimeout=5 + BatchMode=yes are MANDATORY.
//   Without them a black-holed host hangs 133 SECONDS. With them auth fails in ~119ms.
//   ssh's own chatter goes to stderr → never merge into the JSON parse.
```
**Main loop integration** — one `poll()` over everything:
```
poll( ttyfd, resizefd, *fetch_pipe_fd )
  fetch pipe readable → read → EOF → waitpid(WNOHANG) → parse STDOUT ONLY
       → merge rows → device: Pending → Ok
  deadline exceeded  → SIGKILL child → device: TimedOut
```
A host's error degrades **only that host's row group**. The app never blocks on a host. *ISC-14*, *ISC-15*.

**ANTI-PATTERNS:** no `core:thread`, no mutexes, no self-pipe for fetches, no `O_NONBLOCK` +
`sleep(16ms)` idle spin. *ISC-A-2*, *ISC-A-6*.

**Acceptance:** with two configured hosts (one real, one black-hole like `10.255.255.1`), the UI paints
local instantly, one host goes `Ok`, the other goes `TimedOut` at ~5 s, and the UI stayed responsive
throughout. *ISC-6*, *ISC-14*.

---

### T4.2 — Identity-preserving merge

**Create:** in `src/app/fetch.odin`

```odin
merge :: proc(app: ^App, device: string, fetched: []Session)
// keyed by (device, name)
// Sort: (device != "local", device, ts)   ← local always first, then host, then timestamp
```
**⚠️ Two merge rules that index-based logic breaks:**
1. **Selection is tracked by identity `(device, name)`, never by index.** A remote fetch landing while
   the user has row 2 selected inserts rows above it — index selection silently jumps to a different
   session and the next `Enter` targets the wrong one.
2. Filter text and caret position survive a merge untouched. Fetches mutate the **model only**; the view
   re-resolves identity after every merge.

**Acceptance:** select a local row, then let a remote fetch land rows above it → the same session is still
highlighted, and `Enter` attaches the same session. *ISC-4*.

---

# PHASE 5 — UI + state machine

---

### T5.1 — Frame: Header / Main / Footer with ruled borders

**Create:** `src/ui/frame.odin`

```odin
// Root: TopToBottom, SizingFixed(cols) x SizingFixed(rows)  — fills all available space
//   Header  SizingFixed(1)  + border between children
//   Main    SizingGrow({})  + border between children
//   Footer  SizingFixed(1)
// Use clay.BorderElementConfig{ width = clay.BorderWidth{ ... betweenChildren = 1 } }
// for the inter-section rules the spec asks for.
// ANTI-PATTERNS: no hand-painted box glyphs outside Clay's knowledge (main.odin:887-893);
// no backgroundColor.alpha used as a pane-id tag (main.odin:768) — use
// clay.GetElementData(id).boundingBox for geometry.
```
**Acceptance:** the spec's ASCII layout reproduced: outer border + a rule between each section.

---

### T5.2 — Sessions view: filter line + scrollable table

**Create:** `src/ui/sessions.odin`

Columns: **device**, **timestamp**, **state** (running/stopped), **name** — fixed `SizingFixed(n)` per
column, truncation applied by **us** (Clay's `textAlignment` does not truncate). Scroll with
`clip = clay.ClipElementConfig{ vertical = true, childOffset = ... }` — **app-managed** offset
(keyboard-driven; pixel offsets are meaningless at cell granularity).
Selection highlight = draw from app state at render time.

**Acceptance:** filter starts empty and filters rows live; scroll keeps the selection on screen; on
shrink the selection is re-clamped and never lost.

---

### T5.3 — Single edit + Filtered list + floating error pane

**Create:** `src/ui/edit.odin`, `src/ui/list.odin`, `src/ui/float.odin`

- **edit**: caret is a **display column**, derived from the display width of the prefix — *never* a byte
  offset. Backspace deletes a whole rune (`utf8.decode_last_rune_in_string`). Paste is sanitized — strip
  control chars and embedded escapes before inserting.
- **list**: shared component for the theme picker and remote picker. Up/Down/Tab/Shift+Tab move, typed
  chars filter, `Enter` selects (no selection → **no-op**, per spec).
- **float**: `floating = clay.FloatingElementConfig{ attachTo = .Root, zIndex = N }` for the error pane.
  Dismissed by `Enter`/`Esc`.

**Acceptance:** typing/pasting CJK and emoji never desyncs the column layout.

---

### T5.4 — State machine returns Commands; it performs no side effects

**Create:** `src/app/state.odin`

```odin
State :: enum { mode_selection, name_local, remote_server, name_remote_named,
               attach, delete_session, theme, error }

Command :: union {
    None,
    LaunchLocal   : LaunchSpec,
    LaunchRemote  : LaunchSpec,
    Attach        : LaunchSpec,
    Delete        : DeleteSpec,
    SetTheme      : string,
    ShowError     : string,
    ClearFilter, ClearField,
    GotoState     : State,
    Quit,
}

update :: proc(app: ^App, k: input.Key) -> Command
```
Transition table = **plan §State transitions**. Note the resolved spec inconsistency: **`[s]` collects the
name first, then the server** (2 steps) — `[s]`→`name_remote_named`, `Enter`→`remote_server`,
`Enter`→`LaunchRemote`.

**Acceptance:** scripted key-sequence test covering all 7 states + the `[s]` two-step. *ISC-3*.

---

### T5.5 — Executor: launch / attach with validation

**Create:** in `src/main.odin`

**Two hard requirements, both verified failure modes:**
1. **Never attach to an unvalidated name.** A crashed-on-tty-init attach **still creates** a live orphan
   session (the server spawns before terminal init). Check the target against the currently-loaded model first.
2. **`delete` lies.** Unknown name → `exit 0` + `{"deleted":true}`. Pre-check existence in the model;
   if running, `stop` then `delete` (parity with `herdr-cycle.cleanup_session`). Never offer `default`.

Launch argv:
```
local  new   : herdr --session <name>
local  attach: herdr session attach <name>     # CREATE-OR-ATTACH — hence the validation above
remote new/attach: herdr --remote <device-verbatim> --session <name>
   → use `herdr --remote` (herdr owns ssh multiplexing/keepalive/config), NOT hand-rolled ssh
   → caveat: no way to pass a custom -F, so the device string must resolve via default ~/.ssh/config
child cwd = $HOME  (created session's identity_cwd = spawner cwd)
env = scrub_env(os.environ)   ← see T3.1
then: terminal.handoff_run(...)   ← see T1.2
```
**Acceptance:** *ISC-5*, *ISC-16*, *ISC-17*. Attempting to attach a name that is not in the model is
**refused in-app** and creates nothing.

---

# PHASE 6 — Config, themes, and final verification

---

### T6.1 — JSON config via `core:encoding/json`

**Create:** `src/app/config.odin`

**D13: JSON — this removes the TOML dependency entirely. No `Up05/toml_parser`, no hand-rolled TOML.**
File: **`~/.config/herdr_session.json`** (the spec said `.toml`; renamed by this decision).
```odin
Config :: struct {
    theme   : string,          // default "gruvbox-dark"
    remotes : []RemoteCfg,     // fallback remote list
    // cleanup_policy omitted while D2 is parked; add later, defaulting to "never"
}
// Path via Odin stdlib XDG — verified resolves $XDG_CONFIG_HOME/herdr_session.json
dir, cerr := os.user_config_dir(context.allocator)
path    , _  := os.join_path({dir, "herdr_session.json"}, context.allocator)
```
**Corrupt / missing / unknown-theme must not brick the app:** fall back to defaults + surface one warning
line in the footer. *ISC-19*.
Saving writes **only the keys we own** — never silently clobber a hand-edited file.

**Acceptance:** absent file → defaults; `{ "theme": "nonsense" }` → `gruvbox-dark` + warning, app starts.

---

### T6.2 — Compiled-in palettes from terminalcolors.com, `gruvbox-dark` default

**Create:** `src/app/theme.odin`

**Machine-readable source (verified):** `https://terminalcolors.com/downloads/alacritty/<theme>.toml`
returns `colors.primary{foreground,background}`, `colors.cursor`, `colors.selection`, `colors.normal{8}`,
`colors.bright{8}` — e.g. gruvbox-dark `background #282828 / foreground #ebdbb2 / normal.red #cc241d …`
Fetch at **author time** and emit an Odin table; no runtime TOML.

Ship: **`gruvbox-dark` (DEFAULT)** + `catppuccin-latte` (required, explicitly *not* default) +
`catppuccin-mocha`, `nord`, `solarized-dark`, `solarized-light`, `tokyo-night`, `dracula`, `one-dark`,
`gruvbox-light`. Extend later.
**`catppuccin-latte` ships with the canonical spelling** (the user typed "catputin"); add an alias list for
forgiving filtering rather than a wrong canonical name.
Clay `Color` is `[4]c.float` in **0–255**, not 0.0–1.0. Map hex directly.
Requires `tb_set_output_mode(TB_OUTPUT_TRUECOLOR)` and `TB_OPT_ATTR_W 32` (see T0.1) or every colour is
quantised.

**Acceptance:** *ISC-8*. Picking a theme repaints every element and persists across restart.

---

### T6.3 — ⭐ The acceptance test the loopback fixture CANNOT satisfy

**Create:** `dev/device-discriminator.md` (+ any scripted helpers under `dev/`)

> A bug that ignores the `device` field passes **every** `localhost` test, because here local and remote
> are literally the same install. This todo exists to make that bug impossible to ship.

**Cheap discriminator — no second physical host required.** Register the *same machine* under **two
distinct ssh target strings**, `localhost` and `127.0.0.1`, so the underlying sessions are byte-identical
but the device strings differ.

| Check | Passes only if |
|---|---|
| Both appear as **separate rows** for the same session name | key is genuinely `(device, name)`, not `name` |
| Filtering by device shows both distinctly | device is carried into the view model |
| Attaching via the `127.0.0.1` row puts **`127.0.0.1`** in the `--remote` argv — not the alias, not the FQDN | device string is verbatim through the round trip |
| Deleting one leaves the other's row intact | merge/dedup is identity-correct |

**Stronger variant when available:** two unix users on the same box → different session namespaces under
the *same* device string (discriminates user scoping).

**Record the actual command transcripts in the todo's acceptance output.** This is a
**manual / non-fixture** verification and must be labelled as such.

---

### T6.4 — Test-fixture isolation: grep-removable in one action

**Create:** `dev/test-remote.md` (the ONLY place the fixture may appear)

Per the user's constraint: `localhost` is a **temporary dev/CI fixture**, not a product feature.
```
grep -rn 'localhost\|127\.0\.0\.1' src/      → MUST return NOTHING in product code
```
The test remote arrives **only** via `HERDR_SESSION_TEST_REMOTE` or the single labelled `dev/` file.
Deleting that one file / unset that one env var leaves remote support **intact and fully generic**.

**Fixture safety:** never create/attach against the fixture with a name resembling the live session
(this session runs inside `HERDR_SESSION=2026-08-11-23-37-41-812`). Use `hs-t-*` scratch names only and
`stop` + `delete` them afterwards; **prove cleanup** in the acceptance output
(`herdr session list --json` back to pre-existing state).

**Acceptance:** *ISC-A-3*. `grep -rn 'localhost' src/` empty; `dev/` removable in one action.

---

### T6.5 — Resize: coalescing + "too small" state

**Create:** `src/terminal/resize.odin` (or fold into T1.2)

```
SIGWINCH → termbox2's handle_resize() writes the self-pipe (async-signal-safe, errno preserved)
         → poll() wakes on resizefd from tb_get_fds()
         → tb_poll_event() == TB_EVENT_RESIZE{w,h}   [already ran resize_cellbufs():
              back+front resized, FRONT CLEARED, send_clear() ⇒ guaranteed full repaint]
         → clay.SetLayoutDimensions(cols, rows)      ← MUST precede clay.BeginLayout()
         → re-describe → EndLayout → renderer → tb_present
```
**⚠️ THE ONE WAY TO BREAK IT: if our `poll()` set omits `resizefd` and includes only the tty fd, a
resize is never noticed until the next keypress.** Named acceptance test below.

Ours regardless of termbox2: recompute visible row count · keep the selected session selected (clamp) ·
scroll so selection isn't off-screen after shrinking · recompute column truncation · **"too small"**
message under ~40×10 · **coalesce** a window-border drag flood into one layout per frame.
Also handle `TB_ERR_POLL`/`EINTR` by looping rather than erroring.

**Acceptance:** *ISC-13* — resize the window with **no further key input** → the screen updates within one
frame. Then drag the border continuously → no repaint storm, no flicker, selection preserved.

---

### T6.6 — Final anti-criteria sweep + README

**Create:** `README.md`; run the sweep.

```
grep -rn '2>&1'                      src/   → nothing before a JSON parse        (ISC-A-1)
grep -rn 'core:thread'               src/   → nothing                          (ISC-A-6)
grep -rn 'time.sleep'                src/   → no idle-spin sleep in the loop   (ISC-A-2)
grep -rn 'localhost\|127\.0\.0\.1'  src/   → nothing                          (ISC-A-3)
grep -rn 'toml'                      src/ nix/ → no TOML parser dependency    (ISC-A-5)
grep -rn '\[>1u\|kitty'              src/   → no Kitty protocol              (ISC-A-4)
grep -rn 'tui_experiment'            src/   → no copied code                  (ISC-A-7)
grep -rn 'backgroundColor.*alpha'    src/   → no alpha-as-identity hack       (ISC-A-8)
git ls-files | grep -E '\.(a|lib|o)$'      → no committed prebuilt blobs     (ISC-A-9)
```
README: what it is, key bindings table, `~/.config/herdr_session.json` schema, how to add a remote,
how to change theme, and **how to replace `herdr-cycle`** — one line in
`~/.config/home-manager/modules/editors/alacritty.nix`:
`terminal.shell.program = "<herdr-session>";`

**Acceptance:** every grep above clean; ISC checklist walked end-to-end.

---

## Sequencing

```
T0.1 → T0.2                    ← toolchain risk retired; `nix run .` works
  → T1.1 → T1.2                ← HANDOFF proven with a dummy child (highest-value de-risking)
  → T2.1 → T2.2 → T2.3         ← renderer
  → T3.1 → T3.2 → T3.3 → T3.4 ← herdr integration
  → T4.1 → T4.2                ← parallel fan-out
  → T5.1 → T5.2 → T5.3 → T5.4 → T5.5
  → T6.1 → T6.2 → T6.5 → T6.3 → T6.4 → T6.6
```
`nix build` must stay green at every arrow. **Do not reorder T1.2 later** — it is the assumption the whole
plan rests on (premortem **A1**) and it is cheapest to validate before feature work exists.
