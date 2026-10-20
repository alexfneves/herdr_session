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

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$(dirname "$0")/.."

BIN="${BIN:-/tmp/hs-local}"

# Refuse to certify a stale binary: a previous build under this path would
# otherwise print as current evidence (see dev/lib.sh).
require_fresh_bin "$BIN" src
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
OUT="${1:-/tmp/hs-resize}"
rm -rf "$OUT"; mkdir -p "$OUT"
LOG=/tmp/hs-resize-smoke.log
: >"$LOG"

for rep in $(seq 1 "$REPS"); do
	for scen in resize-no-key flood too-small eintr-safe selection-shrink; do
		# ONE log file per scenario: the tally must see exactly this scenario's
		# verdict lines, so they are never concatenated into a shared file where a
		# later scenario could inherit an earlier one's PASSes.
		slog="$OUT/rep${rep}-${scen}.log"
		timeout 180 python3 dev/resize_drive.py "$scen" >"$slog" 2>&1
		rc=$?
		out=$(cat "$slog")
		printf '\n===== %s (rep %s) =====\n%s\n' "$scen" "$rep" "$out" >>"$LOG"
		# The driver's own verdict decides, not a count of accumulated PASS lines.
		# A run that printed NOTHING used to land in the `fail -eq 0` branch and
		# read as a pass with zero checks behind it; classify_log names that case
		# EMPTY and tally counts it as a failure.
		case_result=$(classify_log "$slog")
		pass=$(printf '%s' "$out" | grep -c '\[PASS\]')
		fail=$(printf '%s' "$out" | grep -c '\[FAIL\]')
		skipped=$(printf '%s' "$out" | grep -c '\[SKIP\]')
		# Surface the coalescing ledger regardless of verdict — these lines are
		# the evidence, not decoration.
		ledger=$(printf '%s' "$out" | grep -E '^\s*(trace:|drag wall)' | tr -d '\n')
		tally "$scen (rep $rep)" "$slog" || true
		case "$case_result" in
		PASS)
			RESULTS+=("PASS $scen ($pass checks) $ledger")
			;;
		SKIP)
			# Explicitly skipped by the driver (fixture not armed). NOT a pass.
			RESULTS+=("SKIP $scen ($skipped skip reason(s), 0 checks) — fixture not armed")
			;;
		EMPTY)
			# The driver produced no verdict line at all: a crash, a traceback, or a
			# binary that does not implement the scenario. Recorded as a FAILURE.
			RESULTS+=("FAIL $scen (EMPTY — no verdict line, driver rc=$rc) $ledger")
			overall=1
			;;
		*)
			RESULTS+=("FAIL $scen ($pass pass / $fail fail, driver rc=$rc) $ledger")
			overall=1
			printf '%s\n' "$out" | grep '\[FAIL\]' | sed 's/^/    /'
			;;
		esac
		assert_formatted "$scen (rep $rep)" "$slog" || true
	done
done

printf '\n──────────────── resize smoke (T6.5) ────────────────\n'
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
green=0
for r in "${RESULTS[@]}"; do [[ "$r" == PASS* ]] && green=$((green + 1)); done
skips=0
for r in "${RESULTS[@]}"; do [[ "$r" == SKIP* ]] && skips=$((skips + 1)); done
printf '  %d/%d runs green, %d skipped — full log: %s\n' \
	"$green" "${#RESULTS[@]}" "$skips" "$LOG"
smoke_verdict "RESIZE"
