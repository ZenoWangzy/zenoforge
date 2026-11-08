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
eval "$(sed -n '/^land_state_json_attribute_lines() {/,/^}/p' "$p/land-direct-main.sh")"
git init -q "$t/r"; cd "$t/r"; g() { git -c user.name=t -c user.email=t@t "$@"; }
mkdir -p pk/state; echo '{"incidents":[{"id":"in-repo"}]}' > pk/state/incident-guards.json; g add -A; g commit -qm a
export ZF_PACK_REL=pk ZF_PACK_DIR="$t/pack"; mkdir -p "$t/pack/state"; echo '{"incidents":[{"id":"in-pack"}]}' > "$t/pack/state/incident-guards.json"
land_script_dir="$p"
INCIDENT_GUARDS_REPO_PATH=pk/state/incident-guards.json INCIDENT_GUARDS_FRAGMENT_DIR=pk/state/incident-guards.d
[[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-repo ]]
g rm -qr pk; g commit -qm b
[[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-pack ]]
ZF_PACK_DIR="$t/none"; [[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-engine ]]
mkdir -p .zenoforge/state
echo '{"incidents":[{"id":"in-config"}]}' > .zenoforge/state/incident-guards.json
g add .zenoforge/state/incident-guards.json; g commit -qm c
INCIDENT_GUARDS_REPO_PATH=.zenoforge/state/incident-guards.json INCIDENT_GUARDS_FRAGMENT_DIR=.zenoforge/state/incident-guards.d
[[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-config ]]
# A guard that exists only as a fragment at the base counts as landed; one added after the base does not.
mkdir -p .zenoforge/state/incident-guards.d
echo '{"incidents":[{"id":"in-fragment"}]}' > .zenoforge/state/incident-guards.d/in-fragment.json
g add .zenoforge/state/incident-guards.d; g commit -qm d
[[ $(landed_incident_guards HEAD | jq -r '[.incidents[].id] | join(",")') == in-config,in-fragment ]]
[[ $(landed_incident_guards HEAD~1 | jq -r '[.incidents[].id] | join(",")') == in-config ]]
# Landing renumbers a V id in the added record: a guard added as a fragment is found and rewritten in its own file.
eval "$(sed -n '/^land_is_incident_guards_path() {/p' "$p/land-direct-main.sh")"
eval "$(sed -n '/^added_guard_id_for_lesson_occurrence() {/,/^}/p' "$p/land-direct-main.sh")"
eval "$(sed -n '/^replace_added_lesson_occurrence() {/,/^}/p' "$p/land-direct-main.sh")"
base=$(g rev-parse HEAD)
echo '{"incidents":[{"id":"fresh-guard","lesson_id":"V900"}]}' > .zenoforge/state/incident-guards.d/fresh-guard.json
g add .zenoforge/state/incident-guards.d; g commit -qm e
[[ $(added_guard_id_for_lesson_occurrence "$base" 900 1) == fresh-guard ]]
replace_added_lesson_occurrence "$base" .zenoforge/state/incident-guards.d/fresh-guard.json 900 901 1
[[ $(jq -r '.incidents[0].lesson_id' .zenoforge/state/incident-guards.d/fresh-guard.json) == V901 ]]
ZF_PACK_REL=scripts/agent
[[ "$(land_state_json_attribute_lines)" == $'scripts/agent/state/*.json merge=statejson\n.zenoforge/state/*.json merge=statejson' ]]
echo ok
