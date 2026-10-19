# Execution Log — herdr-session (autonomous run)

Per the user's instruction: *"Once the planner returns, don't ask anymore questions and execute as I'll not
be here to answer. If you or the subagents have doubts, make the decisions until things are done."*

This log records **every** decision made without the user, plus each phase gate verdict, so the run is
auditable after the fact.

---

## Operating rules I adopted

1. **No questions to the user.** Ambiguity is resolved by me, recorded here with rationale.
2. **Sequential workers only.** Same git repo — parallel workers would conflict on commits.
3. **Group adjacent, tightly-coupled todos per worker.** Each phase has one verifiable exit condition and
   its todos share context heavily; one worker per phase avoids re-deriving context N times.
4. **Verify every phase gate myself** before queueing the next — do not accept a worker's self-report.
5. **Keep the plan's decision register authoritative.** I only fill gaps the planner left; I do not
   override its decisions.
6. **Cleanup after every probe.** Any scratch herdr session is stopped+deleted and the clean state shown.

---

## Decisions made by me (orchestrator) without the user

| # | Decision | Rationale |
|---|---|---|
| **O1** | Group todos into **7 phase-level workers** instead of 24 individual ones | Phase 0's T0.1 cannot be verified without T0.2's flake outputs; they are one unit. Same coupling elsewhere. 24 spawns ≈ 8–16 h of redundant context re-derivation vs ~5–7 h for 7. |
| **O2** | **Commit the `.pi/` planning artifacts** at baseline | Auditability: the user asked to evaluate results later; the reasoning must be in-repo, not just in session logs. |
| **O3** | Deleted the `docs/main.md` symlink **early** instead of at the end | It was a known deferred chore. Deferred chores get forgotten; deleting early removed all risk since all scouts + planner were already done. |
| **O4** | Told Phase 1 explicitly that **`proc "c"` has no context**, C-style foreign decls are **gone**, `#` is **not** a comment, `-mode:release` **doesn't exist** | These cost Phase 0 real time to rediscover. Propagating them forward is cheap. |
| **O5** | Instructed Phase 1 to test the handoff under **`script -q -e -c "stty rows 40 cols 120; …" /dev/null`** | The agent shell has **no controlling tty**; a handoff test here panics for a reason that is not a real failure. The scouts established this workaround. |
| **O6** | Required **`stty -a` before/after comparison** as the handoff proof | "Terminal restored" is otherwise unverifiable hand-waving. termios round-trip is the actual criterion. |

---

## Phase gates

### Phase 0 — T0.1 + T0.2 — ✅ PASSED (self-verified, not just worker-reported)
Commit `286a784`.

Independently re-ran on the committed tree:
```
nix build .  -> exit 0, result/bin/herdr-session 443880 B
nix run .    -> exit 0
    herdr-session: toolchain OK
      clay.MinMemorySize() = 5785280 bytes
      tb_wcwidth('A')      = 1
      tb_wcwidth(U+4E00)   = 2
```
**ISC-1 satisfied.** Clay + termbox2 + Odin link and execute.

Hygiene I audited directly:
- `git ls-files | grep -E '\.(a|lib|o)$'` → **empty** (ISC-A-9 ✓ — no committed blobs)
- `-Werror` appears **only** in comments explaining its deliberate absence ✓
- `git diff 02df0e1 HEAD -- .envrc` → **empty** (user's direnv config untouched) ✓
- Package derivation never touches devenv ✓

### Corrections Phase 0 discovered that changed the plan's sketches
These are now load-bearing for every later phase:

1. **`-mode:release` does not exist** in `pkgs.odin dev-2026-09` → use **`-o:speed`**.
2. **C-style foreign declarations are gone** — `f(x: u32) : i32 ---` is a syntax error →
   **`f :: proc(x: u32) -> i32 ---`**.
3. **`#` is not an Odin comment** (it's a tag directive) → use `//`.
4. **`lib.fileset` is unusable** here — it demands git-tracked files, so the flake can't evaluate
   pre-commit → switched to **`lib.cleanSourceWith`** with explicit `src`/`vendor` prefix filters.
5. **The real link blocker.** Odin emits staged archives as `-l:<absolute path>`; GNU ld resolves `-l:` by
   *joining* each `-L` dir to the name, so it needs `/` on the search path — but **the nix `cc` wrapper
   silently drops a bare `-L/`**. Measured: `-L/` FAIL · `-Wl,-L/` FAIL · `NIX_LDFLAGS=-L/` FAIL ·
   `LIBRARY_PATH=/` FAIL · **`-Wl,--library-path,/` OK**. Now in `buildPhase` with a comment.
6. `termbox2` input pinned to `48cda6f8…`; `clay` to `e6cc3694…`.
7. `tb_last_errno` **does** exist (`termbox2.h:739`).

**My note on #5:** this is the kind of thing that looks like a hack and invites "cleanup". The inline
comment in `nix/package.nix` explains the measured matrix so the next person doesn't regress it.

---

### Phase 1 — T1.1 + T1.2 — ✅ PASSED (self-verified, suite re-run by orchestrator)
Commit `ad2fa04`. **Risk A1 retired** — the handoff is now *run*, not just read.

I re-ran `./dev/handoff-smoke.sh` myself rather than trusting the report: **28 PASS / 0 FAIL**,
reproduced exactly. Decisive evidence:
- `stty -a` captured before/after inside the same pty is **IDENTICAL in every case** (real termios round-trip).
- Ordered byte stream proves **nothing of ours renders while the child owns the screen**:
  `ENTER@0 → LEAVE@1748 → child output@1958 → ENTER@2029 → forced repaint@2497`.
- `PARENT SigBlk=0x6` (SIGINT|SIGQUIT blocked) while `CHILD SigBlk=0x0` and `CHILD_GOT_SIGNAL=2`
  → we survive a tty-driver-style group SIGINT and still capture the child's exit code.
- `SELF pgid == CHILD pgid` → **no `setsid`**, confirmed empirically.
- 7 `HERDR_*` vars in our env → **0 in the child**, `TERM`/`COLORTERM` kept.
- `SIGTERM → exit 143`, `SIGHUP → exit 129`, each with the alt-screen-leave sequence reaching the tty.
- Forced full repaint is wired via an **installed hook**, so no caller can skip handoff step 6.

### Two Phase-1 discoveries that changed how later phases must be written

1. **⚠️ `tb_poll_event` / `tb_peek_event` return a TB_* *status*, not the event type.**
   `TB_OK` means "`ev` is populated"; the kind is `ev.typ`. The plan/todo sketch `if rv == EVENT_KEY`
   **could never be true** and would fail silently. Propagated to all later phases verbatim.
2. **`cfmakeraw` (called by termbox2 init) clears `ISIG`.** While our TUI is up, Ctrl+C arrives as byte
   `0x03` → `TB_KEY_CTRL_C`. **ISC-12 is keymap work, not signal handling.** SIGINT only exists as a
   signal during the `tb_shutdown()` window — which is precisely why the child must be **un-blocked**
   before `execve` (the signal mask survives both fork and exec).

Also: **`execvp` cannot be used** — it resolves PATH from the inherited `environ`, silently defeating the
`HERDR_*` scrub. PATH must be walked in the parent and `execve` called.

### ⚠️ Nix landmine discovered in Phase 1 (affects every later phase)
**`nix build .` copies the GIT tree (HEAD + tracked-dirty), so UNTRACKED files are INVISIBLE to the build.**
Symptom: `Syntax Error: Path does not exist: ./terminal` while the file sits in the editor and the **drv hash
is unchanged**. `cleanSourceWith` cannot help — the flake-self copy happens *before* the filter.
**Rule adopted: `git add` every new source file before building.**

| **O7** | **Decoupled T3.4 from T6.1**: Phase 3 must take the config-derived remote list as an **injected value**, not build the config loader | The plan puts the JSON config loader in **T6.1**, but **T3.4 needs a config fallback now** — and on this box that fallback is the path that *actually runs* (`herdr machine` is absent in 0.8.2 and `~/.ssh/config` does not exist). Left to its own devices the Phase 3 worker would either block or build the loader early and force T6.1 to redo it. Injecting the list makes T6.1 a drop-in. |

---

### Phase 2 — T2.1 + T2.2 + T2.3 — ✅ PASSED (self-verified: 69 PASS render, 28 PASS Phase-1 regression)
Commit `80966a9`. I re-ran both suites myself rather than trusting the report.

Evidence I reproduced:
- Measure: `"hello" 5B/5r→5` · `"世界" 6B/2r→4` · `e+U+0301 3B/2r→1` · `"😀" 4B/1r→2`.
  Width comes from the **same `tb_wcwidth` table `tb_present()` paints with**, so measure and paint cannot drift.
- **Scissor clipping proven hard**: 75-col text in a 14-col box → **0 of 318 painted past the right edge**,
  0 of 4440 below; col 13 painted, col 14 untouched.
- Truecolour reaches the wire (`38;2;…`/`48;2;…`) with **no `38;5;` indexed fallback anywhere**.
- Error handler: duplicate id captured; 672 B message truncated to 211 ≤ cap 224; 40 frames →
  `retained=8 total=81 dropped=73`.
- The layout dump shows `Text (14.5, 4)` — **fractional x from `childAlignment`**, confirming why one
  shared `round_cell` (`floor(x+0.5)`) is required or borders and text disagree.

**Method worth preserving:** the dev driver reads termbox's **back buffer** via `tb_get_cell(back=1)` and
asserts glyph+fg+bg against **Clay's own reported geometry** — so if Clay lays out differently it fails
loudly instead of the assertion silently retargeting.

### Phase 2 findings that constrain Phase 5 (UI) directly
1. **`betweenChildren` is not geometry.** `BorderRenderData.width.betweenChildren` only *declares*
   dividers; Clay emits each one later as a thin `Rectangle` in the border's colour (`clay.h:2852-2890`).
2. **Those divider rects span the container's full width and erase the border's own `│`** — found by
   rendering; fixed by clipping dividers to the container interior.
3. **⚠️ `childGap` must be ≥ 2.** At 1 the rule lands on the following child's row and paints over its text.
   **Phase 5 must respect this.**
4. **`textAlignment` alone doesn't move x** — alignment comes from the parent's `childAlignment`, which
   bakes *fractional* x.
5. **termbox2 truecolour: a low-24-bit attr of 0 without `TB_HI_BLACK` means "terminal default"** — literal
   black needs `TB_HI_BLACK` explicitly.
6. **`tb_clear()` fills with `' '` (0x20) + clear attrs, not NUL** — "untouched" must be probed with
   `tb_set_clear_attrs(sentinel)`.

### Accepted deviations from the plan (mine to allow, recorded for the user)
- File named `src/render/errors.odin`, not the plan's `src/render/clay_error.odin` (matched the brief).
- **Overlay tinting is a deliberate, documented no-op** rather than a blend. The per-cell painter has no
  blend policy and inventing one would fight Phase 5, which owns hover/selection styling. `paint()` is named
  as where it lands.
- **Rule recognition is matched by (colour + thickness + ordering + containment)**, not a field read —
  forced by finding #1. Deliberately narrow, and asserted so an ordinary fill can't be mistaken for a rule.
- **ISC-A-8 holds**: alpha is used only as a paint gate, never as an identity/tag channel.

---

## Still open / to decide during later phases
- **D2 remains parked** (`cleanup_policy = never`). If the first interactive test shows the user expects
  `herdr-cycle`-style auto-cleanup, flip the single seam — do not redesign around it.
- **D13 renames the config file to `herdr_session.json`**, deviating from the spec's literal `.toml`.
  Accepted for the dependency win; flag it in the final report so the user can veto cheaply.
- Palette set size is explicitly deferred by the plan — I will ship the plan's initial set, not invent one.

---

## Phase 3 — herdr integration (T3.1–T3.4), executed 2026-10-19

**Gate verdict: PASS.** `BIN=./result/bin/herdr-session ./dev/app-smoke.sh` →
**214 PASS / 0 FAIL** (133 unit + 59 live + 22 anti-criteria greps/teardown), with
the prior phases re-run against the same nix-built binary: **handoff 28 PASS / 0
FAIL**, **render 69 PASS / 0 FAIL**, `nix build .` and `nix run .` green.

### Decisions made without the user

1. **Three files, one extra split from the brief.** `src/app/model.odin`,
   `src/app/herdr.odin`, `src/app/remotes.odin` as asked, plus the driver split
   into `src/app_cases.odin` (pure, herdr-independent) and `src/app_live.odin`
   (real binary + ssh). The two halves need different evidence and different
   safety rules; mixing them would have put destructive probes in the same file as
   the offline table.
2. **`run_capture` blocks; the seam is shaped for T4.1 anyway.** Phase 3 only
   needs synchronous control commands, so `run_capture(argv, timeout)` blocks
   until exit or deadline. The drain (`read_all_drain` /
   `drain_until_blocked_or_eof`) and `reap_child` are separate procs precisely so
   the non-blocking fan-out in T4.1 reuses them instead of re-deriving the pipe
   mechanics. Documented at the function.
3. **The delete pre-check does not call herdr at all.** If the name is not in our
   model we refuse before spawning. Calling herdr to "find out" would put
   `{"deleted":true}` in our own logs for a session that never existed, which is
   the exact lie we are defending against.
4. **The shape gate takes bytes, not a `Capture`.** `machine_registry_available
   (payload: []byte) -> bool` — taking the Capture would let a future caller peek
   at `code` first, which is the failure mode the gate exists to prevent.
5. **`device` stays a plain string, never normalised** — asserted with a target
   containing mixed case, dots and a port (`Alice@Work.Box.Example:2222`) so any
   future "tidying" fails the test.
6. **Fixture remote only via env.** `HERDR_SESSION_TEST_REMOTE` (+ `_ALIAS` for
   the discriminator pair). No host literal anywhere in `src/`, asserted by grep.

### New traps found (none of these are in the plan or the corrections file)

1. ⚠️ **`HERDR_ENV=0` is NOT a no-op guard — the header's "the PRESENCE is the
   trigger" only holds for a truthy value.** Re-run today: `HERDR_ENV=1` refuses
   with exit 1 (`nested herdr is disabled by default`), but `HERDR_ENV=0` walks
   straight past the nesting check and only dies later on the tty (101).
   Consequence: never "neutralise" the namespace by setting it to 0; **remove**
   it, which is what `terminal.build_scrubbed_env` does and is correct whatever
   herdr's truthiness rules are. Captured as a differential in `app-live`.
2. ⚠️ **The `machine` exit-0 help-banner premise is wrong for 0.8.2.** The
   installed binary answers `unknown command: machine` with **exit 2** and empty
   stdout. The shape gate survives both this and the exit-0 banner (both asserted),
   but the recorded behaviour is now accurate rather than assumed.
3. ⚠️ **An aborted launch leaves a live session behind — confirmed, not theorised.**
   `herdr --session hs-t-phase3-probe` with no tty exits 101 (ratatui init panic)
   **and the session is left `running:true`**. A design that validated after the
   spawn would leak a live session per typo. Asserted in `live_orphan_rule`.
4. ⚠️ **`odin` in this toolchain has no `?T`, no `trans`, no `to_slice`, and
   struct literals take `=` not `:`.** `#maybe` was merged into `union` upstream,
   so the plan's `?time.Time` becomes `union {time.Time, Unknown_Timestamp}`;
   casts are `T(x)` / `transmute(T)(x)` (the latter rejects untyped literals,
   hence the `to_bytes` helper in the drivers); `sort` compares with
   `proc(T,T) -> int`, not a `less`; `#partial switch` only accepts enums (an
   `i32` exit code needs `if`); and `for b in some_string` yields **runes**, so
   byte-level checks must go through `transmute([]byte)(s)`.
5. ⚠️ **The flake source silently excludes *untracked* files.** `nix build .`
   failed with `Undeclared name: case_app_unit` while `odin build src` was green —
   because the flake hands nix a git-derived tree and the new files were not in the
   index yet. Any phase that adds new source files must `git add` them before
   trusting `nix build`.
6. **`ssh <host>` to `127.0.0.1` fails host-key verification on this box** (only
   `localhost` and the LAN address are in `known_hosts`). For the two-target-string
   discriminator the fixture pair is `localhost` + `192.168.0.45`, supplied via
   env — which is exactly why the fixture must never be hard-coded.

### Cleanup proof

`dev/app-smoke.sh` snapshots `herdr session list --json` before running and
compares after an `EXIT`/`INT`/`TERM` trap that stops+deletes every `hs-t-*`
name, so teardown runs on failure too:

```
== pre-run session list:  2026-08-11-23-37-41-812,2026-08-30-14-59-10-730,default
== post-cleanup list:     2026-08-11-23-37-41-812,2026-08-30-14-59-10-730,default
   [PASS] teardown restored the pre-run session list exactly
   [PASS] the session hosting this agent is still present and untouched
```

The hosting session (`2026-08-11-23-37-41-812`) is never a target: every probe
name is `hs-t-*`, and `live_cleanup` asserts the host is still listed at the end.
