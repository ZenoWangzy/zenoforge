#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../config.sh"
night_config="$(zf_config_file night.json || true)"
if [[ -z "$night_config" ]] || ! jq -e '.jobs.daily_ledger.enabled == true' "$night_config" >/dev/null 2>&1; then
  echo 'skip: daily ledger monitor is not configured'
  exit 0
fi

ssh_host="$(jq -r '.jobs.daily_ledger.ssh_host // empty' "$night_config")"
script_path="$(jq -r '.jobs.daily_ledger.script_path // empty' "$night_config")"
log_name="$(jq -r '.jobs.daily_ledger.log_name // empty' "$night_config")"
if [[ ! "$ssh_host" =~ ^[A-Za-z0-9_.-]+$ || ! "$script_path" =~ ^[A-Za-z0-9._/-]+$ \
  || "$script_path" == /* || "$script_path" == */ || "$script_path" == .. || "$script_path" == */.. \
  || "$script_path" == . || "$script_path" == */. || ! "$log_name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo 'FAIL: invalid daily ledger monitor configuration' >&2
  exit 2
fi
case "/$script_path/" in
  */../*|*/./*)
    echo 'FAIL: invalid daily ledger monitor configuration' >&2
    exit 2
    ;;
esac

repo_dir="$ZF_REPO_DIR"
source_file="$repo_dir/$script_path"
if [[ ! -r "$source_file" ]]; then
  echo 'skip: daily ledger monitor script is unavailable on the target host' >&2
  exit 0
fi

agent_home="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
night_dir="${ZF_NIGHT_DIR:-$agent_home/night}"
mkdir -p -- "$night_dir" || exit 1
log_file="$night_dir/$log_name"
tmp_file="$(mktemp "${log_file}.XXXXXX")" || exit 1

status=0
ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 \
  "$ssh_host" 'bash -s' <"$source_file" >"$tmp_file" 2>&1 || status=$?

printf 'at=%s exit=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" >>"$tmp_file"
mv -f -- "$tmp_file" "$log_file"
cat "$log_file"
exit "$status"
