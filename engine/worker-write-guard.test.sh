#!/usr/bin/env bash
# The 2026-11-07 incident-guard write (unit issue-5573): a dispatched implement
# worker appended its lesson row to the deployment checkout's
# .zenoforge/state/incident-guards.json through a node helper script whose target
# path appeared only inside the script body; the uncommitted row stalled every
# engine pin until a person cleared it. Red before the fix: the write succeeded.
# Green after: the node and python preloads refuse it, the
# unit's own worktree and the supervisor scratch stay writable, and the incident
# rule points the lesson entry at the unit's own checkout registry.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GUARD_ROOT="$TMPDIR/deployment-checkout"
WORKTREE="$TMPDIR/wt-issue-unit"
SUP="$GUARD_ROOT/.scratch-supervisor"
REGISTRY="$GUARD_ROOT/.zenoforge/state/incident-guards.json"
mkdir -p "$GUARD_ROOT/.zenoforge/state" "$SUP" "$WORKTREE"
printf '{"incidents":[]}' > "$REGISTRY"
git -C "$GUARD_ROOT" init -q -b main
git -C "$GUARD_ROOT" config user.name test
git -C "$GUARD_ROOT" config user.email test@example.invalid
printf 'seed\n' > "$GUARD_ROOT/README"
git -C "$GUARD_ROOT" add README .zenoforge/state/incident-guards.json
git -C "$GUARD_ROOT" commit -qm seed

# The scheduler side: worker_write_guard_env hands dispatch the guard words.
source "$SCRIPT_DIR/mac-autopilot/scheduler.d/worker-scope.sh"
ROOT="$GUARD_ROOT" SUP="$SUP" ZF_ENGINE_DIR="$SCRIPT_DIR"
mapfile -t guard_env < <(worker_write_guard_env "$WORKTREE")

refused() { # description, then command...
  local desc="$1" out rc=0
  shift
  set +e
  out=$(env "${guard_env[@]}" "$@" 2>&1)
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "not ok - $desc: write succeeded" >&2; exit 1; }
  [[ "$out" == *'worker write guard: refusing write into the deployment checkout'* ]] \
    || { echo "not ok - $desc: refusal is not loud: $out" >&2; exit 1; }
  echo "ok - $desc"
}

allowed() { # description, then command already carrying its own guard env...
  local desc="$1" rc=0
  shift
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || { echo "not ok - $desc" >&2; exit 1; }
  echo "ok - $desc"
}

# The exact incident shape: a heredoc script whose registry path never appears on
# the command line, appending a lesson row to the deployment checkout registry.
incident_node_write() {
  node --input-type=module <<'NODE'
import fs from 'node:fs';
const registryPath = process.env.ZF_TEST_REGISTRY;
const registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
registry.incidents.push({ id: 'issue-row-unbounded-write' });
fs.writeFileSync(registryPath, JSON.stringify(registry, null, 2));
console.log('appended');
NODE
}
refused "node heredoc script cannot append the lesson row" \
  env ZF_TEST_REGISTRY="$REGISTRY" bash -c "$(declare -f incident_node_write); incident_node_write"
[[ "$(cat "$REGISTRY")" == '{"incidents":[]}' ]] \
  || { echo "not ok - refused node write still changed the registry" >&2; exit 1; }
echo "ok - refused node write left the registry bytes unchanged"

refused "node -e writeFileSync into the deployment checkout is refused" \
  node -e 'require("fs").writeFileSync(process.argv[1], "x")' "$REGISTRY"
refused "node createWriteStream into the deployment checkout is refused" \
  node -e 'require("fs").createWriteStream(process.argv[1]).end("x")' "$GUARD_ROOT/stream.txt"
refused "node fs/promises writeFile into the deployment checkout is refused" \
  node -e 'require("fs/promises").writeFile(process.argv[1], "x")' "$GUARD_ROOT/promise.txt"
refused "python open() for append into the deployment checkout is refused" \
  python3 -c 'import sys; open(sys.argv[1], "a")' "$REGISTRY"

allowed "worker reads from the deployment checkout still work" \
  env "${guard_env[@]}" node -e 'process.stdout.write(require("fs").readFileSync(process.argv[1], "utf8"))' "$REGISTRY"
allowed "node writes inside the unit worktree still work" \
  env "${guard_env[@]}" node -e 'require("fs").writeFileSync(process.argv[1], "ok")' "$WORKTREE/row.json"
allowed "python writes inside the unit worktree still work" \
  env "${guard_env[@]}" python3 -c 'import sys; open(sys.argv[1], "w").write("ok")' "$WORKTREE/py.txt"
allowed "worker report writes into the supervisor scratch still work" \
  env "${guard_env[@]}" sh -c 'printf "report" > "$1"' _ "$SUP/impl-unit.md"
allowed "worktree git commands still work" \
  git -C "$WORKTREE" init -q

[[ " ${guard_env[*]} " == *" ZF_WORKER_WRITE_GUARD_ROOT=$GUARD_ROOT "* ]] \
  || { echo "not ok - guard env omits the deployment checkout root" >&2; exit 1; }
[[ " ${guard_env[*]} " == *" ZF_WORKER_WRITE_GUARD_ALLOW=$SUP "* ]] \
  || { echo "not ok - guard env omits the supervisor scratch allow root" >&2; exit 1; }
echo "ok - worker_write_guard_env emits root and allow"

[[ -z "$(worker_write_guard_env "$SUP")" ]] \
  || { echo "not ok - a worker inside the checkout must not be guarded" >&2; exit 1; }
echo "ok - a workdir inside the deployment checkout skips the guard"

grep -q 'worker_write_guard_env' "$SCRIPT_DIR/mac-autopilot/scheduler.d/dispatch.sh" \
  || { echo 'not ok - dispatch does not wire the worker write guard' >&2; exit 1; }
echo "ok - dispatch passes the worker write guard to every launched worker"

# The prompt contract: the lesson entry belongs to the unit's own checkout
# registry, never a deployment copy, and a diff without its row is not READY.
rule="$(bash -c 'source "'"$SCRIPT_DIR"'/incident-rule.sh"; incident_rule_text')"
[[ "$rule" == *'registry tracked in THIS checkout'* && "$rule" == *'committed on this unit'"'"'s branch'* \
  && "$rule" == *'writing them is forbidden'* ]] \
  || { echo 'not ok - incident rule does not bind the lesson entry to the unit checkout' >&2; exit 1; }
[[ "$rule" == *'written nowhere, or into a registry file outside this checkout'* ]] \
  || { echo 'not ok - incident rule does not make reviewers reject a diff without its lesson row' >&2; exit 1; }
echo "ok - incident rule targets the unit checkout registry and reviewable delivery"

echo "worker-write-guard.test.sh: PASS"
