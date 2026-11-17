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
    {"id": "U2", "index": 1, "title": "Sharing", "depends_on": [], "covers": ["AC2"], "scope": "Share links."},
    {"id": "U3", "index": 2, "title": "Picker", "depends_on": ["U1"], "covers": ["AC1", "AC3"], "scope": "UI."}
  ]
}
JSON

# run_drop_units <dropped.json> <unit-id>...: sets status, and the script's stdout
# and stderr in $work/out and $work/err.
run_drop_units() {
  local dropped=$1; shift
  status=0
  bash "$script" "$work/plan.json" "$dropped" "$@" >"$work/out" 2>"$work/err" || status=$?
}

# expect_plan <label> <jq filter true over the printed plan> <dropped.json> <unit-id>...
expect_plan() {
  local label=$1 filter=$2
  shift 2
  run_drop_units "$@"
  if [ "$status" != 0 ]; then fail "$label" "status $status: $(cat "$work/err")"; return; fi
  if jq -e "$filter" "$work/out" >/dev/null; then pass "$label"; else fail "$label" "$(cat "$work/out")"; fi
}

# expect_refusal <label> <stderr line> <dropped.json> <unit-id>...: exit 1, the
# line on stderr, nothing printed.
expect_refusal() {
  local label=$1 message=$2
  shift 2
  run_drop_units "$@"
  if [ "$status" != 1 ]; then fail "$label" "status $status"; return; fi
  if ! grep -qxF "$message" "$work/err"; then fail "$label" "stderr: $(cat "$work/err")"; return; fi
  if [ -s "$work/out" ]; then fail "$label" "printed: $(cat "$work/out")"; return; fi
  pass "$label"
}

# expect_dropped_file <label> <dropped.json> <expected compact JSON>
expect_dropped_file() {
  local actual
  actual=$(jq -c '.' "$2" 2>&1) || true
  if [ "$actual" = "$3" ]; then pass "$1"; else fail "$1" "$actual"; fi
}

expect_plan "drops an independent unit and its own criterion" \
  '[.units[].id] == ["U1","U3"] and [.criteria[].id] == ["AC1","AC3"]' "$work/d1.json" U2
expect_dropped_file "records the dropped unit" "$work/d1.json" '[{"id":"U2","reason":null}]'

printf '%s' '[{"id":"U9","reason":"earlier"}]' > "$work/d3.json"
expect_plan "appends to an existing dropped file" '[.units[].id] == ["U1","U3"]' "$work/d3.json" U2
expect_dropped_file "keeps the earlier entries" "$work/d3.json" '[{"id":"U9","reason":"earlier"},{"id":"U2","reason":null}]'

expect_refusal "refuses to drop a unit a remaining unit depends on" \
  'plan: U3 depends on dropped unit U1' "$work/d4.json" U1

expect_plan "drops a unit together with its dependent" \
  '[.units[].id] == ["U2"] and [.criteria[].id] == ["AC2"]' "$work/d5.json" U1 U3

expect_plan "keeps a criterion another remaining unit covers" \
  '[.criteria[].id] == ["AC1","AC2"]' "$work/d6.json" U3

expect_refusal "refuses to drop every unit" \
  'plan: every unit dropped; stop the run instead' "$work/d7.json" U1 U2 U3

expect_refusal "refuses an unknown unit id" 'plan: unknown unit U9' "$work/d8.json" U9
if [ -e "$work/d8.json" ]; then fail "a refusal writes no dropped file" "$(cat "$work/d8.json")"; else pass "a refusal writes no dropped file"; fi

# No unit id at all is a usage error.
status=0; bash "$script" "$work/plan.json" "$work/d10.json" >/dev/null 2>"$work/err" || status=$?
if [ "$status" = 2 ]; then pass "usage error without a unit id"; else fail "usage error" "status $status"; fi

echo "drop-units: $passes passed, $failures failed"
[ "$failures" = 0 ]
