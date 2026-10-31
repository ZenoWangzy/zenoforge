#!/usr/bin/env bash
# landed_incident_guards: target config wins, then the pack, then the engine default.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/engine/state"
printf '{"incidents":[{"id":"in-engine"}]}\n' > "$t/engine/state/incident-guards.json"
export ZF_REPO_DIR="$t/r" ZF_ENGINE_DIR="$t/engine" ZF_CONFIG_ROOT="$t/r/.zenoforge"
source "$p/config.sh"
eval "$(sed -n '/^landed_incident_guards() {/,/^}/p' "$p/land-direct-main.sh")"
git init -q "$t/r"; cd "$t/r"; g() { git -c user.name=t -c user.email=t@t "$@"; }
mkdir -p pk/state; echo '{"incidents":[{"id":"in-repo"}]}' > pk/state/incident-guards.json; g add -A; g commit -qm a
export ZF_PACK_REL=pk ZF_PACK_DIR="$t/pack"; mkdir -p "$t/pack/state"; echo '{"incidents":[{"id":"in-pack"}]}' > "$t/pack/state/incident-guards.json"
INCIDENT_GUARDS_REPO_PATH=pk/state/incident-guards.json
[[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-repo ]]
g rm -qr pk; g commit -qm b
[[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-pack ]]
ZF_PACK_DIR="$t/none"; [[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-engine ]]
mkdir -p .zenoforge/state
echo '{"incidents":[{"id":"in-config"}]}' > .zenoforge/state/incident-guards.json
g add .zenoforge/state/incident-guards.json; g commit -qm c
INCIDENT_GUARDS_REPO_PATH=.zenoforge/state/incident-guards.json
[[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-config ]]
echo ok
