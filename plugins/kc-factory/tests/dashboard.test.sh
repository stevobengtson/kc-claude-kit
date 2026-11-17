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
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
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
mkdir -p "$work/home/jobs/ABC-1" "$work/home/runs/x"
echo 'ticket text' > "$work/home/jobs/ABC-1/ticket.md"
echo 'one' > "$work/home/jobs/ABC-1/feedback-1.md"
echo 'twenty' > "$work/home/jobs/ABC-1/feedback-20.md"
echo '{"secret":true}' > "$work/home/runs/x/autopilot.json"
echo '{"outside":true}' > "$work/f.json"
echo 'job private' > "$work/home/jobs/ABC-1/job.json"
ln -s "$work/f.json" "$work/home/jobs/ABC-1/routing.json"
echo '[{"key":"ABC-1","stage":"ready","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T01:00:00Z","history":[],"title":"Add a wishlist","cost_usd":null},{"key":"ABC-2","stage":"delivering","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:10:00Z","history":[],"risk":"low","surfaces":["storefront"],"cost_usd":1.5}]' > "$work/home/jobs/index.json"
status=0
FACTORY_HOME="$work/home" bash "$script" notaport >/dev/null 2>&1 || status=$?
for bad_port in 0 65536; do
  bad_status=0
  FACTORY_HOME="$work/home" bash "$script" "$bad_port" >/dev/null 2>&1 || bad_status=$?
  if [ "$bad_status" = 2 ]; then pass "port $bad_port: exits 2"; else fail "port $bad_port: exits 2" "status $bad_status"; fi
done
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

base="http://127.0.0.1:$port"
# expect_status_code <expected> <label> <curl args...>
expect_status_code() {
  local expected=$1 label=$2 got
  shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "$@" || true)
  if [ "$got" = "$expected" ]; then pass "$label"; else fail "$label" "wanted $expected, got $got"; fi
}
expect_status_code 403 "server (dashboard-server.py): foreign Host header is refused" -H 'Host: evil.test' "$base/"
expect_status_code 403 "server: foreign Host with the right port is refused" -H "Host: evil.test:$port" "$base/jobs/index.json"
expect_status_code 200 "server: localhost Host is accepted" -H "Host: localhost:$port" "$base/"
expect_status_code 200 "server: allowed job file" "$base/jobs/ABC-1/ticket.md"
if [ "$(curl -s "$base/jobs/ABC-1/ticket.md")" = "ticket text" ]; then pass "server: serves the job file's text"; else fail "server: serves the job file's text" "$(curl -s "$base/jobs/ABC-1/ticket.md")"; fi
content_type_of() { curl -s -o /dev/null -w '%{content_type}' "$1"; }
if [ "$(content_type_of "$base/jobs/ABC-1/ticket.md")" = "text/plain; charset=utf-8" ]; then pass "server: a job file is plain text"; else fail "server: a job file is plain text" "$(content_type_of "$base/jobs/ABC-1/ticket.md")"; fi
if [ "$(content_type_of "$base/jobs/index.json")" = "application/json; charset=utf-8" ]; then pass "server: the index is JSON"; else fail "server: the index is JSON" "$(content_type_of "$base/jobs/index.json")"; fi
head_reply=$(curl -s -I -o /dev/null -w '%{http_code} %{size_download}' "$base/jobs/ABC-1/ticket.md")
if [ "$head_reply" = "200 0" ]; then pass "server: HEAD answers with no body"; else fail "server: HEAD answers with no body" "$head_reply"; fi
expect_status_code 200 "server: allowed feedback file" "$base/jobs/ABC-1/feedback-1.md"
if [ "$(curl -s "$base/jobs/ABC-1/feedback-1.md")" = "one" ]; then pass "server: serves the feedback text"; else fail "server: serves the feedback text" "$(curl -s "$base/jobs/ABC-1/feedback-1.md")"; fi
expect_status_code 200 "server: a later feedback file" "$base/jobs/ABC-1/feedback-20.md"
expect_status_code 404 "server: missing allowed name is 404" "$base/jobs/ABC-1/intake.md"
expect_status_code 404 "server: runs/ is not served" "$base/runs/x/autopilot.json"
expect_status_code 404 "server: dot-dot escape is 404" "$base/jobs/ABC-1/../../f.json"
expect_status_code 404 "server: encoded dot-dot escape is 404" "$base/jobs/ABC-1/%2e%2e/%2e%2e/f.json"
expect_status_code 404 "server: symlink escape is 404" "$base/jobs/ABC-1/routing.json"
expect_status_code 404 "server: file outside the allowlist is 404" "$base/jobs/ABC-1/job.json"
expect_status_code 404 "server: bad key is 404" "$base/jobs/abc-1/ticket.md"
expect_status_code 404 "server: feedback-0 is not a feedback file" "$base/jobs/ABC-1/feedback-0.md"
expect_status_code 405 "server: POST is refused" -X POST "$base/"
if [ "$(curl -s -D - -o /dev/null "$base/jobs/ABC-1/ticket.md" | tr -d '\r' | grep -ic '^x-content-type-options: nosniff')" = 1 ]; then
  pass "server: sends nosniff"
else
  fail "server: sends nosniff" "header missing"
fi
if grep -q 'could not load' "$plugin_dir/dashboard/index.html"; then
  pass "page: reports fetch errors"
else
  fail "page: reports fetch errors" "no could-not-load message"
fi

# A partial cost reads "$X+" and says, as the cost's tooltip, what it leaves out.
if command -v node >/dev/null 2>&1; then
  costs=$(node -e '
    const page = require("fs").readFileSync(process.argv[1], "utf8");
    const note = page.match(/var PARTIAL_COST_NOTE = [^;]*;/)[0];
    const fn = page.match(/function formatCost\(c, partial\) \{[\s\S]*?\n\}/)[0];
    const formatCost = new Function(note + fn + "; return formatCost;")();
    console.log([formatCost(1.5, true), formatCost(1.5, false), formatCost(1.5), formatCost(null, true)].join("|"));
  ' "$plugin_dir/dashboard/index.html" 2>&1) || true
  # shellcheck disable=SC2016 # literal dollar amounts
  if [ "$costs" = '$1.50+|$1.50|$1.50|cost unavailable' ]; then
    pass "page: a partial cost is \$X+"
  else
    fail "page: a partial cost is \$X+" "$costs"
  fi
fi
# The page's own logic, run in node: the link check, elapsed time and the Summary extract.
if command -v node >/dev/null 2>&1; then
  page_logic=$(node -e '
    const page = require("fs").readFileSync(process.argv[1], "utf8");
    const grab = re => page.match(re)[0];
    const consts = ["RUNNING", "SECOND_MS", "SECONDS_PER_MINUTE", "MINUTES_PER_HOUR"].map(n => grab(new RegExp("var " + n + " = [^;]*;"))).join("\n");
    const fns = ["safeUrl", "formatElapsed", "getElapsedMs", "getFileSummary"].map(n => grab(new RegExp("function " + n + "\\([^)]*\\) \\{[\\s\\S]*?\\n\\}"))).join("\n");
    const lib = new Function("Date", consts + fns + "; return {safeUrl, formatElapsed, getElapsedMs, getFileSummary};");
    const FixedDate = { parse: Date.parse, now: () => Date.parse("2026-11-17T12:00:00Z") };
    const p = lib(FixedDate);
    const out = [
      p.safeUrl("https://x"), p.safeUrl("javascript:alert(1)"), p.safeUrl("http://x"), p.safeUrl(42),
      p.formatElapsed(59999), p.formatElapsed(60000), p.formatElapsed(3600000),
      p.getElapsedMs({ stage: "delivering", created_at: "2026-11-17T11:48:00Z", updated_at: "2026-11-17T11:50:00Z" }),
      p.getElapsedMs({ stage: "ready", created_at: "2026-11-17T10:00:00Z", updated_at: "2026-11-17T10:42:00Z" }),
      p.getElapsedMs({ stage: "ready", created_at: "garbage", updated_at: "2026-11-17T10:42:00Z" }),
      p.getFileSummary("DECISION: ACCEPT\n\n## Summary\n- one\n- two\n\n## Scope\nx"),
      p.getFileSummary("no summary here"),
    ];
    console.log(JSON.stringify(out));
  ' "$plugin_dir/dashboard/index.html" 2>&1) || true
  # shellcheck disable=SC2016 # literal JSON
  expected='["https://x",null,null,null,"59s","1m","1h 0m",720000,2520000,null,"- one\n- two",null]'
  if [ "$page_logic" = "$expected" ]; then pass "page: link check, elapsed time and summary"; else fail "page: link check, elapsed time and summary" "$page_logic"; fi
fi

# A drawn card links only an https:// PR URL; anything else is shown as text.
if command -v node >/dev/null 2>&1; then
  drawn_links=$(node -e '
    const page = require("fs").readFileSync(process.argv[1], "utf8");
    const script = page.match(/<script>([\s\S]*)<\/script>/)[1];
    const makeNode = tag => ({ tag, children: [], dataset: {}, attributes: {}, className: "", textContent: "",
      appendChild(child) { this.children.push(child); return child; }, replaceChildren() { this.children = []; },
      setAttribute(name, value) { this.attributes[name] = value; }, addEventListener() {}, focus() {} });
    const document = { createElement: makeNode, getElementById: () => makeNode("div"), activeElement: null };
    const run = new Function("document", "fetch", "setInterval", script + "; return drawCard;");
    const drawCard = run(document, () => new Promise(() => {}), () => 0);
    const links = card => { const found = []; const walk = n => { if (n.tag === "a") found.push(n.href); n.children.forEach(walk); }; walk(card); return found; };
    const job = url => ({ key: "ABC-1", stage: "ready", created_at: "2026-11-17T10:00:00Z", updated_at: "2026-11-17T10:42:00Z", pr_url: url });
    console.log(JSON.stringify([links(drawCard(job("https://x/pull/1"))), links(drawCard(job("javascript:alert(1)"))), links(drawCard(job("http://x")))]));
  ' "$plugin_dir/dashboard/index.html" 2>&1) || true
  if [ "$drawn_links" = '[["https://x/pull/1"],[],[]]' ]; then pass "page: a card links only an https PR URL"; else fail "page: a card links only an https PR URL" "$drawn_links"; fi
fi

# A redraw gives keyboard focus back to the card that had it.
if command -v node >/dev/null 2>&1; then
  refocused=$(node -e '
    const page = require("fs").readFileSync(process.argv[1], "utf8");
    const fn = page.match(/function restoreFocus\(container, focusedKey\) \{[\s\S]*?\n\}/)[0];
    const restoreFocus = new Function(fn + "; return restoreFocus;")();
    const focused = [];
    const card = key => ({ dataset: { key }, focus: () => focused.push(key) });
    const container = { children: [card("ABC-1"), card("ABC-2")] };
    restoreFocus(container, "ABC-2");
    restoreFocus(container, null);
    restoreFocus(container, "ABC-9");
    console.log(focused.join(","));
  ' "$plugin_dir/dashboard/index.html" 2>&1) || true
  if [ "$refocused" = "ABC-2" ]; then pass "page: a redraw refocuses the card that had focus"; else fail "page: a redraw refocuses the card that had focus" "$refocused"; fi
fi
if grep -q 'cost.title = PARTIAL_COST_NOTE' "$plugin_dir/dashboard/index.html" \
  && grep -q 'var PARTIAL_COST_NOTE = "agents shared across the run not included"' "$plugin_dir/dashboard/index.html"; then
  pass "page: a partial cost's tooltip says what it leaves out"
else
  fail "page: a partial cost's tooltip says what it leaves out" "no tooltip"
fi

# Data reaches the DOM through textContent only.
if grep -q 'innerHTML' "$plugin_dir/dashboard/index.html"; then
  fail "page: no innerHTML" "dashboard/index.html uses innerHTML"
else
  pass "page: no innerHTML"
fi

echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
