#!/usr/bin/env bash
# Validates a repo's .claude/factory.json and prints it normalized, with
# every default filled in, as compact JSON on stdout.
#
# Usage: read-config.sh <factory.json>
# Exit: 0 valid; 1 invalid (one "factory.json: <problem>" line per problem
# on stderr); 2 jq missing or no file argument.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "factory: jq is required" >&2; exit 2; }

config=${1:-}
if [ -z "$config" ]; then
  echo "factory: usage: read-config.sh <factory.json>" >&2
  exit 2
fi
if [ ! -f "$config" ]; then
  echo "factory.json: $config not found" >&2
  exit 1
fi
if ! jq empty "$config" >/dev/null 2>&1; then
  echo "factory.json: $config is not valid JSON" >&2
  exit 1
fi
if [ "$(jq -r 'type' "$config")" != object ]; then
  echo "factory.json: must be a JSON object" >&2
  exit 1
fi

# Sections of the wrong type read as {} so normalization never crashes;
# SHAPE reports them.
# jq program: $-variables are jq's, not the shell's.
# shellcheck disable=SC2016
readonly NORMALIZE='
  def o: if type == "object" then . else {} end;
  def tier($d): . as $u | ($u | o) as $t
    | ($t.personas | o) as $p
    | { workers: ($t.workers // $d.workers),
        personas: { min: ($p.min // $d.personas.min), max: ($p.max // $d.personas.max) },
        security: ($t.security // $d.security) };
  . as $c
  | ($c.tracker | o) as $t
  | ($t.statuses | o) as $s
  | ($c.routing | o) as $r
  | {
      tracker: {
        kind: ($t.kind // "jira"),
        site: $t.site,
        project_keys: $t.project_keys,
        statuses: { in_progress: ($s.in_progress // "In Progress"), in_review: ($s.in_review // "In Review") },
        comment_on: ($t.comment_on // ["needs-info", "reject", "accept", "ready", "blocked"])
      },
      concurrency: ($c.concurrency // 3),
      intake: { model: (($c.intake | o).model // "best") },
      routing: {
        low: ($r.low | tier({workers: "sonnet", personas: {min: 2, max: 3}, security: "workers"})),
        medium: ($r.medium | tier({workers: "sonnet", personas: {min: 3, max: 4}, security: "workers"})),
        high: ($r.high | tier({workers: "best", personas: {min: 4, max: 5}, security: "staff"})),
        surfaces: ($r.surfaces // {security: {security: "staff"}})
      },
      prices_usd_per_mtok: ($c.prices_usd_per_mtok // {})
    }'

# jq program: $-variables are jq's, not the shell's.
# shellcheck disable=SC2016
readonly SHAPE='
  def wrong($v): $v != null and ($v | type) != "object";
  def o: if type == "object" then . else {} end;
  . as $c
  | ($c.tracker | o) as $t
  | ($c.routing | o) as $r
  | [
      (if wrong($c.tracker) then "tracker must be an object" else empty end),
      (if wrong($t.statuses) then "tracker.statuses must be an object" else empty end),
      (if wrong($c.intake) then "intake must be an object" else empty end),
      (if wrong($c.routing) then "routing must be an object" else empty end),
      (if wrong($r.surfaces) then "routing.surfaces must be an object" else empty end),
      (if wrong($c.prices_usd_per_mtok) then "prices_usd_per_mtok must be an object" else empty end),
      (("low", "medium", "high") as $k
        | (if wrong($r[$k]) then "routing.\($k) must be an object" else empty end),
          (if wrong(($r[$k] | o).personas) then "routing.\($k).personas must be an object" else empty end)),
      (($r.surfaces | o) | to_entries[]
        | (if (.value | type) != "object" then "routing.surfaces.\(.key) must be an object" else empty end))
    ] | .[]'

# jq program: $-variables are jq's, not the shell's.
# shellcheck disable=SC2016
readonly PROBLEMS='
  def posint: type == "number" and . >= 1 and floor == .;
  def model: type == "string" and (. == "haiku" or . == "sonnet" or . == "opus" or . == "best" or test("^claude-[a-z0-9-]+$"));
  def personas: (.min | posint) and (.max | posint) and .min <= .max;
  def secure: . == "workers" or . == "staff";
  def o: if type == "object" then . else {} end;
  def checks($name): select(. != null)
    | [ (if (.workers | model) then empty else "\($name).workers must be haiku, sonnet, opus, best or a claude-* model id" end),
        (if (.personas | personas) then empty else "\($name).personas must be integers with 1 <= min <= max" end),
        (if (.security | secure) then empty else "\($name).security must be workers or staff" end) ] | .[];
  [
    (if .tracker.kind == "jira" then empty else "tracker.kind must be \"jira\"" end),
    (if (.tracker.site | type) == "string" and (.tracker.site | length) > 0 then empty else "tracker.site must be a non-empty string" end),
    (if (.tracker.project_keys | type) == "array" and (.tracker.project_keys | length) > 0 and all(.tracker.project_keys[]; type == "string" and test("^[A-Z][A-Z0-9]+$")) then empty else "tracker.project_keys must be a non-empty array of keys like ABC" end),
    (if (.tracker.statuses | [.in_progress, .in_review] | all(.[]; type == "string" and length > 0)) then empty else "tracker.statuses must be non-empty strings" end),
    (if (.tracker.comment_on | type) == "array" and all(.tracker.comment_on[]; . == "needs-info" or . == "reject" or . == "accept" or . == "ready" or . == "blocked") then empty else "tracker.comment_on must list only needs-info, reject, accept, ready, blocked" end),
    (if (.concurrency | posint) and .concurrency <= 8 then empty else "concurrency must be an integer from 1 to 8" end),
    (if (.intake.model | model) then empty else "intake.model must be haiku, sonnet, opus, best or a claude-* model id" end),
    (.routing.low | checks("routing.low")),
    (.routing.medium | checks("routing.medium")),
    (.routing.high | checks("routing.high")),
    (.routing.surfaces | to_entries[] | select(.value | type == "object")
      | .key as $k | .value | o
      | (if has("workers") and (.workers | model | not) then "routing.surfaces.\($k).workers must be haiku, sonnet, opus, best or a claude-* model id" else empty end),
        (if has("personas") and ((.personas | type) != "object" or (.personas | personas | not)) then "routing.surfaces.\($k).personas must be integers with 1 <= min <= max" else empty end),
        (if has("security") and (.security | secure | not) then "routing.surfaces.\($k).security must be workers or staff" else empty end)),
    (if (.prices_usd_per_mtok | type) == "object" then empty else "prices_usd_per_mtok must be an object" end)
  ] | .[]'

shape_problems=$(jq -r "$SHAPE" "$config")
normalized=$(jq -c "$NORMALIZE" "$config")
value_problems=$(printf '%s' "$normalized" | jq -r "$PROBLEMS")
problems=$(printf '%s\n%s\n' "$shape_problems" "$value_problems" | sed '/^$/d')
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed 's/^/factory.json: /' >&2
  exit 1
fi
printf '%s\n' "$normalized"
