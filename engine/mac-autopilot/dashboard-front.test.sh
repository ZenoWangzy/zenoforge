#!/usr/bin/env bash
# gen_dashboard.py 的 front（收单 → triage → advisor → 发布等待）：阶段 / 仓库总量与滞留时间、需求阶梯、顾问批处理（lib.sh 读状态 + 结果日志）、
# triage 流水线效率账、发布列车被挡；GitHub 计数缓存 5 分钟；任何一块失败只让那一块"数据不可用"，看板其余照常。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "dashboard-front.test.sh: $*" >&2; exit 1; }
f="$test_env_root/front"; root="$f/repo"; sup="$root/.scratch-supervisor"; a="$sup/autopi"
export LUNA_WORKER_SLICE_DIR="$f/workers.slice" LUNA_SLOTS="$f/luna-slots"
mkdir -p "$f/bin" "$a/alerts" "$AGENT_HOME/logs" "$AGENT_HOME/metrics" "$f/sessions" "$root/engine/state" "$root/.zenoforge/state"
mkdir -p "$LUNA_WORKER_SLICE_DIR" "$LUNA_SLOTS"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git init -q -b main "$root"
echo 1 > "$root/a"; git -C "$root" add a; GIT_COMMITTER_DATE="$(date -u -d '-5 hours' +%FT%TZ)" git -C "$root" commit -qm deployed --date "$(date -u -d '-5 hours' +%FT%TZ)"
deployed="$(git -C "$root" rev-parse HEAD)"
echo 2 > "$root/a"; git -C "$root" add a; git -C "$root" commit -qm main
main="$(git -C "$root" rev-parse HEAD)"
iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
stamp() { date -u -d "$1" +%Y%m%dT%H%M%SZ; }
# 会话日边界离现在约 12 小时，夹具里的"今日"事件不会跨日
utc_hour=$((10#$(date -u +%H))); off=$((12 - utc_hour))
if (( off > 0 )); then tz="Etc/GMT-$off"; elif (( off < 0 )); then tz="Etc/GMT+$((-off))"; else tz="Etc/GMT"; fi
export SESSION_TZ="$tz" CODEX_SESSIONS_DIR="$f/sessions" MAC_AUTOPILOT_ROOT="$root" \
  MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$a" ZF_REPO_DIR="$root" ZF_REPO="example/fixture-repo"
export ZF_HOME="$f/zenoforge-home" AUTOPILOT_PAUSE_FILE="$AGENT_HOME/PAUSE"
mkdir -p "$AGENT_HOME/engine-versions/6da8c7285e8b/engine" "$ZF_HOME"
ln -s "$AGENT_HOME/engine-versions/6da8c7285e8b/engine" "$AGENT_HOME/engine-live"
mkdir -p "$AGENT_HOME/night"
jq -n --argjson sampled_epoch "$(date -u +%s)" '{status:"OK",sampled_epoch:$sampled_epoch,gb_per_hour:0,daily:{wire_bytes:0,categories:{}}}' \
  > "$AGENT_HOME/night/network-traffic-last-result.json"
export MAC_AUTOPILOT_COST_CACHE="$f/cost.json" MAC_AUTOPILOT_DASHBOARD_OUTPUT="$f/out.js" GH_KEY_CACHE_DIR="$f/gh-key-cache"
export FAKE_DEPLOYMENTS="$f/deployments.json" FAKE_DEPLOYMENT_WRITES="$f/deployment-writes"
export FAKE_SSH_LOG="$f/ssh.log"
mkdir -p "$root/.zenoforge/mac-autopilot"
cp "$script_dir/NODE-HEALTH.md" "$root/.zenoforge/mac-autopilot/NODE-HEALTH.md"
health_doc_ref="$(PYTHONPATH="$script_dir" python3 -c 'import node_health; print(node_health.health_doc_reference())')"
[[ "$health_doc_ref" == .zenoforge/mac-autopilot/NODE-HEALTH.md ]] || fail 'dashboard standards did not resolve the target health document'
health_doc="$root/$health_doc_ref"
jq -n --arg sha "$deployed" '[{id:7,sha:$sha,created_at:"2026-10-24T00:00:00Z",payload:{sha:$sha,images:{"example-admin":"sha256:observed"},image_shas:{"example-admin":$sha}}}]' > "$FAKE_DEPLOYMENTS"
: > "$FAKE_DEPLOYMENT_WRITES"
: > "$FAKE_SSH_LOG"

cp "$script_dir/config.template.json" "$a/config.json"
partial_session_id="bbbbbbbb-0000-0000-0000-0000000000bb"
jq -n --arg today "$(date -u +%Y-%m-%d)" --arg sid "$partial_session_id" \
  '{date:$today,status:"partial",total:3600,fresh:1500,incomplete_sessions:[$sid]}' > "$a/budget.json"
echo '{"workers":[]}' > "$a/workers.json"
cat > "$a/units.json" <<JSON
{"units":[{"id":"pr-1","issue":555,"title":"fixture title","labels":["focus"],"stage":"repair-pending","history":[
  {"stage":"advisor-ruling","at":"$(iso '-3 hours')"},{"stage":"advisor-unavailable","at":"$(iso '-2 hours')"},
  {"stage":"advisor-unavailable","at":"$(iso '-40 hours')"}]},
 {"id":"pr-2","stage":"repair-pending","history":[{"stage":"advisor-ruling","at":"$(iso '-1 hours')"}]},
 {"id":"issue-801","issue":801,"title":"ready chain","labels":["ready-for-agent"],"stage":"blocked-external","blocked_on":802,"history":[]},
 {"id":"issue-802","issue":802,"title":"parked recut","labels":["ready-for-agent"],"stage":"parked","parked_reason":"recut-refused-unpushed","history":[]},
 {"id":"issue-803","issue":803,"title":"missing blocker","labels":["ready-for-agent"],"stage":"blocked-external","history":[]},
 {"id":"issue-804","issue":804,"title":"tracker blocker","labels":["ready-for-agent"],"stage":"blocked-external","blocked_on":900,"history":[]},
 {"id":"issue-805","issue":805,"title":"already dispatching","labels":["ready-for-agent"],"stage":"implement-pending","history":[]},
 {"id":"issue-807","issue":807,"title":"repair breaker","labels":["ready-for-agent"],"stage":"parked","parked_reason":"repair-breaker","history":[]},
 {"id":"issue-806","issue":806,"title":"missing blocker state","labels":["ready-for-agent"],"stage":"blocked-external","blocked_on":901,"history":[]}]}
JSON
mkdir -p "$AGENT_HOME/state"
printf '{"state":"tracker"}\n' > "$AGENT_HOME/state/900.json"
printf '{"rulings":[{"references":["#555"],"verbatim":"config override wording"},{"id":"nonproduct-lane-routing","references":[],"verbatim":"system lane","membership":{"labels":["pipeline-system"]}}]}\n' \
  > "$root/.zenoforge/state/rulings.json"
printf '{"rulings":[{"references":["#555"],"verbatim":"engine fallback wording"}]}\n' \
  > "$root/engine/state/rulings.json"
jq -n --arg c "$(git -C "$root" rev-parse HEAD)" --arg s "$(iso '-5 hours')" '{status:"held",candidate:$c,started_at:$s,reason:"x"}' > "$a/release-train.json"
cand9="$(git -C "$root" rev-parse --short=9 HEAD)"
{
  printf '[%s] RELEASE-HELD candidate=%s supervised release needed: example-pack\tnew migrations in packages/example-pack;example-runtime\tfleet shards roll through the image-roll API;\n' "$(iso '-3 hours')" "$cand9"
  printf '[%s] RELEASE-HELD candidate=%s supervised release needed: example-pack\tnew migrations in packages/example-pack;example-runtime\tfleet shards roll through the image-roll API;\n' "$(iso '-1 hours')" "$cand9"
} > "$a/alerts/release.md"

# triage 账：run-triage*.sh 分诊完成两张（今日），issue-pipeline.sh 的同名事件不算；昨天一张不算
{
  printf '{"record_type":"event","event_type":"stage-exited","ts":"%s","issue":11,"stage":"needs-triage","writer":"run-triage.sh"}\n' "$(iso '-30 minutes')"
  printf '{"record_type":"event","event_type":"stage-exited","ts":"%s","issue":12,"stage":"needs-triage","writer":"run-triage-batch.sh"}\n' "$(iso '-10 minutes')"
  printf '{"record_type":"event","event_type":"stage-exited","ts":"%s","issue":13,"stage":"needs-triage","writer":"issue-pipeline.sh"}\n' "$(iso '-5 minutes')"
  printf '{"record_type":"event","event_type":"stage-entered","ts":"%s","issue":11,"stage":"needs-advisor","writer":"run-triage.sh"}\n' "$(iso '-30 minutes')"
  printf '{"record_type":"event","event_type":"stage-entered","ts":"%s","issue":12,"stage":"ready-for-agent","writer":"run-triage-batch.sh"}\n' "$(iso '-10 minutes')"
  printf '{"record_type":"event","event_type":"stage-exited","ts":"%s","issue":14,"stage":"needs-triage","writer":"run-triage.sh"}\n' "$(iso '-40 hours')"
} > "$AGENT_HOME/metrics/efficiency-$(date -u +%Y-%m).jsonl"
touch "$AGENT_HOME/logs/triage-triage-batch-$(stamp '-20 minutes')-123.log"

# 顾问批处理结果：今日 1 次失败、1 次 pending；3 小时前落下 3 张裁决；昨天的失败不算今日
result() { jq -n --arg at "$(iso "$1")" --arg o "$2" --argjson applied "$3" '{recorded_at:$at,exit_code:0,outcome:$o,applied_count:$applied}' > "$AGENT_HOME/logs/advisor-batch-$(stamp "$1").result.json"; }
result '-40 hours' job-failed 0
result '-3 hours' completed 3
result '-90 minutes' job-failed 0
result '-5 minutes' pending 0

cat > "$root/engine/lib.sh" <<'LIB'
LOG_DIR="$AGENT_HOME/logs"
advisor_batch_state_read() { cat "$FRONT_BATCH_STATE"; }
advisor_batch_job_json() { advisor_batch_state_read | jq -c '.job // empty'; }
LIB
export FRONT_BATCH_STATE="$f/batch.json"
jq -n --argjson started "$(date -u -d '-45 minutes' +%s)" \
  '{deferred_issue_ids:[7],job:{job_id:"advisor-batch-J1",started_at:$started,input_bytes:2048,members:[{issue:101,input:{body:"x"}},{issue:102,input:{body:"y"}}]}}' > "$FRONT_BATCH_STATE"

printf '%s' '{"data":{"repository":{
 "a0":{"totalCount":4,"nodes":[{"number":10,"createdAt":"2025-12-01T00:00:00Z","updatedAt":"2025-12-01T00:00:00Z","labels":{"nodes":[{"name":"needs-triage"},{"name":"roadmap"}]}},{"number":11,"createdAt":"2025-12-15T00:00:00Z","updatedAt":"2025-12-15T00:00:00Z","labels":{"nodes":[{"name":"needs-triage"},{"name":"pipeline-system"}]}},{"number":9,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","labels":{"nodes":[{"name":"needs-triage"}]}},{"number":7,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-03T00:00:00Z","labels":{"nodes":[{"name":"needs-triage"}]}}]},
 "a1":{"totalCount":0,"nodes":[]},"a2":{"totalCount":2,"nodes":[{"number":5,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"__RECENT__"}]},
 "a3":{"totalCount":3,"nodes":[{"number":6,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"__RECENT__"}]},
 "a4":{"totalCount":0,"nodes":[]},"a5":{"totalCount":9,"nodes":[{"number":8,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"__RECENT__"}]},
 "a6":{"totalCount":5,"nodes":[{"number":3,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"__RECENT__"}]},
 "a7":{"totalCount":0,"nodes":[]}},
 "c0":{"issueCount":128},"c1":{"issueCount":31},"c2":{"issueCount":2},"c3":{"issueCount":3},"c4":{"issueCount":4},"c5":{"issueCount":6},
 "c6":{"issueCount":102},"c7":{"issueCount":0},"c8":{"issueCount":2},"c9":{"issueCount":3},"c10":{"issueCount":0},"c11":{"issueCount":9},"c12":{"issueCount":5},"c13":{"issueCount":0}}}' | sed "s/__RECENT__/$(iso '-2 hours')/g" > "$f/graphql.json"
# Exercise two-page triage pagination above the 100-issue GraphQL page size.
jq '.data.repository.a0.totalCount = 102
  | .data.repository.a0.pageInfo = {endCursor:"triage-cursor-1",hasNextPage:true}
  | .data.repository.a0.nodes += [range(100;196) | {number:.,title:"system lane fixture",createdAt:"2026-01-04T00:00:00Z",updatedAt:"2026-01-04T00:00:00Z",labels:{nodes:[{name:"needs-triage"},{name:"pipeline-system"}]}}]' \
  "$f/graphql.json" > "$f/graphql-page1.json"
mv "$f/graphql-page1.json" "$f/graphql.json"
jq -n '{data:{repository:{issues:{totalCount:102,nodes:([196,197] | map({number:.,title:"system lane fixture",createdAt:"2026-01-05T00:00:00Z",updatedAt:"2026-01-05T00:00:00Z",labels:{nodes:[{name:"needs-triage"},{name:"pipeline-system"}]}})),pageInfo:{endCursor:"triage-cursor-2",hasNextPage:false}}}}}' \
  > "$f/graphql-page2.json"
printf '{"switches":{"roadmap-order":true}}\n' > "$AGENT_HOME/model-policy.json"
export MODEL_POLICY_FILE="$AGENT_HOME/model-policy.json"
jq -n '[8,801,802,803,804,805,806,807,808] | map({number:.})' > "$f/ready-issues.json"
cat > "$f/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1 $2" == "api graphql" ]]; then
  echo graphql >> "$FAKE_GH_LOG"
  if [[ -n "${FAKE_GH_FAIL:-}" ]]; then echo 'HTTP 502: bad gateway' >&2; exit 1; fi
  if [[ -n "${FAKE_GRAPHQL_ZEN:-}" && " $* " == *"owner=ZenoWangzy"* ]]; then cat "$FAKE_GRAPHQL_ZEN"
  elif [[ -n "${FAKE_GRAPHQL_OTHER:-}" && " $* " == *"owner=example-maintainer"* ]]; then cat "$FAKE_GRAPHQL_OTHER"
  elif [[ " $* " == *"after=triage-cursor-1"* ]]; then cat "$FAKE_GRAPHQL_PAGE2"; else cat "$FAKE_GRAPHQL"; fi
elif [[ "$1 $2" == "issue list" && " $* " == *" --label ready-for-agent "* ]]; then
  echo issue-list >> "$FAKE_GH_LOG"
  cat "$FAKE_READY_ISSUES"
elif [[ "$1 $2" == "issue list" ]]; then
  echo '[]'
elif [[ "$1 $2" == "api repos/"* ]]; then
  case "$2" in
    repos/*/deployments\?environment=production\&per_page=20) cat "$FAKE_DEPLOYMENTS" ;;
    repos/*/deployments/8/statuses)
      echo 'status' >> "$FAKE_DEPLOYMENT_WRITES"
      echo '[]' ;;
    repos/*/deployments/*/statuses) echo '[{"state":"success","created_at":"2026-10-24T00:00:00Z"}]' ;;
    repos/*/deployments)
      cat > "$FAKE_DEPLOYMENT_WRITES.body"
      echo 'create' >> "$FAKE_DEPLOYMENT_WRITES"
      echo '{"id":8}' ;;
    *) echo "unexpected fake gh API call: $*" >&2; exit 2 ;;
  esac
elif [[ "$1 $2" == "api --paginate" && " $* " == *"/actions/runners?per_page=100 "* ]]; then
  echo runner >> "$FAKE_GH_LOG"
  echo '{"runners":[{"name":"fixture","status":"online","busy":false,"labels":[{"name":"cihost-ci"}]}]}'
elif [[ "$1 $2" == "api search/issues" ]]; then
  printf '%s\n' "$*" >> "$FAKE_PR_LOG"
  [[ " $* " != *" --slurp "* || " $* " != *" --jq "* ]] || { echo 'the --slurp option is not supported with --jq' >&2; exit 1; }
  jq -c '.[] | {number,mergedAt:.mergedAt}' "${FAKE_PR_JSON:-/dev/null}"
elif [[ "$1 $2" == "pr list" ]]; then
  printf '%s\n' "$*" >> "$FAKE_PR_LOG"; cat "${FAKE_PR_JSON:-/dev/null}"
elif [[ "$1 $2" == "api --paginate" && " $* " == *"/issues?state=open&per_page=100 "* ]]; then
  echo '[[]]'  # --slurp of one empty page: no open issues, so no intake labels to read
else echo '[]'; fi
GH
cat > "$f/bin/ssh" <<SH
#!/usr/bin/env bash
echo inspected >> "\$FAKE_SSH_LOG"
# fields: running digest, image ref, image revision label, compose config_files (overlay dir names are not a revision)
echo "\${FAKE_OBSERVED_IMAGE:-sha256:observed} reg/example-admin:live \${FAKE_OBSERVED_REV:-\${FAKE_OBSERVED_SHA:-$deployed}} /srv/app/releases/\${FAKE_OBSERVED_DIR:-main-\${FAKE_OBSERVED_SHA:-$deployed}}/compose.yml"
SH
cat > "$f/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *list-units*zf-triage-batch*.service*) echo "zf-triage-batch-owner-one.service loaded active running triage"; echo "zf-triage-batch-owner-two.service loaded active running triage" ;;
  *zf-web-advisor-provider-*) echo "zf-web-advisor-provider-advisor-batch-J1.service loaded active running advisor" ;;
esac
SH
chmod +x "$f/bin/gh" "$f/bin/ssh" "$f/bin/systemctl"
export FAKE_GH_LOG="$f/gh.log" FAKE_GRAPHQL="$f/graphql.json" FAKE_GRAPHQL_PAGE2="$f/graphql-page2.json" FAKE_READY_ISSUES="$f/ready-issues.json"; : > "$FAKE_GH_LOG"
export FAKE_OBSERVED_SHA="$deployed" FAKE_OBSERVED_IMAGE=sha256:observed
export PATH="$f/bin:$PATH"
front() { sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -c '.front'; }
run() { python3 "$script_dir/gen_dashboard.py"; }

scorecard_sampled_at="$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
pause_since="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg sampled_at "$scorecard_sampled_at" \
  '{generated:$sampled_at,generated_at:$sampled_at,source_commit:"a1b2c3d4e5f6",paused:null,metrics:[]}' > "$a/node-health.json"
jq -n --arg timestamp "$pause_since" \
  '{reason:"refactor",caller:"operator",issue:"none",provider:"none",model:"none",timestamp:$timestamp}' > "$AGENT_HOME/PAUSE"

# 1. 全部可用：阶段计数 / 滞留 / 顾问 / triage / 发布；每个数字都有标准和状态
run
[[ $(grep -c '^runner$' "$FAKE_GH_LOG") == 1 ]] || fail 'dashboard did not make one keyed runner read'
run
[[ $(grep -c '^runner$' "$FAKE_GH_LOG") == 1 ]] || fail 'dashboard refetched runners before the shared five-minute TTL'
out="$(front)"
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e \
  '.front.fetched_at == .front.github.fetched_at
   and (.repo_sections | length == 1 and .[0].fetched_at == .front.github.fetched_at and .[0].factory_live != null)
   and (.source_freshness.units.fetched_at != null)
   and (.front.advisor.fetched_at | type) == "string"
   and (.front.advisor_loop.fetched_at == .source_freshness.units.fetched_at)
   and (.front.triage.fetched_at | type) == "string"
   and (.front.release.fetched_at | type) == "string"
   and (.live_workers.fetched_at | type) == "string"
   and (.traffic.fetched_at | type) == "string"
   and (.release_train.fetched_at | type) == "string"
   and (.standards.fetched_at | type) == "string"' >/dev/null \
  || fail 'panel fetch times were missing or did not match their source reads'
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | \
  jq -e '.founder_reqs.items | any(.[]; .issue == 555 and .text == "config override wording" and .from_ruling == true)' \
  >/dev/null || fail 'dashboard rulings reader did not use target config'
jq -e --arg sha "$deployed" '.[0].sha == $sha and .[0].payload.images["example-admin"] == "sha256:observed"' "$FAKE_DEPLOYMENTS" >/dev/null \
  || fail 'dashboard fixture has no production Deployment record'
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e --arg sid "$partial_session_id" \
  '.cost.budget_status=="partial" and .cost.budget_incomplete_sessions==[$sid] and .summary.real_daily_tokens==3600' >/dev/null \
  || fail 'partial daily usage or incomplete sessions did not reach dashboard data'
[[ ! -e "$a/deployed.json" ]] || fail 'dashboard recreated host-local deployed.json'
cp "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" "$f/out-success.js"
jq -e '.errors == {}
  and ([.stages[] | {(.label): .count}] | add) == {"needs-triage":2,"finish-first":0,"needs-info":2,"needs-advisor":3,"needs-recut":0,"ready-for-agent":9,"awaiting-release":5,"awaiting-pipeline-sync":0}
  and (.stages[0].idle_hours > 24 and .stages[0].oldest.number == 9)
  and (.stages[1].idle_hours == 0) and (.stages[2].idle_hours > 1.9 and .stages[2].idle_hours < 2.2)
  and .github.cached == true' <<<"$out" >/dev/null || fail "stage rows wrong: $(jq -c '{errors, stages, github}' <<<"$out")"
jq -e '(.stages[0].excluded | map({key, name, count}) == [{"key":"session_owned","name":"会话持有","count":0},{"key":"system","name":"系统通道","count":99},{"key":"roadmap","name":"路线图排序","count":1},{"key":"on_hold","name":"暂停中","count":0},{"key":"model_backoff","name":"模型退避","count":0},{"key":"retry_deferred","name":"等待刷新","count":0},{"key":"scheduler_inflight","name":"调度器处理中","count":0}])
  and (.stages[0].excluded | all(.tooltip | contains("不计入待分诊")))' <<<"$out" >/dev/null \
  || fail "excluded triage figures wrong: $(jq -c '.stages[0] | {count, oldest, excluded}' <<<"$out")"
# triage_split.py: with roadmap-order off, a roadmap-labelled ticket is eligible again
printf '{"switches":{"roadmap-order":false}}\n' > "$f/model-policy-off.json"
MODEL_POLICY_FILE="$f/model-policy-off.json" PYTHONPATH="$script_dir" python3 -c '
import triage_split as t
field = t.graphql_stage_fields([("needs-triage",)])
expected = "a0:issues(states:OPEN,labels:[\"needs-triage\"],first:100,orderBy:{field:UPDATED_AT,direction:ASC}){totalCount nodes{number title createdAt updatedAt labels(first:100){nodes{name}}} pageInfo{endCursor hasNextPage}}"
assert field == expected, field
row = t.stage("needs-triage", {"totalCount": 1, "nodes": [{"number": 10, "updatedAt": "2025-12-01T00:00:00Z", "labels": {"nodes": [{"name": "needs-triage"}, {"name": "roadmap"}]}}]})
assert row["count"] == 1 and all(item["count"] == 0 for item in row["excluded"]), row
' || fail 'roadmap switch off did not count the roadmap ticket as eligible'
ZF_PIPELINE_ROADMAP_SWITCH=true MODEL_POLICY_FILE="$f/model-policy-off.json" PYTHONPATH="$script_dir" python3 -c '
import triage_split as t
row = t.stage("needs-triage", {"totalCount": 1, "nodes": [{"number": 10, "updatedAt": "2025-12-01T00:00:00Z", "labels": {"nodes": [{"name": "needs-triage"}, {"name": "roadmap"}]}}]})
assert row["count"] == 0 and {item["key"]: item["count"] for item in row["excluded"]}["roadmap"] == 1, row
' || fail 'pipeline roadmap override did not take precedence over model-policy'
mkdir -p "$AGENT_HOME/state"
jq -n --argjson until "$(( $(date +%s) + 3600 ))" '{model_failure_backoff:{until_epoch:$until}}' > "$AGENT_HOME/state/1004.json"
jq -n --argjson until "$(( $(date +%s) + 3600 ))" '{triage_retry_after_epoch:$until}' > "$AGENT_HOME/state/1005.json"
PYTHONPATH="$script_dir" python3 - "$script_dir/triage-fixture.json" <<'PY' || fail 'dashboard triage count did not use the shared eligibility filter'
import json, sys, triage_split as t
issues = json.load(open(sys.argv[1], encoding="utf-8"))
nodes = [{**issue, "labels": {"nodes": issue["labels"]}} for issue in issues]
row = t.stage("needs-triage", {"totalCount": len(nodes), "nodes": nodes})
counts = {item["key"]: item["count"] for item in row["excluded"]}
assert row["count"] == 2, row
assert counts == {"session_owned": 1, "system": 1, "on_hold": 1, "model_backoff": 1, "retry_deferred": 1, "scheduler_inflight": 1, "roadmap": 0}, counts
PY
BATCH_MARKER_HOME="$f/triage-batch-marker-home"
mkdir -p "$BATCH_MARKER_HOME"
jq -n '{issues:[901]}' > "$BATCH_MARKER_HOME/triage-batch-active.json"
jq -n '{issues:[902]}' > "$BATCH_MARKER_HOME/triage-batch-active-owner-one.json"
jq -n '{issues:[903]}' > "$BATCH_MARKER_HOME/triage-batch-active-owner-stale.json"
PYTHONPATH="$script_dir" AGENT_HOME="$BATCH_MARKER_HOME" ZF_UNIT_PREFIX=zf python3 - <<'PY' || fail 'triage split did not read all active batch markers'
from types import SimpleNamespace
import subprocess
import triage_split as t
def fake_run(args, **kwargs):
    assert args[-1] == "zf-triage-batch*.service", args
    return SimpleNamespace(returncode=0, stdout="zf-triage-batch.service loaded active running x\nzf-triage-batch-owner-one.service loaded active running x\n")
subprocess.run = fake_run
assert t._active_batch_ids() == {901, 902}
PY
jq -e '.search_counts.issues_open == 128 and .search_counts.issues_closed == 31
  and .search_counts.prs_open == 2 and .search_counts.prs_merged == 3 and .search_counts.prs_closed_unmerged == 4
  and .search_counts.stages["needs-triage"] == 102 and .search_counts.stages["awaiting-release"] == 5' <<<"$out" >/dev/null \
  || fail "cached repository search counts wrong: $(jq -c '.search_counts' <<<"$out")"
jq -e '.ready_queue.total == 9 and .ready_queue.dispatchable == 2 and .ready_queue.active == 1 and .ready_queue.held == 6
  and ([.ready_queue.classes[] | {key, value: .count}] | from_entries) == {"chain-on-ready-issue":1,"recut-refused-unpushed":1,"no-blocker-recorded":1,"tracker":1,"blocker-state-unavailable":1,"repair-breaker":1}' <<<"$out" >/dev/null \
  || fail "ready queue split wrong: $(jq -c '.ready_queue' <<<"$out")"
jq -e '.values["ready_queue.dispatchable"] == 2 and .status["ready_queue.dispatchable"] == "OK"
  and .standards["ready_queue.dispatchable"].desc == "待实现可派发票数量"' <<<"$out" >/dev/null \
  || fail "dispatchable headline metric is missing: $(jq -c '{values,status,standards}' <<<"$out")"
jq -e '.status["stage.needs-triage.count"] == "OK" and .status["stage.needs-triage.idle_hours"] == "UNHEALTHY"
  and .status["stage.needs-advisor.count"] == "OK" and .status["stage.finish-first.count"] == "OK"' <<<"$out" >/dev/null \
  || fail "stage status wrong: $(jq -c '.status' <<<"$out")"
jq -e '.advisor.job.job_id == "advisor-batch-J1" and .advisor.job.members == [101,102] and .advisor.job.worker_active == true
  and .advisor.job.age_min > 44 and .advisor.job.age_min < 47 and .advisor.deferred == [7]
  and .advisor.failures_today == 1 and .advisor.applied_today == 3 and .advisor.ticks_today == 3
  and .advisor.last_outcome == "pending" and .advisor.last_ruling_applied == 3 and .advisor.waiting == 3
  and (.values["advisor.ruling_lag_hours"] > 2.9 and .values["advisor.ruling_lag_hours"] < 3.2)
  and .status["advisor.job_age_min"] == "WARN" and .status["advisor.failures_today"] == "OK"
  and .advisor_loop.rulings_today == 2 and .advisor_loop.unavailable_today == 1 and .values["advisor_loop.fail_pct_today"] == 33
  and .status["advisor_loop.fail_pct_today"] == "WARN"' <<<"$out" >/dev/null || fail "advisor panel wrong: $(jq -c '{advisor, advisor_loop, values}' <<<"$out" | cut -c1-1500)"
jq -e '.triage.done_today == 2 and .triage.running == true and .triage.backlog == 2
  and .triage.routed_today == {"needs-advisor":1,"ready-for-agent":1}
  and .values["triage.last_done_age_min"] >= 9 and .values["triage.last_done_age_min"] <= 12
  and .status["triage.last_done_age_min"] == "OK" and .status["triage.done_today"] == "UNHEALTHY"
  and (.triage.last_batch_at | length) > 0' <<<"$out" >/dev/null || fail "triage panel wrong: $(jq -c '{triage, values}' <<<"$out")"
jq -e '.release.held == true and .release.held_since != null and .release.awaiting_release == 5
  and (.release.held_images | map(.image) | sort) == ["example-pack","example-runtime"]
  and .release.main_ahead_commits == 1 and .release.prod_sha == "'"${deployed:0:12}"'"
  and (.values["release.hold_hours"] > 2.9 and .values["release.hold_hours"] < 3.2) and .status["release.hold_hours"] == "WARN"
  and (.values["release.main_ahead_hours"] > 4.9 and .values["release.main_ahead_hours"] < 5.1) and .status["release.main_ahead_hours"] == "OK"' <<<"$out" >/dev/null \
  || fail "release panel wrong: $(jq -c '{release, values}' <<<"$out")"
# 每个数字都有健康线、不健康线、含义和来源，状态都落在已知取值内；每条标准在 NODE-HEALTH.md 里有记录
jq -e '[.standards[] | select((.healthy|type) != "number" or (.unhealthy|type) != "number" or (.meaning|length) < 10 or (.source|length) < 3)] == []
  and ([.status[] | select(. != "OK" and . != "WARN" and . != "UNHEALTHY" and . != "NO-DATA" and . != "N/A")] == [])
  and (.standards | keys) == (.status | keys) and (.elapsed_s < 5)' <<<"$out" >/dev/null || fail "standards incomplete: $(jq -c '.standards | keys' <<<"$out")"
while IFS= read -r id; do
  key="${id%.count}"; key="${key%.idle_hours}"
  grep -Fq "\`$key" "$health_doc" || fail "NODE-HEALTH.md lacks front standard $id"
done < <(jq -r '.standards | keys[]' <<<"$out")
# 整个看板数据仍是完整的
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e '.units | length == 9' >/dev/null || fail "dashboard lost its units"
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e \
  --arg sampled_at "$scorecard_sampled_at" --arg pause_since "$pause_since" \
  '.standards.generated_at == $sampled_at and .standards.source_commit == "a1b2c3d4e5f6"
   and .standards.paused == null
   and .engine_live.pin == "6da8c7285e8b"
   and .pipeline_pauses.vecta_line.paused and (.pipeline_pauses.vecta_line.since == $pause_since)
   and (.pipeline_pauses.zenoforge_factory.paused == false)
   and (.pipeline_pauses.vecta_line.fetched_at | type) == "string"' >/dev/null \
  || fail 'dashboard did not report the independent current VectA and Zenoforge pause states'

# 2. 5 分钟缓存：再跑一次不再调 GitHub
cache="$MAC_AUTOPILOT_DASHBOARD_OUTPUT"; cache="$(dirname "$cache")/front-cache.json"
github_reads_before_cached_run="$(wc -l < "$FAKE_GH_LOG")"
run
[[ "$(wc -l < "$FAKE_GH_LOG")" == "$github_reads_before_cached_run" ]] || fail "GitHub reads repeated inside the cache window: $(cat "$FAKE_GH_LOG")"
front | jq -e '.github.cached == true and .github.stale == false and .stages[5].count == 9 and .search_counts.issues_open == 128' >/dev/null || fail "cached run not marked cached"

# A pre-split cache must be refreshed instead of restoring its raw needs-triage count.
jq '(.github.stages) |= map(if .label == "needs-triage" then .excluded |= map(select(.key != "session_owned")) else . end)' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
github_reads_before_split_refresh="$(wc -l < "$FAKE_GH_LOG")"
run
front | jq -e '.github.cached == false and .stages[0].count == 2 and (.stages[0].excluded | length == 7)' >/dev/null \
  || fail "pre-split cache kept the raw needs-triage count: $(front | jq -c '{github, stage: .stages[0]}')"
[[ "$(wc -l < "$FAKE_GH_LOG")" == "$((github_reads_before_split_refresh + 3))" ]] || fail "pre-split cache was not refreshed: $(cat "$FAKE_GH_LOG")"

# 3. 缓存过期而 GitHub 失败：沿用旧缓存并标明失败原因（最长 30 分钟）
[[ -s "$cache" ]] || fail "front cache file not written next to dashboard.data.js"
jq --argjson t "$(( $(date +%s) - 600 ))" '.github.fetched_epoch = $t' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
FAKE_GH_FAIL=1 run
front | jq -e '.github.stale == true and (.github.error | contains("502")) and .errors == {} and .stages[5].count == 9
  and .ready_queue.dispatchable == 2 and .ready_queue.held == 6 and .values["ready_queue.dispatchable"] == 2' >/dev/null \
  || fail "stale cache fallback wrong: $(front | jq -c '{github, errors, ready_queue, dispatchable_value: .values["ready_queue.dispatchable"]}')"

# 4. 缓存也太旧且 GitHub 失败：只有阶段块"数据不可用"，顾问 / triage / 发布与整页数据照常
jq --argjson t "$(( $(date +%s) - 4000 ))" '.github.fetched_epoch = $t' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
FAKE_GH_FAIL=1 run
out="$(front)"
jq -e '(.errors | keys) == ["stages"] and (.errors.stages | contains("502")) and .stages == [] and .search_counts == null
  and .advisor.job.job_id == "advisor-batch-J1" and .triage.done_today == 2 and .release.held == true' <<<"$out" >/dev/null \
  || fail "GitHub failure leaked beyond the stage block: $(jq -c '{errors, stages}' <<<"$out")"
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e '.units | length == 9' >/dev/null || fail "GitHub failure broke the dashboard"
node - "$script_dir/dashboard.html" "$f/out-success.js" "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" <<'JS' || fail "intake totals partition or unread rendering was wrong"
const fs = require("fs"), vm = require("vm");
const [htmlPath, successPath, failedPath] = process.argv.slice(2), src = fs.readFileSync(htmlPath, "utf8");
const inline = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
function render(dataPath) {
  const raw = fs.readFileSync(dataPath, "utf8").replace(/^window\.DASH=/, "").replace(/;\s*$/, ""), D = JSON.parse(raw);
  const el = () => ({innerHTML:"",textContent:"",classList:{add(){},remove(){},contains(){return false}},style:{},addEventListener(){},setAttribute(){},removeAttribute(){},appendChild(){},remove(){},dataset:{}});
  const els = {}, storage = {getItem(){return null},setItem(){}}, document = {getElementById:id => els[id] ||= el(),addEventListener(){},createElement:el,head:el(),documentElement:el(),title:""};
  const ctx = {document,localStorage:storage,sessionStorage:storage,setInterval(){},setTimeout(){},innerWidth:1440,innerHeight:900,location:{reload(){}},console,Date,Math,JSON,Number,String,Object,Array,Set,encodeURIComponent};
  ctx.window = ctx; ctx.scrollTo = () => {}; ctx.DASH = D; vm.createContext(ctx); vm.runInContext(inline[0], ctx, {filename:"dashboard.html"});
  return ctx.__dash.MODULES.find(m => m.id === "intake").render(D);
}
const good = render(successPath), bad = render(failedPath), cells = [...good.matchAll(/<div class="ts-m" data-total="([^"]+)" title="([^"]*)"><span>[^<]*<\/span><b>([^<]*)<\/b><\/div>/g)];
const values = new Map(cells.map(([,id,tip,value]) => [id,{tip,value}]));
const stages = ["needs-triage","finish-first","needs-info","needs-advisor","needs-recut","ready-for-agent","awaiting-release","awaiting-pipeline-sync"];
const open = values.get("issues.open"), stageTotal = stages.reduce((n,label) => n + Number(values.get(`tickets.${label}`).value), 0) + Number(values.get("tickets.unclassified").value);
if (!open || stageTotal !== Number(open.value) || values.get("tickets.unclassified").value !== "7") throw new Error("stage buckets do not add to open issues");
if (values.get("requirements.total").value !== "1" || values.get("requirements.提出").value !== "1") throw new Error("founder requirement ledger counts were not rendered");
if (!good.includes("Issue 与 PR 共用同一编号序列") || !good.includes("#5975")) throw new Error("shared issue/PR sequence explanation was not rendered");
if (!good.includes("待分诊标签") || !good.includes("路线图排序 1") || !good.includes("系统通道 99") || !good.includes('title="带 roadmap / roadmap-theme / roadmap-epic 标签') || !good.includes('title="带系统通道标签')) throw new Error("triage exclusions were not shown with their Chinese tooltips");
if (cells.some(([, , tip]) => !tip)) throw new Error("a total has no source tooltip");
const failedOpen = bad.match(/<div class="ts-m" data-total="issues\.open" title="([^"]*)"><span>[^<]*<\/span><b>([^<]*)<\/b><\/div>/);
if (!failedOpen || failedOpen[2] !== "未读取" || !failedOpen[1].includes("HTTP 502")) throw new Error(failedOpen && failedOpen[0]);
JS

# 5. lib.sh 读不了：只有顾问批处理块失败，错误带原因
rm -f "$cache"; mv "$root/engine/lib.sh" "$root/engine/lib.sh.off"
run
out="$(front)"
jq -e '(.errors | keys) == ["advisor"] and (.errors.advisor | length) > 5 and .advisor == null
  and (.stages | length) == 8 and .triage.done_today == 2 and .release.held == true
  and (.standards | has("advisor.job_age_min") | not)' <<<"$out" >/dev/null || fail "lib.sh failure leaked beyond the advisor block: $(jq -c '{errors}' <<<"$out")"

# 6. 没有批处理任务 + 没有积压：对应数字不判，不是红也不是绿
mv "$root/engine/lib.sh.off" "$root/engine/lib.sh"
echo '{}' > "$FRONT_BATCH_STATE"; rm -f "$cache"
jq '.data.repository.a3 = {"totalCount":0,"nodes":[]} | .data.repository.a0 = {"totalCount":0,"nodes":[]}' "$f/graphql.json" > "$f/graphql.new" && mv "$f/graphql.new" "$f/graphql.json"
run
front | jq -e '.errors == {} and .advisor.job == null and .values["advisor.job_age_min"] == 0 and .status["advisor.job_age_min"] == "OK"
  and .status["advisor.ruling_lag_hours"] == "N/A" and .status["triage.done_today"] == "N/A" and .status["triage.last_done_age_min"] == "N/A"' >/dev/null \
  || fail "idle front not handled: $(front | jq -c '{errors, status}')"
[[ "$(wc -l < "$FAKE_SSH_LOG")" == 1 ]] || fail 'dashboard rendered more than one host reconciliation inside the low-cadence interval'

# A low-cadence host observation that differs from the recorded digest/revision creates a shared reconciliation Deployment.
rm -f "$a/production-reconciliation-checked"
FAKE_OBSERVED_IMAGE=sha256:hotpatch FAKE_OBSERVED_SHA="$main" run
jq -e --arg sha "$main" '.ref == $sha and .payload.sha == $sha
  and .payload.images["example-admin"] == "sha256:hotpatch"
  and .payload.image_shas["example-admin"] == $sha and .payload.reconciled == true' \
  "$FAKE_DEPLOYMENT_WRITES.body" >/dev/null || fail 'host drift was not recorded with its observed digest and source SHA'
grep -Fxq create "$FAKE_DEPLOYMENT_WRITES" && grep -Fxq status "$FAKE_DEPLOYMENT_WRITES" \
  || fail 'host reconciliation Deployment did not receive a success status'

# 11-19: a rollback overlay dir carries the rolled-back SHA (rollback-6361-<new>) while the container runs the old image.
# The observed source is the image's revision label, never the overlay dir name.
jq -n --arg sha "$main" '[{id:9,sha:$sha,created_at:"2026-10-24T00:00:00Z",payload:{sha:$sha,images:{"example-admin":"sha256:new"},image_shas:{"example-admin":$sha}}}]' > "$FAKE_DEPLOYMENTS"
: > "$FAKE_DEPLOYMENT_WRITES"; rm -f "$a/production-reconciliation-checked" "$FAKE_DEPLOYMENT_WRITES.body"
FAKE_OBSERVED_DIR="rollback-6361-$main" FAKE_OBSERVED_REV="$deployed" FAKE_OBSERVED_IMAGE=sha256:old run
jq -e --arg old "$deployed" '.ref == $old and .payload.image_shas["example-admin"] == $old and .payload.images["example-admin"] == "sha256:old"' \
  "$FAKE_DEPLOYMENT_WRITES.body" >/dev/null || fail "rollback overlay read as the new SHA: $(cat "$FAKE_DEPLOYMENT_WRITES.body" 2>/dev/null)"
# An image without a revision label is not reconciled at all.
: > "$FAKE_DEPLOYMENT_WRITES"; rm -f "$a/production-reconciliation-checked"
FAKE_OBSERVED_REV='<no value>' FAKE_OBSERVED_IMAGE=sha256:other run
[[ ! -s "$FAKE_DEPLOYMENT_WRITES" ]] || fail "unlabelled image produced a Deployment: $(cat "$FAKE_DEPLOYMENT_WRITES")"

# 7. 看板页面把前段拆进入口 / 顾问 / 发布三个模块渲染，且每块都有"数据不可用"分支（逐模块渲染见 dashboard-modules.test.sh）
for m in intake advisor release; do grep -Fq "{id:\"$m\"" "$script_dir/dashboard.html" || fail "dashboard.html has no $m module for the front"; done
[[ "$(grep -c '数据不可用' "$script_dir/dashboard.html")" -ge 1 ]] || fail "no unavailable state in dashboard.html"
# 8. 看板数字的三个口径：今日完成按合并时间检索（不被 --limit 截掉）；套件只认配置的 Pipeline suites；额度按 LA 日归属会话
export FAKE_PR_LOG="$f/pr-list.log" FAKE_PR_JSON="$f/merged-prs.json"; : > "$FAKE_PR_LOG"
la_today="$(TZ=America/Los_Angeles date +%F)"
la_yesterday="$(TZ=America/Los_Angeles date -d "$la_today -1 day" +%F)"
utc_of() { date -u -d "@$(TZ=America/Los_Angeles date -d "$1" +%s)" +%Y-%m-%dT%H:%M:%SZ; } # an LA wall-clock time as UTC
la_midnight_utc="$(utc_of "$la_today 00:00")"
jq -n --arg today_early "$(utc_of "$la_today 00:01")" \
  --arg yesterday "$(utc_of "$la_yesterday 12:00")" \
  '[{number:3,mergedAt:$today_early},{number:4,mergedAt:$yesterday}]' > "$FAKE_PR_JSON"
jq -n '{schema:1,main_runs:{"Pipeline suites":[{databaseId:1,status:"completed",conclusion:"success"}],CI:[{databaseId:2,status:"completed",conclusion:"failure"}]}}' \
  > "$a/pr-run-snapshot.json"
codex="$f/codex-block"; mkdir -p "$codex"
gen_block() { # extra env, then config main_workflow, then the codex root
  env TZ=Asia/Shanghai SESSION_TZ=America/Los_Angeles CODEX_SESSIONS_DIR="$codex" MAC_AUTOPILOT_COST_CACHE="$f/cost-block.json" \
    MAC_AUTOPILOT_DASHBOARD_OUTPUT="$f/out-block.js" python3 "$script_dir/gen_dashboard.py"
}
block_out() { sed 's/^window.DASH=//; s/;$//' "$f/out-block.js"; }
cp "$a/config.json" "$f/config.saved.json"
gen_block >/dev/null
grep -Fq -- 'api search/issues' "$FAKE_PR_LOG" && grep -Fq -- "merged:>=$la_midnight_utc" "$FAKE_PR_LOG" \
  || fail "merged-today census did not query the REST search endpoint by merge time: $(cat "$FAKE_PR_LOG")"
block_out | jq -e '.totals.merged_today == [3]' >/dev/null || fail "merged-today census wrong: $(block_out | jq -c .totals.merged_today)"
# 8b. 套件：配置的是 Pipeline suites 才取它的结果；配成 CI 时 套件 为未知，不复用 CI 的结果
block_out | jq -e '.totals.suites == "success" and .totals.ci == "failure"' >/dev/null || fail "suites verdict wrong: $(block_out | jq -c '.totals | {suites, ci}')"
jq '.merge_gate.main_workflow = "CI"' "$f/config.saved.json" > "$a/config.json"
gen_block >/dev/null
block_out | jq -e '.totals.suites == "unknown" and .totals.ci == "failure"' >/dev/null \
  || fail "suites shown for a CI-configured main: $(block_out | jq -c '.totals | {suites, ci}')"
cp "$f/config.saved.json" "$a/config.json"
# 8c. 额度：Codex 目录按宿主时区（Asia/Shanghai）命名，会话归属看 LA 日；LA 今天 23:30 的会话落在宿主的下一天目录里也要算
codex_session() { # LA day, LA clock, id: one rollout of 1M input + 1M output on gpt-6-luna, filed under the host-local dir
  local epoch host_dir host_stamp
  epoch="$(TZ=America/Los_Angeles date -d "$1 $2" +%s)"
  host_dir="$codex/$(TZ=Asia/Shanghai date -d "@$epoch" +%Y/%m/%d)"; host_stamp="$(TZ=Asia/Shanghai date -d "@$epoch" +%Y-%m-%dT%H-%M-%S)"
  mkdir -p "$host_dir"
  printf '%s\n' '{"type":"turn_context","payload":{"model":"gpt-6-luna"}}' \
    '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":1000000}}}}' \
    > "$host_dir/rollout-$host_stamp-$3.jsonl"
}
codex_session "$la_today" 08:00 aaaaaaaa-0000-0000-0000-00000000000a
codex_session "$la_today" 23:30 aaaaaaaa-0000-0000-0000-00000000000c
codex_session "$la_yesterday" 23:00 aaaaaaaa-0000-0000-0000-00000000000b
codex_session "$(TZ=America/Los_Angeles date -d "$la_today -2 days" +%F)" 12:00 aaaaaaaa-0000-0000-0000-00000000000d
gen_block >/dev/null
block_out | jq -e '.cost.today.sessions == 2 and .cost.today.billable == 4000000 and .cost.yesterday.sessions == 1' >/dev/null \
  || fail "codex sessions not attributed to the LA day: $(block_out | jq -c '{today: .cost.today, yesterday: .cost.yesterday}')"
# 8d. 员工标题：没有 issue 的行不查 "None"；标题缓存里 issue 为空的单元不成为 None 键
python3 - "$script_dir" <<'CHECK' || fail 'fill_titles gave an issue-less card another unit title'
import sys
sys.path.insert(0, sys.argv[1]); import dashboard_titles
rows = [{"issue": None, "task": "fs-triage-default"}, {"issue": 555, "task": "opt-i555"}]
dashboard_titles.fill_titles(rows, {None: "title of an issue-less unit", 555: "Real issue title"}, "/nonexistent/titles.json",
                             lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("offline")))
assert rows[0]["task"] == "fs-triage-default", rows
assert rows[1]["task"] == "Real issue title", rows
print("dashboard fill_titles skips issue-less cards: PASS")
CHECK
# 8e. 首评通过率只有一个计算：看板 efficiency.review_first_pass 读 node-health.json 里 node_health 的同一个值。
# Fixture: live approve; blocked-then-approved (first verdict counts); archived approve; expected 2 approved of 3 counted.
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$a/units.json" <<JSON
{"units":[{"id":"fp-live","stage":"merged","history":[{"stage":"review-approve","at":"$(iso '-2 hours')"}]},
 {"id":"fp-blocked","stage":"repair-pending","history":[{"stage":"review-block","at":"$(iso '-3 hours')"},{"stage":"review-approve","at":"$(iso '-1 hours')"}]}]}
JSON
printf '%s\n' "{\"units\":[{\"id\":\"fp-archived\",\"stage\":\"closed\",\"history\":[{\"stage\":\"review-approve\",\"at\":\"$(iso '-10 hours')\"}]}]}" > "$a/units-archive.json"
: > "$f/audit.jsonl"
python3 "$script_dir/node_health.py" --runtime "$a" --audit "$f/audit.jsonl" --hours 5 --now "$now" --json "$a/node-health.json" >/dev/null \
  || fail "node_health --json failed"
jq -e '(.metrics | length > 0) and (.metrics | all(has("value_1h") and has("trend_1h") and has("short_window"))) and (.trend_metrics | type == "array")' "$a/node-health.json" >/dev/null \
  || fail "node_health scorecard omitted short-window fields or trend panel data"
run >/dev/null
dash_fp="$(sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -c '.efficiency.review_first_pass')"
nh_fp="$(jq -c '.metrics[] | select(.id == "review.first_pass_pct") | .value' "$a/node-health.json")"
[[ "$nh_fp" != "null" && -n "$nh_fp" ]] || fail "node_health emitted no review.first_pass_pct"
[[ "$dash_fp" == "$nh_fp" ]] || fail "dashboard first_pass $dash_fp differs from node_health $nh_fp"
python3 -c 'import sys; assert abs(float(sys.argv[1]) - 100 * 2 / 3) < 1e-6, sys.argv[1]' "$nh_fp" \
  || fail "first_pass $nh_fp is not 2 of 3 counted"
echo "dashboard first_pass equals node_health on one fixture: PASS"

# The generator keeps 30-day standards in a separate trend-panel data list.
cat > "$a/node-health.json" <<'JSON'
{"generated":"2026-11-07T12:00:00Z","metrics":[{"id":"delivery.revert_rate_30d_pct","node":"delivery","desc":"revert rate 30 d","meaning":"reverts","value":12,"value_1h":4,"trend_1h":{"delta":-2,"direction":"down"},"short_window":"1h","healthy":5,"unhealthy":10,"higher_is_better":false,"status":"UNHEALTHY","source":"release records"}],"trend_metrics":[{"id":"delivery.revert_rate_30d_pct","node":"delivery","desc":"revert rate 30 d","meaning":"reverts","value":12,"value_1h":4,"trend_1h":{"delta":-2,"direction":"down"},"short_window":"1h","healthy":5,"unhealthy":10,"higher_is_better":false,"status":"UNHEALTHY","source":"release records"}]}
JSON
run >/dev/null
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e '.standards.trend_metrics | length == 1 and .[0].id == "delivery.revert_rate_30d_pct" and .[0].value > .[0].unhealthy' >/dev/null \
  || fail "30-day metric did not reach the dashboard trend-panel data"

# Traffic trend: three readable day files reach traffic.days; the malformed day and the missing day drop out, nothing raises.
traffic_day() { date -u -d "-$1 days" +%Y-%m-%d; }
traffic_row() { jq -cn --argjson rx "$1" --argjson tx "$2" --argjson cov "$3" \
  '{daily:{rx_bytes:$rx, tx_bytes:$tx, wire_bytes:($rx+$tx), categories:{}, category_rx_bytes:{models:($rx*0.75), git:($rx*0.25)}, category_tx_bytes:{}, coverage:$cov}}'; }
traffic_row 1000000000 100000000 '"full"' > "$AGENT_HOME/metrics/traffic-$(traffic_day 0).jsonl"
traffic_row 5000000000 1000000000 '"full"' >> "$AGENT_HOME/metrics/traffic-$(traffic_day 0).jsonl"
traffic_row 4000000000 1000000000 '{"gaps":1}' > "$AGENT_HOME/metrics/traffic-$(traffic_day 1).jsonl"
traffic_row 2000000000 500000000 '"full"' > "$AGENT_HOME/metrics/traffic-$(traffic_day 4).jsonl"
printf '{"daily":' > "$AGENT_HOME/metrics/traffic-$(traffic_day 2).jsonl"
run >/dev/null
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e --arg d4 "$(traffic_day 4)" --arg d1 "$(traffic_day 1)" --arg d0 "$(traffic_day 0)" '
  (.traffic.days | map(.day) == [$d4, $d1, $d0])
  and (.traffic.days[0] | .rx_gb == 2 and .tx_gb == 0.5 and .partial == false)
  and (.traffic.days[1] | .rx_gb == 4 and .tx_gb == 1 and .partial == true)
  and (.traffic.days[2] | .rx_gb == 5 and .tx_gb == 1 and .category_rx_gb.models == 3.75 and .partial == false)' >/dev/null \
  || fail "traffic.days did not carry each day's last-line totals with the malformed and missing days skipped"

(
  set -euo pipefail
  worker_pids=()
  trap 'for pid in "${worker_pids[@]}"; do kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; done; rm -rf -- "$test_env_root"' EXIT
  worker_root="$f/repo-workers"; worker_slice="$worker_root/zf-workers.slice"; worker_scratch="$worker_root/scratch"; worker_slots="$worker_scratch/tmp/luna-slots"
  mkdir -p "$worker_slice" "$worker_slots" "$worker_scratch/luna"
  make_clone() { mkdir -p "$1"; git init -q -b main "$1"; git -C "$1" remote add origin "https://github.com/$2.git"; }
  start_worker() { (cd "$launcher_clone" && exec sleep 600) & worker_pids+=("$!"); }
  record_run() { local key=$1 pid=$2 cwd=$3 dir="$worker_scratch/luna/$1"; mkdir -p "$dir"; printf '%s\n' "$pid" > "$dir/wrapper.pid"; printf '%s\n' "$cwd" > "$dir/cwd"; }
  launcher_clone="$worker_root/launcher-clone"; zen_clone="$worker_root/zenoforge-clone"; other_clone="$worker_root/other-clone"
  make_clone "$launcher_clone" example-maintainer/launcher
  make_clone "$zen_clone" ZenoWangzy/zenoforge; make_clone "$other_clone" example-maintainer/other-repo
  start_worker; zen_pid="${worker_pids[-1]}"
  start_worker; other_pid="${worker_pids[-1]}"
  mkdir -p "$worker_slice/luna-zenoforge-issue-1537-2201.scope" "$worker_slice/zc-other-issue-77-2202.scope"
  printf '%s\n' "$zen_pid" > "$worker_slice/luna-zenoforge-issue-1537-2201.scope/cgroup.procs"
  printf '%s\n' "$other_pid" > "$worker_slice/zc-other-issue-77-2202.scope/cgroup.procs"
  record_run zenoforge-issue-1537 "$zen_pid" "$zen_clone"; touch -d '@'"$(( $(date +%s) - 300 ))" "$worker_scratch/luna/zenoforge-issue-1537/wrapper.pid"
  record_run other-issue-77 "$other_pid" "$other_clone"; touch -d '@'"$(( $(date +%s) - 300 ))" "$worker_scratch/luna/other-issue-77/wrapper.pid"
  zen_wait_clone="$worker_root/zenoforge-wait-clone"; other_wait_clone="$worker_root/other-wait-clone"
  make_clone "$zen_wait_clone" ZenoWangzy/zenoforge; make_clone "$other_wait_clone" example-maintainer/other-repo
  start_worker; zen_wait_pid="${worker_pids[-1]}"
  start_worker; other_wait_pid="${worker_pids[-1]}"
  for row in "zenoforge-wait-1537:$zen_wait_pid:normal:120:$zen_wait_clone" "other-wait-77:$other_wait_pid:hotfix:60:$other_wait_clone"; do
    key="${row%%:*}"; rest="${row#*:}"; pid="${rest%%:*}"; rest="${rest#*:}"; priority="${rest%%:*}"; rest="${rest#*:}"; age="${rest%%:*}"; cwd="${rest#*:}"
    record_run "$key" "$pid" "$cwd"
    dir="$worker_scratch/luna/$key"; printf '%s\n' "$(( $(date +%s) - age ))" > "$dir/gate-wait"
    printf '%s\n' "$(( $(date +%s) - age ))" > "$worker_slots/wait-$priority-$pid"
  done
  jq '.data.repository.a0.pageInfo.hasNextPage=false | .data.c0.issueCount=21 | .data.c2.issueCount=4 | .data.c5.issueCount=3 | .data.c11.issueCount=8' "$f/graphql.json" > "$f/graphql-zen.json"
  jq '.data.repository.a0.pageInfo.hasNextPage=false | .data.c0.issueCount=55 | .data.c2.issueCount=7 | .data.c5.issueCount=1 | .data.c11.issueCount=12' "$f/graphql.json" > "$f/graphql-other.json"
  export FAKE_GRAPHQL_ZEN="$f/graphql-zen.json" FAKE_GRAPHQL_OTHER="$f/graphql-other.json"
  env ZF_DASHBOARD_REPOS=ZenoWangzy/zenoforge,example-maintainer/other-repo WORKER_SCRATCH_ROOT="$worker_scratch" \
    LUNA_WORKER_SLICE_DIR="$worker_slice" LUNA_SLOTS="$worker_slots" MAC_AUTOPILOT_DASHBOARD_OUTPUT="$f/repo-sections.js" \
    MAC_AUTOPILOT_FRONT_CACHE="$f/repo-section-cache.json" python3 "$script_dir/gen_dashboard.py"
  sed 's/^window.DASH=//; s/;$//' "$f/repo-sections.js" | jq -e '
    [.repo_sections[].repo] == ["ZenoWangzy/zenoforge","example-maintainer/other-repo"]
    and .repo_sections[0].counts == {issues_open:21,ready_for_agent:8,prs_open:4,prs_merged_24h:3}
    and .repo_sections[1].counts == {issues_open:55,ready_for_agent:12,prs_open:7,prs_merged_24h:1}
    and [.repo_sections[0].workers[].key] == ["zenoforge-issue-1537"]
    and [.repo_sections[1].workers[].key] == ["other-issue-77"]
    and [.repo_sections[0].waiters[].key] == ["zenoforge-wait-1537"]
    and [.repo_sections[1].waiters[].key] == ["other-wait-77"]
    and .repo_sections[0].waiters[0].waiter_ahead == "other-wait-77"
    and (.repo_sections[0].workers[0].age_s > 0)
    and (.repo_sections[0].waiters[0].age_s >= 120)' >/dev/null \
    || fail "per-repo dashboard data mixed counts or workers: $(sed 's/^window.DASH=//; s/;$//' "$f/repo-sections.js" | jq -c '.repo_sections')"
  node - "$script_dir/dashboard.html" "$f/repo-sections.js" <<'JS'
const fs = require("fs"), vm = require("vm"), [page, dataFile] = process.argv.slice(2), source = fs.readFileSync(page, "utf8");
const script = [...source.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1], raw = fs.readFileSync(dataFile, "utf8");
const D = JSON.parse(raw.replace(/^window\.DASH=/, "").replace(/;\s*$/, ""));
const el = () => ({innerHTML:"",textContent:"",classList:{add(){},remove(){},contains(){return false}},style:{},addEventListener(){},setAttribute(){},removeAttribute(){},appendChild(){},remove(){},dataset:{}});
const els = {}, store = {}, storage = {getItem:k => store[k] || null,setItem:(k,v) => {store[k]=String(v);}}, document = {getElementById:id => els[id] ||= el(),addEventListener(){},createElement:el,head:el(),documentElement:el(),title:""};
const context = {document,localStorage:storage,sessionStorage:storage,setInterval(){},setTimeout(){},innerWidth:1440,innerHeight:900,location:{reload(){}},console,Date,Math,JSON,Number,String,Object,Array,Set,encodeURIComponent};
context.window=context; context.scrollTo=()=>{}; context.DASH=D; vm.createContext(context); vm.runInContext(script,context,{filename:"dashboard.html"});
const rendered = context.__dash.MODULES.find(module => module.id === "overview").render(D), start = rendered.indexOf('class="panel repo-section"');
const section = rendered.slice(start, rendered.indexOf("</section>", start)+10);
if (start < 0 || !section.includes("ZenoWangzy/zenoforge") || !section.includes("zenoforge-issue-1537") || !section.includes("zenoforge-wait-1537") || !section.includes("other-wait-77"))
  throw new Error("rendered Zenoforge section lacks its counts or workers: " + section);
console.log("Zenoforge section: " + section.replace(/<[^>]+>/g," ").replace(/&amp;/g,"&").replace(/\s+/g," ").trim());
JS
) || fail 'rendered per-repository dashboard did not show each repo and its own workers'
echo "dashboard-front.test.sh: PASS"
