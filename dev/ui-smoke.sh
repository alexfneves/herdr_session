#!/usr/bin/env bash
# Phase 5a UI smoke: runs each UI case inside a REAL pty and greps its PASS/FAIL
# report. Terminal behaviour (resize delivery, key decoding, wide-rune cells,
# alternate screen, handoff) cannot be verified without one.
#
#   CASES="ui-frame ui-sessions ui-edit" ./dev/ui-smoke.sh
set -uo pipefail

cd "$(dirname "$0")/.."

BIN="${BIN:-/tmp/hs-local}"
REPORT="${REPORT:-/tmp/hs-ui-smoke.log}"
CASES="${CASES:-ui-frame ui-sessions ui-shrink ui-edit ui-list ui-float}"

# Input piped into each case's pty. termbox decodes it into real tb_events, so
# UTF-8, escape sequences and control bytes arrive exactly as a user would send
# them.
input_for() {
	case "$1" in
	ui-sessions) printf 'api' ;;
	ui-edit)     printf 'a世b😀c' ;;
	ui-list)     printf '\033[B\033[B\tto' ;;
	ui-float)    printf '\r' ;;
	*)           printf '' ;;
	esac
}

if [[ ! -x "$BIN" ]]; then
	printf 'no binary at %s — run ./dev/local-build.sh first\n' "$BIN" >&2
	exit 2
fi

: >"$REPORT"
overall=0
declare -a RESULTS=()

for case_name in $CASES; do
	# The keystrokes are delayed one second on purpose: termbox consumes whatever
	# is already pending in the pty during tb_init (terminal identification
	# responses), so input written at t=0 gets eaten before the app starts
	# reading. This is the same trick dev/handoff-smoke.sh uses.
	out=$( { sleep 1; input_for "$case_name"; } | timeout 40 script -q -e -c \
		"stty rows 40 cols 120; $BIN $case_name" \
		"/tmp/hs-ui-$case_name.typescript" 2>&1)
	printf '\n===== %s =====\n%s\n' "$case_name" "$out" >>"$REPORT"

	# A case prints one [PASS]/[FAIL] per assertion and a RESULT line at the end.
	if printf '%s' "$out" | grep -q 'RESULT: PASS' && ! printf '%s' "$out" | grep -q '\[FAIL\]'; then
		n=$(printf '%s' "$out" | grep -c '\[PASS\]')
		RESULTS+=("PASS $case_name ($n checks)")
	else
		overall=1
		n=$(printf '%s' "$out" | grep -c '\[FAIL\]')
		RESULTS+=("FAIL $case_name ($n failed checks)")
		printf '%s\n' "$out" | grep '\[FAIL\]' | sed 's/^/    /'
	fi
done

printf '\n──────────────── ui smoke ────────────────\n'
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
total_pass=0
for r in "${RESULTS[@]}"; do [[ "$r" == PASS* ]] && total_pass=$((total_pass + 1)); done
printf '  %d/%d cases green — full log: %s\n' "$total_pass" "${#RESULTS[@]}" "$REPORT"
exit $overall
