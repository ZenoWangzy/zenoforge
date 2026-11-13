#!/usr/bin/env bash
# A touched package's registered escape test runs in the pre-review self-check,
# and its result is included in the review report.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf "$test_env_root"' EXIT

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
HERE="$repo_root/engine/mac-autopilot"
ROOT="$test_env_root/product"
SUP="$test_env_root/sup"
mkdir -p "$ROOT/scripts/ci" "$ROOT/scripts/checks" "$ROOT/packages/fruit/tests" "$ROOT/packages/fruit/src" "$ROOT/.zenoforge/state" "$SUP"
source "$HERE/scheduler.d/self-check.sh"
source "$HERE/scheduler.d/review-rules.sh"
source "$HERE/scheduler.d/reports.sh"
jqf() { command jq "$@"; }
unit_field() { printf '%s' "$SUP/self-check.log"; }
test_evidence_has_pass() { return 1; }
test_evidence_record_pass() { :; }

cat > "$test_env_bin/pnpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_env_bin/pnpm"
cat > "$test_env_root/cihost-exec" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo="$1"
shift
[[ "$1" == -- ]]
shift
cd "$repo"
exec "$@"
EOF
chmod +x "$test_env_root/cihost-exec"
export ZF_CIHOST_EXEC="$test_env_root/cihost-exec"

cat > "$ROOT/scripts/ci/touched-package-selection.mjs" <<'EOF'
console.log(JSON.stringify({rootNames:["fruit"],affectedNames:["fruit"],affectedPaths:["packages/fruit"]}));
EOF
cat > "$ROOT/scripts/checks/authenticated-origin-contract-packages.mjs" <<'EOF'
export {};
EOF
cat > "$ROOT/packages/fruit/package.json" <<'EOF'
{"name":"fruit","scripts":{"test":"true"}}
EOF
cat > "$ROOT/packages/fruit/schema.json" <<'EOF'
{"properties":{"tenantTimezone":{"type":"string"}}}
EOF
cat > "$ROOT/packages/fruit/tests/tenant-timezone.test.sh" <<'EOF'
#!/usr/bin/env bash
grep -q '"tenantTimezone"' packages/fruit/schema.json
EOF
cat > "$ROOT/.zenoforge/state/escape-suites.json" <<'EOF'
{"version":1,"packages":{"packages/fruit":[{"test":"packages/fruit/tests/tenant-timezone.test.sh","command":["bash","packages/fruit/tests/tenant-timezone.test.sh"]}]}}
EOF

git init -q "$ROOT"
git -C "$ROOT" config user.name fixture
git -C "$ROOT" config user.email fixture@example.invalid
git -C "$ROOT" add .
git -C "$ROOT" commit -qm base
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD

printf 'export const changed = true;\n' > "$ROOT/packages/fruit/src/config.js"
git -C "$ROOT" add packages/fruit/src/config.js
git -C "$ROOT" commit -qm 'touch fruit package'
green_head="$(git -C "$ROOT" rev-parse HEAD)"
green_output=''
green_rc=0
if green_output="$(self_check_run "$ROOT" "$green_head" pr main 2>&1)"; then :; else green_rc=$?; fi
[[ "$green_rc" == 0 ]] || { printf '%s\n' "$green_output" >&2; echo 'escape-suite-self-check.test.sh: green escape test made pre-review self-check red' >&2; exit 1; }
grep -q '^escape-suite: package=packages/fruit test=packages/fruit/tests/tenant-timezone.test.sh rc=0 ' <<<"$green_output" \
  || { printf '%s\n' "$green_output" >&2; echo 'escape-suite-self-check.test.sh: pre-review self-check did not report the registered test and rc=0' >&2; exit 1; }

# The review prompt must carry the exact test and rc from the self-check log.
printf '%s\n' "$green_output" > "$SUP/self-check.log"
review_wt="$test_env_root/review"
git init -q "$review_wt"
git -C "$review_wt" config user.name fixture
git -C "$review_wt" config user.email fixture@example.invalid
printf 'fixture\n' > "$review_wt/tracked"
git -C "$review_wt" add tracked
git -C "$review_wt" commit -qm fixture
unit="$(jq -cn --arg log "$SUP/self-check.log" '{self_check_output:$log}')"
review_input="$(review_inputs_rule "$unit" "$review_wt" "$green_head")"
[[ "$review_input" == *'## escape-suite'* && "$review_input" == *'packages/fruit/tests/tenant-timezone.test.sh'* && "$review_input" == *'rc=0'* ]] \
  || { printf '%s\n' "$review_input" >&2; echo 'escape-suite-self-check.test.sh: review prompt omitted the escape test result' >&2; exit 1; }
review_report="$SUP/review-report.md"
printf 'VERDICT: READY\nReview findings: none\n' > "$review_report"
review_report_harvest "$review_report" test-unit
grep -q '^## escape-suite$' "$review_report" \
  && grep -q '^escape-suite: package=packages/fruit test=packages/fruit/tests/tenant-timezone.test.sh rc=0 ' "$review_report" \
  || { cat "$review_report" >&2; echo 'escape-suite-self-check.test.sh: review report omitted the test and its rc' >&2; exit 1; }

# Plant the schema regression: the same package test must make implement's self-check red.
sed -i '/tenantTimezone/d' "$ROOT/packages/fruit/schema.json"
git -C "$ROOT" add packages/fruit/schema.json
git -C "$ROOT" commit -qm 'plant tenant timezone schema regression'
red_head="$(git -C "$ROOT" rev-parse HEAD)"
red_output=''
red_rc=0
if red_output="$(self_check_run "$ROOT" "$red_head" pr main 2>&1)"; then :; else red_rc=$?; fi
[[ "$red_rc" != 0 ]] || { printf '%s\n' "$red_output" >&2; echo 'escape-suite-self-check.test.sh: planted tenantTimezone regression passed pre-review self-check' >&2; exit 1; }
grep -q '^escape-suite: package=packages/fruit test=packages/fruit/tests/tenant-timezone.test.sh rc=1 ' <<<"$red_output" \
  || { printf '%s\n' "$red_output" >&2; echo 'escape-suite-self-check.test.sh: planted regression did not report the escape test rc=1' >&2; exit 1; }

echo 'ok - touched-package escape test runs before review, reports its rc, and catches the planted schema regression'
