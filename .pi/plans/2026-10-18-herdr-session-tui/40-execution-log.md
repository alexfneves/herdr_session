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

### Phase 3 — T3.1–T3.4 — ✅ PASSED (214 PASS / 0 FAIL after a fixture fix I made)
Commit `18f3399`.

**My verification caught a failure the worker's run did not surface.** Unarmed run: 202 PASS / 0 FAIL
(12 fixture cases silently skipped). With the fixture armed: **209 PASS / 1 FAIL** —
`both target strings list successfully → localhost→0 127.0.0.1→255`.

**Diagnosis: a fixture environment gap, not a product bug.** Our code correctly reported `255`
(ssh transport failure). Root cause: `~/.ssh/known_hosts` had `localhost` but **no `127.0.0.1`** →
`Host key verification failed`. The plan's own T6.3 discriminator needs that second address form.

| **O8** | **Extended the ssh fixture to `127.0.0.1`**, after verifying the key is trustworthy | The T6.3 discriminator (two distinct ssh target strings for the same machine) cannot run without it. I did **not** blindly trust `ssh-keyscan`: the scanned **ed25519 key is byte-identical to `localhost`'s existing entry**, confirming the same host under a different address form. Only that verified key was appended; `known_hosts.bak-phase3` backup taken. **This is a machine-config change I made on the user's box — reversible by deleting the appended line.** |

After the fixture fix: **214 PASS / 0 FAIL**, matching the worker's claim exactly, with teardown
restoring the pre-run session list precisely.

**Note on verification discipline:** the worker reported the correct number, but only because it ran
*with* the fixture. Anyone running without it would see a green-but-partial suite. Lesson recorded:
**always run the fixture-armed path when verifying**, since un-armed runs silently skip the remote tests.

### Phase 3 findings that further correct the research
1. **`HERDR_ENV=0` is not the trigger** — it walks past the nesting check and only dies on the missing tty
   (101). Only a *truthy* value refuses. Reinforces: **remove** the var, never "neutralise" it by setting it.
2. **The orphan hazard is confirmed live** — `--session X` with no tty panics (101) **and leaves the session
   `running:true`**. Validation is a *precondition* of building argv, not a post-check.
3. **`machine list` on 0.8.2 exits 2 with `unknown command`** — contradicting T3.4's text ("help banner with
   exit 0"). The shape gate survives **both** behaviours and both are now asserted, so the product is robust
   to whichever a given build does.
4. Re-confirmed: **untracked files are invisible to `nix build`** (`Undeclared name` while `odin build src`
   was green).

### Good design choices from Phase 3 worth preserving
- The stream-shape gate takes `[]byte`, **not** a `Capture`, so no caller can reintroduce an exit-code check.
- `run_capture` blocks (fine for control commands); the **drain/reap pieces are separate procs** so T4.1's
  non-blocking fan-out reuses them instead of re-deriving pipe mechanics.
- Destructive live drivers split into `app_live.odin`, away from the offline unit table.
- `Ts :: union {time.Time, Unknown_Timestamp}` with an `I64_MAX` sort sentinel — a `0` sentinel would have
  put "unknown" *above* real sessions instead of last.

---

## Phase 4 — Parallel fetch fan-out (T4.1 + T4.2), executed 2026-10-19

**Result: ✅ PASSED — 339 PASS / 0 FAIL** on `dev/app-smoke.sh` armed
(`HERDR_SESSION_TEST_REMOTE=localhost`, `_ALIAS=127.0.0.1`), running the **nix-built**
binary, with Phase 1/2/3 suites unregressed (handoff 28 PASS, render 69 PASS) and the
fixture session list restored byte-for-byte by teardown.

New files: `src/app/fetch.odin` (the fan-out), `src/fetch_cases.odin` (67 offline
checks), `src/fetch_live.odin` (54 real-ssh checks), `dev/local-build.sh` (fast
pinned-Odin build loop; the nix build stays the gate). Both new cases are wired into
`dev/app-smoke.sh` as sections 3/5 and 4/5 so nobody has to remember to run them.

### What was actually built (and why it needs no threads)

Every fetch is an OS process, and *that process's stdout becoming readable is the async
wake event* — there is nothing to schedule. One `poll()` over `{ttyfd, resizefd,
∪ fetch fds}` is the whole mechanism. `registry_step(wait)` is the unit of work:
pump (drain every live fetch as far as it will go without blocking) → settle anything
whose streams both hit EOF (`waitpid WNOHANG`) → `poll` for the smallest remaining
deadline capped at `POLL_SLICE` → re-check deadlines → `SIGKILL` what overran. The
deadline is enforced off the same clock the sleep was derived from, so there is no
second timer, no timerfd and no self-pipe anywhere.

`FETCH_DEADLINE = 13 s` sits **above** ssh's `ConnectTimeout = 5` on purpose: ssh
almost always reports its own failure first (measured 5012 ms → `unreachable` with
`kills=0`), so our SIGKILL is only the backstop for a child that is connected but
silent. The local deadline is a tight 5 s because a local list measures ~1.5 ms.

### ⚠️ New traps found in Phase 4 (not in the plan, not in the corrections file)

1. **`drain_until_blocked_or_eof` from T3.1 spins at 100 % CPU on a quiet pipe.**
   `read_all_drain` returned `false` for *both* "I read bytes, more may be waiting"
   **and** "EAGAIN, nothing right now", and the drain loop was `for !eof { eof = … }`.
   Against a long-lived mostly-silent child that loop never terminates. Phase 3 never
   reached it because its children were fast: write-then-exit makes `read` return 0
   almost immediately. T4.1 is the first caller that sits on an ssh pipe for seconds,
   and it fired instantly (observed: 96 % CPU, process wedged in the drain).
   **Fixed** with a tri-state `Drain_Stat {more, blocked, eof, error}` and a drain that
   returns at the first EAGAIN. `run_capture` inherits the fix.
   *Lesson for any later phase reusing that seam: a bool cannot distinguish "blocked"
   from "finished", and every non-blocking caller will eventually hit it.*

2. **Settling a killed child without reaping it = the zombie factory, and a clean
   registry hides it.** The first cut of `registry_expire` did
   `SIGKILL → drain → if !fetch_reap { settle_exit(…) }`. When the child was not
   instantly collectable we wrote the `timeout` verdict and moved on — leaving a real
   zombie. The registry reported *every fetch cleanly `settled`* while `/proc` showed
   **3 zombie children**. T3.1's "a timeout that closes the pipes but never reaps is a
   zombie factory" trap re-created itself the moment the fan-out became asynchronous.
   **Fixed** by tracking `settled` and `reaped` as *separate* facts
   (`kill_and_reap`, `registry_unreaped`, debt sweep in `registry_free`), so "we wrote
   a verdict" can never be mistaken for "the kernel got its child back".

3. **A harness that tallies 0 checks as green.** `tally` summed `[PASS]`/`[FAIL]` lines;
   running with a stale `$BIN` (default `/tmp/hs`, a Phase-1 artifact with no
   `fetch-*` cases) produced `0 PASS / 0 FAIL` per new section and the whole suite
   still printed `RESULT: PASS`. **Fixed**: a section with zero checks is now a FAIL
   and prints the head of its log so the cause is obvious.

4. **`fmt` arity errors silently destroy evidence.** `"name {} -> {}"` was called with
   one argument in 13 Phase-3 cases, so every line printed
   `%!(MISSING ARGUMENT)` where the verdict should have been — the check still passed,
   the text beside it was garbage. Caught only because I added a `%!` grep over every
   driver log (`assert_formatted` in `dev/app-smoke.sh`). Now asserted for all four
   logs, and a repo-wide arity sweep reports zero mismatches.

5. **A prose comment can trip a guard meant for code.** The ISC-A-6 guard greps for
   `core:thread`; my file header comment *saying* "there is no `core:thread` here"
   tripped it. Reworded the comment rather than loosening the guard — the guard being
   dumb and strict is worth more than the phrasing.

6. **A timing baseline measured in a different arm is not a baseline.** My first concurrency
   assertion compared the fan-out wall against the *serial arm's* wall in the same test. That looks
   rigorous and is unsound: per-host ssh cost on this fixture swings between ~95 ms and ~240 ms from
   run to run (sshd auth contention), so the serial arm measured 255 ms while the very next fan-out
   observed one host alone taking 238 ms. The two arms were not measuring the same costs, and the
   ratio blamed the loop for the fixture — it failed 2 of 5 runs with the implementation correct and
   unchanged the whole time.
   **Fixed** by asserting **within** the fan-out arm against the per-child latencies recorded by the
   same clock in the same run (wall must be <0.8 of their sum; serialized WOULD be the sum), and by
   turning the serial arm into an explicit **negative control** that must itself sit AT its sum. 8 runs
   later: fan-out 0.50–0.72, control pinned at 1.00 — the threshold is now demonstrably
   discriminating instead of merely survivable.
   *General rule for later phases: never gate a property on a measurement taken under different
   conditions than the property. If you cannot measure both in the same breath, add a control that
   must fail when the property is absent — otherwise you are tuning a magic number against noise.*

### Measurements worth carrying forward

- Local `herdr session list --json`: **~1.5 ms** — inline at startup costs nothing, which
  is what makes "local paints first" trivially true rather than something to race for.
- One ssh host round-trip on this fixture: **~100–245 ms** (varies with sshd load).
- Fan-out wall = the **slowest child**, not the sum: 442 ms serialized → **244 ms**
  fan-out (ratio 0.55) at N=2; 8 concurrent children all settle in **901 ms** with
  `fds before=6 after=6 delta=0` and `threads 1 → 1`.
- ssh `ConnectTimeout=5` against an unroutable TEST-NET address: **5012 ms**, and
  `BatchMode=yes` means auth failures are instant instead of interactive.
- Loop stayed alive throughout: 101 frames across the 5 s black-hole wait (~20 ms/frame),
  i.e. the UI thread never once blocked on a host.

### Accepted deviations from the plan text (mine to allow, recorded for the user)

- **Black-hole host:** the plan suggests `10.255.255.1`. I used RFC 5737
  **TEST-NET `192.0.2.201`** (overridable via `HERDR_SESSION_TEST_UNREACHABLE`)
  because it is documentation-reserved and cannot belong to a real host on someone's
  network. Behaviour asserted identically.
- **Struct shape:** the plan sketches `DeviceState` as a `union` and `Fetch.pipe_fd` as a
  single `i32`. I used the existing `Device_Status` enum from `model.odin` (Phase 3
  already owns per-host status and its labels are what the UI will render) and **two**
  fds per fetch (`out_fd`, `err_fd`). One pipe would merge stdout and stderr before the
  JSON parse, which ISC-A-1 forbids outright; the status mapping also *needs* stderr
  content to tell `auth` from `unreachable` at exit 255.
- **`foreign` renamed to `carried`** in `Merge_Report` — `foreign` is a keyword in this
  Odin build and cannot be a field name.
- **`apply` vs `merge`:** the plan shows one `merge`. There are two — `merge` replaces
  one device's row group (pure data), `apply` = record the host's status and merge rows
  only when the status is `.ok`. Splitting them is what makes "a failed host contributes
  zero rows but keeps its verdict" a single obvious code path instead of a flag.

### Phase 4 — T4.1 + T4.2 — ✅ PASSED (339 PASS / 0 FAIL, fixture-armed, fresh build)
Commits `9d2c185` (code) + `528a362` (sequencing map).

**⚠️ My own verification error, recorded so it isn't repeated.** My first Phase 4 run reported
`fetch-unit: 0 PASS — nothing ran` + `13 malformed format expansions` → **3 FAIL**. I started
investigating it as a product defect and found `main.odin` *did* dispatch `fetch-unit`. The real cause:
**`app-smoke.sh` was pointing at a stale `result` symlink left over from the Phase 2 build**, which
predated the fetch dispatch entirely, so it printed usage and exited 2.
Running the subcommand directly worked; after `nix build .`, the whole suite went green.
**Discipline added: always `nix build .` (or `dev/local-build.sh`) immediately before any smoke run,
and pass `BIN=` explicitly.** A stale `result` produces *confident-looking false failures.*

**The concurrency proof is the best-designed check in the project so far** — it includes its own control:

| Arm | Wall | Children sum | Ratio | What it shows |
|---|---|---|---|---|
| Serialized (control) | 453 ms | 453 ms | **1.00** | the metric is honest — serial *is* the sum |
| Fan-out | **238 ms** | 342 ms | **0.70** | bounded by the **slowest child**, not their count |

Without the control arm, a 0.70 ratio would be meaningless. Worth copying that pattern.

Other Phase 4 evidence: zero zombie children (settled=3, kills=1); `FETCH_DEADLINE (13 s)` sits deliberately
**above** ssh's `ConnectTimeout (5 s)` so ssh reports first but we can never hang; the fetch argv is
asserted to be exactly `ssh -T -o BatchMode=yes -o ConnectTimeout=5 <host> herdr session list --json`
including a negative assertion that it is **never `-tt`**; `no_herdr` (127) distinguished from
`unreachable`; a vanished identity resolves to `-1` **rather than a stand-in index**, so a stale selection
can never silently act on the wrong row.

Regressions re-run on the same fresh binary: handoff **28 PASS**, render **69 PASS**.

### Note on the truncated worker report
The Phase 4 worker returned a cut-off message (ending on a `ps`/`awk` self-match note) with no summary.
Rather than assume success or failure from that, I verified the tree, the dispatch, and re-ran every suite.
Two of the three reported-looking problems were environmental (my stale binary). Lesson: **a truncated or
ambiguous worker report is a reason to verify harder, not to accept or reject early.**

---

## Phase 5a — T5.1 + T5.2 + T5.3 — ✅ DONE (90 UI checks / 6 pty cases, 0 regressions)

Files added: `src/ui/frame.odin`, `src/ui/sessions.odin`, `src/ui/edit.odin`,
`src/ui/list.odin`, `src/ui/float.odin`, `src/ui_cases.odin`, `dev/ui-smoke.sh`.
**T5.4 / T5.5 deliberately not started** — this slice is views + harness only.

**RCH-1 applied mid-slice.** `50-requirement-changes.md` (untracked, "read this before touching any UI
code") removes the outer border. My first working frame had a full box and a *passing* 18-check suite
asserting its corners — the requirement changed underneath it. The border was deleted rather than
recoloured (`BorderWidth{betweenChildren = 1}` only) and `FRAME_PAD` went `1 → 0` because that padding
was the border allowance. The suite was then **inverted**: the perimeter must hold **zero** box glyphs,
and the two dividers must span the **full** width. Folded into `plan.md` as **D14**.
Lesson: the requirement-changes file is part of the spec's source of truth; check it *before* the first
build, not after the first green suite.

### Suite totals on one fresh `nix build` binary (`./result/bin/herdr-session`)

| Suite | Result |
|---|---|
| `dev/ui-smoke.sh` | **6/6 cases green — 90 checks** (frame 14, sessions 16, shrink 12, edit 20, list 17, float 11) |
| `dev/app-smoke.sh` | **272 PASS / 0 FAIL** (session list byte-identical before/after) |
| `dev/render-smoke.sh` | **69 PASS / 0 FAIL** |
| `dev/handoff-smoke.sh` | **28 PASS / 0 FAIL** |
| `nix build .` / `nix run .` | green / exit 0 |
| `grep -rn 'localhost' src/` | **0 hits** |

`app-smoke` reads **272** here vs **339** logged in Phase 4 — the total includes live-herdr sections
that scale with whatever sessions exist in the daemon at run time. **0 FAIL** is the invariant; the
absolute number is environmental. Both figures came from `BIN=` pointed at a fresh build.

### Traps (each cost real time; all now encoded in the code or the suite)

1. **Odin procedure literals capture nothing.** `frame_paint(p, f, body: proc())` cannot see the
   caller's `v`/`pal`/`ordered` — `Undeclared name`. The spine is `frame_open` / `frame_close` with the
   caller painting MAIN between them, and the smoke driver keeps one module-level `Scene`.
2. **`string(dyn[:])` aliases the buffer.** Converting then `delete`-ing the dynamic array left the
   string dangling. Symptom was confusing: mojibake at the **start** of every line, which reads like a
   painting bug rather than a lifetime bug.
3. **A pty eats keystrokes written at t=0.** termbox consumes pending input during `tb_init` as terminal
   identification responses. Harness must `{ sleep 1; printf … }` and the reader must ride out seconds of
   silence (`FEED_QUIET_POLLS = 40 × 100 ms`). Symptom: **0 keys read**, every typed assertion failing
   at once, with the app otherwise perfect.
4. **A buffered report erases the evidence on crash.** `say` only appended and `print_report` flushed at
   exit, so a mid-case panic printed nothing — indistinguishable from "the case never ran". Now `say`
   streams and the report holds only the verdict.
5. **`fmt` has no `{:02}`.** The name timestamp needs an explicit pad helper; unformatted it becomes
   `%!(NO VERB)`, `ts_from_name` fails, and the whole timestamp column renders `—`.
6. **Counting whole screen lines counts the frame.** "Is this table row populated" must be judged on the
   **interior** columns; with a border every line looked populated (30 populated rows for 7 sessions).
7. **Truncation must be asserted through the *same* helper the view uses.** Comparing displayed cells to
   `fit_cols` output failed against the view's `ellipsize` output (`alpha.exampl` vs `alpha.examp…`).
   Mirror the view's own function or the check tests the wrong thing.
8. **A single `feed` consumes the whole piped script.** The UI cases assumed arrows and typed characters
   would arrive in separate reads; they arrive together, so state assertions have to be written against
   the *end* of the burst (filter `"to"`, `sel` re-placed by identity), not against an imagined step.
9. **`odin build ./src/ui` fails with `Undefined entry point 'main'`** — a non-main package can't be
   built standalone here. Use `dev/local-build.sh` / `nix build`, never a per-directory build.
10. **The nix source only carries git-tracked files.** `nix build` couldn't see `src/ui/` until the new
    files were `git add`ed — a missing-file error in the derivation, not a compile error in the code.
11. **A missing `x += 1` in a manual index loop** produced `Index 4800 is out of range 0..<4800` at the
    line *after* the write. Reproduced minimally before touching anything: worth remembering that Odin's
    bounds-panic line can point one statement past the real mistake.

### Design points worth keeping

- **One scroll helper** (`keep_visible`) drives both the sessions table and the picker, so the shrink /
  selection-visibility rule cannot drift between two lists.
- **Selection is an identity, never an index**, end to end: `app.selection_of` → highlight at render
  time → `-1` when the row is gone. The list picker's "held row filtered out → selection dropped, not
  slid onto a neighbour" check is the strongest guard against acting on the wrong row that exists yet.
- **The edit buffer is a fixed `[1024]u8`, not `[dynamic]byte`**, because a *range* `delete` on a
  dynamic array segfaults this toolchain (verified with a minimal probe). The fixed buffer also gives a
  hard input bound for free.
- **Assertions read cells, not strings.** Every UI claim in this slice is `cell_at(x, y)` /
  `glyph_at(x, y)` / `line_of(y, w)` against the real back buffer after `tb_present`, with failures
  reporting the offending coordinate and glyph name.

### Phase 5a — T5.1 + T5.2 + T5.3 — ✅ PASSED
Commit `c087c01`. Fresh-build results taken by the orchestrator:

| Suite | Result |
|---|---|
| `app-smoke.sh` (fixture-armed) | **339 PASS / 0 FAIL** — per-section 133 / 59 / 67 / 54, **identical to Phase 4** |
| `ui-smoke.sh` | **6/6 cases, 90 checks** (frame 14, sessions 16, shrink 12, edit 20, list 17, float 11) |
| `render-smoke.sh` | **69 PASS / 0 FAIL** |
| `handoff-smoke.sh` | **28 PASS / 0 FAIL** |
| hygiene | no committed binaries · `grep -rn localhost src/` empty · herdr session list unchanged |

**The 339-vs-272 discrepancy was resolved in the worker's favour.** The worker reported 272 and explained
it as environmental; I did **not** take that at face value and diffed per-section against the saved Phase 4
log — my run reproduced **339 exactly** (133/59/67/54). No regression; the worker's environment simply
counted differently. *Instructive: "environmental" is a claim that must be checked, not accepted.*

### RCH-1 (no outer border) — ✅ APPLIED AND INDEPENDENTLY CONFIRMED
Folded into `plan.md` as **D14**. I verified from the **raw ANSI byte stream**, not just the assertions:

```
row  1  herdr-session                          <- no corners, no box
row  2  (blank gap — childGap reservation)
row  3  120 x '─'                             <- Header|Main divider, full width
rows 4-38  filter: + caret, column headers, rows
row 39  120 x '─'                             <- Main|Footer divider, full width
row 40  select enter new  r remote  d delete  a attach  t theme  q quit
```
**Zero `│` vertical glyphs, zero corner glyphs anywhere.** Both dividers survive; the box is gone.

Also held under the change:
- *"both rule rows are pure rule"* → the **`childGap ≥ 2` invariant survived** removing the outer border.
- Predicted MAIN box == Clay's actual **`(0,3,120x34)`** — the freed 2×2 was correctly returned to content.
- *"every palette colour is fully opaque (alpha is not an identity tag)"* — ISC-A-8 still holds.

**Worth noting how this landed:** the worker discovered `50-requirement-changes.md` on its own, recognised
its own suite was asserting a requirement that had just been withdrawn (a full box with **passing corner
assertions**), and inverted the assertions rather than leaving a green-but-wrong test. That is the behaviour
you want from an autonomous worker and is recorded here deliberately.

### Phase 5a traps recorded (11 in todos.md) — the three expensive ones
1. **Odin procedure literals capture nothing** — killed the `frame_paint(body: proc())` design →
   `frame_open` / `frame_close` split.
2. **A pty eats keystrokes written at t=0** — termbox consumes pending input during `tb_init` (terminal
   identification responses). Symptom was *every* typed assertion failing at once. Harness now delays input 1 s.
3. **`string(dyn[:])` aliases the buffer** — dangling-read mojibake appeared at the *start* of each line and
   looked like a painting bug rather than a lifetime bug.

### Phase 5b — T5.4 + T5.5 — ✅ PASSED (823 PASS / 0 FAIL)
Commits `74634f9` (T5.4, 38 min) + `612db79` (T5.5, 157 min). **The split strategy worked** — the
work that stalled for ~12h landed in under 3.5h total once the union question was pre-answered (O10) and
the scope was halved.

| Suite | Orchestrator-verified |
|---|---|
| `tui-smoke.sh` (fixture-armed) | **99 PASS / 0 FAIL** |
| `state-smoke.sh` | **198 PASS / 0 FAIL** |
| `app-smoke.sh` (fixture-armed) | **339 PASS / 0 FAIL** |
| `ui-smoke.sh` | **90 checks / 6 of 6** |
| `render-smoke.sh` | **69 PASS / 0 FAIL** |
| `handoff-smoke.sh` | **28 PASS / 0 FAIL** |
| **Total** | **823 PASS / 0 FAIL** |

Key evidence: `nix run .` starts the TUI on a tty and exits **3** with one human line (no panic, no
leaked escapes) when stdin is `/dev/null`. Trace shows `local_ms=1 first_paint_ms=5`, healthy remote
`+157 ms`, black-hole host bounded at `+5016 ms` while keys stay answered. Terminal restore verified by
reading `tcgetattr` back from the pty **slave** on Ctrl+C, SIGTERM→143 and post-round-trip.
Guards prove a negative: `waitpid(-1,WNOHANG) = -1 (ECHILD)` after every refusal — nothing was forked.

**Verified count nuance (recorded for honesty):** an *unarmed* `tui-smoke` run reports 75 PASS; the
worker's 99 requires the fixture. Same as Phase 3 — always verify **armed**.

### Cleanup investigation — a real leftover, and a clean bill of health
A fixture-armed run left **`hs-t-guard-control` running** in `~/.config/herdr/sessions/` while the
teardown reported `scratch sessions left = []`. I investigated rather than ignoring it:
- The trap **does** remove every `hs-t-*`, and did remove this one on the next run — so the trap is sound.
- The original leftover was left by an **interrupted run** (killed before its EXIT trap could fire).
- I manually `stop` + `delete`d it and confirmed the list returned to exactly
  `default, 2026-08-11-23-37-41-812, 2026-08-30-14-59-10-730`. Two further clean re-runs confirmed it.

**Latent weakness worth hardening (non-blocking):** the drift check compares a `BEFORE` snapshot against
`after`. A leftover that predates the run is absorbed into `BEFORE`, so it is **not** flagged as drift.
The `hs-t-*` trap compensates, but a **hard-coded expected session set** would be strictly more robust.
Flagged for T6.6.

### T5.5's best bug story
A fetch at **EOF is not a reaped fetch**: once both pipes drain, the fd leaves the poll set, but the child
exits a moment later — so nothing can ever wake the loop for it. Measured: EOF at `+155 ms`, not settled
until `+5014 ms`, released only when an unrelated host's ssh exited. Fixed by capping the poll sleep at
`POLL_SLICE` while anything is unreaped (keeping `-1` only for an empty registry).
**Notable: `HS_TUI_DEBUG` was removed deliberately because the bug vanished whenever it was watched** —
a genuine Heisenbug, caught by timing rather than by logging.
