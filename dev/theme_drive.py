#!/usr/bin/env python3
"""
dev/theme_drive.py — T6.1/T6.2 evidence in a REAL pty.

Imports tui_drive's Pty/Screen/check machinery (importing it has no side
effects: BIN is read from the environment and main() only runs under
__main__), so this is the same byte-accurate terminal model that drives T5.5,
pointed at the claims that only a terminal can answer:

  picker-preselect   the theme picker OPENS on the applied theme, marked
  apply-persist      Enter on a theme repaints in it AND writes the file
  corrupt-warning    a broken config shows one warning line and the app works
  unknown-theme      an unknown theme name warns AND paints gruvbox-dark
  sgr-truecolour     the real SGR bytes for the applied palette's colours
  black-is-black     a pure-black cell asks for black, not "terminal default"
  remote-from-config a host named only in the JSON shows up as a device row

Every scenario runs with XDG_CONFIG_HOME pointing at a throwaway directory, so
the developer's real ~/.config/herdr_session.json is never read or written.
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tui_drive import Pty, check, results, base_env  # noqa: E402

CFG_NAME = "herdr_session.json"


def cfg_home(tag):
    d = "/tmp/hs-t6-pty-{}-{}".format(tag, os.getpid())
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        try:
            os.remove(os.path.join(d, f))
        except OSError:
            pass
    return d


def cfg_path(d):
    return os.path.join(d, CFG_NAME)


def write_cfg(d, text):
    with open(cfg_path(d), "w") as fh:
        fh.write(text)


def read_cfg(d):
    p = cfg_path(d)
    if not os.path.exists(p):
        return None
    with open(p) as fh:
        return fh.read()


def env_for(d, extra=None):
    """SCRUB XDG_CONFIG_HOME pointing anywhere else and aim it at the temp dir.

    base_env() already drops HERDR_*; this adds the config aim. It MUST be set
    here rather than inherited, or the suite edits the developer's real config.
    """
    e = base_env(extra)
    e["XDG_CONFIG_HOME"] = d
    return e


def sgr_bg_of(raw, r, g, b):
    return re.compile(rb"48;2;%d;%d;%d" % (r, g, b))


def sgr_fg_of(raw, r, g, b):
    return re.compile(rb"38;2;%d;%d;%d" % (r, g, b))


def default_sgr_count(raw):
    """How many times the stream asks the terminal for its DEFAULT colour.

    SGR 39 = default foreground, SGR 49 = default background: the codes
    termbox2 emits for an unset channel, and what a colour silently loses its
    value to. They must be counted as WHOLE parameters. A naive `b"39" in raw`
    also matches the 139 of `48;2;139;...` and the 239 of a latte bg, so this
    walks each SGR sequence, skips the 5-parameter truecolour sets that follow
    a 38/48 introducer, and counts only a bare 39 or 49.
    """
    n = 0
    for seq in re.finditer(rb"\x1b\[([0-9;]*)m", raw):
        params = seq.group(1).split(b";")
        i = 0
        while i < len(params):
            p = params[i]
            if p in (b"38", b"48") and i + 4 < len(params):
                i += 5
                continue
            if p in (b"39", b"49"):
                n += 1
            i += 1
    return n


def selected_row_text(p):
    """Return the text of the highlighted (selection-bar) row on screen."""
    for line in p.screen.text().splitlines():
        t = line.strip()
        if t and ("▸" in line or t.startswith(">")):
            return t
    return None


# ─────────────────────────────────────────────────────────────────────────────


def scenario_picker_preselect():
    d = cfg_home("preselect")
    write_cfg(d, json.dumps({"theme": "tokyonight-night"}))
    p = Pty(["tui"], env=env_for(d), rows=40, cols=120)
    try:
        assert p.wait_screen("herdr-session", 6)
        # tokyonight-night bg is #1a1b26 = 26,27,38: if it reached the first
        # frame, that SGR is already on the wire before any key was pressed.
        check("the config theme is on the wire in the FIRST frame (no late recolour)",
              sgr_bg_of(bytes(p.raw), 26, 27, 38).search(bytes(p.raw)) is not None,
              "tokyonight bg SGR present before any keystroke (bytes written by us: {})".format(p.written))
        p.keys("t", pause=0.4, settle=0.8)
        txt = p.screen.text()
        check("theme picker opens", "theme" in txt,
              "footer: " + (txt.splitlines()[-1][:90] if txt.strip() else "<empty>"))
        # The picker must NOT be the empty list it was before T6: rows must show.
        rows = [l.strip() for l in txt.splitlines()
                if any(n in l for n in ("gruvbox", "catppuccin", "tokyonight", "nord", "solarized"))]
        check("theme picker lists the compiled-in palettes (was: 'nothing matches')",
              len(rows) >= 8, "{} palette rows visible".format(len(rows)))
        # PRE-SELECT: the highlighted row must be the theme from the config.
        hl = None
        for l in txt.splitlines():
            if "tokyonight-night" in l:
                hl = l
                break
        check("the APPLIED theme is the one the picker is on",
              hl is not None and ("▸" in hl or ">" in hl or "(current)" in hl),
              repr(hl.strip() if hl else "<row not found>"))
        check("the applied row is marked '(current)'",
              hl is not None and "(current)" in hl, repr(hl.strip() if hl else "<none>"))
        # Everything else must NOT carry the mark.
        others = [l for l in txt.splitlines() if "(current)" in l]
        check("exactly ONE row is marked current", len(others) == 1,
              "{} marked rows".format(len(others)))
        # The selection BAR is `selection.background` — for tokyonight-night
        # the vendored #283457 = 40,52,87. Its presence while the picker is
        # open is what proves the highlight is a painted row and not just text.
        # Role: hl_bg -> .selection_background (`theme_role_source`,
        # src/app/theme.odin). There is no `accent` in the mirrored schema; the
        # #7aa2f7 this check used to name is tokyonight's normal.blue, a value
        # no role addresses, so it no longer reaches the wire anywhere.
        check("the selection bar is painted in the theme's selection.background",
              sgr_bg_of(bytes(p.raw), 40, 52, 87).search(bytes(p.raw)) is not None,
              "hl_bg SGR 48;2;40;52;87 (tokyonight selection.background #283457) emitted while the picker is open")
        p.send("\x1b")
        time.sleep(0.3)
    finally:
        p.kill()
        p.close()


def scenario_apply_persist():
    d = cfg_home("apply")
    p = Pty(["tui"], env=env_for(d), rows=40, cols=120)
    try:
        assert p.wait_screen("herdr-session", 6)
        # Before any save: no config file exists at all.
        check("no config file before the theme is chosen", read_cfg(d) is None,
              str(read_cfg(d)))
        p.keys("t", pause=0.4, settle=0.8)
        # Filter to the required theme, then Enter applies it.
        p.keys("catppuccin-latte", pause=0.06, settle=0.6)
        txt = p.screen.text()
        check("typing filters the picker down to catppuccin-latte",
              "catppuccin-latte" in txt and "gruvbox" not in txt,
              repr([l.strip() for l in txt.splitlines() if "latte" in l][:2]))
        # Down, then Enter. With a filter that hides the CURRENTLY APPLIED
        # theme, the machine leaves sel = -1 (the pre-selected row is not in
        # the filtered set), and Enter on -1 is a no-op by design; the arrow
        # is what puts the cursor on the one visible row.
        p.send("\x1b[B")
        time.sleep(0.4)
        p.read(0.4)
        p.send("\n")
        time.sleep(1.6)
        p.read(0.6)
        txt = p.screen.text()
        check("applying reports BOTH the paint and the save",
              "saved" in txt and "catppuccin-latte" in txt,
              repr(txt.splitlines()[-1][:120] if txt.strip() else "<empty>"))
        body = read_cfg(d)
        check("the config file now EXISTS on disk", body is not None, str(body))
        parsed = json.loads(body) if body else {}
        check("…and holds theme=catppuccin-latte",
              parsed.get("theme") == "catppuccin-latte", json.dumps(parsed))
    finally:
        p.kill()
        p.close()

    # ── restart: the file must drive the next boot ──
    p2 = Pty(["tui"], env=env_for(d), rows=40, cols=120)
    try:
        assert p2.wait_screen("herdr-session", 6)
        p2.keys("t", pause=0.4, settle=0.8)
        txt = p2.screen.text()
        cur = [l for l in txt.splitlines() if "(current)" in l]
        check("after a restart the SAVED theme is the applied one",
              len(cur) == 1 and "catppuccin-latte" in cur[0],
              repr(cur[0].strip()) if cur else "<no marked row>")
        # and the theme is NOT reverted to the compiled default
        check("…which is NOT the compiled-in default (so it really was reloaded)",
              cur and "gruvbox-dark" not in cur[0], "default is gruvbox-dark")
        p2.send("\x1b")
        time.sleep(0.3)
    finally:
        p2.kill()
        p.close()


def scenario_corrupt_warning():
    d = cfg_home("corrupt")
    write_cfg(d, '{"theme": "nord", this is not json')
    p = Pty(["tui"], env=env_for(d), rows=40, cols=120)
    try:
        t = p.wait_screen("herdr-session", 6)
        check("a corrupt config still starts the app", t is not None,
              "painted at {}".format(t))
        txt = p.screen.text()
        check("…with a VISIBLE warning line (ISC-19)",
              "not valid JSON" in txt or "defaults in use" in txt,
              repr(txt.splitlines()[-1][:130] if txt.strip() else "<empty>"))
        check("…that names the file the user has to fix",
              CFG_NAME in txt or d in txt, "footer carries the path")
        # …and the app is usable: the picker still works and paints.
        p.keys("t", pause=0.4, settle=0.8)
        rows = [l for l in p.screen.text().splitlines() if "catppuccin" in l]
        check("…and the app is USABLE: the theme picker still lists palettes",
              len(rows) >= 1, "{} rows".format(len(rows)))
        # The applied theme is the safe default
        cur = [l for l in p.screen.text().splitlines() if "(current)" in l]
        check("…painting the DEFAULT theme, not a half-applied one",
              len(cur) == 1 and "gruvbox-dark" in cur[0],
              repr(cur[0].strip()) if cur else "<none>")
        p.send("\x1b")
        time.sleep(0.3)
    finally:
        p.kill()
        p.close()


def scenario_unknown_theme():
    d = cfg_home("unknown")
    write_cfg(d, json.dumps({"theme": "catputin-latte"}))
    p = Pty(["tui"], env=env_for(d), rows=40, cols=120)
    try:
        assert p.wait_screen("herdr-session", 6)
        txt = p.screen.text()
        check("unknown theme: a warning is visible",
              "unknown theme" in txt, repr(txt.splitlines()[-1][:130]))
        check("…naming the bad value the user typed",
              "catputin-latte" in txt, "warning quotes 'catputin-latte'")
        check("…and naming what it fell back to",
              "gruvbox-dark" in txt, "warning carries the fallback")
        cur = [l for l in p.screen.text().splitlines() if "(current)" in l]
        p.keys("t", pause=0.4, settle=0.8)
        cur = [l for l in p.screen.text().splitlines() if "(current)" in l]
        check("…and the app painted the fallback theme",
              len(cur) == 1 and "gruvbox-dark" in cur[0],
              repr(cur[0].strip()) if cur else "<none>")
        # typing the misspelling in the FILTER still finds the right palette
        p.keys("catppuccin-latte", pause=0.06, settle=0.6)
        check("the correctly-spelled name is selectable from the picker",
              "catppuccin-latte" in p.screen.text(), "selectable after warning")
        p.send("\x1b")
        time.sleep(0.3)
    finally:
        p.kill()
        p.close()


def scenario_sgr_truecolour():
    """The applied palette's colours must reach the wire as 24-bit SGR."""
    d = cfg_home("sgr")
    # catppuccin-latte bg = #eff1f5 = 239,241,245
    write_cfg(d, json.dumps({"theme": "catppuccin-latte"}))
    p = Pty(["tui"], env=env_for(d), rows=30, cols=100)
    try:
        assert p.wait_screen("herdr-session", 6)
        raw = bytes(p.raw)
        check("bg #eff1f5 is emitted as SGR 48;2;239;241;245",
              sgr_bg_of(raw, 239, 241, 245).search(raw) is not None,
              "found in {} bytes of output".format(len(raw)))
        # text colour fg #4c4f69 = 76,79,105
        check("fg #4c4f69 is emitted as SGR 38;2;76;79;105",
              sgr_fg_of(raw, 76, 79, 105).search(raw) is not None, "truecolour fg")
        # The selection bar is `selection.background`; latte's is #d8dae1 =
        # 216,218,225. The old #8839ef was the deleted `accent` slot, and
        # latte's mirrored set contains no such value anywhere — so the old
        # expectation asserted a colour the schema never had. (Picking the bar
        # SGR alone rather than the bar's text is deliberate here: latte's
        # `selection.text` is #4c4f69, the SAME hex as its `primary.foreground`,
        # so a fg check would prove nothing about the bar that the check above
        # it does not already prove.)
        p.keys("t", pause=0.4, settle=1.0)
        raw2 = bytes(p.raw)
        check("selection bar selection.background #d8dae1 reaches the wire as 48;2;216;218;225",
              sgr_bg_of(raw2, 216, 218, 225).search(raw2) is not None,
              "selection bar painted in the palette's selection.background")
        check("output mode is truecolour (no 256-colour-only fallback)",
              b"\x1b[?1049h" in raw2 and sgr_bg_of(raw2, 239, 241, 245).search(raw2) is not None,
              "alt-screen + 24-bit SGR present")
        p.send("\x1b")
        time.sleep(0.3)
    finally:
        p.kill()
        p.close()


def scenario_black_is_black():
    """The termbox2 trap: an unset attr means 'terminal default', not black.

    Under the mirrored schema gruvbox-dark's dark value is #282828 (40,40,40) —
    upstream hands that ONE hex to primary.background, normal.black, cursor.text
    and selection.text alike. The dark0_hard #1d2021 this scenario used to name
    is not in the vendored file and is painted nowhere. So what is asserted is
    the same property on the values that actually ship: the dark value goes out
    as explicit 24-bit SGR on BOTH channels (bg for the page, fg for the bar's
    label), and the session stream never falls back to a "use the terminal's own
    colour" code.

    What this does NOT claim: that #282828 sits near the attr-0 cliff. 0x282828
    is nowhere near zero, and the true attr-0 case (pure black vs TB_HI_BLACK)
    is covered in-process by the `colour-wire` case. This is the out-of-process
    half of the same rule — no default-colour substitution on the wire.
    """
    d = cfg_home("black")
    write_cfg(d, json.dumps({"theme": "gruvbox-dark"}))
    p = Pty(["tui"], env=env_for(d), rows=30, cols=100)
    try:
        assert p.wait_screen("herdr-session", 6)
        p.keys("t", pause=0.4, settle=1.0)
        raw = bytes(p.raw)
        check("gruvbox bg #282828 goes out as 48;2;40;40;40 (not the default)",
              sgr_bg_of(raw, 40, 40, 40).search(raw) is not None, "real SGR for the bg")
        # The dark value as a FOREGROUND: gruvbox-dark's selection.text is
        # #282828, so the selection bar's label must go out as explicit
        # 38;2;40;40;40 rather than as "no colour requested".
        check("selection.text #282828 goes out as 38;2;40;40;40",
              sgr_fg_of(raw, 40, 40, 40).search(raw) is not None,
              "the palette's dark value is NOT sent as the terminal default")
        # The trap, asserted directly and non-vacuously. The expression here
        # used to be `A and not (B and not A)`, which reduces to A — it could
        # never fail on the default-colour half no matter what the wire carried.
        # Counting real 39/49 parameters over the WHOLE session (boot paint +
        # picker + every repaint) is the strong form: any dark value that had
        # been mapped to an unset attr would show up here as a count > 0.
        defaults = default_sgr_count(raw)
        check("the dark colour is never routed to 'default' (SGR 39/49)",
              sgr_fg_of(raw, 40, 40, 40).search(raw) is not None and defaults == 0,
              "explicit RGB present; %d default-colour SGR(s) in %d bytes" % (defaults, len(raw)))
        p.send("\x1b")
        time.sleep(0.3)
    finally:
        p.kill()
        p.close()


def scenario_remote_from_config():
    """O7 filled: a host that exists ONLY in the JSON shows up as a device row."""
    d = cfg_home("remote")
    marker = "hs-t6-cfghost"
    write_cfg(d, json.dumps({"theme": "gruvbox-dark", "remotes": [marker]}))
    # No fixture env at all: the ONLY way this host can appear is the config.
    env = env_for(d)
    for k in ("HERDR_SESSION_TEST_REMOTE", "HERDR_SESSION_TEST_REMOTE_ALIAS",
              "HERDR_SESSION_TEST_UNREACHABLE"):
        env.pop(k, None)
    p = Pty(["tui"], env=env, rows=40, cols=120)
    try:
        assert p.wait_screen("herdr-session", 6)
        # wait for the ssh attempt to fail (it is not a real host) — the DEVICE
        # must still be in the table, with its own status.
        seen = p.wait_screen(marker, timeout=25.0)
        check("a host named ONLY in the JSON appears in the app",
              seen is not None, "first seen at t={:.2f}s".format(seen or -1))
        txt = p.screen.text()
        line = [l for l in txt.splitlines() if marker in l]
        check("…as its own device row/status entry (not merged into local)",
              len(line) >= 1, repr(line[0][:120]) if line else "<none>")
        check("…local is still present and separate",
              re.search(r"\blocal\b", txt) is not None, "local row intact")
        # And it went DOWN rather than silently vanishing: the footer carries a
        # per-host verdict for it.
        verdict = re.search(re.escape(marker) + r"\s+(\S+)", txt)
        check("…carrying a status word (so a dead host is visible, ISC-15)",
              verdict is not None and verdict.group(1) in
              ("pending", "ok", "timeout", "down", "no-herdr", "auth", "failed"),
              verdict.group(0) if verdict else "<no status word>")
        check("…config file untouched by the app in this scenario",
              json.loads(read_cfg(d)).get("theme") == "gruvbox-dark", read_cfg(d))
    finally:
        p.kill()
        p.close()


SCENARIOS = {
    "picker-preselect": scenario_picker_preselect,
    "apply-persist": scenario_apply_persist,
    "corrupt-warning": scenario_corrupt_warning,
    "unknown-theme": scenario_unknown_theme,
    "sgr-truecolour": scenario_sgr_truecolour,
    "black-is-black": scenario_black_is_black,
    "remote-from-config": scenario_remote_from_config,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in SCENARIOS:
        print("usage: theme_drive.py <{}>".format("|".join(sorted(SCENARIOS))))
        return 2
    name = sys.argv[1]
    print("-- t6 scenario: {}   (BIN={})".format(name, os.environ.get("BIN")))
    SCENARIOS[name]()
    bad = [r for r in results if not r[0]]
    print("-- t6 scenario {} -> {} PASS / {} FAIL".format(
        name, len(results) - len(bad), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
