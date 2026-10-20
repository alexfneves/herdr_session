#!/usr/bin/env python3
"""
dev/device_discriminator.py — T6.3, the test the loopback fixture exists to make
possible.

The problem this drives at: on ONE box, local and "remote" are the same herdr
install, so a bug that ignores the `device` field passes every localhost test.
Registering the same machine under TWO ssh target strings (`localhost` and
`127.0.0.1`) makes the sessions byte-identical while the device strings differ,
which is the only way to see a device-blind model fail without a second host.

This script runs the REAL TUI in a real pty against that pair and asserts on the
rendered screen — what a user reads, not what a function returned:

  * the same session name appears as TWO rows, one per device
  * typing either device in the filter narrows to THAT device's rows only, in
    both directions

NOT proven here, and deliberately so: "pressing enter on the alias row attaches to
the ALIAS". Driving a real attach through the pty hands the terminal to herdr, so
the assertion would be about whatever that session's UI happens to print rather
than about our code. The argv-level proof — that the alias row yields
`--remote <ALIAS>` verbatim and the primary row yields `--remote <PRIMARY>` —
lives in `app-live`, where it is checked on the argv we would exec. Do not add a
footer string check here and call it that proof: the word `attach` is in the
mode-selection key hints whether or not a row is selected, so it would pass with a
completely device-blind implementation.

Run:
  BIN=./result/bin/herdr-session HERDR_SESSION_TEST_REMOTE=localhost \
      HERDR_SESSION_TEST_REMOTE_ALIAS=127.0.0.1 ./dev/device_discriminator.py

Dev-only; never packaged (nix ships src/ and vendor/ only).
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tui_drive import Pty, base_env, check  # noqa: E402

REMOTE = os.environ.get("HERDR_SESSION_TEST_REMOTE", "")
ALIAS = os.environ.get("HERDR_SESSION_TEST_REMOTE_ALIAS", "")

# Device column width in the session table (T5.2 fixed columns).
DEVICE_W = 12


def table_rows(screen):
    """Rows that look like session-table rows: a device cell, a timestamp, a state
    and a name. Returns the RAW line so column positions survive."""
    out = []
    for line in screen.lines():
        if re.search(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d", line):
            out.append(line.rstrip())
    return out


def devices_in(rows):
    """The device cell of each row, verbatim, trailing spaces stripped."""
    return [r[:DEVICE_W].strip() for r in rows]


def names_in(rows):
    """Everything after the state column — the name, verbatim."""
    out = []
    for r in rows:
        m = re.search(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}\s+\w+\s+(.*)$", r)
        out.append(m.group(1).strip() if m else "")
    return out


def main():
    if not REMOTE or not ALIAS or REMOTE == ALIAS:
        print("    SKIPPED — need HERDR_SESSION_TEST_REMOTE and _ALIAS, distinct.")
        return 0

    env = base_env({
        "HERDR_SESSION_TEST_REMOTE": REMOTE,
        "HERDR_SESSION_TEST_REMOTE_ALIAS": ALIAS,
    })
    p = Pty(["tui"], env=env, rows=40, cols=140)
    try:
        check("boot: the TUI paints", p.wait_screen("herdr-session", 6.0) is not None,
              p.exit_info())
        # Let BOTH devices answer before reading the table.
        time.sleep(3.0)
        p.read(1.0)

        rows = table_rows(p.screen)
        devs = devices_in(rows)
        names = names_in(rows)
        print("    rendered rows: {}".format(len(rows)))
        for r in rows:
            print("      |{}".format(r[:136]))

        shared = [n for n in set(names) if names.count(n) > 1]
        check("the SAME session name appears as MULTIPLE rows (key is (device,name), not name)",
              len(shared) > 0,
              "shared names: {}".format(shared))
        if shared:
            n = shared[0]
            idx = [i for i, x in enumerate(names) if x == n]
            row_devs = [devs[i] for i in idx]
            check("…and those rows carry DIFFERENT devices: {}".format(n),
                  len(set(row_devs)) == len(idx) and len(idx) >= 2,
                  "devices for '{}': {}".format(n, row_devs))
            check("…specifically the fixture target AND its alias, both verbatim",
                  REMOTE in row_devs and ALIAS in row_devs,
                  "wanted {} + {} in {}".format(REMOTE, ALIAS, row_devs))

        # ── device filtering ───────────────────────────────────────────────
        # The filter matches device as well as name, so typing a target narrows
        # the table to that target's rows ALONE. Both directions, because a
        # filter that matched only names would show both here and hide the bug.
        for target, other in ((REMOTE, ALIAS), (ALIAS, REMOTE)):
            p.keys(target, pause=0.12, settle=0.8)
            frows = table_rows(p.screen)
            fdevs = devices_in(frows)
            check("filter '{}' narrows the table to that device alone".format(target),
                  len(frows) > 0 and all(d == target for d in fdevs),
                  "rows={} devices={}".format(len(frows), fdevs))
            check("…and the OTHER target's rows are gone (not merged in)",
                  other not in fdevs,
                  "'{}' absent from {}".format(other, fdevs))
            # clear the filter for the next round
            for _ in range(len(target)):
                p.send("\x7f")
            time.sleep(0.3)
            p.read(0.5)

        # ── attach carries the selected row's device ───────────────────────
        # NOT checked here. Driving an actual attach through the pty would hand
        # the terminal to herdr and the "test" would be whatever that session's
        # UI happens to print. The argv-level proof — that the ALIAS row puts
        # the ALIAS verbatim after `--remote`, and the primary row puts the
        # PRIMARY — lives in `app-live` (`attach on the alias row carries the
        # ALIAS verbatim after --remote`), where it is asserted on the argv we
        # would exec rather than on a rendered side effect.
        # ── NO footer check here, on purpose ───────────────────────────────
        # This file used to assert `"attach" in footer`. That check cannot fail:
        # KEYS_MODE lists `a attach` as a key hint whether a row is selected or
        # not, and the footer's per-host line legitimately names EVERY device
        # with its status (`local ok 2  localhost ok 2  127.0.0.1 ok 2`), so
        # "the footer names the selected row's device" is true for the wrong
        # reason and "the footer names only the selected row's device" is false
        # by design. There is no rendered selection affordance in this app that
        # couples the highlight to a device string, so no screen check here can
        # distinguish a device-correct build from a device-blind one.
        #
        # The proof that matters is at the argv level, where the device is an
        # operand we control rather than a pixel: `app-live` asserts that the
        # alias row produces `--remote <ALIAS>` verbatim and the primary row
        # produces `--remote <PRIMARY>`, and `app-unit` pins the same for the
        # fetch/cleanup argvs. Adding a weaker check here would be worse than
        # nothing — it would read as coverage of the exact thing this fixture
        # exists to test.
        p.send("\x03")
        time.sleep(0.4)
    finally:
        p.kill()
        p.close()

    bad = [r for r in __import__("tui_drive").results if not r[1]]
    print("\n== device-discriminator: {} PASS / {} FAIL ==".format(
        len(__import__("tui_drive").results) - len(bad), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
