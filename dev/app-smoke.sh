#!/usr/bin/env bash
# dev/app-smoke.sh — evidence runner for Phase 3 (T3.1 choke point, T3.2
# timestamp-from-name, T3.3 local list -> model, T3.4 remote discovery).
#
# Why a shell runner at all, when there is no UI yet: the rules in Phase 3 are
# about what the *child process* sees and what herdr *answers*. That evidence has
# to come from real invocations with the raw bytes preserved, not from an
# assertion that a function returned true. So the driver prints its own PASS/FAIL
# lines plus the captured stdout/stderr of every real command, and this script
# keeps the transcript and the tally.
#
#   BIN=./result/bin/herdr-session ./dev/app-smoke.sh [outdir]
#   BIN=/tmp/hs                ./dev/app-smoke.sh      # outdir default /tmp/hs-app
#
# Fixture: the ONLY way a remote host enters this script is
# HERDR_SESSION_TEST_REMOTE (+ _ALIAS for the device-discriminator pair). Nothing
# in src/ names a host, and unsetting the variables leaves remote support intact
# and simply skips the remote checks.
#
# CLEANUP: the EXIT trap tears down every `hs-t-*` session this run created, even
# on failure, Ctrl-C, or a kill, and then PROVES the session list is back to its
# pre-run state. The session hosting the agent is never a target.
#
# Dev-only: nix/package.nix ships src/ and vendor/ only, so this file never
# reaches the package and can be deleted in one action.
set -uo pipefail

BIN="${BIN:-/tmp/hs}"

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# A previous build under this path would otherwise print as current evidence.
require_fresh_bin "$BIN" src
OUT="${1:-/tmp/hs-app}"
rm -rf "$OUT"; mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# Pre-run state + guaranteed teardown
# ---------------------------------------------------------------------------

herdr_cli() { env -u HERDR_ENV -u HERDR_SESSION -u HERDR_SOCKET_PATH herdr "$@"; }

session_names() {
	herdr_cli session list --json 2>/dev/null \
		| python3 -c 'import json,sys; print(",".join(sorted(s["name"] for s in json.load(sys.stdin)["sessions"])))' 2>/dev/null
}

BEFORE="$(session_names)"
echo "== pre-run session list: ${BEFORE}"

cleanup_scratch() {
	local rc=$?
	# Stop then delete every scratch session this run could have created. Names are
	# fixed and prefixed, so the teardown cannot reach anything it should not.
	for name in hs-t-phase3-probe hs-t-never-created-zz hs-t-verbatim-check; do
		herdr_cli session stop --json "$name"  >/dev/null 2>&1 || true
		herdr_cli session delete --json "$name" >/dev/null 2>&1 || true
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

# assert_formatted LABEL LOG — fail if the log contains Go/Odin printf fallout
# (`%!`, `%!f(int=0)`, `%!d(MISSING)` …). A mistyped format string otherwise
# produces a plausible-looking line whose NUMBERS are wrong or absent, which is
# the worst possible failure mode for a timing claim: the check still passes, the
# evidence beside it is garbage. Caught exactly that here — a wall-time line was
# printing the pending count into a `{:.0f}` slot.
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

# tally LABEL LOG — count the driver's own PASS/FAIL lines into the total.
#
# A log with zero [PASS] lines is a FAILURE, not a pass. Without this rule a
# wrong/stale $BIN silently fell through to the driver's default case and every
# section reported "0 PASS / 0 FAIL" while the run still went green — a harness
# that cannot tell "everything passed" from "nothing ran" is worse than none.
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

# ---------------------------------------------------------------------------
# 1. Unit layer — no subprocess against herdr, runs anywhere
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 1/4  app-unit — model, validation, exit-code contract (no subprocess)"
echo "────────────────────────────────────────────────────────────────────────"
"$BIN" app-unit > "$OUT/app-unit.log" 2>&1
echo "    driver exit code: $?"
grep -aE '\[(PASS|FAIL)\]|=== RESULT' "$OUT/app-unit.log" | sed 's/^/    /'
assert_formatted "app-unit" "$OUT/app-unit.log"
	tally "app-unit" "$OUT/app-unit.log"

# ---------------------------------------------------------------------------
# 2. Live layer — the real herdr binary, raw bytes preserved
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 2/4  app-live — the real herdr binary + ssh fixture"
echo "────────────────────────────────────────────────────────────────────────"
if [ -z "${HERDR_SESSION_TEST_REMOTE:-}" ]; then
	echo "    NOTE: HERDR_SESSION_TEST_REMOTE unset — the remote + discriminator"
	echo "          checks will SKIP themselves. Setting it is how the fixture gets in."
	echo "          (dev/test-remote.md is the only other place a fixture may appear.)"
fi
env HERDR_SESSION_TEST_REMOTE="${HERDR_SESSION_TEST_REMOTE:-}" \
	HERDR_SESSION_TEST_REMOTE_ALIAS="${HERDR_SESSION_TEST_REMOTE_ALIAS:-}" \
	"$BIN" app-live > "$OUT/app-live.log" 2>&1
echo "    driver exit code: $?"
grep -aE '\[(PASS|FAIL)\]|=== RESULT|raw stdout|raw stderr|  captured |→ exit|  SKIP' "$OUT/app-live.log" | sed 's/^/    /'
assert_formatted "app-live" "$OUT/app-live.log"
	tally "app-live" "$OUT/app-live.log"

# ---------------------------------------------------------------------------
# 3-4. Fetch layer — the parallel fan-out (T4.1 / T4.2)
#
# fetch-unit is offline (local `sh -c` stand-ins) so the merge / identity /
# status logic is proven even with no fixture. fetch-live needs real ssh; it is
# the only place the concurrency, timeout-bound and no-zombie claims get
# MEASURED, so its numbers are reported, not just its verdicts.
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 3/5  fetch-unit — merge identity, isolation, selection, status mapping"
echo "────────────────────────────────────────────────────────────────────────"
"$BIN" fetch-unit > "$OUT/fetch-unit.log" 2>&1
echo "    driver exit code: $?"
grep -aE '\[(PASS|FAIL)\]|=== RESULT' "$OUT/fetch-unit.log" | sed 's/^/    /'
assert_formatted "fetch-unit" "$OUT/fetch-unit.log"
	tally "fetch-unit" "$OUT/fetch-unit.log"

echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 4/5  fetch-live — real ssh children: concurrency, deadlines, no zombies"
echo "────────────────────────────────────────────────────────────────────────"
if [ -z "${HERDR_SESSION_TEST_REMOTE:-}" ]; then
	echo "    SKIPPED — HERDR_SESSION_TEST_REMOTE is unset."
	echo "    This section is the ONLY proof of concurrency, of the timeout bound"
	echo "    and of zero zombie children. Unarmed, those claims are unproven, so"
	echo "    run it armed (dev/test-remote.md)."
else
	env HERDR_SESSION_TEST_REMOTE="${HERDR_SESSION_TEST_REMOTE:-}" \
		HERDR_SESSION_TEST_REMOTE_ALIAS="${HERDR_SESSION_TEST_REMOTE_ALIAS:-}" \
		HERDR_SESSION_TEST_UNREACHABLE="${HERDR_SESSION_TEST_UNREACHABLE:-192.0.2.201}" \
		"$BIN" fetch-live > "$OUT/fetch-live.log" 2>&1
	echo "    driver exit code: $?"
	# Show the measured numbers too (wall times, fd/thread/zombie counts), not
	# just the verdicts: "it was concurrent" is only evidence with the
	# milliseconds next to it.
	grep -aE '\[(PASS|FAIL)\]|=== RESULT|^    ' "$OUT/fetch-live.log" | sed 's/^/    /'
	assert_formatted "fetch-live" "$OUT/fetch-live.log"
	tally "fetch-live" "$OUT/fetch-live.log"
fi

echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 5/6  device-discriminator (T6.3) — the same machine, two ssh target strings"
echo "────────────────────────────────────────────────────────────────────────"
# The check that a device-blind model cannot pass on a single box. Needs the
# fixture PAIR; without two distinct target strings there is nothing to
# discriminate, so this skips rather than silently going green.
if [ -z "${HERDR_SESSION_TEST_REMOTE:-}" ] || [ -z "${HERDR_SESSION_TEST_REMOTE_ALIAS:-}" ] \
	|| [ "${HERDR_SESSION_TEST_REMOTE:-}" = "${HERDR_SESSION_TEST_REMOTE_ALIAS:-}" ]; then
	echo "    SKIPPED — need REMOTE + a DISTINCT _ALIAS (T6.3 discriminates on two"
	echo "    target strings for one machine; one string proves nothing)."
else
	env BIN="$BIN" \
		HERDR_SESSION_TEST_REMOTE="${HERDR_SESSION_TEST_REMOTE}" \
		HERDR_SESSION_TEST_REMOTE_ALIAS="${HERDR_SESSION_TEST_REMOTE_ALIAS}" \
		python3 "$(dirname "$0")/device_discriminator.py" > "$OUT/device-discriminator.log" 2>&1
	echo "    driver exit code: $?"
	grep -aE '\[(PASS|FAIL)\]|^      \||^== ' "$OUT/device-discriminator.log" | sed 's/^/    /'
	assert_formatted "device-discriminator" "$OUT/device-discriminator.log"
	tally "device-discriminator (T6.3)" "$OUT/device-discriminator.log"
fi

# ---------------------------------------------------------------------------
# 6. Anti-criteria greps — the rules that must hold textually, not just at runtime
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────────────"
echo " 6/6  anti-criteria greps over product sources"
echo "────────────────────────────────────────────────────────────────────────"
SRC_ROOT="$(cd "$(dirname "$0")/../src" && pwd)"
# Product sources = everything EXCEPT the *_cases / *_live drivers. The drivers
# deliberately hand `default` and an invalid name to a builder in order to assert
# it is refused, so running that rule over them would flag the proof, not the bug.
PRODUCT_DIRS=("$SRC_ROOT/app" "$SRC_ROOT/render" "$SRC_ROOT/terminal" "$SRC_ROOT/main.odin")

grep_check() {
	local label="$1" pattern="$2" path="$3" hits
	hits=$(grep -rn "$pattern" "$path" 2>/dev/null | wc -l | tr -d ' ')
	if [ "$hits" = "0" ]; then
		printf '    [PASS] %s\n' "$label"; PASS_TOTAL=$((PASS_TOTAL + 1))
	else
		printf '    [FAIL] %s — %s hit(s)\n' "$label" "$hits"
		grep -rn "$pattern" "$path" 2>/dev/null | head -4 | sed 's/^/         /'
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
	fi
}

# The single-choke-point rule: the literal "herdr" may appear ONLY as the one
# HERDR_BIN constant in src/app/herdr.odin. Anywhere else means a second spawn path.
hits=$(grep -rn '"herdr"' "${PRODUCT_DIRS[@]}" 2>/dev/null | grep -vc 'src/app/herdr.odin' || true)
if [ "$hits" = "0" ]; then
	printf '    [PASS] "herdr" is named only by src/app/herdr.odin (one spawn path)\n'
	PASS_TOTAL=$((PASS_TOTAL + 1))
else
	printf '    [FAIL] the "herdr" literal appears outside the choke point — %s hit(s)\n' "$hits"
	grep -rn '"herdr"' "${PRODUCT_DIRS[@]}" 2>/dev/null | grep -v 'src/app/herdr.odin' | head -4 | sed 's/^/         /'
	FAIL_TOTAL=$((FAIL_TOTAL + 1))
fi

for d in "${PRODUCT_DIRS[@]}"; do
	grep_check "no merged streams before a JSON parse (ISC-A-1) — $d" '2>&1' "$d"
	grep_check "no fixture host names in product code (ISC-A-3) — $d" '127\.0\.0\.1\|localhost' "$d"
	grep_check "no threads (ISC-A-6) — $d" 'core:thread' "$d"
	grep_check "no TOML dependency anywhere (ISC-A-5) — $d" 'toml' "$d"
	grep_check "no Kitty protocol (ISC-A-4) — $d" 'kitty\|\[>1u' "$d"
done

# `default` must never reach an argv builder in product code.
hits=$(grep -rn 'attach_argv("default")\|launch_argv([^,]*, *"default"' "${PRODUCT_DIRS[@]}" 2>/dev/null | wc -l | tr -d ' ')
if [ "$hits" = "0" ]; then
	printf '    [PASS] nothing hands `default` to a launch/attach builder\n'
	PASS_TOTAL=$((PASS_TOTAL + 1))
else
	printf '    [FAIL] `default` reaches a builder — %s hit(s)\n' "$hits"; FAIL_TOTAL=$((FAIL_TOTAL + 1))
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo
echo "════════════════════════════════════════════════════════════════════════"
printf ' PHASE 3 TOTAL: %s PASS / %s FAIL\n' "$PASS_TOTAL" "$FAIL_TOTAL"
# STALE_BIN is checked explicitly because this suite assigns FAIL_TOTAL=0 in its
# own setup, after sourcing lib.sh — which erases any counter bump the freshness
# gate made. Read the flag, not the counter.
if [ "${STALE_BIN:-0}" != "0" ]; then
	echo " RESULT: FAIL — the binary under test is STALE, so none of the lines"
	echo "          above are current evidence. Rebuild and re-run."
	trap - EXIT
	exit 1
fi
if [ "$FAIL_TOTAL" = "0" ]; then
	echo " RESULT: PASS"
else
	echo " RESULT: FAIL"
	trap - EXIT
	exit 1
fi
