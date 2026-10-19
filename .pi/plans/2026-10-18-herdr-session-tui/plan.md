# herdr-session — Implementation Plan

**Date:** 2026-10-18
**Status:** Approved for execution
**Directory:** `/home/alexfneves/gits/herdr_session`
**Todos tag:** `herdr-session-tui`

---

## Intent

A `herdr-session` TUI in **Odin + Clay** that replaces `~/.config/home-manager/herdr/herdr-cycle.sh`:
list, create, attach to and delete herdr sessions both locally and over SSH, packaged in this nix flake so
`nix run .` launches it as the default output. Local sessions paint instantly; remote sessions fan out in
parallel and merge in as they arrive.

**North star:** the user opens a terminal, sees every session across every machine within ~3 ms (local) with
remotes filling in live, and can act on any of them without leaving the keyboard.

## User Story

As a daily herdr user with a local box and one or more remote machines, I want one keyboard-driven screen
that shows all my herdr sessions everywhere, so that I can create, attach and clean up sessions without
remembering host strings or shell incantations.

---

## Decision Register (all resolved 2026-10-18)

| ID | Decision | Resolution |
|---|---|---|
| **D1** | Known-remotes source | **`herdr machine list --json`** (herdr 0.9.x registry). Our TUI **only reads** the registry — `machine add` requires an interactive terminal and stays the user's job. Device key = the profile's **verbatim ssh target**; display label = profile `label`. Fallback when unavailable: `remotes = [...]` in our own config, plus `~/.ssh/config` `Host` stanzas if that file ever exists. |
| **D2** | Destroy-on-detach | **PARKED** until the user's box runs latest herdr and the behaviour is confirmed. Encoded as a single seam `cleanup_policy` in `app/herdr.odin`. Interim default: **`never`** — nothing is destroyed while undecided. |
| **D3** | Timestamp column | **Parsed from the session name** (`YYYY-MM-DD-HH-MM-SS-mmm`), per `herdr-cycle.sh:28,137`. Only named sessions are ever used → **zero stat / ssh round-trips**. Non-matching name → `—`, sorted last. |
| **D4** | Default theme | **`gruvbox-dark`**. Palette set sourced from **terminalcolors.com** (verified machine-readable: `https://terminalcolors.com/downloads/alacritty/<theme>.toml` → `primary / cursor / selection / normal / bright`). Compiled into the binary at author time. `catppuccin-latte` also shipped (user preference, not default). |
| **D5** | Renderer base | **B2** — `clay.odin` (official Odin binding) for layout + **our own ~160-line Clay→cell renderer** on top of **termbox2** (vendored, built in-derivation). |
| **D6** | Platform scope | **Linux only** — `x86_64-linux`, `aarch64-linux`. |
| **D7** | Wide chars | Minimal-correct, free via `tb_wcwidth`. 2-cell glyphs claim the following cell. |
| **D8** | Ctrl+C / ISIG | ISIG **off** (free via `cfmakeraw`) → `0x03` is a normal input event, uniform across all 7 states. **Plus our own** `SIGTERM`/`SIGHUP` handler that calls `tb_shutdown()` — termbox2 installs *only* `SIGWINCH`. |
| **D9** | Repaint | `poll()`-driven; diffing free via `tb_present`. No idle spin. |
| **D10** | Escape ambiguity | Legacy only, termbox2 `TB_INPUT_ESC` — lone ESC returns immediately, **no timeout**. **No Kitty keyboard protocol** (user's terminal is Alacritty). |
| **D11** | New-session naming | Keep `herdr-cycle`'s exact `%Y-%m-%d-%H-%M-%S-%3N`; regenerate on collision (colons are illegal in herdr names). |
| **D12** | `default` session | **Never** listed, attached or deleted (herdr refuses to delete it anyway). |
| **D13** | Config format | **JSON via `core:encoding/json`** — removes the TOML dependency entirely. File: **`~/.config/herdr_session.json`** (spec literally said `.toml`; renamed by this decision). |
| **D14** | Outer border | **REMOVED (RCH-1, user request 2026-10-19 — see `50-requirement-changes.md`).** The app is bounded only by the terminal edges. `BorderAll(1)` on the root is gone — the root carries `border.width = BorderWidth{betweenChildren = 1}` and nothing else, so Clay emits exactly the two dividers (Header\|Main, Main\|Footer) and no box. `FRAME_PAD` dropped `1 → 0` with it: that padding *was* the border allowance, and the freed 2×2 now belongs to the content. `childGap ≥ 2` is unchanged — removing the border does not relax it. |

**Effort level: MVP + targeted hardening.** Hardened now = where being wrong is irreversible or invisible
until it bites. Held at MVP = cheap to improve later.

| Hardened now | MVP (upgrade when it hurts) |
|---|---|
| `HERDR_ENV` scrub on every child | Table scroll ergonomics |
| Attach only to validated names (orphan prevention) | Fuzzy filter matching |
| stdout/stderr split — never `2>&1` before JSON parse | Palettes beyond the initial set |
| Terminal restore on every exit path incl. SIGTERM | Live theme reload |
| `(device,name)` key + verbatim device string | Column-width tuning |
| `ConnectTimeout=5` + `BatchMode=yes` | Per-host retry/backoff |
| `default` never offered | Config validation messages |
| `delete` existence pre-check | |

**Tests:** smoke now (build + scripted checks for the hardened column). **Docs:** README + inline.

---

## Behaviour

### Happy path

1. User opens a terminal → TUI appears: Header / Main (Sessions) / Footer, full-screen, ruled borders.
2. Local sessions are visible on first frame (~3 ms). Each remote host shows a `pending` row group.
3. Remote hosts arrive (~150 ms each, concurrent) and merge in without a redraw flash.
4. `n` → single-line edit → type `api` → `Enter` → TUI leaves alt-screen, `herdr` takes the terminal,
   session `api-<timestamp>` is live.
5. User detaches in herdr → TUI re-enters alt-screen, fully repainted, list refreshed, back at `{Mode selection}`.
6. `r` → remote picker (filtered list) → pick host → `Enter` → new remote session on that host.
7. `a` → filter to a session → `Enter` → attach (local or remote).
8. `d` → pick a session → `Enter` → stop-if-running → delete → list refreshes.
9. `t` → theme picker (filtered list, current theme pre-selected) → `Enter` → applied + persisted.
10. `Esc` returns to `{Mode selection}` from anywhere; `Ctrl+C` exits from anywhere with the terminal restored.

### Main-content modes

| Mode | Contents |
|---|---|
| **Sessions** | filter line (starts empty) + scrollable table: **device**, **timestamp**, **state** (running/stopped), **name** |
| **Single edit** | one editable line, nothing below |
| **Single text** | one message (errors) |
| **Filtered list** | filter line + items matching filter, selectable |

**Sort order:** `(device != "local", device, timestamp)` — `local` always first, then host, then timestamp.

### State transitions

```
Key ──► state.update(app, key) ──► Command ──► main executor ──► handoff / spawn / exit
                                              (state machine performs NO side effects)
```

| From | Key | To |
|---|---|---|
| **ModeSel** (Sessions) | `Enter` | → `Launch` local, timestamped name |
| | `n` | → **NameLocal** (edit) |
| | `r` | → **RemoteServer** (list) |
| | `s` | → **NameRemoteNamed** (edit) |
| | `a` | → **Attach** (Sessions) |
| | `d` | → **Delete** (Sessions) |
| | `t` | → **Theme** (list) |
| | `Esc` / `Ctrl-C` | quit |
| **NameLocal** | `Enter` | → `Launch` local `"<typed>-<ts>"`; empty field → **no-op** |
| | `Esc` | clear field → ModeSel |
| **NameRemoteNamed** | `Enter` | → **RemoteServer** (name carried) |
| **RemoteServer** | `Enter` | → `Launch` remote at `<device>` (+ carried name) |
| **Attach** | `Enter` | → `Launch` attach of validated `(device,name)` |
| **Delete** | `Enter` | existence pre-check → `stop` if running → `delete` → refresh |
| **Theme** | `Enter` | apply + persist → ModeSel |
| **Error** | `Enter` / `Esc` | → ModeSel |

**⚠️ Spec inconsistency resolved.** `docs/requirements.md`'s `[s]` arrow says *"→ {Select remote server for
new named remote session}"*, but the state it actually defines — `{Select name for new named remote session}`
— has `[Enter] → {Select remote server…}`. **Resolution: `[s]` collects the name first, then the server**
(two steps). This is the only reading consistent with both lines of the spec.

### Edge cases & error handling

| Case | Behaviour |
|---|---|
| `herdr` not on PATH | `{Error}`: "herdr not found on PATH" — no crash, no retry storm |
| herdr is 0.8.2 (no `machine` verb) | `machine list` prints help banner with **exit 0** → **JSON-shape gate**, not exit code → fall back to config `remotes` |
| Remote has no herdr (127 / `command not found`) | That host's group: `no-herdr`. App unaffected |
| Host unreachable | bounded by `ConnectTimeout=5` → `unreachable` |
| Auth failure | `BatchMode=yes` fast-fails (~119 ms) → `auth` |
| `delete` on unknown name | herdr returns `deleted:true` + exit 0 for names that **never existed** → **pre-check existence in the model**, report honestly |
| `delete` on running session | `herdr refuses` → we `stop` then `delete` (parity with `herdr-cycle.cleanup_session`) |
| Attach to a name not in the validated list | **Refuse.** A crashed attach still spawns a live orphan session |
| Empty edit field + `Enter` | No-op (per spec) |
| Invalid charset typed | Reject at input: names are `[A-Za-z0-9._-]` only |
| Terminal < ~40×10 | Render "terminal too small", no garbling |
| Rapid resize (window drag) | Coalesce: drain pending resize events, one layout per frame |
| Child panics on tty-init (101) | Restore + repaint anyway; surface generic "needs a real terminal" |
| Config missing | Defaults silently |
| Config corrupt / unparseable | Defaults + one warning line — **must not brick the app** |
| Unknown theme name in config | Fall back to `gruvbox-dark` + warning |
| Name not parseable as timestamp | `—`, sorted last within its device group |
| Filter matches nothing | "no matches" empty state |
| No remotes configured | Empty remote section, no error |
| `SIGTERM` / `SIGHUP` while TUI is up | Our handler → `tb_shutdown()` → terminal restored |
| Signal storm while child owns the tty | `SIGINT`/`SIGQUIT` blocked for the duration of the wait |
| Pasted text into edit field | Sanitized — control chars and embedded escapes stripped before insert |

---

## Scope

### In scope
- 7-state TUI, full-screen, Header/Main/Footer with ruled borders between sections
- Local + remote session listing, merged, live-updating, filterable, scrollable
- Create (local unnamed/named, remote unnamed/named), attach, delete (stop-then-delete)
- Theme system: compiled-in palettes from terminalcolors.com, picker, JSON persistence
- Parallel SSH fan-out with per-host status and hard timeouts
- TTY handoff to/from the herdr child with full terminal restore
- `nix run .` default flake output; `odin`, Clay and termbox2 built reproducibly in-derivation
- Feature detection for herdr 0.8.2 vs 0.9.x `machine` registry

### Out of scope
- `machine add` / any registry mutation (needs an interactive terminal; user's job)
- Session rename (no CLI support; unsafe while the server runs)
- Kitty keyboard protocol; mouse-driven interaction beyond basic focus; scrollback/copy
- Rich per-session state (workspaces/agents/panes), `api snapshot` integration
- macOS / Windows; musl
- Non-herdr multiplexers, tmux integration
- `default` session management
- Destroy-on-detach behaviour (D2 parked)

---

## Architecture

**Decision D5 = B2.** Clay's Odin binding (`bindings/odin/clay-odin/clay.odin`, 601 lines) is
**layout only** — verified: zero occurrences of `write`/`stdout`/`printf`/`draw`/`paint`/`flush`/`cell`, and
its entire output surface is:

```odin
EndLayout               :: proc(deltaTime: c.float) -> ClayArray(RenderCommand) ---   // :489
RenderCommandArray_Get  :: proc(a: ^ClayArray(RenderCommand), i: i32) -> ^RenderCommand ---  // :502
```

We keep that binding exactly as the spec requires and add the missing bottom layer ourselves on termbox2.

**Why B2 over the alternatives** — the reference experiment (`~/gits/tui_experiment/main.odin`, 1047 lines)
**is** Option A: it hand-rolls 354 lines of the bottom layer. Of its 8 fatal defects, **6 sit in the 182
lines termbox2 absorbs**:

| Defect in the experiment | Lines | B2 outcome |
|---|---|---|
| `c := key[0]` — drops every byte after the first in a read | 560–585 | ✅ gone (`tb_poll_event`) |
| **No alternate screen** — destroys scrollback; their git log shows them fighting it | 540, 618, 676 | ✅ gone (`tb_init` → `?1049h`) |
| `measure_text` returns **byte** length as width | 202–215 | ✅ gone (`tb_wcwidth`) |
| `TIOCGWINSZ = 0x5413` hard-coded Linux-only | 155, 173–182 | ✅ gone (per-platform) |
| Resize polled every frame, no `SIGWINCH` | 611 | ✅ gone (`TB_EVENT_RESIZE`) |
| Front buffer written but **never read** → no diff, full repaint + idle spin | 1007–1047 | ✅ gone (`tb_present` diffs) |
| `backgroundColor.alpha` abused as a pane-id | 768, 852–856, 941–957 | ⚠️ **ours to fix** — use `GetElementData(id).boundingBox` |
| `#partial switch` ignores `Border` / `Scissor*` | 842 | ⚠️ **ours to fix** — handle all command types |

Net: **≈182 lines deleted, ≈158 lines kept (and corrected).** B2 is *less* code than the experiment.

### Module layout

```
src/main.odin                    ~60   poll loop wiring only — no logic

terminal/termbox.odin            ~70   foreign decls → libtermbox2.a
                                     (tb_init, tb_shutdown, tb_poll_event, tb_get_fds,
                                      tb_set_cell, tb_present, tb_wcwidth, tb_width/height,
                                      tb_set_output_mode, tb_last_errno)
terminal/handoff.odin           ~140   the leave → exec → wait → re-enter sequence
input/keymap.odin                ~80   tb_event → our Key enum + modifiers
render/renderer.odin            ~160   RenderCommand → tb_set_cell:
                                      Rectangle · Border(incl. betweenChildren) ·
                                      Text · ScissorStart/End · (ignore Image/Custom safely)
render/measure.odin              ~20   Clay measure_text backed by tb_wcwidth
ui/frame.odin                   ~120   header/main/footer tree + border rules
ui/sessions.odin                ~180   filter line + scrollable table + selection
ui/edit.odin                     ~90   single-line edit, caret = display column
ui/list.odin                    ~120   generic filtered list (theme / remote pickers)
ui/float.odin                    ~60   floating error pane (FloatingElementConfig)
app/model.odin                  ~120   Session{device,label,name,running,ts} + DeviceState
app/state.odin                  ~200   the 7-state machine: (state, key) → Command
app/fetch.odin                  ~220   fan-out registry, pipe draining, merge
app/herdr.odin                  ~180   argv build, env scrub, exit-code contract,
                                      stdout/stderr split, name validation, cleanup_policy seam
app/config.odin                 ~120   JSON load/save via core:encoding/json
app/theme.odin                  ~250   compiled-in palettes (terminalcolors.com derived)
```

**Import layering** (no cycles): `main → {terminal, input, ui, render, app}`; `ui → app:model, theme`;
`app` imports no UI and no render.

### The no-threads rule

**There is no thread pool and no `core:thread` in this design.** The spec's "local instant + remote parallel"
does not need one, because every fetch is *already* an OS process:

```
startup:  local fetch inline (3 ms) → first paint
          per device:  ssh -T -o BatchMode=yes -o ConnectTimeout=5 \
                          <device> 'herdr session list --json'     [stdout = pipe, non-blocking]
loop:     poll( ttyfd, resizefd, *fetch_fd )
          fetch_fd readable → read → EOF → waitpid(WNOHANG) → parse stdout JSON only
                                   → merge rows → device: pending → ok
          own deadline (ConnectTimeout + 8 s) → SIGKILL child → device: error(timeout)
```

The ssh child's stdout becoming readable **is** the async wake event. Consequences: no self-pipe for fetches,
no mutexes, no data races, and the 5-second ceiling is enforced by `ssh` itself, not our own timer.

> **Note on `remote_flow` measurement:** a remote list is ~150 ms vs 3 ms local — **50×**. Serial fetching
> N hosts would be `150 ms × N`; the requirement is therefore load-bearing, not decorative.

### Terminal handoff

The child and our TUI share **one** alternate buffer. Verified requirements:

```
1. stop rendering; drain our input modes
2. tb_shutdown()            → SGR0 + CLEAR + leave ?1049 + exit keypad/mouse
                            + restore original termios + SIGWINCH → SIG_DFL
3. fork/exec child — INHERITED stdio, SAME foreground process group (NO setsid; it needs our ctty)
   · child cwd set explicitly to $HOME (created session's identity_cwd = spawner cwd)
   · env: HERDR_* scrubbed, TERM + COLORTERM kept
4. block SIGINT/SIGQUIT; waitpid()   — NOT self-SIGSTOP (a self-stopped process is not resumed by SIGCHLD)
5. tb_init()  (reopens /dev/tty, tb_reset(), re-enters alt screen)
6. clay.SetLayoutDimensions(...) + FORCE full repaint — never trust inherited screen state (the panic
   path skips resets)
```

Termbox2's `tb_init`/`tb_shutdown` round-trip is a **designed-for pattern** (`tb_init` guards with
`TB_ERR_INIT_ALREADY` and calls `tb_reset()` first; `tb_shutdown` fully restores termios and fds)
— `termbox2.h:2345–2388`, `3188–3212`.

### Resize

```
SIGWINCH → handle_resize() writes the self-pipe (async-signal-safe, errno preserved)  [termbox2.h:3777]
         → poll() wakes on resizefd from tb_get_fds()
         → tb_poll_event() == TB_EVENT_RESIZE{w,h}, having already run resize_cellbufs():
              cellbuf_resize(back); cellbuf_resize(front); cellbuf_clear(front); send_clear()  [termbox2.h:3766]
         → clay.SetLayoutDimensions(cols, rows)   ← MUST precede BeginLayout
         → re-describe → EndLayout → renderer → tb_present   (front buffer was cleared ⇒ FULL repaint)
```

⚠️ **The one way to break resize: if our `poll()` set omits `resizefd` and includes only the tty fd, a
resize is never noticed until the next keypress.** Named acceptance test: *resize with no further key input
→ screen updates within one frame.*

Ours regardless of termbox2: recompute visible row count · keep the selected session selected (clamp index)
· scroll so selection isn't off-screen after shrinking · recompute column truncation · "too small" message
under ~40×10 · **coalesce** a border-drag flood into one layout per frame.

### Per-host state model

```
DeviceState = pending | ok | error(timeout | unreachable | no_herdr | auth | unknown)
```
A host's error degrades **only that host's row group**. The app never blocks on a host.

---

## Verbatim rules (never violate)

These are verified facts that override intuition. Every one has bitten during research.

1. **Scrub `HERDR_ENV` from every launched child.** We run *inside* herdr (`HERDR_ENV=1` verified again
   this session). Unscrubbed, **every** create/attach fails with *"nested herdr is disabled by default"*.
   `HERDR_ENV=0` is **not** a bypass — the *presence* is the trigger. Read-only commands are unaffected.
   Also scrub `HERDR_SOCKET_PATH` / `HERDR_CLIENT_SOCKET_PATH` / `HERDR_SESSION` / `HERDR_PANE_ID` /
   `HERDR_TAB_ID` / `HERDR_WORKSPACE_ID` (an inherited socket path could target *this* live session), but
   **keep `TERM` + `COLORTERM`** so the child negotiates `SemanticFrame` rather than `TerminalAnsi`.
2. **Error JSON is on STDERR.** Both with and without `--json`. `exit 0 → parse stdout`;
   `exit ≠0 → parse stderr` for `{"error":{"code","message"}}`. **Never `2>&1` before a JSON parse** —
   the Rust panic path also writes to stderr.
3. **`delete` lies.** Unknown name → `exit 0` + `{"deleted":true}`. Always pre-check existence.
4. **Never attach to an unvalidated name.** A crashed-on-tty-init attach **still creates** a live session
   (server spawns before terminal init).
5. **Primary key is `(device, name)`**, and `device` is the **exact user-typed/configured ssh target
   string**. Normalizing to FQDN/hostname breaks the `--remote` return path. Session names are scoped per
   (host, unix-user); herdr output has **no host field**.
6. **`ConnectTimeout=5` + `BatchMode=yes` are mandatory.** Without them a black-holed host hangs
   **133 seconds**. `-tt` for attach, **`-T`** for fetches (~20 ms faster, no stderr chatter).
7. **`herdr session attach` is create-or-attach.** There is **no** `herdr session create`.
8. **Never offer `default`** — herdr refuses to delete it; `herdr-cycle` filters it out.
9. **Session names are `[A-Za-z0-9._-]` only.** Validate before invoking herdr.
10. **Never parse plain `herdr session list`** — columns are misaligned. `--json` only.
11. **`herdr --remote X session list` is invalid** (exit 2). Listing remotes = our own `ssh -T`.
    `--machine` does **not** forward `session` commands either.
12. **Feature-detect `machine` by JSON shape, not exit code** — 0.8.2 prints a help banner with exit 0.
13. **Pinned behaviour to herdr 0.8.2 available today, targeting 0.9.x.** `machine`/`--machine` are
    0.9-only. Don't let the flake silently change the runtime version.

**Exit-code contract:** `0` ok (stdout) · `1` herdr error (stderr JSON) · `2` CLI syntax/validation ·
`101` tty-init panic (Rust panic, **not** JSON) · `124` our timeout · `127` no herdr on remote ·
`255` ssh transport/auth.

### Nix / Odin landmines
- `pkgs.odin` exists (`dev-2026-09`, prebuilt on cache.nixos.org; wrapper sets `ODIN_ROOT` + clang/lld/bintools).
  **`buildOdinPackage` does NOT exist** → hand-rolled `stdenv.mkDerivation`.
- **Never assert Odin version strings** (`pkgs.odin.version = dev-2026-09` but `odin version` prints `dev-2026-10`).
- `pkgs.odin2` is an unrelated GPL3 synth. `pkgs.ols` provides both `ols` and `odinfmt`.
- **`nix develop` / `nix flake show` fail without `--no-pure-eval`** → the **package derivation must be
  fully independent of devenv**; re-verify `nix run .` after adding it.
- **Don't wrap herdr/ssh into the binary's PATH** — the user manages herdr via home-manager
  (nixpkgs 0.9.3 vs installed 0.8.2 drift). Assume from environment + clear error if missing.
- Odin: `..` range is **removed** → `..<` / `..=`; `-o:` is **optimization mode**, output is **`-out:`**;
  **`proc "c"` has no Odin `context`** → cannot allocate or `fmt` inside it.
- Clay: **zlib** license, C99 floor, verified clean under nixpkgs GCC 16.2, **do not use `-Werror`**.
  `clay.MinMemorySize()` = **5,785,280 bytes (~5.5 MiB)** — budget the arena.
- **`clay.Initialize(..., {})` installs a NO-OP error handler.** Install a real `proc "c"` handler that
  records into a **fixed buffer** (no allocation possible in `proc "c"`) and surface it in the UI later.
- **Do NOT reuse the experiment's prebuilt `.a`/`.lib`/`.o` blobs.** Build both clay and termbox2 in-derivation.
- termbox2: **MIT**, single header (`termbox2.h`, 4312 lines), `#define TB_IMPL`, needs
  `TB_OPT_ATTR_W = 32` for truecolor, **no ncurses/terminfo dependency**. Not in nixpkgs (verified absent).

---

## Dependencies

| Dep | Source | License | Notes |
|---|---|---|---|
| `odin` | `pkgs.odin` (prebuilt) | zlib | compiler; brings clang as link driver |
| `clay` | flake input, `flake = false`, pinned rev of `nicbarker/clay` | zlib | `clay.h` built → `clay-odin/linux/clay.a` (path the binding hard-codes; **zero patching**) |
| `termbox2` | flake input, `flake = false`, pinned `termbox/termbox2` | MIT | `termbox2.h` + `TB_IMPL` → `libtermbox2.a` |
| `ols` + `odinfmt` | `pkgs.ols` (devShell only) | MIT | not in the package |
| `herdr` | **runtime, from the user's environment** | Apache-2.0 | **not** wrapped into our PATH |
| `ssh` | **runtime, from the user's environment** | — | same |
| Config | `core:encoding/json` (Odin stdlib) | — | **no TOML parser needed** (D13) |
| XDG | `os.user_config_dir()` (Odin stdlib) | — | verified resolves `$XDG_CONFIG_HOME/herdr_session.json` |

**Removed from the original scout plan:** `Up05/toml_parser` (whole dependency), `mkozhukh/odin-toml`,
`dogue/odin-xdg`, TermCL, and any hand-rolled `wcwidth`/CSI-parser.

---

## Risks & Open Questions (premortem)

### Riskiest assumptions

| # | Assumption | Confidence | If wrong |
|---|---|---|---|
| A1 | **`tb_shutdown()` → child → `tb_init()` is a clean handoff in practice.** Verified by *reading* termbox2 source; **never run.** | Medium | Fall back to keeping `tb_init` alive and hand-emitting `?1049l` + mode resets around the child. **Retire this early** — it is the single highest-value early test. |
| A2 | `herdr machine list --json` field shape matches docs (`id`, `label`, ssh target, remote session, enabled) | Medium | Adapter in `app/herdr.odin` isolates parsing; feature-detect by shape. |
| A3 | Clay's `BorderWidth.betweenChildren` gives us the inter-section rules we need | Medium-High | We own the renderer, so we draw glyphs directly from `BorderRenderData.width.betweenChildren`. Fallback: explicit 1-row divider elements. |
| A4 | ssh children integrate in the same `poll()` as termbox2's fds without deadlock | Medium-High | Non-blocking reads + drain-to-EOF + our own reaper deadline. |
| A5 | Session-name timestamp parseable for names we create | High | `—` + sorted last. |
| A6 | `pkgs.odin dev-2026-09` compiles `clay.odin` unchanged | High (scout-verified) | Low risk; pin the input. |

### Failure modes

1. **Built the wrong thing.** D2 parked → sessions accumulate instead of being cleaned up like `herdr-cycle`
   did, which may surprise the user. *Mitigation:* one `cleanup_policy` seam, revisit when the box is on latest herdr.
2. **Works on the loopback fixture, breaks on a real remote.** A device-blind bug passes every `localhost`
   test because local and "remote" are the same install. *Mitigation:* the discriminating test below.
3. **Toolchain drift.** A nixpkgs bump moves Odin and breaks `clay.odin` or syntax we adopted.
   *Mitigation:* pin all flake inputs in `flake.lock`; never assert version strings.
4. **Handoff leaves the terminal broken** → user is stuck in a mangled terminal. *Mitigation:* restore on
   every path (including signals) + print `reset` hint in the `{Error}` state.
5. **0.8.2 vs 0.9.x drift during development** → the 0.9 path ships silently untested.
   *Mitigation:* feature-detect and surface *which* path was taken in a debug line in the footer.

### The acceptance test the loopback fixture CANNOT satisfy

> A bug that ignores the `device` field passes every `localhost` test, because local and remote are the
> **same install** here.

**Cheap discriminator (no second physical host required):** register the *same machine* under **two distinct
ssh target strings** — `localhost` **and** `127.0.0.1` — so the underlying sessions are byte-identical but
the device strings differ.

| Check | Passes only if |
|---|---|
| Both appear as **separate rows** for the same session name | key is genuinely `(device, name)`, not `name` |
| Filter `device:` shows both distinctly | device is carried into the view model |
| Attaching via the `127.0.0.1` row uses **`127.0.0.1`** in the `--remote` argv (not the alias, not the FQDN) | device string is verbatim through the round trip |
| Deleting one leaves the other's row intact | merge/dedup is identity-correct |

**Stronger variant (when available):** two unix users on the same box → different session namespaces under
the *same* device string. Discriminates user scoping.

**Fixture isolation requirement:** the test remote arrives **only** via `HERDR_SESSION_TEST_REMOTE` or a
single labelled dev file. `grep -rn 'localhost' src/` must return **nothing** in product code. Deleting the
fixture leaves remote support intact and fully generic. Track as a deliverable.

**Fixture safety:** never run create/attach against the fixture with a name resembling the live session
(this agent itself runs inside `HERDR_SESSION=2026-08-11-23-37-41-812`). Use `hs-t-*` scratch names and
`stop` + `delete` them afterwards; prove cleanup in the todo's acceptance output.

### Open / parked
- **D2 destroy-on-detach** — parked pending latest-herdr behaviour confirmation. Interim `never`.
- **Palette set size** — ship gruvbox-dark + ~8 more initially; extend later.
- Whether `machine list` exposes per-machine *all* sessions or only its targeted one — assume **not**, and
  enumerate via `ssh -T` regardless.

---

## Ideal State Criteria

### Core
- [ ] ISC-1: `nix run .` launches the TUI as the default flake output
- [ ] ISC-2: Every launched child has `HERDR_ENV` scrubbed
- [ ] ISC-3: All 7 states reachable with the spec's exact key bindings
- [ ] ISC-4: `device` in every row is the verbatim user-configured ssh target string
- [ ] ISC-5: Attach uses `herdr --remote <target> --session <name>` remotely / validated name locally
- [ ] ISC-6: Local rows render before any remote fetch completes
- [ ] ISC-7: Theme persists to `~/.config/herdr_session.json` and reloads on start
- [ ] ISC-8: `catppuccin-latte` present and selectable; `gruvbox-dark` is the default

### Terminal / handoff
- [ ] ISC-9: Terminal fully restored (alt-screen, cursor, termios) on every exit path including SIGTERM
- [ ] ISC-10: After a child exits, TUI re-enters alt-screen with a forced full repaint
- [ ] ISC-11: A lone Escape returns "back" with no perceptible delay
- [ ] ISC-12: Ctrl+C exits from all 7 states with the terminal restored
- [ ] ISC-13: Resizing with **no further key input** updates the screen within one frame

### Edge cases
- [ ] ISC-14: No remote can block the UI — worst case bounded by `ConnectTimeout=5`
- [ ] ISC-15: A host failure degrades only that host's rows
- [ ] ISC-16: `delete` pre-checks existence (never trusts `deleted:true`)
- [ ] ISC-17: Attach never targets an unvalidated name — no orphan sessions
- [ ] ISC-18: `default` never appears in any list
- [ ] ISC-19: Corrupt config falls back to defaults with a warning; app still starts
- [ ] ISC-20: herdr 0.8.2 (no `machine` verb) still yields a usable remote list via config fallback
- [ ] ISC-21: The `(device, name)` **two-alias discriminator** test passes (`localhost` vs `127.0.0.1`)

### Anti-criteria
- [ ] ISC-A-1: No `2>&1` before any JSON parse
- [ ] ISC-A-2: No idle spin / busy-wait when nothing changes
- [ ] ISC-A-3: No hard-coded `localhost` in product code (fixture behind one env var, grep-removable in one action)
- [ ] ISC-A-4: No Kitty keyboard protocol dependency
- [ ] ISC-A-5: No TOML parser dependency
- [ ] ISC-A-6: No thread pool / `core:thread`
- [ ] ISC-A-7: No copied code from `tui_experiment`'s main loop
- [ ] ISC-A-8: No `backgroundColor.alpha` used as a identity tag
- [ ] ISC-A-9: No committed prebuilt clay/termbox2 binaries
