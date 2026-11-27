#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-runner-drift-filter.XXXXXX")"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected <$2>, got <$1>"; }

repo="$tmp/repo"
config="$repo/.zenoforge/release.json"
mkdir -p "$(dirname -- "$config")" "$repo/src"
export ZF_ENGINE_DIR="$root/engine" ZF_REPO_DIR="$repo" ZF_CONFIG_ROOT="$repo/.zenoforge" ZF_PACK_DIR=""
cat > "$config" <<'JSON'
{"release":{"deployHost":"fixture","driftHookPath":"src/hook.py","driftSkillPath":"src/skill.md"}}
JSON
printf 'hook-v1\n' > "$repo/src/hook.py"
printf 'skill-v1\n' > "$repo/src/skill.md"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture
git -C "$repo" add src
git -C "$repo" commit -qm baseline
old_sha="$(git -C "$repo" rev-parse HEAD)"
hook_hash="$(md5sum "$repo/src/hook.py" | cut -c1-32)"
skill_hash="$(md5sum "$repo/src/skill.md" | cut -c1-32)"
printf 'hook-v2\n' > "$repo/src/hook.py"
git -C "$repo" add src/hook.py
git -C "$repo" commit -qm intermediate
mid_sha="$(git -C "$repo" rev-parse HEAD)"
mid_hook_hash="$(md5sum "$repo/src/hook.py" | cut -c1-32)"
printf 'hook-v1\n' > "$repo/src/hook.py"
git -C "$repo" add src/hook.py
git -C "$repo" commit -qm current
new_sha="$(git -C "$repo" rev-parse HEAD)"

source "$root/engine/release/runner.sh"
RELEASE_CONFIG="$config"
DEPLOY_HOST="$(release_config_value deployHost)"
declare -F release_filter_drift >/dev/null || fail 'release drift filter is missing'

SSH_TRACE="$tmp/ssh.trace"
ssh() {
  printf '%s\n' "$*" >> "$SSH_TRACE"
  printf 'IMAGE_REVISION app-live-known %s\n' "$mid_sha"
}
input="$(printf 'KNOWN skill %s\nBASELINE app-baseline %s %s\nDRIFT app-baseline hook=%s skill=%s chain=a/b\nDRIFT app-image-known hook=%s skill=%s chain=a/b\nDRIFT app-live-known hook=%s skill=%s chain=a/b\nDRIFT app-unknown-pair hook=%s skill=%s chain=a/b' \
  "$skill_hash" '33333333333333333333333333333333' '44444444444444444444444444444444' \
  '33333333333333333333333333333333' '44444444444444444444444444444444' \
  "$hook_hash" "$skill_hash" "$mid_hook_hash" "$skill_hash" \
  '66666666666666666666666666666666' '77777777777777777777777777777777')"
actual="$(release_filter_drift "$repo" "$old_sha" "$new_sha" "$new_sha" <<< "$input")"
expected='DRIFT app-unknown-pair hook=66666666666666666666666666666666 skill=77777777777777777777777777777777 chain=a/b'
assert_eq "$actual" "$expected" 'filtered drift output'
grep -q 'fixture' "$SSH_TRACE" || fail 'revision probe did not use configured deploy host'

metadata='KNOWN skill 12345678901234567890123456789012'
no_results="$(release_filter_drift "$repo" "$old_sha" "$new_sha" "$new_sha" <<< "$metadata")"
assert_eq "$no_results" "$metadata
DRIFT CHECK=1 returned no container results" 'missing container result output'

printf 'PASS: drift filter keeps only unaccepted rows and uses configured release paths\n'
