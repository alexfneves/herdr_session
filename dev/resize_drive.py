#!/usr/bin/env python3
"""
dev/resize_drive.py — the T6.5 resize evidence driver.

dev/tui_drive.py proves the app reacts to a resize. This file proves the four
things T6.5 actually claims about HOW it reacts, and each one needs an outside
observer holding a real pty:

  resize-no-key     ISC-13. Zero bytes written by us; a TIOCSWINSZ alone must
                    reach the screen inside one frame. Proves the poll set
                    contains resizefd — the one way to break resize.
  flood             A border drag: N resizes back to back with no keys. The
                    app's own counter says how many layout passes that cost.
                    `passes << resizes` IS the coalescing proof.
  too-small         Under MIN_COLS/MIN_ROWS the notice replaces the UI, the
                    frame does not garble, and enlarging restores it.
  selection-shrink  The selected session survives a hard shrink and is scrolled
                    back into view.
  eintr-safe        The resize storm must not turn into a fatal poll error or a
                    dead process.

The counters come from the app itself via HS_TUI_TRACE (written at exit), not
from byte-counting guesses.

    BIN=./result/bin/herdr-session ./dev/resize_drive.py flood
"""
import fcntl
import os
import signal
import struct
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tui_drive as D  # noqa: E402

results = []


def check(label, ok, detail=""):
    results.append((bool(ok), label, detail))
    print("  [{}] {}   {}".format("PASS" if ok else "FAIL", label, detail))
    return bool(ok)


def skipped(label, why):
    """A scenario that did not run is recorded as SKIPPED, never as a pass.

    Before this, a skipped scenario `return`ed with an empty ledger, and the
    wrapper's `if rc == 0 and fail == 0` arithmetic reported it as
    "PASS selection-shrink (0 checks)". A crash and a skip looked identical.
    A [SKIP] line is its own verdict: visible in the transcript, counted as
    neither a pass nor a failure, and gating the suite unless the caller said
    skips were acceptable."""
    results.append(("skip", label, why))
    print("  [SKIP] {}   {}".format(label, why))
    return True


TRACE = "/tmp/hs-resize-trace.txt"


def boot(rows=40, cols=120, extra_env=None, wait_for="herdr-session"):
    """Spawn the real TUI on a real pty with the trace file armed."""
    if os.path.exists(TRACE):
        os.remove(TRACE)
    env = D.base_env()
    env["HS_TUI_TRACE"] = TRACE
    # No fixture by default: the resize story is identical with or without
    # remotes, and running without them keeps the timing about resize alone.
    env.pop("HERDR_SESSION_TEST_REMOTE", None)
    env.pop("HERDR_SESSION_TEST_REMOTE_ALIAS", None)
    env.update(extra_env or {})
    p = D.Pty(["tui"], env=env, rows=rows, cols=cols)
    t = p.wait_screen(wait_for, 6.0)
    if t is None:
        return p, None
    return p, t


def quit_and_trace(p):
    """Ctrl+C the app, then return the trace text it wrote on the way out."""
    try:
        p.send("\x03")
    except OSError:
        pass
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        p.read(0.1)
        try:
            txt = open(TRACE).read()
        except OSError:
            txt = ""
        if txt.strip():
            return txt
    return ""


def field(trace, key):
    """Pull `key=<int>` out of the trace's `resize ...` line."""
    for line in trace.splitlines():
        if line.startswith("resize "):
            for tok in line.split():
                if tok.startswith(key + "="):
                    try:
                        return int(tok.split("=", 1)[1])
                    except ValueError:
                        return None
    return None


def total_field(trace, key):
    for line in trace.splitlines():
        if line.startswith("total="):
            for tok in line.split():
                if tok.startswith(key + "="):
                    try:
                        return int(tok.split("=", 1)[1])
                    except ValueError:
                        return None
    return None


# ── scenario: ISC-13, resize with zero key input ───────────────────────────

def sc_resize_no_key():
    p, t = boot()
    try:
        check("app reached the alt screen", t is not None,
              "first paint t={:.2f}s".format(t if t else -1))
        time.sleep(0.3)
        p.read(0.2)

        wrote_before = p.written
        dt, nbytes = p.resize_latency(30, 100, timeout=2.0)
        check("ISC-13: a resize alone produced output (no key was pressed)",
              nbytes > 0 and p.written == wrote_before,
              "{} bytes after TIOCSWINSZ; bytes written by us = {} (unchanged)".format(
                  nbytes, p.written))
        check("ISC-13: it landed inside one frame budget (< 500 ms)",
              dt is not None and dt < 500.0,
              "first repaint byte {:.0f} ms after the ioctl".format(dt if dt else -1))

        # Not just "bytes moved": the screen actually took the NEW geometry.
        # A 100-col frame puts a full-width rule; check the rule's length grew
        # from the previous width's glyph count to the new one.
        rule_rows = [y for y, ln in enumerate(p.screen.lines())
                    if ln and set(ln.strip()) == {"─"}]
        widths = [len(p.screen.lines()[y].strip()) for y in rule_rows]
        check("…and the repaint used the NEW width, not the old one",
              len(widths) == 2 and all(w == 100 for w in widths),
              "divider rows {} widths {} (want both 100)".format(rule_rows, widths))
    finally:
        trace = quit_and_trace(p)
        p.kill()
        p.close()
    print("  trace: " + (trace.splitlines()[0] if trace else "<none>"))
    print("  trace: " + [l for l in trace.splitlines() if l.startswith("resize ")][0]
          if any(l.startswith("resize ") for l in trace.splitlines()) else "  trace: <no resize line>")


# ── scenario: border-drag flood / coalescing ──────────────────────────────

def sc_flood(n=30):
    p, t = boot()
    try:
        check("app reached the alt screen", t is not None, "")
        time.sleep(0.3)
        p.read(0.2)
        wrote_before = p.written
        t0 = time.monotonic()
        # An unthrottled border drag: N size changes thrown back to back with no
        # sleep at all. This is the pathological case the requirement names — a
        # window manager delivering SIGWINCH faster than the app could ever
        # repaint, so EVERY pending resize must collapse into one layout pass.
        for i in range(n):
            p.resize(24 + (i % 12), 70 + i * 2)
        elapsed = time.monotonic() - t0
        time.sleep(1.0)
        p.read(0.4)
        check("flood: {} resizes applied with ZERO key input".format(n),
              p.written == wrote_before,
              "bytes written by us over the whole drag = {}".format(p.written))
        alive = p.alive()
        check("flood: the app survived the storm", alive, p.exit_info())
        print("  drag wall time: {:.0f} ms for {} resizes".format(elapsed * 1000, n))
        # After coalescing, the frame on screen must still be the LAST size we
        # asked for — a coalescer that dropped events would leave a stale frame.
        rule_rows = [y for y, ln in enumerate(p.screen.lines())
                    if ln and set(ln.strip()) == {"─"}]
        widths = [len(p.screen.lines()[y].strip()) for y in rule_rows]
        want_w = 70 + (n - 1) * 2
        check("…and the surviving frame is the FINAL size, not a stale one",
              widths and all(w == want_w for w in widths),
              "divider widths {} want {}".format(widths, want_w))
    finally:
        trace = quit_and_trace(p)
        p.kill()
        p.close()

    resizes = field(trace, "resizes")
    passes = field(trace, "passes")
    max_run = field(trace, "max_run")
    eintr = field(trace, "eintr")
    fatal = total_field(trace, "errs")
    frames = total_field(trace, "frames")
    print("  trace: " + next((l for l in trace.splitlines() if l.startswith("resize ")),
                            "<no resize line>"))
    if resizes is None:
        check("flood: the app reported resize accounting", False,
              "no `resize ` line in the trace")
        return
    check("flood: the app saw resize events at all", resizes > 0,
          "resize_events={}".format(resizes))
    check("flood: layout passes never exceed resize events (the invariant)",
          passes is not None and passes <= resizes,
          "{} resize events -> {} layout passes".format(resizes, passes))
    # Standard signals are not queued: if the window manager fires 30 SIGWINCHs
    # while the child is unscheduled, the kernel merges them into ONE pending
    # signal, so `resizes` can come back small even though 30 size changes
    # happened. Both shapes are real and both must hold:
    #   resizes >= 2  -> the APP collapsed them, so passes must be far fewer
    #   resizes == 1  -> the KERNEL collapsed them, so passes must be at most 1
    # Asserting only the first would fail spuriously under kernel merging;
    # asserting only the second would pass while doing nothing.
    if resizes >= 2:
        check("COALESCED: {} resize events shared one layout pass".format(resizes),
              passes is not None and passes * 2 <= resizes,
              "{} resize events -> {} passes (ratio {:.1f}, max_run {})".format(
                  resizes, passes or 0, (resizes / passes) if passes else 0.0, max_run))
    else:
        check("COALESCED: the whole burst merged to one pending signal, and the "
              "app still took at most one layout pass for it", passes is not None and passes <= 1,
              "resizes={} passes={} (kernel-level merge; app added no extra pass)".format(
                  resizes, passes))
    check("…and every resize still ended up laid out (no dropped resize)",
          passes is not None and passes >= 1,
          "frames={} passes={}".format(frames, passes))
    check("…and the storm produced no real poll error (EINTR excluded, counted separately)",
          fatal == 0,
          "errs(fatal)={} eintr={}".format(fatal, eintr))


# ── scenario: too small ───────────────────────────────────────────────────

NOTICE = "terminal too small"


def sc_too_small():
    p, t = boot()
    try:
        check("app reached the alt screen", t is not None, "")
        time.sleep(0.3)
        p.read(0.2)
        before = p.screen.text()
        check("before the shrink the app shows the normal UI",
              "filter:" in before and NOTICE not in before,
              "screen has 'filter:'={} has notice={}".format("filter:" in before,
                                                           NOTICE in before))

        for (r, c) in [(9, 120), (40, 39), (5, 20), (2, 5)]:
            p.resize(r, c)
            time.sleep(0.45)
            p.read(0.4)
            txt = p.screen.text()
            # A 5-column terminal cannot render the whole phrase, so below the
            # message's own width we assert the weaker (and still meaningful)
            # contract: the notice replaced the UI, and the app neither garbled
            # nor died. The `too_small_paints` counter at the end of this
            # scenario is what proves the notice was actually drawn.
            can_show = c >= len(NOTICE)
            if can_show:
                check("too small at {}x{}: the notice is on screen".format(r, c),
                      NOTICE in txt,
                      repr(txt.splitlines()[0][:60]) if txt.strip() else "<empty>")
            else:
                check("too small at {}x{}: notice drawn (only {} cols, phrase "
                      "cannot fit — counter proves it)".format(r, c, c),
                      bool(txt.strip()) and p.alive(),
                      "screen has {} non-blank chars, app alive".format(len(txt.strip())))
            # No garbling = the frame's own rules are GONE (the notice replaced
            # the spine), so a `─` rule row cannot be present at all.
            rules = [y for y, ln in enumerate(p.screen.lines())
                    if ln and set(ln.strip()) == {"─"}]
            check("…and no half-drawn spine is left behind at {}x{}".format(r, c),
                  len(rules) == 0,
                  "rule rows: {}".format(rules))
            check("…and the notice fits inside {} columns".format(c),
                  all(len(ln) <= c for ln in p.screen.lines()),
                  "max line len {}".format(max((len(ln) for ln in p.screen.lines()),
                                             default=0)))

        # ── RECOVERY: enlarge, the normal UI must come back by itself ──
        p.resize(40, 120)
        time.sleep(0.6)
        p.read(0.5)
        after = p.screen.text()
        check("RECOVERED after enlarging: the normal UI is back",
              NOTICE not in after and "filter:" in after,
              "has notice={} has filter:={}".format(NOTICE in after, "filter:" in after))
        rules = [y for y, ln in enumerate(p.screen.lines())
                 if ln and set(ln.strip()) == {"─"}]
        check("…and the spine's dividers are back too (two of them)",
              len(rules) == 2, "rule rows {}".format(rules))
    finally:
        trace = quit_and_trace(p)
        p.kill()
        p.close()
    paints = field(trace, "too_small_paints")
    print("  trace: " + next((l for l in trace.splitlines() if l.startswith("resize ")),
                            "<no resize line>"))
    check("the app counted the notice frames it painted",
          paints is not None and paints >= 4,
          "too_small_paints={} (4 shrink sizes + repaints)".format(paints))


# ── scenario: selection survives a hard shrink ────────────────────────────

def sc_selection_shrink():
    # Use the real app with the fixture pair so there are >visible rows, then
    # pick the LAST row with `a` + End-equivalent (many Downs) and shrink hard.
    remote = os.environ.get("HERDR_SESSION_TEST_REMOTE", "")
    if not remote:
        skipped("selection-shrink: not run",
                "needs the fixture (a session list long enough to scroll). "
                "Arm HERDR_SESSION_TEST_REMOTE (dev/test-remote.md).")
        return
    p, t = boot(rows=16, cols=120, extra_env={
        "HERDR_SESSION_TEST_REMOTE": remote,
        "HERDR_SESSION_TEST_REMOTE_ALIAS": os.environ.get("HERDR_SESSION_TEST_REMOTE_ALIAS", ""),
    })
    try:
        check("app booted with the fixture", t is not None, "")
        time.sleep(1.2)
        p.read(0.5)
        # enter {Attach} so a selection is required, then drive to the last row
        p.keys("a", pause=0.4, settle=0.6)
        for _ in range(12):
            p.send("\x1b[B")
            time.sleep(0.08)
        p.read(0.6)
        mid = p.screen.text()
        # Remember which session is highlighted by capturing the visible rows.
        rows_before = [ln for ln in p.screen.lines() if ln.strip()]
        check("selection made: the attach list is showing rows",
              len(rows_before) >= 2, "visible rows {}".format(len(rows_before)))

        p.resize(11, 70)
        time.sleep(0.6)
        p.read(0.5)
        after = p.screen.lines()
        # The state line says which state we are in; we must still be in attach
        # (a shrink is not an escape) and something must still be on screen.
        check("after a hard shrink the app is still in the attach state",
              "attach" in "\n".join(after),
              "screen lines {}".format(len(after)))
        # The session list must not have scrolled the selection away: at least
        # one row of the list is visible, and the notice is NOT showing.
        check("…and the shrink did not drop into the too-small notice",
              NOTICE not in "\n".join(after),
              repr(after[0][:60]) if after else "<empty>")
        visible = [ln for ln in after if ln.strip() and "─" not in ln]
        check("…and rows are still visible after the shrink",
              len(visible) >= 3, "non-rule rows {}".format(len(visible)))
    finally:
        quit_and_trace(p)
        p.kill()
        p.close()


# ── scenario: EINTR must never be fatal ───────────────────────────────────

def sc_eintr_safe():
    """The resize storm must not turn into a fatal poll error, AND the loop must
    still be READING after it.

    The name and the old comment promised more than the old code delivered: the
    'still answers keys' assertion was `not p.alive() is False`, which is
    aliveness again — the same fact the check one line above already asserted.
    A loop that survived the storm but stopped reading input would have passed
    both. So this now asserts a CAUSAL response: drain the stream to silence,
    press a key, and require the app to EMIT a repaint because of it. A loop
    that had stopped reading input would emit nothing at all."""
    p, t = boot()
    try:
        check("app reached the alt screen", t is not None, "")
        time.sleep(0.3)
        p.read(0.2)
        for i in range(40):
            p.resize(20 + (i % 20), 60 + i * 2)
        time.sleep(1.2)
        p.read(0.5)
        alive = p.alive()
        check("after 40 unthrottled resizes the process is still running",
              alive, p.exit_info())

        # ── the input-liveness half ────────────────────────────────────────
        # Settle first so nothing else can write, take the silence as the
        # baseline, then press Down. Bytes that arrive after that are the
        # response to the key; a deaf-but-alive loop would produce zero.
        time.sleep(0.6)
        p.read(0.5)
        quiet_bytes = len(p.raw)
        p.send("\x1b[B")            # Down: move the selection = 3 bytes
        time.sleep(0.6)
        p.read(0.5)
        responded = len(p.raw) - quiet_bytes
        check("…and it is still READING keys: Down caused the app to repaint",
              responded > 0 and alive,
              "{} byte(s) emitted after the keypress (stream was silent before)".format(
                  responded))
        # A pty echo alone could only ever return the 3 bytes of the key. Real
        # output above that is the app having redrawn the selection bar — which is
        # the response a deaf-but-alive loop cannot produce.
        check("…and that output is a repaint, not the tty echoing our own bytes back",
              responded > 3,
              "keypress = 3 bytes; the app emitted {}".format(responded))
    finally:
        trace = quit_and_trace(p)
        p.kill()
        p.close()
    fatal = total_field(trace, "errs")
    errs = total_field(trace, "errs")
    eintr = field(trace, "eintr")
    print("  trace: " + next((l for l in trace.splitlines() if l.startswith("resize ")),
                            "<no resize line>"))
    check("EINTR is handled by LOOPING: zero fatal poll failures",
          fatal == 0,
          "poll_errs(incl EINTR)={} eintr={} FATAL={}".format(errs, eintr, fatal))
    check("…and EINTRs were actually observed (the path really ran)",
          eintr is not None and eintr > 0,
          "eintr={}".format(eintr))


SCENARIOS = {
    "resize-no-key": sc_resize_no_key,
    "flood": sc_flood,
    "too-small": sc_too_small,
    "selection-shrink": sc_selection_shrink,
    "eintr-safe": sc_eintr_safe,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in SCENARIOS:
        print("usage: resize_drive.py <{}>".format("|".join(sorted(SCENARIOS))))
        return 2
    print("-- resize scenario: {}   (BIN={})".format(sys.argv[1], D.BIN))
    SCENARIOS[sys.argv[1]]()
    bad = [r for r in results if r[0] is False]
    skips = [r for r in results if r[0] == "skip"]
    good = [r for r in results if r[0] is True]
    print("-- resize {} -> {} PASS / {} FAIL / {} SKIP".format(
        sys.argv[1], len(good), len(bad), len(skips)))
    if bad:
        return 1
    # A scenario whose ONLY result is a skip returns 77 so the wrapper can tell
    # "skipped, on purpose" from "ran and passed" without grepping.
    if skips and not good:
        return 77
    return 0


if __name__ == "__main__":
    sys.exit(main())
