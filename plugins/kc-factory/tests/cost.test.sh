#!/usr/bin/env bash
# Tests scripts/cost.sh: per-job transcript matching (job dir and autopilot unit
# tag), per-model summing, pricing, and null cost for bad lines or unpriced models.
# shellcheck disable=SC2016
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
script="$(dirname "$tests_dir")/scripts/cost.sh"
fx="$tests_dir/fixtures/transcripts"
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

check() { # <label> <jq filter true over the output> <script args...>
  local label=$1 filter=$2 out
  shift 2
  out=$(bash "$script" "$@" 2>&1) || { fail "$label" "exit $?: $out"; return; }
  if jq -e "$filter" >/dev/null 2>&1 <<<"$out"; then pass "$label"; else fail "$label" "$out"; fi
}

check "two transcripts for ABC-1 (one in a subagents dir) sum together" \
  '.tokens["claude-sonnet-x"].input_tokens == 1500000 and .tokens["claude-sonnet-x"].cache_read_input_tokens == 1000000 and .tokens["claude-opus-x"].output_tokens == 50000' \
  ABC-1 "$fx" "$fx/config.json"
check "prices multiply out to a known figure" '.usd == 12.3 and .unpriced_models == []' ABC-1 "$fx" "$fx/config.json"
check "ABC-2 sums separately" '.usd == 6 and (.tokens | keys) == ["claude-sonnet-x"]' ABC-2 "$fx" "$fx/config.json"
check "unparsable transcript line gives null cost" '.usd == null' ABC-3 "$fx" "$fx/config.json"
check "an unpriced model is listed and gives null cost" '.usd == null and .unpriced_models == ["claude-mystery-x"]' ABC-4 "$fx" "$fx/config.json"
check "no matching transcripts is null cost with matched 0, never a false 0" '. == {"usd":null,"tokens":{},"unpriced_models":[],"matched":0}' ABC-9 "$fx" "$fx/config.json"
check "a message id repeated on several lines counts once (the largest output wins; id-less lines still count)" '.usd == 7.5 and .tokens["claude-sonnet-x"].input_tokens == 2000000 and .tokens["claude-sonnet-x"].output_tokens == 100000' ABC-6 "$fx" "$fx/config.json"
check "matched counts the transcripts used" '.matched == 2' ABC-1 "$fx" "$fx/config.json"
check "autopilot unit tag matches with --run and --unit" '.usd == 3' ABC-5 "$fx" "$fx/config.json" --run /runs/run-7 --unit U2
check "unit tag does not match a longer key (ABC-5 vs ABC-50)" '.usd == 3 and .tokens["claude-sonnet-x"].input_tokens == 1000000' ABC-5 "$fx" "$fx/config.json" --run /runs/run-7 --unit U2
check "the unit tag needs the run dir to match" '.usd == null and .matched == 0' ABC-5 "$fx" "$fx/config.json" --run /runs/other --unit U2
check "without --run the unit tag alone does not match" '.usd == null and .matched == 0' ABC-5 "$fx" "$fx/config.json"

status=0
bash "$script" ABC-1 >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "usage error exits 2"; else fail "usage error exits 2" "status $status"; fi
status=0
bash "$script" ABC-1 "$fx" "$fx/config.json" --run /runs/run-7 >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "--run without --unit exits 2"; else fail "--run without --unit exits 2" "status $status"; fi
status=0
bash "$script" ABC-1 "$fx" "$fx/missing.json" >/dev/null 2>&1 || status=$?
if [ "$status" = 1 ]; then pass "missing config exits 1"; else fail "missing config exits 1" "status $status"; fi

echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
