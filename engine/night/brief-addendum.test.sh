#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export ZF_REPO=test/repo ZF_REPO_DIR="$root" AGENT_DRY_RUN=0
export ZF_NIGHT_DIR="$AGENT_HOME/night" ADDENDUM_ISSUE="$test_env_root/issue.json"
mkdir -p "$AGENT_HOME/state" "$ZF_NIGHT_DIR/briefs" "$ZF_NIGHT_DIR/hand-registry"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$root/engine/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
cat > "$test_env_bin/ps" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$test_env_bin/systemctl" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$test_env_bin/git" <<'SH'
#!/bin/bash
if [ -n "${ADDENDUM_REAL_GIT:-}" ]; then exec "$ADDENDUM_REAL_GIT" "$@"; fi
exit 0
SH
cat > "$test_env_bin/gh-real" <<'SH'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
  'issue list')
    if [[ " $* " == *' -q '* ]]; then jq -r '.number' "$ADDENDUM_ISSUE"
    else jq -c '[. + {title:(.title // "fixture issue"),body:(.body // "")}]' "$ADDENDUM_ISSUE"; fi ;;
  'issue view') cat "$ADDENDUM_ISSUE" ;;
  'pr list') printf '%s\n' "${ADDENDUM_OPEN_PRS:-[]}" ;;
  'api '*) printf '[]\n' ;;
  'label list') printf 'ready-for-agent\nneeds-triage\nneeds-info\nneeds-advisor\nneeds-recut\n' ;;
  'label create') : ;;
  'issue comment')
    [ "${ADDENDUM_COMMENT_FAIL:-0}" != 1 ] || exit 1
    body=''; shift 2
    while (($#)); do case "$1" in --body-file) body="$(cat "$2")"; shift 2 ;; *) shift ;; esac; done
    jq --arg body "$body" '.comments += [{body:$body}]' "$ADDENDUM_ISSUE" > "$ADDENDUM_ISSUE.tmp"
    mv "$ADDENDUM_ISSUE.tmp" "$ADDENDUM_ISSUE" ;;
  'issue edit')
    [ "${ADDENDUM_EDIT_FAIL:-0}" != 1 ] || exit 1
    jq '.labels=[{name:"ready-for-agent"}]' "$ADDENDUM_ISSUE" > "$ADDENDUM_ISSUE.tmp"
    mv "$ADDENDUM_ISSUE.tmp" "$ADDENDUM_ISSUE" ;;
  *) echo "unexpected gh call: $1 $2" >&2; exit 1 ;;
esac
SH
chmod +x "$test_env_bin/ps" "$test_env_bin/systemctl" "$test_env_bin/git" "$test_env_bin/gh-real"
export ZF_GH_REAL_CLI="$test_env_bin/gh-real" PATH="$root/engine/gh-shim:$test_env_bin:$PATH"
helper="$root/engine/night/brief-addendum.sh"
name=hand-777
brief="$ZF_NIGHT_DIR/briefs/$name.md"; report="$ZF_NIGHT_DIR/$name.report"; pending="$ZF_NIGHT_DIR/$name.pending-addenda"
heading='## Addendum 2026-10-29T01:00:00Z'
printf '%s\n%s\n' "$heading" 'Investigate the supplied evidence.' > "$brief"
printf '%s\n' "$heading" > "$pending"
printf 'STATUS: DONE\n' > "$report"
printf '%s\n' '{"number":777,"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$ADDENDUM_ISSUE"
printf '%s\n' '{"state":"on-hold","recut_children":[],"hold":{"holder":"supervisor","kind":"guarded-recut-repeat","created_at":"2026-10-29T00:00:00Z","release_condition":"finish follow-up"}}' > "$AGENT_HOME/state/777.json"
export ADDENDUM_COMMENT_FAIL=1
if bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"; then
  echo 'FAIL failed issue comment must retain pending addendum' >&2; exit 1
fi
[[ -s "$pending" && "$(jq -r '.state' "$AGENT_HOME/state/777.json")" == on-hold ]]
unset ADDENDUM_COMMENT_FAIL
mkdir -p "$AGENT_HOME/land-queue/requests"
printf '%s\n' '{"ticket":"00000000000000000001","owner":"hand-777","owned_issues":"777","state":"queued"}' > "$AGENT_HOME/land-queue/requests/00000000000000000001.json"
if bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"; then
  echo 'FAIL live landing owner must retain pending addendum' >&2; exit 1
fi
[[ -s "$pending" && "$(jq '.comments|length' "$ADDENDUM_ISSUE")" == 0 ]]
rm "$AGENT_HOME/land-queue/requests/00000000000000000001.json"
jq '.state="CLOSED"' "$ADDENDUM_ISSUE" > "$ADDENDUM_ISSUE.tmp"; mv "$ADDENDUM_ISSUE.tmp" "$ADDENDUM_ISSUE"
if bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"; then
  echo 'FAIL closed issue must retain pending addendum' >&2; exit 1
fi
[[ -s "$pending" && "$(jq '.comments|length' "$ADDENDUM_ISSUE")" == 0 ]]
jq '.state="OPEN"' "$ADDENDUM_ISSUE" > "$ADDENDUM_ISSUE.tmp"; mv "$ADDENDUM_ISSUE.tmp" "$ADDENDUM_ISSUE"
bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"
[[ ! -e "$pending" && "$(jq -r '.state' "$AGENT_HOME/state/777.json")" == ready-for-agent ]]
jq -e '(.comments|length)==1 and (.comments[0].body|contains("Investigate the supplied evidence.")) and any(.labels[]; .name=="ready-for-agent")' "$ADDENDUM_ISSUE" >/dev/null
bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"
[[ "$(jq '.comments|length' "$ADDENDUM_ISSUE")" == 1 ]]
echo 'PASS pending addendum is retried and handed to scheduler exactly once'

printf '%s\n' "$heading" > "$pending"
printf 'STATUS: DONE\n%s\n' "$heading" > "$report"
bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"
[[ ! -e "$pending" && "$(jq '.comments|length' "$ADDENDUM_ISSUE")" == 1 ]]
echo 'PASS acknowledged addendum does not trigger a second handoff'

printf '%s\n' '{"number":777,"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$ADDENDUM_ISSUE"
printf '%s\n' '{"state":"on-hold","recut_children":[],"hold":{"holder":"supervisor","kind":"guarded-recut-repeat","created_at":"2026-10-29T00:00:00Z","release_condition":"finish follow-up"}}' > "$AGENT_HOME/state/777.json"
printf '%s\n%s\n%s\n%s\n' "$heading" 'Original context.' '## Acceptance' 'Preserve this requirement.' > "$brief"
printf '%s\n' "$heading" > "$pending"
printf 'STATUS: DONE\n' > "$report"
export ADDENDUM_EDIT_FAIL=1
if bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"; then
  echo 'FAIL failed label transition must retain pending addendum' >&2; exit 1
fi
[[ -s "$pending" && "$(jq '.comments|length' "$ADDENDUM_ISSUE")" == 1 ]]
next_heading='## Addendum 2026-10-29T01:01:00Z'
printf '%s\n%s\n%s\n' "$next_heading" '## New evidence' 'Preserve the later requirement.' >> "$brief"
printf '%s\n' "$next_heading" >> "$pending"
unset ADDENDUM_EDIT_FAIL
bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"
jq -e '(.comments|length)==2 and (.comments[-1].body|contains("## Acceptance\nPreserve this requirement.")) and (.comments[-1].body|contains("## New evidence\nPreserve the later requirement."))' "$ADDENDUM_ISSUE" >/dev/null
[[ ! -e "$pending" && "$(jq -r '.state' "$AGENT_HOME/state/777.json")" == ready-for-agent ]]
echo 'PASS a later addendum and nested headings survive a failed label transition'

# A pending addendum transfers the original worktree identity and dirty flag so
# the scheduler can carry both local commits and uncommitted files forward.
real_git="$(PATH=/usr/bin:/bin command -v git)"
fixture_repo="$test_env_root/real-repo"; fixture_remote="$test_env_root/real-origin.git"; fixture_worktree="$test_env_root/hand-777-real"
"$real_git" init -q --bare "$fixture_remote"
"$real_git" init -q -b main "$fixture_repo"
"$real_git" -C "$fixture_repo" config user.name fixture
"$real_git" -C "$fixture_repo" config user.email fixture@example.invalid
"$real_git" -C "$fixture_repo" commit -q --allow-empty -m base
"$real_git" -C "$fixture_repo" remote add origin "$fixture_remote"
"$real_git" -C "$fixture_repo" push -q origin main
"$real_git" -C "$fixture_repo" worktree add -q -b hand/issue-777 "$fixture_worktree"
printf 'local commit\n' > "$fixture_worktree/work.txt"
"$real_git" -C "$fixture_worktree" add work.txt
"$real_git" -C "$fixture_worktree" commit -q -m prior-work
prior_sha="$("$real_git" -C "$fixture_worktree" rev-parse HEAD)"
"$real_git" -C "$fixture_worktree" push -q origin HEAD:refs/heads/rescued/agent-issue-777-recovery
"$real_git" -C "$fixture_repo" update-ref -d refs/remotes/origin/rescued/agent-issue-777-recovery
if "$real_git" -C "$fixture_repo" rev-parse --verify refs/remotes/origin/rescued/agent-issue-777-recovery >/dev/null 2>&1; then
  echo 'FAIL remote rescue was already cached by the fixture' >&2; exit 1
fi
printf 'dirty work\n' >> "$fixture_worktree/work.txt"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$ADDENDUM_ISSUE"
printf '%s\n' '{"state":"on-hold","recut_children":[],"hold":{"holder":"supervisor","kind":"external-deliverable","created_at":"2026-10-29T00:00:00Z","release_condition":"finish follow-up"}}' > "$AGENT_HOME/state/777.json"
printf '%s\n%s\n' "$heading" 'Continue the prior work.' > "$brief"
printf '%s\n' "$heading" > "$pending"
ADDENDUM_REAL_GIT="$real_git" ZF_REPO_DIR="$fixture_repo" bash "$helper" --agent-exited "$name" "$fixture_worktree" "$brief" "$report"
jq -e --arg wt "$fixture_worktree" --arg sha "$prior_sha" '.scheduler_handoff | .worktree==$wt and .worktree_sha==$sha and .worktree_dirty==true and .start_ref=="rescued/agent-issue-777-recovery" and .start_sha==$sha' "$AGENT_HOME/state/777.json" >/dev/null
[[ "$(cat "$fixture_worktree/work.txt")" == $'local commit\ndirty work' ]]
echo 'PASS addendum handoff preserves the original local and dirty work'

# The hold sweep has no explicit addendum worktree argument. It must discover
# the exited owner's registry entry and preserve the same committed/dirty work.
jq -n --arg wt "$fixture_worktree" '{worktree:$wt}' > "$ZF_NIGHT_DIR/hand-registry/hand-777.json"
printf '%s\n' '{"number":777,"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$ADDENDUM_ISSUE"
printf '%s\n' '{"state":"on-hold","hold":{"holder":"supervisor","kind":"external-deliverable","created_at":"2026-10-29T00:00:00Z","expires_at":"2099-01-01T00:00:00Z","stage_before":"ready-for-agent","durable_record":true,"release_condition":"finish follow-up"}}' > "$AGENT_HOME/state/777.json"
ADDENDUM_REAL_GIT="$real_git" ZF_REPO_DIR="$fixture_repo" ZF_WORKTREE_ROOT="$test_env_root" \
  bash -c 'source "$1/engine/lib.sh"; supervisor_hold_sweep 777' _ "$root"
jq -e --arg wt "$fixture_worktree" --arg sha "$prior_sha" '.state=="ready-for-agent" and .scheduler_handoff.worktree==$wt and .scheduler_handoff.worktree_sha==$sha and .scheduler_handoff.worktree_dirty==true' "$AGENT_HOME/state/777.json" >/dev/null
[[ "$(cat "$fixture_worktree/work.txt")" == $'local commit\ndirty work' ]]
echo 'PASS hold sweep finds and preserves the exited owner worktree'

# A local hand branch can survive even if its original worktree no longer does.
rm "$ZF_NIGHT_DIR/hand-registry/hand-777.json"
"$real_git" -C "$fixture_repo" branch hand-777 "$prior_sha"
printf '%s\n' '{"number":777,"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$ADDENDUM_ISSUE"
printf '%s\n' '{"state":"on-hold","hold":{"holder":"supervisor","kind":"external-deliverable","created_at":"2026-10-29T00:00:00Z","expires_at":"2099-01-01T00:00:00Z","stage_before":"ready-for-agent","durable_record":true,"release_condition":"finish follow-up"}}' > "$AGENT_HOME/state/777.json"
ADDENDUM_REAL_GIT="$real_git" ZF_REPO_DIR="$fixture_repo" ZF_WORKTREE_ROOT="$test_env_root" \
  bash -c 'source "$1/engine/lib.sh"; supervisor_hold_sweep 777' _ "$root"
jq -e --arg sha "$prior_sha" '.state=="ready-for-agent" and .scheduler_handoff.worktree_sha==$sha and .scheduler_handoff.worktree_dirty==false' "$AGENT_HOME/state/777.json" >/dev/null
echo 'PASS hold sweep preserves the surviving local hand branch'

printf '%s\n' '{"number":777,"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$ADDENDUM_ISSUE"
printf '%s\n' '{"state":"on-hold","hold":{"holder":"supervisor","kind":"external-deliverable","created_at":"2026-10-29T00:00:00Z","expires_at":"2099-01-01T00:00:00Z","stage_before":"ready-for-agent","durable_record":true,"release_condition":"finish follow-up"}}' > "$AGENT_HOME/state/777.json"
"$real_git" -C "$fixture_repo" push -q origin "$prior_sha":refs/heads/agent/issue-777
ADDENDUM_OPEN_PRS='[{"number":777,"headRefName":"agent/issue-777","url":"https://example.invalid/pr/777"}]' \
  ADDENDUM_REAL_GIT="$real_git" ZF_REPO_DIR="$fixture_repo" ZF_WORKTREE_ROOT="$test_env_root" \
  bash -c 'source "$1/engine/lib.sh"; supervisor_hold_sweep 777' _ "$root"
jq -e --arg sha "$prior_sha" '.scheduler_handoff.open_pr==777 and .scheduler_handoff.start_ref=="rescued/agent-issue-777-recovery" and .scheduler_handoff.start_sha==$sha' "$AGENT_HOME/state/777.json" >/dev/null
echo 'PASS an existing PR does not hide the rescued commit'

"$real_git" -C "$fixture_repo" push -q origin :refs/heads/rescued/agent-issue-777-recovery
"$real_git" -C "$fixture_repo" update-ref -d refs/remotes/origin/rescued/agent-issue-777-recovery
"$real_git" -C "$fixture_repo" push -q origin "$prior_sha":refs/heads/rescued/hand-777
printf '%s\n' '{"number":777,"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$ADDENDUM_ISSUE"
printf '%s\n' '{"state":"on-hold","hold":{"holder":"supervisor","kind":"external-deliverable","created_at":"2026-10-29T00:00:00Z","expires_at":"2099-01-01T00:00:00Z","stage_before":"ready-for-agent","durable_record":true,"release_condition":"finish follow-up"}}' > "$AGENT_HOME/state/777.json"
ADDENDUM_REAL_GIT="$real_git" ZF_REPO_DIR="$fixture_repo" ZF_WORKTREE_ROOT="$test_env_root" \
  bash -c 'source "$1/engine/lib.sh"; supervisor_hold_sweep 777' _ "$root"
jq -e --arg sha "$prior_sha" '.scheduler_handoff.start_ref=="rescued/hand-777" and .scheduler_handoff.start_sha==$sha' "$AGENT_HOME/state/777.json" >/dev/null
echo 'PASS hand lifecycle rescue is found by the hold sweep'

jq -n --arg wt "$fixture_worktree" '{worktree:$wt}' > "$ZF_NIGHT_DIR/hand-registry/hand-777.json"
printf '#!/bin/bash\nexit 3\n' > "$test_env_bin/systemctl"
for fixture_holder in hand-777 supervisor; do
  printf '%s\n' '{"number":777,"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}' > "$ADDENDUM_ISSUE"
  jq -n --arg holder "$fixture_holder" '{state:"on-hold",hold:{holder:$holder,kind:"manual",created_at:"2026-10-29T00:00:00Z",expires_at:"2026-10-29T01:00:00Z",stage_before:"ready-for-agent",durable_record:true,release_condition:"finish follow-up"}}' > "$AGENT_HOME/state/777.json"
  ADDENDUM_REAL_GIT="$real_git" ZF_REPO_DIR="$fixture_repo" ZF_WORKTREE_ROOT="$test_env_root" \
    bash "$root/engine/hold.sh" --sweep
  jq -e --arg wt "$fixture_worktree" --arg sha "$prior_sha" '.state=="ready-for-agent" and .scheduler_handoff.worktree==$wt and .scheduler_handoff.worktree_sha==$sha and .scheduler_handoff.worktree_dirty==true' "$AGENT_HOME/state/777.json" >/dev/null
done
echo 'PASS ordinary expired hand hold carries the previous worktree'

name=hand-unassigned
brief="$ZF_NIGHT_DIR/briefs/$name.md"; report="$ZF_NIGHT_DIR/$name.report"; pending="$ZF_NIGHT_DIR/$name.pending-addenda"
printf '%s\n%s\n' "$heading" 'Need an issue owner.' > "$brief"
printf '%s\n' "$heading" > "$pending"
if bash "$helper" --agent-exited "$name" "$test_env_root/old-worktree" "$brief" "$report"; then
  echo 'FAIL owner without an issue must retain its addendum' >&2; exit 1
fi
[[ -s "$pending" ]]
grep -Fq 'brief-addendum-no-issue name=hand-unassigned' "$AGENT_HOME/supervisor-inbox"
echo 'PASS owner without an issue retains the pending addendum'
