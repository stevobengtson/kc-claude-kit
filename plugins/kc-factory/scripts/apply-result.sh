#!/usr/bin/env bash
# Applies a finished autopilot run to the jobs it covered. Reads <run-dir>/map.json
# (unit to key), result.json and dropped.json (absent means none; a unit in both
# is taken from dropped.json). A "done" unit with a PR moves its job to ready and
# records the PR; every other outcome, including a done unit with no PR and a
# unit with no result, moves it to blocked and records a non-empty reason. The
# unit's branch, when result.json has one, is recorded first. Writes only through
# job.sh. A job that is not delivering, or whose run_id is not this run's, is
# skipped with a warning.
#
# Usage: apply-result.sh <run-dir> [--no-result]
# --no-result: the run ended with no result.json (the workflow failed, or its
# session died); every unit not in dropped.json is blocked. Refused when
# result.json exists, so a real result is never ignored.
# Prints KEY<TAB>stage<TAB>pr_url-or-reason per unit, in map.json order.
# Exit: 0 applied; 1 refused ("apply-result: <problem>" on stderr); 2 jq missing
# or a usage error. Jobs live at $FACTORY_HOME/jobs/<KEY>/ (default <repo>/.factory).
# jq programs are single-quoted on purpose; their $vars are jq variables.
# shellcheck disable=SC2016
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "apply-result: jq is required" >&2; exit 2; }
usage() { echo "apply-result: usage: apply-result.sh <run-dir> [--no-result]" >&2; exit 2; }
no_result=false
case "$#" in
  1) ;;
  2) [ "$2" = --no-result ] || usage; no_result=true ;;
  *) usage ;;
esac
run_dir=$1
refuse() { echo "apply-result: $*" >&2; exit 1; }

script_dir=$(cd "$(dirname "$0")" && pwd)
job="$script_dir/job.sh"

map="$run_dir/map.json"
result="$run_dir/result.json"
dropped="$run_dir/dropped.json"
[ -f "$map" ] || refuse "$map not found"
if [ "$no_result" = true ]; then
  [ ! -e "$result" ] || refuse "--no-result given but $result exists"
  result_json='{"units": []}'
else
  [ -f "$result" ] || refuse "$result not found"
  jq -e '(.units | type) == "array"' "$result" >/dev/null 2>&1 || refuse "$result has no units array"
  result_json=$(cat "$result")
fi
jq -e 'type == "object"' "$map" >/dev/null 2>&1 || refuse "$map is not a JSON object"
if [ -f "$dropped" ]; then
  jq -e 'type == "array"' "$dropped" >/dev/null 2>&1 || refuse "$dropped is not a JSON array"
  dropped_json=$(cat "$dropped")
else
  dropped_json='[]'
fi

# One row per unit in map order: unit, key, outcome, text (PR url or reason), branch.
rows=$(jq -r --argjson result "[$result_json]" --argjson dropped "$dropped_json" '
  def text_or($fallback): if type == "string" and length > 0 then . else $fallback end;
  . as $map
  | [keys_unsorted[] | {id: ., n: (ltrimstr("U") | tonumber? // 0)}] | sort_by(.n) | map(.id) as $order
  | $order[] as $id
  | ($dropped | map(select(.id == $id)) | first) as $d
  | ($result[0].units | map(select(.id == $id)) | first) as $r
  | ($r.pr_url | text_or("")) as $pr_url
  | (if $d != null then {outcome: "blocked", text: ($d.reason | text_or($d.status | text_or("dropped from the run")))}
     elif $r == null then {outcome: "blocked", text: "no result from the autopilot run"}
     elif $r.status == "done" and $pr_url != "" then {outcome: "done", text: $pr_url}
     elif $r.status == "done" then {outcome: "blocked", text: "the unit finished with no pull request"}
     else {outcome: "blocked", text: ($r.reason | text_or($r.status | text_or("failed")))} end) as $o
  | [$id, $map[$id].key, $o.outcome, ($o.text | gsub("[\t\r\n]+"; " ")), ($r.branch | text_or(""))]
  | @tsv' "$map") || refuse "could not read $map and $result"
run_id=$(basename "$run_dir")

while IFS=$'\t' read -r _ key outcome text branch; do
  [ -n "$key" ] || continue
  shown=$(bash "$job" show "$key" 2>/dev/null) || shown='{}'
  stage=$(jq -r '.stage // ""' <<<"$shown" 2>/dev/null) || stage=""
  job_run_id=$(jq -r '.run_id // ""' <<<"$shown" 2>/dev/null) || job_run_id=""
  if [ "$stage" != delivering ]; then
    echo "apply-result: skipping $key, it is ${stage:-not a job} and not delivering" >&2
    continue
  fi
  if [ "$job_run_id" != "$run_id" ]; then
    echo "apply-result: skipping $key, it is delivering run ${job_run_id:-unknown}, not $run_id" >&2
    continue
  fi
  # The branch, PR or reason first, then the stage: a failure between the two
  # leaves the job delivering, which a rerun applies again, never a ready job
  # with no PR.
  if [ -n "$branch" ]; then bash "$job" set "$key" branch "$(jq -n --arg v "$branch" '$v')"; fi
  if [ "$outcome" = "done" ]; then
    bash "$job" set "$key" pr_url "$(jq -n --arg v "$text" '$v')"
    bash "$job" advance "$key" ready
    printf '%s\t%s\t%s\n' "$key" ready "$text"
  else
    bash "$job" set "$key" reason "$(jq -n --arg v "$text" '$v')"
    bash "$job" advance "$key" blocked
    printf '%s\t%s\t%s\n' "$key" blocked "$text"
  fi
done <<<"$rows"
