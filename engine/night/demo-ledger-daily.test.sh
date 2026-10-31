#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
target_root="$tmp/target/.zenoforge"
pack_dir="$tmp/pack"
repo_dir="$tmp/repo"
bin_dir="$tmp/bin"
mkdir -p "$target_root" "$pack_dir" "$repo_dir/ops" "$bin_dir" "$tmp/agent-home"
cat > "$repo_dir/ops/ledger.sh" <<'LEDGER'
printf 'target ledger output\n'
LEDGER
cat > "$repo_dir/ops/pack.sh" <<'LEDGER'
printf 'pack ledger output\n'
LEDGER

cat > "$target_root/night.json" <<'JSON'
{"jobs":{"daily_ledger":{"enabled":true,"ssh_host":"target-host","script_path":"ops/ledger.sh","log_name":"ledger.log"}}}
JSON
jq '.jobs.daily_ledger.ssh_host = "pack-host" | .jobs.daily_ledger.script_path = "ops/pack.sh" | .jobs.daily_ledger.log_name = "pack.log"' \
  "$target_root/night.json" > "$pack_dir/night.json"

cat > "$bin_dir/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_SSH_CALLS"
cat > "$TEST_REMOTE_INPUT"
bash -s < "$TEST_REMOTE_INPUT"
exit "${TEST_SSH_STATUS:-0}"
SSH
chmod +x "$bin_dir/ssh"

export TEST_SSH_CALLS="$tmp/ssh-calls" TEST_REMOTE_INPUT="$tmp/remote-input"
ZF_CONFIG_ROOT="$target_root" ZF_PACK_DIR="$pack_dir" ZF_REPO_DIR="$repo_dir" \
  AGENT_HOME="$tmp/agent-home" PATH="$bin_dir:$PATH" bash "$script_dir/demo-ledger-daily.sh" > "$tmp/output"
grep -Fq 'target-host' "$TEST_SSH_CALLS"
grep -Fq "printf 'target ledger output\\n'" "$TEST_REMOTE_INPUT"
! grep -Fq 'pack ledger output' "$TEST_REMOTE_INPUT"
grep -Fq 'target ledger output' "$tmp/agent-home/night/ledger.log"
! grep -Fq 'pack ledger output' "$tmp/agent-home/night/ledger.log"

set +e
skip_output="$(ZF_CONFIG_ROOT="$tmp/empty/.zenoforge" ZF_PACK_DIR='' ZF_REPO_DIR="$repo_dir" \
  AGENT_HOME="$tmp/agent-home" PATH="$bin_dir:$PATH" bash "$script_dir/demo-ledger-daily.sh" 2>&1)"
skip_status=$?
set -e
[[ "$skip_status" == 0 ]]
grep -Fq 'skip: daily ledger monitor is not configured' <<< "$skip_output"

mkdir -p "$tmp/invalid/.zenoforge"
cat > "$tmp/invalid/.zenoforge/night.json" <<'JSON'
{"jobs":{"daily_ledger":{"enabled":true,"ssh_host":"target-host","script_path":"ops/../secret.sh","log_name":"ledger.log"}}}
JSON
set +e
invalid_output="$(ZF_CONFIG_ROOT="$tmp/invalid/.zenoforge" ZF_PACK_DIR='' ZF_REPO_DIR="$repo_dir" \
  AGENT_HOME="$tmp/agent-home" PATH="$bin_dir:$PATH" bash "$script_dir/demo-ledger-daily.sh" 2>&1)"
invalid_status=$?
set -e
[[ "$invalid_status" == 2 ]]
grep -Fq 'FAIL: invalid daily ledger monitor configuration' <<< "$invalid_output"

echo 'ok - daily ledger monitor uses the target configuration override and skips when unset'
