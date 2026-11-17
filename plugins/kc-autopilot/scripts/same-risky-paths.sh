#!/usr/bin/env bash
# Checks that a run's config (kc-run --config) guards the same paths as the
# repo's .claude/autopilot.json. guard.sh reads risky_paths from the repo's file,
# never from the run's, so a run config that lists other paths would look
# guarded and not be.
#
# Usage: same-risky-paths.sh <run-config.json> <repo .claude/autopilot.json>
# Exit: 0 same risky_paths (a missing list counts as []); 1 they differ or a
# file is missing or not JSON ("config: <problem>" on stderr); 2 jq missing or
# a usage error.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "config: jq is required" >&2; exit 2; }
[ "$#" = 2 ] || { echo "usage: same-risky-paths.sh <run-config.json> <repo-config.json>" >&2; exit 2; }
run_config=$1 repo_config=$2

for config_file in "$run_config" "$repo_config"; do
  [ -f "$config_file" ] || { echo "config: $config_file not found" >&2; exit 1; }
  jq -e . "$config_file" >/dev/null 2>&1 || { echo "config: $config_file is not valid JSON" >&2; exit 1; }
done

if ! jq -e -n --slurpfile run "$run_config" --slurpfile repo "$repo_config" \
  '($run[0].risky_paths // []) == ($repo[0].risky_paths // [])' >/dev/null; then
  echo "config: $run_config lists other risky_paths than $repo_config; the guard reads only $repo_config, so copy its risky_paths into the run config" >&2
  exit 1
fi
