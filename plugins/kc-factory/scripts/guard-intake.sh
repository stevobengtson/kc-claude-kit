#!/usr/bin/env bash
# PreToolUse guard for the factory's intake agent (agent_type "kc-factory:intake").
# That agent reads hostile ticket text, and what it writes is posted back to the
# ticket, so it gets the least it needs:
#   - Write, Edit, MultiEdit: only a file named intake.md directly inside
#     <repo>/.factory/jobs/<KEY>/.
#   - Read, Glob, Grep: only inside the repo, and never a secret-looking path
#     (.env*, *.pem, *.key, id_*, .ssh/, .aws/, .netrc, *credentials*, *secret*,
#     .git/). Glob and Grep patterns may not be absolute or use "..".
#   - No path or pattern may start with "~".
#   - Every other tool: denied.
# Paths are made absolute against the hook's cwd, ".." is collapsed, and the real
# path (symlinks followed) is what is compared. The repo is the git top level of
# the hook's cwd, or the cwd itself outside git. Other agents and the main
# session pass untouched.
#
# Input: PreToolUse JSON on stdin (tool_name, tool_input, agent_type, cwd).
# Hook schema and deny JSON: https://code.claude.com/docs/en/hooks
# Output: the PreToolUse deny JSON on a block, nothing otherwise.
# Exit: always 0. Fails closed for the intake agent when jq is missing, the
# input cannot be parsed, or the guard itself errors.
#
# Only `set -u`: a failing command must never abort the guard and let the tool
# call through (a hook that errors is non-blocking). `set -f`: no globbing.
set -u
set -f

input=""
IFS= read -r -d '' input || true

readonly INTAKE_AGENT='"agent_type"[[:space:]]*:[[:space:]]*"kc-factory:intake"'
looks_like_intake() { [[ $input =~ $INTAKE_AGENT ]]; }

decided=0
deny() {
  local json=""
  decided=1
  if command -v jq >/dev/null 2>&1; then
    json=$(jq -cn --arg reason "kc-factory intake: $1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}' 2>/dev/null)
  fi
  if [ -n "$json" ]; then
    printf '%s\n' "$json"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"kc-factory intake: %s"}}\n' \
      "${1//[\"\\]/}"
  fi
  exit 0
}

# An unexpected error denies instead of exiting non-zero, which Claude Code
# would treat as "allow".
# shellcheck disable=SC2317,SC2329
on_exit() {
  local status=$?
  if [ "$status" != 0 ] && [ "$decided" = 0 ] && looks_like_intake; then
    deny "guard error; refusing the tool call"
  fi
  exit 0
}
trap on_exit EXIT

if ! command -v jq >/dev/null 2>&1; then
  if looks_like_intake; then deny "jq is required for the intake guard"; fi
  exit 0
fi
if ! agent=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null); then
  if looks_like_intake; then deny "unreadable hook input"; fi
  exit 0
fi
[ "$agent" = kc-factory:intake ] || exit 0

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
tool=$(field .tool_name)
cwd=$(field .cwd)
[ -n "$cwd" ] || cwd=$PWD

# lexical <path> <base>: <path> made absolute against <base>, with //, /./ and
# /../ collapsed, so a ".." cannot step out of an allowed directory.
lexical() {
  local path=$1 out="" seg
  case "$path" in /*) ;; *) path="$2/$path" ;; esac
  local IFS=/
  for seg in $path; do
    case "$seg" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# real <absolute path>: the path with every symlink followed, for a path that
# may not exist yet (its nearest existing directory is resolved and the rest
# appended). Fails on a symlink loop or a dangling link on the way.
real() {
  local path=$1 hops=0 target dir rest=""
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    target=$(readlink "$path") || return 1
    case "$target" in /*) ;; *) target="${path%/*}/$target" ;; esac
    path=$(lexical "$target" /)
  done
  dir=$path
  while [ ! -d "$dir" ]; do
    [ ! -L "$dir" ] || return 1
    rest="/${dir##*/}$rest"
    dir=${dir%/*}
    [ -n "$dir" ] || dir=/
  done
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  [ "$dir" != / ] || dir=""
  dir="$dir$rest"
  printf '%s' "${dir:-/}"
}

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || root=$cwd
root=$(real "$(lexical "$root" /)") || deny "cannot resolve the repo root"

# inside_root <real path>: is it the repo root or under it?
inside_root() { [ "$1" = "$root" ] || [ "${1#"$root"/}" != "$1" ]; }

# secret <real path inside the root>: does any part of it look like a secret?
secret() {
  local rel=${1#"$root"} seg base lower
  base=${rel##*/}
  local IFS=/
  for seg in $rel; do
    lower=$(printf '%s' "$seg" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      .env*|.ssh|.aws|.git|*credentials*|*secret*) return 0 ;;
    esac
  done
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.pem|*.key|id_*|.netrc) return 0 ;;
  esac
  return 1
}

# no_home <path>: deny a path starting with "~". Claude Code expands it to a
# home directory, which this guard would otherwise join onto the cwd.
no_home() {
  case "$1" in '~'*) deny "$tool of a ~ path is not allowed: $1" ;; esac
}

# readable <path>: deny unless it is inside the repo and not secret-looking.
readable() {
  local abs resolved
  [ -n "$1" ] || deny "$tool needs a path"
  no_home "$1"
  abs=$(lexical "$1" "$cwd")
  resolved=$(real "$abs") || deny "cannot resolve $1"
  inside_root "$resolved" || deny "$tool outside the repo is not allowed: $1"
  if secret "$resolved" || secret "$root${abs#"${abs%/*}"}"; then
    deny "$tool of a secret-looking path is not allowed: $1"
  fi
}

# safe_pattern <glob>: relative, with no ".." part.
safe_pattern() {
  case "$1" in
    /*|'~'*) deny "$tool patterns must be relative: $1" ;;
    ..|../*|*/..|*/../*) deny "$tool patterns may not use ..: $1" ;;
  esac
}

case "$tool" in
  Write|Edit|MultiEdit)
    file=$(field .tool_input.file_path)
    [ -n "$file" ] || deny "$tool needs a file_path"
    no_home "$file"
    resolved=$(real "$(lexical "$file" "$cwd")") || deny "cannot resolve $file"
    job_dir=${resolved%/*}
    key=${job_dir##*/}
    if [ "${resolved##*/}" = intake.md ] && [ "${job_dir%/*}" = "$root/.factory/jobs" ] \
      && [[ $key =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
      exit 0
    fi
    deny "it may write only .factory/jobs/<KEY>/intake.md, not $file"
    ;;
  Read)
    readable "$(field .tool_input.file_path)"
    ;;
  Glob)
    safe_pattern "$(field .tool_input.pattern)"
    path=$(field .tool_input.path)
    readable "${path:-$cwd}"
    ;;
  Grep)
    glob=$(field .tool_input.glob)
    [ -z "$glob" ] || safe_pattern "$glob"
    path=$(field .tool_input.path)
    readable "${path:-$cwd}"
    ;;
  *)
    deny "only Read, Glob, Grep and writing its intake.md are allowed, not ${tool:-an unnamed tool}"
    ;;
esac
exit 0
