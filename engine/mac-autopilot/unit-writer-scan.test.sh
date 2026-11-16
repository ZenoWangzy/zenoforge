#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() { echo "unit-writer-scan.test.sh: $*" >&2; exit 1; }

# The shared writer is units.sh:125 (set_unit) and :149 (units_update).
# The only direct sinks today only append new units: health-release.sh:417 and orphan-prs.sh:80, :114.
allowed_writers=(
  engine/mac-autopilot/scheduler.d/health-release.sh:417
  engine/mac-autopilot/scheduler.d/orphan-prs.sh:80
  engine/mac-autopilot/scheduler.d/orphan-prs.sh:114
  engine/mac-autopilot/scheduler.d/units.sh:125
  engine/mac-autopilot/scheduler.d/units.sh:149
)
unit_writer_sites() {
  local root="$1"
  (cd "$root" && rg -n --no-heading -g '*.sh' -g '!*.test.*' \
    'write_state[[:space:]]+"\$UNITS"|mv[[:space:]].*"\$UNITS"|>[>]*[[:space:]]+"\$UNITS"' \
    engine/mac-autopilot || true) | sed -E 's#^([^:]+:[0-9]+):.*#\1#' | sort
}
assert_writer_allowlist() {
  local root="$1" actual expected
  actual="$(unit_writer_sites "$root")"
  expected="$(printf '%s\n' "${allowed_writers[@]}" | sort)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'unexpected unit ledger writers:\n%s\n' "$actual" >&2
    return 1
  fi
}

assert_writer_allowlist "$repo_root" || fail 'unit ledger writer allowlist changed'

planted="$test_env_root/unit-writer-scan"
mkdir -p "$planted/engine/mac-autopilot/scheduler.d"
cp "$repo_root/engine/mac-autopilot/scheduler.d/units.sh" \
  "$repo_root/engine/mac-autopilot/scheduler.d/health-release.sh" \
  "$repo_root/engine/mac-autopilot/scheduler.d/orphan-prs.sh" \
  "$planted/engine/mac-autopilot/scheduler.d/"
assert_writer_allowlist "$planted" || fail 'writer fixture changed before planting'
cat > "$planted/engine/mac-autopilot/scheduler.d/planted.sh" <<'SH'
jqf '.units[0].stage = "closed"' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
SH
if assert_writer_allowlist "$planted" >/dev/null 2>&1; then
  fail 'lint accepted a planted direct stage write'
fi
echo 'ok - unit stage writes stay at the shared writer; planted direct write is caught'
