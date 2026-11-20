#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd -P)/test-env.sh"
trap 'rm -rf "$test_env_root"' EXIT

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
HERE="$repo_root/engine/mac-autopilot"
ROOT="$test_env_root/product"
SUP="$test_env_root/sup"
mkdir -p "$ROOT" "$SUP"
source "$HERE/scheduler.d/self-check.sh"

jqf() { command jq "$@"; }
test_evidence_has_pass() { return 1; }
test_evidence_record_pass() { :; }
fail() { printf 'self-check-main-sync.test.sh: %s\n' "$*" >&2; exit 1; }

export ZF_SELF_CHECK_LOCAL=1 SELF_CHECK_STEP_TIMEOUT=10
export PNPM_LOG="$test_env_root/pnpm.log" ROUTE_LOG="$test_env_root/conflict-route.log"
cat > "$test_env_bin/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PNPM_LOG"
EOF
chmod +x "$test_env_bin/pnpm"

make_repo() {
  local name="$1" conflict="$2" dir origin
  dir="$test_env_root/$name"
  origin="$test_env_root/$name-origin.git"
  mkdir -p "$dir/scripts/ci" "$dir/scripts/checks" "$dir/packages/fruit/src"
  git init -q -b main "$dir"
  git -C "$dir" config user.name fixture
  git -C "$dir" config user.email fixture@example.invalid
  cat > "$dir/scripts/ci/touched-package-selection.mjs" <<'EOF'
console.log(JSON.stringify({rootNames:["fruit"],affectedNames:["fruit"],affectedPaths:["packages/fruit"]}));
EOF
  printf 'export {};\n' > "$dir/scripts/checks/authenticated-origin-contract-packages.mjs"
  cat > "$dir/packages/fruit/package.json" <<'EOF'
{"name":"fruit","scripts":{"build":"true","test":"true","lint":"true"}}
EOF
  printf 'base\n' > "$dir/packages/fruit/src/shared.js"
  git -C "$dir" add .
  git -C "$dir" commit -qm base
  git init --bare -q "$origin"
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push -q origin main

  git -C "$dir" checkout -q -b "agent/$name"
  printf 'unit\n' > "$dir/packages/fruit/src/unit.js"
  if [[ "$conflict" == true ]]; then
    printf 'unit\n' > "$dir/packages/fruit/src/shared.js"
  fi
  git -C "$dir" add .
  git -C "$dir" commit -qm unit
  git -C "$dir" push -q origin "agent/$name"
  local unit_head
  unit_head="$(git -C "$dir" rev-parse HEAD)"

  git -C "$dir" checkout -q main
  if [[ "$conflict" == true ]]; then
    printf 'main\n' > "$dir/packages/fruit/src/shared.js"
  else
    printf 'main\n' > "$dir/packages/fruit/src/main.js"
  fi
  git -C "$dir" add .
  git -C "$dir" commit -qm main-update
  git -C "$dir" push -q origin main
  git -C "$dir" update-ref refs/remotes/origin/main main
  git -C "$dir" checkout -q "agent/$name"
  printf '%s\n' "$dir" "$origin" "$unit_head" "$(git -C "$dir" rev-parse origin/main)"
}

mapfile -t clean_repo < <(make_repo clean false)
clean="${clean_repo[0]}"
clean_origin="${clean_repo[1]}"
clean_head="${clean_repo[2]}"
clean_main="${clean_repo[3]}"
ROOT="$clean"
clean_output=""
clean_rc=0
if clean_output="$(self_check_run "$clean" "$clean_head" pr main clean-unit agent/clean 101 2>&1)"; then :; else clean_rc=$?; fi
[[ "$clean_rc" == 0 ]] || { printf '%s\n' "$clean_output" >&2; fail "clean merge self-check returned $clean_rc"; }
git -C "$clean" merge-base --is-ancestor "$clean_main" HEAD \
  || fail 'clean stale branch did not merge origin/main'
[[ "$(git --git-dir="$clean_origin" rev-parse refs/heads/agent/clean)" == "$(git -C "$clean" rev-parse HEAD)" ]] \
  || fail 'clean main merge was not pushed to the unit branch'
grep -Fq 'self-check main sync: merged clean' <<<"$clean_output" \
  || fail 'clean main merge outcome was not logged'
grep -Fq 'run build' "$PNPM_LOG" || fail 'clean main merge did not continue to builds'

mapfile -t conflict_repo < <(make_repo conflict true)
conflict="${conflict_repo[0]}"
conflict_head="${conflict_repo[2]}"
conflict_main="${conflict_repo[3]}"
ROOT="$conflict"
: > "$PNPM_LOG"
: > "$ROUTE_LOG"
merge_conflict_to_repair() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$5" >> "$ROUTE_LOG"
}
conflict_output=""
conflict_rc=0
if conflict_output="$(self_check_run "$conflict" "$conflict_head" pr main conflict-unit agent/conflict 202 2>&1)"; then :; else conflict_rc=$?; fi
[[ "$conflict_rc" == 76 ]] || { printf '%s\n' "$conflict_output" >&2; fail "conflict did not stop self-check with route status 76 (rc=$conflict_rc)"; }
grep -Fq 'self-check main sync: conflict routed' <<<"$conflict_output" \
  || fail 'conflict route outcome was not logged'
grep -Fq "conflict-unit|202|self-check: conflicts with main before builds|$conflict_head" "$ROUTE_LOG" \
  || fail 'conflict was not handed to merge_conflict_to_repair'
[[ ! -s "$PNPM_LOG" ]] || fail 'conflicting branch ran a build or package command'
[[ "$(git -C "$conflict" rev-parse HEAD)" == "$conflict_head" ]] || fail 'conflict changed the unit branch head'
[[ -z "$(git -C "$conflict" ls-files -u)" ]] || fail 'conflict left unmerged paths in the unit worktree'
[[ "$(git -C "$conflict" rev-parse origin/main)" == "$conflict_main" ]] || fail 'conflict fixture main moved unexpectedly'

echo 'self-check-main-sync.test.sh: PASS'
