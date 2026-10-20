# T6.4 — The test remote is a fixture, not a feature

**Status: ✅ DONE**

`localhost` is a **temporary dev/CI fixture**. It is not a product concept and the
product must not know it exists. This file is the single place the fixture is
described; the driver scripts under `dev/` are the only things that read it.

---

## The rule

```
grep -rn 'localhost\|127\.0\.0\.1' src/          → NOTHING
```

Verified against the tree as committed:

```console
$ grep -rn 'localhost\|127\.0\.0\.1' src/
$
```

Zero hits. Not "zero in product files, some in comments" — zero, because a
loopback address in a comment is one copy-paste away from being a loopback address
in a shipped default. The words appear in `dev/` and in this file, and nowhere else.

(One adjacent scrub: `src/fetch_cases.odin` carried a real captured ssh error
naming `127.0.0.1` as the host in an auth-failure sample. The sample tests how we
*classify* the string, so the host is irrelevant — replaced with `203.0.113.9`
(RFC 5737 TEST-NET), which cannot be a real host and cannot become a fixture.)

---

## How the fixture gets in — env vars, one producer each

| Variable | Role | Read by |
|---|---|---|
| `HERDR_SESSION_TEST_REMOTE` | the loopback ssh target | `main.odin` (dev host set), `app_live`, `fetch_live` |
| `HERDR_SESSION_TEST_REMOTE_ALIAS` | a **second ssh target string** for the same machine | same three |
| `HERDR_SESSION_TEST_UNREACHABLE` | black-hole host, makes "one host is down" measurable | same three |

There is no fourth. Nothing else in the tree reads a host from anywhere.

`HERDR_SESSION_TEST_REMOTE_ALIAS` is a **second target string, not a label** — see
`dev/device-discriminator.md` (T6.3) for why that distinction is the whole point.

---

## Removing the fixture is one action

Two ways, both complete:

**Unset the env.** Every fixture-dependent check skips itself and the rest of the
suite stays green:

```console
$ env -u HERDR_SESSION_TEST_REMOTE -u HERDR_SESSION_TEST_REMOTE_ALIAS \
      -u HERDR_SESSION_TEST_UNREACHABLE BIN=./result/bin/herdr-session ./dev/app-smoke.sh
...
  SKIP: HERDR_SESSION_TEST_REMOTE is unset — no fixture remote available
  SKIP: need two DISTINCT ssh target strings for the discriminator
...
 PHASE 3 TOTAL: 315 PASS / 0 FAIL
 RESULT: PASS
```

315 checks pass with no fixture at all (390 with it: the 75-difference is the
remote + discriminator + fan-out checks that have nothing to point at). Remote
support is **not** the fixture — it is the generic ssh path, which every one of
those 315 checks still exercises against `local` and against the shape of the
model.

**Delete the `dev/` directory.** `nix/package.nix` filters the source to `src/`
and `vendor/` only:

```nix
rel == "src" || rel == "vendor" || lib.any (p: lib.hasPrefix p rel) [ "src/" "vendor/" ];
```

so `dev/` never enters the package today, and deleting it removes every fixture
reference without touching a line of product code. Verified: `nix build` output is
byte-identical with or without the fixture, because the fixture is data read at
runtime, never a compiled-in constant.

---

## What "intact and fully generic" means, concretely

After removing the fixture, the following still work, unchanged:

* **Config-driven remotes.** `"remotes"` in `~/.config/herdr_session.json` is the
  product path. The loader (T6.1) reads verbatim ssh targets; nothing about it
  was written for loopback.
* **Registry merge.** `machine list --json` ∪ config (O13) is shape-driven, not
  host-driven.
* **Identity `(device, name)`**, the guards, the fan-out, the per-host status
  mapping, the timeout, the handoff — all generic over an opaque device string.

The fixture made these *testable on one box*. It is not what they are.

---

## Fixture safety (enforced by the drivers, not by trust)

* Scratch names only: `hs-t-*`, one prefix constant shared by every driver.
* **Never** `hs-t-*`-adjacent to the live agent session; the running host session
  (`HERDR_SESSION=2026-10-20-08-42-00-459` on this box) is excluded by name and
  asserted present-and-untouched at the end of every run.
* Config tests use a throwaway `XDG_CONFIG_HOME` under `/tmp/hs-t6-*`. The real
  `~/.config/herdr_session.json` is never written — and does not exist on this
  box, which is why its absence is the check.
* Every driver carries an EXIT trap that stops+deletes its scratch sessions on
  failure, Ctrl-C or kill, then proves the session list is back to its pre-run
  value:

```
== post-cleanup session list: 2026-10-20-08-42-00-459,default
   [PASS] teardown restored the pre-run session list exactly
```

* `env -u HERDR_ENV -u HERDR_SESSION -u HERDR_SOCKET_PATH` prefix on every raw
  `herdr` CLI call in the drivers, so the agent's own session context cannot leak
  into a probe and make it act on the wrong server.
