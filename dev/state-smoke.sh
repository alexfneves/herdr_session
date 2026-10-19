#!/usr/bin/env bash
# dev/state-smoke.sh — evidence runner for T5.4, the state machine.
#
#   BIN=./result/bin/herdr-session ./dev/state-smoke.sh [outdir]
#   BIN=/tmp/hs-local            ./dev/state-smoke.sh     # default
#
# Why this needs NO pty, while the UI suites do: `update(app, key) -> Command`
# performs no side effects, so the whole transition table is verifiable with no
# terminal, no herdr and no network in sight. The absence of those is not a gap
# in the test, it IS one of the things under test — see section 2 (the same
# battery, run with an EMPTY environment and a PATH that contains nothing) and
# section 3 (the no-side-effect surface of the source itself).
#
# Sections
#   1/4  state-machine  every rule + the printed (state x key) transition matrix
#   2/4  state-offline  the battery again, under `env -i PATH=/nonexistent`
#   3/4  source-surface  greps: what state.odin does NOT import, cannot do
#   4/4  safety         the real herdr session list, before and after
set -uo pipefail

cd "$(dirname "$0")/.."

BIN="${BIN:-/tmp/hs-local}"
OUT="${1:-/tmp/hs-state}"
rm -rf "$OUT"; mkdir -p "$OUT"

if [[ ! -x "$BIN" ]]; then
	printf 'no binary at %s — run `nix build .` (BIN=./result/bin/herdr-session) or ./dev/local-build.sh\n' "$BIN" >&2
	exit 2
fi

PASS_TOTAL=0
FAIL_TOTAL=0

# tally LABEL LOG — mirrors dev/app-smoke.sh: a log with zero [PASS] lines is a
# FAILURE, not a pass. A suite that silently ran nothing must never go green.
tally() {
	local label="$1" log="$2" p f
	if [ ! -f "$log" ]; then
		printf '\n== %s: NO LOG (treated as FAIL)\n' "$label"
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
		return
	fi
	p=$(grep -ac '\[PASS\]' "$log" || true)
	f=$(grep -ac '\[FAIL\]' "$log" || true)
	if [ "$p" = "0" ] && [ "$f" = "0" ]; then
		printf '\n== %s: 0 PASS / 0 FAIL — nothing ran (treated as FAIL)\n' "$label"
		printf '    the binary probably has no such case. head of its log:\n'
		head -3 "$log" | sed 's/^/      /'
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
		return
	fi
	PASS_TOTAL=$((PASS_TOTAL + p))
	FAIL_TOTAL=$((FAIL_TOTAL + f))
	printf '\n== %s: %s PASS / %s FAIL\n' "$label" "$p" "$f"
}

# assert_formatted — no Odin/Go printf fallout (%!, %!(NO VERB)) in the evidence.
assert_formatted() {
	local label="$1" log="$2" bad
	bad=$(grep -ac '%!' "$log" 2>/dev/null || true)
	if [ "${bad:-0}" = "0" ]; then
		printf '    [PASS] %s — no printf format fallout\n' "$label"
		PASS_TOTAL=$((PASS_TOTAL + 1))
	else
		printf '    [FAIL] %s — %s malformed format expansion(s)\n' "$label" "$bad"
		grep -a '%!' "$log" 2>/dev/null | head -3 | sed 's/^/      /'
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
	fi
}

# ---------------------------------------------------------------------------
# 1. the full machine
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 1/4  state-machine — every rule + the transition matrix"
echo "────────────────────────────────────────────────────────────────────────"
"$BIN" state-machine > "$OUT/state-machine.log" 2>&1
echo "    driver exit code: $?"
# The matrix itself is printed verbatim into the transcript — it is the
# reachability evidence (ISC-3), not a summary of it.
sed -n '/full (state x key) grid/,/spec assertions/p' "$OUT/state-machine.log" | sed 's/^/    /'
grep -aE '\[(PASS|FAIL)\]|=== RESULT' "$OUT/state-machine.log" | sed 's/^/    /'
assert_formatted "state-machine" "$OUT/state-machine.log"
	tally "state-machine" "$OUT/state-machine.log"

# ---------------------------------------------------------------------------
# 2. the same battery, with NO environment and NO herdr reachable
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 2/4  state-offline — no env, no PATH, no herdr binary anywhere"
echo "────────────────────────────────────────────────────────────────────────"
printf '    which herdr BEFORE: %s\n' "$(command -v herdr || echo '(none)')"
env -i PATH=/nonexistent HERDR_ENV=1 HERDR_SESSION=2026-08-11-23-37-41-812 \
	"$BIN" state-offline > "$OUT/state-offline.log" 2>&1
echo "    driver exit code: $?"
grep -aE '\[PASS\] no child|\[FAIL\]|=== RESULT|env variables visible' "$OUT/state-offline.log" | sed 's/^/    /'
assert_formatted "state-offline" "$OUT/state-offline.log"
	tally "state-offline" "$OUT/state-offline.log"

# ---------------------------------------------------------------------------
# 3. the side-effect surface, read off the source
# ---------------------------------------------------------------------------
#
# The runtime proof above says "this run created no children". These greps say
# WHY it could not: the machine's import list has nothing that could create one,
# write a file, open a socket or touch a terminal.
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 3/4  source surface — what the state machine cannot reach"
echo "────────────────────────────────────────────────────────────────────────"
STATE_SRC="src/app/state.odin"
KEYMAP_SRC="src/input/keymap.odin"

grep_absent() {
	# Comments are STRIPPED before matching: the machine's own doc comments talk
	# about spawning, forking and reading all day long, and matching them would
	# flag the prose instead of the code.
	local label="$1" pattern="$2" file="$3" hits
	hits=$(sed 's,//.*,,' "$file" 2>/dev/null | grep -c "$pattern" || true)
	if [ "${hits:-0}" = "0" ]; then
		printf '    [PASS] %s\n' "$label"; PASS_TOTAL=$((PASS_TOTAL + 1))
	else
		printf '    [FAIL] %s — %s hit(s)\n' "$label" "$hits"
		sed 's,//.*,,' "$file" 2>/dev/null | grep -n "$pattern" | head -4 | sed 's/^/         /'
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
	fi
}

printf '\n    %s imports:\n' "$STATE_SRC"
grep -n '^import' "$STATE_SRC" | sed 's/^/      /'
printf '\n    %s imports:\n' "$KEYMAP_SRC"
grep -n '^import' "$KEYMAP_SRC" | sed 's/^/      /'
echo

grep_absent "no os module (no files, no env, no process) in state.odin" 'core:os' "$STATE_SRC"
grep_absent "no posix (no fork/exec/pipe/signal) in state.odin" 'core:sys/posix' "$STATE_SRC"
grep_absent "no net (no sockets) in state.odin" 'core:net' "$STATE_SRC"
grep_absent "no terminal module in state.odin" 'terminal' "$STATE_SRC"
grep_absent "no clay/termbox in state.odin (it never paints)" 'clay\|termbox' "$STATE_SRC"
grep_absent "no time module / sleep / event peek in state.odin => no Escape timeout exists (ISC-11)" 'core:time\|time\.\|sleep\|peek_event' "$STATE_SRC"
grep_absent "no exec/fork/spawn/system call in state.odin" 'execv\|fork(\|spawn(\|system(' "$STATE_SRC"
grep_absent "no union for Command — decision O10's tagged struct is used" 'union {' "$STATE_SRC"
grep_absent "no Kitty keyboard protocol in the keymap (ISC-A-4)" 'kitty\|\[>1u\|\[u' "$KEYMAP_SRC"
grep_absent "no fixture host names in the keymap (ISC-A-3)" 'localhost\|127\.0\.0\.1' "$KEYMAP_SRC"
grep_absent "no fixture host names in state.odin (ISC-A-3)" 'localhost\|127\.0\.0\.1' "$STATE_SRC"

# The machine must not reach the outside world under any alias.
grep_absent "no os./posix./net./open()/read()/write() call shape in state.odin" \
	'os\.\|posix\.\|net\.\|open(\|read(\|write(' "$STATE_SRC"

# ISC-A-3 across the whole of src/, including the new driver and keymap.
hits=$(grep -rn 'localhost' src/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$hits" = "0" ]; then
	printf '    [PASS] grep -rn localhost src/ is empty (ISC-A-3)\n'
	PASS_TOTAL=$((PASS_TOTAL + 1))
else
	printf '    [FAIL] `localhost` appears %s time(s) in src/\n' "$hits"
	grep -rn 'localhost' src/ 2>/dev/null | head -4 | sed 's/^/         /'
	FAIL_TOTAL=$((FAIL_TOTAL + 1))
fi

# ---------------------------------------------------------------------------
# 4. safety — the real herdr session list must be exactly as found
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 4/4  safety — the real herdr session list is untouched"
echo "────────────────────────────────────────────────────────────────────────"
herdr_cli() { env -u HERDR_ENV -u HERDR_SESSION -u HERDR_SOCKET_PATH herdr "$@"; }
session_names() {
	herdr_cli session list --json 2>/dev/null \
		| python3 -c 'import json,sys; print(",".join(sorted(s["name"] for s in json.load(sys.stdin)["sessions"])))' 2>/dev/null
}
if ! command -v herdr >/dev/null 2>&1; then
	printf '    NOTE: no herdr on PATH — nothing COULD have been touched. Skipped.\n'
else
	BEFORE="$(session_names)"
	printf '    before: %s\n' "${BEFORE}"
	# Re-run the battery once more and compare: the machine is under test for
	# having NO effect on the real session list, not just for returning cleanly.
	"$BIN" state-machine >/dev/null 2>&1 || true
	AFTER="$(session_names)"
	printf '    after:  %s\n' "${AFTER}"
	if [ "${BEFORE}" = "${AFTER}" ]; then
		printf '    [PASS] the herdr session list is byte-identical after the run\n'
		PASS_TOTAL=$((PASS_TOTAL + 1))
	else
		printf '    [FAIL] the session list changed: %s -> %s\n' "${BEFORE}" "${AFTER}"
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
	fi
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo
echo "════════════════════════════════════════════════════════════════════════"
printf ' T5.4 STATE-MACHINE TOTAL: %s PASS / %s FAIL\n' "$PASS_TOTAL" "$FAIL_TOTAL"
if [ "$FAIL_TOTAL" = "0" ]; then
	echo " RESULT: PASS"
else
	echo " RESULT: FAIL"
	trap - EXIT
	exit 1
fi
