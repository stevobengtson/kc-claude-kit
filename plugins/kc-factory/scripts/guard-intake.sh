#!/usr/bin/env bash
# PreToolUse guard for the factory's intake agent (agent_type "kc-factory:intake").
# That agent reads hostile ticket text, and what it writes is posted back to the
# ticket, so it gets the least it needs:
#   - Write, Edit, MultiEdit: only a file named intake.md directly inside
#     <repo>/.factory/jobs/<KEY>/.
#   - Read, Glob: only inside the repo, and never a secret-looking path
#     (.env*, *.pem, *.key, id_*, .ssh/, .aws/, .netrc, *credentials*, *secret*,
#     .git/). Glob patterns may not be absolute or use "..".
#   - Grep: one named file that Read may read. Grep reads the contents of every
#     file it searches, so a directory could reach a secret-looking file.
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
  local status=$? exited_badly=false undecided=false
  [ "$status" = 0 ] || exited_badly=true
  [ "$decided" = 1 ] || undecided=true
  if [ "$exited_badly" = true ] && [ "$undecided" = true ] && looks_like_intake; then
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

read_hook_field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
tool=$(read_hook_field .tool_name)
cwd=$(read_hook_field .cwd)
[ -n "$cwd" ] || cwd=$PWD

# normalize_path <path> <base>: <path> made absolute against <base>, with //, /./ and
# /../ collapsed, so a ".." cannot step out of an allowed directory.
normalize_path() {
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

# resolve_real_path <absolute path>: the path with every symlink followed, for a path that
# may not exist yet (its nearest existing directory is resolved and the rest
# appended). Fails on a symlink loop or a dangling link on the way.
resolve_real_path() {
  # 40 is the symlink-loop limit common to Linux and macOS.
  local path=$1 hops=0 max_hops=40 target dir rest=""
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le "$max_hops" ] || return 1
    target=$(readlink "$path") || return 1
    case "$target" in /*) ;; *) target="${path%/*}/$target" ;; esac
    path=$(normalize_path "$target" /)
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
root=$(resolve_real_path "$(normalize_path "$root" /)") || deny "cannot resolve the repo root"

# is_inside_repo_root <real path>: is it the repo root or under it?
is_inside_repo_root() {
  local is_root=false is_under_root=false
  [ "$1" != "$root" ] || is_root=true
  [ "${1#"$root"/}" = "$1" ] || is_under_root=true
  [ "$is_root" = true ] || [ "$is_under_root" = true ]
}

# is_secret_looking_path <real path inside the root>: does any part of it look like a secret?
is_secret_looking_path() {
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

# deny_tilde_path <path>: deny a path starting with "~". Claude Code expands it to a
# home directory, which this guard would otherwise join onto the cwd.
deny_tilde_path() {
  case "$1" in '~'*) deny "$tool of a ~ path is not allowed: $1" ;; esac
}

# deny_unless_readable <path>: deny unless it is inside the repo and not secret-looking.
deny_unless_readable() {
  local abs resolved
  [ -n "$1" ] || deny "$tool needs a path"
  deny_tilde_path "$1"
  abs=$(normalize_path "$1" "$cwd")
  resolved=$(resolve_real_path "$abs") || deny "cannot resolve $1"
  is_inside_repo_root "$resolved" || deny "$tool outside the repo is not allowed: $1"
  if is_secret_looking_path "$resolved" || is_secret_looking_path "$root${abs#"${abs%/*}"}"; then
    deny "$tool of a secret-looking path is not allowed: $1"
  fi
}

# deny_unsafe_pattern <glob>: relative, with no ".." part.
deny_unsafe_pattern() {
  deny_tilde_path "$1"
  case "$1" in
    /*) deny "$tool patterns must be relative: $1" ;;
    ..|../*|*/..|*/../*) deny "$tool patterns may not use ..: $1" ;;
  esac
}

case "$tool" in
  Write|Edit|MultiEdit)
    file=$(read_hook_field .tool_input.file_path)
    [ -n "$file" ] || deny "$tool needs a file_path"
    deny_tilde_path "$file"
    resolved=$(resolve_real_path "$(normalize_path "$file" "$cwd")") || deny "cannot resolve $file"
    job_dir=${resolved%/*}
    key=${job_dir##*/}
    is_intake_file=false is_in_jobs_dir=false is_ticket_key=false
    [ "${resolved##*/}" != intake.md ] || is_intake_file=true
    [ "${job_dir%/*}" != "$root/.factory/jobs" ] || is_in_jobs_dir=true
    [[ ! $key =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || is_ticket_key=true
    if [ "$is_intake_file" = true ] && [ "$is_in_jobs_dir" = true ] && [ "$is_ticket_key" = true ]; then
      exit 0
    fi
    deny "it may write only .factory/jobs/<KEY>/intake.md, not $file"
    ;;
  Read)
    deny_unless_readable "$(read_hook_field .tool_input.file_path)"
    ;;
  Glob)
    deny_unsafe_pattern "$(read_hook_field .tool_input.pattern)"
    path=$(read_hook_field .tool_input.path)
    deny_unless_readable "${path:-$cwd}"
    ;;
  Grep)
    path=$(read_hook_field .tool_input.path)
    [ -n "$path" ] || deny "Grep may search one named file; use Glob to find files, then Read or Grep one"
    deny_unless_readable "$path"
    [ -f "$(resolve_real_path "$(normalize_path "$path" "$cwd")")" ] \
      || deny "Grep may search one named file, not a directory: $path; use Glob to find files, then Read or Grep one"
    ;;
  *)
    deny "only Read, Glob, Grep and writing its intake.md are allowed, not ${tool:-an unnamed tool}"
    ;;
esac
exit 0
