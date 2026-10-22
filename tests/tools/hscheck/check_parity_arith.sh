#!/usr/bin/env bash
# check_parity_arith.sh — verify tests/parity.tsv adds up, per tier and overall.
#
# WHY THIS IS A SCRIPT AND NOT A COMMENT
#
# The parity table's arithmetic was previously asserted in a comment block and
# checked by hand. Hand-checked totals in a file that changes every time a lane
# lands are not verification — they are a claim that goes stale quietly. This
# re-reads the actual rows every run.
#
# It also prints the ORIGIN reconciliation: every assertion in the table is
# traced back to either the armed bash baseline (1544), a specific lane's
# measured delivery, or an explicitly reserved row that does not exist yet.
# A total that closes without that trace is arithmetic, not accounting.
#
# Exit 0 = the table adds up AND every tier is accounted for.
# Exit 1 = mismatch. Do not proceed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TSV="${1:-$ROOT/tests/parity.tsv}"

python3 - "$TSV" <<'PY'
import collections, sys

path = sys.argv[1]
rows = []
for line in open(path):
    if line.startswith("#") or not line.strip():
        continue
    rows.append(line.rstrip("\n").split("\t"))

tiers = collections.Counter()
detail = collections.defaultdict(list)
for c in rows:
    if len(c) < 3:
        print("  MALFORMED ROW (fewer than 3 columns): %r" % (c,)); sys.exit(1)
    try:
        floor = int(c[2])
    except ValueError:
        print("  MALFORMED FLOOR in row %r: %r" % (c[0], c[2])); sys.exit(1)
    tiers[c[1]] += floor
    detail[c[1]].append((c[0], floor))

KNOWN = {"hermetic", "fixture", "pty"}
unknown = [k for k in tiers if k not in KNOWN]

print("  PER-TIER FLOORS (what the gate enforces)")
for k in ["hermetic", "pty", "fixture"]:
    print("    %-9s = %5d   rows: %s" % (k, tiers[k], ", ".join("%s:%d" % x for x in detail[k])))
total = sum(tiers.values())
print("    %-9s = %5d" % ("TOTAL", total))

if unknown:
    print()
    print("  UNKNOWN TIER(S): %s -- the gate refuses these rows, so they are"
          % ", ".join(unknown))
    print("  NOT enforced. Fix the tier value or teach the gate.")
    sys.exit(1)

# Origin reconciliation. Each entry is (label, amount) and must sum to `total`.
ORIGIN = [
    ("armed bash baseline (T0 closed)",              1544),
    ("T2 diag(10) + keyhints(44 as first counted)",   54),
    ("T2 keyhints floor raised 44 -> 54",              10),
    ("lane P pty: width 67 + ffi 27 + screen 73 + driver 51", 218),
    ("theme tty work RESERVED (NOT delivered yet)",   36),
]
acc = 0
print()
print("  ORIGIN RECONCILIATION")
for label, amt in ORIGIN:
    acc += amt
    print("    + %4d  %s" % (amt, label))
print("    = %5d  expected" % acc)
print("      table=%d expected=%d  CLOSES: %s" % (total, acc, acc == total))

if acc != total:
    print()
    print("  MISMATCH. A row was added, removed, or re-numbered without")
    print("  updating the origin reconciliation. State the new origin here in")
    print("  the SAME commit -- an unexplained total is how parity silently stops")
    print("  meaning anything.")
    sys.exit(1)

print()
print("  Reserved-vs-real: the 36 for theme tty work claims groups no file")
print("  produces. The gate fails those rows under rule 3b by design -- a")
print("  reserved floor must fail rather than pass vacuously. `--tier=pty` is")
print("  therefore NOT green until that work lands.")
print("  OK")
PY
