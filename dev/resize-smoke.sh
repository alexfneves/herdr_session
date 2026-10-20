#!/usr/bin/env bash
# T6.5 resize smoke: coalescing, "too small", recovery and EINTR safety, all
# driven through a REAL pty with REAL TIOCSWINSZ.
#
# Why a separate suite from dev/ui-smoke.sh: `ui-shrink` proves the one thing
# that suite can — that a selection stays valid when the usable row count drops.
# The rest of T6.5 needs the app's own poll loop running, with resize events
# arriving at the rate a window manager sends them, and needs counters read out
# of the process that produced them. That is dev/resize_drive.py's job.
#
#   ./dev/resize-smoke.sh
#   BIN=/path/to/herdr-session ./dev/resize-smoke.sh
#   REPS=5 ./dev/resize-smoke.sh     # repeat the set (timing is not deterministic)
set -uo pipefail

cd "$(dirname "$0")/.."

BIN="${BIN:-/tmp/hs-local}"
REPS="${REPS:-3}"

if [[ ! -x "$BIN" ]]; then
	printf 'no binary at %s — run ./dev/local-build.sh first\n' "$BIN" >&2
	exit 2
fi
export BIN

# The too-small and coalescing cases run without the fixture (fewer moving
# parts); selection-shrink needs the remote pair, so export it if the caller
# provided it and let that one scenario skip itself otherwise.
export HERDR_SESSION_TEST_REMOTE="${HERDR_SESSION_TEST_REMOTE:-}"
export HERDR_SESSION_TEST_REMOTE_ALIAS="${HERDR_SESSION_TEST_REMOTE_ALIAS:-}"

overall=0
declare -a RESULTS=()
: >/tmp/hs-resize-smoke.log

for _ in $(seq 1 "$REPS"); do
	for scen in resize-no-key flood too-small eintr-safe selection-shrink; do
		if out=$(timeout 180 python3 dev/resize_drive.py "$scen" 2>&1); then
			rc=0
		else
			rc=$?
		fi
		printf '\n===== %s =====\n%s\n' "$scen" "$out" >>/tmp/hs-resize-smoke.log
		pass=$(printf '%s' "$out" | grep -c '\[PASS\]')
		fail=$(printf '%s' "$out" | grep -c '\[FAIL\]')
		# Surface the coalescing ledger regardless of pass/fail — these lines are
		# the evidence, not decoration.
		ledger=$(printf '%s' "$out" | grep -E '^\s*(trace:|drag wall)' | tr -d '\n')
		if [[ $rc -eq 0 && $fail -eq 0 ]]; then
			RESULTS+=("PASS $scen ($pass checks) $ledger")
		else
			overall=1
			RESULTS+=("FAIL $scen ($pass pass / $fail fail) $ledger")
			printf '%s\n' "$out" | grep '\[FAIL\]' | sed 's/^/    /'
		fi
	done
done

printf '\n──────────────── resize smoke (T6.5) ────────────────\n'
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
green=0
for r in "${RESULTS[@]}"; do [[ "$r" == PASS* ]] && green=$((green + 1)); done
printf '  %d/%d runs green — full log: /tmp/hs-resize-smoke.log\n' "$green" "${#RESULTS[@]}"
exit $overall
