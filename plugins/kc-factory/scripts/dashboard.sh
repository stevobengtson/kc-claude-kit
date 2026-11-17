#!/usr/bin/env bash
# Serves the browser dashboard: copies dashboard/index.html into FACTORY_HOME
# (default <repo>/.factory, as job.sh resolves it) and serves that folder on
# localhost only, so the page can read jobs/index.json and each job's files.
#
# Usage: dashboard.sh [port]     (default 8765)
# Exit: 0 server stopped; 1 no jobs yet ("dashboard: <problem>" on stderr);
#       2 bad port, python3 missing or outside a git repo without FACTORY_HOME.
set -euo pipefail

port=${1:-8765}
case $port in
  ''|*[!0-9]*) echo "dashboard: bad port: $port" >&2; exit 2 ;;
esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  echo "dashboard: bad port: $port" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "dashboard: python3 is required" >&2; exit 2; }

if [ -n "${FACTORY_HOME:-}" ]; then
  home=$FACTORY_HOME
elif root=$(git rev-parse --show-toplevel 2>/dev/null); then
  home="$root/.factory"
else
  echo "dashboard: set FACTORY_HOME outside a git repo" >&2
  exit 2
fi

if [ ! -f "$home/jobs/index.json" ]; then
  echo "dashboard: no .factory/jobs/index.json yet — run /kc-factory:factory first" >&2
  exit 1
fi

page_dir=$(cd "$(dirname "$0")/../dashboard" && pwd)
cp "$page_dir/index.html" "$home/index.html"

echo "dashboard: http://127.0.0.1:$port/"
cd "$home"
exec python3 -m http.server "$port" --bind 127.0.0.1
