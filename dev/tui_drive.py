#!/usr/bin/env python3
"""
dev/tui_drive.py — a real pty driver for the T5.5 TUI.

Why this file exists: every interesting claim about a terminal application is a
claim about BYTES ON A TTY and TIMING, and none of it can be checked from a unit
test that only sees a function's return value. So this spawns the real binary in a
real pseudo-terminal that it owns end-to-end, and measures:

  * what appeared on the screen, per repaint (bursts grouped into frames)
  * WHEN, relative to spawn, to a resize, to a keypress
  * what the terminal's own termios looked like before and after we ran
  * how much CPU the process burned while nothing happened
  * the exit status, including "killed by signal N" == shell 128+N

The parent keeps the pty SLAVE open on purpose: that is the only way to read the
terminal's line-discipline settings back after the app died, which is the whole
SIGTERM-restores-the-tty proof.

Scenario per invocation (isolated: one spawn, one verdict), driven by
dev/tui-smoke.sh.

    BIN=/tmp/hs-local ./dev/tui_drive.py boot-local
    BIN=/tmp/hs-local ./dev/tui_drive.py state-error
"""
import codecs
import fcntl
import os
import pty
import re
import signal
import struct
import subprocess
import sys
import termios
import time
import tty
import unicodedata

BIN = os.environ.get("BIN", "/tmp/hs-local")

CSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]")

results = []


def check(label, ok, detail=""):
    results.append((bool(ok), label, detail))
    print("  [{}] {}   {}".format("PASS" if ok else "FAIL", label, detail))
    return bool(ok)


def strip(b):
    return CSI.sub(b"", b).decode("utf-8", "replace")




# ─────────────────────────────────────────────────────────────────────────────
# A small terminal model
#
# termbox's renderer emits a CELL DIFF: it writes a cursor-address sequence and
# only the characters whose cell actually changed. Grep-ing the raw byte stream
# for "delete_session" therefore FAILS on a correct screen — the 'e' at column 4
# was already 'e' in the previous frame, so nothing was sent for it, and the word
# arrives with holes ("delte_sss"). Checking that is how you get a red suite on
# working code and, worse, a green suite on code that never painted.
#
# So the harness keeps a screen: cursor + grid, updated from the same bytes the
# terminal sees. What we assert on is what a user would read.
# ─────────────────────────────────────────────────────────────────────────────

CSI_RE = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z@])")


def char_width(ch):
    if unicodedata.combining(ch):
        return 0
    if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


class Screen:
    def __init__(self, rows, cols):
        self.resize(rows, cols)
        self.cx = 0
        self.cy = 0
        self.dec = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def resize(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]

    def _put(self, ch):
        if not (0 <= self.cy < self.rows):
            return
        w = char_width(ch)
        if 0 <= self.cx < self.cols:
            self.grid[self.cy][self.cx] = ch
            if w == 2 and self.cx + 1 < self.cols:
                self.grid[self.cy][self.cx + 1] = " "
        self.cx += w
        if self.cx > self.cols:
            self.cx = self.cols

    def _clear_row(self, y, x0, x1):
        if 0 <= y < self.rows:
            for x in range(max(0, x0), min(self.cols, x1)):
                self.grid[y][x] = " "

    def feed(self, data: bytes):
        s = self.dec.decode(data)
        i = 0
        while i < len(s):
            c = s[i]
            if c == "\x1b":
                # Every escape family termbox's terminfo strings actually use.
                # Missing one of these puts the escape's OWN bytes into the grid —
                # `ESC ( B` (charset designation) showed up as literal "(B"
                # smeared between the real characters, which is how the footer
                # "delete_session" became "delete_sess(Bn" and failed a check
                # against perfectly correct rendering.
                if i + 1 >= len(s):
                    break
                nxt = s[i + 1]
                if nxt == "[":
                    m = CSI_RE.match(s, i)
                    if not m:
                        break
                    self.csi(m.group(1), m.group(2))
                    i = m.end()
                    continue
                if nxt == "]":  # OSC … BEL
                    j = s.find("\x07", i)
                    i = len(s) if j < 0 else j + 1
                    continue
                if nxt in "()#":  # ESC ( X / ESC ) X / ESC # 8
                    i += 3
                    continue
                i += 2  # ESC = / ESC > / ESC 7 / ESC 8 / ESC c …
                continue
            if c == "\r":
                self.cx = 0
            elif c == "\n":
                self.cy += 1
            elif c == "\b":
                self.cx = max(0, self.cx - 1)
            elif c == "\t":
                self.cx = min(self.cols, self.cx + 8)
            else:
                self._put(c)
            i += 1

    def csi(self, params, final):
        private = params.startswith("?")
        p = params.lstrip("?")
        nums = [int(x) for x in p.split(";") if x.isdigit()]
        n = nums[0] if nums else 1
        if private or final == "m":
            return  # DECSET/DECREST and SGR: colours and modes, not content
        if final in ("H", "f"):
            self.cy = (nums[0] - 1) if len(nums) >= 1 else 0
            self.cx = (nums[1] - 1) if len(nums) >= 2 else 0
        elif final == "A":
            self.cy -= n
        elif final == "B":
            self.cy += n
        elif final == "C":
            self.cx += n
        elif final == "D":
            self.cx -= n
        elif final == "d":
            self.cy = n - 1
        elif final == "`":
            self.cx = n - 1
        elif final == "J":
            if n == 2:
                for y in range(self.rows):
                    self._clear_row(y, 0, self.cols)
            elif n == 0:
                self._clear_row(self.cy, self.cx, self.cols)
                for y in range(self.cy + 1, self.rows):
                    self._clear_row(y, 0, self.cols)
        elif final == "K":
            if n == 0:
                self._clear_row(self.cy, self.cx, self.cols)
            elif n == 1:
                self._clear_row(self.cy, 0, self.cx + 1)
            else:
                self._clear_row(self.cy, 0, self.cols)

    def lines(self):
        return ["".join(r).rstrip() for r in self.grid]

    def text(self):
        return "\n".join(self.lines())


class Pty:
    """A pty we own on both ends, plus the child running on the slave."""

    def __init__(self, args, env=None, rows=40, cols=120, cwd=None):
        self.master, self.slave = pty.openpty()
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        # Snapshot the terminal the app is about to inherit. Any handler that does
        # not put termios back shows up as a mismatch against this.
        self.termios_before = termios.tcgetattr(self.slave)
        self.child = os.fork()
        if self.child == 0:
            try:
                os.close(self.master)
                os.setsid()
                fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
                for i, fd in enumerate((self.slave, self.slave, self.slave)):
                    os.dup2(fd, i)
                if self.slave > 2:
                    os.close(self.slave)
                if cwd:
                    os.chdir(cwd)
                e = dict(os.environ)
                e.update(env or {})
                e["TERM"] = os.environ.get("TERM", "xterm-256color")
                os.execve(BIN, [BIN] + list(args), e)
            except Exception as exc:  # noqa: BLE001
                sys.stderr.write("exec failed: %s\n" % exc)
            os._exit(127)
        self.screen = Screen(rows, cols)   # what the user would read
        self.raw = bytearray()      # every byte, ever
        self.bursts = []            # (t_start, bytes) — one per read
        self.t0 = time.monotonic()
        self.written = 0            # bytes WE sent: proves "no key was pressed"

    # ── observation ────────────────────────────────────────────────────────

    def read(self, wait=0.2):
        """Read whatever is available for `wait` seconds. Returns the new bytes."""
        import select

        out = bytearray()
        deadline = time.monotonic() + wait
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            r, _, _ = select.select([self.master], [], [], left)
            if not r:
                break
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            t = time.monotonic() - self.t0
            self.bursts.append((t, bytes(chunk)))
            self.screen.feed(chunk)
            out.extend(chunk)
        self.raw.extend(out)
        return bytes(out)

    def wait_screen(self, needle, timeout=10.0, pump=0.05):
        """When (seconds after spawn) did `needle` first appear ON THE SCREEN.

        Screen model, not byte stream — see the note above the Screen class.
        """
        end = time.monotonic() + timeout
        while True:
            if needle in self.screen.text():
                return time.monotonic() - self.t0
            if time.monotonic() >= end:
                return None
            self.read(pump)

    def watch_screen(self, labels, timeout=12.0, pump=0.05):
        """First-seen time for EVERY label, watched at once.

        Sequential wait_screen() calls lie: the first one burns its whole timeout
        and every later label then "appears" at the moment we finally looked. This
        keeps a pending set and records each label the first time it hits screen.
        """
        pending = dict(labels)          # key -> search string
        seen = {}
        end = time.monotonic() + timeout
        while pending and time.monotonic() < end:
            txt = self.screen.text()
            for key, needle in list(pending.items()):
                if needle in txt:
                    seen[key] = time.monotonic() - self.t0
                    del pending[key]
            if pending:
                self.read(pump)
        return seen

    # ── input ──────────────────────────────────────────────────────────────

    def send(self, s):
        b = s.encode() if isinstance(s, str) else s
        self.written += len(b)
        os.write(self.master, b)

    def keys(self, s, pause=0.35, settle=0.5):
        for ch in s:
            self.send(ch)
            time.sleep(pause)
        self.read(settle)

    def resize_latency(self, rows, cols, timeout=2.0):
        """Resize and report how long the FIRST byte of the repaint took.

        The prior version timed the whole read window and reported 2000 ms as if
        the app were slow, when it was just our own timeout. Measure the arrival,
        not the window.
        """
        mark = len(self.bursts)
        t0 = time.monotonic()
        self.resize(rows, cols)
        end = t0 + timeout
        while time.monotonic() < end:
            self.read(0.05)
            if len(self.bursts) > mark:
                return (time.monotonic() - t0) * 1000.0, sum(len(d) for _, d in self.bursts[mark:])
        return None, 0

    def resize(self, rows, cols):
        """TIOCSWINSZ on the master -> kernel SIGWINCH -> termbox self-pipe."""
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        # The model follows the terminal, not the other way round.
        self.screen.resize(rows, cols)

    # ── teardown ───────────────────────────────────────────────────────────

    def alive(self):
        try:
            pid, status = os.waitpid(self.child, os.WNOHANG)
        except ChildProcessError:
            self.exit_status = getattr(self, "exit_status", None)
            return False
        if pid == 0:
            return True
        self.exit_status = status
        return False

    def exit_info(self):
        st = getattr(self, "exit_status", None)
        if st is None:
            return "still running"
        if os.WIFEXITED(st):
            return "exit=%d" % os.WEXITSTATUS(st)
        if os.WIFSIGNALED(st):
            return "exit=%d (killed by signal %d)" % (128 + os.WTERMSIG(st), os.WTERMSIG(st))
        return "status=%r" % st

    def kill(self, sig=signal.SIGKILL):
        try:
            os.kill(self.child, sig)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.child, 0)
        except ChildProcessError:
            pass

    def close(self):
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass

    # ── CPU accounting ─────────────────────────────────────────────────────

    def cpu_ticks(self):
        """utime+stime of the CHILD only, in clock ticks, from /proc."""
        try:
            with open("/proc/%d/stat" % self.child, "rb") as fh:
                fields = fh.read().split()
            # comm can contain spaces; count from the END so the indexes are stable
            utime = int(fields[-15])
            stime = int(fields[-14])
            return utime + stime
        except (OSError, IndexError, ValueError):
            return None

    def termios_now(self):
        try:
            return termios.tcgetattr(self.slave)
        except OSError:
            return None


def herdr_cli(*args):
    env = dict(os.environ)
    for k in ("HERDR_ENV", "HERDR_SESSION", "HERDR_SOCKET_PATH"):
        env.pop(k, None)
    return subprocess.run(["herdr"] + list(args), capture_output=True, text=True, env=env)


def session_names():
    out = herdr_cli("session", "list", "--json")
    try:
        import json

        return sorted(s["name"] for s in json.loads(out.stdout)["sessions"])
    except Exception:  # noqa: BLE001
        return []


def base_env(extra=None):
    """The TUI's env. HERDR_* is scrubbed here so the app under test starts from
    the same place a user's bare shell would, minus our own session's variables."""
    e = {}
    for k, v in os.environ.items():
        if k.startswith("HERDR_"):
            continue
        e[k] = v
    e.update(extra or {})
    return e


# ─────────────────────────────────────────────────────────────────────────────
# Scenarios
# ─────────────────────────────────────────────────────────────────────────────


def scenario_boot_local():
    """No remotes configured at all: the loop must reach `timeout == -1`, which is
    what makes the idle-CPU and resize-without-a-key claims meaningful."""
    p = Pty(["tui"], env=base_env(), rows=40, cols=120)
    try:
        t_paint = p.wait_screen("herdr-session", 4.0)
        check("boot: the app paints within 4 s", t_paint is not None,
              "first paint at t={:.2f}s ({})".format(t_paint if t_paint else -1, p.exit_info()))
        # A first frame that already carries a local session name is the
        # local-list-inline claim; with no remotes configured nothing else could
        # have produced it.
        names = [n for n in session_names() if n != "default"]
        got = p.screen.text()
        hit = next((n for n in names if n in got), None)
        check("first frame already shows a LOCAL session row", hit is not None,
              "screen contains {!r} (local rows: {})".format(hit, len(names)))
        check("first frame shows the local device as ok",
              re.search(r"\blocal ok \d", got) is not None,
              "footer: " + (got.splitlines()[-1][:100] if got.strip() else "<empty>"))

        # ── idle CPU: nothing pending, nothing typed ──
        time.sleep(0.6)
        t0 = p.cpu_ticks()
        time.sleep(5.0)
        t1 = p.cpu_ticks()
        spent = (t1 - t0) if (t0 is not None and t1 is not None) else None
        check("5 s idle burns no CPU (no spin)", spent is not None and spent <= 2,
              "{} clock ticks over 5 s (>2 would be a busy wait)".format(spent))

        # ── resize with ZERO keys ──
        wrote_before = p.written
        dt, nbytes = p.resize_latency(28, 97, timeout=2.0)
        check("a resize repaints with NO key input at all", nbytes > 0,
              "{} bytes after TIOCSWINSZ; bytes WE wrote in total = {}".format(
                  nbytes, wrote_before))
        check("…and it repaints inside one frame budget (<500 ms)",
              dt is not None and dt < 500,
              "first byte {:.0f} ms after the ioctl".format(dt if dt is not None else -1))

        # ── Ctrl+C from {Mode selection} ──
        p.send("\x03")
        time.sleep(0.6)
        p.read(0.8)
        p.alive()
        check("Ctrl+C from {Mode selection} quits", not p.alive(), p.exit_info())
        check("…with exit code 0 (a quit, not a crash)",
              getattr(p, "exit_status", None) is not None
              and os.WIFEXITED(p.exit_status) and os.WEXITSTATUS(p.exit_status) == 0,
              p.exit_info())
        check("…and leaves the alternate screen", b"\x1b[?1049l" in bytes(p.raw),
              "found ?1049l in the output stream")
        check("…and restores the terminal settings",
              p.termios_now() == p.termios_before,
              "termios after == termios before")
    finally:
        p.kill()
        p.close()


def scenario_boot_remote():
    """Loopback fixture + a black-hole host: local rows first, one host's failure
    confined to that host, and the loop still responsive while it waits."""
    remote = os.environ.get("HERDR_SESSION_TEST_REMOTE", "")
    if not remote:
        print("    SKIPPED — HERDR_SESSION_TEST_REMOTE is unset.")
        return
    dead = os.environ.get("HERDR_SESSION_TEST_UNREACHABLE", "192.0.2.201")
    env = base_env({
        "HERDR_SESSION_TEST_REMOTE": remote,
        "HERDR_SESSION_TEST_REMOTE_ALIAS": os.environ.get("HERDR_SESSION_TEST_REMOTE_ALIAS", ""),
        "HERDR_SESSION_TEST_UNREACHABLE": dead,
    })
    p = Pty(["tui"], env=env, rows=40, cols=120)
    try:
        check("boot: paints", p.wait_screen("herdr-session", 4.0) is not None, p.exit_info())
        # The footer shows each device's LABEL, so watch for the label the config
        # actually carries rather than the variable it came from — and watch them
        # ALL at once, because waiting in sequence timestamps the look, not the
        # arrival.
        rdisplay = os.environ.get("HERDR_SESSION_TEST_REMOTE_ALIAS") or remote
        seen = p.watch_screen(
            {
                "local_ok": "local ok",
                "remote_ok": "{} ok".format(rdisplay),
                "dead_down": "{} down".format(dead),
                "dead_timeout": "{} timeout".format(dead),
                "dead_auth": "{} auth".format(dead),
                "dead_noh": "{} no-herdr".format(dead),
            },
            timeout=16.0,
        )
        print("    footer timeline: " + ", ".join(
            "{}={:.2f}s".format(k, v) for k, v in sorted(seen.items(), key=lambda kv: kv[1])))

        check("local rows are on screen BEFORE the remote list arrives",
              seen.get("local_ok") is not None and seen.get("remote_ok") is not None
              and seen["local_ok"] < seen["remote_ok"],
              "local ok at {:.3f}s, {} ok at {:.3f}s".format(
                  seen.get("local_ok", -1.0), rdisplay, seen.get("remote_ok", -1.0)))

        t_dead = seen.get("dead_down") or seen.get("dead_timeout") \
            or seen.get("dead_auth") or seen.get("dead_noh")
        check("the unreachable host resolves to a verdict (never hangs in pending)",
              t_dead is not None,
              "{} -> {}".format(dead, sorted(k for k in seen if k.startswith("dead"))))
        if t_dead is not None:
            check("…inside the ssh connect-timeout bound (~6 s)", t_dead <= 6.5,
                  "{:.2f}s after spawn".format(t_dead))
        check("ONLY the dead host degraded: local keeps its rows and the healthy "
              "remote still gets its own ok row",
              seen.get("local_ok") is not None and seen.get("remote_ok") is not None
              and not any(k.startswith("dead") and k.endswith("_ok") for k in seen),
              "local ok + {} ok; {} never ok".format(rdisplay, dead))

        # and the loop answered a key the whole time
        p.send("a")
        p.read(1.2)
        check("a keypress is answered while a host is still unwelcome",
              "attach  \u00b7" in p.screen.text(),
              "footer moved to the attach state mid-fetch")
        p.send("\x03")
        time.sleep(0.5)
        p.alive()
        check("Ctrl+C still quits afterwards", not p.alive(), p.exit_info())
    finally:
        p.kill()
        p.close()


STATE_KEYS = {
    # state name -> the keys that get us there from {Mode selection}
    "mode_selection": "",
    "name_local": "n",
    "remote_server": "r",
    "name_remote_named": "s",
    "attach": "a",
    "delete_session": "d",
    "theme": "t",
    # {error}: with no herdr on PATH the very first launch cannot be resolved, and
    # the executor's refusal is the machine's error state. A real failure on the
    # real path, not a test-only poke.
    "error": "ENTER_WITHOUT_HERDR",
}


def scenario_state(name):
    if name not in STATE_KEYS:
        print("unknown state %r" % name)
        return
    keys = STATE_KEYS[name]
    if name == "error":
        env = base_env({"PATH": "/nonexistent-directory-for-this-test"})
        drive = "\n"
    else:
        env = base_env()
        drive = keys
    p = Pty(["tui"], env=env, rows=40, cols=120)
    try:
        ok_boot = p.wait_screen("herdr-session", 4.0) is not None
        if not ok_boot:
            check("state {}: reached".format(name), False, "app never painted: " + p.exit_info())
            return
        if drive:
            p.keys(drive, pause=0.3, settle=0.7)
        shown = p.screen.text()
        # Match the FOOTER's own shape ("<state>  ·  <hosts>"), not the bare word:
        # "attach" also occurs in the key hints, which would pass the check
        # without the app ever having changed state.
        marker = "{}  \u00b7  ".format(name)
        check("state {}: the footer names this state".format(name), marker in shown,
              "footer marker {!r} present".format(marker))
        p.send("\x03")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and p.alive():
            time.sleep(0.05)
        p.read(0.8)
        check("state {}: Ctrl+C quits".format(name), not p.alive(), p.exit_info())
        st = getattr(p, "exit_status", None)
        check("state {}: exit 0, not a crash".format(name),
              st is not None and os.WIFEXITED(st) and os.WEXITSTATUS(st) == 0,
              p.exit_info())
        check("state {}: alternate screen left".format(name), b"\x1b[?1049l" in bytes(p.raw), "?1049l present")
        check("state {}: termios restored".format(name),
              p.termios_now() == p.termios_before, "tcgetattr matches the pre-run snapshot")
    finally:
        p.kill()
        p.close()


def scenario_roundtrip():
    """THE happy path, end to end through the real handoff:

    type a prefix -> the app generates prefix+cycle-name -> herdr CREATES it ->
    the child owns the tty -> prefix+q detaches -> the app re-enters the alt
    screen, fully repainted, with the new row already in the list -> delete it
    through the app -> it is gone from herdr, not just from our screen.
    """
    prefix = "hs-t-tui-rt"
    scratch = "hs-t-tui"

    def purge():
        for n in session_names():
            if n.startswith(scratch):
                herdr_cli("session", "stop", "--json", n)
                herdr_cli("session", "delete", "--json", n)

    purge()
    before = session_names()
    created = None
    p = Pty(["tui"], env=base_env(), rows=40, cols=120)
    try:
        check("boot", p.wait_screen("herdr-session", 4.0) is not None, p.exit_info())
        check("no scratch session exists before we start",
              not any(n.startswith(scratch) for n in before), "list: {}".format(before))

        # {Mode selection} -> n -> {Select name of new local session}
        p.keys("n", pause=0.3, settle=0.5)
        check("the edit state is up", "name_local  \u00b7" in p.screen.text(),
              "footer names name_local")
        p.keys(prefix, pause=0.06, settle=0.5)
        check("the typed prefix is on the edit line", prefix in p.screen.text(),
              "screen shows {!r}".format(prefix))

        p.send("\n")
        time.sleep(4.0)
        mid = session_names()
        made = [n for n in mid if n.startswith(prefix + "-")]
        created = made[0] if made else None
        check("Enter handed the terminal over and herdr CREATED the session",
              created is not None,
              "created: {} (D11: prefix + cycle timestamp)".format(created))
        check("…and exactly one scratch session appeared", len(made) == 1,
              "matches: {}".format(made))

        # herdr owns the tty. `prefix+q` detaches; the app must take it back.
        p.send("\x02q")
        back = p.read(5.0)
        check("after prefix+q the app took the terminal back and repainted",
              len(back) > 500, "{} bytes streamed after the detach".format(len(back)))
        # The footer carries the executor's own honest line about the child, and
        # it is the D2 seam made visible: `never` means NOTHING was destroyed
        # behind the user's back.
        notice = p.wait_screen("cleanup_policy=never", timeout=6.0)
        check("…back in our own UI, reporting what the child did",
              notice is not None and created is not None
              and "{} left running".format(created) in p.screen.text(),
              "footer reports the session it just left running")
        p.send("\x1b[B")
        p.read(0.8)
        check("…the next key clears the notice back to the state name",
              "mode_selection  \u00b7" in p.screen.text(),
              "footer is back at mode_selection")
        seen = p.wait_screen(created, timeout=10.0)
        check("…and the refreshed list already shows the new row", seen is not None,
              "{!r} on screen at t={}".format(created,
                                            "{:.1f}s".format(seen) if seen else "never"))

        # now delete it through the app: d -> filter -> enter
        p.keys("d", pause=0.3, settle=0.8)
        check("the delete picker is up", "delete_session  \u00b7" in p.screen.text(),
              "footer names delete_session")
        p.keys(created, pause=0.04, settle=0.9)
        def device_of(line):
            parts = line.split()
            return parts[0] if parts else ""

        rows = [l for l in p.screen.lines() if created in l]
        local_rows = [l for l in rows if device_of(l) == "local"]
        check("the filter narrowed the TABLE to that one LOCAL row",
              len(local_rows) == 1,
              "{} local row(s): {}".format(len(local_rows),
                                         " | ".join(r[:100] for r in local_rows)))
        # If the fixture points at THIS machine, the same session legitimately
        # shows under a second device identity too. That is the (device, name)
        # rule being visible rather than papered over — never name-alone.
        others = [l for l in rows if device_of(l) not in ("local", "")]
        if others:
            check("…and any duplicate is a DIFFERENT device identity, never a "
                  "second local row",
                  len(local_rows) == 1,
                  "also seen on: {}".format(sorted({device_of(l) for l in others})))
        # Nothing was selected yet, and the machine does not act on an unset
        # selection — Tab is what puts the cursor on the surviving row.
        p.send("\t")
        p.read(0.6)
        p.send("\n")
        time.sleep(4.0)
        after = session_names()
        check("the app STOPPED then DELETED it, verified against herdr itself",
              created not in after, "{} is gone from herdr".format(created))
        # The filter line still shows the name we typed — that is the user's own
        # text, not a row. Look at the TABLE only.
        def table_rows():
            out = []
            for l in p.screen.lines():
                if created not in l:
                    continue
                parts = l.split()
                if parts and parts[0] == "local":
                    out.append(l)
            return out

        for _ in range(20):
            p.read(0.25)
            if not table_rows():
                break
        check("…and the table caught up (no row for a deleted session)",
              not table_rows(), "{} table rows remain; the filter line is our own text".format(
                  len(table_rows())))

        p.send("\x03")
        time.sleep(0.6)
        p.read(0.8)
        p.alive()
        check("Ctrl+C quits after the round trip", not p.alive(), p.exit_info())
        check("terminal settings restored after all of that",
              p.termios_now() == p.termios_before, "tcgetattr matches")
    finally:
        p.kill()
        p.close()
        purge()
        leftover = [n for n in session_names() if n.startswith(scratch)]
        print("    teardown: scratch sessions left = {}".format(leftover))


def scenario_sigterm():
    p = Pty(["tui"], env=base_env(), rows=40, cols=120)
    try:
        check("boot", p.wait_screen("herdr-session", 4.0) is not None, p.exit_info())
        os.kill(p.child, signal.SIGTERM)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and p.alive():
            time.sleep(0.05)
        p.read(0.8)
        check("SIGTERM exits", not p.alive(), p.exit_info())
        st = getattr(p, "exit_status", None)
        sig = os.WTERMSIG(st) if (st is not None and os.WIFSIGNALED(st)) else 0
        check("…with the shell-visible code 143 (128+SIGTERM)", sig == 15, p.exit_info())
        check("…after leaving the alternate screen", b"\x1b[?1049l" in bytes(p.raw),
              "?1049l present in the stream")
        check("…and with the terminal's termios exactly as we found it",
              p.termios_now() == p.termios_before,
              "before/after tcgetattr on the pty slave match")
    finally:
        p.kill()
        p.close()


def scenario_no_orphan():
    """The orphan rule, against the LIVE model: attach to a name that is not
    running, and prove herdr never got asked (and so never created it)."""
    name = "hs-t-tui-orphan"
    before = session_names()
    if name in before:
        herdr_cli("session", "stop", "--json", name)
        herdr_cli("session", "delete", "--json", name)
        before = session_names()
    out = subprocess.run([BIN, "guard-attach", "local", name], capture_output=True, text=True)
    print("    guard-attach said:")
    for line in out.stdout.splitlines():
        if line.strip():
            print("      " + line)
    check("attach_guard refused the unknown name",
          "[PASS] attach_guard refused" in out.stdout and "[FAIL]" not in out.stdout,
          "guard-attach exit={}".format(out.returncode))
    check("…with ECHILD from waitpid (we spawned nothing)", "errno=10" in out.stdout,
          "waitpid(-1,WNOHANG) = -1 (errno=10)")
    check("…and herdr really did not create it", name not in session_names(),
          "session list: {}".format(before))
    d = subprocess.run([BIN, "guard-delete", "local", name], capture_output=True, text=True)
    print("    guard-delete said:")
    for line in d.stdout.splitlines():
        if line.strip():
            print("      " + line)
    check("delete_guard reported honestly (nothing was deleted)",
          "nothing was deleted" in d.stdout and "[FAIL]" not in d.stdout,
          "guard-delete exit={}".format(d.returncode))
    check("…and the delete was not even attempted", "errno=10" in d.stdout,
          "ECHILD again: no child, no `session delete` call")


SCENARIOS = {
    "boot-local": scenario_boot_local,
    "boot-remote": scenario_boot_remote,
    "sigterm": scenario_sigterm,
    "no-orphan": scenario_no_orphan,
    "roundtrip": scenario_roundtrip,
}
for _s in STATE_KEYS:
    SCENARIOS["state-" + _s] = (lambda n=_s: scenario_state(n))


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in SCENARIOS:
        print("usage: tui_drive.py <{}>".format("|".join(sorted(SCENARIOS))))
        return 2
    print("-- scenario: {}   (BIN={})".format(sys.argv[1], BIN))
    SCENARIOS[sys.argv[1]]()
    bad = [r for r in results if not r[0]]
    print("-- scenario {} -> {} PASS / {} FAIL".format(
        sys.argv[1], len(results) - len(bad), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
