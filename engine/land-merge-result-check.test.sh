#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
fixture="$test_env_root/land-merge-result"
runtime="$fixture/runtime"
repo="$fixture/repo"
remote="$fixture/origin.git"
mkdir -p "$runtime"
cp -a "$repo_root/engine" "$runtime/engine"

fail() { printf 'land-merge-result-check.test.sh: %s\n' "$*" >&2; exit 1; }

export GIT_AUTHOR_NAME='merge-result fixture' GIT_AUTHOR_EMAIL='merge-result@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
command git init -q -b main "$repo"
command git -C "$repo" config user.name "$GIT_AUTHOR_NAME"
command git -C "$repo" config user.email "$GIT_AUTHOR_EMAIL"
mkdir -p "$repo/scripts"
cat > "$repo/scripts/branch-delivery-preflight.mjs" <<'JS'
export function before() { return 1; }
// spacer one
// spacer two
// spacer three
// spacer four
// spacer five
export function after() { return 2; }
console.log('Push preflight passed: fixture (development-system-direct-main).');
JS
command git -C "$repo" add scripts/branch-delivery-preflight.mjs
command git -C "$repo" commit -qm 'fixture base'
base="$(command git -C "$repo" rev-parse HEAD)"
{ printf 'function runMigrationNumberCheck() { return "main"; }\n'; cat "$repo/scripts/branch-delivery-preflight.mjs"; } > "$fixture/main.mjs"
cp "$fixture/main.mjs" "$repo/scripts/branch-delivery-preflight.mjs"
command git -C "$repo" add scripts/branch-delivery-preflight.mjs
command git -C "$repo" commit -qm 'fixture main addition'
main="$(command git -C "$repo" rev-parse HEAD)"
command git clone -q --bare "$repo" "$remote"
command git -C "$repo" remote add origin "$remote"
command git -C "$repo" update-ref refs/remotes/origin/main "$main"
command git -C "$repo" checkout -q -b agent/issue-771 "$base"
{ cat "$repo/scripts/branch-delivery-preflight.mjs"; printf '\nfunction runMigrationNumberCheck() { return "branch"; }\n'; } > "$fixture/pr.mjs"
cp "$fixture/pr.mjs" "$repo/scripts/branch-delivery-preflight.mjs"
command git -C "$repo" add scripts/branch-delivery-preflight.mjs
command git -C "$repo" commit -qm 'issue #771 fixture duplicate addition'
command git -C "$repo" show "$main:scripts/branch-delivery-preflight.mjs" > "$fixture/main-side.mjs"
command git -C "$repo" show HEAD:scripts/branch-delivery-preflight.mjs > "$fixture/pr-side.mjs"
node --check "$fixture/main-side.mjs" || fail 'main side of the fixture must parse'
node --check "$fixture/pr-side.mjs" || fail 'branch side of the fixture must parse'

run_lander() {
  (
    cd "$repo"
    AGENT_HOME="$fixture/agent" ZF_AGENT_NAME=direct-main ZF_AGENT_ISSUES='' \
      ZF_ENGINE_DIR="$runtime/engine" ZF_EXECUTION_MODULE_DIR="$runtime/engine" \
      ZF_LAND_CODE_SNAPSHOT="$runtime" ZF_LAND_RESULT_DIR="$fixture/result" \
      ZF_REPO_DIR="$repo" ZF_PACK_REL=engine ZF_LAND_PREFLIGHT_TIMEOUT_SECONDS=30 \
      bash "$runtime/engine/land-direct-main.sh" --preflight-only
  )
}

if run_lander > "$fixture/duplicate.log" 2>&1; then
  cat "$fixture/duplicate.log" >&2
  fail 'land-direct-main accepted a merge result with a duplicate declaration'
fi
grep -Fq 'scripts/branch-delivery-preflight.mjs: SyntaxError: Identifier' "$fixture/duplicate.log" \
  || { cat "$fixture/duplicate.log" >&2; fail 'lander did not report the merge-result SyntaxError'; }
grep -Fq 'refusing push because merge result Node syntax check failed' "$fixture/duplicate.log" \
  || fail 'lander refusal did not clearly identify the blocked push'
if grep -Fq 'Push preflight passed:' "$fixture/duplicate.log"; then
  fail 'lander ran its delivery preflight after detecting the invalid merge result'
fi

command git -C "$repo" checkout -q -B agent/issue-772 "$base"
printf '\nfunction runDifferentCheck() { return true; }\n' >> "$repo/scripts/branch-delivery-preflight.mjs"
command git -C "$repo" add scripts/branch-delivery-preflight.mjs
command git -C "$repo" commit -qm 'issue #772 fixture valid addition'
if ! run_lander > "$fixture/valid.log" 2>&1; then
  cat "$fixture/valid.log" >&2
  fail 'lander refused a merge result that parses'
fi
grep -Fq 'Push preflight passed:' "$fixture/valid.log" \
  || { cat "$fixture/valid.log" >&2; fail 'valid merge did not reach the existing delivery preflight'; }
grep -Fq 'preflight-only passed' "$fixture/valid.log" || fail 'valid merge did not complete the preflight-only landing path'

printf 'land-merge-result-check.test.sh: PASS\n'
