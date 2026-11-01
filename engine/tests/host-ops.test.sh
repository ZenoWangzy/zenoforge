#!/usr/bin/env bash
set -euo pipefail
if [[ $# == 0 ]]; then
  for flavor in shell node python sites; do bash "$0" "$flavor"; done
  exit
fi
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "$repo/.git/host-ops-test.XXXXXX")"
export HOME="$scratch/home" AGENT_HOME="$scratch/agent" ZF_ENGINE_DIR="$scratch/engine"
mkdir -p "$HOME" "$AGENT_HOME/host-ops/scripts/agent" "$ZF_ENGINE_DIR" "$scratch/custom/scripts/agent"
printf engine > "$ZF_ENGINE_DIR/tool"
printf host > "$AGENT_HOME/host-ops/scripts/agent/tool"
printf custom > "$scratch/custom/scripts/agent/tool"
unset TOOL_OVERRIDE ZF_HOME
export ZF_HOST_OPS_DIR="$scratch/custom"
case "$1" in
  sites)
    check_site() { grep -Fq -- "$2" "$repo/engine/$1" || { printf 'missing host-ops resolution: %s\n' "$1" >&2; exit 1; }; }
    check_site run-tick.sh 'zf_host_ops_dir)/scripts/agent/systemd'
    check_site supervise-pipeline.sh 'zf_host_ops_file scripts/agent/supervise-browser-check.sh'
    check_site run-tick.sh 'zf_host_ops_file scripts/agent/check-host-daemons.py'
    check_site land-direct-main.sh 'zf_host_ops_file scripts/agent/check-host-daemons.py'
    check_site lib.d/codex-budget.sh 'zf_host_ops_file scripts/agent/network-traffic.py'
    check_site lib.d/gitnexus.sh 'zf_host_ops_file "scripts/agent/gitnexus-'
    check_site mac-autopilot/scheduler.d/self-check.sh 'zf_host_ops_file "scripts/agent/'
    check_site mac-autopilot/node_health.py 'or zf_host_ops_file('
    printf 'host-ops surviving sites: PASS\n'
    exit
    ;;
  shell)
    source "$repo/engine/config.sh"
    resolve() { printf '%s\n' "${TOOL_OVERRIDE:-$(zf_host_ops_file scripts/agent/tool)}"; }
    resolve_built_alias() { zf_host_ops_file "engine/${ALIAS_TOOL:-tool}" "$ZF_ENGINE_DIR/${ALIAS_TOOL:-tool}"; }
    ;;
  node)
    resolve() { REPO="$repo" node --input-type=module -e 'const {zfHostOpsFile} = await import(process.env.REPO + "/engine/pack-dir.mjs"); console.log(process.env.TOOL_OVERRIDE || zfHostOpsFile("scripts/agent/tool"));'; }
    resolve_built_alias() { REPO="$repo" node --input-type=module -e 'const {zfHostOpsFile} = await import(process.env.REPO + "/engine/pack-dir.mjs"); console.log(process.env.TOOL_OVERRIDE || zfHostOpsFile(`engine/${process.env.ALIAS_TOOL || "tool"}`));'; }
    ;;
  python)
    resolve() { PYTHONPATH="$repo/engine/mac-autopilot" python3 -B -c 'import os; from config_paths import zf_host_ops_file; print(os.environ.get("TOOL_OVERRIDE") or zf_host_ops_file("scripts/agent/tool"))'; }
    resolve_built_alias() { PYTHONPATH="$repo/engine/mac-autopilot" python3 -B -c 'import os; from config_paths import zf_host_ops_file; name=os.environ.get("ALIAS_TOOL", "tool"); print(os.environ.get("TOOL_OVERRIDE") or zf_host_ops_file("engine/" + name))'; }
    ;;
  *) exit 2 ;;
esac
check() { [[ "$1" == "$2" ]] || { printf 'expected %s, got %s\n' "$2" "$1" >&2; exit 1; }; }
if [[ "$1" == shell ]]; then check "$(zf_host_ops_dir)" "$scratch/custom"; fi
check "$(resolve)" "$scratch/custom/scripts/agent/tool"
check "$(resolve_built_alias)" "$ZF_ENGINE_DIR/tool"
printf engine > "$scratch/custom/scripts/agent/tool"
check "$(resolve_built_alias)" "$scratch/custom/scripts/agent/tool"
printf moved > "$scratch/custom/scripts/agent/moved-tool"
ALIAS_TOOL=moved-tool check "$(ALIAS_TOOL=moved-tool resolve_built_alias)" "$scratch/custom/scripts/agent/moved-tool"
printf engine > "$ZF_ENGINE_DIR/tool"
export ZF_HOST_OPS_DIR="$scratch/missing"
if [[ "$1" == shell ]]; then check "$(zf_host_ops_dir)" "$scratch/missing"; fi
check "$(resolve)" "$ZF_ENGINE_DIR/tool"
unset ZF_HOST_OPS_DIR
if [[ "$1" == shell ]]; then check "$(zf_host_ops_dir)" "$AGENT_HOME/host-ops"; fi
check "$(resolve)" "$AGENT_HOME/host-ops/scripts/agent/tool"
export TOOL_OVERRIDE="$scratch/override"
check "$(resolve)" "$scratch/override"
printf 'host-ops %s: PASS\n' "$1"
