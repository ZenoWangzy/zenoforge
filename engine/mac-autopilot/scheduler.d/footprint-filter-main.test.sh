#!/usr/bin/env bash
# footprint_filter_rows_main keeps its result (present main paths per row and field, unique; a row with a non-string entry or preserve is untouched)
# after the paths are grouped once. Mixed rows are checked by value, then 300 rows must each keep their one present path.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() { printf 'footprint-filter-main.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/footprint-filter-main"
mkdir -p "$fixture/repo/src/dir" "$fixture/supervisor/autopi/alerts"
printf 'a\n' > "$fixture/repo/src/a.ts"; printf 'b\n' > "$fixture/repo/src/b.ts"; printf 'c\n' > "$fixture/repo/src/dir/c.ts"
git -C "$fixture/repo" init -q
git -C "$fixture/repo" add -A
git -C "$fixture/repo" -c user.email=test@example.invalid -c user.name=test commit -qm base
git -C "$fixture/repo" update-ref refs/remotes/origin/main HEAD
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

rows='[{"scope":["src/a.ts","gone.ts","src/dir"],"old_scope":["src/b.ts"]},{"scope":["src/a.ts"],"preserve":true},{"scope":"notarray"},{"scope":["src/b.ts",5]}]'
expected='[{"scope":["src/a.ts","src/dir"],"old_scope":["src/b.ts"]},{"scope":["src/a.ts"],"preserve":true},{"scope":"notarray"},{"scope":["src/b.ts",5]}]'
actual="$(footprint_filter_rows_main "$rows")" || fail "filter failed on mixed rows"
[[ "$(jq -cS . <<<"$actual")" == "$(jq -cS . <<<"$expected")" ]] || fail "mixed rows: got $actual"

many="$(jq -cn '[range(0;300) | {scope:["src/a.ts", "gone-\(.).ts"]}]')"
out="$(footprint_filter_rows_main "$many")" || fail "filter failed on 300 rows"
jq -e 'length == 300 and all(.[]; .scope == ["src/a.ts"])' <<<"$out" >/dev/null || fail "300-row grouping lost or mixed a row's path"
echo "footprint-filter-main.test.sh: ok"
