#!/usr/bin/env bash
# node_health.py：按 NODE-HEALTH.md 的标准给每个环节打分；正常结束的 worker 计时、无报告率、首评通过率、
# 返工轮数、仍在等待的单元计入等待时长、supervisor 响应时延、--alert 每小时每指标只报一次。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "node_health.test.sh: $*" >&2; exit 1; }
sup="$test_env_root/sup"; a="$sup/autopi"; mkdir -p "$a/alerts"
audit="$test_env_root/actions-run-cancellations.jsonl"
cat > "$audit" <<'JSON'
{"when":"2026-10-19T10:00:00Z","run_id":"deferred-1","repo":"example-maintainer/example-repo","reason":"ci deferred"}
{"when":"2026-10-19T10:01:00Z","run_id":"deferred-1","repo":"example-maintainer/example-repo"}
{"when":"2026-10-19T10:05:00Z","run_id":"repair-1","repo":"example-maintainer/example-repo","reason":"repair dispatched"}
{"when":"2026-10-19T10:06:00Z","run_id":"repair-1","repo":"example-maintainer/example-repo"}
{"when":"2026-10-19T11:00:00Z","run_id":"hold-1","repo":"example-maintainer/example-repo","reason":"ci hold"}
{"when":"2026-10-18T10:00:00Z","run_id":"hold-2","repo":"example-maintainer/example-repo","reason":"ci hold"}
{"when":"2026-10-17T10:00:00Z","run_id":"hold-old","repo":"example-maintainer/example-repo","reason":"ci hold"}
{"when":"2026-10-19T10:00:00Z","run_id":"other-repo","repo":"other/repo","reason":"ci deferred"}
JSON
prs="$test_env_root/open-prs.json"
cat > "$prs" <<'JSON'
[{"number":111,"headRefName":"agent/issue-111","labels":[{"name":"agent/ci-gated"}]},
 {"number":112,"headRefName":"agent/issue-112","labels":[]},
 {"number":113,"headRefName":"hand/x","labels":[{"name":"agent/ci-gated"}]}]
JSON
mkdir -p "$test_env_root/bin"
cat > "$test_env_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}:${2:-}" == "pr:list" ]]; then cat "$NODE_HEALTH_PRS"; exit 0; fi
echo "unexpected fake gh call: $*" >&2
exit 43
GH
chmod +x "$test_env_root/bin/gh"
export PATH="$test_env_root/bin:$PATH" NODE_HEALTH_PRS="$prs"
run() { # name minutes-long tokens with-report
  local start="2026-10-19T${2}:00Z" log="$sup/$1.worker.log"
  printf 'codex\ntokens used\n%s\ndone\n' "$4" > "$log"
  touch -d "$(date -u -d "$start + $3 minutes" +%Y-%m-%dT%H:%M:%SZ)" "$log"
  [[ "$5" == 1 ]] && echo report > "$sup/$1.md"
  return 0
}
run impl-issue-1-20261019T100000Z 10:00 20 100000 1
run impl-issue-2-20261019T100500Z 10:05 40 100000 0
run review-11-20261019T103000Z 10:30 6 50000 1
run impl-11-fix-20261019T104000Z 10:40 12 300000 1
run review-11-r-20261019T110000Z 11:00 4 50000 1
run review-11-r-20261019T111500Z 11:15 3 1000 1   # arbiter rereview without a repair before it: must not push the share past 100
run review-11-20260101T100000Z 10:00 6 999999 1   # outside the window
run impl-issue-3-20261019T114000Z 11:40 15 1000 0   # still running at 12:00 (log touched 11:55): not a no-report run
cat > "$a/units.json" <<'JSON'
{"units":[
 {"id":"pr-11","stage":"merged","review_findings":[
   {"round":1,"at":"2026-10-19T10:36:00Z","report":"review-11.md","block":"ok","findings":[]},
   {"round":2,"at":"2026-10-19T10:50:00Z","report":"review-11-r.md","block":"missing","findings":[]},
   {"round":3,"at":"2026-10-19T11:20:00Z","report":"review-11-r2.md","block":"missing","findings":[]},
   {"round":4,"at":"2026-10-18T09:00:00Z","report":"old.md","block":"missing","findings":[]}],"history":[
   {"stage":"review-request-changes","at":"2026-10-19T10:36:00Z"},
   {"stage":"repair-delivered","at":"2026-10-19T10:52:00Z"},
   {"stage":"review-approve","at":"2026-10-19T11:04:00Z"},
   {"stage":"merged","at":"2026-10-19T11:34:00Z"}]},
 {"id":"pr-12","stage":"ready-to-merge","history":[
   {"stage":"review-approve","at":"2026-10-19T10:00:00Z"},
   {"stage":"ci-red","at":"2026-10-19T10:30:00Z"}]},
 {"id":"pr-14","stage":"ready-to-merge","history":[{"stage":"review-approve","at":"2026-10-19T09:30:00Z"},
   {"stage":"precheck","result":"PRECHECK: SKIP workspace package selection failed","at":"2026-10-19T09:35:00Z"},
   {"stage":"ci-test-red","at":"2026-10-19T09:40:00Z"}]},
 {"id":"pr-13","stage":"supervisor-review","history":[
   {"stage":"supervisor-escalated","at":"2026-10-19T09:00:00Z"},
   {"stage":"supervisor-requeue","at":"2026-10-19T11:00:00Z"},
   {"stage":"advisor-ruling","at":"2026-10-19T11:01:00Z"},{"stage":"advisor-unavailable","at":"2026-10-19T11:02:00Z"},
   {"stage":"worker-no-output","at":"2026-10-19T11:10:00Z"}]}
]}
JSON
printf '[2026-10-19T11:00:00Z] tick done units=3 live=1\n[2026-10-19T11:05:00Z] tick done units=3 live=1\n[2026-10-19T11:12:00Z] tick done units=3 live=1\n' > "$a/scheduler.log"
echo '{"node_health":{"review.first_pass_pct":[40,10]}}' > "$a/config.json"

pause_since="2026-10-19T11:50:00Z"
mkdir -p "$AGENT_HOME"
jq -n --arg timestamp "$pause_since" '{reason:"refactor",caller:"operator",issue:"none",provider:"none",model:"none",timestamp:$timestamp}' > "$AGENT_HOME/PAUSE"
out="$(python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-19T12:00:00Z --alert --json "$a/node-health.json")"
source_commit="$(git -C "$repo_root" rev-parse HEAD)"
jq -e --arg sampled_at '2026-10-19T12:00:00Z' --arg source_commit "$source_commit" --arg pause_since "$pause_since" \
  '.generated == $sampled_at and .generated_at == $sampled_at and .source_commit == $source_commit
   and .paused == {since:$pause_since,reason:"refactor"}' \
  "$a/node-health.json" >/dev/null || fail 'scorecard JSON lacks its sample time, source commit or PAUSE details'
row() { grep -F "$1" <<<"$out" | head -1; }
grep -Eq ' 20 .*OK$' <<<"$(row 'implement run minutes p50')" || fail "implement wall time wrong: $(row 'implement run minutes')"
grep -Eq ' 50 .*UNHEALTHY$' <<<"$(row 'implement runs with no report')" || fail "no-report rate wrong: $(row 'no report')"
grep -Eq ' 67 +>=40 .*OK$' <<<"$(row 'approved on their first review')" || fail "first-pass yield or override wrong: $(row 'first review %')"
grep -Eq ' 1 .*OK$' <<<"$(row 'rounds before approve')" || fail "rounds wrong: $(row 'rounds')"
grep -Eq ' 58 .*UNHEALTHY$' <<<"$(row 'share of worker tokens')" || fail "rework token share wrong: $(row 'share of worker tokens')"
grep -Eq ' 100 .*OK$' <<<"$(row 'followed by an incremental rereview')" || fail "incremental rereview share wrong: $(row 'incremental rereview')"
grep -Eq ' 120 .*WARN$' <<<"$(row 'approve -> merged')" || fail "waiting unit not counted at its age (30, 120, 150 -> p50 120): $(row 'approve -> merged')"
# ci-test-red（L75 起 CI 红的主类）也算批准后 CI 红：漏掉它看板曾报 2%，实际 24h 内 74 单
grep -Eq ' 67 .*UNHEALTHY$' <<<"$(row 'then saw CI red')" || fail "red-after-approve wrong (ci-test-red must count): $(row 'CI red')"
grep -Eq ' 1 .*UNHEALTHY$' <<<"$(row 'local prechecks skipped by package selector')" || fail "precheck package-selection failure not guarded: $(row 'local prechecks skipped by package selector')"
grep -Eq ' 120 .*WARN$' <<<"$(row 'escalation -> supervisor')" || fail "supervisor latency wrong: $(row 'escalation')"
grep -Eq ' 1 .*OK$' <<<"$(row 'worker-no-output events')" || fail "deaths wrong: $(row 'worker-no-output')"
grep -Eq ' 50 .*UNHEALTHY$' <<<"$(row 'advisor asks that got no ruling')" || fail "advisor failure share wrong: $(row 'advisor asks')"
grep -Eq ' 300 .*WARN$' <<<"$(row 'between tick starts')" || fail "tick gap wrong: $(row 'tick starts')"
# 打回报告缺发现块的比例：窗口内 3 次打回记录里 2 次 missing（窗口外那条不算）；窗口内没有记录时为空，不算 0
grep -Eq ' 67 .*UNHEALTHY$' <<<"$(row 'without a findings block')" || fail "findings-block gap wrong: $(row 'findings block')"
quiet="$(python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 0.2 --now 2026-10-19T12:00:00Z)"
grep -Eq 'findings block % +-  .*NO-DATA' <<<"$quiet" || fail "no rejection records in the window must show no value, not 0: $(grep -F 'findings block' <<<"$quiet")"
grep -Eq ' 5 .*WARN$' <<<"$(row 'M1 audited cancelled runs/day: ci deferred')" || fail "M1 did not count one unique audited deferred run: $(row 'ci deferred')"
grep -Eq ' 5 .*OK$' <<<"$(row 'M1 audited cancelled runs/day: repair dispatched')" || fail "M1 did not retain the cause for a duplicate no-reason audit: $(row 'repair dispatched')"
grep -Eq ' 50 .*UNHEALTHY$' <<<"$(row 'active agent PRs with the agent/ci-gated label')" || fail "M12 did not read the provider label census: $(row 'agent/ci-gated')"
grep -Eq ' 2 .*UNHEALTHY$' <<<"$(row 'unique PR runs cancelled for priority hold in 48 h')" || fail "M13 48-hour priority activity wrong: $(row 'priority hold in 48 h')"
jq -e '.metrics[] | select(.id == "ci.cancel_deferred_per_day") | .value == 4.8 and .source != "" and .healthy == 0 and .unhealthy == 261' "$a/node-health.json" >/dev/null || fail 'M1 values, bounds or source missing from scorecard JSON'
jq -e '.metrics[] | select(.id == "ci.gated_pr_pct") | .value == 50 and .source != "" and .healthy == 80 and .unhealthy == 50' "$a/node-health.json" >/dev/null || fail 'M12 values, bounds or provider source missing from scorecard JSON'
jq -e '.metrics[] | select(.id == "ci.priority_hold_runs_48h") | .value == 2 and .source != "" and .healthy == 0 and .unhealthy == 1' "$a/node-health.json" >/dev/null || fail 'M13 values, bounds or source missing from scorecard JSON'
! grep -Fq 'tokens=1649999' <<<"$out" || fail 'run outside the window counted'
python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-19T12:20:00Z --alert >/dev/null
[[ "$(grep -c 'metric=loop.rework_token_pct' "$a/alerts/node-health.md")" == 1 ]] || fail "unhealthy metric alerted more than once per hour: $(cat "$a/alerts/node-health.md")"
# 发布节点：有当前批次在等时算距批次开始的小时数；热修阻断与孤儿 PR 计数
echo '{"status":"held","released_at":"2026-10-19T02:00:00Z","started_at":"2026-10-19T02:00:00Z"}' > "$a/release-train.json"
echo '{"blockers":[3572,3588]}' > "$a/release-blockers.json"; echo 'agent=12 foreign=3' > "$a/orphan-prs.count"
out="$(python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-19T12:00:00Z)"
grep -Eq ' 10 .*WARN$' <<<"$(row 'hours current release batch has waited')" || fail "release wait age wrong: $(row 'hours current release batch has waited')"
grep -Eq ' 2 .*UNHEALTHY$' <<<"$(row 'hot patches whose PR')" || fail "hot-patch blockers wrong: $(row 'hot patches')"
grep -Eq ' 12 .*UNHEALTHY$' <<<"$(row 'agent PRs outside the ledger')" || fail "orphan PRs wrong: $(row 'outside the ledger')"
# The current batch start, not an older accepted batch, is the wait clock.
echo '{"status":"delegated","started_at":"2026-10-28T17:05:00Z"}' > "$a/release-train.json"
printf '[2026-10-23T02:12:00Z] release-closer: deployed=%040d closed=[101] awaiting-release=[]\n' 0 > "$a/alerts/events.md"
out="$(python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-28T20:12:00Z --json "$a/node-health.json")"
grep -Eq ' 3 .*OK$' <<<"$(row 'hours current release batch has waited')" || fail "old batch acceptance inflated the current wait: $(row 'hours current release batch has waited')"
jq -e '((([.metrics[] | select(.id=="release.hours_waiting")][0].value * 60) | round) == 187)' "$a/node-health.json" >/dev/null \
  || fail 'release wait metric did not use the active batch start'
# Missing start evidence is unknown; never fall back to a historical acceptance.
echo '{"status":"delegated"}' > "$a/release-train.json"
python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-28T20:12:00Z --json "$a/node-health.json" >/dev/null
jq -e '[.metrics[] | select(.id=="release.hours_waiting")][0].value == null' "$a/node-health.json" >/dev/null \
  || fail 'missing active batch start reused historical release acceptance'
# 持续 3 小时 UNHEALTHY 才开 issue；同一指标 6 小时内不重复；恢复后清掉记录
mkdir -p "$test_env_root/bin"; : > "$test_env_root/gh.calls"
cat > "$test_env_root/roadmap-tree.json" <<'JSON'
{"roots":[{"number":900,"title":"the product Roadmap","state":"OPEN","labels":["roadmap"],"children":[{"number":3279,"title":"开发流水线与运行稳定","state":"OPEN","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":3309,"title":"自动派发与规则校验持续可靠","state":"OPEN","labels":["roadmap-epic"],"children":[]}]}]}]}
JSON
export MAC_AUTOPILOT_ROOT="$repo_root" ZF_REPO_DIR="$repo_root" ZF_REPO=example-maintainer/example-repo
export ZF_ROADMAP_TREE_CACHE_FILE="$test_env_root/roadmap-tree.json"
cat > "$test_env_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALLS"
case "${1:-}:${2:-}:${3:-}" in
  issue:list:*) echo "${FAKE_ISSUE_LIST:-[]}" ;;
  pr:list:*) cat "$NODE_HEALTH_PRS" ;;
  issue:create:*)
    body_next=0
    for arg in "$@"; do
      if (( body_next )); then cp "$arg" "$ISSUE_CREATE_BODY"; break; fi
      [[ "$arg" == --body-file ]] && body_next=1
    done
    echo "https://github.com/example-maintainer/example-repo/issues/${FAKE_NEXT_ISSUE:?}" ;;
  issue:view:*) jq -cn --argjson number "$3" --arg title "$FAKE_ISSUE_TITLE" \
    --arg body "$FAKE_ISSUE_BODY" '{number:$number,title:$title,body:$body,state:"OPEN",labels:[{name:"pipeline-system"},{name:"priority:top"},{name:"needs-triage"}]}' ;;
  issue:edit:*) echo '{}' ;;
  api:repos/*/issues/*/sub_issues:*) echo '{}' ;;
  api:repos/*/issues/*:*) echo 99001 ;;
  *) echo "unexpected fake gh call: $*" >&2; exit 43 ;;
esac
GH
chmod +x "$test_env_root/bin/gh"
export GH_CALLS="$test_env_root/gh.calls" FAKE_NEXT_ISSUE=99000 ISSUE_CREATE_BODY="$test_env_root/issue-create-body.md"
export FAKE_ISSUE_TITLE='pipeline health: release.hotpatch_blockers unhealthy'
export FAKE_ISSUE_BODY='Node health metric stayed unhealthy.'
cat > "$audit" <<'JSON'
{"when":"2026-10-19T10:00:00Z","run_id":"deferred-1","repo":"example-maintainer/example-repo","reason":"ci deferred"}
JSON
cat > "$prs" <<'JSON'
[{"number":111,"headRefName":"agent/issue-111","labels":[{"name":"agent/ci-gated"}]},
 {"number":112,"headRefName":"agent/issue-112","labels":[{"name":"agent/ci-gated"}]}]
JSON
nh() { PATH="$test_env_root/bin:$PATH" python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now "$1" --file-issues >/dev/null; }
rm -f "$a/node-health-state.json"; nh 2026-10-19T12:00:00Z
! grep -q 'issue create' "$test_env_root/gh.calls" || fail 'issue filed before the metric was unhealthy for 3 hours'
nh 2026-10-19T15:10:00Z
[[ "$(grep -c 'issue create --repo example-maintainer/example-repo --title pipeline health: release.hotpatch_blockers unhealthy' "$test_env_root/gh.calls")" == 1 ]] || fail "persistent unhealthy metric not filed once through roadmap helper: $(cat "$test_env_root/gh.calls")"
grep -q -- '--label pipeline-system --label priority:top' "$test_env_root/gh.calls" || fail 'filed issue lacks pipeline-system/priority:top'
# #4487：健康 issue 的正文必须把修复者引向行为根因，改口径/阈值要先证明指标错了
grep -qF 'Fix the behaviour, not the metric (#4487)' "$ISSUE_CREATE_BODY" || fail "health issue body lacks the behaviour-first rule: $(cat "$ISSUE_CREATE_BODY")"
grep -qF 'If a root-cause ticket already covers it, link this issue there and close it here' "$ISSUE_CREATE_BODY" || fail "health issue body lacks the root-cause ticket routing rule"
grep -qF "metric's definition or bounds is a fix only when the metric itself is proven wrong, with that evidence in the PR" "$ISSUE_CREATE_BODY" || fail "health issue body lacks the metric-change evidence rule"
grep -qF 'api repos/example-maintainer/example-repo/issues/3309/sub_issues' "$test_env_root/gh.calls" || fail 'pipeline-health issue was not placed under the pipeline-system epic'
nh 2026-10-19T17:00:00Z
[[ "$(grep -c 'issue create.*release.hotpatch_blockers' "$test_env_root/gh.calls"):$(grep -c 'issue comment' "$test_env_root/gh.calls")" == 1:0 ]] || fail 'metric re-filed inside 6 hours'
echo '{"blockers":[]}' > "$a/release-blockers.json"; nh 2026-10-19T17:10:00Z
! jq -e 'has("release.hotpatch_blockers")' "$a/node-health-state.json" >/dev/null || fail 'recovered metric still tracked'
# #4487：健康 issue 归因关闭后，同一 unhealthy 时段不再重开；恢复后再次恶化（新时段）才重新开票
unset FAKE_ISSUE_LIST
echo '{"blockers":[3572,3588]}' > "$a/release-blockers.json"
nh 2026-10-19T18:00:00Z   # new episode starts; under 3h -> nothing filed
[[ "$(grep -c 'issue create.*release.hotpatch_blockers' "$test_env_root/gh.calls")" == 1 ]] || fail 'filed before the new episode was 3 hours old'
export FAKE_ISSUE_LIST='[{"number":99000,"title":"pipeline health: release.hotpatch_blockers unhealthy","state":"CLOSED","closedAt":"2026-10-19T15:30:00Z"}]'
nh 2026-10-19T21:10:00Z   # closed during the previous episode (15:30 < since 18:00) -> new issue for the new episode
[[ "$(grep -c 'issue create.*release.hotpatch_blockers' "$test_env_root/gh.calls")" == 2 ]] || fail "fresh unhealthy episode after recovery did not file: $(cat "$test_env_root/gh.calls")"
export FAKE_ISSUE_LIST='[{"number":99001,"title":"pipeline health: release.hotpatch_blockers unhealthy","state":"CLOSED","closedAt":"2026-10-19T21:30:00Z"}]'
nh 2026-10-20T03:40:00Z   # refile window open again, but the issue was closed inside this episode (triaged) -> no re-file
[[ "$(grep -c 'issue create.*release.hotpatch_blockers' "$test_env_root/gh.calls")" == 2 ]] || fail "closed (triaged) health issue was re-filed in the same unhealthy episode"
# 每个数字都有标准：指标、含义、NODE-HEALTH.md 一一对应（看板与体检读同一份）
python3 - "$script_dir" <<'CHECK' || fail 'metric standards out of alignment'
import sys; sys.path.insert(0, sys.argv[1]); import node_health as n
doc = open(sys.argv[1] + "/NODE-HEALTH.md").read()
gaps = [m for m in n.CRITERIA if m not in n.MEANING or f"`{m}`" not in doc] + [m for m in n.MEANING if m not in n.CRITERIA]
gaps += [k for k in n.UNIT_STANDARDS if f"`unit.{k}`" not in doc]
gaps += [f"source:{m}" for m in n.CRITERIA if not n.SOURCE.get(m)] + [f"source:{m}" for m in n.SOURCE if m not in n.CRITERIA]
gaps += [k for k in list(n.TIME_SINKS) + list(n.CI_STANDARDS) if f"`{k}`" not in doc]
sys.exit(print("missing:", gaps) or 1 if gaps else 0)
CHECK
# 工作单标准：在途单超过 bug 线计入 workorders.over_standard；已合并的不算；--json 给看板
run review-15-20261019T113000Z 11:30 20 29000000 1
jq '.units += [{"id":"pr-15","pr":15,"stage":"review-pending","history":[{"stage":"review-request-changes","at":"2026-10-19T11:50:00Z"}]},
               {"id":"pr-16","pr":16,"stage":"merged","history":[{"stage":"pr-opened","at":"2026-09-01T00:00:00Z"},{"stage":"merged","at":"2026-09-02T00:00:00Z"}]}]' "$a/units.json" > "$a/u.tmp" && mv "$a/u.tmp" "$a/units.json"
# 时间都花在哪：返工触发→派出（排队）、返工干活、交付→复检派出、复检干活、批准→CI 判红，取自台账事件 + dispatch 行
printf '[2026-10-19T10:40:00Z] dispatch mode=fresh pid=1 type=repair unit=pr-11\n[2026-10-19T11:00:00Z] dispatch mode=resume pid=2 type=rereview unit=pr-11\n' >> "$a/scheduler.log"
echo '{"lines":{"15":900,"16":2000}}' > "$a/pr-sizes.json"
out="$(python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-19T12:00:00Z --json "$a/node-health.json")"
[[ "$(jq -c '[.time_sinks[] | [.id, (.value | if . == null then null else round end)]]' "$a/node-health.json")" == '[["repair_queue",4],["repair_work",12],["rereview_queue",8],["rereview_work",4],["approve_to_ci_red",10],["approve_to_merge",null]]' ]] \
  || fail "time sinks wrong: $(jq -c '[.time_sinks[] | [.id, .value]]' "$a/node-health.json")"
# 本机测试库：可达 = 1 OK，不可达或未配置 = 0 UNHEALTHY（重装后静默丢失过 4 天）
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
db_row() { PGTEST_URL="$1" python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-19T12:00:00Z | grep -F 'PGTEST_URL'; }
grep -Eq ' 0 .*UNHEALTHY$' <<<"$(db_row "postgresql://example@127.0.0.1:$port/postgres")" || fail "closed test DB port not unhealthy: $(db_row "postgresql://example@127.0.0.1:$port/postgres")"
grep -Eq ' 0 .*UNHEALTHY$' <<<"$(db_row '')" || fail 'missing PGTEST_URL not unhealthy'
# 监听端口由同一进程持有，体检在它活着时运行：无需轮询等待就绪
up="$(python3 -c 'import os,socket,subprocess,sys; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen()
env=dict(os.environ, PGTEST_URL="postgresql://example@127.0.0.1:%d/postgres" % s.getsockname()[1])
sys.exit(subprocess.run(sys.argv[1:], env=env).returncode)' python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-19T12:00:00Z | grep -F 'PGTEST_URL')"
grep -Eq ' 1 .*OK$' <<<"$up" || fail "reachable test DB not OK: $up"
# 主机依赖：host-prereqs.json 每项探测，不响应的计数并列出名字（10-17 重装静默丢了 3 项）
cat > "$a/prereqs.json" <<JSON
{"prereqs": [{"name": "dead tcp", "tcp": "127.0.0.1:$port"}, {"name": "dead http", "http": "http://127.0.0.1:$port/json/version"}]}
JSON
host="$(HOST_PREREQS_FILE="$a/prereqs.json" python3 "$script_dir/node_health.py" --runtime "$a" --audit "$audit" --hours 5 --now 2026-10-19T12:00:00Z)"
grep -Eq 'host services .* 2 .*UNHEALTHY$' <<<"$host" || fail "missing host services not unhealthy: $(grep -F 'host services' <<<"$host")"
grep -qF 'host missing: dead tcp; dead http' <<<"$host" || fail 'missing host service names not printed'
# GitHub 网络失败每小时数：只数最终失败行（重试行不算）；没有 journal 时为空，不算 0
cat > "$a/journalctl" <<'STUB'
#!/usr/bin/env bash
for i in 1 2 3 4; do echo 'worktree-lifecycle: origin fetch timed out (exit 124); retrying once'; echo 'worktree-lifecycle: origin fetch failed after 2 attempt(s) (exit 124)'; done
echo 'git fetch: timed out after 60s: git -C /x fetch origin main -- treated as an environment fault, not a verdict'
echo 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout'
echo 'unrelated: Post "https://example.com/x": net/http: TLS handshake timeout'
STUB
chmod +x "$a/journalctl"
python3 - "$script_dir" "$a" <<'CHECK' || fail 'GitHub network failures per hour miscounted'
import os, sys, datetime as dt; sys.path.insert(0, sys.argv[1]); import node_health as n
now = dt.datetime(2026, 10, 22, 15, tzinfo=dt.timezone.utc); since = now - dt.timedelta(hours=2)
os.environ["NODE_HEALTH_JOURNALCTL"] = sys.argv[2] + "/journalctl"
got = n.github_net_failures_per_hour(since, now)
os.environ["NODE_HEALTH_JOURNALCTL"] = sys.argv[2] + "/no-such-journalctl"
missing = n.github_net_failures_per_hour(since, now)
sys.exit(0 if (got, missing) == (3.0, None) else print(got, missing) or 1)
CHECK
# ~/wt 下超过 2 小时的工作目录：按 .git 链接文件的建立时间数；没有 .git 的目录不算；没有 ~/wt（Mac）为空
wt="$test_env_root/wt"; mkdir -p "$wt/old-a" "$wt/old-b" "$wt/fresh" "$wt/node-auto-owner"
for d in old-a old-b fresh; do echo "gitdir: /x/$d" > "$wt/$d/.git"; done
touch -d 2026-10-22T12:00:00Z "$wt/old-a/.git" "$wt/old-b/.git"; touch -d 2026-10-22T14:30:00Z "$wt/fresh/.git"
python3 - "$script_dir" "$wt" <<'CHECK' || fail 'stale worktree count wrong'
import sys, datetime as dt; sys.path.insert(0, sys.argv[1]); import node_health as n
now = dt.datetime(2026, 10, 22, 15, tzinfo=dt.timezone.utc)
got = (n.stale_worktrees(now, sys.argv[2]), n.stale_worktrees(now, sys.argv[2] + "/missing"), n.CRITERIA["host.stale_worktrees"][2:4])
sys.exit(0 if got == (2, None, (10, 40)) else print(got) or 1)
CHECK
# 被后一个触发取代的触发（CI 红→重跑绿→评审要改）不是"等返工 worker"：只配对返工前最后一个触发
python3 - "$script_dir" "$a" <<'CHECK' || fail 'a superseded trigger was paired with a later repair'
import sys, datetime as dt; sys.path.insert(0, sys.argv[1]); import node_health as n
open(sys.argv[2] + "/sinks.log", "w").write("[2026-10-19T11:05:00Z] dispatch mode=fresh pid=9 type=repair unit=pr-31\n")
h = [("ci-red", "10:00"), ("review-request-changes", "11:00"), ("repair-delivered", "11:20")]
u = {"id": "pr-31", "history": [{"stage": k, "at": f"2026-10-19T{t}:00Z"} for k, t in h]}
rows = {r["id"]: r for r in n.time_sinks([u], sys.argv[2] + "/sinks.log", dt.datetime(2026, 10, 19, 9, tzinfo=dt.timezone.utc), dt.datetime(2026, 10, 19, 12, tzinfo=dt.timezone.utc))[0]}
sys.exit(0 if (rows["repair_queue"]["n"], rows["repair_queue"]["value"]) == (1, 5) else print(rows["repair_queue"]) or 1)
CHECK
jq -e '.time_sinks[] | select(.id == "approve_to_ci_red") | .status == "OK" and .source != "" and .meaning != ""' "$a/node-health.json" >/dev/null || fail 'time sink lacks a standard, meaning or source'
grep -Eq ' 100 .*UNHEALTHY$' <<<"$(row 'over 800 changed lines')" || fail "large-PR share wrong: $(row 'over 800 changed lines')"
# #4482：窗口只保留最近 30 天有台账活动的 PR——pr-16（2000 行，9 月已合并）不计入；全量口径下一次性的大 PR 永久计入
[[ "$(jq -c '[.rework_by_size[] | .units]' "$a/node-health.json")" == '[0,0,1,0]' ]] || fail "rework by size wrong: $(jq -c .rework_by_size "$a/node-health.json")"
# Check the public scorecard at both window boundaries, including future and missing dates.
window="$test_env_root/size-window"; mkdir -p "$window"
cat > "$window/units.json" <<'JSON'
{"units":[
 {"id":"old","pr":1,"history":[{"stage":"merged","at":"2026-09-19T11:59:59Z"}]},
 {"id":"boundary","pr":2,"history":[{"stage":"pr-opened","at":"2026-09-19T12:00:00Z"}]},
 {"id":"exactly-800","pr":3,"history":[{"stage":"pr-opened","at":"2026-10-19T12:00:00Z"}]},
 {"id":"future-only","pr":4,"history":[{"stage":"pr-opened","at":"2026-10-19T12:00:01Z"}]},
 {"id":"no-date","pr":5,"stage":"review-pending","history":[]},
 {"id":"recent-and-future","pr":6,"history":[{"stage":"pr-opened","at":"2026-10-18T12:00:00Z"},{"stage":"merged","at":"2026-10-19T12:00:01Z"}]}
]}
JSON
echo '{"lines":{"1":2000,"2":801,"3":800,"4":2000,"5":2000,"6":100}}' > "$window/pr-sizes.json"
python3 "$script_dir/node_health.py" --runtime "$window" --audit "$audit" --now 2026-10-19T12:00:00Z --json "$window/result.json" >/dev/null
jq -e '[.metrics[] | select(.id == "review.large_pr_pct")][0] | .value == 50 and .healthy == 10 and .unhealthy == 25 and .status == "UNHEALTHY"' "$window/result.json" >/dev/null \
  || fail 'large-PR share did not honor the 30-day window and 800-line boundary'
# A temporary failed size fetch must not reset an existing unhealthy episode.
export FAKE_ISSUE_LIST='[]' FAKE_ISSUE_TITLE='pipeline health: review.large_pr_pct unhealthy'
size_alert() { python3 "$script_dir/node_health.py" --runtime "$window" --audit "$audit" --now "$1" --file-issues >/dev/null; }
size_alert 2026-10-19T12:00:00Z
jq 'del(.lines["5"])' "$window/pr-sizes.json" > "$window/sizes.tmp"; mv "$window/sizes.tmp" "$window/pr-sizes.json"
python3 "$script_dir/node_health.py" --runtime "$window" --audit "$audit" --now 2026-10-19T12:00:00Z --json "$window/result.json" >/dev/null
jq -e '[.metrics[] | select(.id == "review.large_pr_pct")][0] | .value == null and .status == "NO-DATA"' "$window/result.json" >/dev/null \
  || fail 'missing size for an active PR must not produce a partial percentage'
size_alert 2026-10-19T13:00:00Z
jq -e '.["review.large_pr_pct"].since == "2026-10-19T12:00:00Z"' "$window/node-health-state.json" >/dev/null \
  || fail 'missing size reset the unhealthy episode'
jq '.lines["5"] = 2000' "$window/pr-sizes.json" > "$window/sizes.tmp"; mv "$window/sizes.tmp" "$window/pr-sizes.json"
size_alert 2026-10-19T15:10:00Z
grep -q 'issue create.*pipeline health: review.large_pr_pct unhealthy' "$test_env_root/gh.calls" \
  || fail 'persistent large-PR episode was not filed after data returned'
jq '.lines |= with_entries(.value = 100)' "$window/pr-sizes.json" > "$window/sizes.tmp"; mv "$window/sizes.tmp" "$window/pr-sizes.json"
size_alert 2026-10-19T15:20:00Z
! jq -e 'has("review.large_pr_pct")' "$window/node-health-state.json" >/dev/null || fail 'healthy large-PR sample did not clear the episode'
jq '(.units[] | select(.id == "no-date").stage) = "closed"' "$window/units.json" > "$window/units.tmp"; mv "$window/units.tmp" "$window/units.json"
python3 "$script_dir/node_health.py" --runtime "$window" --audit "$audit" --now 2026-12-20T12:00:00Z --json "$window/result.json" >/dev/null
jq -e '[.metrics[] | select(.id == "review.large_pr_pct")][0] | .value == null and .status == "NO-DATA"' "$window/result.json" >/dev/null \
  || fail 'an empty 30-day sample must report NO-DATA'
jq -e '(.metrics | all(.source != "")) and (.ci_standards.queued_runs.unhealthy == 100)' "$a/node-health.json" >/dev/null || fail 'metric sources or CI standards missing from the dashboard JSON'
grep -Eq ' 1 .*WARN$' <<<"$(row 'past a spend bug bound')" || fail "over-standard work orders wrong: $(row 'past a spend bug bound')"
[[ "$(jq -c '[.work_orders[] | select(.over != []) | [.id, .over]]' "$a/node-health.json")" == '[["pr-15",["tokens"]]]' ]] || fail "work-order bug bounds wrong: $(jq -c .work_orders "$a/node-health.json")"
jq -e '.metrics[] | select(.id == "loop.rounds_p90") | .meaning != "" and .healthy == 3 and .unhealthy == 5' "$a/node-health.json" >/dev/null || fail 'scorecard JSON lacks meaning or bounds'
jq -e '.metrics[] | select(.id == "delivery.cycles_to_pass_30d") | .value == 2 and .source != "" and .healthy == 1.32 and .unhealthy == 2.28' "$a/node-health.json" >/dev/null || fail 'delivery review cycles missing from scorecard JSON'
jq -e '.metrics[] | select(.id == "delivery.issue_to_accept_p50_7d_hours") | .value == null and .source != "" and .healthy == 24 and .unhealthy == 72' "$a/node-health.json" >/dev/null || fail 'delivery lead-time standard missing when there are no acceptance records'
echo 'node_health.test.sh: PASS'

# A prevented wait is not a collision. Count actual overlapping writers, even
# when triage missed the shared file, independently of the scorecard window.
python3 - "$script_dir" <<'CHECK'
import sys
sys.path.insert(0, sys.argv[1])
import node_health as n
now = n.ts("2026-10-24T12:00:00Z")
def unit(uid, start, end, predicted, actual):
    import json
    return {"id": uid, "history": [
        {"stage": "write-start", "at": start, "result": json.dumps(predicted)},
        {"stage": "write-end", "at": end, "result": json.dumps(actual)}]}
a = unit("a", "2026-10-24T10:00:00Z", "2026-10-24T11:00:00Z", ["a.py"], ["shared.py"])
b = unit("b", "2026-10-24T10:30:00Z", "2026-10-24T11:30:00Z", ["b.py"], ["shared.py"])
c = unit("c", "2026-10-24T11:30:00Z", "2026-10-24T11:40:00Z", ["shared.py"], ["shared.py"])
assert n.dispatch_collisions([a, b, c], now) == 1
assert n.dispatch_collisions([a, c], now) == 0
assert n.dispatch_collisions([], now) is None
assert n.dispatch_collisions([a, b], now + n.timedelta(days=2)) == 0
assert n.CRITERIA["dispatch.collisions_per_day"][2:4] == (0, 1)
print("node_health collision intervals: PASS")
CHECK

# First-pass BLOCK is a failed first review; native resumed workers count only
# the new turn's fresh tokens, so pre-review repair cannot disappear from spend.
python3 - "$script_dir" "$test_env_root" <<'CHECK'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1]); import node_health as n
now = n.ts("2026-10-24T12:00:00Z")
u = [{"id":"blocked-first", "history":[
 {"stage":"review-block","at":"2026-10-24T10:00:00Z"},
 {"stage":"review-approve","at":"2026-10-24T11:00:00Z"}]}]
assert n.ledger_metrics(u, now-n.timedelta(hours=5), now)["review.first_pass_pct"] == 0
sup=pathlib.Path(sys.argv[2])/"native-spend"; (sup/"autopi").mkdir(parents=True)
name="impl-1-selfcheck1-fix-20261024T100000Z.worker.log"
(sup/name).write_text(json.dumps({"type":"turn.completed", "usage":{"input_tokens":1300,"cached_input_tokens":500,"output_tokens":200}})+"\n")
(sup/"autopi"/"workers.json").write_text(json.dumps({"workers":[{"log":name,"mode":"resume","token_usage_start":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100}}]}))
(sup/name.replace(".worker.log",".md")).write_text("self-fix delivered")
r=n.worker_runs(n.worker_cost.run_rows(str(sup)),now-n.timedelta(hours=5),now)
assert len(r)==1 and r[0]["tokens"]==300 and r[0]["node"]=="repair" and r[0]["unit"]=="1" and r[0]["self_fix"],r
(sup/"autopi"/"workers.json").write_text('{"workers":[]}')
assert n.worker_runs(n.worker_cost.run_rows(str(sup)),now-n.timedelta(hours=5),now)[0]["tokens"] is None
print("node_health native self-fix spend: PASS")
CHECK

# Delivery metrics recognize the Git revert marker written by scheduler revert paths.
python3 - "$script_dir" "$test_env_root" <<'CHECK' || fail 'delivery revert marker is not reflected in the accepted-unit rate'
import json, os, pathlib, subprocess, sys
sys.path.insert(0, sys.argv[1]); import node_health as n
root = pathlib.Path(sys.argv[2]) / "delivery-revert-git"
root.mkdir()
def git(*args, env=None):
    return subprocess.run(["git", *args], cwd=root, check=True, text=True, capture_output=True, env=env)
git("init", "-b", "main")
git("config", "user.name", "fixture")
git("config", "user.email", "fixture@example.test")
(root / "change.txt").write_text("accepted change\n")
git("add", "change.txt")
commit_env = dict(os.environ, GIT_AUTHOR_DATE="2026-10-24T12:00:00Z", GIT_COMMITTER_DATE="2026-10-24T12:00:00Z")
git("commit", "-m", "accepted change", env=commit_env)
merge_sha = git("rev-parse", "HEAD").stdout.strip()
revert_env = dict(os.environ, GIT_AUTHOR_DATE="2026-10-25T12:00:00Z", GIT_COMMITTER_DATE="2026-10-25T12:00:00Z")
git("revert", "--no-edit", merge_sha, env=revert_env)
git("update-ref", "refs/remotes/origin/main", "HEAD")
now = n.ts("2026-10-26T12:00:00Z")
metrics = n.delivery_metrics(
    [{"id":"pr-201", "issue":101, "pr":201, "merge_sha":merge_sha,
      "history":[{"stage":"merged", "at":"2026-10-24T12:30:00Z"}]}],
    [{"number":101, "createdAt":"2026-10-20T00:00:00Z"}],
    [{"number":201, "mergedAt":"2026-10-24T12:30:00Z", "mergeCommit":{"oid":merge_sha}, "reviews":[]}],
    [{"issue":101, "sha":"b"*40, "at":"2026-10-24T13:00:00Z"}], [], now,
    reverted_merge_times=n.git_revert_times(str(root), "refs/remotes/origin/main"))
assert metrics["values"]["delivery.revert_rate_30d_pct"] == 100, metrics
print("node_health Git revert markers: PASS")
CHECK

# Delivery metrics join only recorded issue -> unit -> PR -> merge -> release links.
python3 - "$script_dir" "$test_env_root" <<'CHECK' || fail 'delivery metrics join or percentiles are wrong'
import datetime as dt, json, os, pathlib, sys
sys.path.insert(0, sys.argv[1]); import node_health as n
now = n.ts("2026-10-26T12:00:00Z")
runtime = pathlib.Path(sys.argv[2]) / "release-events"
(runtime / "alerts").mkdir(parents=True)
line = "[2026-10-26T11:59:00Z] release-closer: deployed=" + "a"*40 + " closed=[101, 102] awaiting-release=[]\n"
(runtime / "alerts" / "events.md").write_text(line)
(runtime / "scheduler.log").write_text(line)
assert n.release_acceptances(str(runtime)) == [
    {"issue":101,"sha":"a"*40,"at":"2026-10-26T11:59:00Z"},
    {"issue":102,"sha":"a"*40,"at":"2026-10-26T11:59:00Z"}]
issues, prs, units, releases = [], [], [], []
latencies = [24, 48, 72, 96, 120, 240]
for offset, hours in enumerate(latencies, start=1):
    number, pr_number = 100 + offset, 200 + offset
    closed = now - dt.timedelta(days=2 + (offset % 4)) if offset < 6 else now - dt.timedelta(days=8)
    created = closed - dt.timedelta(hours=hours)
    approved_at = closed - dt.timedelta(hours=2)
    request_at = approved_at - dt.timedelta(days=1)
    merge_at = closed - dt.timedelta(hours=1)
    issues.append({"number": number, "createdAt": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "closedAt": closed.strftime("%Y-%m-%dT%H:%M:%SZ")})
    reviews = ([{"author":{"login":"example-maintainer"}, "state":"APPROVED",
                "submittedAt":approved_at.strftime("%Y-%m-%dT%H:%M:%SZ"), "body":""}] if offset == 1 else [])
    body, commits = "", []
    if offset == 2:
        commits = [{"commit":{"messageBody":"Co-Authored-By: Codex gpt-6-luna <noreply@openai.com>"}}]
        reviews = [{"author":{"login":"example-maintainer"}, "state":"APPROVED",
                    "submittedAt":(approved_at + dt.timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ"), "body":""}]
    if offset == 3:
        reviews = [{"author":{"login":"example-maintainer"}, "state":"CHANGES_REQUESTED",
                    "submittedAt":(approved_at + dt.timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ"), "body":"manual review"}]
    if offset == 4:
        reviews = [{"author":{"login":"reviewer"}, "state":"COMMENTED",
                    "submittedAt":approved_at.strftime("%Y-%m-%dT%H:%M:%SZ"), "body":"reviewed"}]
    if offset == 5:
        reviews = [{"author":{"login":"example-maintainer"}, "state":"APPROVED",
                    "submittedAt":approved_at.strftime("%Y-%m-%dT%H:%M:%SZ"), "body":"<!-- vecta-agent-comment -->"}]
    merge_sha = f"{1000 + offset:040x}"
    prs.append({"number":pr_number, "mergedAt":merge_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "mergeCommit":{"oid":merge_sha}, "body":body, "commits":commits, "reviews":reviews})
    review_history = ([{"stage":"review-request-changes", "at":request_at.strftime("%Y-%m-%dT%H:%M:%SZ")},
                       {"stage":"review-approve", "at":approved_at.strftime("%Y-%m-%dT%H:%M:%SZ")}] if offset in (1, 3) else
                      [{"stage":"review-approve", "at":approved_at.strftime("%Y-%m-%dT%H:%M:%SZ")}])
    history = review_history + [{"stage":"merged", "at":merge_at.strftime("%Y-%m-%dT%H:%M:%SZ")}]
    units.append({"id":f"pr-{pr_number}", "issue":number, "pr":pr_number, "merge_sha":merge_sha,
                  "stage":"merged", "history":history})
    releases.append({"issue":number, "sha":f"{offset:040x}", "at":closed.strftime("%Y-%m-%dT%H:%M:%SZ")})
issues.append({"number":199, "createdAt":"2026-10-20T00:00:00Z", "closedAt":"2026-10-25T00:00:00Z"})
releases.append({"issue":199, "sha":"f"*40, "at":"2026-10-25T00:00:00Z"})
# A recorded PR number does not establish the merge edge if GitHub has a different merge commit.
issues.append({"number":198, "createdAt":"2026-10-20T00:00:00Z", "closedAt":"2026-10-25T00:00:00Z"})
units.append({"id":"pr-298", "issue":198, "pr":298, "merge_sha":"b"*40, "stage":"merged",
              "history":[{"stage":"review-approve", "at":"2026-10-24T22:00:00Z"},
                         {"stage":"merged", "at":"2026-10-24T23:00:00Z"}]})
prs.append({"number":298, "mergedAt":"2026-10-24T23:00:00Z", "mergeCommit":{"oid":"c"*40}, "reviews":[]})
releases.append({"issue":198, "sha":"f"*40, "at":"2026-10-25T00:00:00Z"})
incidents = [{"id":"incident-1", "date":"2026-10-25", "issue":101},
             {"id":"incident-2", "date":"2026-10-25", "issue":199},
             {"id":"incident-3", "date":"2026-10-25", "issue":777},
             {"id":"incident-old", "date":"2026-08-01"}]
result = n.delivery_metrics(units, issues, prs, releases, incidents, now, repo="example-maintainer/example-repo",
                            reverted_merge_times={f"{1001:040x}": n.ts("2026-10-25T10:00:00Z")})
values, details = result["values"], result["details"]
assert values["delivery.issue_to_accept_p50_7d_hours"] == 72, values
assert values["delivery.issue_to_accept_p95_7d_hours"] == 120, values
assert values["delivery.issue_to_accept_p50_30d_hours"] == 72, values
assert values["delivery.issue_to_accept_p95_30d_hours"] == 240, values
assert values["delivery.revert_rate_30d_pct"] == 100 / 6, values
assert values["delivery.incident_rate_30d_pct"] == 300 / 8, values
assert values["delivery.cycles_to_pass_30d"] == 9 / 7, values
assert values["delivery.approvals_per_merge_30d"] == 1, values
assert values["delivery.human_actions_per_merge_30d"] == 2 / 7, values
assert values["delivery.human_actions_unattributed_30d"] == 1, values
assert values["delivery.unlinked_units_30d"] == 2, values
assert values["delivery.unlinked_incidents_30d"] == 1, values
assert details["unlinked_incidents_30d"] == 1 and details["human_actions_unattributed_30d"] == 1, details
assert details["accepted_units_30d"] == 8, details
acceptance = n.delivery_metrics(
    [{"id":"pr-201", "issue":101, "pr":201, "merge_sha":"a"*40,
      "history":[{"stage":"merged", "at":"2026-10-24T20:00:00Z"}]}],
    [{"number":101, "createdAt":"2026-10-20T00:00:00Z", "closedAt":"2026-10-24T21:00:00Z"}],
    [{"number":201, "mergedAt":"2026-10-24T20:00:00Z", "mergeCommit":{"oid":"a"*40}, "reviews":[]}],
    [{"issue":101, "sha":"b"*40, "at":"2026-10-25T00:00:00Z"}], [], now)
assert acceptance["values"]["delivery.issue_to_accept_p50_30d_hours"] == 120, acceptance
gh_bin = pathlib.Path(sys.argv[2]) / "delivery-gh"
gh_bin.mkdir()
gh = gh_bin / "gh"
gh.write_text("""#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
if args[:2] in (["issue", "list"], ["pr", "list"]):
    print("[]")
elif args[:3] == ["issue", "view", "101"]:
    print(json.dumps({"number":101,"createdAt":"2026-09-01T00:00:00Z","closedAt":"2026-09-02T00:00:00Z"}))
elif args[:3] == ["pr", "view", "201"]:
    print(json.dumps({"number":201,"mergedAt":"2026-10-24T20:00:00Z","mergeCommit":{"oid":"a"*40},"reviews":[],"body":"","commits":[]}))
else:
    raise SystemExit("unexpected fake gh command: " + " ".join(args))
""")
gh.chmod(0o755)
os.environ["PATH"] = str(gh_bin) + os.pathsep + os.environ["PATH"]
old_closed_issue = [{"id":"pr-201", "issue":101, "pr":201, "merge_sha":"a"*40,
                     "history":[{"stage":"merged", "at":"2026-10-24T20:00:00Z"}]}]
release = [{"issue":101, "sha":"b"*40, "at":"2026-10-25T00:00:00Z"}]
issue_rows, pr_rows = n.gh_delivery_rows("example-maintainer/example-repo", now, old_closed_issue, release)
fetched = n.delivery_metrics(old_closed_issue, issue_rows, pr_rows, release, [], now)
assert fetched["values"]["delivery.issue_to_accept_p50_30d_hours"] == 1296, fetched
concurrent_bin = pathlib.Path(sys.argv[2]) / "delivery-concurrency-gh"
concurrent_bin.mkdir()
concurrency_state = pathlib.Path(sys.argv[2]) / "delivery-concurrency.json"
concurrency_state.write_text('{"active":0,"peak":0}')
gh = concurrent_bin / "gh"
gh.write_text("""#!/usr/bin/env python3
import fcntl, json, os, sys, time
state_path = os.environ["DELIVERY_CONCURRENCY_STATE"]
def change_active(delta):
    with open(state_path, "r+") as state_file:
        fcntl.flock(state_file, fcntl.LOCK_EX)
        state = json.load(state_file)
        state["active"] += delta
        state["peak"] = max(state["peak"], state["active"])
        state_file.seek(0); state_file.truncate(); json.dump(state, state_file); state_file.flush()
        fcntl.flock(state_file, fcntl.LOCK_UN)
args = sys.argv[1:]
change_active(1)
try:
    time.sleep(0.1)
    if args[:2] in (["issue", "list"], ["pr", "list"]):
        print("[]")
    elif args[:2] == ["issue", "view"]:
        number = int(args[2])
        print(json.dumps({"number":number,"createdAt":"2026-09-01T00:00:00Z"}))
    elif args[:2] == ["pr", "view"]:
        number = int(args[2])
        print(json.dumps({"number":number,"mergedAt":"2026-10-24T20:00:00Z",
                          "mergeCommit":{"oid":f"{number:040x}"},"reviews":[],"body":"","commits":[]}))
    else:
        raise SystemExit("unexpected fake gh command: " + " ".join(args))
finally:
    change_active(-1)
""")
gh.chmod(0o755)
os.environ["PATH"] = str(concurrent_bin) + os.pathsep + os.environ["PATH"]
os.environ["DELIVERY_CONCURRENCY_STATE"] = str(concurrency_state)
accepted_at = "2026-10-25T00:00:00Z"
parallel_units = [{"issue":number,"pr":number + 100,"merge_sha":f"{number + 100:040x}"}
                  for number in range(301, 311)]
parallel_releases = [{"issue":unit["issue"],"at":accepted_at} for unit in parallel_units]
issue_rows, pr_rows = n.gh_delivery_rows("example-maintainer/example-repo", now, parallel_units, parallel_releases)
peak = json.loads(concurrency_state.read_text())["peak"]
assert len(issue_rows) == len(pr_rows) == 10, (issue_rows, pr_rows)
assert 2 <= peak <= 8, peak
print("node_health bounded GitHub lookup fan-out: PASS")
unavailable_bin = pathlib.Path(sys.argv[2]) / "delivery-unavailable-gh"
unavailable_bin.mkdir()
gh = unavailable_bin / "gh"
gh.write_text("""#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
if args[:2] in (["issue", "list"], ["pr", "list"]):
    print("[]")
elif args[:2] == ["issue", "view"]:
    raise SystemExit(1)
elif args[:2] == ["pr", "view"]:
    number = int(args[2])
    print(json.dumps({"number":number,"mergedAt":"2026-10-24T20:00:00Z",
                      "mergeCommit":{"oid":f"{number:040x}"},"reviews":[],"body":"","commits":[]}))
else:
    raise SystemExit("unexpected fake gh command: " + " ".join(args))
""")
gh.chmod(0o755)
os.environ["PATH"] = str(unavailable_bin) + os.pathsep + os.environ["PATH"]
unknown_issues, available_prs = n.gh_delivery_rows(
    "example-maintainer/example-repo", now, [{"issue":999,"pr":299}], [{"issue":999,"at":accepted_at}])
assert unknown_issues is None and [row["number"] for row in available_prs] == [299], (unknown_issues, available_prs)
print("node_health unavailable GitHub source stays unknown: PASS")
print("node_health delivery joins and percentiles: PASS")
CHECK

# --- 流动指标（#4366）：fixture 账本算数值；阈值内不发事件，越限每个指标只发一次 ---
fsup="$test_env_root/flow-sup"; fa="$fsup/autopi"; mkdir -p "$fa" "$fsup"
noaudit="$test_env_root/no-audit.jsonl"
cat > "$fa/units.json" <<'JSON'
{"units":[
 {"id":"pr-21","stage":"landed","history":[{"stage":"created","at":"2026-10-19T07:30:00Z"},{"stage":"landed","at":"2026-10-19T08:00:00Z"}]},
 {"id":"pr-22","stage":"merged","history":[{"stage":"created","at":"2026-10-19T09:00:00Z"},{"stage":"merged","at":"2026-10-19T11:00:00Z"}]},
 {"id":"pr-25","stage":"merged","history":[{"stage":"created","at":"2026-10-19T06:00:00Z"},{"stage":"merged","at":"2026-10-19T07:30:00Z"}]},
 {"id":"pr-23","stage":"ready-to-merge","history":[{"stage":"created","at":"2026-10-19T06:30:00Z"},{"stage":"review-approve","at":"2026-10-19T11:50:00Z"}]},
 {"id":"pr-24","stage":"implement","history":[{"stage":"created","at":"2026-10-18T22:00:00Z"},{"stage":"implement-started","at":"2026-10-18T23:00:00Z"}]},
 {"id":"pr-26","stage":"repair-pending","history":[{"stage":"created","at":"2026-10-19T06:00:00Z"},{"stage":"review-request-changes","at":"2026-10-19T07:50:00Z"}]},
 {"id":"pr-27","stage":"repair-pending","history":[{"stage":"created","at":"2026-10-19T06:00:00Z"},{"stage":"review-request-changes","at":"2026-10-19T10:00:00Z"}]}
]}
JSON
printf '[2026-10-19T09:00:00Z] dispatch mode=fresh pid=1 type=repair unit=pr-26\n[2026-10-19T11:00:00Z] dispatch mode=fresh pid=2 type=repair unit=pr-27\n' > "$fa/scheduler.log"
flowrun() { # <runtime-dir> <extra-args...> —— 统一窗口与固定 now
  local rt="$1"; shift
  PATH="$test_env_root/bin:$PATH" python3 "$script_dir/node_health.py" --runtime "$rt" --audit "$noaudit" \
    --main-red-dir "$rt/main-red" --hours 5 --now 2026-10-19T12:00:00Z "$@"
}
# 返工等待：pr-26 07:50→09:00 派出，全程无 repair worker 在跑 = 70 min 空转；
# pr-27 10:00→11:00 派出，其中 10:20–10:40 有 repair 在跑 = 40 min 空转；合计 110 min。
wrun() { local start="2026-10-19T${2}:00Z" log="$fsup/$1.worker.log"; printf 'codex\ntokens used\n1000\ndone\n' > "$log"
  touch -d "$(date -u -d "$start + $3 minutes" +%Y-%m-%dT%H:%M:%SZ)" "$log"; }
wrun impl-pr-26-fix-20261019T090000Z 09:00 30
wrun impl-pr-27-fix-20261019T102000Z 10:20 20
mkdir -p "$fa/main-red"
printf '{"red_sha":"%s","status":"flaky","created_at":"2026-10-19T08:00:00Z","updated_at":"2026-10-19T08:40:00Z"}' "$(printf 'a%.0s' {1..40})" > "$fa/main-red/$(printf 'a%.0s' {1..40}).json"
printf '{"red_sha":"%s","status":"bisecting","created_at":"2026-10-19T09:00:00Z","updated_at":"2026-10-19T09:30:00Z"}' "$(printf 'b%.0s' {1..40})" > "$fa/main-red/$(printf 'b%.0s' {1..40}).json"
printf '{"red_sha":"%s","status":"reverted","created_at":"2026-10-18T20:00:00Z","updated_at":"2026-10-18T21:00:00Z"}' "$(printf 'c%.0s' {1..40})" > "$fa/main-red/$(printf 'c%.0s' {1..40}).json"
printf 'not json' > "$fa/main-red/stale.json.tmp"
flowrun "$fa" --json "$fa/node-health.json" >/dev/null
flowval() { jq -r --arg id "$1" '.metrics[] | select(.id == $id) | "\(.value) \(.status)"' "$fa/node-health.json"; }
[[ "$(flowval flow.merge_rate_per_hour)" == "0.6 UNHEALTHY" ]] || fail "merge rate wrong: $(flowval flow.merge_rate_per_hour)（3 merged / 5h，有积压）"
[[ "$(flowval flow.in_out_imbalance)" == "1 OK" ]] || fail "in/out imbalance wrong: $(flowval flow.in_out_imbalance)（entered 2, merged 3）"
[[ "$(flowval flow.wip_age_stage_p90_hours)" == "13.0 UNHEALTHY" ]] || fail "wip stage age wrong: $(flowval flow.wip_age_stage_p90_hours)"
[[ "$(flowval flow.slot_idle_hours)" == "1.83 UNHEALTHY" ]] || fail "slot idle wrong: $(flowval flow.slot_idle_hours)"
[[ "$(flowval flow.main_red_hours)" == "3.67 UNHEALTHY" ]] || fail "main-red hours wrong: $(flowval flow.main_red_hours)（flaky 0.67 + 未终结 3.0，窗口外 reverted 不算）"
jq -e '.flow.entered == 2 and .flow.merged == 3
  and (.flow.wip_age[] | select(.stage == "implement") | .count == 1 and .p90_hours == 13)
  and (.flow.wip_age[] | select(.stage == "ready-to-merge") | .p90_hours == 0.2)' \
  "$fa/node-health.json" >/dev/null || fail "flow details wrong: $(jq -c .flow "$fa/node-health.json")"
# 无积压（全部终态且在窗口前）：合入速率不计值，不读成 0
ssup="$test_env_root/starve-sup"; sa="$ssup/autopi"; mkdir -p "$sa" "$ssup"
printf '{"units":[{"id":"pr-31","stage":"merged","history":[{"stage":"created","at":"2026-10-18T10:00:00Z"},{"stage":"merged","at":"2026-10-18T11:00:00Z"}]}]}' > "$sa/units.json"
out="$(flowrun "$sa")"
grep -F '6.5 target' <<<"$out" | grep -Eq ' - +>=6.5 .*NO-DATA$' || fail "starved queue must show no value, not 0: $(grep -F '6.5 target' <<<"$out")"
# 阈值内（33 单 / 5h = 6.6/h，全部当天完成）：全 OK，且不发事件
rsup="$test_env_root/rate-sup"; ra="$rsup/autopi"; mkdir -p "$ra" "$rsup"
python3 - "$ra" <<'PY'
import json, sys
units = [{"id": f"pr-{i}", "stage": "merged",
          "history": [{"stage": "created", "at": "2026-10-19T08:00:00Z"},
                      {"stage": "merged", "at": "2026-10-19T09:00:00Z"}]} for i in range(100, 133)]
json.dump({"units": units}, open(sys.argv[1] + "/units.json", "w"))
PY
flowrun "$ra" --json "$ra/node-health.json" >/dev/null
jq -e '.metrics[] | select(.id == "flow.merge_rate_per_hour") | .value == 6.6 and .status == "OK"' "$ra/node-health.json" >/dev/null \
  || fail "healthy merge rate wrong: $(jq '.metrics[] | select(.id == "flow.merge_rate_per_hour")' "$ra/node-health.json")"
# 事件：越限每个 flow 指标只发一条；同一越限期内重跑不再发；恢复清记录；再越限重新可发
inbox="$AGENT_HOME/supervisor-inbox"
state_file="$fa/flow-inbox-state.json"
rm -f "$inbox" "$state_file" "$AGENT_HOME"/logs/supervisor-alert-seen-*.tsv
flowrun "$fa" --inbox >/dev/null
flowlines() { grep -c 'flow metric=flow\.' "$inbox" 2>/dev/null || printf '0\n'; }
[[ "$(flowlines)" == 4 ]] || fail "expected one inbox event per unhealthy flow metric, got $(flowlines): $(cat "$inbox" 2>/dev/null)"
grep -Fq 'flow metric=flow.merge_rate_per_hour status=UNHEALTHY value=0.6' "$inbox" || fail "inbox event lacks metric id and value: $(cat "$inbox")"
flowrun "$fa" --inbox >/dev/null
[[ "$(flowlines)" == 4 ]] || fail "same unhealthy episode emitted again: $(flowlines)"
# 恢复：同一 runtime 换回健康账本（无越限 flow 指标）→ 越限记录清空，不再发事件
mv "$fa/units.json" "$fa/units.busy.json"
mv "$fa/main-red" "$fa/main-red.busy"
cp "$ra/units.json" "$fa/units.json"
flowrun "$fa" --inbox >/dev/null
jq -e 'length == 0' "$state_file" >/dev/null || fail "recovered metrics still recorded as alerted: $(cat "$state_file")"
[[ "$(flowlines)" == 4 ]] || fail "healthy run emitted events: $(flowlines)"
# 再越限：恢复后状态已重新武装；lib.sh 的同文去重按天滚动（supervisor-alert-seen-<day>.tsv），跨天后可重发
rm -f "$fa/units.json"; mv "$fa/units.busy.json" "$fa/units.json"; mv "$fa/main-red.busy" "$fa/main-red"
rm -f "$AGENT_HOME"/logs/supervisor-alert-seen-*.tsv
flowrun "$fa" --inbox >/dev/null
[[ "$(flowlines)" == 8 ]] || fail "re-armed crossing did not emit again after recovery: $(flowlines)"

# --- 机制心跳（#4495 M2/#4498 登记接缝；#4500 STPA 全量登记）：登记表机制超过沉默上限计入
# mechanism.silent，expected_idle 不计。fixture 覆盖全量登记：非 idle 项每项一条新鲜事件
# （11:55，两小时内的上限都过），只有 f3 过期（26h > 6h）；f1 过期（35h > 24h）但 expected_idle 不计。 ---
python3 - "$script_dir" <<'REGCHK' || fail 'mechanism-registry.json schema invalid'
import json, re, sys
reg = json.load(open(sys.argv[1] + "/../state/mechanism-registry.json"))
ids = [m["id"] for m in reg["mechanisms"]]
assert len(ids) == len(set(ids)), "duplicate ids: %s" % ids
for m in reg["mechanisms"]:
    for k in ("id", "desc", "supervisor", "silence_hours", "events"):
        assert m.get(k), (m.get("id"), k)
    assert isinstance(m["silence_hours"], int) and m["silence_hours"] > 0, m["id"]
    assert isinstance(m.get("expected_idle"), bool), m["id"]
    for e in m["events"]:
        assert e.get("base") in ("runtime", "agent_home") and e.get("file"), (m["id"], e)
        re.compile(e["pattern"])  # 坏 pattern 会让 node_health 的心跳循环抛 re.error
missing = {"factory-f%d" % i for i in range(1, 17)}
missing = {p for p in missing if not any(i == p or i.startswith(p + "-") for i in ids)}
assert not missing, "f1-f16 not all registered: %s" % missing
print("mechanism registry schema: PASS")
REGCHK
msup="$test_env_root/mech-sup"; ma="$msup/autopi"; mkdir -p "$ma/alerts" "$AGENT_HOME/logs"
printf '{"units":[]}' > "$ma/units.json"
{
  printf '[2026-10-29T01:00:00Z] footprint wait unit=pr-9 owner=pr-8\n'
  printf '[2026-10-29T11:55:00Z] tick done units=0\n'
  printf '[2026-10-29T11:55:00Z] dispatch mode=fresh reason=initial pid=99 type=implement unit=issue-1\n'
  printf '[2026-10-29T11:55:00Z] self-check pid=99 unit=issue-1 head=0123456789abcdef (before review)\n'
  printf '[2026-10-29T11:55:00Z] merged PR#7 merge=0123456789abcdef (own checks green; main CI verifies)\n'
  printf '[2026-10-29T11:55:00Z] dispatch land pid=98 unit=issue-2 PR#8 sha=0123456789abcdef\n'
  printf '[2026-10-29T11:55:00Z] ci wip: limit 8; 9 ready unit(s) wait for a CI slot (cancelled 1 queued run(s)); started 0\n'
  printf '[2026-10-29T11:55:00Z] ci deferred: cancelled 1 PR run(s) on heads still in review (CI starts on approval)\n'
  printf '[2026-10-29T11:55:00Z] intake issue #9 -> implement-pending (product)\n'
  printf '[2026-10-29T11:55:00Z] intake held: 30 units wait to merge (max_ready 30); the merge lane is the constraint; predecessors still admitted\n'
  printf '[2026-10-29T11:55:00Z] supervisor budget-park unit=issue-3: ticket stop-loss budget: wall 300min of 240min after 3 rounds\n'
  printf '[2026-10-29T11:55:00Z] supervisor arbitration unit=pr-7: requeue -> repair-pending\n'
  printf '[2026-10-29T11:55:00Z] test evidence not persisted tree=0123456789abcdef target=test:p source=self-check\n'
  printf '[2026-10-29T11:55:00Z] cihost admission decision MemAvailable_mb=13000 threshold_mb=12000 outcome=admit\n'
  printf '[2026-10-29T11:55:00Z] execution admission decision mode=run outcome=admit MemAvailable_mb=12288 load1=0.5 ceiling=10 held=0 decision_cap=10 reason=capacity-and-resources-approved\n'
} > "$ma/scheduler.log"
{
  printf '[2026-10-28T10:00:00Z] release-closer: deployed=%040d closed=[101] awaiting-release=[]\n' 0
  printf '[2026-10-29T11:55:00Z] IMPL-DELIVERED unit=issue-1 report=impl-issue-1-x.md\n'
} > "$ma/alerts/events.md"
printf '[2026-10-29T11:55:00Z] GATE main=0123456789abcdef run=1 status=pending — pipeline PRs merge on their own checks; main CI verifies after merge\n' > "$ma/alerts/gate.md"
printf '[2026-10-29T11:55:00Z] medium sig=abc event_id=1-1-1 action=queue=append,notify=off,supervisor=not-required\n' > "$ma/bell.log"
printf '2026-10-29T11:55:00Z test-kind supervisor inbox fixture line\n' > "$AGENT_HOME/supervisor-inbox"
printf '2026-10-28T01:00:00Z red abc: bisect named culprit abc\n' > "$AGENT_HOME/logs/main-red.log"
out="$(PATH="$test_env_root/bin:$PATH" python3 "$script_dir/node_health.py" --runtime "$ma" --audit "$noaudit" \
  --hours 1 --now 2026-10-29T12:00:00Z --alert --json "$ma/node-health.json")"
row() { grep -F "$1" <<<"$out" | head -1; }
grep -Eq ' 1 .*UNHEALTHY$' <<<"$(row 'registered mechanisms past their silence bound')" \
  || fail "mechanism.silent wrong (only f3 over bound, f1 expected_idle): $(row 'past their silence bound')"
reg_n="$(jq '.mechanisms | length' "$script_dir/../state/mechanism-registry.json")"
jq -e --argjson n "$reg_n" '(.mechanisms | length) == $n' "$ma/node-health.json" >/dev/null \
  || fail "scorecard mechanisms block does not cover the full registry: $(jq '.mechanisms | length' "$ma/node-health.json") of $reg_n"
jq -e '[.mechanisms[] | select(.silent) | .id] | length == 1 and .[0] == "factory-f3-release-train"' \
  "$ma/node-health.json" >/dev/null \
  || fail "only f3 should be silent (fixture must give every non-idle registry entry a fresh event): $(jq -c '[.mechanisms[] | select(.silent) | .id]' "$ma/node-health.json")"
jq -e '.metrics[] | select(.id == "mechanism.silent") | .value == 1 and .status == "UNHEALTHY" and .source != ""' \
  "$ma/node-health.json" >/dev/null || fail 'mechanism.silent missing bounds or source in scorecard JSON'
jq -e '.mechanisms[] | select(.id == "factory-f1-main-red-bisect") | .silent == false and .expected_idle == true and .silent_hours == 35 and .last_event_at == "2026-10-28T01:00:00Z"' \
  "$ma/node-health.json" >/dev/null || fail "f1 row wrong: $(jq -c '.mechanisms[] | select(.id == "factory-f1-main-red-bisect")' "$ma/node-health.json")"
jq -e '.mechanisms[] | select(.id == "factory-f3-release-train") | .silent == true and .silent_hours == 26' \
  "$ma/node-health.json" >/dev/null || fail "f3 row wrong: $(jq -c '.mechanisms[] | select(.id == "factory-f3-release-train")' "$ma/node-health.json")"
jq -e '.mechanisms[] | select(.id == "factory-f9-footprint-wait") | .silent == false and .silent_hours == 11' \
  "$ma/node-health.json" >/dev/null || fail "f9 row wrong: $(jq -c '.mechanisms[] | select(.id == "factory-f9-footprint-wait")' "$ma/node-health.json")"
grep -Fq 'NODE-UNHEALTHY metric=mechanism.silent node=mechanisms value=1 unhealthy-bound=1' "$ma/alerts/node-health.md" \
  || fail "silent mechanism was not written to the health alert: $(cat "$ma/alerts/node-health.md" 2>/dev/null)"
# scheduler.test.sh proves disabling f9 suppresses new footprint-wait lines.
# Two hours later (14:00): f9's last event is 13h (>12h) and the two 1h-bound loop mechanisms
# (scheduler-tick, bell-triage) are 2.1h quiet; f3 is 28h. Exactly those four must be silent.
out="$(PATH="$test_env_root/bin:$PATH" python3 "$script_dir/node_health.py" --runtime "$ma" --audit "$noaudit" \
  --hours 1 --now 2026-10-29T14:00:00Z --alert --json "$ma/node-health.json")"
jq -e '.metrics[] | select(.id == "mechanism.silent") | .value == 4 and .status == "UNHEALTHY"' \
  "$ma/node-health.json" >/dev/null || fail 'f9/tick/bell did not become silent after their bounds'
jq -e '[.mechanisms[] | select(.silent) | .id] | sort == (["factory-f3-release-train", "factory-f9-footprint-wait", "scheduler-tick", "bell-triage"] | sort)' \
  "$ma/node-health.json" >/dev/null \
  || fail "wrong silent set at 14:00: $(jq -c '[.mechanisms[] | select(.silent) | .id]' "$ma/node-health.json")"
jq -e '.mechanisms[] | select(.id == "factory-f9-footprint-wait") | .silent == true and .silent_hours == 13' \
  "$ma/node-health.json" >/dev/null || fail "f9 silence was not reported: $(jq -c '.mechanisms[] | select(.id == "factory-f9-footprint-wait")' "$ma/node-health.json")"
grep -Fq '[2026-10-29T14:00:00Z] NODE-UNHEALTHY metric=mechanism.silent node=mechanisms value=4 unhealthy-bound=1' "$ma/alerts/node-health.md" \
  || fail "post-bound f9 health alert missing: $(cat "$ma/alerts/node-health.md")"
python3 - "$script_dir" "$ma" <<'CHECK' || fail 'mechanism heartbeat semantics wrong'
import datetime as dt, os, sys
sys.path.insert(0, sys.argv[1]); import node_health as n
now = n.ts("2026-10-29T12:00:00Z")
rt, ah = sys.argv[2], os.environ.get("AGENT_HOME")
def reg(idle, hours, pattern="hit"):
    return [{"id": "m", "desc": "d", "supervisor": "s", "silence_hours": hours, "expected_idle": idle,
             "events": [{"base": "runtime", "file": "scheduler.log", "pattern": pattern}]}]
rows, silent = n.mechanism_heartbeat(reg(False, 6), rt, ah, now)
assert silent == 1 and rows[0]["last_event_at"] is None, (rows, silent)  # 从未有过事件 = 沉默
rows, silent = n.mechanism_heartbeat(reg(True, 6), rt, ah, now)
assert silent == 0 and rows[0]["expected_idle"] and rows[0]["silent_hours"] is None, rows  # expected_idle 不计
os.rename(rt + "/scheduler.log", rt + "/scheduler.log.1")  # rotate_logs 只留一代 .1，也要读到
rows, silent = n.mechanism_heartbeat(reg(False, 12, "footprint wait"), rt, ah, now)
assert silent == 0 and rows[0]["silent_hours"] == 11.0, rows
rows, silent = n.mechanism_heartbeat(reg(False, 6, "no such event"), rt, ah, now)
assert silent == 1, rows  # 没有匹配行的机制照样沉默
print("node_health mechanism heartbeat units: PASS")
CHECK
