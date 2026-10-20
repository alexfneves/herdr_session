#!/usr/bin/env bash
# dev/tui-smoke.sh — evidence runner for T5.5: the real TUI, in a real terminal.
#
# Everything before this phase could be proven by calling a function and reading
# what it returned. That stops being true the moment the program owns a terminal:
# the claims are about BYTES, TIMING and THE STATE OF THE TTY, and each one needs
# an outside observer. So this script drives dev/tui_drive.py, which holds a pty
# end-to-end (including the slave, which is how the terminal's own termios gets
# read back after the app dies), and keeps the transcript.
#
#   BIN=/tmp/hs-local ./dev/tui-smoke.sh [outdir]      # default /tmp/hs-tui
#
# Fixture: HERDR_SESSION_TEST_REMOTE (+ _ALIAS for the device discriminator, +
# _UNREACHABLE for the dead-host bound). Same three variables T4's live driver
# uses; nothing in src/ names a host. Unarmed, the remote scenarios say so and
# the local ones still run.
#
# CLEANUP: the EXIT trap removes every `hs-t-*` session the run created and then
# PROVES the session list is back where it started. The session hosting the agent
# is never a target.
#
# Dev-only: nix/package.nix ships src/ and vendor/, so none of this reaches the
# package and the whole file can be deleted in one action.
set -uo pipefail

BIN="${BIN:-/tmp/hs-local}"
OUT="${1:-/tmp/hs-tui}"
rm -rf "$OUT"; mkdir -p "$OUT"

PY="python3 $(cd "$(dirname "$0")" && pwd)/tui_drive.py"
export BIN

herdr_cli() { env -u HERDR_ENV -u HERDR_SESSION -u HERDR_SOCKET_PATH herdr "$@"; }
session_names() {
	herdr_cli session list --json 2>/dev/null \
		| python3 -c 'import json,sys; print(",".join(sorted(s["name"] for s in json.load(sys.stdin)["sessions"])))' 2>/dev/null
}

BEFORE="$(session_names)"
echo "== pre-run session list: ${BEFORE}"

cleanup_scratch() {
	local rc=$?
	for n in $(session_names); do
		case "$n" in
		hs-t-*)
			herdr_cli session stop --json "$n"  >/dev/null 2>&1 || true
			herdr_cli session delete --json "$n" >/dev/null 2>&1 || true
			;;
		esac
	done
	local after; after="$(session_names)"
	echo
	echo "== post-cleanup session list: ${after}"
	if [ "${after}" = "${BEFORE}" ]; then
		echo "   [PASS] teardown restored the pre-run session list exactly"
	else
		echo "   [FAIL] session list drifted: ${BEFORE} -> ${after}"
	fi
	return $rc
}
trap cleanup_scratch EXIT INT TERM

PASS_TOTAL=0
FAIL_TOTAL=0

# run_scenario NAME [needs_fixture] — one spawn per scenario, so a hang in one
# cannot hide the others' results.
run_scenario() {
	local name="$1" need_fixture="${2:-no}" log="$OUT/$1.log"
	echo
	echo "────────────────────────────────────────────────────────────────────────"
	echo " scenario: $name"
	echo "────────────────────────────────────────────────────────────────────────"
	if [ "$need_fixture" = "fixture" ] && [ -z "${HERDR_SESSION_TEST_REMOTE:-}" ]; then
		echo "    SKIPPED — HERDR_SESSION_TEST_REMOTE is unset, and this scenario is"
		echo "    the only proof it covers. Arm the fixture (dev/test-remote.md) to run it."
		return
	fi
	$PY "$name" > "$log" 2>&1
	local rc=$?
	grep -aE '\[(PASS|FAIL)\]|timeline|teardown|footer|    ' "$log" | sed 's/^/    /'
	local badfmt; badfmt=$(grep -ac '%!' "$log" 2>/dev/null || true)
	if [ "${badfmt:-0}" != "0" ]; then
		echo "    [FAIL] printf fallout in the scenario output (%! …) — a wrong format"
		echo "           string still prints a plausible LINE with wrong NUMBERS, which is"
		echo "           the worst thing a timing claim can do."
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
		grep -a '%!' "$log" | head -3 | sed 's/^/      /'
		return
	fi
	local p f
	p=$(grep -ac '\[PASS\]' "$log" || true)
	f=$(grep -ac '\[FAIL\]' "$log" || true)
	PASS_TOTAL=$((PASS_TOTAL + p))
	FAIL_TOTAL=$((FAIL_TOTAL + f))
	printf '\n== %s: %s PASS / %s FAIL (driver rc=%s)\n' "$name" "$p" "$f" "$rc"
}

# The seven states, each with its own Ctrl+C proof.
# Guard proofs: a returned boolean is not evidence. A guard that says NO must
# also be shown to have spawned NOTHING — `waitpid(-1, WNOHANG)` returning
# ECHILD in the same process is that proof, which is why these run as in-process
# cases rather than as screen observations.
run_guards() {
	local name
	for name in "guard-attach local hs-t-does-not-exist-99" \
		"guard-attach local default" \
		"guard-delete local hs-t-never-created-77"; do
		echo
		echo "────────────────────────────────────────────────────────────────────────"
		echo " guard: $name"
		echo "────────────────────────────────────────────────────────────────────────"
		$BIN $name > "$OUT/guard-$(echo "$name" | tr ' ' '_').log" 2>&1
		grep -aE 'ok=|refused|no child|would create|D12|nothing was deleted|ECHILD|spawned' \
			"$OUT/guard-$(echo "$name" | tr ' ' '_').log" | sed 's/^/    /'
		local p f
		p=$(grep -acE '\[PASS\]' "$OUT/guard-$(echo "$name" | tr ' ' '_').log" || true)
		f=$(grep -acE '\[FAIL\]' "$OUT/guard-$(echo "$name" | tr ' ' '_').log" || true)
		PASS_TOTAL=$((PASS_TOTAL + p))
		FAIL_TOTAL=$((FAIL_TOTAL + f))
		printf '\n== guard %s: %s PASS / %s FAIL\n' "$name" "$p" "$f"
	done
}

run_scenario boot-local
run_scenario sigterm
run_scenario no-orphan
run_scenario state-mode_selection
run_scenario state-name_local
run_scenario state-remote_server
run_scenario state-name_remote_named
run_scenario state-attach
run_scenario state-delete_session
run_scenario state-theme
run_scenario state-error
run_scenario boot-remote fixture
run_scenario roundtrip fixture
run_scenario refresh-key
run_scenario delete-notice
run_guards

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf ' T5.5 TUI smoke: %s PASS / %s FAIL\n' "$PASS_TOTAL" "$FAIL_TOTAL"
if [ -n "${HERDR_SESSION_TEST_REMOTE:-}" ]; then
	echo " fixture: armed (remote=${HERDR_SESSION_TEST_REMOTE} unreachable=${HERDR_SESSION_TEST_UNREACHABLE:-192.0.2.201})"
else
	echo " fixture: UNARMED — the remote/dead-host/round-trip proofs above were skipped"
fi
echo "════════════════════════════════════════════════════════════════════════════"
[ "$FAIL_TOTAL" = "0" ]
