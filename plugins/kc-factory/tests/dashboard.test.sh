#!/usr/bin/env bash
# Tests scripts/dashboard.sh: refuses with no jobs, serves the page and
# jobs/index.json on localhost, rejects a bad port, and the page never
# assigns data through innerHTML.
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir=$(dirname "$tests_dir")
script="$plugin_dir/scripts/dashboard.sh"
work=$(mktemp -d)
server_pid=""
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "dashboard.test: python3 is required" >&2; exit 2; }

# No jobs yet: refuses with the pointer to /kc-factory:factory.
mkdir -p "$work/empty"
status=0
err=$(FACTORY_HOME="$work/empty" bash "$script" 2>&1 >/dev/null) || status=$?
if [ "$status" = 1 ] && [ "$err" = "dashboard: no .factory/jobs/index.json yet — run /kc-factory:factory first" ]; then
  pass "no jobs: refuses with exit 1 and the pointer"
else
  fail "no jobs: refuses with exit 1 and the pointer" "status $status, stderr: $err"
fi

# Bad port: exit 2.
mkdir -p "$work/home/jobs"
echo '[{"key":"ABC-1","stage":"ready","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T01:00:00Z","history":[],"title":"Add a wishlist","cost_usd":null},{"key":"ABC-2","stage":"delivering","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:10:00Z","history":[],"risk":"low","surfaces":["storefront"],"cost_usd":1.5}]' > "$work/home/jobs/index.json"
status=0
FACTORY_HOME="$work/home" bash "$script" notaport >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then
  pass "bad port: exits 2"
else
  fail "bad port: exits 2" "status $status"
fi

# Serve on a free port.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
FACTORY_HOME="$work/home" bash "$script" "$port" > "$work/server.out" 2>&1 &
server_pid=$!

up=0
for _ in $(seq 1 25); do
  if curl -fs -o /dev/null "http://127.0.0.1:$port/index.html"; then up=1; break; fi
  sleep 0.2
done
if [ "$up" = 1 ]; then
  pass "serve: answers on the port"
else
  fail "serve: answers on the port" "$(cat "$work/server.out")"
fi

code=$(curl -s -o "$work/page.html" -w '%{http_code}' "http://127.0.0.1:$port/index.html" || true)
if [ "$code" = 200 ] && grep -q 'jobs/index.json' "$work/page.html"; then
  pass "page: 200 and references jobs/index.json"
else
  fail "page: 200 and references jobs/index.json" "code $code"
fi

code=$(curl -s -o "$work/index.json" -w '%{http_code}' "http://127.0.0.1:$port/jobs/index.json" || true)
if [ "$code" = 200 ] && [ "$(jq length "$work/index.json")" = 2 ]; then
  pass "jobs/index.json: 200 with both jobs"
else
  fail "jobs/index.json: 200 with both jobs" "code $code"
fi

if grep -q "http://127.0.0.1:$port" "$work/server.out"; then
  pass "serve: prints the URL"
else
  fail "serve: prints the URL" "$(cat "$work/server.out")"
fi

# Data reaches the DOM through textContent only.
if grep -q 'innerHTML' "$plugin_dir/dashboard/index.html"; then
  fail "page: no innerHTML" "dashboard/index.html uses innerHTML"
else
  pass "page: no innerHTML"
fi

echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
