#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/repo/engine/state" "$tmp/home"
cp "$REPO_DIR/engine/check-rulings.sh" "$REPO_DIR/engine/test-bootstrap-check.sh" \
  "$REPO_DIR/engine/test-env.sh" "$REPO_DIR/engine/scheduling-policy.mjs" \
  "$REPO_DIR/engine/lesson-guard-schema.mjs" "$tmp/repo/engine/"
# scheduling-policy.mjs verifies the contract against minimal fixture copies; AGENT_HOME points
# away from any live ledger so the ledger-conformance part stays hermetic.
printf '{"rulings": []}\n' > "$tmp/repo/engine/state/rulings.json"
printf '{"schema": "zf-scheduling-policy/v1", "version": 1, "state_machine": {"executed_by": [], "states": {}, "initial_states": [], "escalation_targets": [], "transitions": {}}, "areas": {}}\n' \
  > "$tmp/repo/engine/state/scheduling-policy.json"
# Static mode also validates the problem-register schema; one pre-schema record keeps the fixture green.
printf '{"incidents":[{"id":"fixture-history","date":"2026-10-01"}]}\n' \
  > "$tmp/repo/engine/state/incident-guards.json"
# Model-source behaviour has its own real-lib integration suite; isolate suite discovery here.
printf 'model_policy_scan_sources() { return 0; }\n' > "$tmp/repo/engine/lib.sh"
printf 'set -euo pipefail\nsource "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"\n' \
  > "$tmp/repo/engine/valid.test.sh"
check() {
  ZF_REPO_DIR="$tmp/repo" AGENT_HOME="$tmp/home" AGENT_RULINGS_MODE="$1" bash "$tmp/repo/engine/check-rulings.sh" "${@:2}"
}
output="$(check static)"
grep -qx 'check-rulings: static checks passed' <<< "$output"
printf 'echo missing-bootstrap\n' > "$tmp/repo/engine/invalid.test.sh"
status=0
output="$(check static 2>&1)" || status=$?
[[ "$status" == 2 ]]
grep -qF 'test suite must start with set -euo pipefail and source test-env.sh' <<< "$output"
# An explicitly selected source suite does not evaluate unrelated suites.
output="$(check source "$tmp/repo/engine/valid.test.sh")"
grep -qx 'check-rulings: source checks passed' <<< "$output"
output="$(check source --sources-only)"
grep -qx 'check-rulings: source checks passed' <<< "$output"
printf 'check-rulings.test.sh: PASS\n'
