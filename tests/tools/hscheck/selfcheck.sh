#!/usr/bin/env bash
# selfcheck.sh — PROVES the gate works, in both directions.
#
# The plan's T1 acceptance is stated as a pair, and both halves have to be shown:
#
#   * a gate whose suite table is EMPTY must FAIL, and
#   * the SAME gate pointed at a 1-test fixture must PASS.
#
# Both runs use the same binary and the same code path. Only the data differs.
# If a future change makes the empty case pass, or the one-test case fail, this
# script goes red — which is the point. A gate nobody demonstrated is a gate that
# is not believed.
#
# Run: dev/../tests/tools/hscheck/selfcheck.sh   (from the repo root)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

ODIN_BIN="${ODIN_BIN:-/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin}"
export PATH="$ODIN_BIN:$PATH"

WORK="${HS_SELFCHECK_DIR:-/tmp/hs-selfcheck}"
rm -rf "$WORK"
mkdir -p "$WORK"

pass=0
fail=0
verdict() { # want_pass  label  exit_code  haystack_file  needle
	local want="$1" label="$2" code="$3" file="$4" needle="$5"
	if [ "$want" = "pass" ] && [ "$code" = "0" ]; then
		echo "    [PASS] $label"
		pass=$((pass+1))
	elif [ "$want" = "fail" ] && [ "$code" != "0" ]; then
		echo "    [PASS] $label"
		pass=$((pass+1))
	else
		echo "    [FAIL] $label (exit=$code, wanted $want)"
		[ -f "$file" ] && tail -6 "$file" | sed 's/^/           | /'
		fail=$((fail+1))
	fi
}

has_line() { grep -aq "$1" "$2" 2>/dev/null; }

echo "── building the gate and the fixtures ──"
odin build ./tests/tools/hscheck/cmd -out:"$WORK/hs_check" >/dev/null 2>&1 || {
	echo "FATAL: the gate does not build"; exit 1; }

# A fixture table naming the two fixture suites. `hsfixture` has exactly one
# test that makes exactly one counted assertion.
cat > "$WORK/parity-one.tsv" <<'EOF'
# suite	tier	floor_before	pass_after	fail_after	skipped	files	task	notes
fixture	hermetic	1				fixture_test	T1	gate positive fixture: exactly 1 assertion
EOF

# The same table with every row removed: the empty-table case.
cat > "$WORK/parity-empty.tsv" <<'EOF'
# suite	tier	floor_before	pass_after	fail_after	skipped	files	task	notes
# (deliberately no rows)
EOF

# A floor the fixture cannot reach — proves rule 4 actually bites.
cat > "$WORK/parity-toohigh.tsv" <<'EOF'
# suite	tier	floor_before	pass_after	fail_after	skipped	files	task	notes
fixture	hermetic	9				fixture_test	T1	floor is unreachable on purpose
EOF

# A suite named with no parity row — proves the floor-0 self-disable is refused.
cat > "$WORK/parity-norow.tsv" <<'EOF'
# suite	tier	floor_before	pass_after	fail_after	skipped	files	task	notes
other	hermetic	1				other_test	T1	this row is not the suite we will name
EOF

# The JSON report path is COMPILE-TIME (ODIN_TEST_JSON_REPORT is a #config, not
# an env var), so it is baked into the fixture here and handed to the gate as the
# third field of --suite. Same shape the nix test derivation uses in T15.
build_fixture() { # $1 = tag
	# Declared separately: bash expands every word of a single `local` line before
	# assigning any of them, so referencing $tag on the same line trips set -u.
	local tag
	local rep
	tag="$1"
	rep="$WORK/reports/$tag/fixture.json"
	mkdir -p "$WORK/reports/$tag"
	rm -f "$rep"
	odin build ./tests/tools/hscheck/fixture -build-mode:test \
		-out:"$WORK/hs-fixture-$tag" \
		-define:ODIN_TEST_JSON_REPORT="$rep" \
		>/dev/null 2>&1 || { echo "FATAL: the fixture ($tag) does not build"; exit 1; }
	echo "fixture=$WORK/hs-fixture-$tag:$rep"
}

mkdir -p "$WORK/reports"

echo
echo "── PROOF 1: an EMPTY suite table must FAIL the gate ──"
"$WORK/hs_check" --parity="$WORK/parity-empty.tsv" \
	--report-dir="$WORK/reports/empty" > "$WORK/p1.log" 2>&1
code=$?
verdict fail "empty table: gate exits non-zero" "$code" "$WORK/p1.log" ""
if has_line "EMPTY SUITE TABLE" "$WORK/p1.log"; then
	echo "    [PASS] empty table: the gate SAYS why out loud"
	pass=$((pass+1))
else
	echo "    [FAIL] empty table: failed but never said the table was empty"
	fail=$((fail+1))
fi

echo
echo "── PROOF 2: a 1-TEST FIXTURE must PASS the same gate ──"
SUITE_ARG="$(build_fixture one)"
"$WORK/hs_check" --parity="$WORK/parity-one.tsv" \
	--suite="$SUITE_ARG" \
	--report-dir="$WORK/reports/one" > "$WORK/p2.log" 2>&1
code=$?
verdict pass "1-test fixture: gate exits zero" "$code" "$WORK/p2.log" ""
if has_line "RESULT: PASS" "$WORK/p2.log"; then
	echo "    [PASS] 1-test fixture: the gate reports PASS"
	pass=$((pass+1))
else
	echo "    [FAIL] 1-test fixture: no RESULT: PASS"
	fail=$((fail+1))
fi
if has_line "1 assertions against a floor of 1" "$WORK/p2.log"; then
	echo "    [PASS] 1-test fixture: the counted assertion meets the floor"
	pass=$((pass+1))
else
	echo "    [FAIL] 1-test fixture: assertion/floor line not reported"
	fail=$((fail+1))
fi

echo
echo "── PROOF 3: an unreachable floor must FAIL (the rule bites) ──"
SUITE_ARG="$(build_fixture high)"
"$WORK/hs_check" --parity="$WORK/parity-toohigh.tsv" \
	--suite="$SUITE_ARG" \
	--report-dir="$WORK/reports/high" > "$WORK/p3.log" 2>&1
code=$?
verdict fail "floor 9 vs 1 assertion: gate exits non-zero" "$code" "$WORK/p3.log" ""
if has_line "REGRESSION" "$WORK/p3.log"; then
	echo "    [PASS] shortfall is called a REGRESSION, not a pass"
	pass=$((pass+1))
else
	echo "    [FAIL] shortfall was not named a regression"
	fail=$((fail+1))
fi

echo
echo "── PROOF 4: a suite with no parity row is REFUSED (floor 0 disabled) ──"
SUITE_ARG="$(build_fixture norow)"
"$WORK/hs_check" --parity="$WORK/parity-norow.tsv" \
	--suite="$SUITE_ARG" \
	--report-dir="$WORK/reports/norow" > "$WORK/p4.log" 2>&1
code=$?
verdict fail "no parity row: gate exits non-zero" "$code" "$WORK/p4.log" ""
if has_line "no row in the parity table" "$WORK/p4.log"; then
	echo "    [PASS] refuses to run an unrated suite instead of assuming floor 0"
	pass=$((pass+1))
else
	echo "    [FAIL] ran an unrated suite silently"
	fail=$((fail+1))
fi

echo
echo "════════════════════════════════════════════"
printf ' selfcheck: %s PASS / %s FAIL\n' "$pass" "$fail"
[ "$fail" = "0" ] || exit 1
echo " RESULT: PASS"
