#!/usr/bin/env bash
# Run every offline test suite. Never runs the live guards (snapshot.sh, verify.sh,
# dictation-smoke.sh) against the real HOME: those are run by hand, with Ben present.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
failed=0

run_suite() {
  local name="$1"; shift
  echo "== $name"
  if "$@"; then echo "== $name: ok"; else echo "== $name: FAIL"; failed=1; fi
}

run_suite "guard selftest" bash "$repo/notetaker/tests/guard/selftest.sh"

if command -v lua >/dev/null 2>&1 && [ -f "$repo/notetaker/mac/tests/run.lua" ]; then
  run_suite "lua tests" bash -c 'cd "$1" && lua notetaker/mac/tests/run.lua' _ "$repo"
else
  echo "== lua tests: skipped (no lua or no notetaker/mac/tests/run.lua)"
fi

if [ -d "$repo/notetaker/worker/node_modules" ]; then
  run_suite "worker tests" bash -c 'cd "$1/notetaker/worker" && npm test' _ "$repo"
else
  echo "== worker tests: skipped (no notetaker/worker/node_modules)"
fi

[ "$failed" -eq 0 ]
