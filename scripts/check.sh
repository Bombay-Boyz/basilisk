#!/usr/bin/env bash
# Everything the project claims about itself, checked. Run locally
# before pushing; CI runs exactly this file, so the two cannot drift.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
step () { printf '\n=== %s\n' "$1"; }
bad  () { printf '  FAIL: %s\n' "$1"; fail=1; }
ok   () { printf '  ok: %s\n' "$1"; }

step "build (library, executable, tests, benchmarks) with zero warnings"
out=$(cabal build all --enable-tests --enable-benchmarks 2>&1) || { echo "$out" | tail -30; bad "build failed"; }
warnings=$(printf '%s' "$out" | grep -ci 'warning:' || true)
[ "$warnings" -eq 0 ] && ok "zero warnings" || { printf '%s' "$out" | grep -A4 -i 'warning:' | head -40; bad "$warnings warnings"; }

step "no partial functions in the pure core"
# Strip string literals and then trailing comments before matching, or
# prose beats the check: "no write since last change" and a Haddock
# "-- ^ the last search again" have both tripped it.
hits=$(cat src/Basilisk/*.hs app/Main.hs \
  | sed 's/"[^"]*"//g; s/--.*$//' \
  | grep -vE '^\s*$' \
  | grep -nE '\b(head|tail|init|last|fromJust|undefined|error)\b|!!|unsafePerformIO' || true)
[ -z "$hits" ] && ok "none" || { echo "$hits"; bad "partial function"; }

step "line-count ceiling"
# The same definition the handoff document reports, so the two agree.
loc=$(cat src/Basilisk/*.hs app/Main.hs | grep -vcE '^\s*(--|$)')
ceiling=3000
[ "$loc" -le "$ceiling" ] && ok "$loc / $ceiling" || bad "$loc exceeds the $ceiling-line ceiling"

step "test suites"
for suite in Basilisk-laws Basilisk-smoke Basilisk-exhaustive; do
  if LANG=C.UTF-8 cabal run -v0 "test:$suite" >/tmp/$suite.log 2>&1; then
    ok "$suite: $(tail -1 /tmp/$suite.log | sed 's/^ *//')"
  else
    tail -30 /tmp/$suite.log; bad "$suite"
  fi
done

step "complexity benchmarks"
if LANG=C.UTF-8 cabal run -v0 bench:Basilisk-scaling >/tmp/bench.log 2>&1; then
  ok "no scaling regression"
else
  cat /tmp/bench.log; bad "a scaling expectation was broken"
fi

step "the handoff document matches the sources"
# Part 3 is spliced from the source tree, so a stale document is a
# process failure rather than an editing mistake.
if command -v python3 >/dev/null; then
  cp Basilisk.md /tmp/Basilisk.prev.md 2>/dev/null || true
  python3 docgen.py >/dev/null 2>&1 || true
  if [ -f /tmp/Basilisk.prev.md ] && ! diff -q /tmp/Basilisk.prev.md Basilisk.md >/dev/null 2>&1; then
    bad "Basilisk.md is stale -- run python3 docgen.py"
  else
    ok "in sync"
  fi
fi

printf '\n'
[ "$fail" -eq 0 ] && { echo "ALL CHECKS PASSED"; exit 0; } || { echo "CHECKS FAILED"; exit 1; }
