# Planner Brief — `herdr-session`

**Read these first, in this order:**
1. `docs/requirements.md` — the spec (authoritative, user-written)
2. `.pi/plans/2026-10-18-herdr-session-tui/00-user-constraints.md` — hard constraints (localhost = deletable test fixture)
3. `.pi/plans/2026-10-18-herdr-session-tui/20-verified-corrections.md` — **overrides scout claims where they conflict**
4. `.pi/plans/2026-10-18-herdr-session-tui/10-open-questions.md` — **D1–D10: ASK THE USER THESE**
5. `.pi/plans/2026-10-18-herdr-session-tui/scout-herdr.md` — herdr CLI/data model/handoff
6. `.pi/plans/2026-10-18-herdr-session-tui/scout-odin-clay.md` — Clay API + 18 experiment defects
7. `.pi/plans/2026-10-18-herdr-session-tui/scout-remote-flow.md` — measured ssh/tty/latency/failure modes
8. `.pi/plans/2026-10-18-herdr-session-tui/scout-nix-packaging.md` — flake/Odin/Clay/TOML/themes

---

## What we're building

A `herdr-session` TUI in **Odin** + **Clay** (layout only), packaged in this nix flake so `nix run .`
launches it as the default output. It replaces `~/.config/home-manager/herdr/herdr-cycle.sh`.
7-state state machine, local + remote herdr sessions, parallel remote fetch, themes in
`~/.config/herdr_session.toml`. Layout: Header / Main / Footer with border lines between sections.

## GREENFIELD — nothing exists yet
Repo is one commit: a devenv flake skeleton that runs `hello`. No `.odin` files. `nix run .` currently
fails with *"does not provide … `packages.x86_64-linux.default`"*.

---

## MUST-ASK (blocking; from 10-open-questions.md)
- **D1** known-remotes source (toml / `~/.ssh/config` / both) — *`~/.ssh/config` does not exist on this host*
- **D2** destroy-on-detach policy (always / never / only-what-we-created) — *`prefix+q` only detaches*
- **D3** timestamp column source (birth time / mtime / batched remote `stat` / `—`)
- **D4** default theme (latte required but explicitly NOT default)
- **D5** renderer base: hand-rolled vs **termbox2** (recommended; port target `clay_renderer_termbox2.c`)
- **D6** platform scope (Linux only vs +Darwin; affects `TIOCGWINSZ`, `.a` linked, flake `systems`)
- **D7** UTF-8/wide-char bar in names & filter
- **D8** Ctrl+C / `ISIG` on-or-off
- **D9** repaint: true diff vs change-gated full repaint
- **D10** ESC ambiguity: legacy+timeout vs Kitty protocol — *user's terminal is **Alacritty**, which does
  not reliably support Kitty; do NOT hard-depend on it*

---

## Non-negotiable facts (verified — do not re-litigate, do not lose these)

### herdr integration
- Use `--json` everywhere. **Plain `session list` output is misaligned — never parse it.**
- Fields: `default, name, running, session_dir, socket_path`. `running` is a **live socket connect-probe**
  (proven: a planted non-socket file reports `false`).
- **NO TIMESTAMP EXISTS** in `session list --json` or `session.json`. Only `stat -c %W` (birth),
  `session.json` mtime, or the name-embedded `YYYY-MM-DD-HH-MM-SS-mmm` convention.
- Session name charset: `[A-Za-z0-9._-]` only (no colons). Reject invalid input before invoking herdr.
- `herdr session attach <name>` is **create-or-attach**. There is **no** `herdr session create`.
- `delete` **refuses running** and **refuses `default`** (herdr enforces); **never offer to delete `default`**.
- Pinned to herdr **0.8.2** (installed). `herdr machine` / `--machine` are **0.9.x-only → unusable**.
  nixpkgs carries 0.9.3 — don't let the flake silently change the runtime version.

### 🚨 Verified corrections (main session) — see `20-verified-corrections.md`
- **Error JSON is on STDERR, not stdout** (both with and without `--json`).
  `exit 0 → parse stdout` · `exit ≠0 → parse stderr for {"error":{"code","message"}}`.
  **Never `2>&1` when a JSON parse follows.** Rust panic text also lands on stderr.
- **`delete` lies**: unknown name → `exit 0` + `{"deleted":true}`. Must pre-check existence.
- **`HERDR_ENV=1` blocks every LAUNCH/attach path** with *"nested herdr is disabled by default"* (exit 1).
  We run **inside** herdr. **Must scrub `HERDR_ENV` from every child.** Confirmed fix:
  `env -u HERDR_ENV herdr --session X` clears the check. `HERDR_ENV=0` is NOT a bypass.
  Read-only cmds (`session list`) are unaffected — only launching is blocked.
- **Orphan trap reproduced**: a crashed-on-tty-init attach **still created** a live session (server spawns
  before terminal init). **Never attach to an unvalidated name.**
- Exit-code contract: `0` ok · `1` herdr error (stderr JSON) · `2` syntax/validation · `101` tty panic ·
  `124` our timeout · `127` no herdr on remote · `255` ssh transport/auth.

### ssh / remote (measured)
- **`ConnectTimeout` is mandatory**: without it a black-holed host hangs **133 seconds**.
  Use `-o ConnectTimeout=5 -o BatchMode=yes` (auth failure then fast-fails in 119 ms).
- **`-t` fails OPEN**: non-tty stdin silently downgrades to no-pty and still exits 0 → use **`-tt`** for attach.
- Use **`ssh -T`** for fetches (~20 ms faster, no stderr chatter). Fetch ≈ **150 ms** vs local **3 ms** (50×).
- **Fetch and attach are two different ssh shapes** — never mix.
- Prefer `herdr --remote <host> --session <name>` for attach (herdr owns ssh multiplexing/keepalive/config).
  Caveat: no way to pass a custom `-F`, so the device string must resolve via default `~/.ssh/config`.
- **Primary key = `(device, name)`**, never `name` alone — names are scoped per (host, unix-user) and
  herdr output has **no host field**.
- `device` must be **the exact user-typed ssh target string** (alias / `user@host` / hostname).
  Normalizing to FQDN/hostname **breaks the attach return path**.
- Remote `herdr` may be absent from a non-interactive PATH (`env -i` loses the nix profile) →
  treat `127`/`command not found` as a first-class distinct error state.
- Per-host state: `pending → ok | error(timeout|unreachable|no-herdr|auth)`. A host error must degrade that
  host's row group **only**, never the app.

### Terminal handoff (single shared alternate buffer)
- On child launch: stop rendering → **leave our alt screen + disable mouse/focus/bracketed-paste**
  (`?1049l`, `?1000/1002/1003l`, `?2004l`) → `exec` child with **inherited** stdio in the **same
  foreground process group** (NO `setsid` — it needs our ctty) → `waitpid` (NOT self-`SIGSTOP`;
  a self-stopped process isn't resumed by `SIGCHLD`).
- On child exit: re-enter alt screen, `ESC[2J ESC[H`, re-assert raw mode, **force a full repaint**.
  Do not trust inherited screen state (the panic path skips resets).
- **Block `SIGINT`/`SIGQUIT` while the child owns the tty** — the child shares our foreground pgroup.
- Set the child's cwd explicitly (e.g. `$HOME`) — the created session inherits the spawner's cwd as
  `identity_cwd`.
- Keep `TERM` + `COLORTERM` in the child env (herdr negotiates a richer render encoding with them).

### Odin + Clay
- **Clay = layout ONLY.** Emits a `RenderCommandArray`. Raw mode, ANSI output, glyphs, input parsing,
  resize, color→SGR are all ours. Local `clay-odin` is **byte-identical to upstream main** (Clay v0.14).
- **Do NOT copy the experiment's loop.** Fatal defects: `c := key[0]` drops all but the first byte of a
  read; **no alternate screen**; `measure_text` returns **byte** length as width; `backgroundColor.alpha`
  abused as a pane-id tag; full repaint every frame with a front buffer never read; mouse Y off-by-one fed
  raw to `SetPointerState`; `TIOCGWINSZ=0x5413` hard-coded Linux-only; `#partial switch` ignores
  `Border`/`Scissor*`. `report.html` **falsely** claims diffing + blocking input exist.
- Use real Clay features: `BorderWidth.betweenChildren` = inter-section rules;
  `FloatingElementConfig{attachTo=.Root, zIndex}` = floating error pane; `clip{vertical, childOffset}`
  = scrollable table; `GetElementData(id).boundingBox` instead of any alpha hack.
- Install a **`proc "c"` Clay error handler** — `clay.Initialize(..., {})` installs a **no-op**, so duplicate
  ids / arena overflow / unbalanced open-close are **silently swallowed**. NOTE: `proc "c"` has **no Odin
  `context`** → cannot allocate or `fmt` inside it; record into a fixed buffer and surface later.
- `clay.MinMemorySize()` = **5,785,280 bytes (~5.5 MiB)** — budget the arena.
- **Odin core has NO `wcwidth`, NO `ioctl`, NO terminal-size helper.** Must hand-declare `ioctl` +
  `winsize` via `foreign libc`; `TIOCGWINSZ` is Linux `0x5413` vs Darwin/BSD `0x40087468`.
- Main loop should be **`poll()`-driven** (not `O_NONBLOCK` + `sleep(16ms)` idle spin) with an
  **incremental, buffered, partial-safe** escape parser.
- Async remote fetch needs to **wake the poll loop** (self-pipe / eventfd / writable-queue signalling).

### Nix packaging
- **`pkgs.odin` EXISTS** — `dev-2026-09`, **prebuilt on cache.nixos.org**, wrapper already sets
  `ODIN_ROOT` + puts clang/lld/bintools on PATH. Odin invokes **clang as the link driver** itself, so the
  derivation needs no extra clang.
- **`pkgs.buildOdinPackage` DOES NOT EXIST** → hand-rolled `stdenv.mkDerivation`.
- `pkgs.odin` is **`broken` on musl** (`platforms = lib.platforms.unix`); `import systems` includes darwin.
  Decide the system list explicitly.
- `pkgs.odin.version` = `dev-2026-09` but `odin version` prints `dev-2026-10` — **never assert version strings**.
- `pkgs.odin2` = an unrelated **GPL3 synth**. `pkgs.ols` provides **both `ols` and `odinfmt`**.
- **Clay license = zlib/libpng** (Nic Barker, 2024). Canonical source = **`clay.h` at repo root**
  (`VERSION: 0.14`, sha256 `54aef6d5…`). Requires **C99 floor**; **verified clean with nixpkgs GCC 16.2**
  (`-std=c99 -DCLAY_IMPLEMENTATION -ffreestanding -fPIC -O2`). **Do not use `-Werror`.**
  Needs libc at link time (`memcpy`/`__stack_chk_fail`) — fine, Odin links libc anyway.
- **Proven path**: build `libclay.a` in-derivation → copy to `clay-odin/linux/clay.a` (the path the binding
  hard-codes) → `odin build`. **Zero patching.** Fetch clay as a **`flake = false`** input; keep zlib
  `LICENSE.md`; **do NOT reuse the experiment's prebuilt `.a`/`.lib`/`.o` blobs**.
- Add `packages.<sys>.default` + `meta.mainProgram = "herdr-session"`.
- ⚠️ **`nix develop` / `nix flake show` FAIL without `--no-pure-eval`** ("devenv was not able to determine
  the current directory"). The **package derivation must be fully independent of devenv**. Re-verify
  `nix run .` after adding it.
- **Don't wrap `herdr`/`ssh` into the binary's PATH** — the user manages herdr via home-manager
  (nixpkgs 0.9.3 vs installed 0.8.2 = drift risk). Assume them from the environment + fail with a clear error.
- **Odin language landmines** (the experiment predates these): `..` range is **removed** → use `..<` / `..=`;
  `-o:` is **optimization mode**, output is **`-out:`**; `proc "c"` has **no Odin `context`**.
- **TOML**: `Up05/toml_parser` (MIT, TOML 1.1.0) **verified to compile+parse under this exact Odin**.
  Gotchas: `Error` is a **struct** → check `err.type != .None` (not `!= nil`); generic
  `get(int,…)` **won't compile** → use `get_i64`; `parse_data` takes `[]u8`; `get_list` returns `^^List`
  (use `len(lst^)`); manual `deep_delete(toml.Type(table))`. Author admits it's not fully `toml-test` clean.
  **No writer chosen** — recommend hand-emitting the single `theme = "…"` line rather than adding a serialiser.
- **XDG: roll nothing** — `os.user_config_dir()` is built into `core:os` (verified resolving
  `$XDG_CONFIG_HOME/herdr_session.toml`).
- **Themes**: full hex tables are in `scout-nix-packaging.md` §f (Catppuccin palette.json v1.8.0, gruvbox,
  tokyonight, dracula, nord, everforest, rosé-pine, solarized). Ship kebab-case `catppuccin-latte` (canonical
  spelling; the user typed "catputin").
  ⚠️ **Slot model needs freezing**: Catppuccin has 26 colors (map down), **nord 16 ✓**, **solarized 16 ✓**,
  **dracula only 11**, **rosé-pine 12 with NO GREEN AT ALL**, `tokyonight-day` has **no static palette**
  (runtime-inverted). Decide: derive missing slots vs drop those themes.
  Clay `Color` is `[4]c.float` in **0–255** (not 0.0–1.0).

---

## Suggested module decomposition (to avoid the experiment's 1046-LOC monolith)
```
terminal/   raw mode, alt screen, size/ioctl, ANSI writer, restore-on-exit
input/      key event model + incremental escape parser (buffered, partial-safe)
render/     Clay RenderCommand -> cell grid -> diff -> ANSI
ui/         Clay layout components (header, footer, sessions table, filter, edit, floating error)
app/        state machine (7 states), session model+merge, config/themes, remote fan-out
main.odin   loop wiring only
```

## Acceptance tests the loopback fixture CANNOT satisfy (must be called out)
A bug that ignores the `device` field passes every `localhost` test, because local and "remote" are the
same install. Plan a discriminating check (two real hosts, or two unix-users) and label it explicitly as
requiring manual/non-fixture verification.
