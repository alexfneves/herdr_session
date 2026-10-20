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

> **STATUS: ✅ DONE (2026-10-19) — `src/app/herdr.odin`.** Every herdr invocation in
> the product goes through `run_capture` (captured, non-interactive) or the T1.2
> handoff (interactive); nothing else spawns herdr — enforced by the grep in
> `dev/app-smoke.sh` §3 (*"herdr" is named only by `src/app/herdr.odin`*).
> **214 PASS / 0 FAIL** (`BIN=./result/bin/herdr-session ./dev/app-smoke.sh`),
> 133 of them unit + 59 live against the real 0.8.2 binary.
>
> **a) env scrub** — reuses `terminal.build_scrubbed_env` (T1.2), prefix-based on
> `terminal.HERDR_NAMESPACE`, never re-implemented. Proven at the level that
> matters — what the **child** reports:
> ```
> our own env: HERDR_ENV="1" HERDR_SESSION="2026-08-11-23-37-41-812" (nesting is live here)
> [PASS] child sees NO HERDR_* variable   leaked=[]
> [PASS] child still has TERM             TERM=xterm-256color
> ```
> The **differential** that makes the scrub load-bearing rather than decorative
> (case `app-live`):
> ```
> scrubbed   `herdr --session hs-t-phase3-probe` → exit 101   (nesting never fired; died later on the absent tty)
> injected   HERDR_ENV=1 `herdr --session …`     → exit 1     "error: nested herdr is disabled by default."
> ```
>
> **b) capture with the streams kept APART.** `Capture{code,out,err,timed_out,spawned,argv}`;
> child's stdout→pipe A, stderr→pipe B (never dup2'd onto each other), both drained
> non-blocking under a deadline, then reaped with `WNOHANG`. The stream choice lives
> in **one** function so ISC-A-1 is structural, not a habit:
> ```
> [PASS] stdout holds ONLY the stdout marker   stdout="STDOUT_ONLY\n" (12 bytes)
> [PASS] stderr holds ONLY the stderr marker   stderr="STDERR_ONLY\n" (12 bytes)
> [PASS] payload came from stderr, not stdout  payload=errjson        (exit 1 child)
> [PASS] no merged streams before a JSON parse (ISC-A-1) — src/app, src/render, src/terminal, main.odin
> ```
> **Exit-code contract, all 8 codes distinct** (`eq "all 8 exit codes map to distinct meanings" 8`)
> and each reproduced live where reproducible:
> ```
   0 ok · 1 herdr error (stderr {"error":{"code":"session_stop_failed",…}}, stdout 0 bytes)
   2 bad command line (unknown subcommand) · 101 terminal-init panic (ratatui init.rs:299, NOT JSON)
   124 ours (`sleep 30` under a 400 ms budget → returned in 402 ms, reaped)
   127 no herdr there · 255 ssh transport/auth (ssh to 192.0.2.201 → exit 255)
> ```
>
> **c) name validation** — `^[A-Za-z0-9._-]+$`, non-empty, not `.`/`..`, never
> `default`, ≤ `NAME_MAX_LEN` (64). 15 cases incl. colon, slash, `$`, space, non-ASCII.
> Every builder returns **no argv at all** on an invalid name:
> ```
> [PASS] invalid name "bad:name" produces no launch/attach argv   launch_ok=false attach_ok=false
> [PASS] delete of `default` is refused by name (D12)
> ```
>
> **d) `cleanup_policy` seam** — `Cleanup_Policy{never, only_created, always}`,
> `DEFAULT_CLEANUP_POLICY = never` (D2 **still parked**). Settable at runtime, so
> un-parking is one assignment; `default` is refused under **every** policy.
>
> **New traps found (not in the header):**
> 1. ⚠️ **`HERDR_ENV=0` is NOT the documented "presence is the trigger".** Re-run
>    today: `HERDR_ENV=1` → exit 1 nesting refusal, but `HERDR_ENV=0` **walks past
>    the nesting check** and dies later on the tty (101). The header's claim is only
>    true for a truthy value. Consequence: never rely on setting `HERDR_ENV=0` —
>    remove the whole namespace (which is what `build_scrubbed_env` does), because
>    that is correct whatever herdr's truthiness rules are.
> 2. ⚠️ **`execvp` searches PATH with the inherited env.** Resolve the program in
>    the **parent** (`terminal.resolve_program`) before swapping in the scrubbed
>    env, or the scrub is silently defeated (same lesson as T1.2, re-verified here).
> 3. ⚠️ **A timeout that closes the pipes but never reaps is a zombie factory.**
>    `run_capture` SIGKILLs at the deadline **and** reaps on a bounded
>    `WNOHANG` spin, so a killed probe cannot outlive the call.

### T3.2 — Timestamp parsed from the session name (D3)

> **STATUS: ✅ DONE (2026-10-19) — `src/app/model.odin` (`ts_from_name`).**
> Parsed out of the **name**, so the timestamp column costs **zero extra `stat`
> and zero extra ssh round-trips**. Fixed-width positional check (`TS_SUFFIX_LEN=23`,
> dashes at 4/7/10/13/16/19) plus `time.components_to_time` for calendar validity —
> never a regexp.
> ```
> [PASS] bare cycle ts parses                 2026-10-18-20-30-45-123 → 2026-10-18 20:30:45.123
> [PASS] named cycle ts parses                api-2026-10-18-20-30-45-123 → 2026-10-18 20:30:45.123
> [PASS] no ts -> em dash                    mydb → —
> [PASS] no separator -> em dash             mydb2026-10-18-20-30-45-12 → —
> [PASS] wrong width -> em dash              2026-10-18-20-30-45-12 → —
> [PASS] impossible calendar date → em dash  2026-13-45-99-99-99-000 → —  (no silent rollover)
> [PASS] feb 30 -> em dash                   2026-02-30-12-00-00-000 → —
> [PASS] ts ascending, unknown last within group
>        a-2026-10-17…, b-2026-10-18…, aaa-no-ts, zzz-no-ts
> ```
> `format_cycle_timestamp` is the **same** implementation the parser reads back,
> so the D11 names we generate round-trip; `new_session_name(prefix, taken)`
> regenerates on collision (3 generated, 0 collisions).
>
> **Deviation, forced by the toolchain:** the header writes `-> ?time.Time`. This
> Odin has **no `?T`** — `#maybe` was merged into `union` upstream. `Ts :: union
> {time.Time, Unknown_Timestamp}` is the equivalent, and turned out better: the
> unknown case is a *type*, so every consumer must handle it, and the sort
> sentinel is `I64_MAX` (a `0` sentinel would sort "—" **above** real sessions).

### T3.3 — Local session list → model

> **STATUS: ✅ DONE (2026-10-19) — `src/app/model.odin` (`Session`, `Key`,
> `parse_session_list`).** Reads `--json` only; `default` is dropped **inside the
> parser**, so no caller can offer one.
> ```
> raw stdout: {"sessions":[{"default":true,"name":"default",…}, …]}  (644 bytes)
> [PASS] list parses   2 rows
>   row device=local name=2026-08-11-23-37-41-812 running=true ts=2026-08-11 23:37:41.812
>   row device=local name=2026-08-30-14-59-10-730 running=true ts=2026-08-30 14:59:10.730
> [PASS] NO row is `default` (D12)
> [PASS] every row carries device=local
> ```
> *ISC-18* satisfied from inside a real herdr pane. Identity is the **pair**:
> ```
> [PASS] three rows survive because device differs      workbox/api, homebox/api, local/api
> [PASS] local/api is found by (device,name)  got 2 · workbox/api got 0 · homebox/api got 1
> [PASS] a device the model does not know is NOT found  — identity is the pair, not the name
> [PASS] local first, groups contiguous, ts ascending inside each   local/alpha/zeta/zeta/
> ```
> Degradation is tested payload by payload: 6 malformed bodies (plain text, empty,
> `"sessions":"nope"`, `[1,2,3]`, an ANSI banner) each return `ok=false` **and
> no rows** — an unexpected payload costs that device its group, never the app.
> Forward-compatible: unknown extra JSON keys are ignored, not fatal.
>
> **New traps found:**
> 1. ⚠️ **Filter `default` on the FLAG, not the name.** A
>    `{"default":true,"name":"weird"}` entry is still filtered — asserted.
> 2. ⚠️ **`running` is a live connect-probe, not a file check.** Pass it through
>    verbatim; never re-derive it from the presence of a socket file.

### T3.4 — Remotes from `herdr machine list --json`, with fallback (D1)

> **STATUS: ✅ DONE (2026-10-19) — `src/app/remotes.odin`.** Read-only registry
> consumer + shape gate + config fallback. *ISC-5 / ISC-16 / ISC-17* are covered
> by the delete pre-check and the in-app refusal in `herdr.odin`, both proven
> live (see T3.1's evidence block).
>
> **The gate is a JSON-shape check, not an exit-code check** — asserted both ways:
> ```
> [PASS] 0.8.2 'unknown command' text → NO registry
> [PASS] help banner with exit 0 is NOT a registry        (the trap this exists for)
> [PASS] object with machines array → registry            (shape alone)
> [PASS] object WITHOUT a machines array → no registry
> [PASS] gate decision is made on shape, independent of the exit code   exit=2 shape=false
> ```
> Precedence and the VERBATIM rule:
> ```
> [PASS] device string is never normalised   Alice@Work.Box.Example:2222 stays byte-for-byte
> [PASS] registry wins as the source; its label wins over the config label
> [PASS] local is never in the remote list   (the local group is implicit in the table)
> [PASS] registry + config merge, deduped on the device string
> [PASS] empty registry → config fallback
> [PASS] the fetch uses the device string verbatim in argv
>        ssh -T -o BatchMode=yes -o ConnectTimeout=5 <device> 'herdr session list --json'
> ```
> Live against the fixture (`HERDR_SESSION_TEST_REMOTE=localhost`), rows parsed with
> the remote as `device`, `default` filtered there too:
> ```
> remote row device=localhost name=2026-08-11-23-37-41-812 running=true ts=2026-08-11 23:37:41.812
> [PASS] every remote row carries the remote device, not 'local'
> [PASS] `default` is filtered from the REMOTE list too (D12 applies everywhere)
> ```
> **Device-discriminator preview (T6.3)** — the same machine reached by TWO target
> strings, which is the only way to catch a name-keyed model on one box:
> ```
> [PASS] the two targets really do reach identical sessions (only `device` differs)
> [PASS] identical names stay DISTINCT rows (device is part of the key)   got 6 want 6
> [PASS] an alias-scoped identity survives independently of the primary target
> [PASS] launch argv keeps the primary target verbatim    herdr --remote localhost --session …
> [PASS] launch argv keeps the alias target verbatim      herdr --remote 192.168.0.45 --session …
> ```
>
> **Corrections to this todo's own text (both re-verified today):**
> 1. ⚠️ The header says *"on herdr 0.8.2 `machine list` prints the help banner
>    with EXIT 0."* **It does not.** The installed 0.8.2 answers
>    `unknown command: machine` / `run 'herdr --help' for usage` with **exit 2**,
>    empty stdout. The shape gate is still the right defence — and the exit-0
>    help-banner case is asserted separately so it stays covered if a future build
>    behaves the way the header described.
> 2. The sample `detect_machine_list` reads the exit code first. **Implemented as
>    `machine_registry_available(payload) -> bool`** taking *bytes, not a Capture*,
>    so a caller cannot accidentally reintroduce a code-based gate.
> 3. `Remote :: struct {id, label, ssh_target}` → implemented as
>    `Remote{device, label}`, with the registry read generously
>    (`ssh_target` → `host` → `name` → `alias`) because no contract fixes those
>    field names and the build here has never shipped the registry. `id` is
>    accepted but is **never** an identity: `device` is the only key.


# PHASE 4 — Parallel fetch fan-out (no threads)

---

### T4.1 — ssh children as the async mechanism ✅ DONE

**Evidence (fixture armed: `HERDR_SESSION_TEST_REMOTE=localhost`, `_ALIAS=127.0.0.1`,
`_UNREACHABLE=192.0.2.201`; every number below is captured output, not a claim).**

Created `src/app/fetch.odin` (registry + spawn/drain/reap + status mapping + merge),
`src/fetch_cases.odin` (67 offline checks), `src/fetch_live.odin` (54 real-ssh checks).
Both new cases are wired into `dev/app-smoke.sh` as sections 3/5 and 4/5.

**1. Concurrency — 2 hosts finish in ~one host's time, not 2×.**
Both arms use the SAME non-blocking registry and the SAME ssh commands; only the overlap differs, so the
ssh spawn cost is identical on both sides of the comparison. The assertion is measured **inside** the
fan-out arm against its own children's latencies, and the serial arm is the explicit **negative control**:
```
one at a time  wall=365 ms  (children sum=365 ms, wall/sum=1.00)
[PASS] CONTROL: the serialized arm sits AT its children's sum (>0.8)   ratio 1.00 — serialized IS the sum
[PASS] all children are in flight simultaneously   pending=2 devices=2
    localhost settled 145 ms after its own spawn
    127.0.0.1 settled 95 ms after its own spawn
  fan-out          wall=145 ms  (loops=5 wakeups=5)
    children: sum=240 ms  slowest=145 ms  fan-out wall=145 ms (ratio vs sum 0.61)
[PASS] fan-out wall is well under the SUM of its own children's latencies   0.61, want <0.80 — serialized would BE the sum
[PASS] fan-out wall is bounded by the SLOWEST child, not by their number   145 ms vs slowest 145 ms
```
The wall equals the slowest child exactly, and 8 consecutive runs put the fan-out ratio between
**0.50 and 0.72** while the control stayed pinned at **1.00** — so the 0.8 threshold demonstrably
separates concurrent from serialized rather than being a number picked to pass.

⚠️ **This replaced an unsound baseline.** The first cut compared the fan-out wall to the *serial arm's*
wall. Per-host ssh cost on this fixture swings ~95 ms → ~240 ms between runs (sshd auth contention), so
a serial arm can measure 255 ms while the very next fan-out sees one host alone take 238 ms. The two
arms were not measuring the same costs, and the ratio blamed the loop for the fixture — it failed 2 of 5
runs while the implementation was correct and unchanged. Comparing within one arm, against latencies
taken from the same clock in the same run, removes the confound entirely.
*Lesson: a timing assertion is only as good as its baseline being measured under the same conditions as
the thing it gates. A control arm that must fail if the property is absent is worth more than a tighter
threshold against a wandering one.*

**2. Local paints before any remote fd is read.** The remote is spawned BEFORE local is read, so local
winning is not a matter of ordering.
```
local fetch: exit=0 rows=2 wall=1.73 ms
[PASS] remote has delivered ZERO bytes so far (no read attempted)   out=0 B err=0 B
[PASS] remote is still pending   settled=false
[PASS] local group is already ok while remote is pending   local=ok
[PASS] …and its fd WAS read (so the earlier zero was timing, not silence)   out=644 B
remote arrived at 143 ms after local; local painted 2 ms earlier
```

**3. Timeout bounded — ours and ssh's, both measured.**
```
our deadline: budget=500 ms  elapsed=501 ms  frames=25  killed=true  status=timeout
[PASS] …inside the budget (+ polling slack, never the 300 s sleep)   501 ms vs budget 500 ms
[PASS] the UI thread got MANY frames during the wait (never blocked)   25 frames → one every 20.1 ms
ssh black hole (192.0.2.201): status=unreachable after 5012 ms (101 frames)
[PASS] …bounded at ~ssh's ConnectTimeout, far under the 133 s no-timeout case
[PASS] …and we did NOT have to kill it (ssh answered its own deadline)   kills=0
```
`FETCH_DEADLINE=13 s` sits above ssh's `ConnectTimeout=5` so ssh always reports first; our SIGKILL is
only the backstop.

**4. No zombies — after normal, timeout AND error.**
```
zombie children of us: 0  (settled=3 kills=1)
[PASS] zero zombie children of this process   got 0 want 0
after a second batch of 4: zombie children = 0
=== stress === [PASS] no zombie children after the stress pass   got 0 want 0
post-run shell check: stray `ssh -T -o BatchMode` processes = 0; zombies owned by uid = 0
```
Counted out of `/proc` by `PPid`, not via `ps` (a `ps` pipe would add a child of our own).
⚠️ **This test caught a real bug**: the first cut settled a killed child *without reaping it* —
T3.1's "zombie factory" trap reproducing itself the moment the fan-out became asynchronous. 3 zombies
sat behind a registry reporting every fetch cleanly `settled`. `settled` and `reaped` are now tracked
apart (`kill_and_reap`, `registry_unreaped`, and a debt sweep in `registry_free`).

**5. Per-host isolation.**
```
[PASS] healthy host status = ok / healthy host has rows   rows for localhost = 2
[PASS] broken host status = unreachable / contributed ZERO rows   got 0 want 0
[PASS] the healthy host's rows are all that is in the table   total=2 healthy=2
```

**6. `no_herdr` is DISTINCT from `unreachable`.**
```
no-herdr-host: status=no herdr exit=127 detail=herdr not installed there
unreachable-host: status=unreachable exit=255 detail=ssh failed
[PASS] THE TWO ARE NOT THE SAME STATE   no herdr vs unreachable
```
All six statuses map distinctly (`ok|timeout|unreachable|no_herdr|auth|failed`); exit 255 is split by
stderr so `Permission denied`→`auth` while `Connection refused`→`unreachable`.

**7. Stress — 8 concurrent, no fd leak, no deadlock, all settle.**
```
all 8 settled=true in 901 ms (loops=24 wakeups=15 idle=9 kills=2)
fds: before=6 after=6 delta=0     [PASS] no fd leak across 8 concurrent fetches (2 pipes each)
[PASS] no thread leak either (the design has none)   got 1 want 1
[PASS] idempotent close: fd count unchanged after a second pass
```

**No threads.** `grep -rn 'core:thread' src/` → 0 hits. Wake events are child stdout readability via a
single `poll()`. `FETCH_DEADLINE`/`POLL_SLICE` (13 s / 100 ms) keep every sleep bounded and the loop
iterating (measured: 101 frames during a 5 s black-hole wait, i.e. never a single long block).

**⚠️ Bug found in the T3 seam this task was told to reuse.** `read_all_drain` returned `false` for BOTH
"read some bytes" and "would block (EAGAIN)", and `drain_until_blocked_or_eof` looped on `for !eof` —
an unbounded 100 %-CPU spin against any long-lived, mostly-quiet pipe. Phase 3 never hit it because its
children were fast (write-then-exit → `read` returns 0 immediately). A fetch fan-out sits on ssh's pipe
for seconds, so it fired instantly. Fixed with a tri-state `Drain_Stat {more, blocked, eof, error}` and a
drain that stops at the first EAGAIN; herdr.odin's own `run_capture` gets the fix for free.

**⚠️ Harness integrity hole, also fixed.** `tally` counted `0 PASS / 0 FAIL` as green, so a stale `$BIN`
ran none of the new sections and the suite still reported PASS. A zero-check section is now a FAIL.


---

### T4.2 — Identity-preserving merge ✅ DONE

**Evidence — `src/app/fetch.odin` (`merge`/`apply`/`Selection`) + 67 offline + 54 live checks.**

Identity is `(device, name)` everywhere; `device` is the verbatim ssh target string, `local` is the
literal `local`, and `default` is filtered at parse.

**Identity never collapses on `name`.** Same session name fetched from two hosts:
```
[PASS] same name under two devices -> two rows   got 2 want 2
[PASS] neither row was collapsed onto the name   A@0 B@1
[PASS] each identity resolves to its OWN row   a.device=unit-host-a b.device=unit-host-b
```
Real ssh, two target strings for the same machine (`localhost` + `127.0.0.1`):
```
localhost -> 2 session(s); 127.0.0.1 -> 2 session(s)
[PASS] no rows collapsed: total == sum of both groups   got 4 want 4
[PASS] dropping it from ONE target leaves it on the other   still-under-primary=true still-under-alias=false
```

**Refreshing one host leaves the other byte-identical.**
```
[PASS] carried through 2 foreign rows   carried=2 total=4
[PASS] host B's rows are byte-identical after A's refresh
    B unchanged: unit-host-b|b-one-…|true ;; unit-host-b|b-two-…|true
```

**Delete / re-add keeps the identity stable.**
```
[PASS] empty refresh removes the row   got 1 want 1
[PASS] re-add yields exactly one row   got 1 want 1
[PASS] re-added row is found by the SAME identity   identity stable across delete/re-add
[PASS] re-added row carries the NEW state, not the old one   running=false
```

**Selection is tracked by identity, never index — with the counterfactual proved.**
```
index moved 0 -> 3 while the identity stayed put
[PASS] the index MOVED (3 rows inserted above)   0 -> 3
[PASS] …and it is STILL the session the user picked   resolved=pick-…-10-00-00-000@unit-host-a
[PASS] an index-based selection WOULD have landed on a different session
        index-0 would be n1-2026-10-18-06-00-00-000@aaa-host
[PASS] a vanished identity resolves to -1 (never to a stand-in index)   got -1 want -1
[PASS] resolving a vanished identity yields no session, not a wrong one
```
Held-across-a-real-merge, plus the launch seam keeps the target string verbatim:
```
[PASS] a selection held across that merge still resolves to the same session
[PASS] …and launching with it keeps the target string verbatim
        herdr --remote localhost --session 2026-08-11-23-37-41-812
```

**Ordering invariant: local first, then device, then timestamp, unknown-ts last.**
```
device order: local,aaa-host,unit-host-a
[PASS] local group first, then alphabetical host, then unit-host-a
[PASS] local rows contiguous (never interleaved)
[PASS] timestamps ascending, 'no ts' last
```

**A failed fetch merges ZERO rows and degrades only its own host** (`apply` records status, merges rows
only on `.ok`):
```
[PASS] a failed fetch merges ZERO rows   got 0 want 0
[PASS] the other host's rows are untouched
[PASS] the FAILED host carries the failure   status=unreachable
```

**Not done in this task (deliberately out of scope):** filter-text/caret survival across a merge is a
view-layer concern and lands with the Phase 5 UI. The model layer guarantees the identity contract the
UI will re-resolve against — `selection_of` / `selection_index` / `selection_from_index` — and the
selection never stores a row index.


---

# PHASE 5 — UI + state machine

---

### T5.1 — Frame: Header / Main / Footer with ruled borders — ✅ DONE (RCH-1 applied: no outer border)

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
**Acceptance (amended by RCH-1 / D14):** **no outer border**; a rule between Header/Main and between
Main/Footer. The first and last row/column must contain **no** box-drawing glyphs.

✅ DONE — `src/ui/frame.odin`, **14 checks green** in `./dev/ui-smoke.sh` (`ui-frame`), every
assertion read out of real termbox cells inside a pty:

| Evidence | Result |
|---|---|
| Perimeter (row 0, row rows-1, col 0, col cols-1) | **0** box-drawing glyphs — RCH-1 holds |
| Divider Header\|Main | row 2, spans **all 120** columns |
| Divider Main\|Footer | row 38, spans **all 120** columns |
| Rule rows free of content | yes → **childGap ≥ 2 invariant** holds by construction |
| Predicted geometry vs Clay's own record | `clay=(0,3,120x34) predicted=(0,3,120x34)` |
| Dividers from Clay's command stream | `rules=2`, exactly `borders=1` (the betweenChildren registration) |
| Palette opacity | every colour `alpha == 255` → alpha is never an identity tag |

**Traps found here (each cost a real debugging cycle):**
1. **Odin procedure literals capture nothing.** A `frame_paint(body: proc())` spine could not see the
   caller's view state (`Undeclared name: v`). The frame is therefore an explicit **`frame_open` /
   `frame_close`** pair with the caller painting MAIN in between.
2. **`string(dyn[:])` shares the buffer.** Freeing the dynamic array right after converting left the
   returned string dangling — it rendered as `]��^���1` mojibake at the start of every line, not at the
   end, which made it look like a painting bug rather than a lifetime bug.
3. **A pty eats input written at t=0.** termbox consumes whatever is pending during `tb_init` as terminal
   identification responses, so keystrokes must be delayed by the harness (`{ sleep 1; printf … }`) and
   the reader must tolerate seconds of silence — otherwise a whole case reads **0 keys** and every typed
   assertion fails at once.
4. **Buffered reports swallow the evidence on a crash.** `say` used to append only; the report is now
   streamed so a mid-case panic still shows which assertions passed. Without this, a crash looked like a
   case that never ran.
5. **`fmt` has no `{:02}`.** Zero-padding the session-name timestamp needs an explicit helper, or the
   name silently becomes `…%!(NO VERB)…`, which then fails `ts_from_name` and paints the whole table as
   `—`.

---

### T5.2 — Sessions view: filter line + scrollable table — ✅ DONE

**Create:** `src/ui/sessions.odin`

Columns: **device**, **timestamp**, **state** (running/stopped), **name** — fixed `SizingFixed(n)` per
column, truncation applied by **us** (Clay's `textAlignment` does not truncate). Scroll with
`clip = clay.ClipElementConfig{ vertical = true, childOffset = ... }` — **app-managed** offset
(keyboard-driven; pixel offsets are meaningless at cell granularity).
Selection highlight = draw from app state at render time.

✅ DONE — `src/ui/sessions.odin`, **16 checks green** (`ui-sessions`) + **12** (`ui-shrink`):

- four **fixed** columns (`device 12 / timestamp 23 / state 8 / name rest`), each cell read back at its
  predicted display column; the widths add up inside the interior
- filter starts empty and narrows **live, typed through the pty** — 7 rows → 1 row on `api`, and every
  row still visible contains the filter (a helper names the row that leaked through, rather than
  reporting a bare `false`)
- **every displayed row mirrors the model row at the same index**, built through the same `ellipsize`
  the view uses; the fixture is deliberately scrambled so an unsorted view fails rather than gets lucky
- selection highlight = the app's accent on the selected row **only**, resolved from the
  `(device, name)` identity
- **real shrink** (`TIOCSWINSZ` on our own tty → `SIGWINCH` → termbox resize): selection survives at the
  same index, stays visible, scroll re-clamped, verified again after a second, brutal shrink to 12 rows
- a held identity against a row set that no longer contains it resolves to **`-1`**, never to a
  stand-in neighbour

**Trap:** counting "populated rows" by reading whole screen lines counts the **frame** too — every row
looked populated. Row emptiness must be judged on the *interior* columns only.

**Acceptance:** filter starts empty and filters rows live; scroll keeps the selection on screen; on
shrink the selection is re-clamped and never lost.

---

### T5.3 — Single edit + Filtered list + floating error pane — ✅ DONE

**Create:** `src/ui/edit.odin`, `src/ui/list.odin`, `src/ui/float.odin`

- **edit**: caret is a **display column**, derived from the display width of the prefix — *never* a byte
  offset. Backspace deletes a whole rune (`utf8.decode_last_rune_in_string`). Paste is sanitized — strip
  control chars and embedded escapes before inserting.
- **list**: shared component for the theme picker and remote picker. Up/Down/Tab/Shift+Tab move, typed
  chars filter, `Enter` selects (no selection → **no-op**, per spec).
- **float**: `floating = clay.FloatingElementConfig{ attachTo = .Root, zIndex = N }` for the error pane.
  Dismissed by `Enter`/`Esc`.

✅ DONE — `src/ui/edit.odin`, `src/ui/list.odin`, `src/ui/float.odin`, **20 + 17 + 11 checks green**
(`ui-edit`, `ui-list`, `ui-float`):

- `"a世b😀c"` typed **through the pty** (5 `tb_event`s, `ch` = 97/19990/98/128512/99): caret lands on
  the **derived display column** (7), the bytes-vs-cells gap is real (10 bytes vs 7 cells), and walking
  the painted cells from the field start reaches the caret with **zero drift**
- whole-rune backspace removes a 4-byte emoji and a 3-byte CJK rune in one go, leaving **no stray
  continuation byte**
- paste sanitiser drops **whole escape sequences**, not just the ESC byte — leaving `[200~` behind reads
  as user content — plus control chars and NUL: `hi\x1b[200~世\t\r\n\x07😀\x7f\x00` → `hi世😀` (6 cells)
- narrow-window editing scrolls so the caret stays inside, and the visible slice never exceeds the window
- **one list serves both pickers** (`picker_rows` over `[]string` for themes and `[]app.Remote` for
  remotes); down/tab share one movement op, typed chars filter live, `Enter` with no selection is a
  **no-op**, an empty list prints "nothing matches" instead of a phantom row, and when the held row is
  filtered out the selection is **dropped, not moved onto a neighbour**
- the error pane **floats over the table** (its rows differ from the no-pane snapshot while the rows
  above it are byte-identical — it moved nothing), is **centred on the root** (inset 38 = inset 38),
  border drawn in the error colour, and **Enter/Esc** (typed into the pty) dismiss it completely

**Acceptance:** typing/pasting CJK and emoji never desyncs the column layout.

---

### T5.4 — State machine returns Commands; it performs no side effects — ✅ DONE

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

✅ DONE — `src/app/state.odin` (the machine) + `src/input/keymap.odin` (`tb_event`
→ `Key`) + `src/state_cases.odin` (driver) + `dev/state-smoke.sh` (runner).
**198 PASS / 0 FAIL** — `state-machine` 128 · `state-offline` 54 · 16 source-surface
and safety greps — on a fresh `nix build .`, with every prior suite re-run against the
same binary: **app 339 · ui 90 checks · render 69 · handoff 28**.

| Definition of done | Captured evidence |
|---|---|
| **All 7 states reachable with the spec's exact keys** (ISC-3) | the runner prints the **full (state × key) matrix** (§2) and §3 asserts each reach: `[n]→name_local` `[r]→remote_server` `[s]→name_remote_named` `[a]→attach` `[d]→delete_session` `[t]→theme`, `mode_selection` is the start state, `{Error}` via a refused action |
| **`[s]` two-step proven as a key sequence** | §4: `s` · type `api` · `Enter` → `name_remote_named` → `remote_server` with `carried_name="api"` · `down` · `Enter` → `launch_remote{device:"lab.example", name:"api-<ts>"}` (timestamp parses back via `ts_from_name` → D11 holds). Second run filters to the **mixed-case** target and asserts `cmd.device == "Deploy@lab.example"` byte-identical — no normalisation anywhere (ISC-4) |
| **Empty field + `Enter` is a no-op** | §5: `cmd=none state=name_local (unchanged)`, also after type-then-erase, and the same rule in `name_remote_named` (`carried=""`) |
| **No-selection `Enter` is a no-op** in the list states | §6: `remote_server` · `attach` · `delete_session` · `theme` all `none` + unchanged |
| **`Ctrl+C` → quit from every state** (ISC-12) | §7: **8/8** states answer `quit`; the check sits **above** the per-state dispatch so no future state can swallow it. `0x03` arrives as data because `cfmakeraw` cleared `ISIG` (plan D8) |
| **`Esc` returns to `mode_selection`, no timeout involved** (ISC-11) | §8: 7 states back to the root (the root itself quits). The surface greps prove the absence of a timeout: `core:time` / `sleep` / `peek_event` → **0 hits** in `state.odin`, and the keymap uses legacy `TB_KEY_ESC` — no Kitty protocol (ISC-A-4) |
| **No Command ever targets `default`** (D12/ISC-18) | §10: **128** `(state × key)` probes run against a fixture that **contains** `default` → 0 offenders; aiming `attach`/`delete` at it yields `show_error` with **empty `name` and `device`**, and typing `default` as a new name is refused into `{Error}` |
| **Offline: no side effects** | §12: `waitpid(-1, WNOHANG) = -1 errno=ECHILD` — the entire run created **no child process**. The whole battery re-runs under `env -i PATH=/nonexistent HERDR_ENV=1` (§2) and **passes with no herdr reachable**. `state.odin` imports exactly four things — `input`, `fmt`, `strings`, `unicode/utf8` — no `os`, no `posix`, no `net`, no `terminal`, no `clay`/`termbox`, no `open()/read()/write()` call shape |
| **Hygiene** | `grep -rn 'localhost' src/` → empty · no committed binaries · the real herdr session list is byte-identical before/after (§4 of the runner) |

**Design decisions made here (recorded because the spec is silent or ambiguous on each):**

1. **Uniform clearing on the way back.** Leaving an *edit* state returns `clear_field`;
   leaving a *filter* state returns `clear_filter`; `{Error}` returns `none` because it
   owns neither. The spec names the clearing only for `{NameLocal}` / `{Attach}` /
   `{Theme}` — implementing that asymmetry literally would leave every other edit or
   filtered state holding stale text. Asserted per state in §8.
2. **`name_remote_named` + empty field + `Enter` is a NO-OP.** The no-op rule is spelled
   out only for `{NameLocal}`, but this is the *named* remote path: carrying nothing
   forward would silently produce an unnamed session, which is `[r]`'s job.
3. **In `{Mode selection}` the six mode keys are claimed first, and every *other*
   printable character filters the Sessions table.** The spec binds six letters there
   *and* asks for a filter line in the Sessions content; claiming only unclaimed
   characters is the single reading where both exist.
4. **The selection identity is invalidated when a re-filter drops the row — it never
   slides onto a neighbour** (§9). `held` is what Commands are built from, so it has to
   mean "a visible selection".
5. **`Delete` keeps the user in `{Select session to delete}`** (the list refreshes under
   them and they keep cleaning up); `launch` / `attach` / `set_theme` return to
   `{Mode selection}`, matching the spec's "the TUI appears in the Mode selection".
6. **`Command` is decision O10's tagged struct.** No `union` anywhere near it — the
   runner greps `state.odin` for `union {` so that stays true.
7. **The machine owns the filter/field TEXT**, not the views (per the task: *"mutation of
   UI text fields happens here, external effects do not"*). The existing `ui` views keep
   their own paint state; the cross-layer risk that the two filters disagree is pinned by
   **§9b**, which asserts `app.machine_session_matches == ui.sessions_match` over every
   fixture row × 12 filters (48 pairs, 0 mismatches).

**Traps found here (each cost a real compile cycle; all Odin dev-2026-09):**
1. **A `[dynamic]T` cannot be truncated by assigning a slice, and this Odin has NO
   `delete_range`.** `b^ = b^[:n]` → *"Cannot assign value of type '[]u8' to
   '[dynamic]u8'"*; `delete_range(...)` → *"Undeclared name"*. Backspace needs a
   tail-truncate, so both text fields are now a fixed `[TEXT_MAX]u8` + `len` — the same
   shape `ui.Edit` was forced into in T5.3, for the same reason.
2. **A struct containing a `[dynamic]T` aliases that buffer in every copy of the struct.**
   The transition probes seed and re-seed machine state constantly; a dynamic field would
   be shared and then reallocated out from under a copy. Second reason for fixed buffers.
3. **`and` / `or` are not Odin operators.** `x and y` is a plain *syntax error*; only
   `&&` / `||` exist.
4. **A package-level binding cannot be initialised by a procedure call** — constants must
   be compile-time. `k_enter :: input.key_of(.enter)` fails; the composite literal
   `input.Key{kind = .enter}` works.
5. **`..spread` is for call arguments only.** `[]T{a, ..b}` is a syntax error; build
   with `append(&d, ..b)`.
6. **A variadic `append` cannot resolve an implicit selector**: `append(&out, .attach,
   .theme)` → *"Cannot determine type for implicit selector expression"*. Spell them
   `app.State.attach`.
7. **`#partial switch` requires an enum** — `#partial switch k.r` (a `rune`) is
   rejected; a plain `switch` over values is fine.
8. **`strings.contains` takes 2 arguments** — no allocator parameter, unlike most of
   `core:strings` here.
9. **A one-letter helper proc collides with an import alias** — naming the char-key helper
   `c` broke `import "core:c"` in the same file.
10. **Process note (the anti-stall rule):** the O10 answer in `60-handoff-notes.md` removed
    the blocker entirely. One `/tmp` probe was spent, to confirm `delete_range` is absent;
    everything else came from compiler errors against the real files, not throwaway
    probes. Total wall time for the task: well under the "stop and report" threshold.

---

### T5.5 — Executor + the real poll loop: `nix run .` is a terminal program — ✅ DONE

**Created:** `src/app/exec.odin` (the only place a `Command` becomes a process),
`dev/tui_drive.py` (pty harness that models the screen), `dev/tui-smoke.sh` (runner).
**Modified:** `src/main.odin` (the TUI: boot, poll loop, projection, tty gate — the
default argv case is now `tui`, every prior smoke case still reachable by name),
`src/app/herdr.odin` (`control_argv` — remote control is our own `ssh -T`),
`src/app/fetch.odin` (`merged` flag: a settled child merges exactly once).

**99 PASS / 0 FAIL** on `nix build`'s own binary, and again on `dev/local-build.sh`.
The prior suites are unchanged against the same binaries: **state 198 · app 339 ·
ui 90 · render 69 · handoff 28 = 724 PASS / 0 FAIL.**

| Definition of done | Captured evidence |
|---|---|
| **`nix run .` starts the TUI** (ISC-1, ISC-2) | `script -q -c 'result/bin/herdr-session tui'` renders header + filter line in a real tty; bare invocation with stdin from `/dev/null` prints one human line and exits **3** — no panic, no escape sequences leaked, no mangled terminal |
| **Create → attach → detach → delete, end to end** (ISC-5, ISC-10) | `roundtrip` (17 checks): `n` + typed prefix → **herdr CREATED** `hs-t-tui-rt-<ts>` (D11: prefix + cycle timestamp, so the typed text is never the final name) → the child owns the tty → `ctrl-b q` → **22 491 bytes** streamed as the app re-enters the alt screen and fully repaints → the new row is already in the list → `d` + filter + `Tab` + `Enter` → **gone from herdr itself**, verified by `herdr session list --json`, not by our screen |
| **Attach never targets an unvalidated name** (ISC-17) | `attach_guard` refuses any `(device,name)` not in the model — *"attaching an unknown name would CREATE it"* — and the proof is not the boolean: `waitpid(-1, WNOHANG) = -1 errno=10 (ECHILD)` in the same process, i.e. **nothing was ever forked**. `default` refused with D12 named in the reason |
| **`delete` pre-checks existence, never trusts `deleted:true`** (ISC-16) | `delete_guard` refuses an unknown name with *"nothing was deleted"* **before** any argv is built; ECHILD again proves no call was attempted. A known running row goes `stop` → `delete`, and the runner asserts absence against herdr afterwards |
| **Local rows before any remote fetch** (ISC-6) | `boot-remote` footer timeline: `local_ok=0.05s` vs `remote_ok=0.20–0.30s`. Boot order is: local snapshot **inline**, first frame painted, *then* fan out the remotes |
| **No remote can block the UI; worst case = `ConnectTimeout=5`** (ISC-14) | black-hole host `192.0.2.201` reports `down` at **+5.06 s** (`first_bytes=+5016ms` — that is ssh's own timeout, not ours), while a keypress mid-flight is still answered |
| **A host failure degrades only that host** (ISC-15) | same run, from `HS_TUI_TRACE`: `device local status=1 rows=3 · device localhost status=1 rows=3 · device 192.0.2.201 status=3 rows=0` — the dead host is one footer badge, nothing else notices |
| **Terminal restored on every exit path** (ISC-9) | `boot-local` (Ctrl+C, exit 0), `sigterm` (shell-visible **143**), `roundtrip` (create+attach+delete then quit): each asserts `\x1b[?1049l` in the byte stream **and** `tcgetattr(after) == tcgetattr(before)` — read back from the pty *slave*, so it is the kernel's answer, not ours |
| **Resize updates the screen with no key input** (ISC-13) | harness issues `TIOCSWINSZ` and writes **zero** bytes; first repaint byte lands ~**50 ms** after the ioctl (the resize self-pipe, discovered via `tb_get_fds`) |
| **No idle spin, no threads, no merged streams** (ISC-A-6 + plan constraints) | idle CPU over 5 s of a live TUI = **0 clock ticks**; `tb_get_fds` + `poll` only, `timeout = -1` when the registry is empty; every fetch keeps stdout and stderr on **separate pipes** (`out=866B err=0B` / `out=0B err=64B` in the trace) so JSON is never polluted |
| **The state layer stayed pure** | nothing in `state.odin` changed. `update(&machine, key) -> Command` still owns every decision; `execute(cmd, rows, home, budget)` is the only consumer and it is called from exactly one place (`tui_run_command`) |
| **Cleanup policy still `never`** (D2 parked) | the seam is *wired and visible*: after a launch the footer reads `herdr exited with code 0 — cleanup_policy=never: hs-t-tui-rt-<ts> left running`. Nothing is destroyed behind the user's back. Teardown of scratch sessions is the **runner's** job, not the product's |

**Trace artifact** (`HS_TUI_TRACE`, boot + one remote + one black-hole host):

```
total=17252ms frames=4 polls=56 hits=7 idles=49 errs=0 remote_fans=2 local_ms=1 first_paint_ms=5
fetch localhost kind=1 pid=1356252 eof_out=true eof_err=true settled=true reaped=true status=1 killed=false first_bytes=+157ms settled_at=+259ms exit=0 out=866B err=0B
fetch 192.0.2.201 kind=1 pid=1356253 eof_out=true eof_err=true settled=true reaped=true status=3 killed=false first_bytes=+5016ms settled_at=+5018ms exit=255 out=0B err=64B
device local status=1 rows=3
device localhost status=1 rows=3
device 192.0.2.201 status=3 rows=0
```

Four frames for the whole run: first paint, local landed, remote landed, dead host
bounded. Not one repaint per poll.

**Design decisions made here (the spec is silent on each):**

1. **The TUI is a module singleton (`tui`), not a threaded parameter.** This Odin
   gives no capturing closures and the repaint callback comes from `terminal`, so
   the choice was one struct owned in one place or `^App` on every signature. One
   struct, greppable, and the smoke drivers still run without it.
2. **One repaint hook, switched by `TUI_ACTIVE`.** Handoff owns a full-repaint hook;
   smoke drivers painted the old frame and the TUI paints the real one. Registering
   the wrong one is a silent black screen, so the switch sits next to both and is
   set/cleared around the loop, not inferred.
3. **The machine owns all text; the view syncs from it each frame** (`tui_sync_text`).
   T5.4 made this the rule and T5.5 honours it — the editors are paint targets, not
   sources of truth.
4. **Every keypress marks the view dirty.** Most keys change machine state with no
   visible argv effect (cursor moves, filter text, notice clearing). A "smart"
   dirty-tracking scheme cost a whole symptom ("some keys do nothing") before the
   dumb rule was worth it, and the renderer diffs anyway so the cost is noise.
5. **Remote attach = `launch_argv(device, name)`.** Observed herdr 0.8.2 rejects
   `--remote X session attach`; `--remote` pairs only with the default launch
   command, which *is* create-or-attach on that host — the ISC-5 shape exactly.
6. **Remote stop/delete are wrapped in our own `ssh -T` (`control_argv`).** Same
   0.8.2 limitation (`--remote X session delete` is not a valid command), and the
   direction of the failure matters more than the elegance: if the device is not
   part of the argv, a *remote* delete can silently destroy a **local** same-named
   session.
7. **Theme is applied, not persisted.** `set_theme` records and paints; writing
   `~/.config/herdr_session.json` is T6.1, and the executor says so in its own
   effect message rather than pretending to have done it.
8. **Guard reasons are user-facing prose that names the rule** (D12 for `default`,
   "would CREATE it" for unknown attach, "nothing was deleted" for unknown delete).
   A refusal that only says "invalid" makes the user guess which of four safety
   rules just fired.
9. **`default` never leaves the guard alive.** Not filtered from the list (the user
   must see it) — but no `Command` built through `execute` can ever aim at it, so
   D12 holds at the choke point rather than at the paint layer.

**Traps found here (each cost a real cycle; all Odin dev-2026-09 unless stated):**

1. **A fetch that has hit EOF is not a fetch that has been reaped — and if it drops
   out of the poll set, nothing will ever wake the loop for it again.** Measured: a
   healthy fetch had both EOFs at **+155 ms** and did not settle until **+5014 ms**,
   unblocked only when an unrelated host's ssh exited. At that instant the fetch has
   no fd left in the set, so no I/O event can refer to it again. Fix: while anything
   is in flight, cap the sleep at `POLL_SLICE` (100 ms) — the same discipline
   `registry_step` already used for the same reason. `timeout = -1` is reserved for
   an *empty* registry, which is what keeps idle CPU at 0. This is the trap that
   would have shipped as "the app freezes for thirteen seconds".
2. **Grepping the pty byte stream cannot verify a diffing renderer.** termbox writes
   only changed cells, so a string unmistakably on screen never appears in the stream
   (`filt` + `r:` arriving from two different frames). Every early claim was a false
   negative. Fix: `dev/tui_drive.py` keeps a `Screen` model — cursor addressing,
   erase, OSC/BEL, `ESC ( B` charset designation — and asserts on *the screen*.
3. **Sequential `wait_for(A); wait_for(B)` reports B as late even when both were
   instant.** The first wait burns the whole timeout when A never arrives, so B's
   number becomes a lie about *ordering* — the one thing ISC-6 is about. Fix:
   `watch_screen` watches all labels in one loop and records each arrival.
4. **Odin's `for x, i in collection` binds `x` = element, `i` = index** (Go-style).
   Assuming the reverse reads `shown[0]`, `shown[1]`… as positions rather than the
   indices they are. It compiles, it runs, it paints an empty table.
5. **`return string(buf[:])` under a `defer delete(buf)` is a use-after-free that
   renders as garbage instead of crashing.** The footer printed mojibake. Fixed by
   building the string with `fmt.tprintf` and owning it in the caller.
6. **A silent harness is not a passing harness.** "0 bytes read" read as "the app is
   waiting politely" when the app had died at startup. Every scenario now asserts
   liveness (`p.alive()`, exit code) *before* interpreting silence.
7. **`check` takes exactly three arguments** — name, cond, already-formatted detail.
   `check("x", c, "a {} b", v)` is a hard error; `fmt.tprintf` the detail yourself.
8. **A fixture that points at *this* machine legitimately duplicates rows.** With
   the loopback fixture, the same session is a row under `local` *and* under the
   aliased device — two distinct `(device, name)` identities. Row-count assertions
   must be **device-exact** (`line.split()[0] == "local"`), and the duplicate is
   worth asserting on its own: name-alone identity is exactly the bug that would
   make two hosts' sessions indistinguishable.
9. **herdr generates the name from the prefix** (D11). The typed `hs-t-tui-rt`
   becomes `hs-t-tui-rt-2026-10-19-21-56-44-516`; a test matching the literal
   typed string either fails wrongly or — worse — "passes" a delete that never
   happened because the name never existed. Track the *created* name; clean up by
   prefix.
10. **The fixture-host grep catches prose.** The `localhost` grep hit two *comments*
    in `main.odin`. Correct behaviour: the rule is "no fixture host names in `src/`",
    comments included. Reworded to "loopback".
11. **`nix build` builds the git tree, not the working directory.** An untracked
    `src/app/exec.odin` is invisible to it — the failure shows up as "undeclared:
    app.execute" against a file that plainly exists. `git add` new sources before the
    first `nix build`.
12. **Minor, one compile each:** `posix.pollfd.fd` needs `posix.FD(...)`;
    `posix.waitpid` takes a *bitset* (`{.NOHANG}`) not an int; `posix.isatty`
    returns `b32` and needs `bool(...)`; a struct field still needs its trailing `,`
    when the following line is a comment; `os.get_env` does not exist here —
    `os.get_env_alloc`.

**Instrumentation left in place (off by default, dev-only):** `HS_TUI_TRACE=<file>`
dumps the run at exit — frames, poll hits/idles/errors, per-fetch first-byte and
settle times, per-device status and row counts. `HS_TUI_DEBUG` (per-iteration
append) was deliberately removed: file I/O inside the loop moves the timing of the
very races the loop is made of, and it reported a starvation bug that then vanished
whenever it was watching.

---

# PHASE 6 — Config, themes, and final verification

---

### T6.1 — JSON config via `core:encoding/json` ✅ DONE

**Created:** `src/app/config.odin` (+ `src/theme_cases.odin` for the checks,
`dev/theme-smoke.sh` + `dev/theme_drive.py` as the runners)

**D13 held: JSON only.** `core:encoding/json` for parse/marshal,
`os.user_config_dir()` for location, single file
`~/.config/herdr_session.json`. No TOML parser, no XDG package — the hygiene
check asserts both (`0 non-comment hit(s)` for `/toml/i`, `0` XDG imports).
`os.user_config_dir` already implements the whole XDG rule
(`core/os/user_posix.odin:17`: `$XDG_CONFIG_HOME` → `$HOME/.config`), so the
"stdlib XDG" line in the original note is literally what is used.

Owned keys: `theme`, `remotes` (verbatim ssh targets), `cleanup_policy`.

**Contract: a bad config must never brick the app.** `config_load` has no error
return; every mode is absorbed and reported as one visible line. Captured:

| input | captured result |
|---|---|
| file absent | `present=false warnings=0 theme='gruvbox-dark'` — **silent**, and `LOADING DID NOT CREATE a config file` |
| `""` / whitespace | same as absent |
| `{ this is not json at all` | `config <path> is not valid JSON (Expected_Colon_After_Key) - defaults in use`, `corrupt=true`, defaults still applied, **exactly one** warning |
| `[1,2,3]` / `42` (root not object) | `config <path> must be a JSON object - defaults in use` |
| `{"theme":"bogger"}` | `unknown theme 'bogger' - using gruvbox-dark (available: gruvbox-dark, gruvbox-light, catppuccin-latte, …)` |
| `{"theme":42,"cleanup_policy":["never"],"remotes":"x"}` | 3 warnings, one per wrong-typed key; file **not** called corrupt (`corrupt=false present=true`) |
| `{"cleanup_policy":"on"}` | `unknown cleanup_policy 'on' - using never` |
| JSON5 (`// comments`, trailing comma) | loads — the parser's `DEFAULT_SPECIFICATION` is JSON5, which is why a hand-edited file forgives both |

**Unknown keys survive a save — proven, and this is the deliberate design.**
A save is read-modify-write of the parsed `json.Object`: parse, set our key,
marshal the whole document. Hand-written file:

```
{ "hand_added_note": "do not eat this", "theme": "catppuccin-latte",
  "future_key": {"nested": [1,2,3]}, "remotes": ["my-host"] }
```
after `config_save_theme(path, "nord")`:
```json
{ "cleanup_policy"…(later write), "future_key": {"nested": [1,2,3]},
  "hand_added_note": "do not eat this", "remotes": ["my-host"], "theme": "nord" }
```
Survival re-asserted after a **third** write (`config_save_remotes`) and a
fourth (`config_save_cleanup`). The saved file also **re-reads** to the theme
that was saved with **zero warnings** — write and read agree.

Two consequences recorded in the module header: an *unparseable* file cannot be
preserved (the save replaces it with only our keys; the corrupt-mode warning
already said it was invalid), and a key is **not** deleted just because it
holds the default value — absent and explicit-but-default stay distinguishable.

Writes go temp-file + `os.rename` (atomic within a filesystem), pretty-printed
2-space with sorted keys so the file a human edits is also a file they can
diff. `no *.tmp litter left in the config dir` = 0.

**O7 seam filled.** `tui_config_remotes()` used to *be* the configured set
(built from fixture env vars), leaving `discover_resolved(probe,
config_remotes)` with a parameter that had no producer. It is now the union of
`cfg.remotes` (product path) and `tui_fixture_remotes()` (dev path, still the
only place the fixture env is read, so the fixture-host grep over `src/` stays
empty). Config wins a device-string collision. `pty:remote-from-config` proves
the product path independently:

```
a host named ONLY in the JSON appears in the app   first seen at t=0.05s
…as its own device row/status entry (not merged into local)
   'mode_selection · local ok 0  hs-t6-cfghost pending 0 …'
…carrying a status word (so a dead host is visible, ISC-15)   hs-t6-cfghost pending
```
…with **all** `HERDR_SESSION_TEST_*` variables removed from that scenario's
environment, so the only possible source is the file.

**Every case ran under a temporary `XDG_CONFIG_HOME`.** The runner fingerprints
the real file before and after:
`real ~/.config/herdr_session.json untouched   before=ABSENT after=ABSENT`,
and `our XDG_CONFIG_HOME swap did not leak into the caller  unchanged ('unset')`.

---

### T6.2 — Compiled-in palettes, `gruvbox-dark` default ✅ DONE

**Created:** `src/app/theme.odin`, `ui.palette_of` in `src/ui/frame.odin`,
`running`/`stopped` slots wired into `src/ui/sessions.odin`.

**Shipped set (10), captured verbatim from the run:**

```
gruvbox-dark, gruvbox-light, catppuccin-latte, catppuccin-frappe,
catppuccin-macchiato, catppuccin-mocha, tokyonight-night, nord,
solarized-dark, solarized-light
```

`gruvbox-dark` is the default (`D4`), asserted three ways: `theme_default()`,
`THEME_DEFAULT_NAME`, and that the picker's `(current)` marker lands elsewhere
after a change. `catppuccin-latte` ships, is selectable, and
**is not the default**. Hex values are transcribed from the sources named in
`scout-nix-packaging.md` §f (gruvbox_256palette.sh, catppuccin/palette 1.8.0,
tokyonight.nvim `night.lua`, nord.scss `$nord0..$nord15`, solarized README) —
none invented; the per-slot *choice* of which documented colour fills which
role is stated in a comment per theme.

**Slot coverage — "no gaps" is an enforced invariant, not an aspiration.**
`app.PALETTE_SLOTS == 13` and the check that every theme fills every one of
`bg fg dim border header_fg accent sel_fg caret float_bg float_fg err_fg
running stopped` reports `0 gap(s) across 10 themes`, plus
`text is never its own background colour` (fg≠bg and sel_fg≠accent for all 10)
and `every slot of every theme paints through render.attr_of  0 hole(s)`.

`running` / `stopped` are **new** slots: before this, the sessions table painted
both states in the default `fg`, so a theme could not distinguish a live
session from a dormant one — one of the "gaps" the requirement covers.

**Aliases are config-only, never picker rows.** `latte`, `mocha`, `macchiato`,
`gruvbox`, `catpuccin-latte` (misspelling), `tokyonight`, `solarized`, `NORD`
all resolve, and `filter: 'latte' narrows to exactly ONE row  1 rows match
'latte'` proves the alias list cannot inflate the picker.

**Persistence (`ISC-7`) — captured end to end, with a real restart:**

```
no config file before the theme is chosen              None
applying reports BOTH the paint and the save   "theme 'catppuccin-latte'
    applied and saved to /tmp/hs-t6-pty-apply-*/herdr_session.json"
the config file now EXISTS on disk   { "theme": "catppuccin-latte" }
after a restart the SAVED theme is the applied one   'catppuccin-latte (current)'
…which is NOT the compiled-in default                default is gruvbox-dark
```

The notice carries the **save outcome**, not just the intent: the executor's
message is `"theme 'X' applied"` and the persistence layer appends `" and
saved to <path>"` or `" but NOT SAVED: <reason>"`. The message that used to
ship — `"applied for this run (config persistence arrives with T6.1)"` — was
true once and then became a lie the app kept telling the user; it is gone.

**Picker pre-select** (`pty:picker-preselect`, 7/7): the picker opens with the
applied theme highlighted and marked, exactly one row marked, and the theme is
on the wire **before any keystroke** (`bytes written by us: 0`):

```
theme picker lists the compiled-in palettes (was: 'nothing matches')   10 rows
the APPLIED theme is the one the picker is on    'tokyonight-night … (current)'
exactly ONE row is marked current                1 marked rows
the selection bar is painted in the theme's accent colour
    accent SGR 48;2;122;162;247 emitted while the picker is open
```

**Truecolour / black behaviour, on real bytes** (`pty:sgr-truecolour` 4/4,
`pty:black-is-black` 3/3, `colour-wire` 11/11):

```
bg #eff1f5  -> SGR 48;2;239;241;245      fg #4c4f69 -> 38;2;76;79;105
selection bar #8839ef -> 48;2;136;57;239
gruvbox bg #282828 -> 48;2;40;40;40      sel_fg #1d2021 -> 38;2;29;32;33
pure black: attr = 20000000 = TB_HI_BLACK  (TB_DEFAULT = 00000000)
alpha 0 paints nothing; alpha 255 paints
0..1 mistake would be visible: 0..1 form -> 20000000; real gruvbox bg -> 282828
```
The 0..255 conversion exists in exactly **one** function
(`ui.clay_colour`/`palette_of`), which is why `theme.odin` stores plain
`0xRRGGBB` and never a Clay type.

**New traps recorded (all paid for during this todo):**

1. **`json.Object{}` is a NIL map.** Assigning into it is a silent no-op: the
   save reported success and wrote `{}`. A first-run theme change vanished with
   no error anywhere. Must `make(json.Object)`.
2. **`cast(map[string]json.Value)obj^` writes into a DETACHED copy.** It
   compiles, runs, and the key never reaches the document (`len` never grows) —
   the same `{}` symptom from a different cause. `obj^[key] = v` is the form
   that mutates the caller's map.
3. **A config dir created without `+x` cannot have files created inside it.**
   `Permissions_Read_All + Permissions_Write_All` made *every* save fail with
   `permission denied` on a directory we had just created ourselves.
   `CONFIG_DIR_MODE` is `Read_All + Write_All + Execute_All`.
4. **Odin procedure literals capture nothing**, so the natural
   `restore := proc() { … had … }` for a temp-env helper does not compile
   against the caller's locals. The helper returns a `Cfg_Saved` struct and
   `end_cfg_home(&saved)` restores it.
5. **`fmt` has no `{x}` hex verb** (`{x:06x}` and `{x}` render as
   `%!(MISSING CLOSE BRACE)}`). Use `%x`/`%06x`, and do not mix `{}` with `%`
   verbs in one string — the plan's existing trap about arg scrambling applies.
6. **An unprivileged box cannot construct the "unreadable but existing file"
   case.** A chmod that makes `open` refuse also makes `os.is_file` return
   false, which is the *missing* branch. The check therefore reports which
   branch ran instead of faking the unreachable one with root.
7. **Picker `Enter` on `sel == -1` is a no-op by design**, so a filter that
   hides the currently-applied theme leaves nothing to apply — the test drives
   Down then Enter. (Not a bug: pre-select points at the applied theme, and a
   filter that excludes it means the user is looking at something else.)
8. **`os.get_env` is an overload group** (alloc/buf) — use
   `os.lookup_env(key, alloc)` when you need the found flag; `os.getpid` does
   not exist (`posix.getpid`).

**Suite totals.** New T6 suite: **166 checks, 0 FAIL**
(`BIN=./result/bin/herdr-session ./dev/theme-smoke.sh`): 6 in-process cases
(theme-set 14, theme-resolve 23, config-parse 34, config-save 26,
config-live 20, colour-wire 11) + 7 pty scenarios (picker-preselect 7,
apply-persist 7, corrupt-warning 5, unknown-theme 5, sgr-truecolour 4,
black-is-black 3, remote-from-config 5) + 6 hygiene checks.

Prior suites re-run fresh-built and fixture-armed, unchanged from baseline:
handoff 28/0, render 69/0, state 198/0, ui 90/0 (6/6 green), tui 99/0,
app 336 PASS / 3 FAIL. **The 3 `app` failures are not from this work**:
running the identical command against stashed baseline `d483f86` produces the
byte-identical 3 failures (`no-tty launch panics with 101  got 1 want 101`,
its label-mapping dependent, and the orphan-rule check counting a
pre-existing session). They are herdr **0.9.5** behaviour drift against
checks written for 0.8.2, and they fail the same way with and without T6.

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
T0.1 → T0.2                    ← toolchain risk retired; `nix run .` works        ✅
  → T1.1 → T1.2                ← HANDOFF proven with a dummy child               ✅
  → T2.1 → T2.2 → T2.3         ← renderer                                      ✅
  → T3.1 → T3.2 → T3.3 → T3.4 ← herdr integration                             ✅
  → T4.1 → T4.2                ← parallel fan-out (no threads)                 ✅
  → T5.1 → T5.2 → T5.3         ← views + frame (RCH-1 applied: no outer border) ✅
  → T5.4                       ← the state machine (side-effect-free)      ✅
  → T5.5  ✅ DONE                ← executor + real poll loop; `nix run .` is a terminal program
  → T6.1 → T6.2 → T6.5 → T6.3 → T6.4 → T6.6   ← config/themes/resize, next up
```
`nix build` must stay green at every arrow. **Do not reorder T1.2 later** — it is the assumption the whole
plan rests on (premortem **A1**) and it is cheapest to validate before feature work exists.
