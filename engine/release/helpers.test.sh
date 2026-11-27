#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-runner-helpers.XXXXXX")"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected <$2>, got <$1>"; }

repo="$tmp/repo"
config="$repo/.zenoforge/release.json"
mkdir -p "$repo/hooks" "$repo/migrations/meta" "$(dirname -- "$config")"
mkdir -p "$repo/src"
cat > "$repo/hooks/rollback.sh" <<'SH'
#!/usr/bin/env bash
printf 'synthetic rollback\n'
SH
chmod +x "$repo/hooks/rollback.sh"
cat > "$config" <<'JSON'
{"release":{"deployHost":"fixture","deploymentRepository":"fixture/repo","lossProbeImageName":"sample-image","lossProbeHookPath":"src/hook.py","lossProbeService":"sample-probe.service","lossProbeContainerFilter":"name=sample-container","lossProbeLabel":"sample image","rollbackLabel":"sample rollback","rollbackScriptPath":"hooks/rollback.sh","rollbackHookPath":"src/hook.py","rollbackSkillPath":"src/skill.md","rollbackKnownDirectory":"/fixture/known","rollbackRemoteRoot":"/fixture/rollback","rollbackMainReference":"HEAD","driftHookPath":"src/hook.py","driftSkillPath":"src/skill.md"},"postDeploy":{"marker":"-- sample:post","ledger":"audit.applied"}}
JSON
printf 'hook-v1\n' > "$repo/src/hook.py"
printf 'skill-v1\n' > "$repo/src/skill.md"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture
git -C "$repo" add src hooks
git -C "$repo" commit -qm fixture
sha="$(git -C "$repo" rev-parse HEAD)"
hook_hash="$(md5sum "$repo/src/hook.py" | cut -c1-32)"
skill_hash="$(md5sum "$repo/src/skill.md" | cut -c1-32)"

export ZF_ENGINE_DIR="$root/engine" ZF_REPO_DIR="$repo" ZF_CONFIG_ROOT="$repo/.zenoforge" ZF_PACK_DIR=""
source "$root/engine/release/runner.sh"
RELEASE_CONFIG="$config"
DEPLOY_HOST="$(release_config_value deployHost)"
declare -F release_run_loss_probe >/dev/null || fail 'release loss probe helper is missing'
declare -F release_run_rollback >/dev/null || fail 'release rollback helper is missing'
declare -F release_post_deploy_sql >/dev/null || fail 'release post-deploy helper is missing'

mkdir -p "$tmp/engine" "$tmp/bin"
cat > "$tmp/engine/production-deployment-read.sh" <<'SH'
#!/usr/bin/env bash
printf '[{"payload":{"images":{"sample-image":true},"image_shas":{"sample-image":"%s"}}}]\n' "$FIXTURE_DEPLOY_SHA"
SH
cat > "$tmp/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'active\n'
SH
cat > "$tmp/bin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
cat > "$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
request="$*"
cat >/dev/null
printf '%s\n' "$request" >> "$SSH_TRACE"
case "$request" in
  *CHECK=1*)
    printf 'KNOWN hook %s\nKNOWN skill %s\nOK sample-container hook=%s skill=%s\n' \
      "$SAMPLE_HOOK_HASH" "$SAMPLE_SKILL_HASH" "$SAMPLE_HOOK_HASH" "$SAMPLE_SKILL_HASH"
    ;;
  *'cat >'*|*'mkdir -p'*|*unlink*) ;;
  *) printf '%s\n' "$FIXTURE_DEPLOY_SHA" ;;
esac
SH
chmod +x "$tmp/engine/production-deployment-read.sh" "$tmp/bin/systemctl" "$tmp/bin/timeout" "$tmp/bin/ssh"
export ZF_ENGINE_DIR="$tmp/engine" REPO_DIR="$repo" FIXTURE_DEPLOY_SHA="$sha" SAMPLE_HOOK_HASH="$hook_hash" SAMPLE_SKILL_HASH="$skill_hash"
export SSH_TRACE="$tmp/ssh.trace" PATH="$tmp/bin:$PATH"
rollback_output="KNOWN hook $hook_hash
KNOWN skill $skill_hash
OK sample-container hook=$hook_hash skill=$skill_hash"
assert_eq "$(release_run_loss_probe)" "OK sample-container hook=$hook_hash skill=$skill_hash" 'loss probe output'
grep -q 'fixture' "$SSH_TRACE" || fail 'release helper did not use configured deploy host'
assert_eq "$(release_run_rollback "$sha" check "$sha" "$sha")" "$rollback_output" 'rollback check output'
jq '.release.rollbackScriptPath = "../hooks/rollback.sh"' "$config" > "$config.next"
mv "$config.next" "$config"
if output="$(release_run_rollback "$sha" check "$sha" "$sha" 2>&1)"; then fail 'escaping rollback script path unexpectedly succeeded'; fi
[[ "$output" == *'invalid rollback source path'* ]] || fail "invalid script path was not refused: $output"
jq 'del(.release.rollbackScriptPath)' "$config" > "$config.next"
mv "$config.next" "$config"
if output="$(release_run_rollback "$sha" check "$sha" "$sha" 2>&1)"; then fail 'missing rollback script unexpectedly succeeded'; fi
[[ "$output" == *'.release.rollbackScriptPath'* ]] || fail "missing rollback config error did not name its key: $output"
jq '.release.rollbackScriptPath = "hooks/rollback.sh"' "$config" > "$config.next"
mv "$config.next" "$config"

printf '%s\n' '{"entries":[{"tag":"0001_init"}]}' > "$repo/migrations/meta/_journal.json"
printf '%s\n' '-- sample:post' 'CREATE TABLE sample (id integer);' > "$repo/migrations/0001_init.sql"
git -C "$repo" add migrations
git -C "$repo" commit -qm fixture
sha="$(git -C "$repo" rev-parse HEAD)"
export ZF_ENGINE_DIR="$root/engine"
sql="$(release_post_deploy_sql "$sha")"
[[ "$sql" == *'audit.applied'* ]] || fail 'post-deploy SQL did not use configured ledger'
[[ "$sql" == *'post-deploy-migration: applying tag=0001_init'* ]] || fail 'post-deploy SQL did not include the tagged migration'
[[ "$sql" == *'CREATE TABLE sample (id integer);'* ]] || fail 'post-deploy SQL omitted the migration'

printf 'PASS: loss probe, rollback staging, and post-deploy helpers use configured release inputs\n'
