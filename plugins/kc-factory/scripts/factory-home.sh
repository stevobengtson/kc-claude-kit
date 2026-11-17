#!/usr/bin/env bash
# Where the factory keeps its state. Sourced by job.sh, plan.sh and dashboard.sh.

# resolve_factory_home <message prefix>: sets $home to $FACTORY_HOME, or to
# <repo>/.factory inside a git repo; outside one, without FACTORY_HOME, prints
# "<prefix>: set FACTORY_HOME outside a git repo" and exits 2.
# shellcheck disable=SC2034 # home is read by the script that sources this file
resolve_factory_home() {
  local repo_root
  if [ -n "${FACTORY_HOME:-}" ]; then
    home=$FACTORY_HOME
  elif repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    home="$repo_root/.factory"
  else
    echo "$1: set FACTORY_HOME outside a git repo" >&2
    exit 2
  fi
}
