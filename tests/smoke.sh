#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export GITHUB_ACTION_PATH="$root"
export RUNNER_TOOL_CACHE="$(mktemp -d)"
fixture="$(mktemp -d)"
trap 'rm -rf "$RUNNER_TOOL_CACHE" "$fixture"' EXIT

binary="$($root/scripts/install.sh 0.6.0)"
"$binary" --help | grep -q 'USAGE: what-coverage'
archive="$(find "$RUNNER_TOOL_CACHE" -name '*.tar.gz' -print -quit)"
printf 'corrupt' >> "$archive"
set +e
"$root/scripts/install.sh" 0.6.0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 1 && ! -e "$archive" ]]
binary="$($root/scripts/install.sh 0.6.0)"

git -C "$fixture" init -q
git -C "$fixture" config user.email test@example.com
git -C "$fixture" config user.name Test
git -C "$fixture" config commit.gpgsign false
mkdir -p "$fixture/Sources"
printf 'unchanged\n' > "$fixture/Sources/App.swift"
git -C "$fixture" add .
git -C "$fixture" commit -qm base
base="$(git -C "$fixture" rev-parse HEAD)"
printf 'unchanged\nchanged\n' > "$fixture/Sources/App.swift"
git -C "$fixture" commit -qam head
cat > "$fixture/coverage.json" <<'JSON'
{"type":"llvm.coverage.json.export","version":"2.0.0","data":[{"files":[{"filename":"/captured/Sources/App.swift","segments":[[2,1,0,true,true,false],[3,1,0,false,true,false]]}]}]}
JSON

set +e
(cd "$fixture" && "$binary" --input coverage.json --base "$base" --comparison direct \
  --captured-source-root /captured --minimum 100 --markdown-output report.md --json-output report.json)
status=$?
set -e
[[ "$status" == 2 ]]
jq -e '.schemaVersion == 1 and .policy.status == "failed" and .totals.uncovered == 1' "$fixture/report.json" >/dev/null
grep -q 'Policy.*Failed' "$fixture/report.md"

export INPUT_COVERAGE_INPUT=coverage.json INPUT_BASE="$base" INPUT_HEAD=HEAD INPUT_FORMAT=llvm
export INPUT_COMPARISON=direct INPUT_CAPTURED_SOURCE_ROOT=/captured INPUT_MINIMUM=100 INPUT_CONFIG=""
export INPUT_NO_CONFIG=false INPUT_MARKDOWN_OUTPUT=action-report.md INPUT_JSON_OUTPUT=action-report.json
export INPUT_WHATCOVERAGE_VERSION=9.9.9 INPUT_EXECUTABLE="$binary" INPUT_COMMENT=false INPUT_PR_NUMBER="" INPUT_GITHUB_TOKEN=""
export INPUT_COMMENT_AUTHOR='github-actions[bot]'
export GITHUB_OUTPUT="$fixture/action-output" GITHUB_STEP_SUMMARY="$fixture/summary"
export INPUT_BLOCKING=false
(cd "$fixture" && "$root/scripts/execute.sh")
grep -q '^outcome=failed$' "$GITHUB_OUTPUT"
grep -q '^exit-code=2$' "$GITHUB_OUTPUT"

export INPUT_BLOCKING=true GITHUB_OUTPUT="$fixture/blocking-output"
set +e
(cd "$fixture" && "$root/scripts/execute.sh")
status=$?
set -e
[[ "$status" == 2 ]]

export INPUT_BLOCKING=false INPUT_EXECUTABLE=missing-tool GITHUB_OUTPUT="$fixture/missing-output"
(cd "$fixture" && "$root/scripts/execute.sh")
grep -q '^outcome=error$' "$GITHUB_OUTPUT"
echo 'smoke test passed'
