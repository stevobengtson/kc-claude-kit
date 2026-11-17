#!/usr/bin/env bash
# Drops units from the plan JSON that validate-plan.sh printed, for a design
# objection that concerns only some units (see skills/kc-run/SKILL.md, step 2).
#   usage: drop-units.sh <plan.json> <dropped.json> <unit-id>...
# Prints the plan JSON without those units and without criteria only they
# cover. Appends {id, reason: null} per unit to <dropped.json> (created as []
# first); kc-run fills each reason. Exit 1, writing nothing, when an id is
# unknown, a remaining unit depends on a dropped one, or no unit would remain.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: drop-units.sh <plan.json> <dropped.json> <unit-id>..." >&2
  exit 2
fi
plan=$1 dropped_file=$2
shift 2

dropped_ids=$(printf '%s\n' "$@" | jq -R . | jq -sc .)

problems=$(jq -r --argjson ids "$dropped_ids" '
  . as $plan
  | [ $ids[] | select(. as $id | $plan.units | map(.id) | index($id) | not) | "plan: unknown unit \(.)" ] as $unknown
  | if ($unknown | length) > 0 then $unknown[]
    else
      ( $plan.units[] | select(.id as $id | $ids | index($id) | not)
        | .id as $unit | (.depends_on // [])[] | select(. as $dep | $ids | index($dep))
        | "plan: \($unit) depends on dropped unit \(.)" ),
      ( if ($plan.units | map(select(.id as $id | $ids | index($id) | not)) | length) == 0
        then "plan: every unit dropped; stop the run instead" else empty end )
    end' "$plan")
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" >&2
  exit 1
fi

remaining_plan=$(jq --argjson ids "$dropped_ids" '
  .units |= map(select(.id as $id | $ids | index($id) | not))
  | ([.units[].covers[]] | unique) as $covered
  | .criteria |= map(select(.id as $id | $covered | index($id)))' "$plan")

[ -f "$dropped_file" ] || echo '[]' > "$dropped_file"
tmp=$(mktemp)
jq --argjson ids "$dropped_ids" '. + [$ids[] | {id: ., reason: null}]' "$dropped_file" > "$tmp" && mv "$tmp" "$dropped_file"
printf '%s\n' "$remaining_plan"
