#!/usr/bin/env bash
# gen_dashboard.py 的 front（收单 → triage → advisor → 发布等待）：阶段计数与滞留时间、顾问批处理（lib.sh 读状态 + 结果日志）、
# triage 流水线效率账、发布列车被挡；GitHub 计数缓存 5 分钟；任何一块失败只让那一块"数据不可用"，看板其余照常。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "dashboard-front.test.sh: $*" >&2; exit 1; }
f="$test_env_root/front"; root="$f/repo"; sup="$root/.scratch-supervisor"; a="$sup/autopi"
mkdir -p "$f/bin" "$a/alerts" "$AGENT_HOME/logs" "$AGENT_HOME/metrics" "$f/sessions" "$root/engine/state" "$root/.zenoforge/state"
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
  MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$a" ZF_REPO_DIR="$root"
export MAC_AUTOPILOT_COST_CACHE="$f/cost.json" MAC_AUTOPILOT_DASHBOARD_OUTPUT="$f/out.js"
export FAKE_DEPLOYMENTS="$f/deployments.json" FAKE_DEPLOYMENT_WRITES="$f/deployment-writes"
export FAKE_SSH_LOG="$f/ssh.log"
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
 {"id":"pr-2","stage":"repair-pending","history":[{"stage":"advisor-ruling","at":"$(iso '-1 hours')"}]}]}
JSON
printf '{"rulings":[{"references":["#555"],"verbatim":"config override wording"}]}\n' \
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
 "a0":{"totalCount":4,"nodes":[{"number":9,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}]},
 "a1":{"totalCount":0,"nodes":[]},"a2":{"totalCount":2,"nodes":[{"number":5,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"__RECENT__"}]},
 "a3":{"totalCount":3,"nodes":[{"number":6,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"__RECENT__"}]},
 "a4":{"totalCount":0,"nodes":[]},"a5":{"totalCount":9,"nodes":[{"number":8,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"__RECENT__"}]},
 "a6":{"totalCount":5,"nodes":[{"number":3,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"__RECENT__"}]},
 "a7":{"totalCount":0,"nodes":[]}}}}' | sed "s/__RECENT__/$(iso '-2 hours')/g" > "$f/graphql.json"
cat > "$f/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1 $2" == "api graphql" ]]; then
  echo graphql >> "$FAKE_GH_LOG"
  if [[ -n "${FAKE_GH_FAIL:-}" ]]; then echo 'HTTP 502: bad gateway' >&2; exit 1; fi
  cat "$FAKE_GRAPHQL"
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
else echo '[]'; fi
GH
cat > "$f/bin/ssh" <<SH
#!/usr/bin/env bash
echo inspected >> "\$FAKE_SSH_LOG"
echo "\${FAKE_OBSERVED_IMAGE:-sha256:observed} reg/example-admin:live \${FAKE_OBSERVED_OLD:+/srv/app/releases/main-\$FAKE_OBSERVED_OLD/compose.yml,}/srv/app/releases/main-\${FAKE_OBSERVED_SHA:-$deployed}/compose.yml"
SH
cat > "$f/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *zf-triage-batch.service*) echo "zf-triage-batch.service loaded active running triage" ;;
  *zf-web-advisor-provider-*) echo "zf-web-advisor-provider-advisor-batch-J1.service loaded active running advisor" ;;
esac
SH
chmod +x "$f/bin/gh" "$f/bin/ssh" "$f/bin/systemctl"
export FAKE_GH_LOG="$f/gh.log" FAKE_GRAPHQL="$f/graphql.json"; : > "$FAKE_GH_LOG"
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
out="$(front)"
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | \
  jq -e '.founder_reqs.items | any(.[]; .issue == 555 and .text == "config override wording" and .from_ruling == true)' \
  >/dev/null || fail 'dashboard rulings reader did not use target config'
jq -e --arg sha "$deployed" '.[0].sha == $sha and .[0].payload.images["example-admin"] == "sha256:observed"' "$FAKE_DEPLOYMENTS" >/dev/null \
  || fail 'dashboard fixture has no production Deployment record'
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e --arg sid "$partial_session_id" \
  '.cost.budget_status=="partial" and .cost.budget_incomplete_sessions==[$sid] and .summary.real_daily_tokens==3600' >/dev/null \
  || fail 'partial daily usage or incomplete sessions did not reach dashboard data'
[[ ! -e "$a/deployed.json" ]] || fail 'dashboard recreated host-local deployed.json'
jq -e '.errors == {}
  and ([.stages[] | {(.label): .count}] | add) == {"needs-triage":4,"finish-first":0,"needs-info":2,"needs-advisor":3,"needs-recut":0,"ready-for-agent":9,"awaiting-release":5,"awaiting-pipeline-sync":0}
  and (.stages[0].idle_hours > 24 and .stages[0].oldest.number == 9)
  and (.stages[1].idle_hours == 0) and (.stages[2].idle_hours > 1.9 and .stages[2].idle_hours < 2.2)
  and .github.cached == false' <<<"$out" >/dev/null || fail "stage rows wrong: $(jq -c '{errors, stages, github}' <<<"$out")"
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
jq -e '.triage.done_today == 2 and .triage.running == true and .triage.backlog == 4
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
  grep -Fq "\`$key" "$script_dir/NODE-HEALTH.md" || fail "NODE-HEALTH.md lacks front standard $id"
done < <(jq -r '.standards | keys[]' <<<"$out")
# 整个看板数据仍是完整的
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e '.units | length == 2' >/dev/null || fail "dashboard lost its units"
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e \
  --arg sampled_at "$scorecard_sampled_at" --arg pause_since "$pause_since" \
  '.standards.generated_at == $sampled_at and .standards.source_commit == "a1b2c3d4e5f6"
   and .standards.paused == {since:$pause_since,reason:"refactor"}' >/dev/null \
  || fail 'dashboard did not combine the scorecard sample with the current PAUSE details'

# 2. 5 分钟缓存：再跑一次不再调 GitHub
run
[[ "$(wc -l < "$FAKE_GH_LOG")" == 1 ]] || fail "graphql called again inside the cache window: $(cat "$FAKE_GH_LOG")"
front | jq -e '.github.cached == true and .github.stale == false and .stages[5].count == 9' >/dev/null || fail "cached run not marked cached"

# 3. 缓存过期而 GitHub 失败：沿用旧缓存并标明失败原因（最长 30 分钟）
cache="$MAC_AUTOPILOT_DASHBOARD_OUTPUT"; cache="$(dirname "$cache")/front-cache.json"
[[ -s "$cache" ]] || fail "front cache file not written next to dashboard.data.js"
jq --argjson t "$(( $(date +%s) - 600 ))" '.github.fetched_epoch = $t' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
FAKE_GH_FAIL=1 run
front | jq -e '.github.stale == true and (.github.error | contains("502")) and .errors == {} and .stages[5].count == 9' >/dev/null \
  || fail "stale cache fallback wrong: $(front | jq -c '{github, errors}')"

# 4. 缓存也太旧且 GitHub 失败：只有阶段块"数据不可用"，顾问 / triage / 发布与整页数据照常
jq --argjson t "$(( $(date +%s) - 4000 ))" '.github.fetched_epoch = $t' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
FAKE_GH_FAIL=1 run
out="$(front)"
jq -e '(.errors | keys) == ["stages"] and (.errors.stages | contains("502")) and .stages == []
  and .advisor.job.job_id == "advisor-batch-J1" and .triage.done_today == 2 and .release.held == true' <<<"$out" >/dev/null \
  || fail "GitHub failure leaked beyond the stage block: $(jq -c '{errors, stages}' <<<"$out")"
sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" | jq -e '.units | length == 2' >/dev/null || fail "GitHub failure broke the dashboard"

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

# Compose overlays are appended per deploy: with an older layer first, the container runs the LAST layer, so a record that already
# names that layer is not drift and must not be rewritten with the older one.
jq -n --arg sha "$main" '[{id:9,sha:$sha,created_at:"2026-10-24T00:00:00Z",payload:{sha:$sha,images:{"example-admin":"sha256:observed"},image_shas:{"example-admin":$sha}}}]' > "$FAKE_DEPLOYMENTS"
: > "$FAKE_DEPLOYMENT_WRITES"; rm -f "$a/production-reconciliation-checked"
FAKE_OBSERVED_OLD="$deployed" FAKE_OBSERVED_SHA="$main" FAKE_OBSERVED_IMAGE=sha256:observed run
[[ ! -s "$FAKE_DEPLOYMENT_WRITES" ]] || fail "multi-layer compose chain read as drift (oldest layer used): $(cat "$FAKE_DEPLOYMENT_WRITES")"

# 7. 看板页面把前段拆进入口 / 顾问 / 发布三个模块渲染，且每块都有"数据不可用"分支（逐模块渲染见 dashboard-modules.test.sh）
for m in intake advisor release; do grep -Fq "{id:\"$m\"" "$script_dir/dashboard.html" || fail "dashboard.html has no $m module for the front"; done
[[ "$(grep -c '数据不可用' "$script_dir/dashboard.html")" -ge 1 ]] || fail "no unavailable state in dashboard.html"
echo "dashboard-front.test.sh: PASS"
