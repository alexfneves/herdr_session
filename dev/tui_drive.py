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

        # ── R1: the footer reports what the destroy-on-detach policy DID ──
        #
        # THESE ASSERTIONS ARE INVERTED ON PURPOSE. They used to read
        # `cleanup_policy=never` / "<name> left running", which was the parked
        # D2 behaviour. RCH-3/R1 resolved D2 to `only_created`: the session this
        # app just created is stopped and deleted when the handoff returns, and
        # the footer is the seam made visible. So the correct sentence is
        # `cleanup_policy=only_created` + "stopped and deleted", and the OLD
        # sentence must now be asserted ABSENT — a silent reversion to "left
        # running" has to fail loudly here.
        notice = None
        for _ in range(30):
            p.read(0.3)
            if "cleanup_policy=only_created" in p.screen.text():
                notice = True
                break
        txt = p.screen.text()
        check("back in our own UI, reporting the destroy the policy performed",
              notice is not None and created is not None
              and "stopped and deleted" in txt,
              "footer did not report the cleanup (looked for "
              "'cleanup_policy=only_created' + 'stopped and deleted')")
        check("…and it names OUR session as the thing destroyed",
              created is not None and created in txt,
              "{!r} should appear in the cleanup notice".format(created))
        check("…and the OLD never/'left running' sentence is GONE, not lingering",
              "cleanup_policy=never" not in txt and "left running" not in txt,
              "a 'left running' footer here would mean the default reverted")
        check("…and no error is surfaced (destroy-on-detach is not an error path)",
              "NOT cleaned" not in txt and "failed" not in txt,
              "notice must carry no NOT-cleaned/failure wording")

        # ── R1: herdr itself agrees the session is gone, with NO extra key ──
        gone = session_names()
        check("herdr itself confirms the created session is DESTROYED",
              created is not None and created not in gone,
              "live names: {}".format(gone))

        p.send("\x1b[B")
        p.read(0.8)
        check("…the next key clears the notice back to the state name",
              "mode_selection  \u00b7" in p.screen.text(),
              "footer is back at mode_selection")

        # ── R1: the list was ALREADY refreshed on the way back ──
        #
        # INVERTED with the rest of the scenario. The old assertion demanded the
        # refreshed list SHOW the new row. Under R1 the new row was destroyed by
        # the same detach, so what must be proven is the requirement's other
        # half: the list the user lands on is already current — it shows no row
        # for a session herdr no longer has, and the user pressed nothing to make
        # that true. The filter line is excluded: it is the user's own typed text,
        # not a row.
        def created_table_rows():
            out = []
            for l in p.screen.lines():
                if created not in l:
                    continue
                parts = l.split()
                if parts and parts[0] != "device":
                    out.append(l)
            return out

        for _ in range(20):
            p.read(0.25)
            if not created_table_rows():
                break
        check("…and the refreshed list shows NO row for the destroyed session "
              "with no extra keypress", not created_table_rows(),
              "{} stale row(s) remain for {!r}".format(len(created_table_rows()),
                                                     created))
        # The list is not merely empty-looking: it still shows the sessions that
        # DO exist, so "no row" means refreshed rather than "nothing painted".
        still_there = [n for n in session_names() if n != "default"]
        shown_live = [l for l in p.screen.lines()
                     if any(n in l for n in still_there)]
        check("…and the list is genuinely refreshed, not blanked",
              len(shown_live) > 0,
              "{} live session(s) still listed, {} of them on screen".format(
                  len(still_there), len(shown_live)))

        # The created session must not be resurrectable by re-opening the delete
        # picker and pointing at it: it is gone from herdr AND from our list.
        p.keys("d", pause=0.3, settle=0.9)
        check("the delete picker opens on a list with no ghost of it",
              "delete_session  \u00b7" in p.screen.text()
              and not created_table_rows(),
              "ghost row(s): {}".format(len(created_table_rows())))

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


def scenario_del_key():
    """RCH-3/R3, through a REAL pty: the Del key edits.

    Before R3, KEY_DELETE (`ESC [ 3 ~`) was unmapped, so termbox delivered it,
    `ch == 0`, and it decoded to NO_KEY — the keypress vanished. A user pressing
    Del (or fn+Delete on a Mac) saw the filter refuse to shorten. Asserting the
    mapper alone would not have caught the class: the mapping is only worth
    something if the byte `ESC [ 3 ~` arriving on a real pty ends up shortening
    the real filter line the user is looking at.

    Also asserted here: runes are removed WHOLE. A byte-wise delete would leave a
    dangling UTF-8 continuation byte, which renders as garbage rather than as a
    shorter string — so we check for absence of replacement characters too, not
    just a shorter length.
    """
    CARET = "\u258f"

    def filter_text():
        for l in p.screen.lines():
            s = l.rstrip()
            if "filter:" in s:
                t = s[s.index("filter:") + len("filter:"):]
                return t.replace(CARET, "").strip()
        return None

    def table_row_count():
        n = 0
        for l in p.screen.lines():
            s = l.strip()
            if not s or "filter:" in s or s.startswith("device"):
                continue
            if "no sessions match" in s:
                return 0
            if re.match(r"^(local|[0-9a-fA-F:.]+)\s", s) or "2026-" in s:
                n += 1
        return n

    p = Pty(["tui"], env=base_env(), rows=40, cols=120)
    try:
        check("boot", p.wait_screen("herdr-session", 5.0) is not None, p.exit_info())
        p.keys("a", pause=0.3, settle=1.0)
        check("in a state that OWNS the filter", filter_text() == "",
              "filter line = {!r}".format(filter_text()))
        full = table_row_count()
        check("the list starts with rows visible", full > 0,
              "{} rows before filtering".format(full))

        # ── type three ASCII chars, then Del them away one at a time ──
        p.keys("api", pause=0.15, settle=0.9)
        check("typing three chars puts them in the filter", filter_text() == "api",
              "filter = {!r}".format(filter_text()))
        p.send("\x1b[3~")
        time.sleep(0.8)
        p.read(0.5)
        check("ONE Del (ESC [ 3 ~) shortens it to 'ap'", filter_text() == "ap",
              "filter = {!r}".format(filter_text()))
        p.send("\x1b[3~")
        time.sleep(0.7)
        p.read(0.5)
        check("…then 'a'", filter_text() == "a", "filter = {!r}".format(filter_text()))
        p.send("\x1b[3~")
        time.sleep(0.7)
        p.read(0.5)
        check("…then empty", filter_text() == "", "filter = {!r}".format(filter_text()))
        p.send("\x1b[3~")
        time.sleep(0.7)
        p.read(0.5)
        check("Del on an already-empty filter does nothing nasty",
              filter_text() == "", "filter = {!r}".format(filter_text()))

        # ── the list RE-WIDENS: the visible effect the user asked for ──
        p.keys("zzzqqq", pause=0.12, settle=0.9)
        cleared = table_row_count()
        check("a filter that matches nothing empties the table", cleared == 0,
              "{} rows at 'zzzqqq'".format(cleared))
        for _ in range(6):
            p.send("\x1b[3~")
            time.sleep(0.18)
        time.sleep(0.8)
        p.read(0.6)
        rewiden = table_row_count()
        check("six Dels erase the filter and bring the whole list back",
              filter_text() == "" and rewiden == full,
              "filter={!r} rows {} -> {}".format(filter_text(), cleared, rewiden))

        # ── whole-rune deletion: 3-byte CJK and 4-byte astral ──
        for rune, nbytes, label in ((u"\u4e16", 3, "CJK U+4E16"),
                                  (u"\U0001F600", 4, "astral U+1F600")):
            p.keys(rune, pause=0.2, settle=0.9)
            ft = filter_text()
            check("typing {} lands in the filter".format(label), rune in (ft or ""),
                  "filter = {!r}".format(ft))
            check("…and it renders as the rune, not as a replacement char",
                  ft is not None and "\ufffd" not in ft,
                  "filter = {!r}".format(ft))
            p.send("\x1b[3~")
            time.sleep(0.8)
            p.read(0.5)
            check("ONE Del removes the WHOLE {} ({} bytes) in a single press".format(
                      label, nbytes),
                  filter_text() == "",
                  "filter = {!r} (a byte-wise delete would leave {} of it)".format(
                      filter_text(), nbytes - 1))

        p.send("\x03")
        time.sleep(0.6)
        p.read(0.6)
        p.alive()
        check("Ctrl+C quits after the Del session", not p.alive(), p.exit_info())
        check("terminal settings restored", p.termios_now() == p.termios_before,
              "tcgetattr matches")
    finally:
        p.kill()
        p.close()


def scenario_mode_filter_immutable():
    """RCH-3/R2, through a REAL pty: {Mode selection} does not accept typing.

    The spec binds {Mode selection} to `Enter n r s a d t Escape Ctrl+C` and
    nothing else. Before R3's sibling change the implementation let any unclaimed
    printable fall into the filter — rationalised in a comment as keeping the
    filter line "usable" in the Sessions view. It is not in the binding list, so
    it must not happen: the filter line stays drawn (the layout must not jump)
    but stays EMPTY, the table keeps every row, and the six mode keys still work
    immediately afterwards with no residue.
    """
    # Deliberately NOT any of the six mode keys, and not a control key.
    stray = "xyzqjvpmk.1234567890 _-"
    p = Pty(["tui"], env=base_env(), rows=40, cols=120)
    try:
        check("boot into {Mode selection}",
              p.wait_screen("mode_selection", 5.0) is not None, p.exit_info())
        p.read(0.6)
        rows_before = len([n for n in session_names() if n != "default"])
        rows_before_screen = len([l for l in p.screen.lines()
                                if re.match(r"^(local|[0-9a-fA-F:.]+)\s", l.strip())])
        check("the landing list has visible rows to begin with",
              rows_before_screen > 0,
              "{} visible rows, {} non-default sessions".format(
                  rows_before_screen, rows_before))

        p.keys(stray, pause=0.06, settle=1.0)
        txt = p.screen.text()
        filt = [l.strip() for l in p.screen.lines() if "filter:" in l]
        check("typing {} unclaimed keys leaves the filter line EMPTY".format(len(stray)),
              filt and filt[0] in ("filter:", "filter: \u258f", "filter:"),
              "filter line = {!r}".format(filt[:1]))
        # NOTE: a single-character scan of the whole screen would be worthless —
        # 'p' is in "pending", 'm' is in "mode_selection", 'k' is in plenty of
        # ordinary words. "Nothing leaked" is only checkable where the leak would
        # land: the filter line, asserted empty just above, and the row count,
        # asserted unchanged just below.
        rows_after = len([l for l in p.screen.lines()
                        if re.match(r"^(local|[0-9a-fA-F:.]+)\s", l.strip())])
        check("…and the table still shows every row (nothing filtered away)",
              rows_after == rows_before_screen,
              "rows {} before -> {} after stray typing".format(
                  rows_before_screen, rows_after))
        check("…and the footer is still mode_selection (no state change)",
              "mode_selection" in txt, "footer unchanged")

        # The six mode keys must still work right after the stray typing, which
        # is what proves the stray keys were a no-op and not a swallowed prefix.
        for key, expect_footer in (("n", "name_local"), ("r", "remote_server"),
                                 ("s", "name_remote_named"), ("a", "attach"),
                                 ("d", "delete_session"), ("t", "theme")):
            p.send(key)
            time.sleep(0.9)
            p.read(0.6)
            got = p.screen.text()
            check("[%s] still reaches %s after the stray typing" % (key, expect_footer),
                  expect_footer in got,
                  "footer should name {}".format(expect_footer))
            p.send("\x1b")            # Esc back to {Mode selection}
            time.sleep(0.8)
            p.read(0.6)
            check("…and Esc comes back to mode_selection",
                  "mode_selection" in p.screen.text(), "back at the landing screen")

        # And the filter IS still editable where it is supposed to be.
        p.send("a")
        time.sleep(1.0)
        p.read(0.6)
        p.keys("zz", pause=0.15, settle=0.9)
        got = [l.strip() for l in p.screen.lines() if "filter:" in l]
        check("…but in {Attach} the SAME typing DOES reach the filter",
              any("zz" in l for l in got), "filter line = {!r}".format(got[:1]))

        p.send("\x03")
        time.sleep(0.6)
        p.read(0.6)
        p.alive()
        check("Ctrl+C quits after the immutability session", not p.alive(), p.exit_info())
    finally:
        p.kill()
        p.close()


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



# ─────────────────────────────────────────────────────────────────────────────
# A herdr that is SLOW on purpose
#
# The delete path's "working…" repaint is a claim about ORDER: the frame must be
# on the tty BEFORE the blocking control commands run, and the screen must stay
# readable while they do. Against a local herdr that answers in 20 ms the whole
# thing is over before the harness can look, so the property cannot be observed.
#
# This shim makes it observable. It answers `session list` with ONE fabricated
# scratch row and answers stop/delete by sleeping, so:
#
#   * nothing real is addressed — the shim never forwards to the real herdr, so
#     no real session (certainly not the one hosting this agent) can be stopped
#     or deleted by this scenario;
#   * the delete takes seconds, and the frames around it can be timed.
# ─────────────────────────────────────────────────────────────────────────────

SLOW_HERDR = r"""#!/bin/sh
# dev-only shim. argv: %s
PAYLOAD='{"sessions":[{"default":false,"name":"hs-t-slowdel","running":true,
  "session_dir":"/tmp/hs-slowdel","socket_path":"/tmp/hs-slowdel/herdr.sock"}]}'
case "$*" in
  *"session list"*)   printf '%s\n' "$PAYLOAD"; exit 0 ;;
  *"machine list"*)   printf '[]\n'; exit 0 ;;
  *"session stop"*)   sleep 2; printf '{}\n'; exit 0 ;;
  *"session delete"*) sleep 2; printf '{"deleted":true}\n'; exit 0 ;;
  *)                  exit 0 ;;
esac
"""


def slow_herdr_dir():
    """An on-PATH directory holding a `herdr` that stalls the control commands.

    Returns (dir, fake_home) with PATH already pointing at the shim first, so
    the app's own resolve_program finds it before the real binary.
    """
    import shutil
    import tempfile

    d = tempfile.mkdtemp(prefix="hs-slow-herdr-")
    home = tempfile.mkdtemp(prefix="hs-slow-home-")
    script = os.path.join(d, "herdr")
    with open(script, "w") as fh:
        fh.write(SLOW_HERDR)
    os.chmod(script, 0o755)
    return d, home


def scenario_delete_notice():
    """P2-5: a delete must PAINT before it blocks, not after.

    The delete is two sequential control commands the user watches with a
    frozen screen. Without a "working…" frame painted first, the screen holds
    the OLD list for the whole wait and there is no way to tell working from
    hung. Driven against the stalling shim so the wait is real and the order is
    measurable.
    """
    shim, home = slow_herdr_dir()
    live_before = session_names()
    try:
        # HERMETIC on purpose. The fixture hosts are blanked so the app has ONE
        # device (local) and ONE row (the shim's fabricated session): a delete
        # in this scenario has no path — not even a mistaken one — to a real
        # session. Passing `env` to Pty merges over os.environ, so blanking has
        # to be explicit for the scrub to actually stick.
        env = base_env({
            "PATH": shim + ":" + env_path(),
            "XDG_CONFIG_HOME": home,
            "HOME": home,
            "HERDR_SESSION_TEST_REMOTE": "",
            "HERDR_SESSION_TEST_REMOTE_ALIAS": "",
            "HERDR_SESSION_TEST_UNREACHABLE": "",
        })
        p = Pty(["tui"], env=env, rows=30, cols=110)
        try:
            check("boot with the stalling herdr shim",
                  p.wait_screen("herdr-session", 6.0) is not None, p.exit_info())
            check("only the local device is configured (fixture blanked for safety)",
                  "localhost" not in p.screen.text(),
                  "footer: {}".format(last_line(p.screen.text())))
            p.keys("d", pause=0.4, settle=0.8)
            check("delete state is up", "delete_session" in p.screen.text(),
                  "footer: {}".format(last_line(p.screen.text())))
            check("…and the ONLY selectable row is the shim's fabricated scratch session",
                  "hs-t-slowdel" in p.screen.text(),
                  "screen rows: {}".format(
                      [l.strip() for l in p.screen.text().splitlines()
                       if l.strip() and l.startswith(" local")]))

            # Down as ONE write (char-by-char would put ESC on its own through
            # the decoder and bounce us out of the state), Enter as CR.
            p.send("\x1b[B")
            time.sleep(0.25)
            p.read(0.1)
            # Timed from the KEYPRESS, not from spawn: watch_screen reports
            # spawn-relative times, and the claim under test is "the frame was on
            # the tty before the blocking control commands ran".
            t_press = time.monotonic()
            p.send("\r")
            seen = p.watch_screen({"work": "working:", "done": "deleted from"},
                                timeout=14.0)
            off = t_press - p.t0
            el_work = None if seen.get("work") is None else seen["work"] - off
            el_done = None if seen.get("done") is None else seen["done"] - off
            print("    'working:' {:+.2f}s after Enter · final notice {:+.2f}s after Enter".format(
                -1 if el_work is None else el_work,
                -1 if el_done is None else el_done))

            check("the 'working…' frame reached the tty", el_work is not None,
                  "never saw 'working:'")
            check("…and it reached it BEFORE any control command could have finished",
                  el_work is not None and el_work < 1.0,
                  "first seen at +{}".format(el_work))
            check("the delete then COMPLETED and repainted its verdict",
                  el_done is not None, "never saw 'deleted from'")
            if el_work is not None and el_done is not None:
                gap = el_done - el_work
                check("…the working frame was visible for the whole wait (shim: 2 x 2 s)",
                      gap >= 2.0, "visible for {:.2f}s".format(gap))
                check("…and the whole delete stayed inside the 2 x CONTROL_TIMEOUT budget",
                      el_done < 12.0, "done at +{:.2f}s".format(el_done))
            check("no REAL session was stopped or deleted by this scenario",
                  session_names() == live_before,
                  "live list before={} after={}".format(live_before, session_names()))
        finally:
            p.kill()
            p.close()
    finally:
        import shutil
        shutil.rmtree(shim, ignore_errors=True)
        shutil.rmtree(home, ignore_errors=True)


def scenario_refresh_key():
    """P2-4: Ctrl-L re-reads, and the footer says how old the rows are."""
    p = Pty(["tui"], env=base_env(), rows=32, cols=110)
    try:
        check("boot", p.wait_screen("herdr-session", 6.0) is not None, p.exit_info())
        check("the footer carries a list-age token from the start",
              "list " in p.screen.text(),
              "footer: {}".format(last_line(p.screen.text())))

        # Let the snapshot go visibly stale without touching anything.
        time.sleep(2.5)
        p.keys("\x15", pause=0.05, settle=0.4)  # Ctrl-U: a repaint-only key
        txt = p.screen.text()
        check("after 2.5 s idle the footer AGE is not 'now' (staleness is visible)",
              "list now" not in last_line(txt) and "list never" not in last_line(txt),
              "footer: {}".format(last_line(txt)))

        p.send("\x0c")  # Ctrl-L
        t = p.wait_screen("list re-read", 4.0)
        check("Ctrl-L re-read the list and said so", t is not None,
              "never saw 'list re-read'")
        check("…and the age went back to 'now'", "list now" in p.screen.text(),
              "footer: {}".format(last_line(p.screen.text())))

        # Entering Attach must refresh by itself: the row is about to be acted on.
        time.sleep(2.5)
        p.keys("a", pause=0.3, settle=0.6)
        check("entering {Attach} re-read the list (age back to 'now')",
              "list now" in p.screen.text(),
              "footer: {}".format(last_line(p.screen.text())))
        check("…and we are in the attach state", "attach" in p.screen.text(),
              "footer: {}".format(last_line(p.screen.text())))

        time.sleep(2.5)
        p.keys("\x1b", pause=0.2, settle=0.4)   # Esc back to mode selection
        p.keys("d", pause=0.3, settle=0.6)
        check("entering {Delete} re-read the list too",
              "list now" in p.screen.text(),
              "footer: {}".format(last_line(p.screen.text())))
    finally:
        p.kill()
        p.close()


def env_path():
    return os.environ.get("PATH", "/usr/bin:/bin")


def last_line(text):
    lines = [l for l in text.splitlines() if l.strip()]
    return lines[-1] if lines else ""


SCENARIOS = {
    "boot-local": scenario_boot_local,
    "boot-remote": scenario_boot_remote,
    "sigterm": scenario_sigterm,
    "no-orphan": scenario_no_orphan,
    "roundtrip": scenario_roundtrip,
    "del-key": scenario_del_key,
    "mode-filter-immutable": scenario_mode_filter_immutable,
    "delete-notice": scenario_delete_notice,
    "refresh-key": scenario_refresh_key,
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
