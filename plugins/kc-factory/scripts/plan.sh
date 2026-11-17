#!/usr/bin/env bash
# Turns queued, accepted jobs into one autopilot plan, one unit per job in the
# order given. Reads each job's job.json (its stage only), routing.json and
# intake.md, never ticket.md or the tracker's title in job.json: a unit's title
# is its key plus the first line of intake's "## Title", or the key alone.
# Writes <run-dir>/plan.md and <run-dir>/map.json, which maps each unit to its
# key and its plan-wide criteria back to the job's own numbers. A job with
# feedback-<n>.md files (resumed from blocked) gets them, oldest first, and its
# job.json branch in its unit's Scope line.
# Nothing is written unless every job is planned.
#
# Usage: plan.sh <run-dir> <KEY>...
# Env: KC_AUTOPILOT_ROOT, the kc-autopilot root whose validate-plan.sh checks
# the generated plan (default: kc-autopilot beside this plugin, if present).
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

# shellcheck source=factory-home.sh
. "$(dirname "$0")/factory-home.sh"
resolve_factory_home plan

# shellcheck source=intake-format.sh
. "$(dirname "$0")/intake-format.sh"

# flatten_to_one_line <text>: the text on one line, so it cannot start a new plan line.
flatten_to_one_line() { printf '%s' "$1" | tr '\r\n' '  '; }

# join_lines [file]: the non-blank lines of the file (or stdin), trimmed, joined by one space.
join_lines() { awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); printf "%s%s", (joined++ ? " " : ""), $0 }' "$@"; }

# join_list_items <item-marker ERE>: one line per list item read from stdin, the
# marker removed and each wrapped continuation line joined on with one space. A
# blank line ends an item.
join_list_items() {
  awk -v marker="$1" '
    $0 ~ marker { if (item != "") print item; item = $0; sub(marker, "", item); next }
    /^[ \t]*$/ { if (item != "") print item; item = ""; next }
    item != "" { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line); item = item " " line }
    END { if (item != "") print item }'
}

for key in "$@"; do
  [ "$(printf '%s\n' "$@" | grep -cxF -- "$key")" = 1 ] || refuse "$key given twice"
done

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
  jq -e . "$job_dir/job.json" >/dev/null 2>&1 || refuse "$key job.json is not valid JSON"
  stage=$(jq -r '.stage' "$job_dir/job.json")
  [ "$stage" = queued ] || refuse "$key is in $stage, not queued"
  [ -f "$job_dir/intake.md" ] || refuse "$key has no intake.md"
  [ -f "$job_dir/routing.json" ] || refuse "$key has no routing.json"

  # Intake's own one-line title, never the tracker's summary (job.json title).
  title=$(get_intake_section "$job_dir/intake.md" "Title" | awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print; exit }')
  title=$(flatten_to_one_line "$title")
  # route.sh writes the Routing line into routing.json; it is only flattened here.
  routing=$(jq -r '.line // "" | gsub("[\r\n]+"; " ")' "$job_dir/routing.json") \
    || refuse "$key routing.json is not valid JSON"
  [ "${routing#- Routing: }" != "$routing" ] || refuse "$key routing.json has no Routing line"
  scope=$(flatten_to_one_line "$(get_intake_section "$job_dir/intake.md" "Scope" | join_lines)")
  # A job resumed from blocked: the user's feedback-<n>.md files, oldest first,
  # and the branch of its earlier attempt join the unit's Scope line, which
  # every autopilot worker is sent. Flattened like everything else.
  unit_scope=$scope
  feedback=""
  i=1
  while [ -f "$job_dir/feedback-$i.md" ]; do
    one_feedback=$(flatten_to_one_line "$(join_lines "$job_dir/feedback-$i.md")")
    feedback="${feedback:+$feedback }$one_feedback"
    i=$((i + 1))
  done
  if [ -n "$feedback" ]; then
    unit_scope="$unit_scope Feedback from the reviewer: $feedback"
    branch=$(jq -r '.branch // "" | tostring' "$job_dir/job.json")
    if [ -n "$branch" ]; then
      [[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || refuse "$key branch is not a plain branch name"
      unit_scope="$unit_scope An earlier attempt is on branch $branch; start from its commits where they are sound."
    fi
  fi
  url=$(get_intake_section "$job_dir/intake.md" "Ticket" | awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }' | tr -d '\r')
  ac_lines=$(get_intake_section "$job_dir/intake.md" "Acceptance criteria" | join_list_items '^[0-9]+\\.[ \t]+')
  [ -n "$ac_lines" ] || refuse "$key intake has no acceptance criteria"

  count=0
  covers=""
  local_map='{}'
  while IFS= read -r criterion; do
    count=$((count + 1))
    ac=$((next_ac + count - 1))
    criteria="${criteria}${ac}. $(flatten_to_one_line "$criterion")"$'\n'
    covers="${covers:+$covers, }AC${ac}"
    local_map=$(jq -c --arg ac "AC$ac" --argjson i "$count" '. + {($ac): $i}' <<<"$local_map")
  done <<<"$ac_lines"
  next_ac=$((next_ac + count))

  unit="U$n"
  map=$(jq -c --arg u "$unit" --arg k "$key" --argjson c "$local_map" '. + {($u): {key: $k, criteria: $c}}' <<<"$map")
  if [ -n "$title" ]; then
    goal="${goal}- ${key}: ${title}"$'\n'
    unit_title="$key $title"
  else
    goal="${goal}- ${key}"$'\n'
    unit_title=$key
  fi
  units="${units}### ${unit}: ${unit_title}"$'\n'"- Depends on: none"$'\n'"- Covers: ${covers}"$'\n'"${routing}"$'\n'"- Scope: ${unit_scope}"$'\n\n'
  get_intake_section "$job_dir/intake.md" "Out of scope" | join_list_items '^[ \t]*-[ \t]+' > "$tmp/oos"
  while IFS= read -r item; do
    oos="${oos}- ${key}: $(flatten_to_one_line "$item")"$'\n'
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

# Self-check with the autopilot validator: KC_AUTOPILOT_ROOT's when set, else
# the kc-autopilot that plugin-root.sh finds (installed plugins sit in versioned
# cache dirs). A plan is never written unchecked.
if [ -n "${KC_AUTOPILOT_ROOT:-}" ]; then
  autopilot_root=$KC_AUTOPILOT_ROOT
else
  plugin_root=$(cd "$(dirname "$0")/.." && pwd)
  autopilot_root=$(bash "$(dirname "$0")/plugin-root.sh" "$plugin_root" kc-autopilot 2>/dev/null) \
    || refuse "cannot find kc-autopilot to check the plan; install it or set KC_AUTOPILOT_ROOT"
fi
validator="$autopilot_root/scripts/validate-plan.sh"
[ -f "$validator" ] || refuse "kc-autopilot has no scripts/validate-plan.sh: $autopilot_root"
if ! problems=$(bash "$validator" "$tmp/plan.md" 2>&1 >/dev/null); then
  echo "plan: generated plan is invalid:" >&2
  printf '%s\n' "$problems" >&2
  exit 1
fi

mkdir -p "$run_dir"
mv "$tmp/plan.md" "$run_dir/plan.md"
mv "$tmp/map.json" "$run_dir/map.json"
