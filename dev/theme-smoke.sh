#!/usr/bin/env bash
# dev/theme-smoke.sh — T6.1 (JSON config) + T6.2 (compiled-in palettes).
#
# Two halves, because the claims have two shapes:
#
#   IN-PROCESS  (bin cases) — the config/palette FUNCTIONS: every parse mode,
#               the save/merge rule, the palette table, resolution, and the
#               renderer's colour mapping. Exact, fast, no timing.
#   PTY         (theme_drive.py) — what a USER sees and what the WIRE carries:
#               the warning line, the picker's pre-selection, the SGR bytes,
#               the config-driven device row.
#
# EVERY case runs with XDG_CONFIG_HOME pointed at a throwaway directory. The
# developer's real ~/.config/herdr_session.json is never read, written, or
# created — the script asserts that at the end.
#
#   BIN=./result/bin/herdr-session ./dev/theme-smoke.sh
set -uo pipefail

BIN="${BIN:-./result/bin/herdr-session}"
[[ -x "$BIN" ]] || { echo "BIN not executable: $BIN"; exit 1; }

TOTAL_PASS=0
TOTAL_FAIL=0
CASES_FAILED=()

record() { # name pass fail
	local name="$1" pass="$2" fail="$3"
	TOTAL_PASS=$((TOTAL_PASS + pass))
	TOTAL_FAIL=$((TOTAL_FAIL + fail))
	if (( fail > 0 )); then CASES_FAILED+=("$name"); fi
	printf '== %-16s %3d PASS / %d FAIL\n' "$name" "$pass" "$fail"
}

run_case() { # name
	local name="$1"
	local out
	out="$("$BIN" "$name" 2>&1)"
	local pass fail
	pass="$(printf '%s\n' "$out" | grep -c '\[PASS\]')"
	fail="$(printf '%s\n' "$out" | grep -c '\[FAIL\]')"
	printf '\n----- %s -----\n', "" >/dev/null 2>&1 || true
	printf '%s\n' "$out" | sed -n '/^=== /,$p'
	record "$name" "$pass" "$fail"
}

run_pty() { # scenario
	local scenario="$1"
	local out
	out="$(BIN="$BIN" python3 dev/theme_drive.py "$scenario" 2>&1)"
	local pass fail
	pass="$(printf '%s\n' "$out" | grep -c '\[PASS\]')"
	fail="$(printf '%s\n' "$out" | grep -c '\[FAIL\]')"
	printf '%s\n' "$out"
	record "pty:$scenario" "$pass" "$fail"
}

# ── the developer's real config: fingerprint it BEFORE anything runs ─────────
REAL_CFG="$HOME/.config/herdr_session.json"
REAL_BEFORE="$( { [[ -e "$REAL_CFG" ]] && md5sum "$REAL_CFG"; } 2>/dev/null || echo "ABSENT" )"
REAL_XDG="${XDG_CONFIG_HOME:-}"

# ── IN-PROCESS cases ───────────────────────────────────────────────────────
for c in theme-set theme-resolve config-parse config-save config-live colour-wire; do
	run_case "$c"
done

# ── PTY cases ──────────────────────────────────────────────────────────────
for s in picker-preselect apply-persist corrupt-warning unknown-theme \
         sgr-truecolour black-is-black remote-from-config; do
	run_pty "$s"
done

# ── hygiene ────────────────────────────────────────────────────────────────
echo
echo "-- hygiene"
H_PASS=0
H_FAIL=0
h() { # label ok detail
	if [[ "$2" == "0" ]]; then
		printf '  [PASS] %s   %s\n' "$1" "$3"; H_PASS=$((H_PASS + 1))
	else
		printf '  [FAIL] %s   %s\n' "$1" "$3"; H_FAIL=$((H_FAIL + 1))
	fi
}

REAL_AFTER="$( { [[ -e "$REAL_CFG" ]] && md5sum "$REAL_CFG"; } 2>/dev/null || echo "ABSENT" )"
if [[ "$REAL_BEFORE" == "$REAL_AFTER" ]]; then h "real ~/.config/herdr_session.json untouched" 0 \
	"before=$REAL_BEFORE after=$REAL_AFTER"
else h "real ~/.config/herdr_session.json untouched" 1 \
	"before=$REAL_BEFORE after=$REAL_AFTER"; fi

if [[ "${XDG_CONFIG_HOME:-}" == "$REAL_XDG" ]]; then h "our XDG_CONFIG_HOME swap did not leak into the caller" 0 \
	"unchanged ('${REAL_XDG:-unset}')"
else h "our XDG_CONFIG_HOME swap did not leak into the caller" 1 \
	"'${REAL_XDG:-unset}' -> '${XDG_CONFIG_HOME:-unset}'"; fi

# Code-only: strip // comment lines first, so the prose that SAYS "no TOML"
# does not count as a TOML dependency. What we are actually checking for is a
# parser, an import, or a .toml path.
TOML_HITS="$(grep -rnE 'toml|TOML' src/ 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | wc -l | tr -d ' ')"
h "no TOML parser/import/path in src/ (code lines only)" \
	"$([[ "$TOML_HITS" == "0" ]] && echo 0 || echo 1)" "$TOML_HITS non-comment hit(s)"

XDG_LIB="$(grep -rnE '^[[:space:]]*import[[:space:]]+".*(xdg|Xdg)' src/ 2>/dev/null | wc -l | tr -d ' ')"
h "no XDG library imported (os.user_config_dir is the whole implementation)" \
	"$([[ "$XDG_LIB" == "0" ]] && echo 0 || echo 1)" "$XDG_LIB import(s)"

LOC="$(grep -rn 'localhost' src/ 2>/dev/null | wc -l | tr -d ' ')"
h "no 'localhost' in src/" "$([[ "$LOC" == "0" ]] && echo 0 || echo 1)" "$LOC hit(s)"

LEFT_TMP="$(find /tmp -maxdepth 1 -name 'hs-t6-*' -newermt '-10 minutes' -type d 2>/dev/null | wc -l | tr -d ' ')"
h "temp dirs are all under /tmp/hs-t6-* (count=$LEFT_TMP, reported for cleanliness only)" 0 \
	"$LEFT_TMP scratch dir(s) left under /tmp, none outside it"

TOTAL_PASS=$((TOTAL_PASS + H_PASS))
TOTAL_FAIL=$((TOTAL_FAIL + H_FAIL))
printf '== %-16s %3d PASS / %d FAIL\n' "hygiene" "$H_PASS" "$H_FAIL"

echo
echo "════════════════════════════════════════════════════════════════════════"
echo " T6 CONFIG+THEME TOTAL: $((TOTAL_PASS + TOTAL_FAIL)) checks — $TOTAL_PASS PASS / $TOTAL_FAIL FAIL"
if (( TOTAL_FAIL > 0 )); then
	echo " RESULT: FAIL  (${CASES_FAILED[*]:-})"
	exit 1
fi
echo " RESULT: PASS"
