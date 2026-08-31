#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export GITHUB_ACTION_PATH="$root"
export RUNNER_TOOL_CACHE="$(mktemp -d)"
fixture="$(mktemp -d)"
trap 'rm -rf "$RUNNER_TOOL_CACHE" "$fixture"' EXIT

binary="$($root/scripts/install.sh 0.9.0)"
"$binary" --help | grep -q 'USAGE: what-coverage'
"$(dirname "$binary")/what-coverage-pr-comment" --help | grep -q 'what-coverage-pr-comment render'
archive="$(find "$RUNNER_TOOL_CACHE" -name '*.tar.gz' -print -quit)"
printf 'corrupt' >> "$archive"
set +e
"$root/scripts/install.sh" 0.9.0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 1 && ! -e "$archive" ]]
binary="$($root/scripts/install.sh 0.9.0)"

git -C "$fixture" init -q
git -C "$fixture" config user.email test@example.com
git -C "$fixture" config user.name Test
git -C "$fixture" config commit.gpgsign false
mkdir -p "$fixture/Sources"
printf 'unchanged\n' > "$fixture/Sources/App.swift"
git -C "$fixture" add .
git -C "$fixture" commit -qm base
base="$(git -C "$fixture" rev-parse HEAD)"
fixture_root="$(git -C "$fixture" rev-parse --show-toplevel)"
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
export INPUT_WHATCOVERAGE_VERSION=9.9.9 INPUT_EXECUTABLE="$binary" INPUT_COMMENT=false INPUT_RICH_COMMENT=false INPUT_PR_NUMBER="" INPUT_GITHUB_TOKEN=""
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

export INPUT_EXECUTABLE="$binary" INPUT_RICH_COMMENT=true INPUT_WHATCOVERAGE_VERSION=0.8.0 GITHUB_OUTPUT="$fixture/old-rich-output"
(cd "$fixture" && "$root/scripts/execute.sh")
grep -q '^outcome=error$' "$GITHUB_OUTPUT"

tools="$fixture/tools"
mkdir -p "$tools"
cp "$binary" "$tools/what-coverage"
cat > "$tools/what-coverage-pr-comment" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$RENDER_ARGUMENTS"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --output ]]; then output="$2"; shift 2; else shift; fi
done
printf '# Rich WhatCoverage\n' > "$output"
SH
cat > "$tools/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
method=GET output="" data=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -H) shift 2 ;;
    --fail|--silent|--show-error|--location) shift ;;
    *) shift ;;
  esac
done
if [[ "$method" == GET ]]; then printf '[]' > "$output"; else cp "${data#@}" "$RICH_PAYLOAD"; fi
SH
chmod +x "$tools/what-coverage-pr-comment" "$tools/curl"
export PATH="$tools:$PATH" RENDER_ARGUMENTS="$fixture/render-arguments" RICH_PAYLOAD="$fixture/rich-payload"
export INPUT_EXECUTABLE="$tools/what-coverage" INPUT_RICH_COMMENT=true INPUT_WHATCOVERAGE_VERSION=0.9.0 INPUT_COMMENT=true INPUT_PR_NUMBER=7
export INPUT_GITHUB_TOKEN=test GITHUB_REPOSITORY=owner/repo GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=123
export GITHUB_OUTPUT="$fixture/rich-output"
(cd "$fixture" && "$root/scripts/execute.sh")
head_sha="$(git -C "$fixture" rev-parse HEAD)"
grep -Fxq -- '--report' "$RENDER_ARGUMENTS"
grep -Fxq -- "$fixture_root/action-report.json" "$RENDER_ARGUMENTS"
grep -Fxq -- "$head_sha" "$RENDER_ARGUMENTS"
grep -Fxq -- "$fixture_root" "$RENDER_ARGUMENTS"
grep -Fxq -- 'https://github.example/owner/repo/actions/runs/123' "$RENDER_ARGUMENTS"
jq -e '.body | contains("# Rich WhatCoverage")' "$RICH_PAYLOAD" >/dev/null
echo 'smoke test passed'
