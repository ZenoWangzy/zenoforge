#!/usr/bin/env bash
# landed_incident_guards: the registry at a ref when the target repo carries the pack, else the pack's copy (pack outside the repo).
set -euo pipefail
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
source "$p/config.sh"
eval "$(sed -n '/^landed_incident_guards() {/,/^}/p' "$p/land-direct-main.sh")"
git init -q "$t/r"; cd "$t/r"; g() { git -c user.name=t -c user.email=t@t "$@"; }
mkdir -p pk/state; echo '{"incidents":[{"id":"in-repo"}]}' > pk/state/incident-guards.json; g add -A; g commit -qm a
export ZF_PACK_REL=pk ZF_PACK_DIR="$t/pack"; mkdir -p "$t/pack/state"; echo '{"incidents":[{"id":"in-pack"}]}' > "$t/pack/state/incident-guards.json"
[[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-repo ]]
g rm -qr pk; g commit -qm b
[[ $(landed_incident_guards HEAD | jq -r '.incidents[0].id') == in-pack ]]
ZF_PACK_DIR="$t/none"; [[ $(landed_incident_guards HEAD) == '{}' ]]
echo ok
