#!/usr/bin/env bash
# dev/handoff-smoke.sh — evidence runner for Phase 1 (plan risk A1: is
# tb_shutdown() -> child -> tb_init() a clean handoff in practice?).
#
# Every case MUST run inside a real pty. A bare invocation from a shell with no
# controlling terminal dies with ENXIO ("No such device or address") and proves
# nothing, so each case is wrapped in `script -q -e`, which allocates a pty and
# propagates the child's exit code.
#
#   BIN=/tmp/hs ./dev/handoff-smoke.sh [outdir]     # outdir default /tmp/hs-smoke
#
# Dev-only: nix/package.nix ships src/ and vendor/ only, so this file never
# reaches the package and can be deleted in one action.
set -uo pipefail

BIN="${BIN:-/tmp/hs}"
OUT="${1:-/tmp/hs-smoke}"
rm -rf "$OUT"
mkdir -p "$OUT/probes"
PASS_TOTAL=0
FAIL_TOTAL=0

# ---------------------------------------------------------------------------
# Child probes. These run AS the handoff's child and write straight to the
# INHERITED tty, so what they print is ground truth for what the child received.
# ---------------------------------------------------------------------------
cat > "$OUT/probes/env_probe.sh" <<'EOF'
#!/bin/sh
echo "CHILD pid=$$ pgid=$(awk '{print $5}' /proc/self/stat) sid=$(awk '{print $6}' /proc/self/stat) pwd=$(pwd)"
echo "CHILD HERDR_VARS=$(env | grep -c '^HERDR_')"
echo "CHILD HERDR_LINES:[$(env | grep '^HERDR_' | tr '\n' ' ')]"
echo "CHILD TERM=${TERM:-MISSING} COLORTERM=${COLORTERM:-MISSING}"
echo "CHILD stdin=$(tty 2>/dev/null || echo not-a-tty)"
EOF

cat > "$OUT/probes/sig_probe.py" <<'EOF'
import os, signal, sys, time

def mask(pid):
    for line in open('/proc/%d/status' % pid):
        if line.startswith('SigBlk:'):
            return int(line.split()[1], 16)
    return -1

def handler(sig, frame):
    print('CHILD_GOT_SIGNAL=%d  (so the group-delivered signal reached the child)' % sig, flush=True)
    os._exit(40 + sig)

signal.signal(signal.SIGINT, handler)
signal.signal(signal.SIGQUIT, handler)
ppid = os.getppid()
print('CHILD pid=%d pgid=%d sid=%d SigBlk=0x%x  <- child must be 0x0' % (
    os.getpid(), os.getpgid(0), os.getsid(0), mask(os.getpid())), flush=True)
print('PARENT pid=%d pgid=%d SigBlk=0x%x  <- us; 0x6 == SIGINT|SIGQUIT blocked' % (
    ppid, os.getpgid(ppid), mask(ppid)), flush=True)
time.sleep(8)
print('CHILD_NO_SIGNAL', flush=True)
EOF
chmod +x "$OUT/probes/env_probe.sh"

# ---------------------------------------------------------------------------
# run_pty NAME CMD...
#   Runs CMD inside a fresh pty with a fixed size, capturing `stty -a` before and
#   after so the termios round-trip is checked for every single case.
# ---------------------------------------------------------------------------
run_pty() {
	local name="$1"; shift
	local cmd="$*"
	script -q -e -c "
		stty rows 40 cols 120
		stty -a > '$OUT/$name.stty-before'
		$cmd
		echo \$? > '$OUT/$name.rc'
		stty -a > '$OUT/$name.stty-after'
	" "$OUT/$name.typescript" >/dev/null 2>&1
	if diff -q "$OUT/$name.stty-before" "$OUT/$name.stty-after" >/dev/null 2>&1; then
		echo "    stty -a before == after: IDENTICAL (termios round-tripped)"
	else
		echo "    stty -a DIFFERS:"
		diff "$OUT/$name.stty-before" "$OUT/$name.stty-after" | sed 's/^/      /'
	fi
	echo "    program exit code: $(cat "$OUT/$name.rc" 2>/dev/null || echo unknown)"
	grep -aoE 'SELF .*|CHILD .*|\[(PASS|FAIL)\].*|=== RESULT.*|peek_event.*' \
		"$OUT/$name.typescript" | sed 's/^/    /'
}

# stream_order TYPESCRIPT — replay the pty stream in byte order to show that we
# LEAVE the alt screen before the child writes, and RE-ENTER only after it is gone.
stream_order() {
	python3 "$(dirname "$0")/stream_order.py" "$1"
}

verdict() { # verdict <label> <logfile>
	local label="$1" log="$2"
	local p f
	p=$(grep -ac '\[PASS\]' "$log" || true)
	f=$(grep -ac '\[FAIL\]' "$log" || true)
	PASS_TOTAL=$((PASS_TOTAL + p))
	FAIL_TOTAL=$((FAIL_TOTAL + f))
	printf '\n== %s: %s PASS / %s FAIL\n' "$label" "$p" "$f"
}

# ---------------------------------------------------------------------------
echo "=== 1. T1.1 ABI probe (tb_wcwidth / attr width / struct size) ==="
"$BIN" probe 2>&1 | tee "$OUT/01-probe.log" | sed 's/^/    /'
verdict "ABI probe" "$OUT/01-probe.log"

# ---------------------------------------------------------------------------
echo
echo "=== 2. Two tb_init/tb_shutdown round-trips + TB_ERR_INIT_ALREADY guard ==="
run_pty 02-double "$BIN double" | tee "$OUT/02-double.log"
verdict "double init/shutdown" "$OUT/02-double.log"

# ---------------------------------------------------------------------------
echo
echo "=== 3. handoff to 'sleep 2': repaint + input survive, termios round-trips ==="
# 'j' is fed to the pty 4 s in — i.e. after the child has returned — to prove a
# keypress is still readable post-handoff.
(sleep 4; printf 'j') | script -q -e -c "
	stty rows 40 cols 120
	stty -a > '$OUT/03.stty-before'
	$BIN handoff
	echo \$? > '$OUT/03.rc'
	stty -a > '$OUT/03.stty-after'
" > "$OUT/03.typescript" 2>&1
if diff -q "$OUT/03.stty-before" "$OUT/03.stty-after" >/dev/null; then
	echo "    stty -a before == after: IDENTICAL (termios round-tripped)"
else
	echo "    stty -a DIFFERS:"; diff "$OUT/03.stty-before" "$OUT/03.stty-after" | sed 's/^/      /'
fi
echo "    program exit code: $(cat "$OUT/03.rc")"
grep -aoE '\[(PASS|FAIL)\].*|=== RESULT.*' "$OUT/03.typescript" | sed 's/^/    /'
verdict "handoff + repaint + post-handoff key" "$OUT/03.typescript"
stream_order "$OUT/03.typescript"

# ---------------------------------------------------------------------------
echo
echo "=== 4. Exit-code propagation (child 'exit 7' must surface as 7) ==="
run_pty 04-exit7 "$BIN child $HOME sh -c 'exit 7'" | tee "$OUT/04-exit7.log"
verdict "exit code" "$OUT/04-exit7.log"

# ---------------------------------------------------------------------------
echo
echo "=== 5. HERDR_* scrub / same fg pgroup / explicit cwd ==="
echo "    our own environment has $(env | grep -c '^HERDR_') HERDR_* variables"
run_pty 05-env "env HERDR_ENV=1 HERDR_SESSION=fake-live HERDR_PANE_ID=fake-pane \
	HERDR_SOCKET_PATH=/tmp/leaky.sock HERDR_CLIENT_SOCKET_PATH=/tmp/leaky-client.sock \
	HERDR_TAB_ID=fake-tab HERDR_WORKSPACE_ID=fake-ws \
	$BIN child $HOME sh $OUT/probes/env_probe.sh" | tee "$OUT/05-env.log"
verdict "env scrub / pgroup / cwd" "$OUT/05-env.log"

# ---------------------------------------------------------------------------
echo
echo "=== 6. SIGINT arrives while the child owns the tty ==="
echo "    (group-killed exactly like the tty driver does with Ctrl-C)"
rm -f "$OUT/hs.pid"
script -q -e -c "
	stty rows 40 cols 120
	stty -a > '$OUT/06.stty-before'
	HS_PIDFILE='$OUT/hs.pid' $BIN child $HOME python3 $OUT/probes/sig_probe.py
	echo \$? > '$OUT/06.rc'
	stty -a > '$OUT/06.stty-after'
" > "$OUT/06.typescript" 2>&1 &
SP=$!
for _ in $(seq 1 200); do [ -s "$OUT/hs.pid" ] && break; sleep 0.05; done
sleep 1.0
PG=$(cut -d' ' -f2 "$OUT/hs.pid")
echo "    harness: kill -INT -$PG"
kill -INT -"$PG" 2>/dev/null
wait $SP
if diff -q "$OUT/06.stty-before" "$OUT/06.stty-after" >/dev/null; then
	echo "    stty -a before == after: IDENTICAL"
else
	echo "    stty -a DIFFERS"
fi
echo "    program exit code: $(cat "$OUT/06.rc" 2>/dev/null || echo 'MISSING (we died to the signal!)')"
grep -aoE 'CHILD.*|PARENT.*|SELF.*|\[(PASS|FAIL)\].*|=== RESULT.*' "$OUT/06.typescript" | sed 's/^/    /'
verdict "SIGINT during handoff" "$OUT/06.typescript"
stream_order "$OUT/06.typescript"

# ---------------------------------------------------------------------------
echo
echo "=== 7. SIGTERM / SIGHUP while in the alt screen: our handler must restore ==="
for SIG in TERM HUP; do
	case $SIG in TERM) expect=143 ;; HUP) expect=129 ;; esac
	rm -f "$OUT/hs.pid"
	script -q -e -c "
		stty rows 40 cols 120
		stty -a > '$OUT/07-$SIG.stty-before'
		HS_PIDFILE='$OUT/hs.pid' $BIN sig-term
		echo \$? > '$OUT/07-$SIG.rc'
		stty -a > '$OUT/07-$SIG.stty-after'
	" > "$OUT/07-$SIG.typescript" 2>&1 &
	SP=$!
	for _ in $(seq 1 200); do [ -s "$OUT/hs.pid" ] && break; sleep 0.05; done
	sleep 0.8
	PID=$(cut -d' ' -f1 "$OUT/hs.pid")
	echo "    harness: kill -$SIG $PID"
	kill -"$SIG" "$PID" 2>/dev/null
	wait $SP
	rc="$(cat "$OUT/07-$SIG.rc" 2>/dev/null || echo none)"
	leaves=$(grep -aoU $'\x1b\[?1049l' "$OUT/07-$SIG.typescript" | wc -l | tr -d ' ')
	if diff -q "$OUT/07-$SIG.stty-before" "$OUT/07-$SIG.stty-after" >/dev/null; then
		st="IDENTICAL"
	else
		st="DIFFERENT"
	fi
	printf '    SIG%s: exit=%s (expect %s) · alt-screen-leave sequences=%s · stty before/after=%s\n' \
		"$SIG" "$rc" "$expect" "$leaves" "$st"
	[ "$rc" = "$expect" ] && PASS_TOTAL=$((PASS_TOTAL + 1)) || FAIL_TOTAL=$((FAIL_TOTAL + 1))
	[ "$leaves" -ge 1 ] && PASS_TOTAL=$((PASS_TOTAL + 1)) || FAIL_TOTAL=$((FAIL_TOTAL + 1))
	[ "$st" = "IDENTICAL" ] && PASS_TOTAL=$((PASS_TOTAL + 1)) || FAIL_TOTAL=$((FAIL_TOTAL + 1))
done

printf '\n#### TOTAL: %s PASS / %s FAIL — evidence in %s\n' "$PASS_TOTAL" "$FAIL_TOTAL" "$OUT"
