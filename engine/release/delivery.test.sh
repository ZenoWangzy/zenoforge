#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-runner-delivery.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected <$2>, got <$1>"; }

repo="$tmp/repo"
mkdir -p "$repo/.zenoforge"
export ZF_ENGINE_DIR="$root/engine" ZF_REPO_DIR="$repo" ZF_CONFIG_ROOT="$repo/.zenoforge" ZF_PACK_DIR=""
cat > "$repo/.zenoforge/release.json" <<'JSON'
{"release":{"deployHost":"deploy.example.invalid","imageRegistry":"registry.example.invalid","infraWorkflowRepository":"example/build-tools","infraBuildWorkflow":"build-images.yml","infraWorkflowRunUrl":"https://build.example.invalid/runs","productionUrl":"https://service.example.invalid"}}
JSON
source "$root/engine/release/runner.sh"
release_runner_load_config
declare -F remote_up >/dev/null || fail 'release delivery helper is missing'

REMOTE_TRACE="$tmp/ssh.trace"
SLEEP_TRACE="$tmp/sleep.trace"
REMOTE_CALLS=0
SSH_FIRST_RC=0
SSH_SECOND_RC=0
ssh() {
  REMOTE_CALLS=$((REMOTE_CALLS + 1))
  printf '%s\n' "$@" >> "$REMOTE_TRACE"
  if ((REMOTE_CALLS == 1)); then return "$SSH_FIRST_RC"; fi
  return "$SSH_SECOND_RC"
}
sleep() { printf '%s\n' "$1" >> "$SLEEP_TRACE"; }

: > "$REMOTE_TRACE"
: > "$SLEEP_TRACE"
remote_up 'compose up'
assert_eq "$REMOTE_CALLS" 1 'successful command call count'
expected=$'-o\nConnectTimeout=15\n-o\nServerAliveInterval=15\n-o\nServerAliveCountMax=4\ndeploy.example.invalid\ncompose up'
assert_eq "$(cat "$REMOTE_TRACE")" "$expected" 'remote command arguments'

: > "$REMOTE_TRACE"
: > "$SLEEP_TRACE"
REMOTE_CALLS=0 SSH_FIRST_RC=255 SSH_SECOND_RC=0 RELEASE_SSH_RETRY_WAIT=1 DEPLOY_TRANSPORT_DROP=0
remote_up 'compose up' 2> "$tmp/retry.err"
assert_eq "$REMOTE_CALLS" 2 'retry call count'
assert_eq "$(cat "$SLEEP_TRACE")" 1 'retry wait'
[[ "$DEPLOY_TRANSPORT_DROP" == 0 ]] || fail 'successful retry was recorded as a repeated drop'
grep -Fq 'retrying once' "$tmp/retry.err" || fail 'retry message was missing'

: > "$REMOTE_TRACE"
: > "$SLEEP_TRACE"
REMOTE_CALLS=0 SSH_FIRST_RC=255 SSH_SECOND_RC=255 DEPLOY_TRANSPORT_DROP=0
if remote_up 'compose up' 2> "$tmp/repeated-drop.err"; then fail 'repeated transport drop unexpectedly succeeded'; else rc=$?; fi
assert_eq "$rc" 255 'repeated transport drop status'
assert_eq "$DEPLOY_TRANSPORT_DROP" 1 'repeated transport drop flag'
assert_eq "$REMOTE_CALLS" 2 'repeated transport drop call count'

: > "$REMOTE_TRACE"
: > "$SLEEP_TRACE"
REMOTE_CALLS=0 SSH_FIRST_RC=42 SSH_SECOND_RC=0 DEPLOY_TRANSPORT_DROP=0
if remote_up 'compose up'; then fail 'non-transport command failure unexpectedly succeeded'; else rc=$?; fi
assert_eq "$rc" 42 'non-transport failure status'
assert_eq "$REMOTE_CALLS" 1 'non-transport failure call count'
[[ ! -s "$SLEEP_TRACE" ]] || fail 'non-transport failure retried'

printf 'PASS: delivery uses the configured host and retries one transport drop\n'
