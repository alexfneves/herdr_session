# dev/lib.sh — the shared evidence rules for every smoke script.
#
# Why this file exists: the rule that makes these suites trustworthy
# ("a log with zero [PASS] lines is a FAILURE, not a pass") was invented in
# dev/app-smoke.sh and then re-implemented slightly differently — or not at all —
# in the others. A copy that drifts is worse than no copy: `handoff-smoke.sh`
# returned 0 with 10 FAILs on a manufactured broken binary, and `resize-smoke.sh`
# / `tui-smoke.sh` reported a scenario that emitted NOTHING as "PASS (0 checks)".
# One implementation, sourced by every suite, so the rule cannot drift again.
#
# Usage:
#
#   . "$(dirname "$0")/lib.sh"        # sets PASS_TOTAL / FAIL_TOTAL / SKIP_TOTAL
#   ...
#   assert_formatted "app-unit" "$OUT/app-unit.log"
#   tally "app-unit" "$OUT/app-unit.log"
#   skip "fetch-live" "HERDR_SESSION_TEST_REMOTE is unset"
#   smoke_verdict "PHASE 3"           # prints the total, exits 1 on any FAIL
#
# SKIP vs FAIL — the distinction is deliberate and is the whole point of the
# T6 fixture-removability rule ("unset the env and the rest stays green"):
#
#   * a SKIPPED check is one that COULD run but has no fixture. It is counted
#     and printed, loudly, and NEVER added to the pass total. A suite that skipped
#     everything prints "0 PASS" and fails the zero-assertion rule anyway.
#   * an OPTIONAL skip (the fixture-dependent sections that are documented as
#     removable) keeps the suite green — but only if you say so out loud with
#     ALLOW_SKIP=1. Without it, a skip makes the run non-green, which is what
#     stops "we did not run the proof" from ever reading as "the proof passed".
#
# Dev-only: nix/package.nix ships src/ and vendor/ only.

# Tolerate documented fixture-optional skips? 0 = a skip fails the run.
: "${ALLOW_SKIP:=0}"

PASS_TOTAL=0
FAIL_TOTAL=0
SKIP_TOTAL=0

# tally LABEL LOG — fold one driver's own [PASS]/[FAIL]/[SKIP] lines into the
# suite total, under the zero-assertion rule.
#
# A log with zero [PASS] lines is a FAILURE, not a pass. Without this rule a
# wrong/stale $BIN silently fell through to the driver's default case and every
# section reported "0 PASS / 0 FAIL" while the run still went green — a harness
# that cannot tell "everything passed" from "nothing ran" is worse than none.
tally() {
	local label="$1" log="${2:-}" p f s
	if [ ! -f "$log" ]; then
		printf '\n== %s: NO LOG (treated as FAIL)\n' "$label"
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
		return 1
	fi
	p=$(grep -ac '\[PASS\]' "$log" || true)
	f=$(grep -ac '\[FAIL\]' "$log" || true)
	s=$(grep -ac '\[SKIP\]' "$log" || true)
	# The zero-assertion rule, stated precisely: what is a failure is a log with NO
	# VERDICT OF ANY KIND. A log that says [SKIP] did state something — the driver
	# knew the check was there and explained why it could not run — so it counts as
	# a SKIP, not as a silently-missing assertion. Skipping is still not passing:
	# smoke_verdict turns a non-zero SKIP_TOTAL red unless ALLOW_SKIP=1 declares it
	# optional. Conflating SKIP with EMPTY would let a driver paper over a broken
	# harness by printing one [SKIP] and nothing else, and conflating SKIP with
	# PASS is the original sin this whole file exists to remove.
	if [ "${p:-0}" = "0" ] && [ "${f:-0}" = "0" ] && [ "${s:-0}" = "0" ]; then
		printf '\n== %s: 0 PASS / 0 FAIL / 0 SKIP — nothing ran (treated as FAIL)\n' "$label"
		printf '    the binary probably has no such case. head of its log:\n'
		head -3 "$log" | sed 's/^/      /'
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
		return 1
	fi
	PASS_TOTAL=$((PASS_TOTAL + p))
	FAIL_TOTAL=$((FAIL_TOTAL + f))
	SKIP_TOTAL=$((SKIP_TOTAL + s))
	printf '\n== %s: %s PASS / %s FAIL / %s SKIP\n' "$label" "$p" "$f" "$s"
	return 0
}

# classify_log LOG — echo exactly one of PASS / FAIL / SKIP / EMPTY for a log,
# without touching the totals (tally does that). The point is that "nothing was
# asserted" gets its OWN answer instead of collapsing into PASS:
#
#   FAIL  — any [FAIL] line
#   SKIP  — no [FAIL], no [PASS], but the driver said [SKIP]
#   EMPTY — no verdict line of any kind: nothing ran
#   PASS  — at least one [PASS] and no [FAIL]
classify_log() {
	local log="$1" p f s
	if [ ! -f "$log" ]; then echo FAIL; return; fi
	p=$(grep -ac '\[PASS\]' "$log" || true)
	f=$(grep -ac '\[FAIL\]' "$log" || true)
	s=$(grep -ac '\[SKIP\]' "$log" || true)
	if [ "${f:-0}" != "0" ]; then echo FAIL
	elif [ "${p:-0}" = "0" ] && [ "${s:-0}" != "0" ]; then echo SKIP
	elif [ "${p:-0}" = "0" ] && [ "${s:-0}" = "0" ]; then echo EMPTY
	else echo PASS
	fi
}

# skip LABEL REASON — record a check that did not run.
#
# The line is printed as a driver-style [SKIP] so it survives into the transcript
# and can never be mistaken for a pass. The reason has to be a sentence, because
# "skipped" with no reason is how a missing fixture becomes invisible.
skip() {
	local label="$1" reason="${2:-no reason given}"
	SKIP_TOTAL=$((SKIP_TOTAL + 1))
	printf '    [SKIP] %s — %s\n' "$label" "$reason"
}

# assert_formatted LABEL LOG — fail if the log contains Go/Odin printf fallout
# (`%!`, `%!f(int=0)`, `%!d(MISSING)` …). A mistyped format string otherwise
# produces a plausible-looking line whose NUMBERS are wrong or absent, which is
# the worst possible failure mode for a timing claim: the check still passes, the
# evidence beside it is garbage.
assert_formatted() {
	local label="$1" log="$2" bad
	if [ ! -f "$log" ]; then
		printf '    [FAIL] %s — no log to check for printf fallout\n' "$label"
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
		return 1
	fi
	bad=$(grep -ac '%!' "$log" 2>/dev/null || true)
	if [ "${bad:-0}" = "0" ]; then
		printf '    [PASS] %s — no printf format fallout\n' "$label"
		PASS_TOTAL=$((PASS_TOTAL + 1))
		return 0
	fi
	printf '    [FAIL] %s — %s malformed format expansion(s)\n' "$label" "$bad"
	grep -a '%!' "$log" 2>/dev/null | head -3 | sed 's/^/      /'
	FAIL_TOTAL=$((FAIL_TOTAL + 1))
	return 1
}

# smoke_verdict TITLE — print the total and exit non-zero on any FAIL, on any
# SKIP unless ALLOW_SKIP=1 declared that suite's skips as optional, or on a
# STALE binary.
#
# STALE_BIN is checked here rather than left to FAIL_TOTAL on purpose: several
# suites assign `FAIL_TOTAL=0` partway through their own setup, which wiped the
# staleness failure and printed "RESULT: PASS" underneath a banner that had just
# said the binary was not the code under test. A flag read at the very end cannot
# be erased by an earlier reset.
smoke_verdict() {
	local title="${1:-SMOKE}"
	echo
	echo "════════════════════════════════════════════════════════════════════════"
	printf ' %s TOTAL: %s PASS / %s FAIL / %s SKIP\n' "$title" "$PASS_TOTAL" "$FAIL_TOTAL" "$SKIP_TOTAL"
	if [ "${STALE_BIN:-0}" != "0" ]; then
		echo " RESULT: FAIL — the binary under test is STALE (see the note above)."
		echo "          Every line above was produced by code that is not the current"
		echo "          source, so none of it is current evidence. Rebuild and re-run."
		trap - EXIT INT TERM
		exit 1
	fi
	if [ "$FAIL_TOTAL" != "0" ]; then
		echo " RESULT: FAIL"
		trap - EXIT INT TERM
		exit 1
	fi
	if [ "$SKIP_TOTAL" != "0" ] && [ "$ALLOW_SKIP" != "1" ]; then
		echo " RESULT: FAIL — $SKIP_TOTAL check(s) were SKIPPED, and a skipped"
		echo "          check is not a passed check. Run with the fixture armed"
		echo "          (dev/test-remote.md), or ALLOW_SKIP=1 to declare the skips"
		echo "          optional and go green anyway."
		trap - EXIT INT TERM
		exit 1
	fi
	if [ "$SKIP_TOTAL" != "0" ]; then
		echo " RESULT: PASS — $SKIP_TOTAL check(s) SKIPPED, declared optional via ALLOW_SKIP=1"
	else
		echo " RESULT: PASS"
	fi
	return 0
}

# STALE_BIN is set by require_fresh_bin and read by smoke_verdict. It has to be a
# separate sticky flag rather than a bump of FAIL_TOTAL: several suites
# re-initialise their own PASS_TOTAL/FAIL_TOTAL after sourcing this file, which
# would erase the failure and let the run print "0 FAIL" directly under a banner
# that had just said the binary was untrustworthy. Observed doing exactly that.
STALE_BIN=0

# Reproducible builds (nix) set SOURCE_DATE_EPOCH, so result/bin/* carries mtime
# 1970-01-01 by design and is older than every source file forever. Comparing
# mtimes against it would flag every nix build as stale — a false positive that
# trains people to ignore the gate, which is worse than not having the gate.
REPRODUCIBLE_MTIME_MAX=1262304000   # 2010-01-01; below this is an epoch sentinel

# require_fresh_bin BIN [src_root] — refuse to certify a stale binary (P3, found
# the hard way: dev/app-smoke.sh defaulted to /tmp/hs from the previous day, and
# its output showed `%!(MISSING ARGUMENT)` in lines the current source no longer
# produces. Old evidence printed under a new suite's banner is worse than no
# evidence, because it reads as current.)
require_fresh_bin() {
	local bin="${1:-}" root="${2:-src}"
	if [ -z "$bin" ] || [ ! -f "$bin" ]; then
		printf '    [NOTE] require_fresh_bin: no binary at %s — freshness not checked\n' "$bin"
		return 0
	fi
	local btime
	btime=$(stat -c '%Y' "$bin" 2>/dev/null || echo "")
	if [ -z "$btime" ]; then
		printf '    [NOTE] require_fresh_bin: cannot stat %s — freshness not checked\n' "$bin"
		return 0
	fi
	if [ "$btime" -lt "$REPRODUCIBLE_MTIME_MAX" ]; then
		printf '    [NOTE] %s has a reproducible-build timestamp (epoch %s): freshness comes\n' "$bin" "$btime"
		printf '           from the derivation hash, not from mtime, so mtime is not compared.\n'
		return 0
	fi
	local newest
	newest=$(find "$root" -name '*.odin' -newer "$bin" 2>/dev/null | head -3)
	if [ -n "$newest" ]; then
		printf '    [FAIL] %s is STALE — newer sources exist, so this binary is not the code under test:\n' "$bin"
		printf '%s\n' "$newest" | sed 's/^/             /'
		printf '           Rebuild before trusting any output from this suite.\n'
		STALE_BIN=1
		return 1
	fi
	return 0
}
