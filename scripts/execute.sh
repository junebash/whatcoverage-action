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
for value in INPUT_NO_CONFIG INPUT_COMMENT; do
  if [[ "${!value}" != true && "${!value}" != false ]]; then
    fail_or_warn "${value#INPUT_} must be true or false" 64
  fi
done
if [[ -n "$INPUT_CONFIG" && "$INPUT_NO_CONFIG" == true ]]; then
  fail_or_warn "config and no-config cannot be used together" 64
fi

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail_or_warn "the current workspace is not a Git repository" 66
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
  "$GITHUB_ACTION_PATH/scripts/comment.sh" "$markdown_report" "$pr_number" || fail_or_warn "failed to post or update the PR comment"
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
