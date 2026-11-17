#!/usr/bin/env bash
# Serves the browser dashboard on localhost only. FACTORY_HOME (default
# <repo>/.factory, as job.sh resolves it) is never served whole: dashboard-server.py
# serves the plugin's own page and an allowlist of job files under jobs/.
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

# shellcheck source=factory-home.sh
. "$(dirname "$0")/factory-home.sh"
resolve_factory_home dashboard

if [ ! -f "$home/jobs/index.json" ]; then
  echo "dashboard: no .factory/jobs/index.json yet — run /kc-factory:factory first" >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)

echo "dashboard: http://127.0.0.1:$port/"
exec python3 -I "$here/dashboard-server.py" "$port" "$home" "$here/../dashboard/index.html"
