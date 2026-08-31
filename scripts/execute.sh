#!/usr/bin/env bash
set -uo pipefail

write_output() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
fail_or_warn() {
  local message="$1" code="${2:-1}"
  write_output outcome error
  echo "::warning::$message"
  if [[ "$INPUT_BLOCKING" == true ]]; then exit "$code"; fi
  exit 0
}
absolute_path() {
  if [[ "$1" = /* ]]; then printf '%s\n' "$1"; else printf '%s/%s\n' "$repository_root" "$1"; fi
}

if [[ "$INPUT_BLOCKING" != true && "$INPUT_BLOCKING" != false ]]; then
  echo "::error::BLOCKING must be true or false"
  exit 64
fi
for value in INPUT_NO_CONFIG INPUT_COMMENT INPUT_RICH_COMMENT; do
  if [[ "${!value}" != true && "${!value}" != false ]]; then
    fail_or_warn "${value#INPUT_} must be true or false" 64
  fi
done
if [[ -n "$INPUT_CONFIG" && "$INPUT_NO_CONFIG" == true ]]; then
  fail_or_warn "config and no-config cannot be used together" 64
fi

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail_or_warn "the current workspace is not a Git repository" 66
if [[ "$INPUT_RICH_COMMENT" == true ]]; then
  if [[ "$INPUT_WHATCOVERAGE_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    version_major="${BASH_REMATCH[1]}"
    version_minor="${BASH_REMATCH[2]}"
  else
    fail_or_warn "rich-comment requires WhatCoverage 0.9.0 or newer" 64
  fi
  if (( 10#$version_major == 0 && 10#$version_minor < 9 )); then
    fail_or_warn "rich-comment requires WhatCoverage 0.9.0 or newer" 64
  fi
fi
markdown_report="$(absolute_path "$INPUT_MARKDOWN_OUTPUT")"
json_report="$(absolute_path "$INPUT_JSON_OUTPUT")"
write_output markdown-report "$markdown_report"
write_output json-report "$json_report"
mkdir -p "$(dirname "$markdown_report")" "$(dirname "$json_report")"

if [[ -n "$INPUT_EXECUTABLE" ]]; then
  binary="$(absolute_path "$INPUT_EXECUTABLE")"
  [[ -f "$binary" && -x "$binary" ]] || fail_or_warn "executable is not an executable file: $binary" 64
else
  binary="$($GITHUB_ACTION_PATH/scripts/install.sh "$INPUT_WHATCOVERAGE_VERSION")" || fail_or_warn "failed to install verified WhatCoverage v$INPUT_WHATCOVERAGE_VERSION"
fi
command=("$binary" --input "$INPUT_COVERAGE_INPUT" --base "$INPUT_BASE" --head "$INPUT_HEAD" --comparison "$INPUT_COMPARISON" --markdown-output "$markdown_report" --json-output "$json_report")
[[ -n "$INPUT_FORMAT" ]] && command+=(--format "$INPUT_FORMAT")
[[ -n "$INPUT_CAPTURED_SOURCE_ROOT" ]] && command+=(--captured-source-root "$INPUT_CAPTURED_SOURCE_ROOT")
[[ -n "$INPUT_MINIMUM" ]] && command+=(--minimum "$INPUT_MINIMUM")
[[ -n "$INPUT_CONFIG" ]] && command+=(--config "$INPUT_CONFIG")
[[ "$INPUT_NO_CONFIG" == true ]] && command+=(--no-config)

set +e
"${command[@]}"
coverage_exit=$?
set -e
write_output exit-code "$coverage_exit"

if [[ "$coverage_exit" != 0 && "$coverage_exit" != 2 ]]; then
  fail_or_warn "WhatCoverage analysis failed with exit code $coverage_exit" "$coverage_exit"
fi
if [[ ! -s "$markdown_report" || ! -s "$json_report" ]]; then
  fail_or_warn "WhatCoverage did not produce both reports"
fi
policy_status="$(jq -er '.policy.status | select(. == "passed" or . == "failed" or . == "notApplicable")' "$json_report")" || fail_or_warn "WhatCoverage produced an invalid policy status"
write_output policy-status "$policy_status"
write_output outcome "$policy_status"

if [[ "$INPUT_COMMENT" == true ]]; then
  pr_number="$INPUT_PR_NUMBER"
  if [[ -z "$pr_number" && -n "${GITHUB_EVENT_PATH:-}" && -f "$GITHUB_EVENT_PATH" ]]; then
    pr_number="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
  fi
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || fail_or_warn "pr-number is required outside a pull_request event"
  comment_report="$markdown_report"
  if [[ "$INPUT_RICH_COMMENT" == true ]]; then
    comment_binary="$(dirname "$binary")/what-coverage-pr-comment"
    [[ -f "$comment_binary" && -x "$comment_binary" ]] || fail_or_warn "what-coverage-pr-comment is unavailable; rich-comment requires both executables from WhatCoverage 0.9.0 or newer" 64
    head_sha="$(git rev-parse --verify "${INPUT_HEAD}^{commit}" 2>/dev/null)" || fail_or_warn "head does not resolve to a Git commit: $INPUT_HEAD" 64
    [[ "$head_sha" =~ ^[0-9a-f]{40,64}$ ]] || fail_or_warn "head resolved to an invalid Git SHA" 64
    [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]] || fail_or_warn "GITHUB_SERVER_URL, GITHUB_REPOSITORY, and GITHUB_RUN_ID are required for rich comments" 64
    run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    comment_report="$(mktemp "${RUNNER_TEMP:-/tmp}/whatcoverage-rich-comment.XXXXXX")" || fail_or_warn "failed to create rich comment output"
    trap 'rm -f "$comment_report"' EXIT
    "$comment_binary" render --report "$json_report" --head "$head_sha" --repo-root "$repository_root" --run-url "$run_url" --output "$comment_report" || fail_or_warn "failed to render the rich PR comment"
    [[ -s "$comment_report" ]] || fail_or_warn "rich comment renderer did not produce Markdown"
  fi
  "$GITHUB_ACTION_PATH/scripts/comment.sh" "$comment_report" "$pr_number" || fail_or_warn "failed to post or update the PR comment"
  [[ "$INPUT_RICH_COMMENT" == true ]] && rm -f "$comment_report"
fi

{
  echo "### WhatCoverage"
  echo
  echo "Policy: **$policy_status**"
  echo
  echo "Reports: \`$markdown_report\`, \`$json_report\`"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [[ "$coverage_exit" == 2 ]]; then
  if [[ "$INPUT_BLOCKING" == true ]]; then exit 2; fi
  echo "::warning::WhatCoverage policy failed; blocking is disabled"
fi
