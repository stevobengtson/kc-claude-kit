#!/usr/bin/env bash
# Tests scripts/apply-result.sh: done to ready with the PR, other outcomes to
# blocked with the reason, dropped.json winning, a missing unit blocked, and a
# job that is not delivering skipped without failing the rest.
# shellcheck disable=SC2016
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(dirname "$tests_dir")
script="$plugin_dir/scripts/apply-result.sh"
fx="$tests_dir/fixtures/transcripts"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

# fresh_home: a FACTORY_HOME with jobs ABC-1..ABC-4 all in the delivering stage.
fresh_home() {
  local home=$1 key
  rm -rf "$home"
  mkdir -p "$home/jobs"
  for key in ABC-1 ABC-2 ABC-3 ABC-4; do
    mkdir -p "$home/jobs/$key"
    jq -n --arg key "$key" '{key: $key, stage: "delivering", created_at: "2026-11-16T09:00:00Z", updated_at: "2026-11-16T09:00:00Z", history: []}' > "$home/jobs/$key/job.json"
  done
}
stage_of() { jq -r '.stage' "$1/jobs/$2/job.json"; }
field_of() { jq -r ".$3" "$1/jobs/$2/job.json"; }

home="$work/home"
fresh_home "$home"
run="$work/run"
mkdir -p "$run"
cp "$fx/map.json" "$fx/result.json" "$fx/dropped.json" "$run/"
status=0
out=$(FACTORY_HOME="$home" bash "$script" "$run" 2>"$work/err") || status=$?
if [ "$status" = 0 ]; then pass "applies a run"; else fail "applies a run" "status $status: $(cat "$work/err")"; fi

expected=$'ABC-1\tready\thttps://example.com/shop/pull/1\nABC-2\tblocked\tcheckout total wrong\nABC-3\tblocked\toverlaps U1 on the cart\nABC-4\tblocked\tno result from the autopilot run'
if [ "$out" = "$expected" ]; then pass "prints one line per unit in map order"; else fail "prints one line per unit in map order" "$out"; fi
if [ "$(stage_of "$home" ABC-1)" = ready ] && [ "$(field_of "$home" ABC-1 pr_url)" = "https://example.com/shop/pull/1" ]; then pass "done unit is ready with its PR"; else fail "done unit is ready with its PR" "$(cat "$home/jobs/ABC-1/job.json")"; fi
if [ "$(stage_of "$home" ABC-2)" = blocked ] && [ "$(field_of "$home" ABC-2 reason)" = "checkout total wrong" ]; then pass "blocked unit is blocked with its reason"; else fail "blocked unit is blocked with its reason" "$(cat "$home/jobs/ABC-2/job.json")"; fi
if [ "$(stage_of "$home" ABC-3)" = blocked ] && [ "$(field_of "$home" ABC-3 reason)" = "overlaps U1 on the cart" ]; then pass "dropped unit is blocked with the plan-conflict reason and beats its done result"; else fail "dropped unit is blocked with the plan-conflict reason and beats its done result" "$(cat "$home/jobs/ABC-3/job.json")"; fi
if [ "$(stage_of "$home" ABC-4)" = blocked ] && [ "$(field_of "$home" ABC-4 reason)" = "no result from the autopilot run" ]; then pass "unit missing from both files is blocked"; else fail "unit missing from both files is blocked" "$(cat "$home/jobs/ABC-4/job.json")"; fi
if jq -e 'length == 4' "$home/jobs/index.json" >/dev/null 2>&1; then pass "writes go through job.sh (index rewritten)"; else fail "writes go through job.sh (index rewritten)" "no index"; fi

# The PR or reason is recorded before the stage moves: a set that fails leaves
# the job delivering, so a rerun applies it again rather than leaving a ready
# job with no pr_url. job.sh is swapped for one whose set always fails.
fresh_home "$home"
mkdir -p "$work/failing-set/scripts"
cp "$script" "$work/failing-set/scripts/apply-result.sh"
printf '#!/usr/bin/env bash\n[ "$1" != set ] || { echo "job: disk full" >&2; exit 1; }\nexec bash %q "$@"\n' "$plugin_dir/scripts/job.sh" > "$work/failing-set/scripts/job.sh"
status=0
FACTORY_HOME="$home" bash "$work/failing-set/scripts/apply-result.sh" "$run" >/dev/null 2>&1 || status=$?
if [ "$status" != 0 ] && [ "$(stage_of "$home" ABC-1)" = delivering ] && [ "$(stage_of "$home" ABC-2)" = delivering ]; then
  pass "a failing set leaves the stage unchanged"
else
  fail "a failing set leaves the stage unchanged" "status $status, ABC-1 $(stage_of "$home" ABC-1), ABC-2 $(stage_of "$home" ABC-2)"
fi

# No dropped.json: treated as empty, so U3 is done.
fresh_home "$home"
rm "$run/dropped.json"
out=$(FACTORY_HOME="$home" bash "$script" "$run" 2>/dev/null) || true
if [ "$(stage_of "$home" ABC-3)" = ready ]; then pass "absent dropped.json means nothing dropped"; else fail "absent dropped.json means nothing dropped" "$out"; fi

# A job not delivering is skipped with a warning; the rest still apply.
fresh_home "$home"
cp "$fx/dropped.json" "$run/"
jq '.stage = "queued"' "$home/jobs/ABC-1/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/job.json"
status=0
out=$(FACTORY_HOME="$home" bash "$script" "$run" 2>"$work/err") || status=$?
if [ "$status" = 0 ] && [ "$(stage_of "$home" ABC-1)" = queued ] && [ "$(stage_of "$home" ABC-2)" = blocked ] && grep -q "skipping ABC-1" "$work/err" && ! grep -q '^ABC-1' <<<"$out"; then
  pass "skips a job that is not delivering and applies the rest"
else
  fail "skips a job that is not delivering and applies the rest" "status $status out=$out err=$(cat "$work/err")"
fi

# --no-result: the run ended with no result.json, so every unit not dropped is blocked.
fresh_home "$home"
rm -rf "$work/noresult"; mkdir -p "$work/noresult"
cp "$fx/map.json" "$fx/dropped.json" "$work/noresult/"
status=0
out=$(FACTORY_HOME="$home" bash "$script" "$work/noresult" --no-result 2>"$work/err") || status=$?
if [ "$status" = 0 ] && [ "$(stage_of "$home" ABC-1)" = blocked ] && [ "$(field_of "$home" ABC-1 reason)" = "no result from the autopilot run" ] \
  && [ "$(field_of "$home" ABC-3 reason)" = "overlaps U1 on the cart" ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 4 ]; then
  pass "--no-result blocks every unit, keeping dropped reasons"
else
  fail "--no-result blocks every unit, keeping dropped reasons" "status $status out=$out err=$(cat "$work/err")"
fi
cp "$fx/result.json" "$work/noresult/"
status=0
err=$(FACTORY_HOME="$home" bash "$script" "$work/noresult" --no-result 2>&1 >/dev/null) || status=$?
if [ "$status" = 1 ] && [ "$err" = "apply-result: --no-result given but $work/noresult/result.json exists" ]; then
  pass "--no-result refuses when result.json exists"
else
  fail "--no-result refuses when result.json exists" "status $status, err $err"
fi
status=0
bash "$script" "$run" --bogus >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "unknown flag exits 2"; else fail "unknown flag exits 2" "status $status"; fi

# Refusals.
status=0
FACTORY_HOME="$home" bash "$script" "$work/nowhere" >/dev/null 2>"$work/err" || status=$?
if [ "$status" = 1 ] && grep -q '^apply-result: ' "$work/err"; then pass "missing run files exit 1"; else fail "missing run files exit 1" "status $status"; fi
status=0
bash "$script" >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "usage error exits 2"; else fail "usage error exits 2" "status $status"; fi

echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
