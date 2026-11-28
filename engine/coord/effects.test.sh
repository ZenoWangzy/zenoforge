#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$engine/coord.sh"
source "$engine/coord-remote.sh"
source "$engine/coord/effects.sh"

fail() { printf 'effects.test.sh: %s\n' "$*" >&2; exit 1; }

off_output="$(ZF_COORD=off ZF_ENGINE_DIR="$engine" AGENT_HOME="$AGENT_HOME" bash -c \
  'source "$ZF_ENGINE_DIR/config.sh"; effect_run event-test noop merge -- printf off-mode')" \
  || fail 'coordination-off adapter call failed'
[[ "$off_output" == off-mode ]] || fail 'coordination-off adapter changed command output'
[[ "$(effect_claim_for push:agent/topic-9301)" == effect-push-agent-topic-9301 ]] \
  || fail 'effect claim did not sanitize a branch key'
remote_record="$(jq -cn --arg key issue-9301 '{version:1,key:$key,owner:"owner-effects",owner_kind:"ticket",subject:"9301",unit:"issue-9301",stage:"implement",expires_at:100,intents:{"push:agent/topic-9301":{kind:"push",class:"idempotent",state:"pending",gen:1,run:"owner-effects"}}}')"
_coord_remote_record_valid issue-9301 "$remote_record" \
  || fail 'remote claim rejected a branch path in its intent key'

claim=issue-9301
owner=owner-effects
coord_acquire "$claim" "$owner" test 9301 test-unit test || fail 'claim acquisition failed'
ZF_COORD_OWNER="$owner"
effect_begin "$claim" merge:pr-31 merge --class idempotent || fail 'pending intent was not recorded'
record="$(coord_read "$claim")" || fail 'claim was not readable after effect reservation'
jq -e '.intents["merge:pr-31"].kind == "merge" and .intents["merge:pr-31"].class == "idempotent" and .intents["merge:pr-31"].state == "pending"' <<<"$record" >/dev/null \
  || fail 'claim did not expose the pending merge intent'
effect_complete "$claim" merge:pr-31 '{"merge_sha":"abc123"}' || fail 'intent completion was not recorded'
record="$(coord_read "$claim")" || fail 'claim was not readable after effect completion'
jq -e '.intents["merge:pr-31"].state == "done" and .intents["merge:pr-31"].result.merge_sha == "abc123"' <<<"$record" >/dev/null \
  || fail 'claim did not expose the completed merge result'
effect_calls="$test_env_root/effect-calls"
fake_effect() { printf 'x' >>"$effect_calls"; printf 'merged\n'; }
effect_output="$(effect_run "$claim" merge:pr-32 merge -- fake_effect)" || fail 'effect command did not run'
[[ "$effect_output" == merged ]] || fail 'effect command output was not returned'
effect_output="$(effect_run "$claim" merge:pr-32 merge -- fake_effect)" || fail 'completed effect did not return successfully'
[[ "$effect_output" == merged ]] || fail 'completed effect result was not returned'
[[ "$(cat "$effect_calls")" == x ]] || fail 'completed effect command ran more than once'
mail_calls="$test_env_root/mail-calls"
uncertain_mail() { printf 'x' >>"$mail_calls"; return 17; }
if effect_run "$claim" mail:9301:1 mail -- uncertain_mail; then fail 'failed mail command was reported as successful'; else [[ $? == 17 ]] || fail 'mail command status changed'; fi
if effect_run "$claim" mail:9301:1 mail -- uncertain_mail; then fail 'pending mail intent was replayed'; else [[ $? == 3 ]] || fail 'pending mail did not fail closed'; fi
[[ "$(cat "$mail_calls")" == x ]] || fail 'pending mail command was replayed'
record="$(coord_read "$claim")" || fail 'claim was not readable before takeover'
clock_file="$test_env_root/effects-clock"
printf '%s\n' "$(( $(jq -r '.expires_at' <<<"$record") + 1 ))" >"$clock_file"
ZF_COORD_CLOCK_FILE="$clock_file"
coord_acquire "$claim" owner-successor test 9301 test-unit test || fail 'expired claim could not be taken over'
ZF_COORD_OWNER=owner-successor
record="$(coord_read "$claim")" || fail 'successor claim was not readable'
jq -e '.intents["merge:pr-31"].state == "done" and .intents["mail:9301:1"].state == "unknown"' <<<"$record" >/dev/null \
  || fail 'takeover dropped the existing intent history'
effect_begin "$claim" merge:pr-33 merge --class idempotent || fail 'pending merge intent was not recorded'
mkdir -p "$test_env_root/bin"
cat >"$test_env_root/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'pr view 33 '* ) printf '%s\n' '{"state":"MERGED","mergeCommit":{"oid":"dddddddddddddddddddddddddddddddddddddddd"}}' ;;
  'pr view 34 '* ) printf '%s\n' '{"state":"OPEN","mergeCommit":null}' ;;
  *'repos/owner/repo/issues/9302/comments'*) printf '%s\n' 'not-json' ;;
  *'repos/owner/repo/issues/9301/comments'*) printf '%s\n' '[[{"id":7,"body":"Repeated occurrence. <!-- zf-intent:comment:9301:posted -->"}]]' ;;
  *'repos/owner/repo/deployments?environment=production&per_page=20'*) printf '%s\n' '[{"id":77,"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","payload":{"release_seq":7}}]' ;;
  *'repos/owner/repo/deployments/77/statuses'*) printf '%s\n' '[{"state":"success","created_at":"2026-01-01T00:00:00Z"}]' ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$test_env_root/bin/gh"
PATH="$test_env_root/bin:$PATH"
export PATH
REPO=owner/repo
effect_output="$(effect_run "$claim" merge:pr-33 merge -- fake_effect)" || fail 'merged pending intent was not reconciled'
[[ -z "$effect_output" ]] || fail 'reconciled merge emitted a command result it did not have'
record="$(coord_read "$claim")" || fail 'claim was not readable after reconciliation'
jq -e '.intents["merge:pr-33"].state == "done" and .intents["merge:pr-33"].result.merge_commit == "dddddddddddddddddddddddddddddddddddddddd"' <<<"$record" >/dev/null \
  || fail 'merged PR was not recorded as done'
effect_output="$(effect_run "$claim" merge:pr-33 merge -- fake_effect)" || fail 'reconciled merge did not return successfully'
[[ -z "$effect_output" ]] || fail 'reconciled merge emitted a command result it did not have'
[[ "$(cat "$effect_calls")" == x ]] || fail 'reconciled merge was repeated'
effect_begin "$claim" merge:pr-34 merge --class idempotent || fail 'retryable merge intent was not recorded'
retry_calls="$test_env_root/retry-calls"
retry_effect() { printf x >>"$retry_calls"; printf 'retried\n'; }
effect_output="$(effect_run "$claim" merge:pr-34 merge -- retry_effect)" || fail 'open pending merge was not retried'
[[ "$effect_output" == retried && "$(cat "$retry_calls")" == x ]] || fail 'open pending merge retry did not run once'
effect_begin "$claim" mail:9301:2 mail --class once || fail 'pending mail intent was not recorded'
effect_reconcile "$claim" mail:9301:2 || fail 'mail intent reconciliation failed'
record="$(coord_read "$claim")" || fail 'claim was not readable after mail reconciliation'
jq -e '.intents["mail:9301:2"].state == "unknown"' <<<"$record" >/dev/null \
  || fail 'ambiguous mail was not blocked as unknown'
cat >"$test_env_root/bin/git" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *check-ref-format* ]] && exit 0
case "$*" in
  *agent/topic-9301*) printf '%s\trefs/heads/agent/topic-9301\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  *agent/revert-main-*-abcdef123456*) printf '%s\trefs/heads/agent/revert-main-9301-abcdef123456\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$test_env_root/bin/git"
REPO_DIR="$test_env_root/repo"
effect_begin "$claim" push:agent/topic-9301 push --class idempotent || fail 'pending push intent was not recorded'
effect_reconcile "$claim" push:agent/topic-9301 || fail 'push intent reconciliation failed'
record="$(coord_read "$claim")" || fail 'claim was not readable after push reconciliation'
jq -e '.intents["push:agent/topic-9301"].state == "done" and .intents["push:agent/topic-9301"].result.branch == "agent/topic-9301"' <<<"$record" >/dev/null \
  || fail 'published branch was not recorded as done'
effect_begin "$claim" revert:abcdef123456 revert --class idempotent || fail 'pending revert intent was not recorded'
effect_reconcile "$claim" revert:abcdef123456 || fail 'revert intent reconciliation failed'
record="$(coord_read "$claim")" || fail 'claim was not readable after revert reconciliation'
jq -e '.intents["revert:abcdef123456"].state == "done" and .intents["revert:abcdef123456"].result.branch == "agent/revert-main-9301-abcdef123456"' <<<"$record" >/dev/null \
  || fail 'reverted branch was not recorded as done'
effect_begin "$claim" deploy:7 deploy --class once || fail 'pending deploy intent was not recorded'
effect_reconcile "$claim" deploy:7 || fail 'deploy intent reconciliation failed'
record="$(coord_read "$claim")" || fail 'claim was not readable after deploy reconciliation'
jq -e '.intents["deploy:7"].state == "done" and .intents["deploy:7"].result.deployment_id == 77' <<<"$record" >/dev/null \
  || fail 'deployed release was not recorded as done'
effect_begin "$claim" comment:9301:posted comment --class once || fail 'pending comment intent was not recorded'
effect_reconcile "$claim" comment:9301:posted || fail 'comment intent reconciliation failed'
record="$(coord_read "$claim")" || fail 'claim was not readable after comment reconciliation'
jq -e '.intents["comment:9301:posted"].state == "done" and .intents["comment:9301:posted"].result.issue == 9301' <<<"$record" >/dev/null \
  || fail 'comment marker was not recorded as done'
effect_begin "$claim" comment:9301:missing comment --class once || fail 'missing comment intent was not recorded'
effect_reconcile "$claim" comment:9301:missing || fail 'missing comment reconciliation failed'
record="$(coord_read "$claim")" || fail 'claim was not readable after missing comment reconciliation'
jq -e '.intents["comment:9301:missing"].state == "unknown"' <<<"$record" >/dev/null \
  || fail 'an absent comment marker was not blocked as unknown'
effect_begin "$claim" comment:9302:malformed comment --class once || fail 'malformed comment intent was not recorded'
if effect_reconcile "$claim" comment:9302:malformed; then
  fail 'malformed comment response was accepted as an absent marker'
else
  [[ "$?" == 3 ]] || fail 'malformed comment response did not remain unknown'
fi
record="$(coord_read "$claim")" || fail 'claim was not readable after malformed comment response'
jq -e '.intents["comment:9302:malformed"].state == "pending"' <<<"$record" >/dev/null \
  || fail 'malformed comment response changed the pending intent'

printf 'effects.test.sh: PASS\n'
