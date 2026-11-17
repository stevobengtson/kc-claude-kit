#!/usr/bin/env bash
# Tests scripts/job.sh, and through it the factory-home.sh it sources: create, legal and illegal stage moves, field
# whitelist, history, and the index.json the dashboard reads.
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(dirname "$tests_dir")
script="$plugin_dir/scripts/job.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

bash "$plugin_dir/scripts/read-config.sh" "$tests_dir/fixtures/config/minimal.json" > "$work/config.json"

home=""
fresh_home() { home="$work/home-$1"; rm -rf "$home"; mkdir -p "$home"; }
run_job_script() { FACTORY_HOME="$home" FACTORY_NOW=2026-01-02T03:04:05Z bash "$script" "$@"; }
read_stage() { run_job_script show "$1" | jq -r '.stage'; }

# expect_refusal <label> <expected stderr line> <job.sh args...>
expect_refusal() {
  local label=$1 message=$2 status=0 err
  shift 2
  err=$(run_job_script "$@" 2>&1 >/dev/null) || status=$?
  if [ "$status" = 1 ] && [ "$err" = "$message" ]; then
    pass "$label"
  else
    fail "$label" "status $status, stderr: $err"
  fi
}

fresh_home create
dir=$(run_job_script create ABC-1 "$work/config.json")
if [ "$dir" = "$home/jobs/ABC-1" ] && [ -f "$dir/job.json" ]; then
  pass "create: prints the job dir"
else
  fail "create: prints the job dir" "got $dir"
fi
shown=$(run_job_script show ABC-1)
if [ "$(jq -c '[.key, .stage, .created_at, .updated_at, .history]' <<<"$shown")" = '["ABC-1","intake","2026-01-02T03:04:05Z","2026-01-02T03:04:05Z",[{"stage":"intake","at":"2026-01-02T03:04:05Z"}]]' ]; then
  pass "create: show gives stage intake, timestamps and history"
else
  fail "create: show gives stage intake, timestamps and history" "$shown"
fi

# Every legal move in the table.
expect_legal_move() {
  local from=$1 to=$2 path=$3 key=$4 step
  fresh_home "legal-$key"
  run_job_script create "$key" "$work/config.json" >/dev/null
  for step in $path; do run_job_script advance "$key" "$step" >/dev/null; done
  if [ "$(read_stage "$key")" != "$from" ]; then
    fail "legal: $from -> $to" "setup reached $(read_stage "$key"), not $from"
    return
  fi
  if run_job_script advance "$key" "$to" >/dev/null 2>&1 && [ "$(read_stage "$key")" = "$to" ]; then
    pass "legal: $from -> $to"
  else
    fail "legal: $from -> $to" "refused or wrong stage"
  fi
}
expect_legal_move intake needs-info "" ABC-1
expect_legal_move intake rejected "" ABC-2
expect_legal_move intake queued "" ABC-3
expect_legal_move needs-info intake "needs-info" ABC-4
expect_legal_move needs-info rejected "needs-info" ABC-5
expect_legal_move queued delivering "queued" ABC-6
expect_legal_move queued blocked "queued" ABC-7
expect_legal_move delivering ready "queued delivering" ABC-8
expect_legal_move delivering blocked "queued delivering" ABC-9
expect_legal_move blocked queued "queued blocked" ABC-10
expect_legal_move blocked rejected "queued blocked" ABC-11

fresh_home illegal
run_job_script create ABC-1 "$work/config.json" >/dev/null
for step in queued delivering ready; do run_job_script advance ABC-1 "$step" >/dev/null; done
expect_refusal "illegal move is refused" "job: ABC-1 cannot move from ready to intake" advance ABC-1 intake
expect_refusal "unknown stage is refused" "job: ABC-1 cannot move from ready to done" advance ABC-1 "done"
if [ "$(read_stage ABC-1)" = ready ]; then pass "illegal move leaves the stage alone"; else fail "illegal move leaves the stage alone" "$(read_stage ABC-1)"; fi

fresh_home keys
expect_refusal "create refuses a key outside project_keys" "job: ABC1 is not a ticket key in project_keys" create ABC1 "$work/config.json"
expect_refusal "create refuses another project's key" "job: XYZ-1 is not a ticket key in project_keys" create XYZ-1 "$work/config.json"

fresh_home running
run_job_script create ABC-1 "$work/config.json" >/dev/null
run_job_script advance ABC-1 queued >/dev/null
expect_refusal "create refuses a queued job" "job: ABC-1 is already queued" create ABC-1 "$work/config.json"
run_job_script advance ABC-1 delivering >/dev/null
expect_refusal "create refuses a key whose job is running" "job: ABC-1 is already delivering" create ABC-1 "$work/config.json"

fresh_home resume
run_job_script create ABC-1 "$work/config.json" >/dev/null
run_job_script advance ABC-1 queued >/dev/null
run_job_script advance ABC-1 blocked >/dev/null
resumed=$(run_job_script create ABC-1 "$work/config.json")
if [ "$resumed" = "$home/jobs/ABC-1" ] && [ "$(read_stage ABC-1)" = blocked ]; then
  pass "create on a blocked job returns its dir"
else
  fail "create on a blocked job returns its dir" "got $resumed, stage $(read_stage ABC-1)"
fi
run_job_script create ABC-2 "$work/config.json" >/dev/null
run_job_script advance ABC-2 needs-info >/dev/null
if [ "$(run_job_script create ABC-2 "$work/config.json")" = "$home/jobs/ABC-2" ]; then
  pass "create on a needs-info job returns its dir"
else
  fail "create on a needs-info job returns its dir" "wrong dir"
fi

fresh_home set
run_job_script create ABC-1 "$work/config.json" >/dev/null
run_job_script set ABC-1 risk '"high"'
run_job_script set ABC-1 surfaces '["security","ui"]'
run_job_script set ABC-1 cost_usd 1.5
run_job_script set ABC-1 cost_partial true
run_job_script set ABC-1 title '"Fix checkout total"'
if [ "$(run_job_script show ABC-1 | jq -c '[.risk, .surfaces, .cost_usd, .cost_partial, .title]')" = '["high",["security","ui"],1.5,true,"Fix checkout total"]' ]; then
  pass "set: stores json values on whitelisted fields"
else
  fail "set: stores json values on whitelisted fields" "$(run_job_script show ABC-1)"
fi
expect_refusal "set refuses an unknown field" "job: stage is not a settable field" set ABC-1 stage '"ready"'
expect_refusal "set refuses a non-JSON value" "job: value for risk is not valid JSON" set ABC-1 risk high
expect_refusal "set refuses a missing job" "job: ABC-9 has no job" set ABC-9 risk '"low"'
expect_refusal "show refuses a missing job" "job: ABC-9 has no job" show ABC-9

fresh_home clear
run_job_script create ABC-1 "$work/config.json" >/dev/null
run_job_script set ABC-1 pr_url '"https://example.com/pr/1"'
run_job_script set ABC-1 pr_url null
run_job_script set ABC-1 reason false
if [ "$(run_job_script show ABC-1 | jq -c '[.pr_url, .reason]')" = '[null,false]' ]; then
  pass "set: null and false are storable values"
else
  fail "set: null and false are storable values" "$(run_job_script show ABC-1)"
fi

fresh_home corrupt
run_job_script create ABC-1 "$work/config.json" >/dev/null
echo '{broken' > "$home/jobs/ABC-1/job.json"
status=0
run_job_script set ABC-1 risk '"low"' >/dev/null 2>&1 || status=$?
if [ "$status" != 0 ] && [ "$(cat "$home/jobs/ABC-1/job.json")" = '{broken' ]; then
  pass "corrupt job.json: set fails and leaves the file unchanged"
else
  fail "corrupt job.json: set fails and leaves the file unchanged" "status $status, file: $(cat "$home/jobs/ABC-1/job.json")"
fi
leftovers=$(find "$home/jobs" -type f \( -name 'job.json.*' -o -name 'index.json.*' \))
if [ -z "$leftovers" ]; then pass "a failed write leaves no temp file"; else fail "a failed write leaves no temp file" "$leftovers"; fi

fresh_home edge
run_job_script create ABC-1 "$work/config.json" >/dev/null
expect_refusal "advance refuses an empty stage" "job: ABC-1 cannot move from intake to " advance ABC-1 ""
expect_refusal "create refuses a key containing a newline" "job: key must be a single line" create "$(printf 'XYZ-1\nABC-1')" "$work/config.json"
for step in queued delivering ready; do run_job_script advance ABC-1 "$step" >/dev/null; done
if [ "$(run_job_script create ABC-1 "$work/config.json")" = "$home/jobs/ABC-1" ]; then
  pass "create on a ready job prints its dir"
else
  fail "create on a ready job prints its dir" "wrong output"
fi

fresh_home later
run_job_script create ABC-1 "$work/config.json" >/dev/null
later=$(FACTORY_HOME="$home" FACTORY_NOW=2026-02-03T04:05:06Z bash "$script" set ABC-1 reason '"waiting"' && FACTORY_HOME="$home" bash "$script" show ABC-1)
if [ "$(jq -c '[.created_at, .updated_at, (.history | length)]' <<<"$later")" = '["2026-01-02T03:04:05Z","2026-02-03T04:05:06Z",1]' ]; then
  pass "set stamps updated_at, keeps created_at and history"
else
  fail "set stamps updated_at, keeps created_at and history" "$later"
fi

fresh_home history
run_job_script create ABC-1 "$work/config.json" >/dev/null
run_job_script advance ABC-1 queued >/dev/null
run_job_script advance ABC-1 delivering >/dev/null
if [ "$(run_job_script show ABC-1 | jq -c '[.history[].stage]')" = '["intake","queued","delivering"]' ]; then
  pass "history grows by one per advance"
else
  fail "history grows by one per advance" "$(run_job_script show ABC-1 | jq -c .history)"
fi

fresh_home index
run_job_script create ABC-2 "$work/config.json" >/dev/null
run_job_script create ABC-1 "$work/config.json" >/dev/null
run_job_script advance ABC-2 queued >/dev/null
if [ "$(jq -c '[.[] | [.key, .stage]]' "$home/jobs/index.json")" = '[["ABC-1","intake"],["ABC-2","queued"]]' ]; then
  pass "index.json lists every job sorted by key, current after writes"
else
  fail "index.json lists every job sorted by key, current after writes" "$(cat "$home/jobs/index.json")"
fi
listed=$(run_job_script list)
if [ "$listed" = "$(printf 'ABC-1\tintake\t\nABC-2\tqueued\t')" ]; then
  pass "list: KEY, stage and title per line"
else
  fail "list: KEY, stage and title per line" "$listed"
fi
run_job_script set ABC-1 title '"Fix checkout total"'
if [ "$(run_job_script list | head -1)" = "$(printf 'ABC-1\tintake\tFix checkout total')" ]; then
  pass "list: shows a set title"
else
  fail "list: shows a set title" "$(run_job_script list)"
fi
leftovers=$(find "$home/jobs" -type f \( -name 'job.json.*' -o -name 'index.json.*' \))
if [ -z "$leftovers" ]; then
  pass "no temp files left behind"
else
  fail "no temp files left behind" "$leftovers"
fi

echo
echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
