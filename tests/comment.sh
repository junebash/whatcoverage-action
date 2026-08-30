#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
cat > "$temporary/curl" <<'SH'
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
if [[ "$method" == GET ]]; then
  printf '%s' "$MOCK_COMMENTS" > "$output"
else
  cp "${data#@}" "$CAPTURED_PAYLOAD"
  printf '%s\n' "$method" > "$CAPTURED_METHOD"
fi
SH
chmod +x "$temporary/curl"
printf '# WhatCoverage\n\n**Policy:** Passed\n' > "$temporary/report.md"
export PATH="$temporary:$PATH" INPUT_GITHUB_TOKEN=test INPUT_COMMENT_AUTHOR='github-actions[bot]' GITHUB_REPOSITORY=owner/repo
export CAPTURED_PAYLOAD="$temporary/payload" CAPTURED_METHOD="$temporary/method"

export MOCK_COMMENTS='[]'
"$root/scripts/comment.sh" "$temporary/report.md" 7 >/dev/null
[[ "$(cat "$CAPTURED_METHOD")" == POST ]]
jq -e '.body | startswith("<!-- whatcoverage-action:pr-report:v1 -->\n\n# WhatCoverage")' "$CAPTURED_PAYLOAD" >/dev/null

export MOCK_COMMENTS='[{"id":41,"user":{"login":"other-bot"},"body":"<!-- whatcoverage-action:pr-report:v1 -->\nspoof"},{"id":42,"user":{"login":"github-actions[bot]"},"body":"<!-- whatcoverage-action:pr-report:v1 -->\nold"}]'
"$root/scripts/comment.sh" "$temporary/report.md" 7 >/dev/null
[[ "$(cat "$CAPTURED_METHOD")" == PATCH ]]
echo 'comment test passed'
