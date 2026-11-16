#!/usr/bin/env bash
# Turns queued, accepted jobs into one autopilot plan, one unit per job in the
# order given. Reads each job's job.json, routing.json and intake.md (never
# ticket.md) and writes <run-dir>/plan.md and <run-dir>/map.json, which maps
# each unit to its key and its plan-wide criteria back to the job's own numbers.
# Nothing is written unless every job is planned.
#
# Usage: plan.sh <run-dir> <KEY>...
# Exit: 0 written; 1 refused ("plan: <problem>" on stderr); 2 jq missing or a
# usage error. Jobs live at $FACTORY_HOME/jobs/<KEY>/ (default <repo>/.factory).
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "plan: jq is required" >&2; exit 2; }

if [ "$#" -lt 2 ]; then
  echo "plan: usage: plan.sh <run-dir> <KEY>..." >&2
  exit 2
fi
run_dir=$1
shift
refuse() { echo "plan: $*" >&2; exit 1; }

if [ -n "${FACTORY_HOME:-}" ]; then
  home=$FACTORY_HOME
elif root=$(git rev-parse --show-toplevel 2>/dev/null); then
  home="$root/.factory"
else
  echo "plan: set FACTORY_HOME outside a git repo" >&2
  exit 2
fi

# section <intake.md> <heading>: the lines under "## <heading>", up to the next heading.
section() {
  awk -v want="$2" '
    /^## / { name = $0; sub(/^##[ \t]+/, "", name); sub(/[ \t\r]+$/, "", name); on = (name == want); next }
    on { sub(/\r$/, ""); print }' "$1"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

goal=""
criteria=""
units=""
oos=""
notes=""
map='{}'
next_ac=1
n=0

for key in "$@"; do
  n=$((n + 1))
  job_dir="$home/jobs/$key"
  [ -f "$job_dir/job.json" ] || refuse "$key has no job"
  stage=$(jq -r '.stage' "$job_dir/job.json")
  [ "$stage" = queued ] || refuse "$key is in $stage, not queued"
  [ -f "$job_dir/intake.md" ] || refuse "$key has no intake.md"
  [ -f "$job_dir/routing.json" ] || refuse "$key has no routing.json"

  title=$(jq -r --arg k "$key" '.title // $k' "$job_dir/job.json")
  routing=$(jq -r '"- Routing: workers=\(.workers); personas=\(.personas.min)-\(.personas.max); security=\(.security)"' "$job_dir/routing.json") \
    || refuse "$key routing.json is not valid routing"
  scope=$(section "$job_dir/intake.md" "Scope" | awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); printf "%s%s", (n++ ? " " : ""), $0 }')
  url=$(section "$job_dir/intake.md" "Ticket" | awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }')
  ac_lines=$(section "$job_dir/intake.md" "Acceptance criteria" | sed -n 's/^[0-9][0-9]*\.[ \t][ \t]*//p')
  [ -n "$ac_lines" ] || refuse "$key intake has no acceptance criteria"

  count=0
  covers=""
  local_map='{}'
  while IFS= read -r criterion; do
    count=$((count + 1))
    ac=$((next_ac + count - 1))
    criteria="${criteria}${ac}. ${criterion}"$'\n'
    covers="${covers:+$covers, }AC${ac}"
    local_map=$(jq -c --arg ac "AC$ac" --argjson i "$count" '. + {($ac): $i}' <<<"$local_map")
  done <<<"$ac_lines"
  next_ac=$((next_ac + count))

  unit="U$n"
  map=$(jq -c --arg u "$unit" --arg k "$key" --argjson c "$local_map" '. + {($u): {key: $k, criteria: $c}}' <<<"$map")
  goal="${goal}- ${key}: ${title}"$'\n'
  unit_title=$key
  [ "$title" = "$key" ] || unit_title="$key $title"
  units="${units}### ${unit}: ${unit_title}"$'\n'"- Depends on: none"$'\n'"- Covers: ${covers}"$'\n'"${routing}"$'\n'"${scope}"$'\n\n'
  section "$job_dir/intake.md" "Out of scope" | sed -n 's/^[ \t]*-[ \t][ \t]*//p' > "$tmp/oos"
  while IFS= read -r item; do
    oos="${oos}- ${key}: ${item}"$'\n'
  done < "$tmp/oos"
  notes="${notes}### ${key}"$'\n'"Ticket: ${url}"$'\n'"Accepted scope: ${scope}"$'\n\n'
done

run_id=$(basename "$run_dir")
title_keys=$(printf '%s, ' "$@")
{
  echo "# Factory run ${run_id}: ${title_keys%, }"
  echo
  echo "## Goal"
  echo "Deliver these accepted tickets, one pull request each:"
  echo
  printf '%s' "$goal"
  echo
  echo "## Acceptance criteria"
  printf '%s' "$criteria"
  echo
  echo "## Work units"
  printf '%s' "$units"
  echo "## Out of scope"
  if [ -n "$oos" ]; then printf '%s' "$oos"; else echo "- Nothing beyond each ticket's accepted scope."; fi
  echo
  echo "## Notes"
  printf '%s' "$notes"
} > "$tmp/plan.md"
printf '%s\n' "$map" > "$tmp/map.json"

mkdir -p "$run_dir"
mv "$tmp/plan.md" "$run_dir/plan.md"
mv "$tmp/map.json" "$run_dir/map.json"
