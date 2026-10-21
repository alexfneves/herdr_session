# T0 — Baseline: CLOSED (measured, fixture-armed)

**Date:** 2026-10-20 · **Binary:** `./result/bin/herdr-session` (nix-built @ `02c9ced`)
**Fixture:** ARMED — `HERDR_SESSION_TEST_REMOTE=localhost` · `_ALIAS=127.0.0.1` · `_UNREACHABLE=192.0.2.201`
**`ALLOW_SKIP=0`** — so no assertion quietly skipped; every figure below actually ran.
**Real `~/.config/herdr_session.json` md5 before == after:** `0cce060b885d2796d87ef1f4fd8d98b5` ✅
**Live herdr sessions before == after:** `2026-10-20-19-16-08-614`, `default` ✅ untouched
**Every suite's own teardown asserted the session list was restored exactly.**

## ✅ CORRECTED AUTHORITATIVE BASELINE

```
state 259 · app+disc 532 · tui 172 · theme 171 · resize 138 · ui 168 · render 69 · handoff 35
TOTAL: 1544 PASS / 0 FAIL   (0 SKIP)
```

**This replaces `1461` as the parity target of record for this migration.**

## Measured vs recorded, per suite

| Suite | RCH-7 recorded | Measured (armed) | Δ |
|---|---|---|---|
| `state` | 259 | **259** | 0 ✅ |
| `app+disc` | 532 | **532** | 0 ✅ |
| `tui` | 172 | **172** | 0 ✅ |
| `theme` | 171 | **171** | 0 ✅ |
| `resize` | 138 | **138** | 0 ✅ |
| `render` | 69 | **69** | 0 ✅ |
| `handoff` | 35 | **35** | 0 ✅ |
| `ui` | 90 | **168** | **+78** ⚠️ |
| **Total** | *1466 (components)* / *1461 (stated)* | **1544** | **+78** |

**Seven of eight suites match their recorded figures exactly.** The entire discrepancy is `ui`.

## The two defects found in the recorded baseline

**1. `ui` = 90 was stale; it is 168.**
The last recorded per-case breakdown (`40-execution-log.md:472`) was
*"frame 14 · sessions 16 · shrink 12 · edit 20 · list 17 · float 11" = 90*.
Measured armed: **frame 92** · sessions 16 · shrink 12 · edit 20 · list 17 · float 11 = **168**.
Five of six cases match history exactly; `ui-frame` grew 14 → 92 and the aggregate was never re-totalled.
The growth is real and accounted for — `ui-frame` now carries the **RCH-1 no-outer-border proof set**
(divider span/purity, predicted-vs-Clay box equality, *"exactly one border call, registered as the divider
source (RCH-1)"*, palette opacity, `cell_error == 0`) plus the **`KEYS_MODE` footer-overflow** checks
(`never overflows` / `cuts no hint in half` / `is not blank`). Verified not to be screen-dump
miscounting: the harness's own per-case count and an independent `grep -c '\[PASS\]'` over the same log
section both give 92.

**2. The recorded total `1461` was never consistent with its own components.**
The recorded per-suite figures sum to **1466**, not 1461 — a 5-off arithmetic slip. That is the whole of
the "≈5 residual" I flagged as unexplained in the earlier un-armed pass. It is not lost coverage; it is a
typo in a prose total.

## Hermetic / fixture split (for nix tiering)

Measured with the fixture **unarmed** (`ALLOW_SKIP=1`), against the armed figures above:

| Suite | Armed | Unarmed | Fixture-gated |
|---|---|---|---|
| `state` | 259 | 259 | **0 — 100 % hermetic** |
| `theme` | 171 | 171 | **0 — 100 % hermetic** |
| `render` | 69 | 69 | **0 — 100 % hermetic** |
| `handoff` | 35 | 35 | **0 — 100 % hermetic** |
| `app+disc` | 532 | 444 | 88 |
| `tui` | 172 | 145 | 27 |
| `resize` | 138 | 123 | 15 |
| `ui` | 168 | 168 | **0 — 100 % hermetic** |
| **Total** | **1544** | **1414** | **130** |

- **Hermetic tier (runnable in the nix sandbox — has a pty, no network): 1414 assertions, 0 fail.**
  Five suites — `state`, `theme`, `render`, `ui`, `handoff` = **585 assertions** — are 100 % hermetic
  and need no fixture at all.
- **Fixture delta = 130 assertions**, mapping exactly to the scenarios already named in the plan:
  `app-live`, `fetch-live`, `device_discriminator` (88) · `boot-remote`, `roundtrip` (27) ·
  `selection-shrink` ×3 reps (15).
- The arithmetic closes exactly: 1414 + 130 = 1544.

## Fixture arming — how it was done (reproducible)

The fixture is loopback ssh by design (`dev/test-remote.md`: *"a temporary dev/CI fixture, not a product
concept"*). Confirmed working on this host with **no `~/.ssh/config`** required:
```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost 'echo SSH_OK'      # works
ssh -o BatchMode=yes -o StrictHostKeyChecking=no 127.0.0.1 'echo SSH_OK'      # works
export HERDR_SESSION_TEST_REMOTE=localhost
export HERDR_SESSION_TEST_REMOTE_ALIAS=127.0.0.1
export HERDR_SESSION_TEST_UNREACHABLE=192.0.2.201     # RFC 5737 TEST-NET (default)
BIN=./result/bin/herdr-session ALLOW_SKIP=0 ./dev/<suite>-smoke.sh
```
`localhost` and `127.0.0.1` must both be reachable: the **discriminator** depends on them being two
distinct target *strings* for the same machine. Note `/dev/tcp/127.0.0.1/22` fails while `ssh` succeeds —
probe with `ssh`, not with a raw socket.

## T0 status: CLOSED. Nothing owed.

- [x] Full fixture-armed run of all 8 suites, `ALLOW_SKIP=0`
- [x] Corrected per-suite floors established (**`ui` → 168**)
- [x] Recorded-total arithmetic slip (1461 vs 1466) explained — no coverage lost
- [x] Hermetic / fixture split measured and closed exactly (1414 + 130 = 1544)
- [x] Reproducible fixture-arming recipe recorded
- [x] Real config md5 and live session set verified untouched across the entire run

**Timing thresholds to freeze** (from `dev/*.py`; **none may be widened during the migration** — ISC-A-2):
paint ≤ 4 / 5 / 6 s · idle ≤ 2 clock ticks over 5 s · resize first repaint < 500 ms ·
`working:` frame < 1 s after Enter · dead-host verdict ≤ 6.5 s · `delete_notice` gap ≥ 2.0 s and < 12 s ·
`resize_latency` timeout 2 s.

**Suite ports may now start against these floors.**
