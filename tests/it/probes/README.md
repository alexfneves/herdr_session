# tests/it/probes — the T11 handoff suite's app-role and child-probe roles

These are not tests. They are the processes a handoff test is made of, and they
make **zero** counted assertions: a forked or exec'd process's ledger counters
die with its copy of the ledger, so every `support.check` lives in the parent
(`tests/it/handoff_test.odin`). What these files produce is FACTS, written to
`$HS_EVIDENCE` as `key=value` lines and echoed to the tty each process
inherited.

They exist because two of the checks in the suite they replace were not
compiled code at all. `dev/handoff-smoke.sh:37-81` wrote two probes to disk
at run time — `env_probe.sh` (a POSIX shell script) and `sig_probe.py`
(python) — and the assertions about HERDR_* scrubbing, process groups, cwd,
and the SIGINT/SIGQUIT masks existed **only** as text inside that one shell
file. Deleting `dev/` would have deleted the assertions with it.

## Layout

| path | package | what it is |
|---|---|---|
| `evidence/evidence.odin` | `evidence` | the append-only fact channel, plus its reader |
| `hsapp/hsapp.odin` | `hsapp` | every role, including both ported probes |
| `handoff_app/handoff_app.odin` | `main` | standalone build for hand runs |

## One binary, many roles

The role is selected by `$HS_ROLE`. `hsapp` is a library package so the same
role code is reachable two ways:

1. **From the it test binary itself.** `tests/it/handoff_roles_init.odin` is
   an `@(init)` dispatcher: the test process re-execs ITSELF as the app, and
   the app re-execs itself as the handoff's child probe. That removes probe
   path discovery from the suite entirely — the only path the test needs to
   know is its own (`os.get_executable_path`).
2. **From `handoff_app`**, built here, for running a role by hand.

`$BIN` in the run environment stays pointed at the product binary, which the
pty harness needs for its own purposes; `hh_begin` repoints it at the test
binary for the duration of the fork and restores it immediately after.

## Roles and the old check site each one feeds

| `$HS_ROLE` | old site in `dev/handoff-smoke.sh` | notes |
|---|---|---|
| `abi` | `:135` `"$BIN probe"` | the six foreign-ABI facts |
| `double` | `:141` | two `tb_init`/`tb_shutdown` round-trips + the guards |
| `handoff` | `:155`, `:158` | paint → `sleep N` → re-acquire → wait for one key |
| `child` | `:165`, `:175`, `:196`/`:199`, `:224`/`:250` | the generic handover; `$HS_CHILD_ROLE` names the child's role, `$HS_CHILD_CWD` the cwd handed over, `$HS_LEAK` the HERDR_* variables to install first |
| `sig-term` | `:224`, `:250` | parks in the alt screen with the product's restore handlers installed |
| `env-probe` | **the `env_probe.sh` HEREDOC at `:37-45`** | ported, see below |
| `sig-probe` | **the `sig_probe.py` HEREDOC at `:47-67`** | ported, see below |
| `exit7` | the `sh -c 'exit 7'` of case 4 | compiled, so the exit-code check does not depend on `/bin/sh` |

## `env-probe` ⇄ `env_probe.sh`

Same five lines on the inherited tty, same field meanings:

| heredoc | this port |
|---|---|
| `$$` | `posix.getpid()` |
| `awk '{print $5}' /proc/self/stat` | `posix.getpgid(0)` — column 5 of `/proc/self/stat` IS the process group |
| `awk '{print $6}' /proc/self/stat` | `posix.getsid(0)` |
| `$(pwd)` | `posix.getcwd` into a stack buffer, cloned out |
| `env \| grep -c '^HERDR_'` | prefix walk over our own environment |
| `env \| grep '^HERDR_' \| tr '\n' ' '` | the same blob, space-joined |
| `${TERM:-MISSING}` / `${COLORTERM:-MISSING}` | `lookup_env`, `"MISSING"` when absent or empty |
| `tty` | `posix.ttyname(0)`, `"not-a-tty"` when it fails |

Plus one thing `tty` cannot answer: `tcgetpgrp(0)`, i.e. whether the child is
actually IN FRONT of the terminal — the property that makes input reach it at
all, and the thing a stray `setsid()` would break.

## `sig-probe` ⇄ `sig_probe.py`

Same output, same convention, same failure semantics:

* `CHILD pid=… pgid=… sid=… SigBlk=0x…  <- child must be 0x0`
* `PARENT pid=… pgid=… SigBlk=0x…  <- the handoff owner; 0x6 == SIGINT|SIGQUIT blocked`
* handler prints `CHILD_GOT_SIGNAL=<n>` and exits `40 + n`
* sleeps 8 s and prints `CHILD_NO_SIGNAL` if nothing arrived

Read from each process's OWN `/proc` entry, which is the only way to ask the
question of the process that is actually running. The handler is written for
async-signal-safety: every byte it writes was rendered before it was
installed, into fds that were already open, and it leaves by `_exit` so no
atexit handler runs in the handoff's child.

## Completion sentinels

Every role ends by reporting `<role>_complete`. A harness that waits for the
first fact it wants and then reads the later facts off that same snapshot
races the writer — that race showed up as `key_ch=<absent>` on a run where
the keypress had been read perfectly, and as absent `app_after_*` masks.
Wait on the sentinel.

## Running a role by hand

```sh
odin build ./tests/it/probes/handoff_app -out:/tmp/handoff_app

# the app side
HS_EVIDENCE=/tmp/e.log HS_ROLE=handoff /tmp/handoff_app

# the app, handing over to the env probe with a deliberately leaky environment
HS_EVIDENCE=/tmp/e.log HS_ROLE=child HS_CHILD_ROLE=env-probe HS_CHILD_CWD=/tmp \
HS_LEAK='HERDR_ENV=1;HERDR_SESSION=x' /tmp/handoff_app
```

Every role needs a real pty except `abi` (which needs no terminal at all).
