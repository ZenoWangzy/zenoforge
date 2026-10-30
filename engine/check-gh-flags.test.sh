#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECKER="$REPO_DIR/engine/check-gh-flags.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/engine"

# The 2026-10-03 shape: an unknown flag inside $(...) with || return 0 after it.
printf '%s\n' 'rows="$(gh issue list --repo r --state open --sort updated --json number)" || return 0' \
  > "$tmp/engine/bad.sh"
set +e
out="$(bash "$CHECKER" "$tmp" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]]
grep -qF 'engine/bad.sh:1: gh issue list has no --sort' <<< "$out"
echo "ok - an unknown gh flag fails with file, line and flag"

# Flags after a pipe belong to the next command; comments and test files are not scanned.
printf '%s\n' 'rows="$(gh issue list --repo r --state open --json number | jq --arg a b .)"' \
  '# gh issue list --sort updated' > "$tmp/engine/bad.sh"
printf '%s\n' 'gh issue list --sort updated' > "$tmp/engine/ignored.test.sh"
bash "$CHECKER" "$tmp"
echo "ok - valid flags, piped flags, comments and test files pass"

# The repository-wide scan runs as an incident guard on the agent host, whose gh runs these scripts;
# CI runners carry an older gh (2.45), so scanning the repository here would test the wrong binary.
