#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: install.sh VERSION}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid WhatCoverage version: $version" >&2
  exit 64
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target=macos-arm64 ;;
  Darwin-x86_64) target=macos-x86_64 ;;
  Linux-x86_64) target=linux-x86_64 ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

expected="$(awk -v version="$version" -v target="$target" '$1 == version && $2 == target { print $3 }' "$GITHUB_ACTION_PATH/checksums.txt")"
if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "WhatCoverage v$version ($target) is not pinned by this action release" >&2
  exit 1
fi

archive="what-coverage-v$version-$target.tar.gz"
cache="${RUNNER_TOOL_CACHE:-${HOME}/.cache/whatcoverage}/whatcoverage/$version/$target"
mkdir -p "$cache"
if [[ ! -f "$cache/$archive" ]]; then
  temporary="$(mktemp "${RUNNER_TEMP:-/tmp}/whatcoverage.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT
  curl --fail --location --silent --show-error \
    "https://github.com/junebash/WhatCoverage/releases/download/v$version/$archive" \
    --output "$temporary"
  mv "$temporary" "$cache/$archive"
fi

actual="$(shasum -a 256 "$cache/$archive" | awk '{ print $1 }')"
if [[ "$actual" != "$expected" ]]; then
  rm -f "$cache/$archive"
  echo "checksum mismatch for $archive" >&2
  exit 1
fi

extract="$(mktemp -d "${RUNNER_TEMP:-/tmp}/whatcoverage.XXXXXX")"
trap 'rm -rf "$extract"' EXIT
tar -C "$extract" -xzf "$cache/$archive"
install -m 755 "$extract/what-coverage" "$cache/what-coverage"

printf '%s\n' "$cache/what-coverage"
