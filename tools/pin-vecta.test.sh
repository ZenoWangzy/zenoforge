#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
pin_script="$script_dir/pin-vecta.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pin-vecta-test.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/tmp"
export TMPDIR="$tmp/tmp"
export PATH="$tmp/bin:$PATH"

fail() { echo "pin-vecta.test.sh: $*" >&2; exit 1; }
ok() { echo "pin-vecta.test.sh: $*"; }

cat > "$tmp/bin/systemd-run" <<'SYSTEMD'
#!/usr/bin/env bash
set -euo pipefail
printf 'scope:%s\n' "$*" >> "${PIN_SCOPE_CALLS:?}"
while (($#)) && [[ "$1" != -- ]]; do shift; done
[[ $# -gt 1 ]] || exit 2
shift
exec "$@"
SYSTEMD
chmod +x "$tmp/bin/systemd-run"

engine_repo="$tmp/engine"
git init -q --initial-branch=main "$engine_repo"
git -C "$engine_repo" config user.name 'pin-vecta test'
git -C "$engine_repo" config user.email 'pin-vecta@example.invalid'
mkdir -p "$engine_repo/engine/hotfix"
printf 'echo old one\n' > "$engine_repo/engine/hotfix/one.sh"
printf 'echo old two\n' > "$engine_repo/engine/hotfix/two.sh"
printf '{"value":"old"}\n' > "$engine_repo/engine/hotfix.json"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'fixture: old engine'
old_engine=$(git -C "$engine_repo" rev-parse HEAD)
printf 'echo old one\necho shared line\n' > "$engine_repo/engine/hotfix/one.sh"
printf 'echo engine-only line\n' > "$engine_repo/engine/hotfix/two.sh"
printf '{"value":"new"}\n' > "$engine_repo/engine/hotfix.json"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'fixture: engine changes'
new_engine=$(git -C "$engine_repo" rev-parse HEAD)

cat > "$tmp/bin/engine-sync" <<'SYNC'
#!/usr/bin/env bash
set -euo pipefail
printf 'dispatcher:%s\n' "$*" >> "${PIN_CALLS:?}"
case "${1:-}" in
  --build)
    if [[ "${PIN_BUILD_FAIL:-}" == override ]]; then
      echo 'override changed: hotfix/one.sh; update overrides.tsv' >&2
      echo 'override changed: hotfix/two.sh; update overrides.tsv' >&2
      echo 'engine-sync: override guard failed' >&2
      exit 1
    fi
    engine_sha=$2
    product_sha=$3
    out_root=$5
    version="$out_root/${engine_sha:0:12}-fixture"
    mkdir -p "$version/engine"
    printf 'id=%s\nzenoforge_sha=%s\nproduct_sha=%s\n' "${version##*/}" "$engine_sha" "$product_sha" > "$version/BUILD-INFO"
    cat > "$version/engine/engine-sync.sh" <<'PREFLIGHT'
#!/usr/bin/env bash
set -euo pipefail
printf 'candidate:%s\n' "$*" >> "${PIN_CALLS:?}"
if [[ "${1:-}" == --preflight && "${PIN_PREFLIGHT_FAIL:-0}" == 1 ]]; then
  echo 'resolved-config-check: CHANGED hotfix.json: live aaaa -> new bbbb' >&2
  echo 'publish-preflight: resolved-config check failed' >&2
  exit 1
fi
echo 'publish-preflight: OK'
PREFLIGHT
    chmod +x "$version/engine/engine-sync.sh"
    echo "engine-sync: built $version"
    ;;
  --check)
    if [[ -f "$2/BUILD-INFO" ]]; then echo "engine-sync: check OK $2"; else echo "engine-sync: check FAILED $2" >&2; exit 1; fi
    ;;
  --preflight)
    echo 'fallback publish-preflight: attempted' >&2
    ;;
  *) echo "unexpected engine-sync mode: ${1:-<none>}" >&2; exit 2 ;;
esac
SYNC
chmod +x "$tmp/bin/engine-sync"

cat > "$tmp/bin/node" <<'NODE'
#!/usr/bin/env bash
set -euo pipefail
script="$1"
shift
if [[ "$script" == */scripts/branch-delivery-policy.mjs ]]; then
  printf 'classifier:%s %s\n' "$script" "$*" >> "$PIN_CALLS"
  [[ "$*" == '--classify-path-set -' ]] || exit 2
  paths=$(cat)
  # Mirrors VectA's BRANCH_DELIVERY_POLICY_PR_PATHS: overrides.tsv is PR-only.
  if jq -e 'type == "array" and length > 0 and all(.[]; (startswith(".zenoforge/") or startswith("docs/")) and . != ".zenoforge/build/overrides.tsv")' \
      <<<"$paths" >/dev/null; then
    printf 'eligible\n'
  else
    printf 'not-eligible\n'
  fi
  exit 0
fi
printf 'delivery:%s %s\n' "$script" "$*" >> "${PIN_CALLS:?}"
[[ "$script" == */scripts/branch-delivery-preflight.mjs && "$*" == '--mode push --publish-topic' ]]
repo=$(dirname "$(dirname "$script")")
branch=$(git -C "$repo" symbolic-ref --short HEAD)
git -C "$repo" push -q --set-upstream origin "$branch"
NODE
chmod +x "$tmp/bin/node"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh:%s\n' "$*" >> "${PIN_CALLS:?}"
printf 'gh-cwd:%s\n' "$PWD" >> "${PIN_CALLS:?}"
if [[ "${1:-}" == api ]]; then
  [[ "${PIN_GH_API_FAIL:-0}" != 1 ]] || exit 1
  if [[ -n "${PIN_WORKFLOW_RUNS+x}" ]]; then
    printf '%s\n' "$PIN_WORKFLOW_RUNS"
  else
    printf '%s\n' '[{"workflow_runs":[]}]'
  fi
fi
GH
chmod +x "$tmp/bin/gh"
export GH="$tmp/bin/gh"

setup_target() { # <name>
  local name="$1" bare="$tmp/$1-origin.git" target="$tmp/$1-target"
  git init -q --bare "$bare"
  git init -q --initial-branch=main "$target"
  git -C "$target" config user.name 'pin-vecta fixture'
  git -C "$target" config user.email 'pin-vecta@example.invalid'
  mkdir -p "$target/.zenoforge/build/pack/scripts/agent/hotfix"
  mkdir -p "$target/scripts"
  printf '.worktrees/\n' > "$target/.gitignore"
  printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$old_engine" > "$target/.zenoforge/build.json"
  : > "$target/.zenoforge/build/overrides.tsv"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$target/.zenoforge/build/engine-sync.sh"
  printf '// fixture delivery preflight\n' > "$target/scripts/branch-delivery-preflight.mjs"
  printf '// fixture branch delivery policy classifier\n' > "$target/scripts/branch-delivery-policy.mjs"
  chmod +x "$target/.zenoforge/build/engine-sync.sh"
  git -C "$target" add -A
  git -C "$target" commit -qm 'fixture: initial Vecta state'
  git -C "$target" remote add origin "$bare"
  git -C "$target" push -q -u origin main
  printf '%s\n' "$target"
}

setup_agent() { # <name> [pack map rows]
  local name="$1" agent="$tmp/$1-agent"
  mkdir -p "$agent/engine-versions/live/engine"
  ln -s "engine-versions/live/engine" "$agent/engine-live"
  if (($# > 1)); then printf '%s\n' "$2" > "$agent/engine-versions/live/PACK-FILES"; fi
  printf '%s\n' "$agent"
}

run_pin() { # <calls-file> <scope-file> <agent-home> <target> [args...]
  local calls="$1" scopes="$2" agent="$3" target="$4"
  shift 4
  PIN_CALLS="$calls" PIN_SCOPE_CALLS="$scopes" \
    AGENT_HOME="$agent" ZF_ENGINE_SYNC="$tmp/bin/engine-sync" \
    ZF_LOCAL_CLONE="$engine_repo" \
    bash "$pin_script" "$new_engine" "$target" "$@"
}

# Main CI pin guard: only completed failures for this exact SHA on main block;
# named workflow overrides are narrow, pending runs are allowed, and API errors fail closed.
ci_target=$(setup_target ci)
ci_agent=$(setup_agent ci)
ci_calls="$tmp/ci.calls"
ci_scopes="$tmp/ci.scopes"
: > "$ci_calls"
: > "$ci_scopes"
failed_runs=$(jq -cn --arg sha "$new_engine" '{workflow_runs:[
  {name:"engine-tests",head_sha:$sha,head_branch:"main",status:"completed",conclusion:"failure"},
  {name:"engine-tests",head_sha:$sha,head_branch:"feature",status:"completed",conclusion:"failure"},
  {name:"cli-tests",head_sha:("0" * 40),head_branch:"main",status:"completed",conclusion:"failure"},
  {name:"unrelated",head_sha:$sha,head_branch:"main",status:"completed",conclusion:"failure"}
]} | [. ]')
set +e
PIN_WORKFLOW_RUNS="$failed_runs" run_pin "$ci_calls" "$ci_scopes" "$ci_agent" "$ci_target" > "$tmp/ci-blocked.out" 2>&1
ci_blocked_status=$?
set -e
((ci_blocked_status != 0)) || fail 'completed engine-tests failure on main was allowed without an override'
grep -Fq "failed zenoforge main workflows for $new_engine: engine-tests" "$tmp/ci-blocked.out" \
  || fail 'main CI failure was not named in the refusal'
! grep -q '^dispatcher:' "$ci_calls" || fail 'failed main CI ran pin build steps before refusing'

if ! PIN_WORKFLOW_RUNS="$failed_runs" ZF_PIN_OVERRIDE=engine-tests \
  run_pin "$ci_calls" "$ci_scopes" "$ci_agent" "$ci_target" > "$tmp/ci-override.out" 2>&1; then
  cat "$tmp/ci-override.out" >&2
  fail 'named engine-tests override did not allow the pin'
fi
grep -Fq 'explicit ZF_PIN_OVERRIDE allows failed workflows: engine-tests' "$tmp/ci-override.out" \
  || fail 'allowed workflow override was not printed'

both_failed_runs=$(jq -cn --arg sha "$new_engine" '{workflow_runs:[
  {name:"engine-tests",head_sha:$sha,head_branch:"main",status:"completed",conclusion:"failure"},
  {name:"cli-tests",head_sha:$sha,head_branch:"main",status:"completed",conclusion:"failure"}
]} | [. ]')
set +e
PIN_WORKFLOW_RUNS="$both_failed_runs" ZF_PIN_OVERRIDE=engine-tests \
  run_pin "$ci_calls" "$ci_scopes" "$ci_agent" "$ci_target" > "$tmp/ci-partial.out" 2>&1
ci_partial_status=$?
set -e
((ci_partial_status != 0)) || fail 'engine-tests override allowed an unlisted cli-tests failure'
grep -Fq 'failed zenoforge main workflows' "$tmp/ci-partial.out" \
  && grep -Fq 'cli-tests' "$tmp/ci-partial.out" \
  || fail 'partial override refusal did not name the unapproved workflow'

pending_runs=$(jq -cn --arg sha "$new_engine" '{workflow_runs:[
  {name:"engine-tests",head_sha:$sha,head_branch:"main",status:"in_progress",conclusion:null},
  {name:"cli-tests",head_sha:$sha,head_branch:"main",status:"queued",conclusion:null}
]} | [. ]')
if ! PIN_WORKFLOW_RUNS="$pending_runs" run_pin "$ci_calls" "$ci_scopes" "$ci_agent" "$ci_target" > "$tmp/ci-pending.out" 2>&1; then
  cat "$tmp/ci-pending.out" >&2
  fail 'pending main CI runs were not allowed'
fi
grep -Fq 'pin-vecta: prepared route=' "$tmp/ci-pending.out" || fail 'pending CI did not reach pin preparation'

set +e
PIN_GH_API_FAIL=1 run_pin "$ci_calls" "$ci_scopes" "$ci_agent" "$ci_target" > "$tmp/ci-unreadable.out" 2>&1
ci_unreadable_status=$?
set -e
((ci_unreadable_status != 0)) || fail 'pin continued when main CI runs could not be read'
grep -Fq 'could not read zenoforge main CI runs' "$tmp/ci-unreadable.out" \
  || fail 'CI API read failure was not explained'
ok 'main CI pin guard blocks completed failures, permits named overrides and pending runs, and fails closed on unreadable runs'

# A pin-only diff gets a fresh worktree/out root, a skip-ci head commit, and all
# three engine operations in order. Default mode does not publish.
direct_target=$(setup_target direct)
direct_agent=$(setup_agent direct)
direct_calls="$tmp/direct.calls"
direct_scopes="$tmp/direct.scopes"
: > "$direct_calls"
: > "$direct_scopes"
if ! run_pin "$direct_calls" "$direct_scopes" "$direct_agent" "$direct_target" > "$tmp/direct.out" 2>&1; then
  cat "$tmp/direct.out" >&2
  fail 'direct pin preparation failed'
fi
direct_worktree=$(sed -n 's/^pin-vecta: worktree=//p' "$tmp/direct.out" | tail -1)
[[ -n "$direct_worktree" && -d "$direct_worktree" ]] || fail 'fresh worktree was not created'
direct_out=$(sed -n 's/^pin-vecta: out=//p' "$tmp/direct.out" | tail -1)
[[ -n "$direct_out" && -d "$direct_out" ]] || fail 'fresh out directory was not created'
subject=$(git -C "$direct_worktree" log -1 --format=%s)
[[ "$subject" == '[skip ci]'* ]] || fail "direct route commit lacks [skip ci]: $subject"
grep -Fq 'pin-vecta: prepared route=land-direct-main' "$tmp/direct.out" || fail 'pin-only diff did not select land-direct-main'
build_line=$(grep -n '^dispatcher:--build ' "$direct_calls" | cut -d: -f1)
check_line=$(grep -n '^dispatcher:--check ' "$direct_calls" | cut -d: -f1)
preflight_line=$(grep -n '^candidate:--preflight ' "$direct_calls" | cut -d: -f1)
[[ -n "$build_line" && -n "$check_line" && -n "$preflight_line" ]] || fail 'build, check, or publish preflight was skipped'
((build_line < check_line && check_line < preflight_line)) || fail 'engine steps ran out of order'
[[ $(wc -l < "$direct_scopes" | tr -d '[:space:]') == 3 ]] || fail 'build, check, and preflight were not each resource bounded'
[[ "$(git --git-dir="$tmp/direct-origin.git" rev-parse refs/heads/main)" == "$(git -C "$direct_target" rev-parse origin/main)" ]] \
  || fail 'default mode pushed a direct-main pin'
ok 'pin-only diff is prepared and stopped before publication'

# A mixed product pin that also touches the pack uses the PR route, and publish
# preflight still runs. If it rejects a config change, --land cannot push or create a PR.
pack_target=$(setup_target pack)
git -C "$pack_target" checkout -q -b product-pack-change
printf 'pack line\n' > "$pack_target/.zenoforge/build/pack/scripts/agent/hotfix/pack-touch.sh"
printf '# pack-touching override table change\n' > "$pack_target/.zenoforge/build/overrides.tsv"
mkdir -p "$pack_target/packages/fixture"
printf 'product line\n' > "$pack_target/packages/fixture/product-touch.js"
git -C "$pack_target" add .zenoforge/build/pack/scripts/agent/hotfix/pack-touch.sh
git -C "$pack_target" add .zenoforge/build/overrides.tsv
git -C "$pack_target" add packages/fixture/product-touch.js
git -C "$pack_target" commit -qm 'fixture: pack changes'
pack_agent=$(setup_agent pack)
pack_calls="$tmp/pack.calls"
pack_scopes="$tmp/pack.scopes"
set +e
PIN_PREFLIGHT_FAIL=1 PIN_CALLS="$pack_calls" PIN_SCOPE_CALLS="$pack_scopes" \
  AGENT_HOME="$pack_agent" ZF_ENGINE_SYNC="$tmp/bin/engine-sync" \
  ZF_LOCAL_CLONE="$engine_repo" GH="$tmp/bin/gh" \
  bash "$pin_script" "$new_engine" "$pack_target" --land > "$tmp/pack.out" 2>&1
pack_status=$?
set -e
((pack_status != 0)) || fail 'failed pack preflight was allowed to publish'
pack_worktree=$(sed -n 's/^pin-vecta: worktree=//p' "$tmp/pack.out" | tail -1)
[[ -n "$pack_worktree" && -d "$pack_worktree" ]] || fail 'pack pin worktree was not retained for review'
pack_subject=$(git -C "$pack_worktree" log -1 --format=%s)
[[ "$pack_subject" != '[skip ci]'* ]] || fail "pack-touching PR commit unexpectedly has [skip ci]: $pack_subject"
grep -Fq 'candidate:--preflight ' "$pack_calls" || fail 'publish preflight was skipped for the PR route'
grep -Fq 'resolved-config-check: CHANGED hotfix.json' "$tmp/pack.out" || fail 'fixture did not reach the intended publish-preflight failure'
expected_row=$(printf 'hotfix.json\tengine pin %s changes resolved config\t%s' "${new_engine:0:12}" "$new_engine")
grep -Fq "$expected_row" "$tmp/pack.out" || fail 'preflight failure did not print the exact intended-changes row'
if [[ -e "$pack_calls" ]]; then ! grep -q '^gh:pr create ' "$pack_calls" || fail 'failed preflight still created a PR'; fi
[[ "$(git --git-dir="$tmp/pack-origin.git" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d '[:space:]')" == 1 ]] \
  || fail 'failed preflight pushed a topic branch'
ok 'mixed product and pack pin uses the PR preflight and refuses publication on failure'

# A passing PR pin goes through Vecta's SHA-bound branch preflight before the
# PR is created. The simulated publisher only pushes to the fixture bare repo.
pr_target=$(setup_target pr)
git -C "$pr_target" checkout -q -b product-change
printf '# existing override row\n' > "$pr_target/.zenoforge/build/overrides.tsv"
mkdir -p "$pr_target/packages/fixture"
printf 'product line\n' > "$pr_target/packages/fixture/product-touch.js"
git -C "$pr_target" add .zenoforge/build/overrides.tsv
git -C "$pr_target" add packages/fixture/product-touch.js
git -C "$pr_target" commit -qm 'fixture: reviewed product change'
pr_agent=$(setup_agent pr)
pr_calls="$tmp/pr.calls"
pr_scopes="$tmp/pr.scopes"
: > "$pr_calls"
: > "$pr_scopes"
set +e
run_pin "$pr_calls" "$pr_scopes" "$pr_agent" "$pr_target" --land > "$tmp/pr.out" 2>&1
pr_status=$?
set -e
if ((pr_status != 75)); then
  cat "$tmp/pr.out" >&2
  fail "PR pin must exit 75 (opened, not landed), got $pr_status"
fi
pr_worktree=$(sed -n 's/^pin-vecta: worktree=//p' "$tmp/pr.out" | tail -1)
pr_branch=$(git -C "$pr_worktree" symbolic-ref --short HEAD)
pr_subject=$(git -C "$pr_worktree" log -1 --format=%s)
[[ "$pr_subject" != '[skip ci]'* ]] || fail "PR route commit unexpectedly has [skip ci]: $pr_subject"
grep -Fq "delivery:$pr_worktree/scripts/branch-delivery-preflight.mjs --mode push --publish-topic" "$pr_calls" \
  || fail 'PR route skipped Vecta branch delivery preflight'
grep -Fq 'gh:pr create --base main' "$pr_calls" || fail 'PR route did not create a PR after push preflight'
git --git-dir="$tmp/pr-origin.git" show-ref --verify --quiet "refs/heads/$pr_branch" \
  || fail 'successful PR route did not push the preflighted branch'
grep -Fxq "gh-cwd:$pr_worktree" "$pr_calls" || fail 'PR route did not create the PR from the Vecta worktree'
grep -Eq '^pin-vecta: result=pr-open route=PR landed=no ' "$tmp/pr.out" \
  || fail 'PR route did not say the pin is not landed'
! grep -q 'result=landed' "$tmp/pr.out" || fail 'PR route claimed landed'
ok 'passing PR pin uses the topic publish preflight and creates a PR'

# land-direct-main refuses a detached HEAD, so it must run in the pin worktree,
# never in the caller's engine checkout.
land_target=$(setup_target land)
land_agent=$(setup_agent land)
land_calls="$tmp/land.calls"
land_scopes="$tmp/land.scopes"
: > "$land_calls"
: > "$land_scopes"
cat > "$tmp/fake-lander.sh" <<'LANDER'
#!/usr/bin/env bash
printf 'lander-cwd:%s\n' "$PWD" >> "${PIN_CALLS:?}"
LANDER
if ! ZF_LAND_DIRECT_MAIN="$tmp/fake-lander.sh" run_pin "$land_calls" "$land_scopes" "$land_agent" "$land_target" --land > "$tmp/land.out" 2>&1; then
  cat "$tmp/land.out" >&2
  fail 'passing direct pin did not reach land-direct-main'
fi
land_worktree=$(sed -n 's/^pin-vecta: worktree=//p' "$tmp/land.out" | tail -1)
grep -Fxq "lander-cwd:$land_worktree" "$land_calls" || fail 'land-direct-main did not run from the pin worktree'
grep -Fq 'pin-vecta: result=landed route=land-direct-main landed=yes' "$tmp/land.out" \
  || fail 'direct route did not report landed'
ok 'direct pin lands from the pin worktree'

# A lander that fails (it may already have pushed) must not be reported as landed.
lf_target=$(setup_target landfail)
lf_agent=$(setup_agent landfail)
: > "$tmp/landfail.calls"; : > "$tmp/landfail.scopes"
printf '#!/usr/bin/env bash\nexit 7\n' > "$tmp/failing-lander.sh"
set +e
ZF_LAND_DIRECT_MAIN="$tmp/failing-lander.sh" run_pin "$tmp/landfail.calls" "$tmp/landfail.scopes" "$lf_agent" "$lf_target" --land > "$tmp/landfail.out" 2>&1
lf_status=$?
set -e
((lf_status == 7)) || fail "failing lander exit was not passed through: $lf_status"
grep -Fq 'result=land-failed route=land-direct-main landed=unknown' "$tmp/landfail.out" || fail 'failed lander did not say landed=unknown'
! grep -q 'result=landed' "$tmp/landfail.out" || fail 'failed lander reported landed'
ok 'failed lander reports landed=unknown and keeps its exit code'

# A pin plus a pack-only target diff follows the target classifier's direct-main
# lane, keeps [skip ci], and never tries to create a PR.
pack_direct_target=$(setup_target pack-direct)
git -C "$pack_direct_target" checkout -q -b pack-only-change
printf 'pack direct line\n' > "$pack_direct_target/.zenoforge/build/pack/scripts/agent/hotfix/pack-only.sh"
git -C "$pack_direct_target" add .zenoforge/build/pack/scripts/agent/hotfix/pack-only.sh
git -C "$pack_direct_target" commit -qm 'fixture: direct-main pack change'
pack_direct_agent=$(setup_agent pack-direct)
pack_direct_calls="$tmp/pack-direct.calls"
pack_direct_scopes="$tmp/pack-direct.scopes"
: > "$pack_direct_calls"
: > "$pack_direct_scopes"
if ! ZF_LAND_DIRECT_MAIN="$tmp/fake-lander.sh" \
  run_pin "$pack_direct_calls" "$pack_direct_scopes" "$pack_direct_agent" "$pack_direct_target" --land \
  > "$tmp/pack-direct.out" 2>&1; then
  cat "$tmp/pack-direct.out" >&2
  fail 'pack-only direct-main pin did not publish through land-direct-main'
fi
pack_direct_worktree=$(sed -n 's/^pin-vecta: worktree=//p' "$tmp/pack-direct.out" | tail -1)
pack_direct_subject=$(git -C "$pack_direct_worktree" log -1 --format=%s)
[[ "$pack_direct_subject" == '[skip ci]'* ]] \
  || fail "pack-only direct-main commit lacks [skip ci]: $pack_direct_subject"
grep -Fq 'pin-vecta: prepared route=land-direct-main' "$tmp/pack-direct.out" \
  || fail 'pack-only pin did not select land-direct-main'
git -C "$pack_direct_worktree" diff --name-only origin/main...HEAD | grep -Fxq '.zenoforge/build.json' \
  || fail 'pack-only pin diff omitted .zenoforge/build.json'
git -C "$pack_direct_worktree" diff --name-only origin/main...HEAD \
  | grep -Fxq '.zenoforge/build/pack/scripts/agent/hotfix/pack-only.sh' \
  || fail 'pack-only pin diff omitted its .zenoforge/build/pack/ path'
grep -Fq "classifier:$pack_direct_worktree/scripts/branch-delivery-policy.mjs --classify-path-set -" "$pack_direct_calls" \
  || fail 'pack-only pin did not classify through the target worktree policy'
grep -Fxq "lander-cwd:$pack_direct_worktree" "$pack_direct_calls" \
  || fail 'pack-only pin did not use the direct-main lander'
! grep -q '^gh:pr create ' "$pack_direct_calls" \
  || fail 'pack-only direct-main pin called gh pr create'
ok 'pack-only target diff selects direct-main, keeps [skip ci], and never creates a PR'

# An override guard failure still attempts check and preflight, then names every
# stale override and says whether the mapped pack copy contains the changed line.
override_target=$(setup_target override)
# No rows: the pin's own merge step skips unlisted files, so the guard failure below reaches the diagnostics.
: > "$override_target/.zenoforge/build/overrides.tsv"
printf 'echo old one\necho shared line\n' > "$override_target/.zenoforge/build/pack/scripts/agent/hotfix/one.sh"
printf 'echo pack-only line\n' > "$override_target/.zenoforge/build/pack/scripts/agent/hotfix/two.sh"
git -C "$override_target" add -A
git -C "$override_target" commit -qm 'fixture: current override rows and pack copies'
override_agent=$(setup_agent override $'scripts/agent/hotfix/one.sh\thotfix/one.sh\tPACK\toverride\nscripts/agent/hotfix/two.sh\thotfix/two.sh\tPACK\toverride')
override_calls="$tmp/override.calls"
override_scopes="$tmp/override.scopes"
: > "$override_calls"
: > "$override_scopes"
set +e
PIN_BUILD_FAIL=override run_pin "$override_calls" "$override_scopes" "$override_agent" "$override_target" > "$tmp/override.out" 2>&1
override_status=$?
set -e
((override_status != 0)) || fail 'override guard failure was ignored'
grep -Fq 'hotfix/one.sh expected=missing' "$tmp/override.out" || fail 'first override mismatch was not reported'
grep -Fq 'hotfix/two.sh expected=missing actual=' "$tmp/override.out" || fail 'missing override row was not reported'
grep -Fq 'pack copy shares changed lines: yes (1/1 lines; .zenoforge/build/pack/scripts/agent/hotfix/one.sh)' "$tmp/override.out" \
  || fail 'pack copy sharing the changed line was not reported'
grep -Fq 'pack copy shares changed lines: no (0/2 lines; .zenoforge/build/pack/scripts/agent/hotfix/two.sh)' "$tmp/override.out" \
  || fail 'pack copy missing the changed line was not reported'
grep -Fq 'fallback publish-preflight: attempted' "$tmp/override.out" || fail 'preflight was skipped after an override build failure'
ok 'override diagnostics report each path and pack-line overlap'

# Override three-way merge: engine B2 changes m.sh (top) and c.sh (line 3) and
# deletes d.sh. Rows are made from the B1 blobs.
mengine="$tmp/mengine"
git init -q --initial-branch=main "$mengine"
git -C "$mengine" config user.name 'pin-vecta test'
git -C "$mengine" config user.email 'pin-vecta@example.invalid'
mkdir -p "$mengine/engine/hotfix"
seq_file() { printf 'echo %s\n' "$@"; }
seq_file a b c d e f > "$mengine/engine/hotfix/m.sh"
seq_file a b c d e f > "$mengine/engine/hotfix/c.sh"
seq_file a b c > "$mengine/engine/hotfix/d.sh"
seq_file k > "$mengine/engine/hotfix/k.sh"
git -C "$mengine" add -A && git -C "$mengine" commit -qm 'B1'
blob_m=$(git -C "$mengine" rev-parse HEAD:engine/hotfix/m.sh)
blob_c=$(git -C "$mengine" rev-parse HEAD:engine/hotfix/c.sh)
blob_d=$(git -C "$mengine" rev-parse HEAD:engine/hotfix/d.sh)
blob_k=$(git -C "$mengine" rev-parse HEAD:engine/hotfix/k.sh)
seq_file TOP a b c d e f > "$mengine/engine/hotfix/m.sh"
seq_file a b ENGINE d e f > "$mengine/engine/hotfix/c.sh"
git -C "$mengine" rm -q engine/hotfix/d.sh
git -C "$mengine" commit -qam 'B2'
mnew=$(git -C "$mengine" rev-parse HEAD)
mnew_m=$(git -C "$mengine" rev-parse HEAD:engine/hotfix/m.sh)

merge_target() { # <name> <rows> : pack copies local-edit the bottom (m) / line 3 (c), d untouched
  local t
  t=$(setup_target "$1")
  printf '%b' "$2" > "$t/.zenoforge/build/overrides.tsv"
  seq_file a b c d e f LOCAL > "$t/.zenoforge/build/pack/scripts/agent/hotfix/m.sh"
  seq_file a b PACK d e f > "$t/.zenoforge/build/pack/scripts/agent/hotfix/c.sh"
  seq_file a b c > "$t/.zenoforge/build/pack/scripts/agent/hotfix/d.sh"
  git -C "$t" add -A && git -C "$t" commit -qm 'fixture: overrides'
  git -C "$t" push -q origin main
  printf '%s\n' "$t"
}
run_merge_pin() { # <name> <target> [args]
  local name="$1" t="$2"; shift 2
  : > "$tmp/$name.calls"; : > "$tmp/$name.scopes"
  PIN_CALLS="$tmp/$name.calls" PIN_SCOPE_CALLS="$tmp/$name.scopes" \
    AGENT_HOME="$(setup_agent "$name")" ZF_ENGINE_SYNC="$tmp/bin/engine-sync" ZF_LOCAL_CLONE="$mengine" \
    bash "$pin_script" "$mnew" "$t" "$@"
}

# clean: pack copy, row and build.json land in one commit; the unchanged row stays; route is PR.
mc_target=$(merge_target mclean "hotfix/m.sh\t$blob_m\nhotfix/k.sh\t$blob_k\n")
set +e; run_merge_pin mclean "$mc_target" --land > "$tmp/mclean.out" 2>&1; mc_status=$?; set -e
((mc_status == 75)) || { cat "$tmp/mclean.out" >&2; fail "clean override merge: expected PR route exit 75, got $mc_status"; }
mc_wt=$(sed -n 's/^pin-vecta: worktree=//p' "$tmp/mclean.out" | tail -1)
grep -Fq "pin-vecta: merged override hotfix/m.sh base=${blob_m:0:12} -> engine=${mnew_m:0:12}" "$tmp/mclean.out" \
  || fail 'clean merge log line missing'
[[ "$(seq_file TOP a b c d e f LOCAL)" == "$(cat "$mc_wt/.zenoforge/build/pack/scripts/agent/hotfix/m.sh")" ]] \
  || fail 'merged pack copy lost the local or the engine edit'
[[ "$(cat "$mc_wt/.zenoforge/build/overrides.tsv")" == "$(printf 'hotfix/m.sh\t%s\nhotfix/k.sh\t%s' "$mnew_m" "$blob_k")" ]] || fail 'row not updated to the new blob'
[[ "$(git -C "$mc_wt" diff --name-only HEAD~1 HEAD | sort)" == "$(printf '%s\n' .zenoforge/build.json .zenoforge/build/overrides.tsv .zenoforge/build/pack/scripts/agent/hotfix/m.sh)" ]] \
  || fail 'pin, row and pack copy are not one commit'
grep -Fq 'pin-vecta: result=pr-open route=PR landed=no' "$tmp/mclean.out" || fail 'overrides.tsv change did not report the PR route as not landed'
ok 'clean override merge lands pack copy and row in the pin commit'

# conflict: refuse, name the file, create no worktree or branch.
mx_target=$(merge_target mconflict "hotfix/c.sh\t$blob_c\n")
set +e; run_merge_pin mconflict "$mx_target" --land > "$tmp/mconflict.out" 2>&1; mx_status=$?; set -e
((mx_status != 0)) || fail 'conflicting override merge was allowed'
grep -Fq 'override hotfix/c.sh: three-way merge conflicts' "$tmp/mconflict.out" || fail 'conflict did not name the file'
[[ -z "$(ls -A "$mx_target/.worktrees" 2>/dev/null)" ]] || fail 'conflict left a worktree behind'
[[ -z "$(git -C "$mx_target" branch --list 'chore/pin-vecta-*')" ]] || fail 'conflict left a branch behind'
! grep -q '^dispatcher:' "$tmp/mconflict.calls" || fail 'conflict still ran the build'
ok 'conflicting override merge stops the pin and writes nothing'

# engine deleted file: refuse, name the file.
md_target=$(merge_target mdeleted "hotfix/d.sh\t$blob_d\n")
set +e; run_merge_pin mdeleted "$md_target" --land > "$tmp/mdeleted.out" 2>&1; md_status=$?; set -e
((md_status != 0)) || fail 'override of an engine-deleted file was allowed'
grep -Fq 'override hotfix/d.sh: the engine' "$tmp/mdeleted.out" || fail 'deleted file was not named'
[[ -z "$(ls -A "$md_target/.worktrees" 2>/dev/null)" ]] || fail 'deleted-file refusal left a worktree behind'
ok 'engine-deleted override file stops the pin'

echo 'pin-vecta.test.sh: PASS'
