#!/usr/bin/env python3
"""Replay a `script` typescript's byte stream in order.

Used by dev/handoff-smoke.sh to show, with byte offsets, that we LEAVE the
alternate screen before the child writes anything and only RE-ENTER after it is
gone — i.e. nothing of ours renders while the child owns the terminal.
"""
import re
import sys

MARKS = {
    b"\x1b[?1049h": "ENTER alt screen",
    b"\x1b[?1049l": "LEAVE alt screen  (terminal handed over to the child)",
    b"CHILD_GOT_SIGNAL": "child output while it owns the screen",
    "FORCED full repaint".encode(): "forced full repaint after re-entry",
}


def main(path: str) -> None:
    data = open(path, "rb").read()
    events = [
        (m.start(), label)
        for pattern, label in MARKS.items()
        for m in re.finditer(re.escape(pattern), data)
    ]
    for offset, label in sorted(events):
        print("    %7d  %s" % (offset, label))


if __name__ == "__main__":
    main(sys.argv[1])
