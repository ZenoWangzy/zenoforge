#!/usr/bin/env bash
# An engine script run through the engine-live symlink must do its work, not exit 0 with no output.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ln -s "$engine" "$tmp/engine-live"

run() { # run <dir> <stdin> <script> [args]: prints rc then stdout
  local dir=$1 input=$2 script=$3; shift 3
  local rc=0 out
  out="$(printf '%s' "$input" | node "$dir/$script" "$@" 2>/dev/null)" || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
}

for spec in \
  'fruit-migration-analyze.mjs|--stdin' \
  'check-fruit-migration-order.mjs|' \
  'ci-reserved-runners.mjs|' \
  'ci-runner-lanes.mjs|'; do
  script=${spec%%|*}; arg=${spec#*|}
  input='{"runners":[]}'
  real="$(run "$engine" "$input" "$script" ${arg:+"$arg"})"
  link="$(run "$tmp/engine-live" "$input" "$script" ${arg:+"$arg"})"
  [ "$real" = "$link" ] || { echo "FAIL $script differs through the symlink: real [$real] link [$link]"; exit 1; }
  [ "$link" != "$(printf 'rc=0\n')" ] || { echo "FAIL $script did nothing: rc 0 with no output"; exit 1; }
done

echo 'entry-symlink.test.sh: PASS'
