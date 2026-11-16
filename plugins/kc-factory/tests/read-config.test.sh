#!/usr/bin/env bash
# Tests scripts/read-config.sh: valid configs normalize with defaults,
# invalid ones print one error per problem and exit 1.
set -euo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
script="$(dirname "$tests_dir")/scripts/read-config.sh"
fixtures="$tests_dir/fixtures/config"
stderr_file=$(mktemp)
trap 'rm -f "$stderr_file"' EXIT
passes=0
failures=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; echo "     $2"; failures=$((failures + 1)); }

expect_value() {
  local label=$1 fixture=$2 filter=$3 expected=$4 out actual status=0
  out=$(bash "$script" "$fixtures/$fixture" 2>"$stderr_file") || status=$?
  actual=$(printf '%s' "$out" | jq -c "$filter") || actual="<jq failed>"
  if [ "$status" = 0 ] && [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "expected $expected, got $actual (status $status); stderr: $(cat "$stderr_file")"
  fi
}

expect_error() {
  local label=$1 fixture=$2 needle=$3 status=0
  bash "$script" "$fixtures/$fixture" >/dev/null 2>"$stderr_file" || status=$?
  if [ "$status" = 1 ] && grep -qF "factory.json: $needle" "$stderr_file" && ! grep -v '^factory.json: ' "$stderr_file" | grep -q .; then
    pass "$label"
  else
    fail "$label" "status $status, stderr: $(cat "$stderr_file")"
  fi
}

expect_value "defaults: whole config" minimal.json '.' \
  '{"tracker":{"kind":"jira","site":"example.atlassian.net","project_keys":["ABC"],"statuses":{"in_progress":"In Progress","in_review":"In Review"},"comment_on":["needs-info","reject","accept","ready","blocked"]},"concurrency":3,"intake":{"model":"best"},"routing":{"low":{"workers":"sonnet","personas":{"min":2,"max":3},"security":"workers"},"medium":{"workers":"sonnet","personas":{"min":3,"max":4},"security":"workers"},"high":{"workers":"best","personas":{"min":4,"max":5},"security":"staff"},"surfaces":{"security":{"security":"staff"}}},"prices_usd_per_mtok":{}}'
expect_value "keeps: site and keys"   full.json '.tracker | [.site, .project_keys]' '["shop.atlassian.net",["ABC","WEB2"]]'
expect_value "keeps: statuses"        full.json '.tracker.statuses'   '{"in_progress":"Doing","in_review":"Review"}'
expect_value "keeps: comment_on"      full.json '.tracker.comment_on' '["needs-info","ready"]'
expect_value "keeps: concurrency"     full.json '.concurrency'        '5'
expect_value "keeps: intake model"    full.json '.intake.model'       '"opus"'
expect_value "merges: low tier"       full.json '.routing.low'        '{"workers":"haiku","personas":{"min":2,"max":3},"security":"workers"}'
expect_value "keeps: high tier"       full.json '.routing.high'       '{"workers":"claude-opus-4-1","personas":{"min":5,"max":6},"security":"workers"}'
expect_value "defaults: medium tier"  full.json '.routing.medium.workers' '"sonnet"'
expect_value "keeps: surfaces"        full.json '.routing.surfaces'   '{"payments":{"security":"staff","workers":"best"}}'
expect_value "keeps: prices"          full.json '.prices_usd_per_mtok.sonnet.output' '15'
expect_error "rejects missing site"        bad-no-site.json        'tracker.site must be a non-empty string'
expect_error "rejects lowercase key"       bad-lowercase-key.json  'tracker.project_keys must be a non-empty array of keys like ABC'
expect_error "rejects empty keys"          bad-empty-keys.json     'tracker.project_keys must be a non-empty array of keys like ABC'
expect_error "rejects concurrency 0"       bad-concurrency-low.json  'concurrency must be an integer from 1 to 8'
expect_error "rejects concurrency 9"       bad-concurrency-high.json 'concurrency must be an integer from 1 to 8'
expect_error "rejects unknown model"       bad-routing-model.json  'routing.low.workers must be haiku, sonnet, opus, best or a claude-* model id'
expect_error "rejects inverted personas"   bad-personas.json       'routing.low.personas must be integers with 1 <= min <= max'
expect_error "rejects unknown security"    bad-security.json       'routing.medium.security must be workers or staff'
expect_error "rejects a non-object"        bad-not-object.json     'must be a JSON object'

echo
echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
