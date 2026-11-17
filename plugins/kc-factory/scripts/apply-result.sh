#!/usr/bin/env bash
# Applies a finished autopilot run to the jobs it covered. Reads <run-dir>/map.json
# (unit to key), result.json and dropped.json (absent means none; a unit in both
# is taken from dropped.json). A "done" unit moves its job to ready and records
# the PR; every other outcome, including a unit with no result, moves it to
# blocked and records the reason. Writes only through job.sh. A job that is not
# delivering is skipped with a warning.
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

# One row per unit in map order: unit, key, status, text (PR url or reason).
rows=$(jq -r --argjson result "[$result_json]" --argjson dropped "$dropped_json" '
  . as $map
  | [keys_unsorted[] | {id: ., n: (ltrimstr("U") | tonumber? // 0)}] | sort_by(.n) | map(.id) as $order
  | $order[] as $id
  | ($dropped | map(select(.id == $id)) | first) as $d
  | ($result[0].units | map(select(.id == $id)) | first) as $r
  | (if $d != null then {status: ($d.status // "skipped"), text: ($d.reason // "dropped from the run")}
     elif $r != null then {status: ($r.status // "failed"), text: (if $r.status == "done" then ($r.pr_url // "") else ($r.reason // $r.status // "failed") end)}
     else {status: "missing", text: "no result from the autopilot run"} end) as $o
  | [$id, $map[$id].key, (if $d == null and $o.status == "done" then "done" else "blocked" end), ($o.text | gsub("[\t\r\n]+"; " "))]
  | @tsv' "$map") || refuse "could not read $map and $result"

while IFS=$'\t' read -r _ key outcome text; do
  [ -n "$key" ] || continue
  stage=$(bash "$job" show "$key" 2>/dev/null | jq -r '.stage' 2>/dev/null) || stage=""
  if [ "$stage" != delivering ]; then
    echo "apply-result: skipping $key, it is ${stage:-not a job} and not delivering" >&2
    continue
  fi
  if [ "$outcome" = "done" ]; then
    bash "$job" advance "$key" ready
    bash "$job" set "$key" pr_url "$(jq -n --arg v "$text" '$v')"
    printf '%s\t%s\t%s\n' "$key" ready "$text"
  else
    bash "$job" advance "$key" blocked
    bash "$job" set "$key" reason "$(jq -n --arg v "$text" '$v')"
    printf '%s\t%s\t%s\n' "$key" blocked "$text"
  fi
done <<<"$rows"
