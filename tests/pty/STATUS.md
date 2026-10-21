# tests/pty — lane P status & parity-row request

**Owner:** Agent P. **Nothing outside `tests/pty/**` has been edited** except the
T3/T4 ✅ ticks in `.pi/plans/2026-10-20-odin-test-migration/todos.md`, which
the brief explicitly asked for.

## Commits

| hash | what | assertions |
|---|---|---|
| `899065b` | T3a `ffi.odin` + `width_test.odin` | 67 |
| `aa339dd` | T3b `ffi_test.odin` | 27 |
| `736d9cc` | T4 `screen.odin` + `screen_test.odin` | 73 |

**Suite total: 167 green.** Reproduce:

```sh
odin build ./tests/pty -build-mode:test -define:ODIN_TEST_THREADS=1 -out:/tmp/hs-pty1
/tmp/hs-pty1
```

`ODIN_TEST_THREADS=1` is deliberate — see *Single-thread note* below.

## REQUEST: parity rows for S (I did not touch `tests/parity.tsv`)

These are **new capability / additive**, not transfers from the 1544 bash
baseline. Ready to paste. Please re-run your own arithmetic script rather than
trusting my totals.

```
# suite  tier     property                                   from  to      count  notes
pty      pty      width-parity table (tb_wcwidth vs python)   -   odin    67     T3; ISC-16; frozen reachable set + recorded divergence record
pty      pty      pty alloc/resize/ctty/teardown interrogability - odin    27     T3; answers the nix-sandbox question
pty      pty      Screen emulator (ported, unit-tested)       -   odin    73     T4; ISC-A-3; no byte-grep anywhere in this lane
```

Group names for the ledger: `width_test`, `ffi_test`, `screen_test` (file
basenames, per `tests/support/ledger.odin`'s cumulative `HS_TALLY` scheme).

## ANSWER: a pty **does** work inside the nix sandbox

T15's tier design depends on this and it was never tested. Determined
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

## Traps found in this lane (candidates for `60-handoff-notes.md`)

1. **Two procs cannot bind the same C symbol with different signatures.**
   `ioctl_ws :: ...(arg: ^Win_Size)` + `ioctl_int :: ...(arg: c.int)`, both
   `@(link_name="ioctl")` → `Error: Redeclaration of foreign procedure 'ioctl'
   with different type signatures`. Bind **once** with `arg: rawptr`.
2. **Struct fields need commas** in this Odin: `struct { a : int, b : int }`.
   Newline-only separation is a syntax error (`Expected a comma, got a newline`).
3. **Typed globals are not constants.** `X : int = 256` cannot size an array
   (`Array count must be a constant integer`). Use `X :: 256`.
4. **`for` needs all three clauses or none** — `for end > 0; end -= 1 {` is a
   syntax error. Use `for end > 0 { ... end -= 1 }`.
5. **`make` has no `(len, cap)` slice overload** — use `[dynamic]T` declared
   inline, and `clear(&b^)` (not `clear(b^)`) to reset it.
6. **`posix.tcgetattr` returns `result`, not `Errno`** — compare with `== {}`.
   `CLocal_Flag` is spelled `CLocal_Flag_Bits` / `CLocal_Flags`.
7. **`and` / `or` are not operators** (already in the notes) — but note the
   failure is a confusing `Expected ';', got identifier`, not "unknown
   operator", so it reads like a parse problem rather than the real cause.

## Single-thread note

Forks in `ffi_test.odin` are safe under the multi-threaded runner because the
child allocates **nothing** (every message is pre-built in the parent, and the
child only calls `setsid`/`ioctl`/`tcgetsid`/`_exit`). Built with
`ODIN_TEST_THREADS=1` anyway, because that is the shape T5 needs for its
timing evidence and running it this way now means T5 is not the first time the
single-thread path is exercised.

## T5 — not started

Per the brief. `tests/pty/ffi.odin` (spawn primitives) and
`tests/pty/screen.odin` (the emulator) are what it needs and both are
committed. The `resize_latency` evidence must match
`src/terminal/resize.odin`'s frozen format string — that file is read-only
and unread by this lane.

## B9 note

No exit-code logic in this lane inherits `device_discriminator`'s bug: the only
child exit codes are the named `CTTY_*` constants in `ffi_test.odin`, decoded
by the parent against named constants rather than a truthiness test on the raw
status.
