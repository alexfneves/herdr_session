# Scout context — RCH-5 / RCH-6: `tests/` in Odin with `core:testing`

Repo: `/home/alexfneves/gits/herdr_session`
Explored at: `5e84fae` (2026-10-20 ~21:48 CEST). **Working tree clean** at time of reading.
Concurrent worker: RCH-3/RCH-4 landed as `81df8d0` → `a221d8d` → `fd99252` → `e6dbc9f`, plus
`5e84fae` (docs). Nothing to reconcile — no uncommitted drift observed.

Toolchain note (matters for every `core:testing` claim below):
`dev/local-build.sh:3` hardcodes `/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin`,
but `odin version` from **that path** prints **`dev-2026-10`**. All SDK line references in §7 are from
that same store path, so they are the ones this project actually compiles against.
(`dev-2026-09`, `dev-2026-10`, `dev-2026-07a` are all present in the store; do not assume which one
`pkgs.odin` from the flake resolves to without checking.)

---

## 0. AUTHORITATIVE BASELINE + SCOPE PIN (added after `02c9ced`, 2026-10-20 ~21:55 — read this first)

Two things changed while this scout report was being written. They **override §1** and frame everything below.

**A. The baseline is now measured, not reconstructed.** `50-requirement-changes.md` → **RCH-7** records a
fixture-armed, orchestrator-verified run (2026-10-20 ~21:50):

```
state 259 · app+disc 532 · tui 172 · theme 171 · resize 138 · ui 90 (6/6) · render 69 · handoff 35
TOTAL: 1461 PASS / 0 FAIL
```

Use **1461** as the pre-migration parity number, with those **per-suite** figures as the per-suite
targets. This supersedes:
* the §1 reconstruction (1,275 recorded → ~1,313) — now superseded by a direct measurement, and
* RCH-5/RCH-6's "~1,354" prose baseline — that number matches neither the recorded table nor this run.

Note the drift vs the last recorded table in `40-execution-log.md`: state 198→**259**, app 487→**532**,
tui 117→**172**, theme 166→**171**, resize 120→**138**, handoff 28→**35**. All of it is RCH-1..4
growth. The migration must be counted against **these** numbers, suite by suite.

**B. RCH-7 withdraws the folder reorg but keeps the test mandate.**
* **Out of scope:** renaming `vendor/` → `bindings/`, creating `libs/`/`assets/`, reshaping `src/`,
  **changing `nix/package.nix`'s filter semantics**, and touching Clay/termbox2 import paths for
  layout reasons. Existing layout stays.
* **In scope (unchanged from RCH-5/6):** (1) the `argv[1]` test dispatch leaves `main`; (2) `tests/`
  in Odin with `core:testing`; (3) every test-related `.sh`/`.py` replaced by Odin; (4) `nix flake check`
  actually runs them.
* **Reading of §6 for the planner:** "do not change the package filter's *semantics*" ≠ "the test
  derivation may not have its own source list". The **product** derivation must keep shipping
  `src/` + `vendor/` only; a **separate test derivation** needs its own (wider) source view. Keep those
  two facts distinct in the plan so the withdrawal is not read as blocking gate #6.

**C. RCH-3 / RCH-4 are DONE and independently verified** (source inspection + full run), even though the
worker's completion report arrived empty. Confirmed: `only_created` is the cleanup default; `at_mode_selection`
has **no** filter append (the only one lives in `filter_navigate`, reachable by the four editable states only);
`KEY_DELETE` is mapped; `{Mode selection}` highlights nothing. **The migration's job is parity with them,
not completion of them** — do not re-litigate, do not re-implement, do not let a port quietly drop their
assertions (they are worth a large share of the 1461).

---

## 1. Green baseline as previously recorded (SUPERSEDED by §0.A — kept for history)

Latest recorded per-suite totals (fixture-armed), `.pi/plans/2026-10-18-herdr-session-tui/40-execution-log.md:727-742`:

| Suite | Before P-fixes | After (recorded) |
|---|---|---|
| `app-smoke.sh` | 400 | **487** |
| `tui-smoke.sh` | 99 | **117** |
| `state-smoke.sh` | 198 | **198** |
| `theme-smoke.sh` | 166 | **166** |
| `render-smoke.sh` | 69 | **69** |
| `handoff-smoke.sh` | 28 | **28** |
| `ui-smoke.sh` | 90 (6/6 cases) | 90 |
| `resize-smoke.sh` | 120 (15/15 runs) | 120 |
| **Total `[PASS]` lines** | 1170 | **1275** |

Post-RCH-3/RCH-4 additions are recorded only for the two new `tui` scenarios
(`git show e6dbc9f`: `del-key` **18 checks**, `mode-filter-immutable` **19 checks**; `roundtrip`
re-inverted to **18** from **17**). That reconstructs to roughly **1,313**, whereas
`50-requirement-changes.md:332` mandates **~1,354** as the migration baseline.

> **ACTION FOR THE PLAN (not a scout decision):** the per-suite pre-migration counts must be
> **re-measured once, in one run, with the fixture armed**, and frozen into the migration doc.
> The static call-site counts below are *not* the baseline and must never be used as one:
> loops multiply assertions at runtime (proved: `state_cases.odin` = 139 static callsites → 198
> runtime `[PASS]`/`[FAIL]` lines; `scenario_del_key` = 15 static `check()` sites → 18 runtime
> checks because the rune loop runs twice).

Static totals for scale (`grep`-derived, package `main` test files):

| File | Lines | Static assertion callsites |
|---|---|---|
| `src/app_cases.odin` | 1265 | 119 |
| `src/app_live.odin` | 1096 | 83 |
| `src/fetch_cases.odin` | 689 | 35 |
| `src/fetch_live.odin` | 735 | 39 |
| `src/render_cases.odin` | 768 | 49 |
| `src/state_cases.odin` | 1360 | 139 |
| `src/theme_cases.odin` | 821 | 117 |
| `src/ui_cases.odin` | 1521 | 101 |
| `src/main.odin` (cases + probes) | 1612 | 24 |
| **Total** | **8,267** | **706** |

Product-only lines: ~8,730 (`app`, `ui`, `render`, `terminal`, `input` + the TUI half of `main.odin`).

---

## 2. Suite-by-suite inventory

### 2.1 `dev/app-smoke.sh` (15.8 KB, `set -uo pipefail`)
- **Sources `dev/lib.sh` (line 31)** then **overrides `assert_formatted` (80) and `tally` (99) locally, lines 80-122**
  with the older 2-counter (no `[SKIP]`) versions. So this suite does **not** get lib.sh's SKIP
  accounting — an important asymmetry (see §2.9).
- `require_fresh_bin "$BIN" src` at line 33. `BIN` default `/tmp/hs` (line 28).
- Sections and the `src/` case entrypoints each invokes:

| Step | Invocation | Case in `src/` | Fixture required |
|---|---|---|---|
| 1/4 `app-unit` | `"$BIN" app-unit` (line 127) | `case_app_unit` (`app_cases.odin:69`) | no |
| 2/4 `app-live` | `$BIN app-live` (line 147) | `case_app_live` (`app_live.odin:65`) | `HERDR_SESSION_TEST_REMOTE`/`_ALIAS` (self-skips) |
| 3/5 `fetch-unit` | `$BIN fetch-unit` (line 165) | `case_fetch_unit` (`fetch_cases.odin:37`) | no |
| 4/5 `fetch-live` | `$BIN fetch-live` (line 184) | `case_fetch_live` (`fetch_live.odin:57`) | REMOTE + `_UNREACHABLE` |
| 5/6 discriminator | `python3 dev/device_discriminator.py` (line 209) | — (drives `tui`) | REMOTE **and** distinct `_ALIAS` |
| 6/6 anti-criteria greps | pure `grep` over `src/` (lines 227-275) | — | no |

- **Fixture:** only via env (`HERDR_SESSION_TEST_REMOTE`, `_ALIAS`, `_UNREACHABLE=192.0.2.201`); no
  host names in the script beyond the RFC-5737 default.
- **Teardown:** `trap cleanup_scratch EXIT INT TERM` (line 69) stops+deletes three hard-coded
  `hs-t-*` names, then asserts the `herdr session list --json` name set equals the pre-run snapshot
  (lines 51-68). That round-trip is itself **1 counted assertion**.
- **Anti-criteria grep set (22 counted checks):** `"herdr"` outside `src/app/herdr.odin` (1), then for
  each of 4 `PRODUCT_DIRS` (`src/app`, `src/render`, `src/terminal`, `src/main.odin`): `2>&1`,
  `localhost|127.0.0.1`, `core:thread`, `toml`, `kitty|\[>1u` (4×5=20), plus "nothing hands `default`
  to a launch/attach builder" (1). **Note the driver files are deliberately excluded** from these greps
  (comment at lines 224-226) because they legitimately construct the illegal inputs they assert against.
- **Verdict:** custom (`STALE_BIN` read explicitly at line 279, then `FAIL_TOTAL`), **not**
  `smoke_verdict`, because this suite resets `PASS_TOTAL=0/FAIL_TOTAL=0` at lines 71-72.
- **Recorded:** 487 `[PASS]` (was 214 → 339 → 400 → 487 through the plan).

### 2.2 `dev/state-smoke.sh` (11 KB)
- **Does NOT source `dev/lib.sh`** — re-implements `tally` (lines 37-57) and `assert_formatted`
  (lines 59-71) locally. **No `require_fresh_bin`.** Staleness gate absent.
- Sections:
  1. `state-machine` → `case_state_machine` (`state_cases.odin:240`) — prints the full (state × key)
     grid into the transcript, asserts each rule.
  2. `state-offline` → `env -i PATH=/nonexistent HERDR_ENV=1 HERDR_SESSION=… $BIN state-offline`
     (line 96) → `case_state_offline` (`state_cases.odin:1347`).
  3. **Source-surface greps** (lines 115-165; `grep_absent` defined at 118): 12 `grep_absent` checks over `src/app/state.odin` and
     `src/input/keymap.odin` (comments stripped first via `sed 's,//.*,,'`), e.g. no `core:os`,
     no `core:sys/posix`, no `core:net`, no `clay|termbox`, no `core:time|sleep|peek_event`
     (ISC-11: no Escape timeout exists), no `union {` (O10 tagged struct), no Kitty, no
     `os.|posix.|net.|open(|read(|write(` shape.
  4. Safety: real `herdr session list` byte-identical before/after (skipped if no `herdr` on PATH).
- **Recorded:** 198 = `state-machine` 128 + `state-offline` 54 + 16 greps/safety
  (`todos.md:1156`).

### 2.3 `dev/render-smoke.sh` (5.9 KB)
- **No `lib.sh`**, own `tally` (lines 41-47) with **NO zero-assertion rule** — a 0-PASS/0-FAIL log
  contributes nothing and still goes green. **No `require_fresh_bin`.** This is the weakest gate of the eight.
- Every terminal case runs under `script -q -e -c "stty rows 40 cols 120; $BIN <case>"` (`run_pty`, line 33).
- Cases: `measure` (offline), `render`, `clip`, `clay-error`, `layout-dump` (`render-smoke.sh:125` — dump only, **0 assertions**).
- Plus **10 wire-level `expect_wire` checks** over the pty typescript (lines 85-94; helper defined at 52): truecolour SGRs
  (`38;2;255;60;60` etc.), box-drawing glyphs `─ │ ┌`, CJK `中`, emoji `😀`, and a negative check
  that no `ESC[38;5;` indexed-colour fallback appears.
- Cell-level assertions live **inside the binary**: `cell_at`/`glyph_at` read termbox's **back buffer**
  via `tb_get_cell(x,y,back=1,&ptr)` (`render_cases.odin:162-171`), and `dump_rows` renders bands as
  text for the transcript.
- **Recorded:** 69.

### 2.4 `dev/handoff-smoke.sh` (11 KB)
- Sources `lib.sh` (line 16), `require_fresh_bin` (line 22), **`ALLOW_SKIP=0` explicitly** (line 28),
  final gate = `smoke_verdict "HANDOFF"`.
- **Cases:** `probe` (offline), `double`, `handoff` (child `sleep 2`, post-handoff key fed at +4 s),
  `child $HOME sh -c 'exit 7'` (exit-code propagation), `child … env_probe.sh` (HERDR_* scrub /
  pgroup / cwd), `child … sig_probe.py` (SIGINT to the **process group** while the child owns the tty),
  `sig-term` loop over `TERM` and `HUP` with expected 143/129.
- **Two child probe scripts are written at runtime into `$OUT/probes/`** (lines 37-81: `env_probe.sh` at 37, `sig_probe.py` at 46): a POSIX `sh`
  probe and a **Python** probe (`sig_probe.py`) that installs SIGINT/SIGQUIT handlers and prints
  `SigBlk` masks from `/proc`. **These are Python and are covered by RCH-6 gate #1** — they must go too.
- **`check_stty` (line 86)** — the termios round-trip assertion (`stty -a` before == after) for
  every `run_pty` case; verdicts are appended to a separate `$STTY_LOG` and tallied **once** at the end
  (line 250) to avoid double counting.
- SIGTERM/SIGHUP (`for SIG in TERM HUP` at line 205) add 3 counted checks each (exit code, `?1049l` present, termios unchanged), lines 227-245.
- `stream_order.py` is called on two typescripts (helper at 128; calls at 159 and 200) — **informational only, 0 assertions** (§3.5).
- **Recorded:** 28.

### 2.5 `dev/ui-smoke.sh` (2.4 KB)
- **No `lib.sh` at all.** Own loop + own pass rule:
  `grep -q 'RESULT: PASS' && ! grep -q '[FAIL]'` (line 48). **A case that prints `RESULT: PASS` with
  zero `[PASS]` lines counts as a green case "(0 checks)"** — no zero-assertion guard. **No freshness gate.**
- `CASES` is overridable; default 6: `ui-frame ui-sessions ui-shrink ui-edit ui-list ui-float` (line 13).
- **Keystroke feeding:** `{ sleep 1; input_for "$case"; } | timeout 40 script -q -e -c "stty rows 40 cols 120; $BIN $case"`.
  The 1-second delay is load-bearing and documented (lines 40-41, comment at 38-39): termbox consumes pending bytes during
  `tb_init` (terminal identification responses), so t=0 input is eaten.
- Per-case inputs: `ui-sessions`←`api`; `ui-edit`←`a世b😀c`; `ui-list`←`ESC[B ESC[B TAB to`; `ui-float`←`CR`.
- **Recorded:** 90 checks / 6 cases green.

### 2.6 `dev/theme-smoke.sh` (5.6 KB)
- **No `lib.sh`.** Own `record()` (line 27) sums pass/fail per case. **A case emitting nothing
  yields 0/0 and never enters `CASES_FAILED` → green with zero checks.** No freshness gate.
- In-process cases (line 64): `theme-set theme-resolve config-parse config-save config-live colour-wire`
  → `case_theme_set` (`theme_cases.odin:141`), `case_theme_resolve` (253), `case_config_parse` (329),
  `case_config_save` (453), `case_config_live` (618), `case_colour_wire` (711).
- PTY cases (line 69): 7 `theme_drive.py` scenarios (see §3.3).
- **Hygiene block (lines 58-133; `h()` helper at 79, TOML grep at 101):** real `~/.config/herdr_session.json` md5 before==after;
  `XDG_CONFIG_HOME` non-leak into the caller; no TOML in non-comment `src/` lines; no XDG library import;
  no `localhost` in `src/`; temp-dir accounting under `/tmp/hs-t6-*`.
- **Recorded:** 166 total.

### 2.7 `dev/tui-smoke.sh` (7.5 KB) — the strongest harness today
- Sources `lib.sh` (line 28), `require_fresh_bin` (line 32), final gate `smoke_verdict "TUI"`.
  Resets `PASS_TOTAL/FAIL_TOTAL` at lines 68-69 (hence lib.sh's `STALE_BIN` stickiness matters).
- `run_scenario NAME [fixture]` (lines 84-106): records a `skip()` when fixture is unarmed; runs
  `tui_drive.py <name>` into **its own log**; `assert_formatted`; `tally`; and the extra P2-3 rule —
  *a driver that exits non-zero while logging no `[FAIL]` is still a failure* (lines 101-104).
- **Scenario list (`tui-smoke.sh:129-146`, 17 invocations + `run_guards`):** `boot-local`, `sigterm`, `no-orphan`,
  `state-mode_selection`, `state-name_local`, `state-remote_server`, `state-name_remote_named`,
  `state-attach`, `state-delete_session`, `state-theme`, `state-error`, `boot-remote` (fixture),
  `roundtrip` (fixture), `del-key`, `mode-filter-immutable`, `refresh-key`, `delete-notice`.
- **Guard cases (in-process, `run_guards`, lines 112-127):** `guard-attach local hs-t-does-not-exist-99`,
  `guard-attach local default`, `guard-delete local hs-t-never-created-77` →
  `case_guard_attach` / `case_guard_delete` (`main.odin:1504`, `main.odin:1521`).
- Teardown trap: delete all `hs-t-*` + prove the session list is restored.
- **Recorded:** 117 → ~154 after RCH-3/RCH-4 (`+18 del-key`, `+19 mode-filter-immutable`).

### 2.8 `dev/resize-smoke.sh` (4 KB)
- Sources `lib.sh` (line 14), `require_fresh_bin` (line 21), `smoke_verdict "RESIZE"`.
- `REPS=3` × 5 scenarios = 15 runs, each into **its own log file** (`slog=` at 52; comment at 55-60: never
  concatenate, or a later scenario inherits earlier PASSes).
- Uses `classify_log` (call at line 61; PASS/SKIP/EMPTY/FAIL) — the **EMPTY → FAIL** rule is what stops "driver printed
  nothing" reading as a pass. Also `assert_formatted` per run.
- Scenarios: `resize-no-key`, `flood`, `too-small`, `eintr-safe`, `selection-shrink` (needs fixture).
- **Recorded:** 120 (15/15). Plan convention counts the older 5-run shape as 40 (see §1 counting note).

### 2.9 Cross-suite gate matrix (what is actually enforced where)

| Gate | app | state | render | ui | theme | handoff | tui | resize |
|---|---|---|---|---|---|---|---|---|
| sources `lib.sh` | yes (but overrides) | **no** | **no** | **no** | **no** | yes | yes | yes |
| zero-`[PASS]`-⇒-FAIL | yes | yes | **NO** | **NO** | **NO** | yes | yes | yes |
| `[SKIP]` counted | **no** (local override) | n/a | n/a | n/a | n/a | yes | yes | yes |
| `ALLOW_SKIP` honoured | **no** | n/a | n/a | n/a | n/a | yes (`=0`) | yes | yes |
| `require_fresh_bin` | yes | **no** | **no** | **no** | **no** | yes | yes | yes |
| `assert_formatted` (`%!`) | yes | yes | **no** | **no** | **no** | yes | yes | yes |
| `smoke_verdict` used | **no** (custom) | **no** | **no** | **no** | **no** | yes | yes | yes |
| driver rc considered | exit code printed only | printed only | printed only | no | no | no | **yes** (P2-3) | via `classify_log` |

**Implication for the migration:** parity is not "each suite keeps what it has" — the target must apply
the **strongest** rule set uniformly, or migrating the weak suites (render/ui/theme/state) will carry
their holes forward. RCH-6's "zero assertions = failure" rule makes the render/ui/theme gaps
non-portable as-is.

---

## 3. Python pty-driver capability spec (what an Odin replacement must replicate)

### 3.1 `dev/tui_drive.py` (1245 lines) — the foundation everything else imports

**pty ownership (`Pty.__init__`, lines 201-241)**
- `pty.openpty()` → `(master, slave)`. The parent **keeps the slave open on purpose** (comment lines
  15-18): it is the only way to `tcgetattr` the terminal's termios **after the child dies**. This is
  the entire SIGTERM-restores-the-tty proof mechanism.
- `TIOCSWINSZ` on the slave before spawn to fix initial geometry (line 206).
- `termios.tcgetattr(slave)` snapshot **before** spawn (line 209) = the round-trip reference.
- Child: `os.fork()` → `close(master)` → `os.setsid()` → `ioctl(slave, TIOCSCTTY, 0)` →
  `dup2(slave, 0/1/2)` → close slave if >2 → optional `chdir` → `os.execve(BIN, [BIN]+args, env)`.
  On failure: write to stderr, `_exit(127)`.
  → **Odin equivalent:** `posix.fork` (`unistd.odin:338`), `posix.setsid` (819), `posix.dup2` (181),
  `posix.execve` (290), and **`TIOCSCTTY` must be declared by hand** — `core:sys/posix` has **no
  `ioctl` proc** and **no `openpty`/`forkpty`** (verified: no matches in
  `.../share/core/sys/posix/*.odin`). Precedent for hand-declaring: `src/ui_cases.odin:346-354`
  (`foreign import odin_c "system:c"` + `ioctl` + `TIOCSWINSZ = 0x5414`).

**Observation**
- `read(wait=0.2)` (lines 245-268): `select.select` on master, `os.read(65536)`, timestamps each burst
  `(t_rel, bytes)` into `self.bursts`, feeds the `Screen` model, accumulates `self.raw`.
- `wait_screen(needle, timeout, pump)` (lines 270-281): returns the **relative time the needle first
  appeared on the modelled screen** — not in the byte stream.
- `watch_screen(labels, timeout, pump)` (lines 283-298): **concurrent first-seen times for N labels**.
  Documented rationale (lines 285-288): sequential `wait_screen` calls "timestamp the look, not the
  arrival" — any port must keep the *pending-set* shape or timing evidence becomes meaningless.
- `resize_latency(rows, cols, timeout)` (lines 305-318): time to the **first byte** of the repaint
  after `TIOCSWINSZ` (comment: measuring the window, not the arrival, reported our own timeout as
  app latency).
- `resize()` (lines 320-325): `TIOCSWINSZ` on the **master** → kernel SIGWINCH → termbox self-pipe.
  The `Screen` model follows the terminal, not vice versa.
- `written` counter: bytes **we** sent. Used as proof of "no key was pressed" (ISC-13).
- `alive()` / `exit_info()` / `kill()`: `waitpid(WNOHANG)`; `exit_info` renders `128+N (killed by N)`.
- `cpu_ticks()` (lines 355-366): `/proc/<pid>/stat` utime+stime, **indexed from the END of the field
  list** because `comm` may contain spaces.
- `termios_now()` (line 368): `tcgetattr(slave)`.

**Terminal emulation (`Screen`, lines 78-198) — the largest single porting item**
- Incremental UTF-8 decoder (`codecs.getincrementaldecoder("utf-8")(errors="replace")`) so a rune split
  across reads cannot corrupt the grid.
- Escape handling for every family termbox's terminfo emits: `CSI`, `OSC … BEL`, `ESC ( X` / `ESC ) X` /
  `ESC # 8`, and a generic 2-byte fallback. Comment lines 122-129 records a real bug: missing `ESC ( B`
  smeared `"(B"` into the grid and turned `delete_session` into `delete_sess(Bn`.
- CSI verbs handled: `H`/`f` (abs position), `A/B/C/D` (relative), `d`, `` ` ``, `J` (0/2), `K` (0/1/2).
  SGR (`m`) and all DEC private (`?`) modes are ignored for content.
- Control chars: `\r`, `\n`, `\b`, `\t` (+8).
- **Wide-character placement** (`_put`, lines 96-107) using `char_width` (lines 66-72):
  `unicodedata.combining` / categories `Mn, Me, Cf` → 0; `east_asian_width in (W, F)` → 2; else 1.
  A width-2 glyph blanks the following cell.
  → **Odin has no `unicodedata`.** The natural (and *more faithful*) substitute is
  **`termbox2.tb_wcwidth`**, which is the width authority the product itself uses
  (`render/measure.odin`, and `case_probe` asserts `tb_wcwidth('A')==1` / `U+4E00==2`,
  `main.odin:169-176`). Adopting `tb_wcwidth` also removes a Python-vs-app discrepancy, but note it is
  **not an exact match** for Python's `unicodedata` on some combining marks — a port that changes width
  behaviour will change `del-key`'s rune-delete evidence. Flag and verify per-rune.
- **Why a screen model exists at all** (comment lines 55-76): termbox emits a **cell diff**, so grepping
  the raw stream for a word fails on a *correct* render (`delte_sss`). Any port that greps bytes instead
  of modelling the screen **loses the assertion**. This is the single most important fidelity requirement.

**Scenarios and assertion sets (94 static `check()` sites; runtime counts differ)**

| Scenario | Static checks | Core claims |
|---|---|---|
| `boot_local` (430) | 10 | paints <4 s; first frame already carries a LOCAL row; footer `local ok \d`; **5 s idle ≤ 2 clock ticks**; resize with **zero bytes written by us**; etc. |
| `boot_remote` (489) | 7 | needs fixture; `watch_screen` over 6 footer tokens; **local rows before remote arrives**; dead host resolves ≤6.5 s; only the dead host degraded; key answered mid-fetch; Ctrl+C quits |
| `state(name)` (575) | 6 × 8 invocations | footer marker is `"<state>  ·  "` (**not the bare word** — comment lines 600-602: `"attach"` appears in key hints, so a bare-word match proves nothing); Ctrl+C quits; exit 0; `?1049l` seen; termios restored |
| `roundtrip` (619) | 18 | create → child owns tty → `ctrl-b q` → repaint ≥500 bytes → footer reports `cleanup_policy=only_created` + "stopped and deleted", **old `never`/`left running` asserted ABSENT**, herdr itself confirms destruction, list refreshed-not-blanked, delete picker has no ghost, Ctrl+C, termios |
| `del_key` (774) | 15 → 18 runtime | `ESC[3~` shortens the real filter line; empty-filter Del harmless; table re-widens; **whole-rune deletion** for a 3-byte CJK and 4-byte astral with no U+FFFD left |
| `mode_filter_immutable` (890) | 9 → 19 runtime | 23 stray keys leave the filter EMPTY and row count unchanged; six mode keys still work right after; the same typing **does** reach the filter in `{Attach}`. Explicit note (lines 930-934) that a whole-screen single-char scan is worthless (`p` ∈ `pending`, `m` ∈ `mode_selection`) |
| `sigterm` (973) | 5 | exits, 128+15, left alt screen, termios matches snapshot |
| `no_orphan` (996) | 5 | runs the binary's own `guard-attach`/`guard-delete` as subprocesses and greps **`errno=10`** (ECHILD from `waitpid(-1,WNOHANG)`) as proof nothing was forked, plus herdr's list unchanged |
| `delete_notice` (1079) | 10 | runs against an **on-PATH `herdr` shim** (`SLOW_HERDR`, lines 1063-1077, + `slow_herdr_dir` 1079-1095) that answers `session list` with one fabricated row and sleeps 2 s on stop/delete; asserts `working:` reaches the tty **< 1 s after the Enter keypress** and the final verdict lands after ≥2 s, inside budget; **no real session touched** |
| `refresh_key` (1164) | 8 | footer carries a list-age token; 2.5 s idle ⇒ not `list now`; `Ctrl-L` → `list re-read` + `list now`; entering `{Attach}` and `{Delete}` each self-refresh |

**herdr side-access (lines 379-414)** — `herdr_cli()` scrubs `HERDR_ENV`, `HERDR_SESSION`,
`HERDR_SOCKET_PATH` and shells `herdr session list --json`; `session_names()` parses it.
→ **`app.run_capture(argv, timeout)` (`src/app/herdr.odin:298`) already implements the same
parent-side-resolve-then-exec + capture contract and is importable from `app`.** `core:encoding/json`
covers the parse. This part ports trivially.

**`base_env()` (416-427):** strips every `HERDR_*` from the child env and merges the scenario's extras;
forces `TERM=xterm-256color` when unset.

### 3.2 `dev/resize_drive.py` (466 lines) — imports `tui_drive` and reuses `Pty`/`base_env`
Distinct capabilities:
- **Trace channel:** spawns with `HS_TUI_TRACE=/tmp/hs-resize-trace.txt`; `quit_and_trace()` (lines 84-98)
  Ctrl+C's the app and then **reads the file the app wrote at exit**; `field()`/`total_field()` (lines
  100-125) parse `key=<int>` out of `resize resizes=… passes=… max_run=… too_small_paints=… eintr=…`
  and `total=… errs=… frames=…`.
  → Producer side: `tui_dump_trace` (`src/main.odin:1252`, gated on `HS_TUI_TRACE`) and the counters +
  format live in **`src/terminal/resize.odin` `Coalescer` / `summary()` (lines ~150-175)** — an
  *importable* package. The **format string is the contract**: `resizes=%d passes=%d max_run=%d
  ratio=%.1f too_small_paints=%d eintr=%d`. Any change breaks the port; freeze or replace with a
  structured dump deliberately.
- **SKIP protocol:** `skipped(label, why)` (lines 48-61) emits `[SKIP]` and returns 77 from `main()`
  when a scenario's *only* result is a skip — the wrapper's way to tell skip from pass.
  `core:testing` has **no skip concept** (§7).
- Scenario specifics: `flood` throws 30 unthrottled `TIOCSWINSZ` and asserts `passes*2 <= resizes`
  when `resizes>=2` (app coalesced) **or** `passes <= 1` when the kernel merged them (lines 213-227,
  with the reasoning spelled out); asserts the last frame is the **final** geometry; `too-small` walks
  `9x120, 40x39, 5x20, 2x5` asserting the notice replaced the spine (`─` rule rows == 0) and no line
  exceeds the width, then recovery at 40x120; `eintr-safe` asserts a **causal** response —
  stream silenced, then Down produces `>3` bytes (more than the 3-byte key, so a repaint, not echo).

### 3.3 `dev/theme_drive.py` (387 lines) — imports `Pty`, `check`, `results`, `base_env` from `tui_drive`
- Adds the **config aim**: `env_for(d)` forces `XDG_CONFIG_HOME` to a throwaway dir (comment 55-61:
  must be set, never inherited, or the suite edits the developer's real config).
- **Raw-wire assertions** rather than screen text: `sgr_bg_of`/`sgr_fg_of` regex the accumulated raw
  bytes for `48;2;r;g;b` / `38;2;r;g;b` (lines 64-70). Used to prove truecolour end-to-end,
  that the palette's near-black `#1d2021` is not collapsed to SGR 39/49, and that the config theme
  is on the wire **in the first frame** (`p.written == 0`).
- Screen-level: selection-bar highlight detection (`▸` / `>` / `(current)`), picker row listing.
- Scenarios: `picker-preselect`, `apply-persist` (2 spawns — file drives the next boot),
  `corrupt_warning`, `unknown_theme`, `sgr_truecolour`, `black_is_black`, `remote_from_config`
  (host only in JSON; appears as its own device row with a status word).
- **`picker-preselect` depends on a real theme name/SGR table**: tokyonight-night `#1a1b26`, accent
  `#7aa2f7`; latte `#eff1f5`, `#4c4f69`, `#8839ef`; gruvbox `#282828`, `#1d2021`. These hard-coded
  colours must match `src/app/theme.odin`'s palette table exactly or the port silently checks nothing.

### 3.4 `dev/device_discriminator.py` (172 lines) — imports `Pty`, `base_env`, `check`
- Table parsing by **column offsets**: `DEVICE_W = 12`, rows detected by
  `re.search(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d", line)`; `devices_in()` = first 12 chars stripped;
  `names_in()` via `\d{4}-…\.\d{3}\s+\w+\s+(.*)$`.
- Assertions: same name appears as **two rows**, with **different devices**, specifically PRIMARY and
  ALIAS verbatim; filtering by either target narrows to that device alone, both directions.
- **Explicitly documents what it does NOT prove** (lines 118-146): "attach carries the selected row's
  device" is *not* checked here — that proof lives at argv level in `app-live`
  (`attach_target_argv`, `src/app/exec.odin`), because a footer-string check would pass with a
  completely device-blind implementation. **Preserve this reasoning in the port; do not "add coverage"
  by weakening it into a footer grep.**
- **BUG to not replicate:** the exit-code computation at line 163 is
  `bad = [r for r in results if not r[1]]` — `r[1]` is the *label*, not the boolean, so `bad` is
  always empty and **this driver always exits 0**. Today the failure signal comes only from the bash
  `tally` over its log. RCH-6's single-Odin-entrypoint design must not inherit this.

### 3.5 `dev/stream_order.py` (31 lines)
- No assertions. Replays a `script` typescript and prints byte offsets of
  `?1049h` / `?1049l` / `CHILD_GOT_SIGNAL` / "FORCED full repaint".
  Pure transcript aid. **Retiring it loses zero verification strength** — but note the "we leave the alt
  screen before the child writes" claim is therefore **displayed, never asserted** today; if the plan
  wants it as a real assertion, that is a *new* check, not a port.

### 3.6 Fidelity verdict on a `posix.openpty`-style Odin driver
Nothing in the Python drivers is Python-specific **except**:
1. `unicodedata` (width) — replace with `tb_wcwidth`, with per-rune verification for combining marks.
2. `codecs` incremental UTF-8 — trivial to hand-roll or use `core:unicode/utf8` with a carry buffer.
3. `select` — `posix.poll` / `core:nbio`.
4. `openpty`/`forkpty`/`ioctl` are **absent from `core:sys/posix`** → declare them via
   `foreign import` (precedent `src/ui_cases.odin:346-354`).
5. **`Screen` must be ported, not avoided.** A byte-grep port is a regression, full stop.
Everything else (fork/setsid/dup2/execve/waitpid/kill/tcgetattr/tcsetattr, `/proc` reads,
`WIFEXITED`/`WIFSIGNALED`/`WEXITSTATUS`/`WTERMSIG` — `sys_wait.odin:92-105`) exists.

---

## 4. Test code inside the product — the `main`-package dependency list (THE BLOCKER)

All `*_cases.odin` / `*_live.odin` are `package main`. Measured dependency on `main`-package symbols:

| # | Symbol (defined in `src/main.odin`) | Used by | Port cost |
|---|---|---|---|
| 1 | `check` (`main.odin:58`) | **all 8 test files** (~620 calls) | Replace with `testing.expect`/wrapper. Mechanical but voluminous. |
| 2 | `say` (`main.odin:50`) | all 8 (~180 calls) | Replace with `log`/`testing` output. |
| 3 | `any_failed` (`main.odin:44`) | all 8; `return !any_failed` everywhere; **explicit save/restore** in `state_cases.odin:1349-1358` | **No `core:testing` equivalent.** `testing.failed(t)` is per-test and derived from `error_count`; there is no cross-test "did anything fail" and no way to isolate a sub-block's failures. Needs a wrapper or redesign. |
| 4 | `enter_terminal` / `leave_terminal` (`main.odin:125`, `:137`) — `tb_init` + `OUTPUT_TRUECOLOR` + `tb_hide_cursor` | `render_cases.odin` ×4 pairs (286,287,413,465,466,555,578,579,738,739,766), `ui_cases.odin` (`bring_up` 182 + 6× `defer leave_terminal()`) | Move to a shared **`terminal`** proc or a `tests/support.odin`. Cheap, but must happen. |
| 5 | **`diag_head` (`main.odin:963`)** — a **PRODUCT** helper (called by `tui_host_line` at `main.odin:949`) | `app_cases.odin:1046-1099` (7 assertions on rune-boundary truncation) | **Hard blocker:** product code that lives in `package main` cannot be imported by `tests/`. Must move to `app` or `ui`. Leaving it in `main` means silently losing the P3-12 truncation proof. |
| 6 | **`KEYS_MODE` (`main.odin:1162`)** — product data (also `KEYS_ATTACH/DELETE/NAME/PICK/THEME/ERROR`, 1173-1212) | `ui_cases.odin:505-532` (footer hint-overflow checks at 80/100 cols) | **Hard blocker:** move the hint tables to `ui` (they are `[]ui.Key_Hint`) or lose the footer-overflow suite. |
| 7 | `usage` (`main.odin:1450`) | `app_cases.odin` (1 error path) | Trivial. |
| 8 | **Repaint-hook wiring:** `TUI_ACTIVE` (1539), `tui_repaint_hook` (1541), `FRAMES_PAINTED` (78), `force_repaint` (118), and `main()`'s `terminal.set_full_repaint(tui_repaint_hook)` (1550) | `case_handoff` asserts `FRAMES_PAINTED >= 1` (`main.odin:227`); `case_child` likewise (272) | A `tests/` binary must **register its own repaint hook** before driving `terminal.handoff_run`. Easy, but the test must not accidentally depend on `main`'s `tui_paint` path. |
| 9 | `terminal.install_terminal_restore_handlers()` (`main.odin:1551`) | the SIGTERM/SIGHUP round-trip proofs | Stays in the product (it *is* the behaviour under test); the pty driver observes it. |
| 10 | `tui_dump_trace` + `HS_TUI_TRACE` (`main.odin:1252`, counter side `terminal/resize.odin`) | all of `resize_drive.py`'s numeric evidence | Keep the seam. Consider exposing the counters through `terminal` only, and keeping the dump in `main`. |
| 11 | **`tui_fixture_remotes` (`main.odin:443`)** — reads the three fixture env vars into `[]app.Remote` | every fixture-armed pty scenario | **Decision required:** this is *fixture plumbing living in the product binary*. RCH-5 says "no test code in the product". If it is removed, the pty suite needs a different fixture injection path (write a real config file under a temp `XDG_CONFIG_HOME` — but see the RCH-3 trap: **moving `XDG_CONFIG_HOME` moves herdr's own state dir** and makes `herdr session list` come back empty; `60-handoff-notes.md`, added in `5e84fae`). Recommend keeping it and calling it out explicitly as a supported dev seam rather than pretending it is gone. |
| 12 | `write_pidfile` + `HS_PIDFILE` (`main.odin:141-153`) | handoff SIGINT-group-kill and SIGTERM cases (harness handshake `<pid> <pgid> <sid>`) | Test scaffolding in the product. Either keep it, or have the Odin driver discover the pid itself from `fork`. Small. |
| 13 | `home_dir` (`main.odin:299`) | `case_handoff` | Trivial. |

**Test-local helpers that move with the tests (no blocker):**
`say_raw` (`app_cases.odin:61`), local `eq/eq_i/eq_int/ne_i/to_bytes` (`app_cases.odin:35-60`),
`eq_code`/`check_int` (`app_live.odin:57,61`),
`expect_state`/`expect_cmd`/`expect_noop` (`state_cases.odin:220,225,232`),
`expect_cell` (`state_cases.odin:400` — a *transition* cell, not a screen cell),
`clay_start`/`cell_at`/`glyph_at`/`dump_rows`/`paint_cmds`/`render_and_present`/`find_text_loc`
(`render_cases.odin:38-186`), `bring_up`/`shrink_pty` + `Win_Size`/`TIOCSWINSZ`/`ioctl`
(`ui_cases.odin:181,340-378`).
All of these only need `clay`, `termbox2`, `render`, `ui`, `app` — all importable.

**Answer to the blocker question:** *Mostly movable, but not "as-is".* Two hard blockers
(**`diag_head`** #5 and **`KEYS_MODE`** #6) are **product symbols trapped in `package main`** and must be
relocated to an importable package before their tests can move, or those tests are deleted with the file.
Plus `any_failed` (#3) has no `core:testing` analogue and is used in ~30 places including a
save/restore pattern. Everything else is mechanical.

---

## 5. `src/main.odin` argv dispatch — every case, for safe removal

`main()` at `main.odin:1549`; `name = args[1]` default `"tui"` (1556-1558); `switch name` at 1562.

**31 cases** (default branch prints `usage()` and `os.exit(2)`):

| # | argv | Handler | Line | Currently driven by |
|---|---|---|---|---|
| 1 | `tui` | `tui_run()` | 1563 | the product; pty drivers |
| 2 | `guard-attach <dev> <name>` | `case_guard_attach` | 1564 | `tui-smoke run_guards`, `tui_drive.no_orphan` |
| 3 | `guard-delete <dev> <name>` | `case_guard_delete` | 1567 | same |
| 4 | `probe` | `case_probe` | 1570 | `handoff-smoke` 1/… |
| 5 | `double` | `case_double` | 1571 | `handoff-smoke` 2 |
| 6 | `handoff` | `case_handoff` | 1572 | `handoff-smoke` 3 |
| 7 | `sig-term` | `case_sig_term` | 1573 | `handoff-smoke` 7 |
| 8 | `measure` | `case_measure` | 1574 | `render-smoke` 1 |
| 9 | `app-unit` | `case_app_unit` | 1575 | `app-smoke` 1 |
| 10 | `app-live` | `case_app_live` | 1576 | `app-smoke` 2 |
| 11 | `fetch-unit` | `case_fetch_unit` | 1577 | `app-smoke` 3 |
| 12 | `fetch-live` | `case_fetch_live` | 1578 | `app-smoke` 4 |
| 13 | `render` | `case_render` | 1579 | `render-smoke` 2 |
| 14 | `theme-set` | `case_theme_set` | 1580 | `theme-smoke` |
| 15 | `theme-resolve` | `case_theme_resolve` | 1581 | `theme-smoke` |
| 16 | `config-parse` | `case_config_parse` | 1582 | `theme-smoke` |
| 17 | `config-save` | `case_config_save` | 1583 | `theme-smoke` |
| 18 | `config-live` | `case_config_live` | 1584 | `theme-smoke` |
| 19 | `colour-wire` | `case_colour_wire` | 1585 | `theme-smoke` |
| 20 | `clip` | `case_clip` | 1586 | `render-smoke` 3 |
| 21 | `clay-error` | `case_clay_error` | 1587 | `render-smoke` 4 |
| 22 | `layout-dump` | `case_layout_dump` | 1588 | `render-smoke` 5 (dump only) |
| 23 | `ui-frame` | `case_ui_frame` | 1589 | `ui-smoke` |
| 24 | `ui-sessions` | `case_ui_sessions` | 1590 | `ui-smoke` |
| 25 | `ui-shrink` | `case_ui_shrink` | 1591 | `ui-smoke` |
| 26 | `ui-edit` | `case_ui_edit` | 1592 | `ui-smoke` |
| 27 | `ui-list` | `case_ui_list` | 1593 | `ui-smoke` |
| 28 | `ui-float` | `case_ui_float` | 1594 | `ui-smoke` |
| 29 | `state-machine` | `case_state_machine` | 1595 | `state-smoke` 1 |
| 30 | `state-offline` | `case_state_offline` | 1596 | `state-smoke` 2 |
| 31 | `child <cwd> <argv…>` | `case_child` | 1597 | `handoff-smoke` 4, 5, 6 |

Also in `main` and **not** part of the dispatch but test-adjacent: `guard_probe_rows` (`main.odin:1497`),
`usage()` (1450, lists all cases verbatim — must be updated in lockstep).

**Genuine product code in `main.odin` that must stay:**
`main()`, `tui_run`, `tui_loop` (1221+), `tui_paint`, the `Tui` struct (330) + `tui` global (384),
event plumbing (`tui_take_event`, `tui_lost_terminal`, `TUI_LOST_TERMINAL` 1301, poll counters
1305-1311), footer/projection (`tui_state_text`, `tui_host_line`, `tui_list_age`, `tui_source_line`),
`diag_head` (963, *should move to a package*), `KEYS_*` tables (1162-1212, *should move to `ui`*),
`TUI_ACTIVE`/`tui_repaint_hook` (1539-1546 — product wiring: routes handoff repaint to the live frame),
`tui_fixture_remotes` (443 — see §4 #11), `tui_discover` (460), `write_pidfile` (141),
`install_terminal_restore_handlers` call (1551), `tui_dump_trace` (1252), boot timers (1410-1414).

**Retirable once nothing references it:** the whole `switch`, `usage()`'s case list, `case_probe` …
`case_child`, `case_guard_*`, `guard_probe_rows`, `home_dir`, `paint`/`draw_box`/`draw_text`
(Phase-1 smoke painter, `main.odin:78-119`), `force_repaint`/`FRAMES_PAINTED` — **but only if the
port registers its own repaint hook and its own smoke painter in `tests/`**.

---

## 6. Build wiring

### 6.1 `nix/package.nix`
- **Source filter (lines 26-33): only `src` and `vendor` (and everything under them) ship.**
  A `tests/` directory is **excluded by this filter** — the test derivation cannot see it unless the
  filter is widened *for that derivation only* (or the test drv uses a different `src`).
- `buildPhase` staging (lines 38-51): copies `${clay-src}/bindings/odin/clay-odin/clay.odin` →
  `clay-odin/clay.odin` and `${clay}/lib/libclay.a` → `clay-odin/linux/clay.a`;
  `${termbox2}/lib/libtermbox2.a` → `vendor/termbox2-odin/lib/`.
  **Any test build must repeat this staging** (identical layout), because Clay's
  `foreign import Clay "linux/clay.a"` resolves relative to `clay.odin` itself.
- Build command: `odin build src -out:herdr-session -o:speed -vet -extra-linker-flags=-Wl,--library-path,/`
  (line 62). The `--library-path,/` is mandatory with the nix cc-wrapper (documented lines 55-59).
- **There is no `checkPhase`, no `doCheck`, no `passthru.tests`, and `flake.nix` has no `checks` output.**
  `nix flake check` today runs **nothing** for this project. RCH-6 gate #6 therefore requires net-new wiring.

### 6.2 Import mechanics for a `tests/` package
- Today: `src/` uses relative imports — `main.odin`: `clay "../clay-odin"`,
  `termbox2 "../vendor/termbox2-odin"`, `terminal "./terminal"`, `app "./app"`, etc.
  Sub-packages use `"../../clay-odin"`, `"../app"`, `"../input"`.
- From `tests/` (sibling of `src/`): `import app "../src/app"`, `import ui "../src/ui"`,
  `import render "../src/render"`, `import terminal "../src/terminal"`, `import input "../src/input"`,
  `import clay "../clay-odin"`, `import tb "../vendor/termbox2-odin"`.
  These resolve to the **same absolute paths** the product uses, so there is **one** package instance of
  `clay`/`termbox2`/`app` — no duplicate-package problem. **RCH-5's claim holds: no module file needed.**
- `odin.json` is **absent** today. A `-collection:` flag (`odin build -collection:hs=.`) or an
  `odin.json` with `collections`/`dependencies` is the cleaner long-term shape but is explicitly
  optional; adding it also changes the *product* build invocation, i.e. it is not free.
- **The test binary links termbox2/Clay exactly the same way** (same archives, same
  `-extra-linker-flags=-Wl,--library-path,/`) and does not pollute the product derivation as long as
  it is a separate derivation. Also: `tests/` must not be pulled into `src`'s package.
  `odin test ./tests` builds a **separate** binary with a generated `main`, so the product's
  `main :: proc()` is not a conflict.
- **Risk:** `nix flake check` evaluates *all* outputs including `devShells`, and `flake.nix:2-4,63-66`
  explicitly warn that `nix develop` (devenv) needs `--no-pure-eval` in this repo. A naive
  `nix flake check` may fail for a **non-test** reason. Mitigation options for the plan: target the check
  attribute explicitly (`nix build .#checks.x86_64-linux.<name>`), or fix the devenv eval, or move the
  check onto the package's `passthru` and drive it from a CI script that is itself not a test.

---

## 7. `core:testing` fit assessment (Odin `dev-2026-10`, the SDK this repo compiles with)

SDK path: `/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/` (prints `dev-2026-10`).

**Registration / runner**
- `odin test -help`: *"Builds and runs procedures with the attribute `@(test)` in the initial package."*
  → **Attribute-based, not name-based.** Every test proc needs `@(test)`.
- Required signature: `Test_Signature :: proc(^T)` (`testing.odin:22`), i.e. `proc(t: ^testing.T)`.
- `-all-packages`, `-collection:`, `-tests:<pkg.name,...>` / `ODIN_TEST_NAMES` for selection.
- Configs: `ODIN_TEST_THREADS`, `ODIN_TEST_TRACK_MEMORY=true`, `ODIN_TEST_FAIL_ON_BAD_MEMORY=false`,
  `ODIN_TEST_FANCY`, `ODIN_TEST_LOG_LEVEL`, `ODIN_TEST_SHORT_LOGS`, `ODIN_TEST_JSON_REPORT`,
  `ODIN_TEST_GO_TO_ERROR`, `ODIN_TEST_RANDOM_SEED`.

**Assertion surface (the whole thing)** — `testing.odin`:
`expect(t, ok, msg, expr)` · `expectf(t, ok, fmt, ..args)` ·
`expect_value(t, value, expected)` (generic, `type_is_comparable`, nil-aware) ·
`fail(t)` · `fail_now(t, msg)` (traps immediately) · `failed(t)` ·
`cleanup(t, proc, user_data)` (LIFO, runs even after a fault — but must itself never fault) ·
`expect_leaks(t, client_test, verifier)` · `expect_assert_from/message` · `expect_signal(sig)`.
Failure accounting: `logging.odin:51` — **`t.error_count += 1` per ERROR-level log line.**

**What does NOT exist:** `expect_eq/ne/lt/le/gt/ge`, `expect_str_contains`, `expect_match`,
**any skip mechanism**, and **any per-assertion count in the output**.
`MAX_EXPECTED_ASSERTIONS_PER_TEST :: 5` (testing.odin:19) caps the *expect-assert* bookkeeping.

**The "0 tests = pass" hazard — confirmed in source**
`runner.odin:351-355`:
```odin
if total_test_count == 0 {
    // Exit early.
    fmt.wprintln(stdout, "No tests to run.")
    return true
}
```
→ `odin test ./tests` on an empty/misfiltered package **exits 0**.
(`reporting.odin:65` has `assert(len(internal_tests) > 0)`, unreachable behind the early return.)

**Guards the plan should require (design candidates, not decisions):**
1. A meta-test `@(test) test_something_ran(t)` that asserts a registered-count constant > 0.
   Simplest robust form: a hand-maintained/`#config`-supplied expected count asserted inside the run —
   but that is a second bookkeeping list that can drift.
2. An **outer guard that is not itself a test**: a wrapper proc/derivation that parses the runner's
   summary/JSON report (`ODIN_TEST_JSON_REPORT` gives `total`/`success` per package) and fails when
   `total == 0` or when a package contributes 0. This preserves the *spirit* of lib.sh's
   `tally`/`classify_log` outside the runner and cannot be erased by a reset.
3. Per-suite parity: because `core:testing` counts **tests**, not **assertions**, RCH-6's
   "assertion-count parity" is **not observable out of the box**. It requires either
   (a) a wrapper around `expect` that increments a global counter, printed at exit and asserted ≥ N, or
   (b) a rule that each migrated `check()` becomes exactly one `@(test)` proc (1:1 test↔assertion),
   which makes the runner's own `total` the parity number. (b) is the cleanest mapping but produces
   ~1,300 procs and needs shared fixture setup; (a) is a 20-line support module.
   **This choice drives the whole migration shape — the plan must pick one and state it.**

### 7.1 Mapping the hand-rolled helpers to `core:testing`

| Current | Where | Equivalent | Notes |
|---|---|---|---|
| `check(name, cond, detail)` | `main.odin:58` | `testing.expectf(t, cond, "%s — %s", name, detail)` | Clean. The `[PASS]` text disappears — nothing today *parses* PASS except the bash tally, which is going away. |
| `check_int(name, got, want)` | `app_live.odin:61` | `expect_value(t, got, want)` | Clean. |
| `say(msg)` | `main.odin:50` | `log.info` / `log.error` | Watch log-level filtering (`ODIN_TEST_LOG_LEVEL`); evidence lines must still reach the transcript. |
| `say_raw(label, data)` | `app_cases.odin:61` | `log.info` with escaped bytes | Clean-ish. |
| `expect_state / expect_cmd` | `state_cases.odin:220,225` | `expect_value` on enums + message | Clean. |
| `expect_noop` | `state_cases.odin:232` | compound `expectf` | Clean. |
| **`expect_cell`** (state transition) | `state_cases.odin:400` | `expectf(t, m.state==want && cmd.kind==want_cmd, …)` | Clean. |
| **Back-buffer cell grid** (`cell_at`/`glyph_at`/`dump_rows`/`expect_*` over glyph+fg+bg) | `render_cases.odin:161-215`, `ui_cases.odin` | **No equivalent.** Hand-roll on `termbox2.tb_get_cell(x,y,back=1,&ptr)` + `expect_value(t, glyph, want)` | **The `dump_rows` transcript band is load-bearing evidence and must be kept deliberately** — `core:testing` prints one line per failure and no grid. |
| **`expect_wire` (byte-pattern present in pty stream)** | `render-smoke.sh:51-62` | `expectf(t, contains(raw, pat), …)` over the driver's accumulated buffer | Hand-rolled; fine. |
| **`require_fresh_bin`** | `lib.sh:210-247` | **No equivalent.** Re-implement as an explicit test (`os.stat` mtime + `os.Walker` over `.odin` files newer than the binary) or as a derivation property | Under nix, mtimes are epoch-sentinel (`REPRODUCIBLE_MTIME_MAX = 1262304000`) and the rule is intentionally a no-op — a *built-by-nix* test binary is inherently fresh, which may make this whole rule **retirable in the nix path but still needed in the local path**. Say so out loud when retiring. |
| **`assert_formatted` (`%!` fallout)** | `lib.sh:118-140` | **No equivalent.** Either scan the captured log string, or (better) assert per-format-string in Odin where `fmt.tprintf` output can be checked for `%!` | The class of bug it catches (a mistyped format verb producing plausible-but-wrong numbers) is **real and previously caught twice**; do not retire silently. |
| **`tally` / `classify_log` / `skip` / `smoke_verdict` / `ALLOW_SKIP`** | `lib.sh` | **No equivalent** — see §7 "0 tests" + "no skip concept" | Must be re-created as an outer guard + a custom skip ledger. |

### 7.2 `odin test` and the pty/integration tests
- `odin test` can host pty tests **as long as** each test proc owns its fork/pty lifecycle and does not
  leave orphans; but:
  - **`TEST_THREADS` defaults to core count.** Forking a pty-driving test from N worker threads makes
    timing evidence (`boot ≤ 4 s`, `idle ≤ 2 ticks`, `resize < 500 ms`, `<1 s` before the working frame)
    **competitively flaky**. The integration suite almost certainly needs `ODIN_TEST_THREADS=1`, a separate
    binary, or a separate derivation from the unit tests.
  - `core:testing` traps/forwards SIGTERM/SIGINT/SIGSEGV/SIGTRAP (`signal_handler_*`,
    `expect_signal`). Tests whose **subject** is signal handling and SIGWINCH storms interact with a
    runner that also installs handlers. `testing.expect_signal` exists for "expect a signal in *this* test",
    but here the child gets the signal, not the test — still, verify the runner's handler setup
    does not interfere with the harness's `kill(-pgid)`.
  - **Recommendation to state:** a **custom Odin runner binary** (`tests/pty_runner` or a
    `--scenario <name>` argv in a test-support binary) for the pty suite, driven by *something* that is
    not `sh`/`py` per RCH-6 — either a second `@(test)` wrapper that shells it out, or a single
    `odin run ./tests/runner -- <scenario>` invoked from the nix check phase. `odin test ./tests`
    covers the in-process unit suites.

---

## 8. Risk register — where verification strength can be silently lost

**R-1 — Cell-grid evidence disappears.** `render`/`ui` prove rendering by reading termbox's **back
buffer** (`tb_get_cell(..., back=1, …)`) and printing `dump_rows` bands. `core:testing` has no such
concept. A port that asserts "no panic" instead of the exact glyph+fg+bg triples **loses ~69+90 checks'
worth of actual content** while still going green. *Detect by: render's runtime `[PASS]` count.*

**R-2 — Screen model replaced by byte greps.** termbox emits a **cell diff**; grepping the raw stream
for `"delete_session"` fails on a correct render (`delte_sss`), and passes on a screen that painted
*something else* containing the token. `tui_drive.py:55-76` documents this explicitly. Any shortcut here
converts ~94 real assertions into noise.

**R-3 — Fixture gating turns real tests into skips.** Today 5 suite sections self-skip without the
fixture. In `core:testing` (no skip concept) the failure modes are: (a) an early `return` from a test
= a **green test that tested nothing** — the single worst regression available; (b) the whole
"unsetting the env keeps the rest green" property turning into "the whole suite silently vanishes".
Mitigation must be explicit: skip ⇒ ledger ⇒ non-zero exit unless declared.

**R-4 — Assertion counts are not observable without a design choice.** `core:testing` reports tests, not
assertions. Without a counter (7.1/§7 point 3), "parity" cannot be *measured*, and the RCH-6 mandate
("report the honest new total vs 1,354") becomes unfalsifiable — the exact condition under which drops
go unnoticed.

**R-5 — Weak suites stay weak (or get weaker) during port.** render/ui/theme/state today have **no
zero-assertion rule and no freshness gate** (§2.9). `ui-smoke` accepts `RESULT: PASS` with 0 `[PASS]`
lines; `theme-smoke`'s `record()` treats 0/0 as not-failed. A "faithful" port of these inherits the
hole; the mandated uniform rule set is a *net change* that must be deliberate.

**R-6 — Product symbols trapped in `package main` get deleted with the tests.** `diag_head` (P3-12 rune
truncation) and `KEYS_MODE` (footer overflow at 80/100 cols) are only reachable from `main`. The
path of least resistance is deleting their tests. These are **product-behaviour proofs**, not test scaffolding.

**R-7 — `any_failed` semantics lost.** The "one run, one verdict across many sections" model and the
`state_cases.odin:1349-1358` save/restore pattern (isolate a sub-block's failures, then merge) have no
`core:testing` equivalent. Re-deriving per-test only may silently drop *inter-section* assertions.

**R-8 — Timing tests become flaky and get weakened instead of fixed.** Live thresholds in-tree:
paint ≤ 4 s/5 s/6 s; idle ≤ 2 clock ticks over 5 s; resize first repaint < 500 ms; `working:` frame
< 1 s after Enter; dead-host verdict ≤ 6.5 s; `delete_notice` gap ≥ 2.0 s and < 12 s; `resize_latency`
timeout 2 s. Under `core:testing`'s **multi-threaded default runner** these will flake. The predictable
response is loosening the numbers — which is a silent loss. Plan must fix the runner to single-threaded
for pty tests *before* touching any threshold, and record that no threshold was widened.

**R-9 — The `delete_notice` shim is the only way that property is observable.** `SLOW_HERDR`
(`tui_drive.py:1063-1077`) fabricates one row and stalls stop/delete 2 s each; it is also the
hermeticity guarantee ("no path to a real session"). If the port "simplifies" by using the real herdr,
**the check becomes unobservable** (20 ms round trip) — and if it uses the real binary *badly*, it can
touch real sessions. The shim's contract (fabricated row + 2 s stalls + fixture hosts blanked + temp
HOME) must be ported intact.

**R-10 — `device_discriminator`'s exit-code bug must not be inherited** (§3.4): it always exits 0.
If the Odin port copies that shape, the discriminator contributes *verdict-free output*.

**R-11 — Anti-criteria greps have no regex in Odin.** `core:regex` **does not exist** in this SDK
(verified: `share/core/` has no `regex`/`regexp`; `core:rexcode` is an *instruction* encoder).
Patterns that must be hand-rolled or simplified:
`localhost|127\.0\.0\.1`, `kitty|\[>1u`, `^(local|[0-9a-fA-F:.]+)\s`,
`\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(\.\d{3})?\s+\w+\s+(.*)$`,
`^(device\s+)?timestamp…` etc. `core:strings` contains/has_prefix + `os.Walker` cover the simple ones;
the *timestamp/device column* regexes are structural and should become **column-offset predicates**
(the `DEVICE_W = 12` approach already used) rather than regexes.
Also note the greps must **strip `//` comments first** (state-smoke's `grep_absent` does; theme-smoke's
TOML grep does) or the prose about the rule becomes a rule violation.

**R-12 — Fixture seam is in the product.** `tui_fixture_remotes` (`main.odin:443`) and
`HS_TUI_TRACE` / `HS_PIDFILE` are dev seams inside the shipped binary. RCH-5's "no test code in the
product" collides with them. If they are removed to satisfy the letter of the rule, the pty suite loses
its fixture path — and the documented alternative (temp `XDG_CONFIG_HOME`) **moves herdr's own state
dir** and yields an empty session list (`60-handoff-notes.md`, `5e84fae`). Make an explicit decision;
do not let it drift either way.

**R-13 — `nix flake check` may not be runnable as-is** (§6.1/6.2): no check phase today, package filter
excludes `tests/`, and the devenv devShell needs `--no-pure-eval`. Gate #6 could end up "wired but
green because it skipped", which is the same failure class this whole effort exists to remove.

**R-14 — `render-smoke`'s `layout-dump` step has 0 assertions** but contributes transcript volume;
do not count it toward parity, and do not assume it is being ported "because it was a step".

**R-15 — `stream_order.py` proves nothing** (§3.5). Retiring it is free; but if the plan lists it as
"covered by the port", that is a false claim about an assertion that never existed.

**R-16 — Python child probes** (`sig_probe.py`, `env_probe.sh` written at runtime by
`handoff-smoke.sh:37-81`) are part of the RCH-6 `*.py` sweep and are *inside* a `sh` file. Easy to
miss: deleting `dev/*.py` does not remove `sig_probe.py`, because it is a **heredoc inside
`handoff-smoke.sh`**. The signal/pgid/env proofs must be re-expressed by an Odin probe, or those three
handoff checks vanish.

**R-17 — Baseline ambiguity.** The 1,354 target and the last recorded table (1,275 + 38 + 1) do not
agree (§1). Porting against an unre-measured baseline makes the parity claim unverifiable from the
first commit.

**R-18 — `XDG_CONFIG_HOME` discipline.** `theme-smoke` asserts the real `~/.config/herdr_session.json`
md5 is unchanged and that the swap did not leak to the caller. The port must keep a
*fingerprint-before / verify-after* guard, or a test that writes the developer's real config becomes
possible and undetected.

---

## 9. Files reference (quick index)

```
dev/lib.sh                 ALLOW_SKIP 34 · tally 47 · classify_log 87 · skip 105 · assert_formatted 116
                           smoke_verdict 144 · STALE_BIN 182 · REPRODUCIBLE_MTIME_MAX 188 · require_fresh_bin 195
dev/app-smoke.sh           BIN 28 · lib.sh 31 · require_fresh_bin 33 · session_names 43 · cleanup_scratch 51 · trap 69
                           local assert_formatted 80 / tally 99 (override) · drivers 127/147/165/184/209
                           PRODUCT_DIRS 227 · grep_check 229-241 · default-builder grep 269 · STALE_BIN verdict 279
dev/state-smoke.sh         tally 37 · assert_formatted 59 · state-machine ~85 · env -i 96 · STATE_SRC 115
                           grep_absent 118 · src-wide localhost grep 156 · safety section 165+
dev/render-smoke.sh        run_pty 33 · tally 41 (NO zero-rule) · expect_wire 52 · wire asserts 85-94
                           indexed-colour negative 96-102 · layout-dump 125 (0 asserts)
dev/ui-smoke.sh            CASES 13 · input_for 18 · pty+sleep 38-45 · pass rule 48 · summary 60-70
dev/theme-smoke.sh         record 27 · run_case 35 · run_pty 47 · REAL_BEFORE fingerprint 60 · in-proc cases 64
                           pty scenarios 69 · h() 79 · TOML grep 101 · totals 128-133
dev/handoff-smoke.sh       lib.sh 17 · require_fresh_bin 23 · ALLOW_SKIP=0 31 · env_probe.sh 37 · sig_probe.py 46
                           check_stty 86 · run_pty 110 · stream_order 128 · cases 133-205 · SIG loop 205-247
                           STTY tally 250 · smoke_verdict 252
dev/tui-smoke.sh           lib.sh 28 · require_fresh_bin 32 · cleanup trap ~60 · PASS_TOTAL 71 · run_scenario 84
                           (skip 91 · assert_formatted 98 · tally 99 · rc-vs-classify 101-104) · run_guards 112
                           scenarios 129-146 · verdict 148-165
dev/resize-smoke.sh        lib.sh 14 · require_fresh_bin 21 · rep/scen loop 47-48 · per-run slog 52 · classify_log 61
                           tally 68 · assert_formatted 78 · smoke_verdict end
dev/tui_drive.py           char_width 66 · Screen 78 · escape-family rationale 122-129 · Pty 201 · read 245
                           wait_screen 270 · watch_screen 283 · send/keys 300-304 · resize_latency 305 · resize 320
                           alive/exit_info/kill 331-353 · cpu_ticks 355 · termios_now 368 · herdr_cli 379
                           session_names 387 · base_env 416 · scenarios 430-1206 · SCENARIOS 1217
dev/resize_drive.py        skipped() 48 (exit 77) · TRACE 62 · boot 66 · quit_and_trace 84 · field/total_field 100
                           sc_resize_no_key 127 · sc_flood 165 · sc_too_small 250 (NOTICE 248)
                           sc_selection_shrink 320 · sc_eintr_safe 374 · SCENARIOS 437
dev/theme_drive.py         cfg_home 30 · cfg_path/write/read 41-54 · env_for 56 (XDG aim) · sgr_bg_of/sgr_fg_of 64
                           selected_row_text 72 · scenarios 92-372 · SCENARIOS 374
dev/device_discriminator.py DEVICE_W 43 · table_rows/devices_in/names_in 45-68 · main 71 · NOT-proven notes 118-146
                           exit-code BUG 163
dev/stream_order.py        MARKS 12-17 · 0 assertions
src/main.odin              report/any_failed 43-44 · say 50 · check 58 · print_report 66 · smoke painter 78-119
                           enter_terminal 125 · leave_terminal 137 · write_pidfile 141 · case_probe 164
                           case_double 184 · case_handoff 211 · case_child 258 · case_sig_term 280 · home_dir 299
                           Tui 330 · tui 384 · tui_fixture_remotes 443 · tui_discover 460
                           tui_host_line 938 · diag_head 963 · tui_state_text 975 · KEYS_MODE 1162 … KEYS_ERROR 1211
                           tui_dump_trace 1252 · TUI_* counters 1301-1311 · usage 1450 · guard_probe_rows 1497
                           case_guard_attach 1504 · case_guard_delete 1521 · TUI_ACTIVE 1539 · tui_repaint_hook 1541
                           main 1549 · switch 1562-1598
src/app_cases.odin         to_bytes/eq/eq_i/eq_int/ne_i 35-60 · say_raw 61 · case_app_unit 69 · unit_diag_head 1046
src/app_live.odin          eq_code 57 · check_int 61 · case_app_live 65 · live_device_discriminator 617
src/fetch_cases.odin / src/fetch_live.odin   case_fetch_unit 37 / case_fetch_live 57
src/render_cases.odin      clay_start 38 · Cell/cell_at/glyph_at 152-172 · dump_rows 176-193 · render_and_present 205
                           find_text_loc 221 · case_measure 190 · case_render 284 · case_clip 463 · case_clay_error 576
                           case_layout_dump 736
src/state_cases.odin       expect_state 220 · expect_cmd 225 · expect_noop 232 · case_state_machine 240
                           expect_cell 400 · sm_spec_cells 412 · R2/R3/R4 sections 804/1008/1083
                           case_state_offline 1347 (any_failed save/restore 1349-1358)
src/theme_cases.odin       case_theme_set 141 · case_theme_resolve 253 · case_config_parse 329 · case_config_save 453
                           case_config_live 618 · case_colour_wire 711
src/ui_cases.odin          bring_up 181 · Win_Size 340 · TIOCSWINSZ 346 · foreign ioctl 348-354 · shrink_pty 356
                           case_ui_frame 389 (KEYS_MODE use 505-532) · case_ui_sessions 635 · case_ui_shrink 881
                           case_ui_edit 994 · case_ui_list 1219 · case_ui_float 1338
src/app/herdr.odin         run_capture 298
src/terminal/resize.odin   MIN_COLS/MIN_ROWS 53-54 · too_small 58 · Coalescer 74+ · summary ~168 (trace format)
src/terminal/handoff.odin  set_full_repaint 54 · install_terminal_restore_handlers 309
nix/package.nix           src filter 26-33 · archive staging 38-51 · odin build 62
flake.nix                 packages 58-70 · devShells 72-95 · NO `checks` output anywhere
SDK: /nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09  (prints `odin version dev-2026-10`)
  share/core/testing/testing.odin  Test_Signature 22 · expect 110 · expectf 121 · expect_value 128 · cleanup 106
  share/core/testing/runner.odin   zero-tests-returns-true 351-355 · CLI opts 200-240 · report 416 · JSON 1035-1041
  share/core/testing/logging.odin  error_count += 1 per ERROR log 51
  share/core/testing/reporting.odin assert(len>0) 65
  share/core/sys/posix/unistd.odin fork 338 · setsid 819 · dup2 181 · execve 290 · execvp 271
  share/core/sys/posix/sys_wait.odin WIFEXITED 92 · WEXITSTATUS 97 · WIFSIGNALED 102
  share/core/sys/posix/termios.odin tcgetattr 69 · tcsetattr 92   ← NO ioctl, NO openpty/forkpty ANYWHERE
  share/core/os/dir_walker.odin    Walker (recursive traversal) — the grep-replacement primitive
  share/core/  → NO `regex`/`regexp` package (rexcode is an instruction encoder, not regex)
```
