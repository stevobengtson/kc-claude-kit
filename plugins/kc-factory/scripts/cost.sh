#!/usr/bin/env bash
# Prices one job's model usage from Claude Code transcripts. A transcript counts
# for the job when its first user message contains ".factory/jobs/<KEY>/" or,
# given --run and --unit, contains the run dir path and a line starting
# "Unit <Uid>: <KEY>" (how an autopilot unit prompt opens). Searches the
# transcripts dir recursively, so subagent transcripts are included.
#
# Usage: cost.sh <KEY> <transcripts-dir> <config.json> [--run <run-dir> --unit <Uid>]
# An empty <transcripts-dir> ("") means ~/.claude/projects/<cwd with / replaced by ->.
# Prints {"usd": <number|null>, "tokens": {<model>: {...}}, "unpriced_models": [...]}.
# usd is null when a model has no price or a matched transcript has a line that
# does not parse, or when no transcript matches (never a false 0); "matched" counts the transcripts used.
# Exit: 0 printed; 1 refused ("cost: <problem>" on stderr); 2 jq missing or a usage error.
# jq programs are single-quoted on purpose; their $vars are jq variables.
# shellcheck disable=SC2016
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "cost: jq is required" >&2; exit 2; }
usage() {
  echo "cost: usage: cost.sh <KEY> <transcripts-dir> <config.json> [--run <run-dir> --unit <Uid>]" >&2
  exit 2
}
[ "$#" -ge 3 ] || usage
key=$1 dir=$2 config=$3
shift 3
if [ -z "$dir" ]; then dir="$HOME/.claude/projects/$(pwd | tr / -)"; fi
run="" unit=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run) [ "$#" -ge 2 ] || usage; run=$2; shift 2 ;;
    --unit) [ "$#" -ge 2 ] || usage; unit=$2; shift 2 ;;
    *) usage ;;
  esac
done
if { [ -n "$run" ] && [ -z "$unit" ]; } || { [ -z "$run" ] && [ -n "$unit" ]; }; then usage; fi

[ -f "$config" ] || { echo "cost: $config not found" >&2; exit 1; }
prices=$(jq -c '.prices_usd_per_mtok // {}' "$config") || { echo "cost: $config is not valid JSON" >&2; exit 1; }
[ -d "$dir" ] || { echo "cost: $dir is not a directory" >&2; exit 1; }

# One summary object per transcript: whether it belongs to the job, whether a
# line failed to parse, and its token totals per model.
summarize='
  def text: if (.message.content | type) == "string" then .message.content
            elif (.message.content | type) == "array" then ([.message.content[] | select(type == "object" and .type == "text") | .text] | join("\n"))
            else "" end;
  [split("\n")[] | select(length > 0) | . as $l | (try fromjson catch {bad: true, raw: $l})] as $lines
  | ([$lines[] | select(type == "object" and .type == "user")][0] // {} | text) as $first
  | {
      match: (($first | contains(".factory/jobs/" + $key + "/"))
              or ($run != "" and ($first | contains($run))
                  and ([$first | split("\n")[] | select(. == ("Unit " + $unit + ": " + $key) or startswith("Unit " + $unit + ": " + $key + " "))] | length > 0))),
      bad: ([$lines[] | select(type != "object" or .bad == true)] | length > 0),
      usage: ([$lines[] | select(type == "object" and .type == "assistant" and (.message.usage | type) == "object")
               | {id: .message.id, model: (.message.model // "unknown"), u: .message.usage}]
              | (map(select(.id == null)) + (map(select(.id != null)) | group_by(.id) | map(to_entries | sort_by([.value.u.output_tokens // 0, .key]) | last | .value)))
              | group_by(.model)
              | map({key: .[0].model, value: {
                  input_tokens: (map(.u.input_tokens // 0) | add),
                  output_tokens: (map(.u.output_tokens // 0) | add),
                  cache_creation_input_tokens: (map(.u.cache_creation_input_tokens // 0) | add),
                  cache_read_input_tokens: (map(.u.cache_read_input_tokens // 0) | add)}})
              | from_entries)
    }'

summaries=$(mktemp)
trap 'rm -f "$summaries"' EXIT
while IFS= read -r f; do
  jq -R -s -c --arg key "$key" --arg run "$run" --arg unit "$unit" "$summarize" "$f" >> "$summaries"
done < <(find "$dir" -type f -name '*.jsonl' | sort)

jq -s -c --argjson prices "$prices" '
  [.[] | select(.match)] as $m
  | ($m | map(.usage) | map(to_entries) | add // [] | group_by(.key)
      | map({key: .[0].key, value: {
          input_tokens: (map(.value.input_tokens) | add),
          output_tokens: (map(.value.output_tokens) | add),
          cache_creation_input_tokens: (map(.value.cache_creation_input_tokens) | add),
          cache_read_input_tokens: (map(.value.cache_read_input_tokens) | add)}})
      | from_entries) as $tokens
  | {input_tokens: "input", output_tokens: "output", cache_creation_input_tokens: "cache_write", cache_read_input_tokens: "cache_read"} as $price_key
  | ($tokens | to_entries | map(select(
        .key as $model | .value as $t
        | ($prices[$model] | type) != "object"
          or ([$price_key | to_entries[] | select(($t[.key] // 0) > 0 and (($prices[$model][.value] | type) != "number"))] | length > 0)))
      | map(.key) | sort) as $unpriced
  | {
      usd: (if ($m | length) == 0 then null
            elif ($unpriced | length) > 0 or ($m | map(.bad) | any) then null
            else ($tokens | to_entries | map(. as $e | $price_key | to_entries | map(($e.value[.key] // 0) * ($prices[$e.key][.value] // 0)) | add) | add // 0) / 1000000
            end),
      tokens: $tokens,
      unpriced_models: $unpriced,
      matched: ($m | length)
    }' "$summaries"
