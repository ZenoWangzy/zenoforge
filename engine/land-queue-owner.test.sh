#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
unset ENQUEUE_TIER ENQUEUE_ROLE ENQUEUE_PRIORITY ENQUEUE_FRONT ENQUEUE_REPLACE
export AGENT_HOME="$test_env_root/agent" ZF_LAND_QUEUE_DIR="$test_env_root/queue"
export ZF_NIGHT_DIR="$AGENT_HOME/night" OWNER_TEST_ISSUES="$test_env_root/issues" ZF_REPO=test/repo AGENT_DRY_RUN=0
export FAKE_PS_OUTPUT="$test_env_root/ps-output"
mkdir -p "$ZF_LAND_QUEUE_DIR/requests" "$ZF_NIGHT_DIR/hand-registry" "$AGENT_HOME/state" "$OWNER_TEST_ISSUES" "$test_env_root/wt"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$root/engine/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
export OWNER_TEST_GIT="$(command -v git)" ZF_HAND_REPO_DIR="$test_env_root/repo" ZF_REPO_DIR="$test_env_root/repo"
"$OWNER_TEST_GIT" init -q -b fixture "$ZF_HAND_REPO_DIR"
"$OWNER_TEST_GIT" -C "$ZF_HAND_REPO_DIR" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm fixture
cat > "$test_env_bin/gh-real" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
  'issue view') cat "$OWNER_TEST_ISSUES/$3.json" ;;
  'pr list'|'api '*) printf '[]\n' ;;
  'label list') printf 'ready-for-agent\nneeds-triage\nneeds-info\nneeds-advisor\nneeds-recut\n' ;;
  'label create') : ;;
  'issue comment')
    issue="$3"; body=''; shift 3
    while (($#)); do case "$1" in --body-file) body="$(cat "$2")"; shift 2 ;; *) shift ;; esac; done
    jq --arg body "$body" '.comments += [{body:$body}]' "$OWNER_TEST_ISSUES/$issue.json" > "$OWNER_TEST_ISSUES/$issue.tmp"
    mv "$OWNER_TEST_ISSUES/$issue.tmp" "$OWNER_TEST_ISSUES/$issue.json" ;;
  'issue edit')
    issue="$3"
    jq '.labels=[{name:"ready-for-agent"}]' "$OWNER_TEST_ISSUES/$issue.json" > "$OWNER_TEST_ISSUES/$issue.tmp"
    mv "$OWNER_TEST_ISSUES/$issue.tmp" "$OWNER_TEST_ISSUES/$issue.json" ;;
  *) echo "unexpected gh call: $1 $2" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_env_bin/gh-real"
export ZF_GH_REAL_CLI="$test_env_bin/gh-real" PATH="$root/engine/gh-shim:$PATH"
printf '#!/bin/bash\nexit 0\n' > "$test_env_bin/systemd-run"
cat > "$test_env_bin/git" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = rev-parse ]; then exec "$OWNER_TEST_GIT" "$@"; fi
done
exit 0
EOF
chmod +x "$test_env_bin/git" "$test_env_bin/systemd-run"
printf '#!/bin/bash\nexit 3\n' > "$test_env_bin/systemctl"
printf '#!/bin/bash\ncat "$FAKE_PS_OUTPUT"\n' > "$test_env_bin/ps"
chmod +x "$test_env_bin/systemctl" "$test_env_bin/ps"
: > "$FAKE_PS_OUTPUT"
fail() { echo "FAIL $*" >&2; exit 1; }
recover() { bash "$root/engine/land-queue.sh" recover > "$test_env_root/recover.log" 2>&1 || { cat "$test_env_root/recover.log"; fail recovery; }; }
fixture() {
  name="$1" ticket="$2"; issue="$((10#$2))"; worktree="$test_env_root/wt/$name"; brief="$test_env_root/$name.md"; report="$test_env_root/$name.report"
  "$OWNER_TEST_GIT" -C "$ZF_HAND_REPO_DIR" worktree add --detach -q "$worktree" HEAD
  printf 'Owned issues: %s\nbrief\n' "$issue" > "$brief"
  printf '%s\n' '{"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$OWNER_TEST_ISSUES/$issue.json"
  printf '%s\n' '{"state":"on-hold","recut_children":[],"hold":{"holder":"supervisor","kind":"guarded-recut-repeat","created_at":"2026-10-29T00:00:00Z","release_condition":"finish continuation"}}' > "$AGENT_HOME/state/$issue.json"
  # Incident 15:15Z: LANDED was appended, but both STATUS lines stayed LANDING-QUEUED.
  printf 'STATUS: LANDING-QUEUED\nLANDED %s %040d\nSTATUS: LANDING-QUEUED\n' "$ticket" 1 > "$report"
  jq -n --arg ticket "$ticket" --arg name "$name" --arg wt "$worktree" --arg brief "$brief" --arg report "$report" \
    '{ticket:$ticket,owner:$name,owner_worktree:$wt,worktree:$wt,report:$report,state:"landed",landed_sha:("1"*40),hand_owner_resume:{pid:99999999,role:"work",brief:$brief,attempt:0,start_ticks:"1",log:"",owned_issues:"",owned_nodes:""}}' \
    > "$ZF_LAND_QUEUE_DIR/requests/$ticket.json"
  jq -n --arg wt "$worktree" --arg brief "$brief" --arg report "$report" --arg issue "$issue" \
    '{pid:99999999,worktree:$wt,brief:$brief,report:$report,role:"production",tier:"hotfix",priority:"pipeline",owned_issues:$issue}' \
    > "$ZF_NIGHT_DIR/hand-registry/$name.json"
}
fixture hand-main-suites-red-1012 00000000000000000507
printf 'Incremental continuation required after this independent budget candidate lands\n' >> "$report"
recover
[[ $(jq -r '.state' "$AGENT_HOME/state/$issue.json") == ready-for-agent ]] || fail 'landing continuation was not made schedulable'
jq -e --arg name "$name" '(.comments|length)==1 and (.comments[0].body|contains($name)) and (.comments[0].body|contains("Incremental continuation required"))' "$OWNER_TEST_ISSUES/$issue.json" >/dev/null || fail 'landing continuation lost owner or report context'
[[ $(head -n 1 "$report") != 'STATUS: LANDING-QUEUED'* ]] || fail 'continuation left report queued on landed ticket'
[[ $(jq -r .hand_owner_handoff "$ZF_LAND_QUEUE_DIR/requests/$ticket.json") == queued ]] || fail 'landing continuation not recorded'
recover
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == 1 ]] || fail 'repeat recovery duplicated continuation'
echo 'PASS real continuation line resumes production owner exactly once after LANDED'

fixture hand-addendum-dead-hand-1012 00000000000000000542
printf '## Addendum 2026-10-12T15:15:44.030035647Z\nTwo queue-tooling gaps\n' >> "$brief"
recover
jq -e '.state == "OPEN" and (.comments|length)==1 and (.comments[0].body|contains("Two queue-tooling gaps"))' "$OWNER_TEST_ISSUES/$issue.json" >/dev/null || fail 'unresolved addendum not resumed'
echo 'PASS unacknowledged addendum resumes landed owner'

fixture hand-complete 00000000000000000543
printf '## Addendum 2026-10-12T15:15:44.030035647Z\nHandled\n' >> "$brief"
printf '## Addendum 2026-10-12T15:15:44.030035647Z\nResolved and tested\n' >> "$report"
recover
[[ $(head -n 1 "$report") == 'STATUS: DONE' && $(tail -n 1 "$report") == 'STATUS: DONE' ]] || fail 'completed landing not terminal DONE'
[[ $(jq -r .landing_status "$ZF_NIGHT_DIR/hand-registry/$name.json") == DONE ]] || fail 'registry completion not terminal'
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == 0 ]] || fail 'acknowledged addendum resumed'
echo 'PASS acknowledged addenda leave report and registry DONE'

for prior_stage in awaiting-release concluded; do
  if [[ "$prior_stage" == awaiting-release ]]; then next_ticket=00000000000000000584; else next_ticket=00000000000000000585; fi
  fixture "hand-continuation-$prior_stage" "$next_ticket"
  jq --arg state "$prior_stage" '.state=$state | del(.hold)' "$AGENT_HOME/state/$issue.json" > "$test_env_root/state.tmp"
  mv "$test_env_root/state.tmp" "$AGENT_HOME/state/$issue.json"
  jq --arg label "$prior_stage" '.labels=[{name:$label}]' "$OWNER_TEST_ISSUES/$issue.json" > "$test_env_root/issue.tmp"
  mv "$test_env_root/issue.tmp" "$OWNER_TEST_ISSUES/$issue.json"
  printf 'CONTINUATION: required after landing\n' >> "$report"
  recover
  [[ $(jq -r '.state' "$AGENT_HOME/state/$issue.json") == ready-for-agent ]] || fail "$prior_stage continuation was not requeued"
  jq -e '(.comments|length)==1 and (.comments[0].body|contains("CONTINUATION: required after landing"))' "$OWNER_TEST_ISSUES/$issue.json" >/dev/null || fail "$prior_stage continuation lost its report"
done
echo 'PASS continuation after an awaiting-release or concluded state returns to scheduler'

terminal_index=560
for terminal in DONE 'FOLLOWUP(3454)' 'LANDED complete'; do
  terminal_index=$((terminal_index + 1))
  fixture "hand-terminal-$terminal_index" "$(printf '%020d' "$terminal_index")"
  printf 'STATUS: %s\nCONTINUATION: required old declaration\n' "$terminal" > "$report"
  printf '## Addendum old-heading\nHistorical instructions\n' >> "$brief"
  before_terminal="$(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json")"
  recover
  [[ "$(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json")" == "$before_terminal" ]] || fail 'terminal owner resumed without pending work'
  [[ "$(head -n 1 "$report")" == "STATUS: $terminal" ]] || fail 'terminal report result overwritten'
  [[ "$(tail -n 1 "$report")" == "STATUS: $terminal" ]] || fail 'landing event displaced terminal STATUS footer'
  [[ ! -e "$ZF_NIGHT_DIR/$name.pending-addenda" ]] || fail 'terminal owner gained continuation marker'
done
echo 'PASS DONE FOLLOWUP LANDED owners ignore historical headings and continuation declarations'

fixture hand-terminal-pending 00000000000000000580
printf 'STATUS: DONE\n' > "$report"
printf '## Addendum new-work\n' >> "$brief"
printf '## Addendum new-work\n' > "$ZF_NIGHT_DIR/$name.pending-addenda"
recover
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == 1 ]] || fail 'terminal owner with pending new work not resumed'
echo 'PASS unresolved pending addendum resumes terminal owner'

fixture hand-live-continuation 00000000000000000544
printf 'CONTINUATION: required after landing\n' >> "$report"
printf 'codex exec --cd %s\n' "$worktree" > "$FAKE_PS_OUTPUT"
recover
[[ -s "$ZF_NIGHT_DIR/$name.pending-addenda" ]] || fail 'live landing owner has no exit callback marker'
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == 0 ]] || fail 'live owner was dispatched twice'
: > "$FAKE_PS_OUTPUT"
recover
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == 1 && $(jq -r '.state' "$AGENT_HOME/state/$issue.json") == ready-for-agent ]] || fail 'exited continuation owner not queued'
recover
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == 1 ]] || fail 'live-to-exited continuation duplicated'
echo 'PASS running owner defers to exit; recovery handles exit race without duplicate'

fixture hand-exit-callback 00000000000000000545
printf 'CONTINUATION: required after landing\n' >> "$report"
printf 'codex exec --cd %s\n' "$worktree" > "$FAKE_PS_OUTPUT"
recover
: > "$FAKE_PS_OUTPUT"
bash "$root/engine/night/brief-addendum.sh" --agent-exited "$name" "$worktree" "$brief" "$report" >/dev/null
queued_before=$(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json")
# The accepted resume is already running by the time the old landing request is recovered.
printf 'codex exec --cd %s\n' "$worktree" > "$FAKE_PS_OUTPUT"
recover
[[ ! -e "$ZF_NIGHT_DIR/$name.pending-addenda" ]] || fail 'recovery attached old continuation to the new session'
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == "$queued_before" ]] || fail 'recovery replaced the already accepted exit callback'
echo 'PASS exit callback acknowledgement prevents old landing from resuming a new session'

fixture hand-newer-dispatch 00000000000000000546
printf 'STATUS: IN_PROGRESS\nnew run owns this report\n' > "$report"
jq '.pid=88888888' "$ZF_NIGHT_DIR/hand-registry/$name.json" > "$test_env_root/new-registry"
mv "$test_env_root/new-registry" "$ZF_NIGHT_DIR/hand-registry/$name.json"
queued_before=$(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json")
recover
[[ $(head -n 1 "$report") == 'STATUS: IN_PROGRESS' ]] || fail 'old landing completed a newer dispatch report'
[[ $(jq -r .hand_owner_handoff "$ZF_LAND_QUEUE_DIR/requests/$ticket.json") == superseded ]] || fail 'new dispatch ownership not acknowledged'
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == "$queued_before" ]] || fail 'old landing duplicated newer owner'
echo 'PASS legacy landing leaves a newer dispatch report and ownership intact'

fixture hand-fork-continuation 00000000000000000581
printf 'CONTINUATION: required after landing\n' >> "$report"
fork="$test_env_root/wt/$name-fork"
"$OWNER_TEST_GIT" -C "$ZF_HAND_REPO_DIR" worktree add --detach -q "$fork" HEAD
jq --arg fork "$fork" '.owner_worktree=$fork | .worktree=$fork | del(.hand_owner_resume)' \
  "$ZF_LAND_QUEUE_DIR/requests/$ticket.json" > "$test_env_root/fork-request"
mv "$test_env_root/fork-request" "$ZF_LAND_QUEUE_DIR/requests/$ticket.json"
queued_before=$(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json")
printf 'codex exec --cd %s\n' "$worktree" > "$FAKE_PS_OUTPUT"
recover
[[ $(jq -r .hand_owner_handoff "$ZF_LAND_QUEUE_DIR/requests/$ticket.json") == pending-exit ]] || fail 'fork landing lost live canonical owner'
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == "$queued_before" ]] || fail 'fork landing duplicated live canonical owner'
: > "$FAKE_PS_OUTPUT"
recover
jq -e --arg worktree "$worktree" '.comments[0].body|contains($worktree)' "$OWNER_TEST_ISSUES/$issue.json" >/dev/null || fail 'fork landing resumed wrong worktree'
queued_before=$(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json")
recover
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == "$queued_before" ]] || fail 'fork landing repeated canonical continuation'
echo 'PASS fork landing without snapshot resumes canonical report owner exactly once'

fixture hand-fork-newer 00000000000000000582
queued_before=$(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json")
jq --arg fork "$fork" '.owner_worktree=$fork | .worktree=$fork' \
  "$ZF_LAND_QUEUE_DIR/requests/$ticket.json" > "$test_env_root/fork-request"
mv "$test_env_root/fork-request" "$ZF_LAND_QUEUE_DIR/requests/$ticket.json"
jq '.pid=88888888' "$ZF_NIGHT_DIR/hand-registry/$name.json" > "$test_env_root/new-registry"
mv "$test_env_root/new-registry" "$ZF_NIGHT_DIR/hand-registry/$name.json"
printf 'STATUS: IN_PROGRESS\nnew run owns this report\n' > "$report"
recover
[[ $(jq -r .hand_owner_handoff "$ZF_LAND_QUEUE_DIR/requests/$ticket.json") == superseded ]] || fail 'fork landing missed newer canonical owner'
[[ $(head -n 1 "$report") == 'STATUS: IN_PROGRESS' ]] || fail 'fork landing completed newer canonical owner'
[[ $(jq '.comments|length' "$OWNER_TEST_ISSUES/$issue.json") == "$queued_before" ]] || fail 'fork landing dispatched newer canonical owner'
echo 'PASS fork landing snapshot cannot override newer canonical dispatch'

fixture hand-failed-owner 00000000000000000547
jq '.state="queued" | .branch="hand/fixture" | .head_sha=("1"*40) | .plan_package="fixture"' \
  "$ZF_LAND_QUEUE_DIR/requests/$ticket.json" > "$test_env_root/failed-request"
mv "$test_env_root/failed-request" "$ZF_LAND_QUEUE_DIR/requests/$ticket.json"
if bash "$root/engine/land-queue.sh" run "$ZF_LAND_QUEUE_DIR/requests/$ticket.json" > "$test_env_root/failed.log" 2>&1; then
  fail 'invalid snapshot did not fail'
fi
[[ $(head -n 1 "$report") == "STATUS: BLOCKED-ON landing-failed $ticket" ]] || fail 'failed landing left report queued'
[[ $(jq -r '.[-1].role' "$ZF_NIGHT_DIR/blocked-hand-agents.json") == production ]] || fail 'failed owner recovery lost registry role'
echo 'PASS failed landing records blocker and restores registry role in existing retry path'

fixture hand-newer-failed-owner 00000000000000000548
printf 'STATUS: IN_PROGRESS\nnew owner\n' > "$report"
jq '.pid=88888888' "$ZF_NIGHT_DIR/hand-registry/$name.json" > "$test_env_root/new-registry"
mv "$test_env_root/new-registry" "$ZF_NIGHT_DIR/hand-registry/$name.json"
jq '.state="queued" | .branch="hand/fixture" | .head_sha=("1"*40) | .plan_package="fixture"' \
  "$ZF_LAND_QUEUE_DIR/requests/$ticket.json" > "$test_env_root/failed-request"
mv "$test_env_root/failed-request" "$ZF_LAND_QUEUE_DIR/requests/$ticket.json"
if bash "$root/engine/land-queue.sh" run "$ZF_LAND_QUEUE_DIR/requests/$ticket.json" > "$test_env_root/failed.log" 2>&1; then
  fail 'invalid old snapshot did not fail'
fi
[[ $(head -n 1 "$report") == 'STATUS: IN_PROGRESS' ]] || fail 'old failure overwrote newer owner status'
[[ $(jq -r '.state' "$ZF_LAND_QUEUE_DIR/requests/$ticket.json") == failed ]] || fail 'old failure not durable'
echo 'PASS failed old landing preserves newer owner while retaining failure evidence'
