#!/usr/bin/env bash
set -euo pipefail

report="${1:?usage: comment.sh REPORT PR_NUMBER}"
pr_number="${2:?usage: comment.sh REPORT PR_NUMBER}"
: "${INPUT_GITHUB_TOKEN:?github-token is required when comment is true}"
: "${INPUT_COMMENT_AUTHOR:?comment-author is required when comment is true}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required when comment is true}"

marker='<!-- whatcoverage-action:pr-report:v1 -->'
body_file="$(mktemp "${RUNNER_TEMP:-/tmp}/whatcoverage-comment.XXXXXX")"
response_file="$(mktemp "${RUNNER_TEMP:-/tmp}/whatcoverage-comments.XXXXXX")"
payload_file="$(mktemp "${RUNNER_TEMP:-/tmp}/whatcoverage-payload.XXXXXX")"
trap 'rm -f "$body_file" "$response_file" "$payload_file"' EXIT
printf '%s\n\n' "$marker" > "$body_file"
cat "$report" >> "$body_file"

api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
headers=(-H "Authorization: Bearer $INPUT_GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
comment_id=""
for page in $(seq 1 100); do
  curl --fail --silent --show-error --location "${headers[@]}" \
    "$api/issues/$pr_number/comments?per_page=100&page=$page" --output "$response_file"
  comment_id="$(jq -r --arg marker "$marker" --arg login "$INPUT_COMMENT_AUTHOR" '[.[] | select(.user.login == $login and (.body | startswith($marker)))][0].id // empty' "$response_file")"
  [[ -n "$comment_id" ]] && break
  [[ "$(jq length "$response_file")" -lt 100 ]] && break
done
jq -n --rawfile body "$body_file" '{body: $body}' > "$payload_file"
if [[ -n "$comment_id" ]]; then
  curl --fail --silent --show-error --location -X PATCH "${headers[@]}" \
    "$api/issues/comments/$comment_id" --data-binary "@$payload_file" >/dev/null
  echo "Updated WhatCoverage comment $comment_id"
else
  curl --fail --silent --show-error --location -X POST "${headers[@]}" \
    "$api/issues/$pr_number/comments" --data-binary "@$payload_file" >/dev/null
  echo "Posted WhatCoverage comment"
fi
