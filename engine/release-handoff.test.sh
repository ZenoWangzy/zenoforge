#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
export REPO=fixture/repo ZF_REPO_DIR="$MODEL_POLICY_TEST_REPO"
source "$MODEL_POLICY_TEST_REPO/engine/lib.sh"
ensure_state_labels() { :; }
is_on_hold() { return 1; }
roadmap_ensure_issue_parent() { :; }
guarded_write() { :; }

# Replay the 03:49 label-only recovery of an empty local record.
if state_merge 3013 '.state = "awaiting-release"' 2>"$test_env_root/error"; then
  echo 'not ok - label-only recovery created selectable release state' >&2
  exit 1
fi
[[ ! -e "$STATE_DIR/3013.json" ]]
grep -Fq 'reconcile through conclude_merged_run' "$test_env_root/error"
echo 'ok - incomplete release handoff is refused without writing state'

state_merge 3171 '{state:"awaiting-release",deploy_state:"deployed",deployed_sha:"image-sha",run:{outcome:"merged",merged_at:"2026-10-10T11:46:24Z",evidence:{pr_number:"3179",merged_pr:{number:3179,merge_sha:"main-sha",merged_at:"2026-10-10T11:46:24Z"},real_user_path:"verified production proof"}}}'
before="$(state_read 3171)"
if state_merge 3171 '{state:"awaiting-release",attempts:0}' 2>"$test_env_root/error"; then
  echo 'not ok - stage overwrite erased recorded merge/deploy evidence' >&2
  exit 1
fi
[[ "$(state_read 3171)" == "$before" ]]
mark_awaiting_release 3171 3179
jq -e '.deploy_state == "deployed" and .deployed_sha == "image-sha" and .run.merged_at == "2026-10-10T11:46:24Z" and .run.evidence.merged_pr.merge_sha == "main-sha" and .run.evidence.real_user_path == "verified production proof"' "$(state_file 3171)" >/dev/null
echo 'ok - stage overwrite is refused and same PR replay preserves merge/deploy proof'

mark_awaiting_release 3171 3180
jq -e '.run.evidence.pr_number == "3180" and .deploy_state == "pending" and .deployed_sha == null and .run.evidence.real_user_path == null and .run.evidence.merged_pr == null' "$(state_file 3171)" >/dev/null
mark_awaiting_release 3013 3019
jq -e '.state == "awaiting-release" and .run.outcome == "merged" and .deploy_state == "pending" and .run.evidence.pr_number == "3019"' "$(state_file 3013)" >/dev/null
# Existing incomplete records stay unselectable while an owner repairs identity.
printf '%s\n' '{"state":"awaiting-release","attempts":0}' > "$(state_file 3171)"
if merged_pr_for_issue 3171; then echo 'not ok - incomplete record selected'; exit 1; fi
echo 'ok - new PR gets pending state and legacy incomplete identity stays fail closed'
