#!/usr/bin/env bash
# Tests scripts/guard-intake.sh: the intake agent writes only its job's intake.md,
# reads only inside the repo and never a secret-looking path, and uses no other
# tool; every other agent and the main session pass untouched.
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
guard="$(dirname "$tests_dir")/scripts/guard-intake.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
passes=0
failures=0

# A repo with a job dir, a page, secrets, and a symlink pointing out of it.
repo="$tmp/shop"
git init -q -b main "$repo"
repo=$(cd "$repo" && pwd -P)
mkdir -p "$repo/.factory/jobs/ABC-1" "$repo/site" "$repo/config" "$repo/certs" "$repo/deploy" "$tmp/outside"
echo '<h1>Mugs</h1>' > "$repo/site/category.html"
echo 'API_KEY=x' > "$repo/.env"
echo 'API_KEY=x' > "$repo/config/.env.local"
echo 'pem' > "$repo/certs/server.pem"
echo '{}' > "$repo/deploy/credentials.json"
echo 'outside' > "$tmp/outside/notes.txt"
ln -s "$tmp/outside" "$repo/site/linked"
ln -s "$repo/.env" "$repo/site/settings.txt"
mkdir -p "$repo/.factory/jobs"
ln -s "$tmp/outside" "$repo/.factory/jobs/ABC-2"

I=kc-factory:intake

build_hook_payload() { # <agent> <tool> <tool_input json>
  jq -cn --arg agent "$1" --arg tool "$2" --argjson in "$3" --arg cwd "$repo" \
    '{hook_event_name:"PreToolUse",tool_name:$tool,tool_input:$in,cwd:$cwd} + (if $agent == "" then {} else {agent_type:$agent} end)'
}
build_path_input() { jq -cn --arg k "$1" --arg v "$2" '{($k): $v}'; }

check() { # <allow|deny> <label> <payload>
  local expectation=$1 label=$2 output verdict
  output=$(printf '%s' "$3" | bash "$guard")
  if [ -z "$output" ]; then verdict=allow
  elif printf '%s' "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | startswith("kc-factory intake: "))' >/dev/null 2>&1; then verdict=deny
  else verdict="unexpected: $output"; fi
  if [ "$verdict" = "$expectation" ]; then echo "ok   $label"; passes=$((passes + 1))
  else echo "FAIL $label"; echo "     expected $expectation, got $verdict"; failures=$((failures + 1)); fi
}

job="$repo/.factory/jobs/ABC-1"

# Writes.
check allow "write its job's intake.md"            "$(build_hook_payload $I Write "$(build_path_input file_path "$job/intake.md")")"
check allow "edit its job's intake.md"             "$(build_hook_payload $I Edit "$(build_path_input file_path "$job/intake.md")")"
check allow "a .. that lands back on intake.md"    "$(build_hook_payload $I Write "$(build_path_input file_path "$job/../ABC-1/intake.md")")"
check deny  "write another file in the job dir"    "$(build_hook_payload $I Write "$(build_path_input file_path "$job/ticket.md")")"
check deny  "write settings"                       "$(build_hook_payload $I Write "$(build_path_input file_path "$repo/.claude/settings.json")")"
check deny  "write intake.md outside a job dir"    "$(build_hook_payload $I Write "$(build_path_input file_path "$repo/intake.md")")"
check deny  ".. escape from the job dir"           "$(build_hook_payload $I Write "$(build_path_input file_path "$job/../../../intake.md")")"
check deny  "write a shell rc file"                "$(build_hook_payload $I Write "$(build_path_input file_path "$HOME/.bashrc")")"
check deny  "job dir that is a symlink out"        "$(build_hook_payload $I Write "$(build_path_input file_path "$repo/.factory/jobs/ABC-2/intake.md")")"
check deny  "write with no path"                   "$(build_hook_payload $I Write '{}')"
# shellcheck disable=SC2088 # a literal ~, as the agent would send it
check deny  "write under a ~ path"                 "$(build_hook_payload $I Write "$(build_path_input file_path "~/.factory/jobs/ABC-1/intake.md")")"
check deny  "MultiEdit elsewhere"                  "$(build_hook_payload $I MultiEdit "$(build_path_input file_path "$repo/site/category.html")")"

# Reads.
check allow "read a repo file"                     "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/site/category.html")")"
check allow "read its ticket"                      "$(build_hook_payload $I Read "$(build_path_input file_path "$job/ticket.md")")"
check allow "read a relative path in the repo"     "$(build_hook_payload $I Read "$(build_path_input file_path "site/category.html")")"
check deny  "read .env"                            "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/.env")")"
check deny  "read a nested .env.local"             "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/config/.env.local")")"
check deny  "read a .pem"                          "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/certs/server.pem")")"
check deny  "read a credentials file"              "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/deploy/credentials.json")")"
check deny  "read .git/config"                     "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/.git/config")")"
check deny  "read an innocent name linked to .env" "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/site/settings.txt")")"
check deny  "read outside the repo"                "$(build_hook_payload $I Read "$(build_path_input file_path "/etc/passwd")")"
check deny  "read ~/.ssh"                          "$(build_hook_payload $I Read "$(build_path_input file_path "$HOME/.ssh/id_rsa")")"
check deny  "read via .. out of the repo"          "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/site/../../outside/notes.txt")")"
check deny  "read via a symlink out of the repo"   "$(build_hook_payload $I Read "$(build_path_input file_path "$repo/site/linked/notes.txt")")"
check deny  "read with no path"                    "$(build_hook_payload $I Read '{}')"
# shellcheck disable=SC2088 # a literal ~, as the agent would send it
check deny  "read a ~ path"                        "$(build_hook_payload $I Read "$(build_path_input file_path "~/.zsh_history")")"
check deny  "read a bare ~"                        "$(build_hook_payload $I Read "$(build_path_input file_path "~")")"
check deny  "read a ~user path"                    "$(build_hook_payload $I Read "$(build_path_input file_path "~root/.ssh/id_rsa")")"

# Glob and Grep.
check allow "glob in the repo"                     "$(build_hook_payload $I Glob '{"pattern":"**/*.html"}')"
check allow "glob under a repo dir"                "$(build_hook_payload $I Glob "$(jq -cn --arg p "$repo/site" '{pattern:"*.html",path:$p}')")"
check deny  "glob an absolute pattern"             "$(build_hook_payload $I Glob '{"pattern":"/etc/*"}')"
check deny  "glob a home pattern"                  "$(build_hook_payload $I Glob '{"pattern":"~/.ssh/*"}')"
check deny  "glob a .. pattern"                    "$(build_hook_payload $I Glob '{"pattern":"../**"}')"
check deny  "glob outside the repo"                "$(build_hook_payload $I Glob "$(jq -cn --arg p "$tmp/outside" '{pattern:"*",path:$p}')")"
check deny  "glob under a ~ path"                  "$(build_hook_payload $I Glob '{"pattern":"*","path":"~/.ssh"}')"
check deny  "grep under a ~ path"                  "$(build_hook_payload $I Grep '{"pattern":"x","path":"~/.claude"}')"
check allow "grep one repo file"                   "$(build_hook_payload $I Grep "$(jq -cn --arg p "$repo/site/category.html" '{pattern:"Mugs",path:$p}')")"
check deny  "grep with no path (the whole repo)"   "$(build_hook_payload $I Grep '{"pattern":"Mugs"}')"
check deny  "grep a directory for *.pem files"     "$(build_hook_payload $I Grep '{"pattern":"KEY","path":".","glob":"*.pem","output_mode":"content"}')"
check deny  "grep the repo dir"                    "$(build_hook_payload $I Grep "$(jq -cn --arg p "$repo" '{pattern:"KEY",path:$p}')")"
check deny  "grep .env"                            "$(build_hook_payload $I Grep "$(jq -cn --arg p "$repo/.env" '{pattern:"KEY",path:$p}')")"
check deny  "grep outside the repo"                "$(build_hook_payload $I Grep "$(jq -cn --arg p "$tmp/outside" '{pattern:"x",path:$p}')")"
check deny  "grep with a .. glob and no path"      "$(build_hook_payload $I Grep '{"pattern":"x","glob":"../**"}')"

# Other tools.
check deny  "Bash"                                 "$(build_hook_payload $I Bash '{"command":"cat .env"}')"
check deny  "WebFetch"                             "$(build_hook_payload $I WebFetch '{"url":"https://shop.example.com"}')"
check deny  "an MCP tool"                          "$(build_hook_payload $I mcp__tracker__addComment '{"body":"x"}')"

# Other agents and the main session pass untouched.
check allow "another agent writes anywhere"        "$(build_hook_payload kc-autopilot:engineer Write "$(build_path_input file_path "$repo/site/category.html")")"
check allow "the main session reads .env"          "$(build_hook_payload "" Read "$(build_path_input file_path "$repo/.env")")"
check allow "another agent runs Bash"              "$(build_hook_payload kc-factory:other Bash '{"command":"ls"}')"

# Fails closed for the intake agent on input it cannot read.
check deny  "unreadable input from intake"         '{"agent_type":"kc-factory:intake", nope'
check allow "unreadable input from anyone else"    '{"agent_type":"kc-autopilot:engineer", nope'

echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
