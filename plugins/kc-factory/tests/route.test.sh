#!/usr/bin/env bash
# Tests scripts/route.sh: risk rows, surface overlays, routing.json, the
# printed Routing line, and refusals on a bad intake header.
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(dirname "$tests_dir")
script="$plugin_dir/scripts/route.sh"
validator="$(dirname "$plugin_dir")/kc-autopilot/scripts/validate-plan.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

bash "$plugin_dir/scripts/read-config.sh" "$tests_dir/fixtures/config/minimal.json" > "$work/config.json"

# intake <dir> <header lines...>: a job dir whose intake.md starts with them.
intake() {
  local dir=$1
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$@" '' 'Some reasoning follows.' > "$dir/intake.md"
}

# expect_route <label> <config> <expected line> <expected routing.json> <header lines...>
expect_route() {
  local label=$1 config=$2 line=$3 json=$4 dir="$work/job-$1" out status=0
  shift 4
  intake "$dir" "$@"
  out=$(bash "$script" "$dir" "$config" 2>&1) || status=$?
  if [ "$status" = 0 ] && [ "$out" = "$line" ] && [ "$(jq -cS . "$dir/routing.json")" = "$(jq -cS . <<<"$json")" ]; then
    pass "$label"
  else
    fail "$label" "status $status, out: $out, routing.json: $(cat "$dir/routing.json" 2>/dev/null)"
  fi
}

# expect_refusal <label> <expected stderr line> <header lines...>
expect_refusal() {
  local label=$1 message=$2 dir="$work/job-$1" err status=0
  shift 2
  intake "$dir" "$@"
  err=$(bash "$script" "$dir" "$work/config.json" 2>&1 >/dev/null) || status=$?
  if [ "$status" = 1 ] && [ "$err" = "$message" ] && [ ! -e "$dir/routing.json" ]; then
    pass "$label"
  else
    fail "$label" "status $status, stderr: $err"
  fi
}

expect_route "low, no surfaces" "$work/config.json" \
  "- Routing: workers=sonnet; personas=2-3; security=workers" \
  '{"risk":"low","surfaces":[],"workers":"sonnet","personas":{"min":2,"max":3},"security":"workers"}' \
  "DECISION: ACCEPT" "RISK: low" "SURFACES: none"

expect_route "high" "$work/config.json" \
  "- Routing: workers=best; personas=4-5; security=staff" \
  '{"risk":"high","surfaces":[],"workers":"best","personas":{"min":4,"max":5},"security":"staff"}' \
  "DECISION: ACCEPT" "RISK: high" "SURFACES: none"

expect_route "medium plus security surface forces staff" "$work/config.json" \
  "- Routing: workers=sonnet; personas=3-4; security=staff" \
  '{"risk":"medium","surfaces":["security"],"workers":"sonnet","personas":{"min":3,"max":4},"security":"staff"}' \
  "DECISION: ACCEPT" "RISK: medium" "SURFACES: security"

expect_route "surface without an overlay is kept and changes nothing" "$work/config.json" \
  "- Routing: workers=sonnet; personas=2-3; security=workers" \
  '{"risk":"low","surfaces":["ui","data"],"workers":"sonnet","personas":{"min":2,"max":3},"security":"workers"}' \
  "DECISION: ACCEPT" "RISK: low" "SURFACES: ui, data"

expect_route "surface names are lowercased and trimmed" "$work/config.json" \
  "- Routing: workers=sonnet; personas=2-3; security=staff" \
  '{"risk":"low","surfaces":["ui","security"],"workers":"sonnet","personas":{"min":2,"max":3},"security":"staff"}' \
  "DECISION: ACCEPT" "RISK: low" "SURFACES:   UI ,  Security  "

jq '.routing.low = {workers: "opus", personas: {min: 1, max: 6}, security: "staff"}
    | .routing.surfaces.payments = {workers: "best", personas: {min: 5, max: 6}}' \
  "$work/config.json" > "$work/custom.json"

expect_route "a custom config row is honoured" "$work/custom.json" \
  "- Routing: workers=opus; personas=1-6; security=staff" \
  '{"risk":"low","surfaces":[],"workers":"opus","personas":{"min":1,"max":6},"security":"staff"}' \
  "DECISION: ACCEPT" "RISK: low" "SURFACES: none"

expect_route "a custom surface overlay changes only the keys it names" "$work/custom.json" \
  "- Routing: workers=best; personas=5-6; security=staff" \
  '{"risk":"low","surfaces":["payments"],"workers":"best","personas":{"min":5,"max":6},"security":"staff"}' \
  "DECISION: ACCEPT" "RISK: low" "SURFACES: payments"

expect_refusal "unknown risk" "route: unknown risk: extreme" \
  "DECISION: ACCEPT" "RISK: extreme" "SURFACES: none"
expect_refusal "missing RISK line" "route: intake.md has no RISK line" \
  "DECISION: ACCEPT" "SURFACES: none"

status=0
err=$(bash "$script" "$work/nowhere" "$work/config.json" 2>&1 >/dev/null) || status=$?
if [ "$status" = 1 ] && [ "$err" = "route: $work/nowhere/intake.md not found" ]; then
  pass "missing intake.md"
else
  fail "missing intake.md" "status $status, stderr: $err"
fi

status=0
bash "$script" >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "no arguments is a usage error"; else fail "no arguments is a usage error" "status $status"; fi

# The printed line must parse as a plan unit's Routing line.
dir="$work/job-plan"
intake "$dir" "DECISION: ACCEPT" "RISK: high" "SURFACES: security"
line=$(bash "$script" "$dir" "$work/config.json")
cat > "$work/plan.md" <<PLAN
# Shop plan

## Goal
Shoppers see their orders.

## Acceptance criteria
1. The orders page lists a shopper's orders.

## Work units
### U1: Orders page
- Depends on: none
- Covers: AC1
$line
List the orders.

## Out of scope
- Refunds.
PLAN
status=0
parsed=$(bash "$validator" "$work/plan.md" 2>"$work/plan.err") || status=$?
expected=$(jq -c '{workers, personas, security}' "$dir/routing.json")
if [ "$status" = 0 ] && [ "$(jq -c '.units[0].routing' <<<"$parsed")" = "$expected" ]; then
  pass "the printed line parses in a valid plan and matches routing.json"
else
  fail "the printed line parses in a valid plan and matches routing.json" "status $status, got $(jq -c '.units[0].routing' <<<"$parsed" 2>/dev/null), stderr: $(cat "$work/plan.err")"
fi

echo
echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
