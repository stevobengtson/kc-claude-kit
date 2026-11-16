#!/usr/bin/env bash
# Tests scripts/drop-units.sh: /kc-autopilot:kc-run drops only the units a design
# objection concerns and carries on with the rest. The script prints the plan JSON
# without those units (and without criteria only they cover) and records each in
# the dropped file. Fixture: a three-unit plan JSON, U2 independent, U3 on U1.
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(dirname "$tests_dir")
script="$plugin_dir/scripts/drop-units.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

cat > "$work/plan.json" <<'JSON'
{
  "title": "Saved replies",
  "goal": "Agents can save a reply and reuse it.",
  "criteria": [
    {"id": "AC1", "statement": "A saved reply can be stored."},
    {"id": "AC2", "statement": "A saved reply can be shared."},
    {"id": "AC3", "statement": "A saved reply can be picked."}
  ],
  "units": [
    {"id": "U1", "index": 0, "title": "Storage", "depends_on": [], "covers": ["AC1"], "scope": "Model."},
    {"id": "U2", "index": 1, "title": "Sharing", "depends_on": [], "covers": ["AC2"], "scope": "Share links.",
     "routing": {"workers": "best", "personas": {"min": 4, "max": 5}, "security": "staff"}},
    {"id": "U3", "index": 2, "title": "Picker", "depends_on": ["U1"], "covers": ["AC1", "AC3"], "scope": "UI."}
  ]
}
JSON

# run <dropped.json> <unit-id>...: sets status, out (stdout) and err (stderr).
run() {
  local dropped=$1; shift
  status=0
  bash "$script" "$work/plan.json" "$dropped" "$@" >"$work/out" 2>"$work/err" || status=$?
}

# Dropping an independent unit keeps the others and the criteria they cover.
run "$work/d1.json" U2
if [ "$status" = 0 ] \
  && [ "$(jq -c '[.units[].id]' "$work/out")" = '["U1","U3"]' ] \
  && [ "$(jq -c '[.criteria[].id]' "$work/out")" = '["AC1","AC3"]' ] \
  && [ "$(jq -c '.' "$work/d1.json")" = '[{"id":"U2","reason":null}]' ]; then
  pass "drops an independent unit, its own criterion and records it"
else
  fail "drops an independent unit" "status $status, out: $(cat "$work/out"), dropped: $(cat "$work/d1.json" 2>&1)"
fi

printf '%s' '[{"id":"U9","reason":"earlier"}]' > "$work/d3.json"
run "$work/d3.json" U2
if [ "$status" = 0 ] && [ "$(jq -c '.' "$work/d3.json")" = '[{"id":"U9","reason":"earlier"},{"id":"U2","reason":null}]' ]; then
  pass "appends to an existing dropped file"
else
  fail "appends to an existing dropped file" "status $status, dropped: $(cat "$work/d3.json")"
fi

# Dropping a unit another unit depends on is refused.
run "$work/d4.json" U1
if [ "$status" = 1 ] && grep -qxF 'plan: U3 depends on dropped unit U1' "$work/err" && [ ! -s "$work/out" ]; then
  pass "refuses to drop a unit a remaining unit depends on"
else
  fail "refuses to drop a depended-on unit" "status $status, err: $(cat "$work/err")"
fi

# Dropping the dependent together with its dependency is fine.
run "$work/d5.json" U1 U3
if [ "$status" = 0 ] && [ "$(jq -c '[.units[].id]' "$work/out")" = '["U2"]' ] && [ "$(jq -c '[.criteria[].id]' "$work/out")" = '["AC2"]' ]; then
  pass "drops a unit together with its dependent"
else
  fail "drops a unit together with its dependent" "status $status, out: $(cat "$work/out")"
fi

# A partly covered criterion stays when a remaining unit still covers it.
run "$work/d6.json" U3
if [ "$status" = 0 ] && [ "$(jq -c '[.criteria[].id]' "$work/out")" = '["AC1","AC2"]' ]; then
  pass "keeps a criterion another remaining unit covers"
else
  fail "keeps a shared criterion" "status $status, out: $(cat "$work/out")"
fi

# Dropping every unit is refused.
run "$work/d7.json" U1 U2 U3
if [ "$status" = 1 ] && grep -qxF 'plan: every unit dropped; stop the run instead' "$work/err" && [ ! -s "$work/out" ]; then
  pass "refuses to drop every unit"
else
  fail "refuses to drop every unit" "status $status, err: $(cat "$work/err")"
fi

# An unknown id is refused and leaves the dropped file alone.
run "$work/d8.json" U9
if [ "$status" = 1 ] && grep -qxF 'plan: unknown unit U9' "$work/err" && [ ! -e "$work/d8.json" ]; then
  pass "refuses an unknown unit id"
else
  fail "refuses an unknown unit id" "status $status, err: $(cat "$work/err")"
fi

# Routing on remaining units is carried through untouched.
run "$work/d9.json" U3
if [ "$status" = 0 ] && [ "$(jq -c '.units[] | select(.id == "U2") | .routing.personas' "$work/out")" = '{"min":4,"max":5}' ]; then
  pass "keeps routing on remaining units"
else
  fail "keeps routing on remaining units" "status $status, out: $(cat "$work/out")"
fi

# No unit id at all is a usage error.
status=0; bash "$script" "$work/plan.json" "$work/d10.json" >/dev/null 2>"$work/err" || status=$?
if [ "$status" = 2 ]; then pass "usage error without a unit id"; else fail "usage error" "status $status"; fi

echo "drop-units: $passes passed, $failures failed"
[ "$failures" = 0 ]
