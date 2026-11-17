#!/usr/bin/env bash
# Tests scripts/same-risky-paths.sh: a run config passes only when it guards the
# same risky_paths as the repo's config, which is the one guard.sh reads.
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
script="$(dirname "$tests_dir")/scripts/same-risky-paths.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

# expect_check <label> <expected exit> <run config JSON> <repo config JSON>
expect_check() {
  local label=$1 want=$2 status=0
  printf '%s' "$3" > "$work/run.json"
  printf '%s' "$4" > "$work/repo.json"
  bash "$script" "$work/run.json" "$work/repo.json" >/dev/null 2>"$work/err" || status=$?
  if [ "$status" = "$want" ]; then pass "$label"; else fail "$label" "exit $status: $(cat "$work/err")"; fi
}

expect_check "same risky_paths pass" 0 \
  '{"limits":{"max_parallel_units":2},"risky_paths":["db/migrate/**"]}' '{"limits":{"max_parallel_units":4},"risky_paths":["db/migrate/**"]}'
expect_check "neither lists risky_paths" 0 '{"limits":{}}' '{"limits":{}}'
expect_check "a run config with fewer paths is refused" 1 '{"risky_paths":[]}' '{"risky_paths":["db/migrate/**"]}'
expect_check "a run config with other paths is refused" 1 '{"risky_paths":["docs/**"]}' '{"risky_paths":["db/migrate/**"]}'
expect_check "a run config with no list against a repo list is refused" 1 '{}' '{"risky_paths":["db/migrate/**"]}'
expect_check "a run config that is not JSON is refused" 1 'nope' '{}'

expect_check "the message names the repo config" 1 '{"risky_paths":[]}' '{"risky_paths":["x"]}'
if grep -q "the guard reads only $work/repo.json" "$work/err"; then pass "refusal says which file the guard reads"; else fail "refusal says which file the guard reads" "$(cat "$work/err")"; fi

status=0
bash "$script" "$work/run.json" >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "usage error exits 2"; else fail "usage error exits 2" "status $status"; fi

echo "same-risky-paths: $passes passed, $failures failed"
[ "$failures" = 0 ]
