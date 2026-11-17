#!/usr/bin/env bash
# Tests scripts/plan.sh, and through it the intake-format.sh and factory-home.sh it sources: units, plan-wide criteria numbering, map.json, the
# plan passing validate-plan.sh, no ticket text, and refusals writing nothing.
# The expect_refusal setups are command strings run by eval, so they stay single-quoted.
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
check "unit titles carry key and intake's title (key alone without one)" '.units[0].title == "ABC-1 Show stock level on the product page" and .units[1].title == "ABC-2"'
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
if grep -q "SENTINEL-JIRA-TITLE" "$plan"; then fail "no tracker title (job.json title) in plan" "sentinel found"; else pass "no tracker title (job.json title) in plan"; fi
if grep -q "https://example.atlassian.net/browse/ABC-2" "$plan" && grep -q "^### ABC-1" "$plan"; then
  pass "notes carry ticket URL under a key heading"
else
  fail "notes carry ticket URL under a key heading" "$(cat "$plan")"
fi
if grep -qx -- "- ABC-1: Show stock level on the product page" "$plan" && grep -qx -- "- ABC-2" "$plan"; then
  pass "goal lists key and intake's title, the key alone without one"
else
  fail "goal lists key and intake's title, the key alone without one" "$(cat "$plan")"
fi

# expect_refusal <label> <expected stderr> <setup command string run with $home> <keys...>
expect_refusal() {
  local label=$1 message=$2 setup=$3 err st=0
  shift 3
  fresh_home "$home"
  rm -rf "$run"; mkdir -p "$run"
  eval "$setup"
  err=$(FACTORY_HOME="$home" bash "$script" "$run" "$@" 2>&1 >/dev/null) || st=$?
  if [ "$st" != 1 ] || [ "$err" != "$message" ]; then fail "$label" "status $st, stderr: $err"; return; fi
  if [ -e "$run/plan.md" ] || [ -e "$run/map.json" ]; then fail "$label" "a refusal wrote $(ls "$run")"; return; fi
  pass "$label"
}

expect_refusal "refuses a job still in intake" "plan: ABC-1 is in intake, not queued" \
  'jq ".stage=\"intake\"" "$home/jobs/ABC-1/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/job.json"' ABC-1
expect_refusal "refuses with a second bad job and writes nothing" "plan: ABC-2 is in blocked, not queued" \
  'jq ".stage=\"blocked\"" "$home/jobs/ABC-2/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-2/job.json"' ABC-1 ABC-2
expect_refusal "refuses a missing intake.md" "plan: ABC-1 has no intake.md" 'rm "$home/jobs/ABC-1/intake.md"' ABC-1
expect_refusal "refuses a missing routing.json" "plan: ABC-1 has no routing.json" 'rm "$home/jobs/ABC-1/routing.json"' ABC-1
expect_refusal "refuses an unknown job" "plan: ABC-9 has no job" ':' ABC-9
expect_refusal "refuses an intake with no criteria" "plan: ABC-1 intake has no acceptance criteria" \
  'grep -Ev "^[12]\. " "$home/jobs/ABC-1/intake.md" > "$work/i" && mv "$work/i" "$home/jobs/ABC-1/intake.md"' ABC-1

expect_refusal "refuses an invalid job.json" "plan: ABC-1 job.json is not valid JSON" \
  'echo "{nope" > "$home/jobs/ABC-1/job.json"' ABC-1
expect_refusal "refuses a key given twice" "plan: ABC-1 given twice" ':' ABC-1 ABC-2 ABC-1

# expect_injection_neutralized <label> <setup>: the plan still validates and has exactly the expected two units.
expect_injection_neutralized() {
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
expect_injection_neutralized "scope line shaped like a unit heading stays scope" 'set_scope "### U2: x"'
expect_injection_neutralized "scope line shaped like a Covers line stays scope" 'set_scope "- Covers: AC9"'
expect_injection_neutralized "scope line shaped like a Routing line stays scope" 'set_scope "- Routing: workers=bogus"'
expect_injection_neutralized "scope line shaped like a title stays scope" 'set_scope "# Other"'
set_title() { # <title section body>
  BODY=$1 awk '/^## Title/ { print; print ENVIRON["BODY"]; skip = 1; next } skip && /^## / { skip = 0 } skip { next } { print }' \
    "$home/jobs/ABC-1/intake.md" > "$work/i" && mv "$work/i" "$home/jobs/ABC-1/intake.md"
}
expect_injection_neutralized "a second Title line shaped like a unit heading is not used" 'set_title "first
### U9: injected"'
expect_injection_neutralized "a job.json title with a newline is never read" \
  'jq ".title=\"first\\n### U9: injected\"" "$home/jobs/ABC-1/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/job.json"'
# A newline in the Routing line is flattened, so it is a bad model name the self-check refuses.
expect_refusal "newline in the Routing line is flattened and refused" "plan: generated plan is invalid:
plan: U1 routing workers must be haiku, sonnet, opus, best or a claude-* model id" \
  'jq ".line=\"- Routing: workers=sonnet\\n### U9: injected\"" "$home/jobs/ABC-1/routing.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/routing.json"' ABC-1

# A Routing line the validator rejects is caught by the self-check and writes nothing.
expect_refusal "refuses a plan the validator rejects" "plan: generated plan is invalid:
plan: U1 routing workers must be haiku, sonnet, opus, best or a claude-* model id" \
  'jq ".line=\"- Routing: workers=gpt; personas=3-4; security=workers\"" "$home/jobs/ABC-1/routing.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/routing.json"' ABC-1
expect_refusal "refuses a routing.json with no Routing line" "plan: ABC-1 routing.json has no Routing line" \
  'jq "del(.line)" "$home/jobs/ABC-1/routing.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/routing.json"' ABC-1

# A resumed job: every feedback-<n>.md (oldest first) and the earlier branch go
# into its unit's Scope line, flattened, which deliver.js sends to every worker.
expect_resumed_scope() { # <label> <expected U1 scope> <setup>
  local label=$1 want=$2 st=0 got
  fresh_home "$home"
  rm -rf "$run"; mkdir -p "$run"
  eval "$3"
  FACTORY_HOME="$home" bash "$script" "$run" ABC-1 ABC-2 >/dev/null 2>&1 || st=$?
  got=$(bash "$validator" "$run/plan.md" 2>/dev/null | jq -r '.units[0].scope' 2>/dev/null || true)
  if [ "$st" = 0 ] && [ "$got" = "$want" ] && [ "$(grep -c '^### U' "$run/plan.md")" = 2 ]; then pass "$label"; else fail "$label" "status $st, U1 scope: $got"; fi
}
base_scope="- Scope: Show the remaining stock count on the product page of the storefront. Hide it when the count is above 50."
set_branch() { jq --arg b "$1" '.branch = $b' "$home/jobs/ABC-1/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/job.json"; }
expect_resumed_scope "feedback, oldest first, and the earlier branch join the unit's scope" \
  "$base_scope Feedback from the reviewer: Use the cached stock count. Not the live one. Also hide it for bundles. An earlier attempt is on branch abc-1-stock-level; start from its commits where they are sound." \
  'printf "Use the cached stock count.\nNot the live one.\n" > "$home/jobs/ABC-1/feedback-1.md"; echo "Also hide it for bundles." > "$home/jobs/ABC-1/feedback-2.md"; set_branch abc-1-stock-level'
expect_resumed_scope "feedback with no earlier branch leaves the branch sentence out" \
  "$base_scope Feedback from the reviewer: Use the cached stock count." \
  'echo "Use the cached stock count." > "$home/jobs/ABC-1/feedback-1.md"'
expect_resumed_scope "a feedback line shaped like a unit heading stays in the scope" \
  "$base_scope Feedback from the reviewer: fine ### U9: injected - Covers: AC9" \
  'printf "fine\n### U9: injected\n- Covers: AC9\n" > "$home/jobs/ABC-1/feedback-1.md"'
expect_resumed_scope "a branch with no feedback adds nothing" "$base_scope" 'set_branch abc-1-stock-level'
expect_refusal "refuses a branch name that is not a plain ref" "plan: ABC-1 branch is not a plain branch name" \
  'echo "x" > "$home/jobs/ABC-1/feedback-1.md"; set_branch "x; rm -rf /"' ABC-1

# KC_AUTOPILOT_ROOT names the autopilot install whose validator the self-check runs
# (installed plugins sit in versioned cache dirs, not side by side).
mkdir -p "$work/fake-autopilot/scripts"
printf '#!/usr/bin/env bash\necho "plan: fake validator ran" >&2\nexit 1\n' > "$work/fake-autopilot/scripts/validate-plan.sh"
fresh_home "$home"
rm -rf "$run"; mkdir -p "$run"
status=0
err=$(KC_AUTOPILOT_ROOT="$work/fake-autopilot" FACTORY_HOME="$home" bash "$script" "$run" ABC-1 2>&1 >/dev/null) || status=$?
if [ "$status" = 1 ] && [ "$err" = "plan: generated plan is invalid:
plan: fake validator ran" ] && [ ! -e "$run/plan.md" ]; then
  pass "KC_AUTOPILOT_ROOT picks the validator the self-check runs"
else
  fail "KC_AUTOPILOT_ROOT picks the validator the self-check runs" "status $status, stderr: $err"
fi
status=0
err=$(KC_AUTOPILOT_ROOT="$work/no-such-autopilot" FACTORY_HOME="$home" bash "$script" "$run" ABC-1 2>&1 >/dev/null) || status=$?
if [ "$status" = 1 ] && [ "$err" = "plan: kc-autopilot has no scripts/validate-plan.sh: $work/no-such-autopilot" ]; then
  pass "a KC_AUTOPILOT_ROOT without the validator is refused"
else
  fail "a KC_AUTOPILOT_ROOT without the validator is refused" "status $status, stderr: $err"
fi

# A criterion or out-of-scope bullet that wraps onto a second line keeps its continuation.
fresh_home "$home"
rm -rf "$run"; mkdir -p "$run"
awk '/^1\. / { print "1. The product page shows \"Only N left\""; print "   when stock is 50 or fewer."; next }
     /^- Admin views\./ { print "- Admin views and the"; print "  stock report."; next } { print }' \
  "$home/jobs/ABC-1/intake.md" > "$work/i" && mv "$work/i" "$home/jobs/ABC-1/intake.md"
FACTORY_HOME="$home" bash "$script" "$run" ABC-1 >/dev/null 2>&1 || true
wrapped=$(bash "$validator" "$run/plan.md" 2>/dev/null || echo '{}')
if [ "$(jq -r '.criteria[0].statement' <<<"$wrapped")" = 'The product page shows "Only N left" when stock is 50 or fewer.' ]; then
  pass "a wrapped criterion keeps its second line"
else
  fail "a wrapped criterion keeps its second line" "$(jq -c '.criteria' <<<"$wrapped")"
fi
if grep -qxF -- "- ABC-1: Admin views and the stock report." "$run/plan.md"; then
  pass "a wrapped out-of-scope bullet keeps its second line"
else
  fail "a wrapped out-of-scope bullet keeps its second line" "$(grep -- '- ABC-1' "$run/plan.md")"
fi

# With no KC_AUTOPILOT_ROOT and no kc-autopilot to find, nothing is written unchecked.
mkdir -p "$work/lone/kc-factory"
cp -R "$plugin_dir/scripts" "$work/lone/kc-factory/scripts"
rm "$work/lone/kc-factory/scripts/plugin-root.sh"
cp "$(dirname "$plugin_dir")/kc-autopilot/scripts/plugin-root.sh" "$work/lone/kc-factory/scripts/plugin-root.sh"
fresh_home "$home"
rm -rf "$run"; mkdir -p "$run"
status=0
err=$(cd "$work" && CLAUDE_CONFIG_DIR="$work/no-config" FACTORY_HOME="$home" bash "$work/lone/kc-factory/scripts/plan.sh" "$run" ABC-1 2>&1 >/dev/null) || status=$?
if [ "$status" = 1 ] && [ "$err" = "plan: cannot find kc-autopilot to check the plan; install it or set KC_AUTOPILOT_ROOT" ] && [ ! -e "$run/plan.md" ]; then
  pass "no kc-autopilot to check with refuses and writes nothing"
else
  fail "no kc-autopilot to check with refuses and writes nothing" "status $status, stderr: $err"
fi

status=0
bash "$script" "$run" >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "usage error exits 2"; else fail "usage error exits 2" "status $status"; fi

echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
