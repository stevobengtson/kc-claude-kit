#!/usr/bin/env bash
# Turns a job's intake rating into routing: reads RISK and SURFACES from the
# first three lines of <job-dir>/intake.md, applies the config's row for that
# risk and then the overlay of each surface, writes <job-dir>/routing.json and
# prints the plan's Routing line.
#
# Usage: route.sh <job-dir> <config.json>   (config.json is read-config.sh output)
# Exit: 0 routed; 1 intake.md missing, no RISK line or an unknown risk
# ("route: <problem>" on stderr); 2 jq missing or a usage error.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "route: jq is required" >&2; exit 2; }

if [ "$#" -ne 2 ]; then
  echo "route: usage: route.sh <job-dir> <config.json>" >&2
  exit 2
fi
job_dir=$1
config=$2
intake="$job_dir/intake.md"

if [ ! -f "$intake" ]; then
  echo "route: $intake not found" >&2
  exit 1
fi
if [ ! -f "$config" ]; then
  echo "route: $config not found" >&2
  exit 2
fi

header=$(sed -n '1,3p' "$intake")
# header_value <NAME>: the trimmed text after "NAME:" on its header line.
header_value() {
  printf '%s\n' "$header" | awk -v name="$1" '
    index($0, name ":") == 1 { v = substr($0, length(name) + 2); gsub(/^[ \t]+|[ \t\r]+$/, "", v); print v; exit }'
}

risk=$(header_value RISK | tr '[:upper:]' '[:lower:]')
if [ -z "$risk" ]; then
  echo "route: intake.md has no RISK line" >&2
  exit 1
fi
case "$risk" in
  low | medium | high) ;;
  *) echo "route: unknown risk: $risk" >&2; exit 1 ;;
esac

# Surface names: lowercased, trimmed, blanks dropped; "none" is no surfaces.
surfaces=$(header_value SURFACES | jq -Rc '
  ascii_downcase | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(. != "")) | if . == ["none"] then [] else . end')

# jq program: $-variables are jq's, not the shell's.
# shellcheck disable=SC2016
routing=$(jq -c --arg risk "$risk" --argjson surfaces "$surfaces" '
  .routing as $r
  | reduce ($surfaces[] | $r.surfaces[.] // empty) as $overlay ($r[$risk];
      . + ($overlay | with_entries(select(.key == "workers" or .key == "security")))
        + (if $overlay.personas then {personas: (.personas + $overlay.personas)} else {} end))
  | {risk: $risk, surfaces: $surfaces} + .' "$config")

printf '%s\n' "$routing" > "$job_dir/routing.json"
jq -r '"- Routing: workers=\(.workers); personas=\(.personas.min)-\(.personas.max); security=\(.security)"' <<<"$routing"
