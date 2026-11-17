#!/usr/bin/env bash
# Prices one job's model usage from Claude Code transcripts. A transcript counts
# for the job when its first user message contains ".factory/jobs/<KEY>/" or,
# given --run and --unit, contains the run dir path and a line starting
# "Unit <Uid>: <KEY>" followed by its end or a character that is not a letter,
# digit or "-" (how an autopilot unit prompt opens; ABC-1 never matches ABC-10).
# Searches the transcripts dir recursively, so subagent transcripts are included.
#
# Usage: cost.sh <KEY> <transcripts-dir> <config.json> [--run <run-dir> --unit <Uid>]
# An empty <transcripts-dir> ("") means ~/.claude/projects/<cwd, every character
# but A-Z, a-z and 0-9 replaced by ->.
# Prints {"usd": <number|null>, "tokens": {<model>: {...}}, "unpriced_models": [...],
# "matched": <n>, "partial": <bool>}. usd is null when a model has no price or a
# matched transcript has a line that does not parse, or when no transcript
# matches (never a false 0); "matched" counts the transcripts used.
# With --run, a transcript whose first message contains the run dir but no
# "Unit U<n>: " line is run overhead (review prep, gates, triage, shipping),
# shared by every unit of the run: "partial" is then true and
# "run_overhead_usd" prices those transcripts together (null on the same terms).
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
# Claude Code names a project's transcripts dir after its path with every
# character but A-Z, a-z and 0-9 replaced by "-".
if [ -z "$dir" ]; then dir="$HOME/.claude/projects/$(pwd | sed 's/[^A-Za-z0-9]/-/g')"; fi
run="" unit=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run) [ "$#" -ge 2 ] || usage; run=$2; shift 2 ;;
    --unit) [ "$#" -ge 2 ] || usage; unit=$2; shift 2 ;;
    *) usage ;;
  esac
done
has_run=false has_unit=false
[ -z "$run" ] || has_run=true
[ -z "$unit" ] || has_unit=true
# --run and --unit come together or not at all.
if [ "$has_run" != "$has_unit" ]; then usage; fi

[ -f "$config" ] || { echo "cost: $config not found" >&2; exit 1; }
prices=$(jq -c '.prices_usd_per_mtok // {}' "$config") || { echo "cost: $config is not valid JSON" >&2; exit 1; }
[ -d "$dir" ] || { echo "cost: $dir is not a directory" >&2; exit 1; }

# One summary object per transcript: whether it belongs to the job, whether a
# line failed to parse, and its token totals per model.
# The four usage counts Claude Code records per assistant message, each mapped
# to its price key in prices_usd_per_mtok; every sum below is over these.
token_defs='
  def price_keys: {input_tokens: "input", output_tokens: "output", cache_creation_input_tokens: "cache_write", cache_read_input_tokens: "cache_read"};
  # sum_counts: an array of usage objects summed field by field over price_keys.
  def sum_counts: . as $usages | price_keys | with_entries(.key as $field | .value = ($usages | map(.[$field] // 0) | add // 0));
'

summarize=$token_defs'
  def text: if (.message.content | type) == "string" then .message.content
            elif (.message.content | type) == "array" then ([.message.content[] | select(type == "object" and .type == "text") | .text] | join("\n"))
            else "" end;
  [split("\n")[] | select(length > 0) | . as $l | (try fromjson catch {bad: true, raw: $l})] as $lines
  | ([$lines[] | select(type == "object" and .type == "user")][0] // {} | text) as $first
  | ("Unit " + $unit + ": " + $key) as $tag
  | ([$first | split("\n")[] | select(startswith($tag) and (.[($tag | length):] | test("^([^A-Za-z0-9-]|$)")))] | length > 0) as $tagged
  | ([$first | split("\n")[] | select(test("^Unit U[0-9]+: "))] | length > 0) as $any_unit
  | ($run != "" and ($first | contains($run))) as $in_run
  | {
      match: (($first | contains(".factory/jobs/" + $key + "/")) or ($in_run and $tagged)),
      overhead: ($in_run and ($any_unit | not)),
      bad: ([$lines[] | select(type != "object" or .bad == true)] | length > 0),
      usage: ([$lines[] | select(type == "object" and .type == "assistant" and (.message.usage | type) == "object")
               | {id: .message.id, model: (.message.model // "unknown"), u: .message.usage}]
              | (map(select(.id == null)) + (map(select(.id != null)) | group_by(.id) | map(to_entries | sort_by([.value.u.output_tokens // 0, .key]) | last | .value)))
              | group_by(.model)
              | map({key: .[0].model, value: (map(.u) | sum_counts)})
              | from_entries)
    }'

summaries=$(mktemp)
trap 'rm -f "$summaries"' EXIT
while IFS= read -r f; do
  jq -R -s -c --arg key "$key" --arg run "$run" --arg unit "$unit" "$summarize" "$f" >> "$summaries"
done < <(find "$dir" -type f -name '*.jsonl' | sort)

jq -s -c --argjson prices "$prices" "$token_defs"'
  price_keys as $price_key
  # tokens: the summed token counts per model of a list of transcript summaries.
  | def tokens: map(.usage) | map(to_entries) | add // [] | group_by(.key)
      | map({key: .[0].key, value: (map(.value) | sum_counts)})
      | from_entries;
  # unpriced: the models of a tokens object with a used count that has no price.
  def unpriced: to_entries | map(select(
        .key as $model | .value as $t
        | ($prices[$model] | type) != "object"
          or ([$price_key | to_entries[] | select(($t[.key] // 0) > 0 and (($prices[$model][.value] | type) != "number"))] | length > 0)))
      | map(.key) | sort;
  # usd: the price of a list of transcript summaries, null when none, a model
  # has no price or a line did not parse.
  def usd: (tokens) as $t
    | if length == 0 then null
      elif ($t | unpriced | length) > 0 or (map(.bad) | any) then null
      else ($t | to_entries | map(. as $e | $price_key | to_entries | map(($e.value[.key] // 0) * ($prices[$e.key][.value] // 0)) | add) | add // 0) / 1000000
      end;
  [.[] | select(.match)] as $m
  | [.[] | select(.overhead and (.match | not))] as $o
  | ($m | tokens) as $tokens
  | {
      usd: ($m | usd),
      tokens: $tokens,
      unpriced_models: ($tokens | unpriced),
      matched: ($m | length),
      partial: (($o | length) > 0)
    }
  + (if ($o | length) > 0 then {run_overhead_usd: ($o | usd)} else {} end)' "$summaries"
