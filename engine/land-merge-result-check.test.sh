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

real_node="$(command -v node)"
mkdir -p "$fixture/bin"
cat > "$fixture/bin/node" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FIXTURE_RACE_MAIN_SHA:-}" && "${1:-}" == "$FIXTURE_REPO/scripts/branch-delivery-preflight.mjs" ]]; then
  git --git-dir="$FIXTURE_REMOTE" update-ref refs/heads/main "$FIXTURE_RACE_MAIN_SHA"
fi
exec "$FIXTURE_REAL_NODE" "$@"
SH
chmod +x "$fixture/bin/node"

export GIT_AUTHOR_NAME='merge-result fixture' GIT_AUTHOR_EMAIL='merge-result@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
command git init -q -b main "$repo"
command git -C "$repo" config user.name "$GIT_AUTHOR_NAME"
command git -C "$repo" config user.email "$GIT_AUTHOR_EMAIL"
mkdir -p "$repo/scripts" "$repo/engine/prompts"
printf 'budget-fixture.md\t4\n' > "$repo/engine/prompts/byte-budgets.tsv"
printf 'okay' > "$repo/engine/prompts/budget-fixture.md"
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
command git -C "$repo" add scripts/branch-delivery-preflight.mjs engine/prompts
command git -C "$repo" commit -qm 'fixture base'
mkdir -p "$repo/docs" "$repo/packages/example/tests" "$repo/.zenoforge" "$repo/.agents" \
  "$repo/lessons/full" "$repo/lessons/pending"
printf 'Original recommendations\n' > "$repo/docs/operating-recommendations.md"
printf "readFileSync('docs/operating-recommendations.md');\n" > "$repo/packages/example/recommendations.test.mjs"
printf "readFileSync('operating-recommendations.md');\n" > "$repo/packages/example/tests/contracts.mjs"
printf '{"engine":"base"}\n' > "$repo/.zenoforge/build.json"
printf 'base pin fixture\n' > "$repo/.agents/pin-fixture.md"
printf "readFileSync('.zenoforge/build.json'); readFileSync('.agents/pin-fixture.md');\n" \
  > "$repo/packages/example/pin.test.mjs"
printf '# Rules\n' > "$repo/lessons/RULES.md"
printf '# Catalog\n' > "$repo/lessons/CATALOG.md"
printf 'base full lesson\n' > "$repo/lessons/full/generated.md"
printf '{"id":"generated"}\n' > "$repo/lessons/pending/generated.json"
printf "readFileSync('lessons/RULES.md'); readFileSync('lessons/CATALOG.md'); readFileSync('lessons/full/generated.md'); readFileSync('lessons/pending/generated.json');\n" \
  > "$repo/packages/example/lessons.test.mjs"
command git -C "$repo" add docs packages .zenoforge .agents lessons
command git -C "$repo" commit -qm 'fixture: seed doc references in tests'
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
  local -a lander_args=(--preflight-only)
  if [[ "${FIXTURE_RUN_FULL_LANDER:-0}" == 1 ]]; then
    lander_args=()
  fi
  (
    cd "$repo"
    PATH="$fixture/bin:$PATH" \
      FIXTURE_REPO="$repo" FIXTURE_REMOTE="$remote" FIXTURE_REAL_NODE="$real_node" \
    AGENT_HOME="$fixture/agent" ZF_AGENT_NAME=direct-main ZF_AGENT_ISSUES='' \
      ZF_ENGINE_DIR="$runtime/engine" ZF_EXECUTION_MODULE_DIR="$runtime/engine" \
      ZF_LAND_CODE_SNAPSHOT="$runtime" ZF_LAND_RESULT_DIR="$fixture/result" \
      ZF_REPO_DIR="$repo" ZF_PACK_REL=engine ZF_LAND_PREFLIGHT_TIMEOUT_SECONDS=30 \
      bash "$runtime/engine/land-direct-main.sh" "${lander_args[@]}"
  )
}

run_skip_ci_policy() {
  (
    cd "$repo"
    land_script_dir="$runtime/engine"
    export ZF_PACK_REL=engine
    source "$runtime/engine/land-direct-main-policy.sh"
    refuse_skip_ci_test_references "$main..HEAD"
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

command git -C "$repo" checkout -q -B agent/issue-773 "$base"
printf 'x' >> "$repo/engine/prompts/budget-fixture.md"
command git -C "$repo" add engine/prompts/budget-fixture.md
command git -C "$repo" commit -qm 'issue #773 fixture over-budget prompt'
if run_lander > "$fixture/prompt-budget.log" 2>&1; then
  cat "$fixture/prompt-budget.log" >&2
  fail 'land-direct-main accepted an over-budget prompt'
fi
grep -Fq 'engine/prompts/budget-fixture.md is 5 bytes, budget 4 bytes' "$fixture/prompt-budget.log" \
  || { cat "$fixture/prompt-budget.log" >&2; fail 'direct-main refusal omitted the prompt size and budget'; }

command git -C "$repo" checkout -q -B agent/issue-774 "$main"
printf 'Updated recommendations\n' > "$repo/docs/operating-recommendations.md"
command git -C "$repo" add docs/operating-recommendations.md
command git -C "$repo" commit -qm '[skip ci] docs: update recommendations'
if run_lander > "$fixture/referenced-doc.log" 2>&1; then
  cat "$fixture/referenced-doc.log" >&2
  fail 'land-direct-main accepted a [skip ci] doc change referenced by tests'
fi
grep -Fq 'changed file docs/operating-recommendations.md' "$fixture/referenced-doc.log" \
  || { cat "$fixture/referenced-doc.log" >&2; fail 'referenced-doc refusal omitted the changed path'; }
grep -Fq 'packages/example/recommendations.test.mjs' "$fixture/referenced-doc.log" \
  || { cat "$fixture/referenced-doc.log" >&2; fail 'referenced-doc refusal omitted the path-matching test'; }
grep -Fq 'packages/example/tests/contracts.mjs' "$fixture/referenced-doc.log" \
  || { cat "$fixture/referenced-doc.log" >&2; fail 'referenced-doc refusal omitted the basename-matching test'; }
grep -Fq 'land without [skip ci] (PR or CI-running commit) instead' "$fixture/referenced-doc.log" \
  || { cat "$fixture/referenced-doc.log" >&2; fail 'referenced-doc refusal omitted the corrective action'; }

command git -C "$repo" checkout -q -B agent/issue-775 "$main"
printf 'An unreferenced guide\n' > "$repo/docs/unreferenced-guide.md"
command git -C "$repo" add docs/unreferenced-guide.md
command git -C "$repo" commit -qm '[skip ci] docs: add unreferenced guide'
if ! run_lander > "$fixture/unreferenced-doc.log" 2>&1; then
  cat "$fixture/unreferenced-doc.log" >&2
  fail 'land-direct-main refused a [skip ci] doc change that no test names'
fi
grep -Fq 'Push preflight passed:' "$fixture/unreferenced-doc.log" \
  || { cat "$fixture/unreferenced-doc.log" >&2; fail 'unreferenced [skip ci] doc did not reach preflight'; }
grep -Fq 'preflight-only passed' "$fixture/unreferenced-doc.log" \
  || { cat "$fixture/unreferenced-doc.log" >&2; fail 'unreferenced [skip ci] doc did not pass'; }

command git -C "$repo" checkout -q -B agent/issue-777 "$main"
printf '{"engine":"pinned"}\n' > "$repo/.zenoforge/build.json"
command git -C "$repo" add .zenoforge/build.json
command git -C "$repo" commit -qm '[skip ci] chore(engine): pin zenoforge 0123456789abcdef0123456789abcdef01234567'
if ! run_skip_ci_policy > "$fixture/pin-only.log" 2>&1; then
  cat "$fixture/pin-only.log" >&2
  fail 'skip-ci policy refused a pin-only build manifest change'
fi

command git -C "$repo" checkout -q -B agent/issue-778 "$main"
printf '{"engine":"pinned"}\n' > "$repo/.zenoforge/build.json"
printf 'Updated pin fixture\n' > "$repo/.agents/pin-fixture.md"
command git -C "$repo" add .zenoforge/build.json .agents/pin-fixture.md
command git -C "$repo" commit -qm '[skip ci] chore(engine): pin zenoforge 0123456789abcdef0123456789abcdef01234567'
if run_skip_ci_policy > "$fixture/pin-with-other-reference.log" 2>&1; then
  cat "$fixture/pin-with-other-reference.log" >&2
  fail 'skip-ci policy accepted a pin commit with another test-referenced file'
fi
grep -Fq 'changed file .agents/pin-fixture.md' "$fixture/pin-with-other-reference.log" \
  || { cat "$fixture/pin-with-other-reference.log" >&2; fail 'mixed pin refusal omitted the additional file'; }
grep -Fq 'packages/example/pin.test.mjs' "$fixture/pin-with-other-reference.log" \
  || { cat "$fixture/pin-with-other-reference.log" >&2; fail 'mixed pin refusal omitted its test reference'; }

command git -C "$repo" checkout -q -B agent/issue-779 "$main"
printf '# Folded Rules\n' > "$repo/lessons/RULES.md"
printf '# Folded Catalog\n' > "$repo/lessons/CATALOG.md"
printf 'folded full lesson\n' > "$repo/lessons/full/generated.md"
command git -C "$repo" rm -q lessons/pending/generated.json
command git -C "$repo" add lessons/RULES.md lessons/CATALOG.md lessons/full/generated.md
command git -C "$repo" commit -qm '[skip ci] fold merged lesson fragments'
printf '# Folded Catalog by current producer\n' > "$repo/lessons/CATALOG.md"
command git -C "$repo" add lessons/CATALOG.md
command git -C "$repo" commit -qm '[skip ci] fold lesson documentation'
printf '# Assigned Rules\n' > "$repo/lessons/RULES.md"
printf 'assigned full lesson\n' > "$repo/lessons/full/generated.md"
command git -C "$repo" add lessons/RULES.md lessons/full/generated.md
command git -C "$repo" commit -qm '[skip ci] assign merged lesson IDs'
if ! run_skip_ci_policy > "$fixture/lesson-commits.log" 2>&1; then
  cat "$fixture/lesson-commits.log" >&2
  fail 'skip-ci policy refused test-referenced lesson reconciliation commits'
fi

command git -C "$repo" checkout -q -B agent/issue-780 "$main"
printf '# Mixed Rules\n' > "$repo/lessons/RULES.md"
printf 'Updated pin fixture\n' > "$repo/.agents/pin-fixture.md"
command git -C "$repo" add lessons/RULES.md .agents/pin-fixture.md
command git -C "$repo" commit -qm '[skip ci] fold lesson documentation'
if run_skip_ci_policy > "$fixture/lesson-with-other-reference.log" 2>&1; then
  cat "$fixture/lesson-with-other-reference.log" >&2
  fail 'skip-ci policy accepted a lesson fold commit with another test-referenced file'
fi
grep -Fq 'changed file .agents/pin-fixture.md' "$fixture/lesson-with-other-reference.log" \
  || { cat "$fixture/lesson-with-other-reference.log" >&2; fail 'mixed lesson refusal omitted the additional file'; }

command git -C "$repo" checkout -q -B agent/issue-776 "$main"
printf 'An unreferenced guide\n' > "$repo/docs/unreferenced-guide.md"
command git -C "$repo" add docs/unreferenced-guide.md
command git -C "$repo" commit -qm '[skip ci] docs: add guide before concurrent test'
command git -C "$repo" checkout -q -B fixture-race "$main"
printf "readFileSync('unreferenced-guide.md');\n" > "$repo/packages/example/tests/race.mjs"
command git -C "$repo" add packages/example/tests/race.mjs
command git -C "$repo" commit -qm 'fixture: add a concurrent test reference'
race_main="$(command git -C "$repo" rev-parse HEAD)"
command git -C "$repo" push -q origin "$race_main:refs/heads/fixture-race"
command git -C "$repo" checkout -q agent/issue-776
if FIXTURE_RACE_MAIN_SHA="$race_main" FIXTURE_RUN_FULL_LANDER=1 run_lander > "$fixture/rebase-reference.log" 2>&1; then
  cat "$fixture/rebase-reference.log" >&2
  fail 'land-direct-main accepted a [skip ci] doc after rebasing onto a test reference'
fi
grep -Fq 'changed file docs/unreferenced-guide.md' "$fixture/rebase-reference.log" \
  || { cat "$fixture/rebase-reference.log" >&2; fail 'rebase refusal omitted the changed doc'; }
grep -Fq 'packages/example/tests/race.mjs' "$fixture/rebase-reference.log" \
  || { cat "$fixture/rebase-reference.log" >&2; fail 'rebase refusal omitted the concurrent test'; }

printf 'land-merge-result-check.test.sh: PASS\n'
