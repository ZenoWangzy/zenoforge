#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "$root/.git/release-runner-test.XXXXXX")"
mkdir -p "$tmp/repo/.zenoforge" "$tmp/engine" "$tmp/repo/scripts/release"
export ZF_ENGINE_DIR="$tmp/engine" ZF_REPO_DIR="$tmp/repo"
source "$root/engine/config.sh"
check() { [[ "$(zf_release_runner)" == "$1" ]] || { echo "FAIL: expected $1" >&2; exit 1; }; }
printf '%s\n' '{"release":{"runner":"scripts/release/run-release.sh"}}' > "$tmp/repo/.zenoforge/release.json"
touch "$tmp/repo/scripts/release/run-release.sh"
check "$tmp/repo/scripts/release/run-release.sh"
printf '%s\n' '{}' > "$tmp/repo/.zenoforge/release.json"
check "$tmp/engine/run-release.sh"
printf '%s\n' '{"release":{"runner":"scripts/release/missing.sh"}}' > "$tmp/repo/.zenoforge/release.json"
check "$tmp/engine/run-release.sh"
echo 'PASS: configured, absent, missing runner'
