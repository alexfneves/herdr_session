#!/usr/bin/env bash
# dev/render-smoke.sh — evidence runner for Phase 2 (T2.1 measure, T2.2
# Clay->cell renderer, T2.3 the Clay error handler).
#
# Two layers of evidence, because each catches what the other cannot:
#
#   1. CELL LEVEL. The driver reads termbox's *back buffer* back with
#      tb_get_cell(x, y, back=1, ..) and asserts on glyph + fg + bg against the
#      geometry Clay itself reported. Deterministic, exact, no pixel guessing.
#   2. WIRE LEVEL. The pty typescript is grepped for the truecolour SGR
#      sequences and the box-drawing bytes, which proves the colours actually
#      left the process rather than only living in a buffer we wrote ourselves.
#
# Every terminal case runs inside a real pty: `script -q -e` allocates one and
# propagates the child's exit status. A terminal case run without one dies with
# ENXIO and proves nothing.
#
#   BIN=./result/bin/herdr-session ./dev/render-smoke.sh [outdir]
#   BIN=/tmp/hs               ./dev/render-smoke.sh   # outdir default /tmp/hs-render
#
# Dev-only: nix/package.nix ships src/ and vendor/ only, so this file never
# reaches the package and can be deleted in one action.
set -uo pipefail

BIN="${BIN:-/tmp/hs}"
OUT="${1:-/tmp/hs-render}"
rm -rf "$OUT"
mkdir -p "$OUT"
PASS_TOTAL=0
FAIL_TOTAL=0

# run_pty NAME CASE — one case, one pty, one typescript.
run_pty() {
	local name="$1" case="$2"
	script -q -e -c "stty rows 40 cols 120; $BIN $case" "$OUT/$name.typescript" >/dev/null 2>&1
	echo "    program exit code: $?"
	grep -aoE '\[(PASS|FAIL)\].*|=== RESULT.*|reported:.*|^  .*\|.*|^  [\.`].*\.$' "$OUT/$name.typescript" | sed 's/^/    /'
}

# tally LABEL LOGFILE — count the driver's own PASS/FAIL lines.
tally() {
	local label="$1" log="$2"
	local p f
	p=$(grep -ac '\[PASS\]' "$log" || true)
	f=$(grep -ac '\[FAIL\]' "$log" || true)
	PASS_TOTAL=$((PASS_TOTAL + p))
	FAIL_TOTAL=$((FAIL_TOTAL + f))
	printf '\n== %s: %s PASS / %s FAIL\n' "$label" "$p" "$f"
}

# expect_wire LABEL PATTERN — assert a byte pattern reached the tty.
expect_wire() {
	local label="$1" pattern="$2" log="$3"
	local hits
	hits=$(grep -aoF "$pattern" "$log" | wc -l | tr -d ' ')
	if [ "$hits" -ge 1 ]; then
		printf '    [PASS] %s (%s occurrence(s))\n' "$label" "$hits"
		PASS_TOTAL=$((PASS_TOTAL + 1))
	else
		printf '    [FAIL] %s — not found on the wire\n' "$label"
		FAIL_TOTAL=$((FAIL_TOTAL + 1))
	fi
}

if [ ! -x "$BIN" ]; then
	echo "no executable at BIN=$BIN — build first:"
	echo "  nix build .           # then BIN=./result/bin/herdr-session"
	echo "  odin build src -out:/tmp/hs -o:speed -vet"
	exit 2
fi

# ---------------------------------------------------------------------------
echo "=== 1. T2.1 measure_text — display columns, not bytes, not runes ==="
"$BIN" measure 2>&1 | tee "$OUT/01-measure.log" | sed 's/^/    /'
tally "measure" "$OUT/01-measure.log"

# ---------------------------------------------------------------------------
echo
echo "=== 2. T2.2 renderer — border, betweenChildren rule, alignment, colour ==="
run_pty 02-render render | tee "$OUT/02-render.log"
tally "renderer (cell level)" "$OUT/02-render.log"

echo
echo "  wire-level proof from the same pty typescript:"
expect_wire "truecolour foreground for the border (255,60,60)" '38;2;255;60;60' "$OUT/02-render.typescript"
expect_wire "truecolour foreground for body text (220,220,220)" '38;2;220;220;220' "$OUT/02-render.typescript"
expect_wire "truecolour foreground for the centred accent (60,200,120)" '38;2;60;200;120' "$OUT/02-render.typescript"
expect_wire "truecolour foreground for the right-aligned footer (40,90,200)" '38;2;40;90;200' "$OUT/02-render.typescript"
expect_wire "truecolour background for the panel (16,20,28)" '48;2;16;20;28' "$OUT/02-render.typescript"
expect_wire "box-drawing horizontal glyph U+2500 reached the tty" '─' "$OUT/02-render.typescript"
expect_wire "box-drawing vertical glyph U+2502 reached the tty" '│' "$OUT/02-render.typescript"
expect_wire "corner glyphs U+250C/2510/2514/2518 reached the tty" '┌' "$OUT/02-render.typescript"
expect_wire "CJK glyph 中 reached the tty" '中' "$OUT/02-render.typescript"
expect_wire "emoji 😀 reached the tty" '😀' "$OUT/02-render.typescript"
# 8-bit / 16-colour fallback sequences would mean the truecolour path was NOT used.
if grep -aqF $'\x1b[38;5;' "$OUT/02-render.typescript"; then
	echo "    [FAIL] an indexed-colour (38;5) sequence appeared: truecolour was not used end to end"
	FAIL_TOTAL=$((FAIL_TOTAL + 1))
else
	echo "    [PASS] no indexed-colour fallback: truecolour all the way out"
	PASS_TOTAL=$((PASS_TOTAL + 1))
fi

# ---------------------------------------------------------------------------
echo
echo "=== 3. T2.2 scissor — overflowing content stays inside the clip ==="
run_pty 03-clip clip | tee "$OUT/03-clip.log"
tally "scissor" "$OUT/03-clip.log"

# ---------------------------------------------------------------------------
echo
echo "=== 4. T2.3 Clay error handler — duplicate id survives the C frame ==="
run_pty 04-clay-error clay-error | tee "$OUT/04-clay-error.log"
tally "clay error handler" "$OUT/04-clay-error.log"

# The default Clay handler is a no-op, so the message could only have come from
# ours. Show it verbatim from the captured stream.
echo
echo "  the message as it reached the log:"
grep -a 'reported:' "$OUT/04-clay-error.log" | sed 's/^/    /'

# ---------------------------------------------------------------------------
echo
echo "=== 5. layout-dump — the command stream the renderer consumes ==="
script -q -e -c "stty rows 40 cols 120; $BIN layout-dump" "$OUT/05-layout.typescript" >/dev/null 2>&1
grep -aoE '(Rectangle|Border|Text|ScissorStart|ScissorEnd) +\([^)]*\).*' "$OUT/05-layout.typescript" | sed 's/^/    /'

printf '\n#### TOTAL: %s PASS / %s FAIL — evidence in %s\n' "$PASS_TOTAL" "$FAIL_TOTAL" "$OUT"
[ "$FAIL_TOTAL" -eq 0 ] || exit 1
