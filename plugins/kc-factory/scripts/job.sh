#!/usr/bin/env bash
# The only writer of job state. Jobs live at $FACTORY_HOME/jobs/<KEY>/job.json
# (FACTORY_HOME defaults to <repo>/.factory); jobs/index.json lists every job
# for the dashboard and is rewritten after each write.
#
# Usage:
#   job.sh create <KEY> <config.json>   print the job dir (config is read-config.sh output)
#   job.sh advance <KEY> <stage>        move the job one legal step
#   job.sh set <KEY> <field> <json>     set risk, surfaces, run_id, unit, pr_url,
#                                       branch, title, reason or cost_usd
#   job.sh show <KEY>                   print job.json
#   job.sh list                         print KEY<TAB>stage<TAB>title per job
# Exit: 0 ok; 1 refused ("job: <problem>" on stderr); 2 jq missing or bad usage.
# Set FACTORY_NOW to pin the clock (tests).
# jq programs are single-quoted on purpose; their $vars are jq variables.
# shellcheck disable=SC2016
set -euo pipefail

# Legal moves: "<from> <to>..." per line. A stage with no targets is terminal.
transitions='intake needs-info rejected queued
needs-info intake rejected
queued delivering blocked
delivering ready blocked
blocked queued rejected
ready
rejected'
settable_fields='risk surfaces run_id unit pr_url branch title reason cost_usd'

command -v jq >/dev/null 2>&1 || { echo "job: jq is required" >&2; exit 2; }

usage() {
  echo "job: usage: job.sh create <KEY> <config.json> | advance <KEY> <stage> | set <KEY> <field> <json> | show <KEY> | list" >&2
  exit 2
}
refuse() { echo "job: $*" >&2; exit 1; }

if [ -n "${FACTORY_HOME:-}" ]; then
  home=$FACTORY_HOME
elif root=$(git rev-parse --show-toplevel 2>/dev/null); then
  home="$root/.factory"
else
  echo "job: set FACTORY_HOME outside a git repo" >&2
  exit 2
fi
jobs_dir="$home/jobs"

now() { echo "${FACTORY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

# Runs jq with the given arguments and replaces <dest> with its output, via a
# temp file, only when jq succeeds: a failed jq never truncates <dest>.
write_jq() {
  local dest=$1 tmp
  shift
  tmp=$(mktemp "$dest.XXXXXX")
  if jq "$@" > "$tmp"; then
    mv "$tmp" "$dest"
  else
    rm -f "$tmp"
    refuse "could not write $dest"
  fi
}

rewrite_index() {
  local files=()
  [ -d "$jobs_dir" ] && while IFS= read -r f; do files+=("$f"); done < <(find "$jobs_dir" -mindepth 2 -maxdepth 2 -name job.json)
  if [ "${#files[@]}" = 0 ]; then
    write_jq "$jobs_dir/index.json" -n '[]'
  else
    write_jq "$jobs_dir/index.json" -s 'sort_by(.key)' "${files[@]}"
  fi
}

job_file() { echo "$jobs_dir/$1/job.json"; }

require_job() {
  [ -f "$(job_file "$1")" ] || refuse "$1 has no job"
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  create)
    [ "$#" = 2 ] || usage
    key=$1 config=$2
    case "$key" in *$'\n'*) refuse "key must be a single line" ;; esac
    [ -f "$config" ] || refuse "$config not found"
    pattern=$(jq -r '"^(" + (.tracker.project_keys | join("|")) + ")-[0-9]+$"' "$config")
    printf '%s' "$key" | grep -Eq "$pattern" || refuse "$key is not a ticket key in project_keys"
    file=$(job_file "$key")
    if [ -f "$file" ]; then
      existing=$(jq -r '.stage' "$file")
      case "$existing" in
        queued|delivering) refuse "$key is already $existing" ;;
      esac
      echo "$jobs_dir/$key"
      exit 0
    fi
    mkdir -p "$jobs_dir/$key"
    at=$(now)
    write_jq "$file" -n --arg key "$key" --arg at "$at" \
      '{key: $key, stage: "intake", created_at: $at, updated_at: $at, history: [{stage: "intake", at: $at}]}'
    rewrite_index
    echo "$jobs_dir/$key"
    ;;
  advance)
    [ "$#" = 2 ] || usage
    key=$1 to=$2
    require_job "$key"
    file=$(job_file "$key")
    from=$(jq -r '.stage' "$file")
    legal=$(printf '%s\n' "$transitions" | awk -v from="$from" -v to="$to" '$1 == from { for (i = 2; i <= NF; i++) if ($i == to) print "yes" }')
    [ "$legal" = yes ] || refuse "$key cannot move from $from to $to"
    at=$(now)
    write_jq "$file" --arg to "$to" --arg at "$at" \
      '.stage = $to | .updated_at = $at | .history += [{stage: $to, at: $at}]' "$file"
    rewrite_index
    ;;
  set)
    [ "$#" = 3 ] || usage
    key=$1 field=$2 value=$3
    require_job "$key"
    case " $settable_fields " in
      *" $field "*) ;;
      *) refuse "$field is not a settable field" ;;
    esac
    printf '%s' "$value" | jq empty >/dev/null 2>&1 || refuse "value for $field is not valid JSON"
    file=$(job_file "$key")
    write_jq "$file" --arg field "$field" --argjson value "$value" --arg at "$(now)" \
      '.[$field] = $value | .updated_at = $at' "$file"
    rewrite_index
    ;;
  show)
    [ "$#" = 1 ] || usage
    require_job "$1"
    cat "$(job_file "$1")"
    ;;
  list)
    [ "$#" = 0 ] || usage
    [ -d "$jobs_dir" ] || exit 0
    find "$jobs_dir" -mindepth 2 -maxdepth 2 -name job.json -print0 \
      | xargs -0 -r jq -rs 'sort_by(.key)[] | [.key, .stage, (.title // "")] | @tsv'
    ;;
  *) usage ;;
esac
