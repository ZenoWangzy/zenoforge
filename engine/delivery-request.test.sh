#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
entry="$MODEL_POLICY_TEST_REPO/engine/delivery-request.sh"
mkdir -p "$AGENT_HOME/checkout/engine" "$AGENT_HOME/land-queue/requests" "$AGENT_HOME/fixture"
printf '[]\n' > "$AGENT_HOME/fixture/deployments.json"
# Fake gh: deployment listings and statuses come from fixtures, and --jq is applied the way gh applies it.
cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api ]] || exit 2
endpoint="$2"; shift 2
filter=""
while (($#)); do
  case "$1" in --jq) filter="$2"; shift 2 ;; *) shift ;; esac
done
[[ -z "${FAKE_GH_FAIL:-}" ]] || exit 1
if [[ "${FAKE_GH_SLEEP_ON:-}" == list && "$endpoint" != */statuses ]] ||
   [[ "${FAKE_GH_SLEEP_ON:-}" == status && "$endpoint" == */statuses ]]; then
  exec sleep "${FAKE_GH_SLEEP_SECONDS:-30}"
fi
case "$endpoint" in
  repos/*/deployments\?*) body="$(cat "$AGENT_HOME/fixture/deployments.json")" ;;
  repos/*/deployments/*/statuses) id="${endpoint%/statuses}"; id="${id##*/}"; body="$(cat "$AGENT_HOME/fixture/statuses-$id.json")" ;;
  *) exit 2 ;;
esac
if [[ -n "$filter" ]]; then jq -r "$filter" <<< "$body"; else printf '%s\n' "$body"; fi
GH
chmod +x "$test_env_bin/gh"
cat > "$AGENT_HOME/checkout/engine/lib.sh" <<'LIB'
agent_pipeline_write_guard() { [[ "$1" == delivery-request && "$2" == "$AGENT_HOME/delivery-requests" ]]; }
LOG_DIR="$AGENT_HOME/logs"
REPO=test/repo
pr_merge_delivery_row() { printf '%s\t%s\t%s\n' "${FIXTURE_PR_STATE:-OPEN}" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
merge_agent_pr() {
  printf '%s\n' "$*" >> "$AGENT_HOME/merge-calls"
  [[ "${FIXTURE_MERGE_PENDING:-0}" != 1 ]] || { MERGE_GATE_FAILURE_KIND=checks; MERGE_GATE_FAILURE_REASON=pending; return 1; }
}
conclude_merged_run() { printf '%s\n' "$*" >> "$AGENT_HOME/conclude-calls"; }
LIB
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bash "$entry" merge-one merge 42 101 "$sha" > "$test_env_root/result"
bash "$entry" merge-one merge 42 101 "$sha" > "$test_env_root/replay"
cmp "$test_env_root/result" "$test_env_root/replay"
[[ "$(wc -l < "$AGENT_HOME/merge-calls" | tr -d ' ')" == 1 ]]
[[ "$(wc -l < "$AGENT_HOME/conclude-calls" | tr -d ' ')" == 1 ]]
grep -q '42 101 .* 1 0' "$AGENT_HOME/merge-calls"
echo 'ok - replay uses one canonical gated merge and one handoff'
if bash "$entry" merge-one merge 42 102 "$sha"; then echo 'unexpected identity reuse' >&2; exit 1; fi
if FIXTURE_MERGE_PENDING=1 bash "$entry" merge-two merge 42 102 "$sha"; then echo 'unexpected pending success' >&2; exit 1; else [[ "$?" == 75 ]]; fi
bash "$entry" merge-two merge 42 102 "$sha" > /dev/null
[[ "$(wc -l < "$AGENT_HOME/merge-calls" | tr -d ' ')" == 3 ]]
echo 'ok - argument drift is refused; a deferred request can resume under the same identity'

jq -n --arg path "$AGENT_HOME/delivery-requests/worktrees/land-one" \
  '{ticket:"00000000000000000001",worktree:$path}' > "$AGENT_HOME/land-queue/requests/00000000000000000001.json"
bash "$entry" land-one land codex/topic "$sha" fixture > "$test_env_root/land"
grep -q 'LANDING-QUEUED 00000000000000000001' "$test_env_root/land"
bash "$entry" land-one status > "$test_env_root/status"
cmp "$test_env_root/land" "$test_env_root/status"
echo 'ok - an enqueue/ack interruption recovers the existing queue ticket'
if bash "$entry" ../escape status; then echo 'unexpected path escape' >&2; exit 1; fi

# A merge completed before acknowledgement: resume the canonical handoff only.
FIXTURE_PR_STATE=MERGED bash "$entry" merge-after-crash merge 42 103 "$sha" > /dev/null
[[ "$(wc -l < "$AGENT_HOME/merge-calls" | tr -d ' ')" == 3 ]]
echo 'ok - a completed merge never repeats while its handoff is recovered'

runtime="$AGENT_HOME/checkout"
cp "$MODEL_POLICY_TEST_REPO/engine/production-deployment-read.sh" "$runtime/engine/production-deployment-read.sh"
chmod +x "$runtime/engine/production-deployment-read.sh"
git -C "$runtime" init -q -b main
git -C "$runtime" config user.name fixture
git -C "$runtime" config user.email fixture@example.invalid
cat > "$runtime/engine/land-direct-main.sh" <<'LANDER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --enqueue && "$ZF_AGENT_NAME" == fixture ]]
printf '%s\n' "$PWD" >> "$AGENT_HOME/land-calls"
jq -n --arg path "$PWD" '{ticket:"00000000000000000002",worktree:$path}' > "$AGENT_HOME/land-queue/requests/00000000000000000002.json"
printf 'LANDING-QUEUED 00000000000000000002\n'
LANDER
git -C "$runtime" add .
git -C "$runtime" commit -qm fixture
git -C "$runtime" branch codex/fixture
git init -q --bare "$test_env_root/origin.git"
git -C "$runtime" remote add origin "$test_env_root/origin.git"
git -C "$runtime" push -q origin main codex/fixture
head="$(git -C "$runtime" rev-parse HEAD)"
bash "$entry" land-new land codex/fixture "$head" fixture > /dev/null
[[ "$(wc -l < "$AGENT_HOME/land-calls" | tr -d ' ')" == 1 ]]
rm "$AGENT_HOME/delivery-requests/land-new.json"
bash "$entry" land-new land codex/fixture "$head" fixture > /dev/null
[[ "$(wc -l < "$AGENT_HOME/land-calls" | tr -d ' ')" == 1 ]]
echo 'ok - a fresh branch is imported into an isolated worktree; ack recovery never enqueues twice'

