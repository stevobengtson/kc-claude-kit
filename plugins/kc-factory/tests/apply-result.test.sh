#!/usr/bin/env bash
# Tests scripts/apply-result.sh: done with a PR to ready, every other outcome to
# blocked with a non-empty reason, dropped.json winning, a missing unit blocked,
# the branch recorded, and a job that is not delivering this run skipped without
# failing the rest.
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

# fresh_home <home> <run_id>: jobs ABC-1..ABC-4, all delivering that run.
fresh_home() {
  local home=$1 run_id=$2 key
  rm -rf "$home"
  mkdir -p "$home/jobs"
  for key in ABC-1 ABC-2 ABC-3 ABC-4; do
    mkdir -p "$home/jobs/$key"
    jq -n --arg key "$key" --arg run "$run_id" \
      '{key: $key, stage: "delivering", run_id: $run, created_at: "2026-11-16T09:00:00Z", updated_at: "2026-11-16T09:00:00Z", history: []}' \
      > "$home/jobs/$key/job.json"
  done
}
read_job_field() { jq -r ".$3 // \"\"" "$1/jobs/$2/job.json"; }

# expect_job <label> <home> <key> <stage> <field> <value>
expect_job() {
  local stage field_value
  stage=$(read_job_field "$2" "$3" stage)
  field_value=$(read_job_field "$2" "$3" "$5")
  if [ "$stage" != "$4" ]; then fail "$1" "stage $stage: $(cat "$2/jobs/$3/job.json")"; return; fi
  if [ "$field_value" != "$6" ]; then fail "$1" "$5 is '$field_value': $(cat "$2/jobs/$3/job.json")"; return; fi
  pass "$1"
}

# apply <home> <run-dir> [--no-result]: sets status, out and $work/err.
apply() {
  local home=$1
  shift
  status=0
  out=$(FACTORY_HOME="$home" bash "$script" "$@" 2>"$work/err") || status=$?
}

home="$work/home"
run="$work/run"
mkdir -p "$run"
cp "$fx/map.json" "$fx/result.json" "$fx/dropped.json" "$run/"
fresh_home "$home" run
apply "$home" "$run"
if [ "$status" = 0 ]; then pass "applies a run"; else fail "applies a run" "status $status: $(cat "$work/err")"; fi

expected=$'ABC-1\tready\thttps://example.com/shop/pull/1\nABC-2\tblocked\tcheckout total wrong\nABC-3\tblocked\toverlaps U1 on the cart\nABC-4\tblocked\tno result from the autopilot run'
if [ "$out" = "$expected" ]; then pass "prints one line per unit in map order"; else fail "prints one line per unit in map order" "$out"; fi
expect_job "done unit is ready with its PR" "$home" ABC-1 ready pr_url "https://example.com/shop/pull/1"
expect_job "done unit records its branch" "$home" ABC-1 ready branch "abc-1-stock-level"
expect_job "blocked unit is blocked with its reason" "$home" ABC-2 blocked reason "checkout total wrong"
expect_job "dropped unit is blocked with the plan-conflict reason and beats its done result" "$home" ABC-3 blocked reason "overlaps U1 on the cart"
expect_job "unit missing from both files is blocked" "$home" ABC-4 blocked reason "no result from the autopilot run"
if jq -e 'length == 4' "$home/jobs/index.json" >/dev/null 2>&1; then pass "writes go through job.sh (index rewritten)"; else fail "writes go through job.sh (index rewritten)" "no index"; fi

# A done unit with no PR, and a blocked unit with an empty reason, never leave a
# ready job without a PR or a blocked job without a reason.
fresh_home "$home" odd
odd="$work/odd"
mkdir -p "$odd"
cp "$fx/map.json" "$odd/"
echo '{"units": [{"id": "U1", "status": "done", "reason": "", "pr_url": ""}, {"id": "U2", "status": "blocked:qa", "reason": ""}]}' > "$odd/result.json"
apply "$home" "$odd"
expect_job "a done unit with no PR is blocked, not ready" "$home" ABC-1 blocked reason "the unit finished with no pull request"
expect_job "an empty reason falls back to the status" "$home" ABC-2 blocked reason "blocked:qa"

# The branch, PR or reason is recorded before the stage moves: a set that fails
# leaves the job delivering, so a rerun applies it again rather than leaving a
# ready job with no pr_url. job.sh is swapped for one whose set always fails.
fresh_home "$home" run
mkdir -p "$work/failing-set/scripts"
cp "$script" "$work/failing-set/scripts/apply-result.sh"
printf '#!/usr/bin/env bash\n[ "$1" != set ] || { echo "job: disk full" >&2; exit 1; }\nexec bash %q "$@"\n' "$plugin_dir/scripts/job.sh" > "$work/failing-set/scripts/job.sh"
status=0
FACTORY_HOME="$home" bash "$work/failing-set/scripts/apply-result.sh" "$run" >/dev/null 2>&1 || status=$?
if [ "$status" = 0 ]; then fail "a failing set fails the run" "exit 0"; else pass "a failing set fails the run"; fi
expect_job "a failing set leaves ABC-1 delivering" "$home" ABC-1 delivering stage delivering

# No dropped.json: treated as empty, so U3 is done.
fresh_home "$home" run
rm "$run/dropped.json"
apply "$home" "$run"
expect_job "absent dropped.json means nothing dropped" "$home" ABC-3 ready pr_url "https://example.com/shop/pull/3"

# A job not delivering is skipped with a warning; the rest still apply.
fresh_home "$home" run
cp "$fx/dropped.json" "$run/"
jq '.stage = "queued"' "$home/jobs/ABC-1/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-1/job.json"
apply "$home" "$run"
if [ "$status" = 0 ]; then pass "a skipped job does not fail the run"; else fail "a skipped job does not fail the run" "status $status"; fi
expect_job "a queued job is left alone" "$home" ABC-1 queued stage queued
expect_job "the other jobs still apply" "$home" ABC-2 blocked reason "checkout total wrong"
if grep -q "skipping ABC-1" "$work/err"; then pass "the skip is reported"; else fail "the skip is reported" "$(cat "$work/err")"; fi
if grep -q '^ABC-1' <<<"$out"; then fail "a skipped job prints no line" "$out"; else pass "a skipped job prints no line"; fi

# A job delivering another run is skipped: a stale re-apply never touches it.
fresh_home "$home" run
jq '.run_id = "later-run"' "$home/jobs/ABC-2/job.json" > "$work/j" && mv "$work/j" "$home/jobs/ABC-2/job.json"
apply "$home" "$run"
expect_job "a job delivering another run is left alone" "$home" ABC-2 delivering run_id later-run
if grep -q "skipping ABC-2, it is delivering run later-run, not run" "$work/err"; then pass "the other-run skip is reported"; else fail "the other-run skip is reported" "$(cat "$work/err")"; fi

# --no-result: the run ended with no result.json, so every unit not dropped is blocked.
fresh_home "$home" noresult
rm -rf "$work/noresult"; mkdir -p "$work/noresult"
cp "$fx/map.json" "$fx/dropped.json" "$work/noresult/"
apply "$home" "$work/noresult" --no-result
if [ "$status" = 0 ]; then pass "--no-result applies"; else fail "--no-result applies" "status $status: $(cat "$work/err")"; fi
expect_job "--no-result blocks a unit with no result" "$home" ABC-1 blocked reason "no result from the autopilot run"
expect_job "--no-result keeps a dropped reason" "$home" ABC-3 blocked reason "overlaps U1 on the cart"
if [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 4 ]; then pass "--no-result prints every unit"; else fail "--no-result prints every unit" "$out"; fi
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
