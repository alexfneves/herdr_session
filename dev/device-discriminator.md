# T6.3 — The device discriminator (⚠ MANUAL / NON-FIXTURE VERIFICATION)

**Status: ✅ DONE**

> **Labelled as the todo requires:** this is a **manual verification against a
> real loopback ssh fixture**, not a fixture-independent test. It is meaningful
> only on a box where `ssh localhost` and `ssh 127.0.0.1` reach the same herdr.
> The checks it stands for are asserted in `app-live` too, but *this* transcript
> is what the todo asked to be recorded.

---

## Why two target strings for one machine

On a single box, local and remote are the **same herdr install**. A model that
ignored `device` and keyed on session `name` alone would pass every localhost
test ever written against it, because there is only one namespace to confuse.

Registering the same machine under two distinct ssh target strings makes the
sessions **byte-identical** while the device strings differ. That is the minimum
setup in which a device-blind model *cannot* hide.

**Setup used** (fixture env only — see `dev/test-remote.md`):

```console
export HERDR_SESSION_TEST_REMOTE=localhost
export HERDR_SESSION_TEST_REMOTE_ALIAS=127.0.0.1
```

`_ALIAS` is a **second target string registered as its own `Remote`**, not a
display label on the first one. It was a label before this todo, and with that it
produced one row and the discriminator discriminated nothing. Fixed in
`src/main.odin:tui_fixture_remotes`.

---

## The underlying sessions really are identical

```console
$ herdr --version
herdr 0.9.5

$ ssh -T localhost  'herdr session list --json' | jq -c '.sessions[]|{name,running}'
{"name": "default", "running": false}
{"name": "2026-10-20-08-42-00-459", "running": true}

$ ssh -T 127.0.0.1 'herdr session list --json' | jq -c '.sessions[]|{name,running}'
{"name": "default", "running": false}
{"name": "2026-10-20-08-42-00-459", "running": true}
```

Same names, same state, same socket. Only the string we dialed differs.

---

## Check 1 — both appear as separate rows for the same session name

Key is genuinely `(device, name)`, not `name`.

`BIN=./result/bin/herdr-session ./dev/device_discriminator.py` — real TUI, real
pty, asserted on the rendered screen:

```
  [PASS] boot: the TUI paints   still running
    rendered rows: 3
      |local        2026-10-20 08:42:00.459 running  2026-10-20-08-42-00-459
      |127.0.0.1    2026-10-20 08:42:00.459 running  2026-10-20-08-42-00-459
      |localhost    2026-10-20 08:42:00.459 running  2026-10-20-08-42-00-459
  [PASS] the SAME session name appears as MULTIPLE rows (key is (device,name), not name)   shared names: ['2026-10-20-08-42-00-459']
  [PASS] …and those rows carry DIFFERENT devices: 2026-10-20-08-42-00-459   devices for '2026-10-20-08-42-00-459': ['local', '127.0.0.1', 'localhost']
  [PASS] …specifically the fixture target AND its alias, both verbatim   wanted localhost + 127.0.0.1 in ['local', '127.0.0.1', 'localhost']
```

Three rows, one session, three device strings. A `name`-keyed model would have
shown one.

---

## Check 2 — filtering by device shows both distinctly

Typing either target narrows the table to **that device's rows alone**:

```
  [PASS] filter 'localhost' narrows the table to that device alone   rows=1 devices=['localhost']
  [PASS] …and the OTHER target's rows are gone (not merged in)   '127.0.0.1' absent from ['localhost']
  [PASS] filter '127.0.0.1' narrows the table to that device alone   rows=1 devices=['127.0.0.1']
  [PASS] …and the OTHER target's rows are gone (not merged in)   'localhost' absent from ['127.0.0.1']
```

Run both directions because a filter that matched only names would show both rows
under either query and hide the bug.

---

## Check 3 — attaching via the `127.0.0.1` row puts `127.0.0.1` in `--remote`

Proved at the argv level in `app-live` (`attach_target_argv` is the branch the UI
actually takes; pulled out as a pure proc so it can be asserted without handing a
terminal to herdr):

```
  [PASS] attach on the alias row carries the ALIAS verbatim after --remote   --remote → 127.0.0.1
      127.0.0.1 row -> herdr --remote 127.0.0.1 --session 2026-10-20-08-42-00-459
  [PASS] attach on the primary row carries the PRIMARY verbatim   --remote → localhost
      localhost row -> herdr --remote localhost --session 2026-10-20-08-42-00-459
  [PASS] …and the two argvs are DIFFERENT strings — the target was not merged away
```

Asserted on `argv_after(argv, "--remote") == device`, not on
`argv_contains(argv, device)`: a contains-check would also pass on a command that
put the target in the wrong slot. **Not the alias, not the FQDN, not the label —
the exact string the row carries.**

---

## Check 4 — deleting one leaves the other's row intact

Merge/dedup is identity-correct, in both directions:

```
  [PASS] delete scoped to the alias is permitted while the primary identity is absent   alias=true primary=false
  [PASS] delete_guard(primary while only alias exists) forked nothing   waitpid(-1,WNOHANG) = -1 errno=10 (10 = ECHILD)
  [PASS] the mirror case refuses too — neither target can borrow the other's row   primary=true alias=false
```

`delete_guard(rows_with_only_alias_row, localhost, name)` **refuses**: it will not
satisfy a `localhost`-scoped delete from a `127.0.0.1` row, and vice versa. The
refusal forks nothing (`ECHILD`), so "refused" is proven rather than asserted.

And in the merged model both identities coexist:

```
  [PASS] the name is known under BOTH devices as two separate identities   localhost: true 127.0.0.1: true
  [PASS] …and looking one up by (device,name) finds exactly one, not two   got 1 want 1
  [PASS] …which is exactly 2 identities, not 1 shared row   got 2 want 2
```

---

## Stronger variant — not run

The todo's optional upgrade (two unix users on the same box → different session
namespaces under the **same** device string) would additionally discriminate
*user* scoping. It needs a second unix account and a second ssh credential on
this box; not available in this environment, so **not run and not claimed**. The
`(device, name)` identity rule it would exercise is the same one Checks 1–4 pin.

---

## Reproducing

```console
nix build
BIN=$PWD/result/bin/herdr-session \
HERDR_SESSION_TEST_REMOTE=localhost \
HERDR_SESSION_TEST_REMOTE_ALIAS=127.0.0.1 \
  python3 dev/device_discriminator.py          # the real-TUI transcript above

BIN=$PWD/result/bin/herdr-session \
HERDR_SESSION_TEST_REMOTE=localhost \
HERDR_SESSION_TEST_REMOTE_ALIAS=127.0.0.1 \
  ./dev/app-smoke.sh                          # the argv/guard checks (app-live)
```

Cleanup: the drivers stop+delete every `hs-t-*` scratch session and prove the list
is back to pre-run state. `2026-10-20-08-42-00-459` (the session hosting this
agent) is never a target and is asserted present at the end of every run.
