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
old_one=$(git -C "$engine_repo" rev-parse HEAD:engine/hotfix/one.sh)
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
printf 'delivery:%s\n' "$*" >> "${PIN_CALLS:?}"
script="$1"
shift
[[ "$script" == */scripts/branch-delivery-preflight.mjs && "$*" == '--mode push --publish-topic' ]]
repo=${script%/scripts/branch-delivery-preflight.mjs}
branch=$(git -C "$repo" symbolic-ref --short HEAD)
git -C "$repo" push -q --set-upstream origin "$branch"
NODE
chmod +x "$tmp/bin/node"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf 'gh:%s\n' "$*" >> "${PIN_CALLS:?}"
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

# A pack-touching pin takes the PR route, but publish preflight still runs. If
# that preflight rejects a config change, --land cannot push or create a PR.
pack_target=$(setup_target pack)
git -C "$pack_target" checkout -q -b product-pack-change
printf 'pack line\n' > "$pack_target/.zenoforge/build/pack/scripts/agent/hotfix/pack-touch.sh"
printf '# pack-touching override table change\n' > "$pack_target/.zenoforge/build/overrides.tsv"
git -C "$pack_target" add .zenoforge/build/pack/scripts/agent/hotfix/pack-touch.sh
git -C "$pack_target" add .zenoforge/build/overrides.tsv
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
if [[ -e "$pack_calls" ]]; then ! grep -q '^gh:' "$pack_calls" || fail 'failed preflight still created a PR'; fi
[[ "$(git --git-dir="$tmp/pack-origin.git" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d '[:space:]')" == 1 ]] \
  || fail 'failed preflight pushed a topic branch'
ok 'pack-touching PR pin always runs publish preflight and refuses publication on failure'

# A passing PR pin goes through Vecta's SHA-bound branch preflight before the
# PR is created. The simulated publisher only pushes to the fixture bare repo.
pr_target=$(setup_target pr)
git -C "$pr_target" checkout -q -b product-change
printf '# existing override row\n' > "$pr_target/.zenoforge/build/overrides.tsv"
git -C "$pr_target" add .zenoforge/build/overrides.tsv
git -C "$pr_target" commit -qm 'fixture: reviewed product change'
pr_agent=$(setup_agent pr)
pr_calls="$tmp/pr.calls"
pr_scopes="$tmp/pr.scopes"
: > "$pr_calls"
: > "$pr_scopes"
if ! run_pin "$pr_calls" "$pr_scopes" "$pr_agent" "$pr_target" --land > "$tmp/pr.out" 2>&1; then
  cat "$tmp/pr.out" >&2
  fail 'passing PR pin did not publish through the PR route'
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
ok 'passing PR pin uses the topic publish preflight and creates a PR'

# An override guard failure still attempts check and preflight, then names every
# stale override and says whether the mapped pack copy contains the changed line.
override_target=$(setup_target override)
printf 'hotfix/one.sh\t%s\n' "$old_one" > "$override_target/.zenoforge/build/overrides.tsv"
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
grep -Fq 'hotfix/one.sh expected=' "$tmp/override.out" || fail 'first override mismatch was not reported'
grep -Fq 'hotfix/two.sh expected=missing actual=' "$tmp/override.out" || fail 'missing override row was not reported'
grep -Fq 'pack copy shares changed lines: yes (1/1 lines; .zenoforge/build/pack/scripts/agent/hotfix/one.sh)' "$tmp/override.out" \
  || fail 'pack copy sharing the changed line was not reported'
grep -Fq 'pack copy shares changed lines: no (0/2 lines; .zenoforge/build/pack/scripts/agent/hotfix/two.sh)' "$tmp/override.out" \
  || fail 'pack copy missing the changed line was not reported'
grep -Fq 'fallback publish-preflight: attempted' "$tmp/override.out" || fail 'preflight was skipped after an override build failure'
ok 'override diagnostics report each path and pack-line overlap'

echo 'pin-vecta.test.sh: PASS'
