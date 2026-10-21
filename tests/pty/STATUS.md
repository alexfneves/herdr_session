# tests/pty — lane P status & parity-row request

**Owner:** Agent P. **Nothing outside `tests/pty/**` has been edited** except the
T3/T4/T5 ✅ ticks in `.pi/plans/2026-10-20-odin-test-migration/todos.md`, which
the brief explicitly asked for. No product code, no `tests/support/**`, no
`tests/parity.tsv`.

## Commits

| hash | what | assertions |
|---|---|---|
| `899065b` | T3a `ffi.odin` + `width_test.odin` | 67 |
| `aa339dd` | T3b `ffi_test.odin` | 27 |
| `736d9cc` | T4 `screen.odin` + `screen_test.odin` | 73 |
| `0f96c04` | docs: lane status + parity-row request | — |
| `1898991` | docs(plan): tick T3/T4 | — |
| `d3322cf` | T5a `pty.odin` driver core | — |
| `761ef2e` | T5b `pty_test.odin` + 3 real bugs | +44 |
| `17562ea` | T5c leak cleanup + honest single-thread assertion | +1 |
| `d59dea2` | T5d `herdr_cli` / `session_names` | +6 |

**Lane total: 218 green** (38 tests, ~6.0 s, identical across repeat runs).
**T3/T4's 167 is intact** — 67 + 27 + 73. Reproduce:

```sh
odin build ./tests/pty -build-mode:test -define:ODIN_TEST_THREADS=1 -out:/tmp/hs-pty
BIN="$PWD/result/bin/herdr-session" /tmp/hs-pty
# width_test 67 | ffi_test 27 | screen_test 73 | pty_test 51
```

Per-group max is the correct tally; `HS_TALLY` lines are cumulative snapshots and
must not be summed naively (naive sum of one run's lines: 820 — meaningless).

`odin build ./src` green. `nix build .` green.

## REQUEST: parity rows for S (I did not touch `tests/parity.tsv`)

These are **new capability / additive**, not transfers from the 1544-assertion
bash baseline. Please re-run your own arithmetic script rather than trusting my
totals.

```
# suite  tier  property                                       from  to    count  notes
pty      pty   width-parity table (tb_wcwidth vs python)       -     odin  67     T3; ISC-16; frozen reachable set + recorded divergence record
pty      pty   pty alloc/resize/ctty/teardown interrogability  -     odin  27     T3; answers the nix-sandbox question
pty      pty   Screen emulator (ported, unit-tested)           -     odin  73     T4; ISC-A-3; no byte-grep anywhere in this lane
pty      pty   pty driver: spawn/observe/resize/kill/termios    -     odin  51     T5; ISC-13 written-counter + resize evidence via the product's own formatter
```

Ledger groups: `width_test`, `ffi_test`, `screen_test`, `pty_test` (file
basenames, per `tests/support/ledger.odin`'s cumulative `HS_TALLY` scheme).

## ANSWER: a pty **does** work inside the nix sandbox

T15's tier design depends on this and it had never been tested. Determined
empirically by compiling and running a C probe **inside** a `nix build` sandbox
(`pkgs.runCommand`, sandbox enabled):

```
PTY_OK master=3 slave=4
WINSZ_OK 24x80
CTTY_CHILD_EXIT=0
PTMX_OPEN=yes errno=0 (Success)
PTS_DIR=present
WRITABLE_TMP=yes
```

**→ The `pty` tier belongs in `nix flake check`, not only in `odinTestsFull`.**
`/dev/ptmx` is available and a forked child can take the controlling terminal.
There is no sandbox reason to defer pty-tier tests.

---

## RECONCILIATION 1 — the "6 failures were all wrong test expectations" claim

I made that claim loosely during T4 and it **overstated fidelity**. Corrected:

**Two of the six are deliberate divergences from Python, not matches.** They were
never cases of "the emulator matches Python exactly". Recorded as divergences with
reasons at the time.

Category A — **the test was wrong, Python is the authority** (4 cases). The
emulator matched the port and the test asserted a more "obviously correct"
behaviour than the modelled renderer actually has:

| Behaviour | Test (in `screen_test.odin`) | What I first expected | What Python actually does | Kept |
|---|---|---|---|---|
| `LF` / `\n` | `screen_control_chars_are_control_not_content` | newline returns the column to 0 | `cy += 1` only; `cx` is preserved | Python's behaviour |
| `TAB` | same test | snap to the next 8-column tab stop | `cx = min(cols, cx + 8)` — a **flat +8** | Python's behaviour |
| Leading blanks | `screen_trailing_blanks_stripped_leading_kept` | strip both ends | `rstrip()` only — leading blanks are content | Python's behaviour |
| Bare `CSI J` | `screen_erase_verbs_behave_per_spec` | defaults to `n=0` (clear below) | the ported branch table gives bare `J` **`n=1`**, which has **no branch**, so it clears **nothing** | Python's behaviour; tests emit `CSI 0 J` explicitly |

**Authority for Python:** `dev/tui_drive.py:55-196` is the emulator the existing
green bash-side TUI assertions were built against. Those assertions are the
product-level truth; the port's job is to reproduce the model they already trust.
"More correct than the model" is not a defensible reason to differ — it silently
invalidates every downstream assertion calibrated to that model. In each of the 4
cases the reason is written into the test's own comment.

Category B — **deliberate divergence from Python** (2 cases). Python is wrong here
and the port intentionally does not copy it:

| Behaviour | Test | Python does | Port does | Why |
|---|---|---|---|---|
| Truncated escape across a read boundary | `screen_split_escape_across_feeds_is_not_dropped` | regex `break` **drops** the tail of the chunk | parser state **persists** across `feed()` | A pty can fragment a write at any byte. Dropping the tail loses real terminal output and would make results depend on read size |
| UTF-8 carry buffer | `screen_split_utf8_across_two_feeds_every_boundary` | module-global carry | carry is **per-`Screen`** | Two live Screens (e.g. a diff) would corrupt each other's partial sequences |

**Did any of those "failures" expose an emulator bug that changing the expectation
then hid?** Not in the four Category-A cases — in each one the emulator's output
was re-checked against the ported Python line before the expectation was changed,
and the emulator was the thing that was right. The two Category-B items are the
opposite shape: there the *emulator* was changed (not the expectation), because
Python's behaviour was known-bad. If any of the six had been "emulator wrong,
expectation right", the fix would have been to the emulator — and there is no
expectation change in this lane that moved *away* from Python without a stated
reason in the table above.

**Caveat on reconstruction.** The exact six were observed mid-T4 while iterating;
the table is reconstructed from the committed tests and their comments, which is
the durable record. If the precise original failure list matters, it is not
recoverable from git — only the final state and its reasoning are.

---

## RECONCILIATION 2 — the width divergence record

**Where:** `tests/pty/width_test.odin`, table **`DIVERGENT_NOT_REACHED`**. Frozen as
data, not prose, with tests that assert the record *still* diverges and stays
**disjoint** from the reachable `WIDTH_CASES` table — so the divergence cannot
quietly become a claim of equality.

**What diverges** (`tb_wcwidth`, as the product applies it with `FALLBACK_WIDTH` /
`raw < 0 → 1`, vs a `unicodedata`-based model: `Mn`/`Me`/`Cf` → 0, East Asian
`W`/`F` → 2, else 1):

* **61,019** codepoints diverge in total — overwhelmingly **unassigned (Cn)**.
* **491 assigned** codepoints diverge. Named examples, with direction:

| Codepoint | Python model | termbox (post-fallback) | Direction |
|---|---|---|---|
| `U+00AD` SOFT HYPHEN | 0 | 1 | termbox wider |
| `U+1160` HANGUL JUNGSEONG FILLER | 1 | 0 | termbox narrower |
| `U+3164` HANGUL FILLER | 2 | 0 | termbox narrower |
| `U+FFA0` HALFWIDTH HANGUL FILLER | 1 | 0 | termbox narrower |
| `U+2630` TRIGRAM FOR HEAVEN | 1 | 2 | termbox wider |
| `U+3248` CIRCLED NUMBER TEN ON BLACK SQUARE | 1 | 2 | termbox wider |

**Agreements that matter** (all frozen in `WIDTH_CASES`): combining marks
`U+0300/0301/0303/0308/FE0F` = **0** in both; wide runes
`U+4E16 4E2D 6587 754C 5C3E 1F600` = **2** in both.

**Who decided the Odin side is right, and why.** Nobody voted. **`tb_wcwidth` is
the authority by construction** — it is the function the product renders with, so
whatever it returns is what a user sees. The Python model is only an approximation
of it, so where they differ the Python is the thing that is wrong for our purposes.
The decision recorded is narrower and is the only one that was actually available:
**none of these 491 assigned divergences is reachable by this project's UI**, so
parity is asserted over the reachable set and the rest is documented rather than
silently averaged. `STOP` was never triggered. If a future change makes one of
these reachable, the test that asserts disjointness is the one that should fire.

---

## Traps found in this lane (candidates for `60-handoff-notes.md`)

1. **Two procs cannot bind the same C symbol with different signatures.**
   `ioctl_ws` + `ioctl_int`, both `@(link_name="ioctl")` → `Error: Redeclaration
   of foreign procedure 'ioctl' with different type signatures`. Bind **once**
   with `arg: rawptr` — that is what C's variadic third argument actually is.
2. **Struct fields need commas.** Newline-only separation is a syntax error.
3. **Typed globals are not constants.** `X : int = 256` cannot size an array
   (`Array count must be a constant integer`). Use `X :: 256`.
4. **`for` needs all three clauses or none** — `for end > 0; end -= 1 {` is a
   syntax error. Use `for end > 0 { ... end -= 1 }`.
5. **`make` has no `(len, cap)` slice overload** — declare `[dynamic]T` inline;
   reset with `clear(&b^)`.
6. **`posix.tcgetattr` returns `result`, not `Errno`** — compare `== {}`.
   `CLocal_Flag` is spelled `CLocal_Flag_Bits` / `CLocal_Flags`.
7. **`and` / `or` are not operators** — and the error is a misleading
   `Expected ';', got identifier`, which reads like a parse problem.
8. **A clock helper must not measure itself.** `ms_now() = since(time.now())` is
   identically ~0, so *every* `ms_now() < deadline` comparison is permanently
   true; `pty_resize_latency` looped until the harness killed it at 3m20s. Use
   one monotonic epoch per object (`time.Tick`) and read it as
   `tick_diff(epoch, now)`.
9. **Every wait loop must honour EOF.** After the child dies the master reads
   `0`/`EIO` forever, so a `while now < deadline` loop busy-spins a whole core
   for the full timeout and makes "timed out" indistinguishable from a hang.
10. **`/proc/self/status` `Threads` is not a proxy for "our code is single-threaded".**
    It is process-global and picks up the test runner's own machinery: three builds
    of this lane reported **1, 2 and 3** threads for the *identical* single
    filtered test. Assert the `#config(ODIN_TEST_THREADS, 0)` knob and that *our*
    cycle adds zero threads.
11. **`os.file_info_slice_delete` took this test binary from 1 thread to 2** merely
    by being called. If a suite must stay single-threaded, do not route its
    leak-check through `os.read_directory`; use `waitpid(-1, WNOHANG)`, which is a
    stronger child-leak proof anyway.
12. **`cstring` cannot be indexed** in this Odin (`Cannot index 'c' of type
    'cstring'`); transmute to `[^]u8` for byte-level prefix checks.
13. **`json.unmarshal` wants `[]byte`, not `string`** — use
    `json.unmarshal_string` to avoid an unsafe transmute.
14. **`driver` is a reserved identifier** (procedure receiver) — avoid it as a
    module/file name; the driver is `pty.odin`.

## Single-thread note

Forks in `ffi_test.odin` are safe under a multi-threaded runner because the child
allocates **nothing** (every message is pre-built in the parent; the child calls
only `setsid`/`ioctl`/`tcgetsid`/`_exit`). Built with `ODIN_TEST_THREADS=1`
because T5's timing evidence needs it — see trap 10 for why the assertion is
written against the knob rather than `/proc`.

## Known leaks (recorded, not papered over)

* **Product-side, needs a fix outside this lane:**
  `termhandoff.build_scrubbed_env` (`src/terminal/handoff.odin:232`) calls
  `os.environ(context.allocator)` and never releases the `[]string` — ~195
  allocations per spawn. The harness frees everything it *receives* (each
  `cstring` and the array), but the intermediate is the product's to free.
  **Request:** delete `env` in `build_scrubbed_env`, or return an owned struct.
* **Test-only, pre-existing since the T4 commit:** `screen.odin:508
  runes_to_string` allocates per CSI verb inside the escape parser (line 307) and
  the result is dropped. `screen.odin` has **zero diff since `736d9cc`**, so T5
  caused none of it. Bounded per byte fed. Fix is a `defer delete` in the parser;
  not done here because the brief said not to churn T4's emulator mid-lane.

Neither leak affects a verdict, and both are visible in the run output rather than
suppressed.

## B9 note

No exit-code logic in this lane inherits `device_discriminator`'s bug. The only
child exit codes are the named `CTTY_*` constants in `ffi_test.odin`, decoded by
the parent **against named constants** rather than a truthiness test on the raw
status. `pty_exit_info` renders signal deaths as
`exit=137 (killed by signal 9)` instead of presenting a killed child as one that
chose 137, and a test asserts the report does **not** read as a chosen exit code.

## T5 — verification detail

* **Termios round-trip:** snapshot `tcgetattr(slave)` before spawn → app runs →
  `SIGTERM` → `tcgetattr(slave)` again; compared field by field including every
  `c_cc` entry. The parent holds the slave open on purpose so the terminal is
  still interrogable after the child dies — that is the whole proof.
* **No orphans:** `waitpid(-1, WNOHANG)` finds nothing left to reap after three
  spawn/kill cycles; `ps` shows **0** processes with `PPID=1` from this lane; no
  `hs-pty*` binary alive; `/dev/pts` back to **0** entries. (The pre-existing
  `herdr server` processes and the protected live-session tree are untouched and
  are not ours.)
* **No fd leaks:** `fcntl(F_GETFD)` sweep across 1024 descriptors, before vs after
  three full cycles — delta **0**. Chosen over opening `/proc/self/fd/N` probes
  because a probe open consumes the very slot being counted.
* **Resize evidence** is rendered by the product's own `th.summary()`, never a
  copied format string, and a test pins the frozen field order
  `resizes= passes= max_run= ratio= too_small_paints= eintr=` plus
  `MIN_COLS=40` / `MIN_ROWS=10`.

## Next wave

T5 is delivered, so **T11 / T12 / T13 / T14 are unblocked**. Nothing further is
planned in this lane.
