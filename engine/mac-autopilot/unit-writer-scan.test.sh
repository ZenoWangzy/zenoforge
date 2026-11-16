#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() { echo "unit-writer-scan.test.sh: $*" >&2; exit 1; }

# Registration writes stay in their two functions; normal writes use set_unit/units_update.
allowed_writers=(
  engine/mac-autopilot/scheduler.d/health-release.sh:register_new_prs
  engine/mac-autopilot/scheduler.d/orphan-prs.sh:reconcile_orphan_prs
  engine/mac-autopilot/scheduler.d/units.sh:set_unit
  engine/mac-autopilot/scheduler.d/units.sh:units_update
)
unit_writer_sites() {
  local root="$1" file
  while IFS= read -r file; do
    awk -v file="$file" '
      {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^#/) next
        if (match(line, /^[[:alnum:]_]+[[:space:]]*\(\)[[:space:]]*\{/)) {
          fn = substr(line, RSTART, RLENGTH)
          sub(/[[:space:]]*\(.*/, "", fn)
          current = fn
        }
        if (line ~ /write_state[[:space:]]+["]?[$]UNITS([[:space:]]|"|$|;|\||&)/ \
          || line ~ /mv[[:space:]].*["]?[$]UNITS([[:space:]]|"|$|;|\||&)/ \
          || line ~ /[>][>]*[[:space:]]*["]?[$]UNITS([[:space:]]|"|$|;|\||&)/ \
          || line ~ /tee[[:space:]].*["]?[$]UNITS([[:space:]]|"|$|;|\||&)/ \
          || line ~ /sed[[:space:]].*-i.*["]?[$]UNITS([[:space:]]|"|$|;|\||&)/ \
          || line ~ /cp[[:space:]].*["]?[$]UNITS([[:space:]]|"|$|;|\||&)/) {
          printf "%s:%s\n", file, (current == "" ? "<top-level>" : current)
        }
      }' "$root/$file"
  done < <(cd "$root" && rg --files -g '*.sh' -g '!*.test.*' engine/mac-autopilot | sort)
}
assert_writer_allowlist() {
  local root="$1" actual expected
  actual="$(unit_writer_sites "$root" | sort -u)"
  expected="$(printf '%s\n' "${allowed_writers[@]}" | sort -u)"
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

# The allowlist is stable when unrelated lines move an allowed write, and comments are not writes.
sed -i '1i\# inserted line: cp source "$UNITS"' \
  "$planted/engine/mac-autopilot/scheduler.d/health-release.sh"
cat > "$planted/engine/mac-autopilot/scheduler.d/comments.sh" <<'SH'
  # jqf '.units[0].stage = "closed"' "$UNITS" >"$UNITS"
# tee "$UNITS"
SH
assert_writer_allowlist "$planted" || fail 'line movement or comments changed the writer allowlist'

writer_statements=(
  ': >"$UNITS"'
  'printf x | tee "$UNITS"'
  'sed -i s/x/y/ "$UNITS"'
  'cp source "$UNITS"'
  'jqf . "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"'
)
for statement in "${writer_statements[@]}"; do
  printf 'bad_writer() { %s; }\n' "$statement" \
    > "$planted/engine/mac-autopilot/scheduler.d/planted.sh"
  if assert_writer_allowlist "$planted" >/dev/null 2>&1; then
    fail "lint accepted a planted ledger write: $statement"
  fi
done
echo 'ok - unit ledger writer allowlist uses functions and catches direct write forms'
