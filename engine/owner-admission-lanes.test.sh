#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
src="$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
eval "$(sed -n '/^hand_agent_process_count() {/,/^}/p' "$src")"
root="$AGENT_HOME/worktrees/"
mkdir -p "$AGENT_HOME/night/hand-registry"
hand_codex_worktrees() {
  printf '%s\n' "${root}hand-work" "${root}hand-production" "${root}issue-123" \
    "${root}issue-123-other" "${root}unknown"
}
hand_zcode_agents() { printf '55\thand-zcode\n'; }
hand_codex_pid_matches() { [[ "$1:$2" == "42:${root}hand-production" ]]; }
jq -n --arg wt "${root}hand-production" '{role:"production",pid:42,worktree:$wt}' \
  > "$AGENT_HOME/night/hand-registry/production.json"
[[ "$(hand_agent_process_count "$root")" == 6 ]]
actual="$(hand_agent_process_count "$root" ordinary-hand)"
[[ "$actual" == 4 ]] || { echo "FAIL: independent pipeline/production lanes charged to hand cap: $actual != 4" >&2; exit 1; }
# A stale production registry never frees a slot occupied by an unknown owner.
jq '.pid=99' "$AGENT_HOME/night/hand-registry/production.json" > "$AGENT_HOME/stale"
mv "$AGENT_HOME/stale" "$AGENT_HOME/night/hand-registry/production.json"
[[ "$(hand_agent_process_count "$root" ordinary-hand)" == 5 ]]
# Only direct issue-N pipeline roots are excluded; similarly named hand roots count.
echo 'ok - production and pipeline lanes excluded from the ordinary hand cap; stale identity never frees slot'
