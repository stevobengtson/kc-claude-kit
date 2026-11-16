#!/usr/bin/env bash
# Tests scripts/plan.sh: units, plan-wide criteria numbering, map.json, the
# plan passing validate-plan.sh, no ticket text, and refusals writing nothing.
# The refusal setups are command strings run by eval, so they stay single-quoted.
# shellcheck disable=SC2016
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(dirname "$tests_dir")
script="$plugin_dir/scripts/plan.sh"
validator="$(dirname "$plugin_dir")/kc-autopilot/scripts/validate-plan.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

# fresh_home: a FACTORY_HOME holding copies of the fixture jobs.
fresh_home() {
  local home=$1
  rm -rf "$home"
  mkdir -p "$home"
  cp -R "$tests_dir/fixtures/jobs" "$home/jobs"
}

home="$work/home"
fresh_home "$home"
run="$work/runs/run-42"
mkdir -p "$run"
status=0
out=$(FACTORY_HOME="$home" bash "$script" "$run" ABC-1 ABC-2 2>&1) || status=$?
if [ "$status" = 0 ]; then pass "plans two queued jobs"; else fail "plans two queued jobs" "status $status: $out"; fi

plan="$run/plan.md"
parsed=$(bash "$validator" "$plan" 2>&1) || { fail "plan passes validate-plan.sh" "$parsed"; parsed='{}'; }
if [ "$parsed" != '{}' ]; then pass "plan passes validate-plan.sh"; fi

check() { # <label> <jq filter that must be true over the parsed plan>
  if jq -e "$2" >/dev/null 2>&1 <<<"$parsed"; then pass "$1"; else fail "$1" "$(jq -c . <<<"$parsed")"; fi
}
check "title names the run and keys" '.title == "Factory run run-42: ABC-1, ABC-2"'
check "two units in key order" '[.units[].id] == ["U1","U2"]'
check "unit titles carry key and title (key alone when untitled)" '.units[0].title == "ABC-1 Show stock level on the product page" and .units[1].title == "ABC-2"'
check "criteria renumbered plan-wide" '(.criteria | length) == 5'
check "U1 covers AC1-AC2, U2 covers AC3-AC5" '.units[0].covers == ["AC1","AC2"] and .units[1].covers == ["AC3","AC4","AC5"]'
check "units are independent" '.units[0].depends_on == [] and .units[1].depends_on == []'
check "routing parsed on U1" '.units[0].routing == {"workers":"sonnet","personas":{"min":3,"max":4},"security":"workers"}'
check "routing parsed on U2" '.units[1].routing.workers == "best" and .units[1].routing.security == "staff"'
check "out of scope merged with key prefixes" '.out_of_scope == "- ABC-1: Changing the stock sync job.\n- ABC-1: Admin views.\n- ABC-2: Refund flows."'

if [ "$(jq -cS . "$run/map.json")" = '{"U1":{"criteria":{"AC1":1,"AC2":2},"key":"ABC-1"},"U2":{"criteria":{"AC3":1,"AC4":2,"AC5":3},"key":"ABC-2"}}' ]; then
  pass "map.json maps back to keys and local criteria"
else
  fail "map.json maps back to keys and local criteria" "$(cat "$run/map.json")"
fi

if grep -q "SENTINEL-TICKET-TEXT" "$plan"; then fail "no ticket.md text in plan" "sentinel found"; else pass "no ticket.md text in plan"; fi
if grep -q "https://example.atlassian.net/browse/ABC-2" "$plan" && grep -q "^### ABC-1" "$plan"; then
  pass "notes carry ticket URL under a key heading"
else
  fail "notes carry ticket URL under a key heading" "$(cat "$plan")"
fi
if grep -q "ABC-1: Show stock level on the product page" "$plan"; then pass "goal lists key and title"; else fail "goal lists key and title" "$(cat "$plan")"; fi

# refusal <label> <expected stderr> <setup command string run with $home> <keys...>
refusal() {
  local label=$1 message=$2 setup=$3 err st=0
  shift 3
  fresh_home "$home"
  rm -rf "$run"; mkdir -p "$run"
  eval "$setup"
  err=$(FACTORY_HOME="$home" bash "$script" "$run" "$@" 2>&1 >/dev/null) || st=$?
  if [ "$st" = 1 ] && [ "$err" = "$message" ] && [ ! -e "$run/plan.md" ] && [ ! -e "$run/map.json" ]; then
    pass "$label"
  else
    fail "$label" "status $st, stderr: $err"
  fi
}

refusal "refuses a job still in intake" "plan: ABC-1 is in intake, not queued" \
  'jq ".stage=\"intake\"" "$home/jobs/ABC-1/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/job.json"' ABC-1
refusal "refuses with a second bad job and writes nothing" "plan: ABC-2 is in blocked, not queued" \
  'jq ".stage=\"blocked\"" "$home/jobs/ABC-2/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-2/job.json"' ABC-1 ABC-2
refusal "refuses a missing intake.md" "plan: ABC-1 has no intake.md" 'rm "$home/jobs/ABC-1/intake.md"' ABC-1
refusal "refuses a missing routing.json" "plan: ABC-1 has no routing.json" 'rm "$home/jobs/ABC-1/routing.json"' ABC-1
refusal "refuses an unknown job" "plan: ABC-9 has no job" ':' ABC-9
refusal "refuses an intake with no criteria" "plan: ABC-1 intake has no acceptance criteria" \
  'grep -Ev "^[12]\. " "$home/jobs/ABC-1/intake.md" > "$work/i" && mv "$work/i" "$home/jobs/ABC-1/intake.md"' ABC-1

refusal "refuses an invalid job.json" "plan: ABC-1 job.json is not valid JSON" \
  'echo "{nope" > "$home/jobs/ABC-1/job.json"' ABC-1
refusal "refuses a key given twice" "plan: ABC-1 given twice" ':' ABC-1 ABC-2 ABC-1

# injected <label> <setup>: the plan still validates and has exactly the expected two units.
injected() {
  local label=$1 setup=$2 st=0 units
  fresh_home "$home"
  rm -rf "$run"; mkdir -p "$run"
  eval "$setup"
  FACTORY_HOME="$home" bash "$script" "$run" ABC-1 ABC-2 >/dev/null 2>&1 || st=$?
  units=$(grep -c '^### U' "$run/plan.md" 2>/dev/null || true)
  if [ "$st" = 0 ] && [ "$units" = 2 ] && bash "$validator" "$run/plan.md" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label" "status $st, unit headings $units"
  fi
}
set_scope() { # <first scope line>
  awk -v first="$1" '/^## Scope/ { print; print first; skip = 1; next } skip && NF { skip = 0 } { print }' \
    "$home/jobs/ABC-1/intake.md" > "$work/i" && mv "$work/i" "$home/jobs/ABC-1/intake.md"
}
injected "scope line shaped like a unit heading stays scope" 'set_scope "### U2: x"'
injected "scope line shaped like a Covers line stays scope" 'set_scope "- Covers: AC9"'
injected "scope line shaped like a Routing line stays scope" 'set_scope "- Routing: workers=bogus"'
injected "scope line shaped like a title stays scope" 'set_scope "# Other"'
injected "newline in a job title stays on one line" \
  'jq ".title=\"first\\n### U9: injected\"" "$home/jobs/ABC-1/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/job.json"'
# A newline in a routing field is flattened, so it is a bad model name the self-check refuses.
refusal "newline in a routing field is flattened and refused" "plan: generated plan is invalid:
plan: U1 routing workers must be haiku, sonnet, opus, best or a claude-* model id" \
  'jq ".workers=\"sonnet\\n### U9: injected\"" "$home/jobs/ABC-1/routing.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/routing.json"' ABC-1

# A routing value the validator rejects is caught by the self-check and writes nothing.
refusal "refuses a plan the validator rejects" "plan: generated plan is invalid:
plan: U1 routing workers must be haiku, sonnet, opus, best or a claude-* model id" \
  'jq ".workers=\"gpt\"" "$home/jobs/ABC-1/routing.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/routing.json"' ABC-1

status=0
bash "$script" "$run" >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "usage error exits 2"; else fail "usage error exits 2" "status $status"; fi

echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
