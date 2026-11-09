#!/usr/bin/env python3
"""Per-node health scorecard for the Code Factory (deterministic, read-only).

Usage: node_health.py [--hours N] [--runtime DIR] [--audit FILE] [--now ISO] [--alert] [--file-issues]

Each node is scored against the criteria in NODE-HEALTH.md (healthy / unhealthy bounds; between
them is WARN). Sources: worker logs in the supervisor dir (exact start from the file name, end from
mtime, tokens from the shared native reader or legacy "tokens used" footer), ledger history (rounds, yield, waits) and
scheduler.log tick lines. `config.json` key `node_health` overrides any bound by metric id.
--alert appends UNHEALTHY nodes to alerts/node-health.md (once per metric per hour).
--file-issues: a metric UNHEALTHY for ESCALATE_HOURS files (or comments on) a pipeline-system issue so the
pipeline repairs itself; at most once per REFILE_HOURS per metric (state in node-health-state.json). The
issue body routes the worker to the behavioural root cause (#4487); an issue closed during the current
unhealthy episode (triaged onto a root-cause ticket) is not re-filed until the metric recovers and relapses.
"""
import argparse, glob, json, os, re, socket, subprocess, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime, timezone, timedelta
from pathlib import Path
import arbiter_health, existing_walk_health, harvest_health, ledger_history, live_delivery, merge_wait, metric_windows
import line_holds
import release_age
import release_retained
import rulings_copies
import station_standards
import pr_census
import watch_alerts
import worker_cost
import workorder_cost
import usage_reader
from config_paths import zf_config_file, zf_host_ops_file, zf_incident_guards, zf_mechanism_registry


def is_test_path(path):
    return re.search(r'(^|/)(tests?|__tests__|fixtures?|__snapshots__|eval[-_a-z]*)/|\.(test|spec)\.|\.snap$', path) is not None


def health_doc_reference():
    doc = zf_config_file("mac-autopilot/NODE-HEALTH.md")
    if doc is None:
        doc = Path(__file__).resolve().parent / "NODE-HEALTH.md"
    engine_dir = Path(os.environ.get("ZF_ENGINE_DIR") or Path(__file__).resolve().parent.parent)
    repo_dir = Path(os.environ.get("ZF_REPO_DIR") or engine_dir.parent).resolve()
    try:
        return Path(doc).resolve().relative_to(repo_dir).as_posix()
    except ValueError:
        return os.fspath(doc)


# metric id: (node, description, healthy bound, unhealthy bound, higher_is_better)
CRITERIA = {**arbiter_health.CRITERIA, **harvest_health.CRITERIA, **existing_walk_health.CRITERIA, **merge_wait.CRITERIA, **live_delivery.CRITERIA, **ledger_history.CRITERIA,
    "implement.wall_p50":      ("implement", "implement run minutes p50", 30, 60, False),
    "implement.no_output_pct": ("implement", "implement runs with no report %", 5, 15, False),
    "merge.conflict_repairs_per_day": ("ci+merge", "merge conflicts that a repair run followed, in 24 h", 20, 27, False),
    "review.wall_p50":         ("review", "first review minutes p50", 10, 20, False),
    "review.first_pass_pct":   ("review", "units approved on their first review %", 50, 30, True),
    "repair.wall_p50":         ("repair", "repair run minutes p50", 15, 30, False),
    "loop.rounds_p90":         ("review-loop", "request-changes rounds before approve p90", 3, 5, False),
    "loop.rework_token_pct":   ("review-loop", "repair+rereview share of worker tokens %", 35, 50, False),
    "loop.incremental_rereview_pct": ("review-loop", "repairs followed by an incremental rereview %", 60, 30, True),
    "workers.deaths":          ("workers", "worker-no-output events in window", 2, 8, False),
    "ci.approve_to_ship_p50":  ("ci+merge", "approve -> merged/landed min p50 (incl. waiting)", 60, 180, False),
    "ci.red_after_approve_pct": ("ci+merge", "approved units that then saw CI red %", 15, 30, False),
    "ci.precheck_setup_failures": ("ci+merge", "local prechecks skipped by package selector", 0, 1, False),
    "supervisor.latency_p50":  ("supervisor", "escalation -> supervisor decision minutes p50", 60, 180, False),
    "scheduler.tick_gap_p50":  ("scheduler", "seconds between tick starts p50", 240, 420, False),
    "scheduler.merge_pass_gap_min": ("scheduler", "minutes since the last merge pass while ready-to-merge units wait", 10, 30, False),
    "release.hours_waiting":   ("release", "hours current release batch has waited", 4, 12, False),
    "release.hotpatch_blockers": ("release", "production hot patches whose PR is not on main", 0, 1, False),
    "pipeline.orphan_prs":     ("pipeline", "open agent PRs outside the ledger", 3, 10, False),
    "workorders.over_standard": ("work-orders", "open work orders past a spend bug bound", 0, 3, False),
    # Frozen fallbacks (2026-10-21 distribution: tokens p50 0.53M / p90 2.4M, worker minutes p50 25 / p90 90);
    # token bounds use cache-split history only and fall back here when no such sample is available.
    "workorders.ticket_tokens_p90": ("work-orders", "per-ticket worker fresh tokens p90, tickets closed in 7 d", 800_000, 4_800_000, False),
    "workorders.ticket_wall_p90": ("work-orders", "per-ticket worker wall minutes p90, tickets closed in 7 d", 38, 180, False),
    "ci.waste_runner_pct":     ("ci+merge", "CI runner minutes that could not change a verdict %", 20, 35, False),
    "ci.held_ready_pct":       ("ci+merge", "ready-to-merge units whose CI is held for hot patches %", 20, 50, False),
    "ci.cancel_deferred_per_day": ("ci+merge", "M1 audited cancelled runs/day: ci deferred", 0, 261, False),
    "ci.cancel_slot_wait_per_day": ("ci+merge", "M1 audited cancelled runs/day: ci wip", 0, 213, False),
    "ci.cancel_repair_per_day": ("ci+merge", "M1 audited cancelled runs/day: repair dispatched", 177, 354, False),
    "ci.cancel_tests_red_per_day": ("ci+merge", "M1 audited cancelled runs/day: tests already red", 62, 124, False),
    "ci.cancel_review_changes_per_day": ("ci+merge", "M1 audited cancelled runs/day: review requested changes", 0, 60, False),
    "ci.cancel_review_blocked_per_day": ("ci+merge", "M1 audited cancelled runs/day: review blocked", 2, 5, False),
    "ci.cancel_parked_per_day": ("ci+merge", "M1 audited cancelled runs/day: parked", 3, 6, False),
    "ci.cancel_superseded_per_day": ("ci+merge", "M1 audited cancelled runs/day: superseded main run", 30, 60, False),
    "ci.cancel_other_per_day": ("ci+merge", "M1 audited cancelled runs/day: other or unclassified", 0, 1, False),
    "ci.gated_pr_pct":          ("ci+merge", "active agent PRs with the agent/ci-gated label %", 80, 50, True),
    "ci.priority_hold_runs_48h": ("ci+merge", "unique PR runs cancelled for priority hold in 48 h", 0, 1, False),
    "ci.shared_append_rebase_conflict_pct": ("ci+merge", "shared-append landings whose rebase conflicted on a shared-append file %, rolling 24 h", 25, 50, False),
    "landing.post_land_runs_ratio": ("ci+merge", "post-land Pipeline suites runs per direct-main landing, rolling 24 h", 0.5, 0, True),
    "review.large_pr_pct":     ("review-loop", "ledger PRs over 800 non-test added lines %, rolling 30 d", 10, 25, False),
    "workers.local_test_db":   ("workers", "local test Postgres (PGTEST_URL) reachable, 1 = yes", 1, 0, True),
    "loop.advisor_fail_pct":   ("review-loop", "advisor asks that got no ruling %", 10, 50, False),
    "advisor.last_answer_age_hours": ("review-loop", "hours since the newest successful advisor answer while needs-advisor > 0", 2, 6, False),
    "review.findings_missing_pct": ("review-loop", "REQUEST-CHANGES reports without a findings block %", 5, 20, False),
    "delivery.issue_to_accept_p50_7d_hours": ("delivery", "issue created -> release accepted p50, 7 d hours", 24, 72, False),
    "delivery.issue_to_accept_p95_7d_hours": ("delivery", "issue created -> release accepted p95, 7 d hours", 72, 168, False),
    "delivery.issue_to_accept_p50_30d_hours": ("delivery", "issue created -> release accepted p50, 30 d hours", 24, 72, False),
    "delivery.issue_to_accept_p95_30d_hours": ("delivery", "issue created -> release accepted p95, 30 d hours", 72, 168, False),
    "delivery.revert_rate_30d_pct": ("delivery", "accepted units reverted within 30 d %", 5, 10, False),
    "delivery.incident_rate_30d_pct": ("delivery", "accepted units named by a production incident within 30 d %", 5, 10, False),
    "delivery.cycles_to_pass_30d": ("delivery", "review rounds to pass per merged unit, 30 d", 1.32, 2.28, False),
    "delivery.approvals_per_merge_30d": ("delivery", "review approvals per merged unit, 30 d", 1, 2.28, False),
    "delivery.unlinked_units_30d": ("delivery", "release-accepted units missing a recorded join, 30 d", 0, 1, False),
    "delivery.unlinked_incidents_30d": ("delivery", "production incidents and alert episodes without an accepted-unit link, 30 d", 0, 1, False),
    "host.prereqs_missing":    ("host", "host services from host-prereqs.json that do not answer", 0, 1, False),
    "host.github_net_failures_per_hour": ("host", "GitHub fetch/API network failures per hour (user journal)", 2, 10, False),
    "host.stale_worktrees":    ("host", "worktrees under ~/wt older than 2 h", 10, 40, False),
    "intake.closed_units_open_issues": ("intake", "open ready-for-agent issues whose units all ended", 0, 10, False),
    "engine.follow_lag_hours": ("host", "hours the live engine has not followed example HEAD:scripts", 0.5, 2, False),
    # Factory flow metrics (#4366): throughput vs the 6.5/h SLO, staged WIP age, dispatch
    # stalls, main-red duration and in/out conservation. Crossing the unhealthy bound sends
    # one supervisor-inbox event per episode (--inbox); regular samples reach the dashboard.
    "flow.merge_rate_per_hour": ("flow", "merges per hour vs the 6.5 target over 24 h (starved queue has no value)", 6.5, 3.5, True),
    "flow.wip_age_stage_p90_hours": ("flow", "worst per-stage p90 age of open units, hours", 4, 12, False),
    # Units parked on purpose (blocked-external, parked) stay out of the worst-stage pick; their own row
    # shows how long they have waited. Bounds: 699 completed holds (2026-11-07), p90 80 h and 2x it.
    "flow.wait_stage_p90_hours": ("flow", "p90 age of units waiting on a predecessor or a park, hours", 80, 160, False),
    "flow.wait_stage_units":   ("flow", "units waiting on a predecessor or a park (measured, no bound)", 0, -1, True),
    "flow.slot_idle_hours":    ("flow", "hours units queued for a repair/rereview worker while none of that phase ran", 0.25, 1, False),
    "flow.main_red_hours":     ("flow", "hours main was red (bisect sessions) in the window", 1, 3, False),
    "flow.in_out_imbalance":   ("flow", "|units entered - units merged/landed| in the window", 5, 15, False),
    # M2 mechanism heartbeat (#4495/#4498): a mechanism whose code landed but never runs is
    # silent (f3 stopped releases for 18 h while release_train.enabled=false, #4483).
    "mechanism.silent":        ("mechanisms", "registered mechanisms past their silence bound", 0, 1, False),
}
GH_DELIVERY_FANOUT = 8
GH_DELIVERY_CALL_TIMEOUT = 15
GH_DELIVERY_CENSUS_TIMEOUT = 30
GH_DELIVERY_BATCH_TIMEOUT = 60
# What each number means, in the dashboard's words. Every metric above needs one (node_health.test.sh).
MEANING = {**arbiter_health.MEANING, **harvest_health.MEANING, **existing_walk_health.MEANING, **merge_wait.MEANING, **live_delivery.MEANING, **ledger_history.MEANING,
    "implement.wall_p50": "一次开发从派出到交付的中位时长。偏长多半是任务太大，或卡在环境上。",
    "implement.no_output_pct": "开发员跑完却没交报告的比例：这些 token 全白花，多是进程被杀或崩溃。",
    "merge.conflict_repairs_per_day": "过去 24 小时内发生了合并冲突（merge-conflict）、随后由修复运行接手的次数。多个任务可以同时改同一个文件，撞上了由原任务自己修；这个数偏高说明撞得太多，修复拖慢交付。24 小时值 20 以内健康，27 以上不健康；这两个界来自 9 个有效日的账本均值 15.6、标准差 5.5。",
    "review.wall_p50": "首次质检的中位时长。",
    "review.first_pass_pct": "固定滚动 24h（止于现在）内，首条评审结论为通过的工作单占比：每单取时间最早的一条 review-approve / review-request-changes / review-block，落在窗口内才计入分母；通过数 ÷ 计入数。越高说明开发一次做对，返工越少。",
    "repair.wall_p50": "一次返工修改的中位时长。",
    "loop.rounds_p90": "通过前被打回的轮数（90 分位）：轮数多 = 评审不收敛，时间和 token 都耗在来回上。",
    "loop.rework_token_pct": "返工 + 复检占全部 AI 用量的比例：隐性工厂，越低越好。",
    "loop.incremental_rereview_pct": "修复后只复查修复部分（增量复检）的比例：低说明每轮都在重审整份改动，永不收敛（L63）。",
    "workers.deaths": "窗口内 AI 员工无产出死亡次数。",
    "ci.approve_to_ship_p50": "批准到合并的中位等待（含仍在等的）：CI 排队与合并车道的速度。",
    "ci.red_after_approve_pct": "批准后 CI 又红的比例：评审没看出的问题，或 CI 环境不稳。",
    "ci.precheck_setup_failures": "本机预检因无法选择受影响的 workspace 包而跳过；CI 可能成为测试第一次运行的位置。",
    "ci.waste_runner_pct": "CI runner 时间里改变不了结论的部分：被取消的 job、从未获批又被取代的 head、非产品改动触发的产品 CI（L64/L65）。",
    "ci.cancel_deferred_per_day": "M1：共享取消审计中，原因是 ci deferred 的不同 PR run 数按天折算；健康为零，bug 线取冻结基线日均数。",
    "ci.cancel_slot_wait_per_day": "M1：共享取消审计中，原因是 ci wip（等待 CI 名额）的不同 PR run 数按天折算；健康为零，bug 线取冻结基线日均数。",
    "ci.cancel_repair_per_day": "M1：共享取消审计中，原因是 repair dispatched 的不同 PR run 数按天折算；健康上限为冻结基线日均数，bug 线为其两倍。",
    "ci.cancel_tests_red_per_day": "M1：共享取消审计中，原因是 tests already red 的不同 PR run 数按天折算；健康上限为冻结基线日均数，bug 线为其两倍。",
    "ci.cancel_review_changes_per_day": "M1：共享取消审计中，原因是 review requested changes 的不同 PR run 数按天折算；健康为零，bug 线取冻结基线日均数。",
    "ci.cancel_review_blocked_per_day": "M1：共享取消审计中，原因是 review blocked 的不同 PR run 数按天折算；健康上限为冻结基线日均数，bug 线为其两倍。",
    "ci.cancel_parked_per_day": "M1：共享取消审计中，原因是 parked 的不同 PR run 数按天折算；健康上限为最近 7 天滚动 24 小时读数的 p90，bug 线为其两倍；样本薄：7 天内只有 6 个 parked run，来自 4 个单元。",
    "ci.cancel_superseded_per_day": "M1：共享取消审计中，原因是 superseded by newer main head（main 防抖：更新的 main 头取代尚在排队的旧 run）的不同 run 数按天折算；数量随 main 合入节奏，边界为运维设定值。",
    "ci.cancel_other_per_day": "M1：共享取消审计中，原因不在已知类别里的不同 PR run 数按天折算。",
    "ci.gated_pr_pct": "M12：当前活跃 agent/issue-* PR 中带服务端 agent/ci-gated 标签的比例；不读本机台账镜像。",
    "ci.priority_hold_runs_48h": "M13：最近 48 小时共享取消审计中原因是 ci hold 的不同 PR run 数；零活动满足优先挡板的退役观察条件。",
    "ci.shared_append_rebase_conflict_pct": "shared-append 注册表文件（footprint 互斥对其放行并行的名单，config 的 footprint_mutex.shared_append）在 direct-main 落地 rebase 时真的撞出文本冲突的比例。裁决接受少量冲突换并行；一天样本里持续偏高就把对应文件从名单移回互斥。无样本不计值。",
    "landing.post_land_runs_ratio": "founder 裁决 2026-10-29：非产品代码先落地，落地后的 Pipeline suites 加 fix-forward 就是检查。24h 内有 direct-main 落地却一次落地后运行都没有，说明这个检查已经失效（2026-10-31 #4860 删掉 workflow 后就是这样）。无落地不计值。",
    "supervisor.latency_p50": "升级到主管后多久得到裁决（中位）。",
    "scheduler.tick_gap_p50": "调度两拍之间的秒数（中位）：越长，派活、合并、发布都越慢。",
    "scheduler.merge_pass_gap_min": "有已批准待合并的单、但合并车道已经多少分钟没跑过一次：越长，绿了的 PR 越晚合入（暂定界线，攒够 10 天数据再调）。",
    "release.hours_waiting": "当前有待发布改动时，本批次已等待的小时数；无待发布工作时为 0。",
    "release.hotpatch_blockers": "生产上跑着、但源 PR 还没进 main 的热修数：每个都会挡住发布。",
    "pipeline.orphan_prs": "流水线台账之外的 agent PR：没人推进的工作。",
    "review.large_pr_pct": "非测试新增行超过 800 行的 PR 占比，只统计最近 30 天有台账活动的 PR；测试路径包括名为 test、tests、__tests__、fixture、fixtures、__snapshots__ 的目录，以及名称以 eval 开头且后续只含小写字母、连字符或下划线的目录；文件名含 .test.、.spec. 或以 .snap 结尾也算测试路径。全量口径下旧的大 PR 永久计入，异常只会靠新 PR 稀释而不会随时间自然恢复（#4482）。PR 越大返工越多：<300 行中位 1 轮返工，>2000 行中位 9 轮（10-22 台账 170 个 PR）。高 = 票太大，要在分诊时拆小。",
    "ci.held_ready_pct": "已批准待合并、但 CI 被热修优先挡住的工作单比例：高 = 优先级变成了饥饿，整条合并车道停摆（L75：10-21 一度 100/101）。",
    "workorders.over_standard": "超过单项花费 bug 线的在途工作单数（见下方工作单标准）：每一单都按缺陷处理，查根因。",
    "workorders.ticket_tokens_p90": "每张 ticket 生命周期 worker fresh token（未缓存输入 + 输出）的 p90，只统计有缓存拆分的票；取最近 7 天关闭的票，阈值来自之前 30 天有缓存拆分的已关票 p50×1.5（健康）与 p90×2（异常），没有可用历史时回退到静态 800k / 4.8M。升高 = 现在这批票比历史更烧钱，去单元表里找是哪张。",
    "workorders.ticket_wall_p90": "每张 ticket 生命周期 worker 墙钟（分钟）的 p90，取最近 7 天关闭的票；阈值同上取历史 p50×1.5 / p90×2。",
    "loop.advisor_fail_pct": "第 2 次评审打回后问顾问（拆票 / 定范围 / 修复方向），没拿到裁决的比例。高 = 顾问 provider 不可用。",
    "advisor.last_answer_age_hours": "needs-advisor 队列非空时，距最近一次成功 advisor 回答的小时数。高 = 顾问死了而没人发现（10-28 21:17 PDT 起约 30 小时无产出）。队列为空记 0。",
    "review.findings_missing_pct": "打回报告里缺结构化发现块（或块畸形）的比例。缺块 = 这一轮的发现没记进台账，同文件复发规则就看不见它；Claude 评审员不带 review skill，10-20 起 81% 的打回报告没有块。",
    "host.prereqs_missing": "WSL 主机上流水线依赖的服务（测试库、代理等）有几个没响应。非 0 时看体检输出里列出的名字；10-17 重装后这些缺失要几天后才以浪费的形式暴露。",
    "host.github_net_failures_per_hour": "每小时连不上 GitHub 的次数（fetch 最终失败、API TLS 握手超时）。WSL 上 GitHub 只能走 egress 代理，单元缺代理就静默超时：10-22 三个定时单元没有代理 drop-in，6 小时约 1,600 次，没有任何数字显示。",
    "engine.follow_lag_hours": "live 引擎没跟上 example HEAD:scripts 的小时数。converge 导出、构建或自检失败时开始计时，跟上后清零。高 = 落地了但没上线。",
    "host.stale_worktrees": "~/wt 下建立超过 2 小时还没删的工作目录数。分诊、顾问、hand 每轮结束就该删掉；堆积 = 收尾清理坏了（10-21/22 收尾先 fetch，代理一卡就全部保留，26 小时堆到 287 个）。",
    "intake.closed_units_open_issues": "issue 开着且 ready-for-agent、但单元都已结束的张数。intake 的 terminal 跳过不派 worker，也不逐行报，所以这类票会静默停住；非 0 时看体检输出列出的号（11-06 查出 8 张）。",
    "flow.merge_rate_per_hour": "过去 24 小时内 merged/landed 的工厂单元数（不含人工 PR 与账本外的 PR）÷ 24，对照 6.5/h 的吞吐目标（#4355）。窗口里没有在制品也没进单（无积压）时不计值；跌破 3.5/h 是升级前串行合并道的上限，工厂没在产出。",
    "flow.wip_age_stage_p90_hours": "每张在途单在当前阶段已停留的小时（按阶段分组取 p90，取最差阶段；分组明细在 scorecard 的 flow.wip_age）。高 = 流动卡在某个阶段，去单元表找是哪几张。",
    "flow.wait_stage_p90_hours": "units.json 中 blocked-external（等前序单）与 parked（止损挂起）的在途单，自进入该阶段的最后事件起算的 p90 小时；不计入上一行的最差阶段。高 = 有一串单长期等同一个前序，去单元表找前序。",
    "flow.wait_stage_units": "同上两个阶段的在途单数，只计数，不设阈值。",
    "flow.slot_idle_hours": "有单排队等返工/复检 worker、而该阶段一个 worker 都没在跑的小时数：这是派发停摆（槽位空转），不是产能不足（那会表现为 worker 全忙）。",
    "flow.main_red_hours": "main 处在红的小时数（#4356 二分会话覆盖）：红一次并自动回滚是设计内；持续红 = 二分卡住或回滚 PR 未合并。",
    "flow.in_out_imbalance": "|窗口内进入的单数 − 完成合入的单数|：进出守恒。持续不等 = 单在系统里堆积或凭空消失（WIP 泄漏 / 孤儿单）。",
    "mechanism.silent": "登记表（engine/state/mechanism-registry.json）里沉默超过上限的机制数：代码落地了但没在跑（#4483 里 f3 落地后停转 18 小时就是这类）。允许长期无事件的机制（expected_idle）只展示最近事件时间，不计入。分组明细在 scorecard 的 mechanisms。",
    "workers.local_test_db": "AI 员工 push 前能否在本机跑集成测试。0 = 集成测试第一次运行要等到批准后的 CI，红了再返工一轮（10-17 重装丢了测试库，24h 内 146 次返工由批准后 CI 红触发）。",
    "delivery.issue_to_accept_p50_7d_hours": "过去 7 天发布关闭单元的 issue 创建到 release-closer 接受的中位小时数；只计有一条验收记录且 issue 创建时间可读的单元（不要求单元/PR 关联）；窗口内没有发布验收时显示 NO-DATA（发布停摆时如此，不是读数丢失）。",
    "delivery.issue_to_accept_p95_7d_hours": "过去 7 天发布关闭单元的 issue 创建到 release-closer 接受的 p95 小时数；只计有一条验收记录且 issue 创建时间可读的单元（不要求单元/PR 关联）；窗口内没有发布验收时显示 NO-DATA（发布停摆时如此，不是读数丢失）。",
    "delivery.issue_to_accept_p50_30d_hours": "过去 30 天发布关闭单元的 issue 创建到 release-closer 接受的中位小时数；只计有一条验收记录且 issue 创建时间可读的单元（不要求单元/PR 关联）。",
    "delivery.issue_to_accept_p95_30d_hours": "过去 30 天发布关闭单元的 issue 创建到 release-closer 接受的 p95 小时数；只计有一条验收记录且 issue 创建时间可读的单元（不要求单元/PR 关联）。",
    "delivery.revert_rate_30d_pct": "过去 30 天接受单元中，release-closer 接受后 main 出现对应 Git revert marker 的比例。",
    "delivery.incident_rate_30d_pct": "过去 30 天被线上事故明确点名的接受单元数 ÷ 同期接受单元数（上限 100%）。只统计能关联到接受单元的事故；没有点名 issue 的线上告警不在这里，由 delivery.unlinked_incidents_30d 计分，所以 0 不代表线上没有问题。",
    "delivery.cycles_to_pass_30d": "过去 30 天合并单元从首次评审到第一次 review-approve 的评审轮数均值，含通过轮。",
    "delivery.approvals_per_merge_30d": "过去 30 天合并单元的 review-approve 台账事件均值。",
    "delivery.unlinked_units_30d": "过去 30 天 release-closer 明确关闭的 issue 中，issue→unit→PR→merge→release 链缺字段或多义的数量。",
    "delivery.unlinked_incidents_30d": "过去 30 天线上事故账本（与负责人邮件同源）里未关联接受单元的事故，加上 head-watch 的线上告警次数（PROD-DB-TIMEOUT，间隔 30 分钟内算一次，与负责人邮件线上告警同口径）；告警不带 issue，一律未关联。告警日志只从 2026-11-04 开始，所以这是下限而非完整 30 天；不会猜测归属。",
}
# Where each number comes from (dashboard "来源" column). node_health.test.sh requires one per metric.
SOURCE = {**arbiter_health.SOURCE, **harvest_health.SOURCE, **existing_walk_health.SOURCE, **merge_wait.SOURCE, **live_delivery.SOURCE, **ledger_history.SOURCE,
    "implement.wall_p50": "worker 日志 *.worker.log：文件名里的开始时间 → 最后写入时间；只算交了报告的开发轮；24 h 窗口",
    "implement.no_output_pct": "同上；已结束（10 分钟没写日志）却没有报告 .md 的开发轮",
    "merge.conflict_repairs_per_day": "units.json（含 units-archive.json）单元历史：merge-conflict 事件之后出现 write-start（修复运行）的次数，固定滚动 24h。",
    "review.wall_p50": "review-*.worker.log 的开始 → 最后写入",
    "review.first_pass_pct": "units.json 与 units-archive.json 单元历史（同 id 取 units.json 行）：每单最早一条评审结论（review-approve / review-request-changes / review-block），其时间落在固定滚动 24h 窗口内才计入；通过 = review-approve。",
    "repair.wall_p50": "impl-*-fix-*.worker.log 的开始 → 最后写入；24 h 窗口",
    "loop.rounds_p90": "units.json：每次 review-approve 之前的 review-request-changes 次数",
    "loop.rework_token_pct": "worker 页脚或 usage_reader 原生 turn 用量减派发基线：repair（含 self-fix）+ rereview ÷ 已计量的 run；未计量的 run 不计入，显示已计量 run 数；全部未计量则 N/A",
    "loop.incremental_rereview_pct": "每次 repair 之后同一单的下一次评审是否为增量复检（rereview）",
    "workers.deaths": "units.json 的 worker-no-output 事件",
    "ci.approve_to_ship_p50": "units.json：review-approve → merged/landed；仍在等的按已等时长计",
    "ci.red_after_approve_pct": "units.json：批准后、下一次评审前出现 ci-red / ci-test-red 的比例",
    "ci.precheck_setup_failures": "units.json：窗口内 precheck 结果为 PRECHECK: SKIP workspace package selection failed 的次数",
    "supervisor.latency_p50": "units.json：supervisor-escalated → 下一个 supervisor 裁决事件",
    "scheduler.tick_gap_p50": "scheduler.log 相邻两条 tick done 的间隔",
    "scheduler.merge_pass_gap_min": "运行目录 .merge-pass-epoch（run_merge_lane 拿到车道锁时写入）距今分钟数；units.json 里没有待合并单时为 0",
    "release.hours_waiting": "release-train.json：当前待发布批次的 started_at",
    "release.hotpatch_blockers": "release-blockers.json（release_train.sh 对照生产热修与 main）",
    "pipeline.orphan_prs": "orphan-prs.count（调度器比对 open PR 与台账）",
    "workorders.over_standard": "units.json + worker 日志：每单 token、员工分钟、返工轮、年龄对照下方工作单标准",
    "workorders.ticket_tokens_p90": "worker_cost.ticket_spend.fresh（未缓存输入 + 输出）按 units.json issue 归票；只纳入有缓存拆分的票（票的任一 run 没有用量记录就不算：GLM 与 claude 的 review 不写用量，7 天窗口内没有任何票全程有记录时为 NO-DATA），窗口 7 天，阈值取窗口前 30 天有缓存拆分的已关票 p50/p90；无可用历史时用静态 800k / 4.8M",
    "workorders.ticket_wall_p90": "worker 日志文件名起始 → 最后写入，按 units.json issue 归票（review/repair 日志文件名里的 PR 号经 unit.pr 归到 issue）；窗口 7 天，阈值取窗口前 30 天已关票 p50/p90",
    "ci.waste_runner_pct": "ci-spend.json（ci_spend.py 每 30 分钟用 GitHub Actions jobs API 统计）",
    "ci.held_ready_pct": "units.json：ready-to-merge 且带 ci_held_sha 的单数 ÷ 就绪单数",
    "ci.cancel_deferred_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的最后一个非空 reason=ci deferred ÷ 窗口小时 × 24；边界取冻结基线 M1。",
    "ci.cancel_slot_wait_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的最后一个非空 reason=ci wip ÷ 窗口小时 × 24；边界取冻结基线 M1。",
    "ci.cancel_repair_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的最后一个非空 reason=repair dispatched ÷ 窗口小时 × 24；边界取冻结基线 M1。",
    "ci.cancel_tests_red_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的最后一个非空 reason=tests already red ÷ 窗口小时 × 24；边界取冻结基线 M1。",
    "ci.cancel_review_changes_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的最后一个非空 reason=review requested changes ÷ 窗口小时 × 24；边界取冻结基线 M1。",
    "ci.cancel_review_blocked_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的最后一个非空 reason=review blocked ÷ 窗口小时 × 24；边界取冻结基线 M1。",
    "ci.cancel_parked_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的最后一个非空 parked reason ÷ 窗口小时 × 24；边界取最近 7 天滚动 24 小时读数的 p90（3）及其两倍（6），样本见 NODE-HEALTH.md。",
    "ci.cancel_superseded_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的最后一个非空 reason=superseded by newer main head ÷ 窗口小时 × 24。",
    "ci.cancel_other_per_day": "共享 actions-run-cancellations.jsonl：窗口内不同 run_id 的其他或缺失 reason ÷ 窗口小时 × 24。",
    "ci.gated_pr_pct": "GitHub pull request API：带 agent/ci-gated 标签的 open agent/issue-* PR ÷ 所有 open agent/issue-* PR。",
    "ci.priority_hold_runs_48h": "共享 actions-run-cancellations.jsonl：最近 48 小时不同 run_id 的最后一个非空 reason=ci hold。",
    "ci.shared_append_rebase_conflict_pct": "logs/shared-append-rebases.jsonl（land-direct-main 记录每次改动范围带 shared-append 文件的落地 rebase）：固定滚动 24h 内 conflict_files 非空的比例；24h 内没有这类落地 rebase 时显示 N/A（没有事件可量，不是缺数据）。",
    "landing.post_land_runs_ratio": "land-queue/requests/*.json：direct_landing 且 state=landed、finished_epoch 在固定滚动 24h 内的数量为落地数；GitHub pipeline-suites.yml 在 main 上 display_title 以 “Pipeline suites post-land ” 开头的 run 数（含取消）为运行数；比值=运行数÷落地数。24h 内没有落地，或 gh 读不到 run 列表时显示 N/A。",
    "review.large_pr_pct": "pr-sizes.json（ci_spend.py 取 PR 非测试新增行；测试路径包括名为 test、tests、__tests__、fixture、fixtures、__snapshots__ 的目录，以及名称以 eval 开头且后续只含小写字母、连字符或下划线的目录；文件名含 .test.、.spec. 或以 .snap 结尾也排除）对照最近 30 天有台账活动的 PR；无历史的在途单也计入，缺尺寸时显示无数据",
    "loop.advisor_fail_pct": "units.json：advisor-unavailable ÷（advisor-ruling + advisor-unavailable），24 h 窗口",
    "advisor.last_answer_age_hours": "web-advisor-provider-jobs/*/answer.err 中不含 FAIL: 的最新 mtime；needs-advisor 数来自 gh issue list",
    "review.findings_missing_pct": "units.json 每单的 review_findings：窗口内 block=missing 的打回 ÷ 全部打回（调度器收割打回报告时写入）",
    "host.prereqs_missing": "host-prereqs.json 里每项每次体检做一次 TCP 连接或 HTTP 200 探测",
    "host.github_net_failures_per_hour": "journalctl --user 窗口内的最终失败行（origin fetch failed、git fetch: timed out after、api.github.com TLS handshake timeout）÷ 小时；没有 journal（Mac）为空",
    "engine.follow_lag_hours": "engine-sync converge 失败时写入的 $AGENT_HOME/engine-versions/.lag-since（epoch 秒），成功跟上即删除；没有该文件记 0",
    "host.stale_worktrees": "ZF_WORKTREE_ROOT（默认 ~/wt）下每个工作目录的 .git 链接文件建立时间早于 2 小时的个数；没有该目录（Mac）为空",
    "intake.closed_units_open_issues": "intake-candidates.json 的候选行里，单元全部处于终态且交接 episode 已消费的 issue 数；没有候选快照时为空",
    "flow.merge_rate_per_hour": "units.json 与 units-archive.json 的 merged/landed 事件 ÷ 24 h；无积压判定：窗口内没有任何在途或新进入的单",
    "flow.wip_age_stage_p90_hours": "units.json 在途单（stage 非终态）当前 stage 的最后事件时间 → now，按 stage 分组取 p90",
    "flow.wait_stage_p90_hours": "units.json 在途单 stage 为 blocked-external 或 parked：最后事件时间 → now，取 p90",
    "flow.wait_stage_units": "units.json 在途单 stage 为 blocked-external 或 parked 的个数",
    "flow.slot_idle_hours": "units.json 触发事件 + scheduler.log dispatch 行给出排队区间（同 time_sinks），worker_cost 运行区间给出同阶段在跑区间，取无人在跑的净空转",
    "flow.main_red_hours": "$AGENT_HOME/main-red/*.json 二分会话（created_at → updated_at，未终态会话算到 now），按窗口裁剪",
    "flow.in_out_imbalance": "units.json 首个事件落在窗口内 = 进入，merged/landed 落在窗口内 = 完成",
    "mechanism.silent": "engine/state/mechanism-registry.json 的事件模式匹配 scheduler.log / alerts/events.md / $AGENT_HOME/logs 的行（含轮转 .1 代），取每个机制最近一次事件时间",
    "workers.local_test_db": "每次体检对 PGTEST_URL（runtime-env.sh，zenoforge-pgtest.service）做 TCP 连接",
    "delivery.issue_to_accept_p50_7d_hours": "alerts/events.md release-closer accepted-at → GitHub issue createdAt（每个有一条验收记录的 issue；unit 关联只用于 unlinked_units）",
    "delivery.issue_to_accept_p95_7d_hours": "alerts/events.md release-closer accepted-at → GitHub issue createdAt（每个有一条验收记录的 issue；unit 关联只用于 unlinked_units）",
    "delivery.issue_to_accept_p50_30d_hours": "alerts/events.md release-closer accepted-at → GitHub issue createdAt（每个有一条验收记录的 issue；unit 关联只用于 unlinked_units）",
    "delivery.issue_to_accept_p95_30d_hours": "alerts/events.md release-closer accepted-at → GitHub issue createdAt（每个有一条验收记录的 issue；unit 关联只用于 unlinked_units）",
    "delivery.revert_rate_30d_pct": "units.json 接受单元的 merge SHA，与 origin/main Git revert commit 的 This reverts commit marker",
    "delivery.incident_rate_30d_pct": "night/founder-health-mail.json production incidents (same ledger as the owner mail) naming an issue ID in release-closer acceptance events ÷ unique accepted issue IDs",
    "delivery.cycles_to_pass_30d": "units.json review-approve / review-request-changes / review-block events before merged / landed",
    "delivery.approvals_per_merge_30d": "units.json review-approve events on merged / landed units",
    "delivery.unlinked_units_30d": "release-closer output in alerts/events.md joined by exact issue, unit, PR and merge IDs",
    "delivery.unlinked_incidents_30d": "night/founder-health-mail.json incidents (issue joined to accepted issue IDs) plus logs/head-watch.alerts PROD-DB-TIMEOUT episodes, which name no issue",
}
# Line-hold rows (holds.*) live in line_holds.py: node_health.py is at its size-ratchet baseline.
CRITERIA.update({**line_holds.CRITERIA, **station_standards.CRITERIA, **worker_cost.TOKEN_EFFICIENCY_CRITERIA})
MEANING.update({**line_holds.MEANING, **station_standards.MEANING, **worker_cost.TOKEN_EFFICIENCY_MEANING})
SOURCE.update({**line_holds.SOURCE, **station_standards.SOURCE, **worker_cost.TOKEN_EFFICIENCY_SOURCE})
# release.hours_since_release lives in release_age.py, rulings.copies_differ in rulings_copies.py, for the same size-ratchet reason.
CRITERIA.update(release_age.CRITERIA); MEANING.update(release_age.MEANING); SOURCE.update(release_age.SOURCE)
CRITERIA.update(release_retained.CRITERIA); MEANING.update(release_retained.MEANING); SOURCE.update(release_retained.SOURCE)
CRITERIA.update(rulings_copies.CRITERIA); MEANING.update(rulings_copies.MEANING); SOURCE.update(rulings_copies.SOURCE)
# Where the time of a work order goes: wait vs work per phase, over the last TIME_SINK_HOURS (enough samples).
# (description, statistic, healthy minutes, unhealthy minutes, meaning)
TIME_SINK_HOURS = 24
WALL_WINDOW_HOURS = 24  # implement/repair run-minute p50 window
TIME_SINKS = {
    "repair_queue": ("返工触发 → 派出返工员", "p90", 30, 120, "等 AI 员工名额。长 = 员工数不够，或派活顺序有问题。"),
    "repair_work": ("返工员干活", "p50", 15, 30, "一轮返工本身的时长。"),
    "rereview_queue": ("返工交付 → 派出复检", "p90", 10, 30, "复检排队。"),
    "rereview_work": ("复检干活", "p50", 10, 20, "一次增量复检本身的时长。"),
    "approve_to_ci_red": ("批准 → CI 判红", "p50", 60, 180, "批准后多久 CI 才发现问题：排队 + CI 运行。长 = 问题发现太晚，每轮返工都要再等一遍。"),
    "approve_to_merge": ("批准 → 发出合并", "p50", 60, 180, "批准后到真正合并：CI 名额、排队、运行与合并车道。"),
}
TIME_SINK_SOURCE = "units.json 事件时间 + scheduler.log 的 dispatch 行（派出时间）"
# Live CI numbers on the dashboard (gen_dashboard.py measures them each tick).
# (description, healthy, unhealthy, higher_is_better, meaning, source)
CI_STANDARDS = {
    "runners_online": ("在线 runner", 12, 11, True, "cihost 12 个。少了 = 机器掉线，CI 产能直接下降。", "GitHub API actions/runners"),
    "pr_runner_busy_pct": ("PR runner 忙碌占比（有排队时）", 70, 40, True, "有 run 在排队时还有 PR runner 空着 = 标签错配或调度浪费。", "GitHub API actions/runners 的 busy 字段"),
    "queued_runs": ("排队中的 workflow run", 40, 100, False, "排队越长，每个 PR 等全绿越久（Little 定律）。", "GitHub API actions/runs?status=queued"),
    "wip_waiting": ("等 CI 名额的就绪单元", 30, 60, False, "CI 在制品上限（ci_wip）外排队的已批准单元。长期很高 = CI 产能不够。", "units.json 的 ci_wip_wait"),
    "held_runs": ("被热修挡住的 run", 10, 50, False, "热修优先挡板取消的普通 run。长期很高 = 优先级变成饥饿（L75）。", "ci-held-runs.json"),
}
SIZE_BANDS = [(0, 300), (300, 800), (800, 2000), (2000, None)]
LARGE_PR_LINES = 800
LARGE_PR_WINDOW_DAYS = 30


def held_ready_pct(units, ledger_ok):
    """Share of ready-to-merge units whose CI is held for a hot patch; no ready units is 0 when units.json was read, NO-DATA when not."""
    ready = [u for u in units if u.get("stage") == "ready-to-merge"]
    if not ready:
        return 0 if ledger_ok else None
    return 100 * sum(1 for u in ready if u.get("ci_held_sha")) / len(ready)


def merge_pass_gap_min(units, ledger_ok, a, now):
    """Minutes since run_merge_lane last held the lane (.merge-pass-epoch), while a unit the lane would take waits in ready-to-merge.
    No such unit is 0 when units.json was read; no recorded pass yet is NO-DATA, not a gap."""
    ready = [u for u in units if u.get("stage") == "ready-to-merge" and not u.get("hold_handoff_waiting")
             and not u.get("supervisor_owned") and u.get("pr") is not None and u.get("lane") != "direct-main"]
    if not ready:
        return 0 if ledger_ok else None
    try:
        last = int(open(os.path.join(a, ".merge-pass-epoch")).read().strip())
    except (OSError, ValueError):
        return None
    return round(max(0, now.timestamp() - last) / 60, 1)


def status_of(v, healthy, unhealthy, higher):
    if v is None:
        return "NO-DATA"
    if (v >= healthy) if higher else (v <= healthy):
        return "OK"
    if (v <= unhealthy) if higher else (v >= unhealthy):
        return "UNHEALTHY"
    return "WARN"


def time_sinks(units, log_path, since, now):
    """Per phase: samples (minutes) of waiting and working, from ledger events and dispatch lines.

    Also returns the queue wait intervals (phase, trigger, dispatch) behind those samples —
    dispatched or still open — for the flow slot-idle metric."""
    disp = {}
    log_rows, _ = ledger_history.scheduler_log_lines(log_path, now)
    for raw in log_rows or []:
        m = DISPATCH_RE.match(raw)
        if m and (t := ts(m.group(1))):
            disp.setdefault((m.group(3), m.group(2)), []).append(t)
    out = {k: [] for k in TIME_SINKS}
    waits = []
    trig = ("review-request-changes", "review-block", "ci-red", "ci-test-red", "merge-conflict")
    for u in units:
        hist = [(h.get("stage") or "", ts(h.get("at"))) for h in u.get("history") or []]
        hist = [(k, t) for k, t in hist if t]
        for i, (k, t) in enumerate(hist):
            if t < since:
                continue
            if k in trig:
                # The repair answers the latest trigger before it: a trigger superseded by another one
                # (a rerun went green, then review asked for changes) is not a wait for a repair worker.
                nxt = next(((kk, x) for kk, x in hist[i + 1:] if kk in trig or kk == "repair-delivered"), None)
                done = nxt[1] if nxt and nxt[0] == "repair-delivered" else None
                d = min((x for x in disp.get((u.get("id"), "repair"), []) if x >= t), default=None)
                if d and done and d <= done:
                    out["repair_queue"].append((d - t).total_seconds() / 60)
                    out["repair_work"].append((done - d).total_seconds() / 60)
                    waits.append(("repair", t, d))
                    verdict = next((x for kk, x in hist[i + 1:] if kk in ("review-approve", "review-request-changes", "review-block") and x >= done), None)
                    rd = min((x for key in ("rereview", "review") for x in disp.get((u.get("id"), key), []) if x >= done), default=None)
                    if verdict and rd and rd <= verdict:
                        out["rereview_queue"].append((rd - done).total_seconds() / 60)
                        out["rereview_work"].append((verdict - rd).total_seconds() / 60)
                        waits.append(("rereview", done, rd))
                    elif not verdict and (rd or u.get("stage") == "rereview-pending"):
                        waits.append(("rereview", done, rd or now))
                elif not nxt and (d or u.get("stage") == "repair-pending"):
                    # An undispatched trigger waits only while the unit is still queued; parked/merged units are not waiting for a worker.
                    waits.append(("repair", t, d or now))
            elif k == "review-approve":
                nxt = next(((kk, x) for kk, x in hist[i + 1:] if kk in ("ci-red", "ci-test-red", "merge-issued")), None)
                if nxt:
                    out["approve_to_merge" if nxt[0] == "merge-issued" else "approve_to_ci_red"].append((nxt[1] - t).total_seconds() / 60)
    rows = []
    for key, (desc, stat, healthy, unhealthy, meaning) in TIME_SINKS.items():
        v = out[key]
        value = pct(v, .5 if stat == "p50" else .9)
        rows.append({"id": key, "desc": desc, "stat": stat, "n": len(v), "p50": pct(v, .5), "p90": pct(v, .9),
                     "total_hours": round(sum(v) / 60, 1), "value": value, "healthy": healthy, "unhealthy": unhealthy,
                     "status": status_of(value, healthy, unhealthy, False), "meaning": meaning, "source": TIME_SINK_SOURCE})
    return rows, waits


def merge_flow(units, since, now):
    """Merges per hour against the 6.5/h SLO (#4355), plus the in/out conservation counts.

    The rate has no value on a starved queue (nothing open, nothing entered): the SLO binds
    'with sufficient backlog', so an empty factory is not a throughput defect."""
    merges, entered, backlog = 0, 0, False
    for u in units:
        hist = [(h.get("stage") or "", ts(h.get("at"))) for h in u.get("history") or []]
        hist = [(k, t) for k, t in hist if t]
        if not hist:
            continue
        if since <= hist[0][1] <= now:
            entered += 1
        done = next((t for k, t in reversed(hist) if k in ("merged", "landed")), None)
        if done and since <= done <= now:
            merges += 1
        if done is None or done >= since or u.get("stage") not in UNIT_DONE:
            backlog = True
    hours = (now - since).total_seconds() / 3600
    return (merges / hours if backlog and hours > 0 else None), entered, merges


# Stages that wait by design (a predecessor, a stop-loss): their rows stay listed but never pick the worst stage.
WIP_WAITING = ("blocked-external", "parked")


def wip_stage_ages(units, now):
    """Each open unit's age in its current stage (last ledger event -> now), grouped by stage.

    The worst p90 skips WIP_WAITING stages: 54 units waiting on one parked predecessor read 228 h
    on 2026-11-07 and hid the one stage a worker could move (supervisor-review, 8 h)."""
    ages = {}
    for u in units:
        if u.get("stage") in UNIT_DONE:
            continue
        times = [t for t in (ts(h.get("at")) for h in u.get("history") or []) if t]
        if not times:
            continue
        ages.setdefault(u.get("stage") or "unknown", []).append(
            ((now - max(times)).total_seconds() / 3600, u.get("id")))
    rows = []
    for stage in sorted(ages):
        hours = sorted(h for h, _ in ages[stage])
        oldest = sorted(ages[stage], key=lambda h: h[0], reverse=True)[:5]
        rows.append({"stage": stage, "count": len(hours), "p90_hours": round(pct(hours, .9), 1),
                     "waiting": stage in WIP_WAITING,
                     "oldest": [{"id": uid, "age_hours": round(h, 1)} for h, uid in oldest]})
    worst = max((r["p90_hours"] for r in rows if r["p90_hours"] is not None and not r["waiting"]), default=None)
    return rows, worst


def wait_stage(units, now):
    """p90 hours (last ledger event -> now) and count of open units in WIP_WAITING: the waits the worst pick skips."""
    ages = []
    for u in units:
        if u.get("stage") not in WIP_WAITING:
            continue
        times = [t for t in (ts(h.get("at")) for h in u.get("history") or []) if t]
        if times:
            ages.append((now - max(times)).total_seconds() / 3600)
    return (round(pct(ages, .9), 1) if ages else None), len(ages)


def slot_idle_hours(waits, cost_rows, since):
    """Hours a queued unit waited for a repair/rereview worker while none of that phase ran.

    A bottleneck busy all through the wait is a capacity problem; a bottleneck with no worker
    running while work waits is a dispatch stall — that idle time is the metric."""
    by_phase = {}
    for r in cost_rows:
        by_phase.setdefault(r["phase"], []).append((r["start"], r["end"]))
    # Wall-clock stall: units waiting side by side share one idle slot, so overlapping waits count once.
    merged = []
    for phase, start, end in sorted((w[0], max(w[1], since), w[2]) for w in waits):
        if end > start:
            if merged and merged[-1][0] == phase and start <= merged[-1][2]:
                merged[-1][2] = max(merged[-1][2], end)
            else:
                merged.append([phase, start, end])
    idle = 0.0
    for phase, start, end in merged:
        spans = sorted((max(s, start), min(e, end)) for s, e in by_phase.get(phase, [])
                       if max(s, start) < min(e, end))
        frontier = start
        for s, e in spans:
            if s > frontier:
                idle += (s - frontier).total_seconds() / 3600
            frontier = max(frontier, e)
        if frontier < end:
            idle += (end - frontier).total_seconds() / 3600
    return round(idle, 2)


# An open session is rewritten at every transition, and a probe wait or the 10 min dispatch retry
# never leaves it untouched for hours. One idle this long is no longer advancing (main went green
# and nothing closed it), so it ends at its last transition. The reader holds no CI run list to
# find the first green main run, so idleness is the bound it can know.
MAIN_RED_OPEN_IDLE_HOURS = 6


def main_red_hours(red_dir, since, now):
    """Hours main was red in the window, from the #4356 bisect sessions.

    A session still in the state machine counts to now unless it has been idle longer than
    MAIN_RED_OPEN_IDLE_HOURS; flaky/recovered/reverted/unattributed ended at their last transition.
    None without a main-red directory (hosts without the merge lane)."""
    try:
        names = os.listdir(red_dir)
    except OSError:
        return None
    spans = []
    for name in names:
        if not name.endswith(".json"):
            continue
        session = read_json(os.path.join(red_dir, name))
        created, updated = ts(session.get("created_at")), ts(session.get("updated_at"))
        if not created or not re.fullmatch(r"[0-9a-f]{40}", str(session.get("red_sha") or "")):
            continue
        idle = updated and (now - updated).total_seconds() > MAIN_RED_OPEN_IDLE_HOURS * 3600
        end = updated if updated and (idle or session.get("status") in ("flaky", "recovered", "reverted", "unattributed")) else now
        spans.append((max(created, since), min(end, now)))
    total, frontier = 0.0, since  # overlapping sessions are one wall-clock red: merge before summing
    for start, end in sorted(spans):
        total += max((end - max(start, frontier)).total_seconds(), 0)
        frontier = max(frontier, end)
    return round(total / 3600, 2)


MECHANISM_LINE_TS_RE = re.compile(r"^\[?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\]?")


def mechanism_heartbeat(registry, runtime, agent_home, now):
    """(#4495 M2) Each registered mechanism's latest event vs its silence bound.

    A mechanism whose code landed but is not live emits no events (#4483: f3 was in
    while release_train.enabled=false stopped releases for 18 h). The registry names the
    event sources; rotate_logs keeps one .1 generation, which is read too. expected_idle
    entries may sit indefinitely quiet (the mechanism's condition simply did not occur)
    and are reported but never counted. held_when_false names a runtime config key (dotted):
    when that key is the literal false the mechanism is switched off on purpose, so its row is
    expected_idle and flagged held; a true or missing key keeps the silence check. not_operating
    is a reason string: the mechanism cannot do its job, so its events prove nothing and its row
    shows that reason instead of a heartbeat."""
    rows, silent = [], 0
    cfg = read_json(os.path.join(runtime, "config.json"))
    for m in registry:
        value = cfg
        for part in (m.get("held_when_false") or "").split("."):
            value = value.get(part) if isinstance(value, dict) else None
        held = bool(m.get("held_when_false")) and value is False
        last = None
        for event in m["events"]:
            root = agent_home if event["base"] == "agent_home" else runtime
            for path in (os.path.join(root, event["file"]), os.path.join(root, event["file"] + ".1")):
                try:
                    with open(path, errors="ignore") as source:
                        for raw in source:
                            stamp = MECHANISM_LINE_TS_RE.match(raw)
                            if stamp and re.search(event["pattern"], raw) and (t := ts(stamp.group(1))) and (last is None or t > last):
                                last = t
                except OSError:
                    continue
        age = (now - last).total_seconds() / 3600 if last else None
        not_operating = m.get("not_operating")
        idle = m.get("expected_idle") is True or held or bool(not_operating)
        quiet = not idle and (age is None or age > m["silence_hours"])
        silent += quiet
        rows.append({"id": m["id"], "desc": m["desc"], "supervisor": m["supervisor"],
                     "last_event_at": f"{last:%Y-%m-%dT%H:%M:%SZ}" if last else None,
                     "silent_hours": round(age, 1) if age is not None else None,
                     "bound_hours": m["silence_hours"], "expected_idle": idle, "held": held,
                     "not_operating": not_operating,
                     "silent": quiet})
    return rows, silent


def size_window_units(units, since, now):
    """PR units active in the window, including newly registered undated work."""
    for u in units:
        if not u.get("pr"):
            continue
        times = [t for t in (ts(h.get("at")) for h in u.get("history") or []) if t]
        if any(since <= t <= now for t in times) or (not times and u.get("stage") and u["stage"] not in UNIT_DONE):
            yield u


def rework_by_size(units, sizes, nontest_added, since, now):
    """Repairs per ledger PR by changed-line band; large share uses non-test additions.

    Only PRs with a ledger event in the 30-day window (#4482): the all-ledger share could
    only fall by dilution, so one-off oversized PRs kept it unhealthy indefinitely."""
    per, large_sizes = [], []
    for u in size_window_units(units, since, now):
        number = str(u.get("pr"))
        lines = sizes.get(number)
        if lines is not None:
            per.append((lines, sum(1 for h in u.get("history") or [] if h.get("stage") == "repair-delivered")))
        nontest = nontest_added.get(number)
        if nontest is not None:  # a PR with no size row is left out of the share, not voiding it
            large_sizes.append(nontest)
    rows = []
    for lo, hi in SIZE_BANDS:
        reps = sorted(r for n, r in per if n >= lo and (hi is None or n < hi))
        rows.append({"band": f"{lo}–{hi}" if hi else f"≥{lo}", "units": len(reps), "median_repairs": pct(reps, .5),
                     "share_4plus": round(100 * sum(1 for r in reps if r >= 4) / len(reps)) if reps else None})
    large = 100 * sum(1 for n in large_sizes if n > LARGE_PR_LINES) / len(large_sizes) if large_sizes else None
    return rows, large


# Spend standards for one work order. Past the bug bound a unit is a pipeline defect, not "a hard issue".
# Bounds from the 2026-10-21 distribution of 94 delivered units (tokens p50 0.53M / p90 2.4M, worker minutes
# p50 25 / p90 90, rounds p50 0 / p90 2, entry → merged p50 7.4 h / p90 18.5 h): healthy ≈ p90, bug ≈ 2-4x p90.
UNIT_STANDARDS = workorder_cost.UNIT_STANDARDS
UNIT_DONE = workorder_cost.UNIT_DONE
ESCALATE_HOURS, REFILE_HOURS = 3, 6
RUNNING_LOG_SECONDS = 600
SUPERVISOR_EVENTS = ("supervisor-requeue", "supervisor-approve", "supervisor-close", "supervisor-park",
                     "supervisor-decision", "supervisor-reroute", "supervisor-unblock", "arbiter-review")
# The live line is `dispatch claim=owned issue=N mode=.. reason=.. pid=P type=T unit=U` (station_health.py reads the same); older logs had no claim/issue/reason.
DISPATCH_RE = re.compile(r"^\[(\S+)\] dispatch (?:claim=\S+ )?(?:issue=\S+ )?mode=\S+ (?:reason=\S+ )?pid=\d+ type=(repair|rereview|review) unit=(\S+)")
LINE_RE = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] tick done")


def ts(value):
    try:
        return datetime.strptime(str(value)[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))] if values else None


def worker_runs(rows, since, now):
    """Windowed view of the shared cost rows (worker_cost.run_rows): wall, tokens, report facts.

    Tokens keep the historical blend: the legacy footer's total, else fresh usage from a
    --json stream or Claude project response inside the run interval."""
    runs = []
    for r in rows:
        if r["start"] < since or r["start"] > now:
            continue
        report = r["path"][: -len(".worker.log")] + ".md"
        output = os.path.exists(report) and os.path.getsize(report) > 0
        # A live worker keeps writing its log: no report yet is "running", not "no output" (a running
        # implement read as a 50 % no-report rate on 2026-10-21).
        running = not output and (now - r["end"]).total_seconds() < RUNNING_LOG_SECONDS
        usage = r["usage"]
        if r["footer_tokens"] is not None:
            tokens = r["footer_tokens"]
        elif usage is not None:
            tokens = usage.fresh
        else:
            tokens = None
        runs.append({"node": r["phase"], "unit": r["unit"], "start": r["start"],
                     "minutes": r["minutes"], "tokens": tokens,
                     "output": output, "running": running, "self_fix": r["self_fix"]})
    return runs


def rework_token_pct(runs):
    """Repair and rereview share of worker tokens over the runs whose usage was measured (the caller shows how many)."""
    measured = [r for r in runs if r["tokens"] is not None]
    tokens = sum(r["tokens"] for r in measured)
    if not tokens:
        return None
    rework = sum(r["tokens"] for r in measured if r["node"] in ("repair", "rereview"))
    return 100 * rework / tokens


unit_spend = workorder_cost.unit_spend
work_orders = workorder_cost.work_orders


def local_test_db():
    """1 when the worker-side PGTEST_URL server accepts a connection: integration tests run before push."""
    url = urllib.parse.urlsplit(os.environ.get("PGTEST_URL") or "")
    if not url.hostname:
        return 0
    try:
        socket.create_connection((url.hostname, url.port or 5432), timeout=2).close()
        return 1
    except OSError:
        return 0


# Final-failure lines only (a retried fetch logs "timed out; retrying" first), so one failed fetch counts once.
GITHUB_NET_FAILURE_RE = re.compile(r'origin fetch failed after|git fetch: timed out after|Post "https://api\.github\.com[^"]*": net/http: TLS handshake timeout')


def github_net_failures_per_hour(since, now):
    """GitHub network failures logged by user units per hour; None where there is no user journal (Mac)."""
    fmt = "%Y-%m-%d %H:%M:%S UTC"
    try:
        out = subprocess.run([os.environ.get("NODE_HEALTH_JOURNALCTL") or "journalctl", "--user", "--no-pager", "-o", "cat",
                              "--since", since.strftime(fmt), "--until", now.strftime(fmt)],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    hours = (now - since).total_seconds() / 3600
    if out.returncode != 0 or hours <= 0:
        return None
    return sum(1 for line in out.stdout.splitlines() if GITHUB_NET_FAILURE_RE.search(line)) / hours


STALE_WORKTREE_HOURS = 2


def engine_follow_lag_hours(agent_home, now):
    try:
        since = int(open(os.path.join(agent_home, "engine-versions", ".lag-since")).read().strip())
    except (OSError, ValueError):
        return 0.0
    return round(max(0.0, now.timestamp() - since) / 3600, 2)


def stale_worktrees(now, root=None):
    """Worktrees under ~/wt whose .git link (written once at `git worktree add`) is older than 2 h; None without ~/wt."""
    root = root or os.environ.get("ZF_WORKTREE_ROOT") or os.path.expanduser("~/wt")
    try:
        entries = os.listdir(root)
    except OSError:
        return None
    cutoff = now.timestamp() - STALE_WORKTREE_HOURS * 3600
    count = 0
    for name in entries:
        try:
            if os.lstat(os.path.join(root, name, ".git")).st_mtime < cutoff:
                count += 1
        except OSError:
            continue
    return count


def host_prereqs_missing(path=None):
    """Names of host-prereqs.json entries that do not answer (TCP connect, or HTTP 200 without any proxy)."""
    path = path or os.environ.get("HOST_PREREQS_FILE") or zf_host_ops_file(
        "scripts/agent/mac-autopilot/host-prereqs.json",
        os.path.join(os.path.dirname(os.path.realpath(__file__)), "host-prereqs.json"),
    )
    try:
        prereqs = json.load(open(path))["prereqs"]
    except (OSError, ValueError, KeyError):
        return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    missing = []
    for p in prereqs:
        try:
            if "tcp" in p:
                host, port = p["tcp"].rsplit(":", 1)
                socket.create_connection((host, int(port)), timeout=2).close()
            elif opener.open(p["http"], timeout=3).status != 200:
                missing.append(p["name"])
        except (OSError, ValueError):
            missing.append(p["name"])
    return missing


def shared_append_rebase_metrics(path, repo, since, now):
    """(attempts, pct): shared-append landings whose rebase conflicted on a shared-append file.

    Reads the JSONL land-direct-main appends per rebase attempt whose landing range
    touches a shared-append file; a conflict row carries the unmerged shared files.
    None means no observation (no file / no attempts in the window)."""
    try:
        rows = []
        with open(path, errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or not row.get("when"):
                    continue
                if row.get("repo") and row["repo"] != repo:
                    continue
                rows.append(row)
    except OSError:
        return None, None
    attempts = []
    for row in rows:
        at = ts(row.get("when"))
        if at and since <= at <= now and row.get("shared_files"):
            attempts.append(row)
    conflicts = [row for row in attempts if row.get("conflict_files")]
    return len(attempts), (100 * len(conflicts) / len(attempts) if attempts else None)


def post_land_runs_ratio(requests_dir, repo, since, now, gh_json):
    """Post-land Pipeline suites runs per direct-main landing in the window. None when nothing landed
    or the run list cannot be read (no observation); 0 with landings is the broken-check signal."""
    landings = 0
    for path in glob.glob(os.path.join(requests_dir, "*.json")):
        try:
            with open(path) as handle:
                row = json.load(handle)
        except (OSError, ValueError):
            continue
        done = row.get("finished_epoch") if isinstance(row, dict) else None
        if (row.get("direct_landing") is True and row.get("state") == "landed"
                and isinstance(done, (int, float)) and since.timestamp() <= done <= now.timestamp()):
            landings += 1
    if not landings or not repo:
        return None
    created = urllib.parse.quote(">=" + since.strftime("%Y-%m-%dT%H:%M:%SZ"))
    response = gh_json(["api", f"repos/{repo}/actions/workflows/pipeline-suites.yml/runs?branch=main&per_page=100&created={created}"],
                       GH_DELIVERY_CALL_TIMEOUT)
    if not isinstance(response, dict) or not isinstance(response.get("workflow_runs"), list):
        return None
    runs = sum(1 for run in response["workflow_runs"] if str(run.get("display_title") or "").startswith("Pipeline suites post-land "))
    return runs / landings


RED_STAGES = ("ci-red", "ci-test-red", "ci-red-rerun")


def red_after_approve(units, since):
    """(approved unit count, one row per unit) for units approved in the window that saw CI red after
    an approve and before the next verdict. A unit counts once however many approves it had; the row
    names the failed checks and, for ci-test-red, the failing tests recorded on the event."""
    approved, rows = 0, []
    for u in units:
        events = [(h.get("stage") or h.get("ev") or "", ts(h["at"]), h) for h in u.get("history") or [] if ts(h.get("at"))]
        red, seen = [], False
        for i, (k, t, _) in enumerate(events):
            if k == "review-approve" and t >= since:
                seen = True
                rest = events[i + 1:]
                stop = next((j for j, x in enumerate(rest) if x[0] in ("review-request-changes", "review-approve")), len(rest))
                red += [x[2] for x in rest[:stop] if x[0] in RED_STAGES]
        approved += seen
        if red:
            rows.append({"unit": u.get("id"), "reds": len(red), "stage": red[-1].get("stage"),
                         "checks": red[-1].get("result") or "", "tests": red[-1].get("tests") or []})
    return approved, rows


def ledger_metrics(units, since, now, window_hours=None):
    first_reviews, rounds, approve_to_ship, sup_lat, deaths = [], [], [], [], 0
    for u in units:
        hist = [h for h in u.get("history") or [] if ts(h.get("at"))]
        kinds = [(h.get("stage") or h.get("ev") or "", ts(h["at"])) for h in hist]
        deaths += sum(1 for k, t in kinds if k == "worker-no-output" and t >= since)
        verdicts = [(k, t) for k, t in kinds if k in ("review-approve", "review-request-changes", "review-block")]
        if verdicts and now - timedelta(hours=window_hours or 24) <= verdicts[0][1] <= now:  # fixed 24 h unless short-cohort scoring was requested
            first_reviews.append(verdicts[0][0] == "review-approve")
        n = 0
        for i, (k, t) in enumerate(kinds):
            if k == "review-request-changes":
                n += 1
            elif k == "review-approve":
                if t >= since:
                    rounds.append(n)
                    rest = kinds[i + 1:]
                    nxt = next((x for x in rest if x[0] in ("review-request-changes", "review-approve")), None)
                    window = rest[: rest.index(nxt)] if nxt else rest
                    ship = next((x for x in window if x[0] in ("merged", "landed")), None)
                    if ship:
                        approve_to_ship.append((ship[1] - t).total_seconds() / 60)
                    elif not nxt and u.get("stage") in ("ready-to-merge", "landing"):
                        # Still waiting: count the age so far, or only the fast ones would be measured.
                        approve_to_ship.append((now - t).total_seconds() / 60)
                n = 0
            elif k == "supervisor-escalated" and t >= since:
                done = next((x for x in kinds[i + 1:] if x[0] in SUPERVISOR_EVENTS), None)
                if done:
                    sup_lat.append((done[1] - t).total_seconds() / 60)
    asked = [k for u in units for k, t in ((h.get("stage") or "", ts(h.get("at"))) for h in u.get("history") or [])
             if t and t >= since and k in ("advisor-ruling", "advisor-unavailable")]
    precheck_setup_failures = sum(
        1 for u in units for h in u.get("history") or []
        if (h.get("stage") or h.get("ev") or "") == "precheck"
        and (h.get("result") or "").startswith("PRECHECK: SKIP workspace package selection failed")
        and (t := ts(h.get("at"))) and t >= since
    )
    approved, red_units = red_after_approve(units, since)
    rejections = [r.get("block") == "missing" for u in units for r in u.get("review_findings") or []
                  if (t := ts(r.get("at"))) and t >= since]
    return {**arbiter_health.ledger_metrics(units, now, ts, window_hours), **ledger_history.metrics(units, now, ts, window_hours),
        "review.findings_missing_pct": 100 * sum(rejections) / len(rejections) if rejections else None,
        "loop.advisor_fail_pct": 100 * asked.count("advisor-unavailable") / len(asked) if asked else None,
        "review.first_pass_pct": 100 * sum(first_reviews) / len(first_reviews) if first_reviews else None,
        "loop.rounds_p90": pct(rounds, .9),
        "ci.approve_to_ship_p50": pct(approve_to_ship, .5),
        "ci.red_after_approve_pct": 100 * len(red_units) / approved if approved else None,
        "ci.precheck_setup_failures": precheck_setup_failures,
        "supervisor.latency_p50": pct(sup_lat, .5),
        "workers.deaths": deaths,
    }


def advisor_answer_age_hours(agent_home, repo, now):
    """Dead-man: age of the newest successful advisor job, only while tickets wait for it."""
    queue = _gh_json(["issue", "list", "--repo", repo, "--label", "needs-advisor", "--state", "open",
                      "--limit", "1", "--json", "number"], 60)
    if queue is None:
        return None
    if not queue:
        return 0.0
    newest = 0.0
    # A finished batch deletes its job dir, so the durable success record is the tick result with outcome "completed".
    for res in glob.glob(os.path.join(agent_home, "logs", "advisor-batch-*.result.json")):
        try:
            if json.load(open(res)).get("outcome") == "completed":
                newest = max(newest, os.path.getmtime(res))
        except (OSError, ValueError, AttributeError):
            continue
    for err in glob.glob(os.path.join(agent_home, "web-advisor-provider-jobs", "*", "answer.err")):
        try:
            # answer.txt marks a captured answer; a bare answer.err without FAIL: can be a job that died early.
            if os.path.exists(os.path.join(os.path.dirname(err), "answer.txt")) and "FAIL:" not in open(err, errors="replace").read():
                newest = max(newest, os.path.getmtime(err))
        except OSError:
            continue
    return max(0.0, (now.timestamp() - newest) / 3600) if newest else 9999.0


def read_json(path):
    try:
        value = json.load(open(path))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def load_prod_incidents(agent_home):
    """Owner-mail ledger incidents plus head-watch alert episodes, as delivery_metrics records; None if either is unreadable."""
    try:
        rows = json.load(open(os.path.join(agent_home, "night", "founder-health-mail.json"))).get("incidents")
        days = watch_alerts.episode_dates(os.path.join(agent_home, "logs", "head-watch.alerts"))
        return [{"issue": r.get("issue"), "date": datetime.fromtimestamp(int(r["opened_at"]), timezone.utc).strftime("%Y-%m-%d")}
                for r in rows] + [{"date": day} for day in days]
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None


def read_cancel_audit(path, repo):
    """Read shared cancel-cause records for this repo; None means the source is unavailable."""
    try:
        rows = []
        with open(path, errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or not row.get("when") or not row.get("run_id"):
                    continue
                if row.get("repo") and row["repo"] != repo:
                    continue
                rows.append(row)
        return rows
    except OSError:
        return None


def cancel_reason(reason):
    text = str(reason or "").split(";", 1)[0].strip().lower()
    if text == "ci deferred":
        return "deferred"
    if text == "ci wip":
        return "slot_wait"
    if text.startswith("repair dispatched"):
        return "repair"
    if text.startswith("tests already red"):
        return "tests_red"
    if text.startswith("review requested changes"):
        return "review_changes"
    if text.startswith("review blocked"):
        return "review_blocked"
    if text.startswith("parked"):
        return "parked"
    if text == "superseded by newer main head":
        return "superseded"
    if text == "ci hold":
        return "priority_hold"
    return "other"


def audited_cancel_reasons(records, since, until):
    """Latest non-empty cause per run in a window; duplicate API attempts remain one M1 run."""
    if records is None:
        return None
    by_run = {}
    for index, row in enumerate(records):
        at = ts(row.get("when"))
        if not at or not since <= at <= until:
            continue
        key = (row.get("repo") or "", str(row["run_id"]))
        previous = by_run.get(key)
        reason = row.get("reason") or (previous[2] if previous else "")
        if previous is None or (at, index) >= (previous[0], previous[1]):
            by_run[key] = (at, index, reason)
    return [cancel_reason(reason) for _, _, reason in by_run.values()]


def cancel_metrics(records, since, until):
    counts = audited_cancel_reasons(records, since, until)
    ids = {
        "deferred": "ci.cancel_deferred_per_day",
        "slot_wait": "ci.cancel_slot_wait_per_day",
        "repair": "ci.cancel_repair_per_day",
        "tests_red": "ci.cancel_tests_red_per_day",
        "review_changes": "ci.cancel_review_changes_per_day",
        "review_blocked": "ci.cancel_review_blocked_per_day",
        "parked": "ci.cancel_parked_per_day",
        "superseded": "ci.cancel_superseded_per_day",
        "other": "ci.cancel_other_per_day",
    }
    if counts is None:
        return {metric: None for metric in ids.values()}, None
    hours = (until - since).total_seconds() / 3600
    per_day = {metric: 0 for metric in ids.values()}
    if hours <= 0:
        return {metric: None for metric in ids.values()}, 0
    for cause in counts:
        if cause in ids:
            per_day[ids[cause]] += 24 / hours
    return per_day, counts.count("priority_hold")


def gated_agent_pr_share(repo):
    """M12 from the provider's open-PR census and server-side gate label."""
    try:
        result = subprocess.run(
            ["gh", "pr", "list", "--repo", repo, "--state", "open", "--limit", "1000",
             "--json", "headRefName,labels"], capture_output=True, text=True)
        if result.returncode != 0:
            return None
        prs = json.loads(result.stdout or "[]")
        if not isinstance(prs, list):
            return None
        active = [pr for pr in prs if isinstance(pr, dict) and
                  str(pr.get("headRefName") or "").startswith("agent/issue-")]
        if not active:
            return None
        gated = sum(any(isinstance(label, dict) and label.get("name") == "agent/ci-gated"
                        for label in pr.get("labels") or []) for pr in active)
        return 100 * gated / len(active)
    except (OSError, ValueError, TypeError):
        return None


RELEASE_CLOSER_RE = re.compile(r"release-closer: deployed=([0-9a-f]{7,40}) closed=\[([0-9,\s]*)\]")
def release_acceptances(runtime):
    """Read the batch close event, which names the accepted deployed SHA and issue IDs."""
    paths = [os.path.join(runtime, "alerts", "events.md"), os.path.join(runtime, "scheduler.log")]
    events, seen = [], set()
    found_source = False
    for path in paths:
        try:
            with open(path, errors="ignore") as source:
                found_source = True
                for raw in source:
                    match = RELEASE_CLOSER_RE.search(raw)
                    at = ts(raw[1:21]) if raw.startswith("[") else None
                    if not match or not at:
                        continue
                    for number in re.findall(r"\d+", match.group(2)):
                        event = {"issue": int(number), "sha": match.group(1), "at": at.strftime("%Y-%m-%dT%H:%M:%SZ")}
                        key = (event["issue"], event["sha"], event["at"])
                        if key not in seen:
                            seen.add(key)
                            events.append(event)
        except OSError:
            continue
    return events if found_source else None


def gh_delivery_rows(repo, now, units=None, release_events=None):
    """Fetch issue creation times and recent merged-PR review activity for delivery metrics."""
    cutoff = (now - timedelta(days=30)).strftime("%Y-%m-%d")
    issues = _gh_json(["issue", "list", "--repo", repo, "--state", "closed", "--search", f"closed:>={cutoff}",
                       "--limit", "1000", "--json", "number,createdAt"], GH_DELIVERY_CENSUS_TIMEOUT)
    rows = {"issues": issues if isinstance(issues, list) else None,
            "prs": pr_census.fetch(repo, cutoff, _gh_json, GH_DELIVERY_CENSUS_TIMEOUT)}
    if rows["issues"] is not None and rows["prs"] is not None and units is not None and release_events is not None:
        since = now - timedelta(days=30)
        accepted_issues = {_number(event.get("issue")) for event in release_events
                           if _number(event.get("issue")) is not None and
                           (at := ts(event.get("at"))) and since <= at <= now}
        available_issues = {_number(issue.get("number")) for issue in rows["issues"]
                            if _number(issue.get("number")) is not None}
        fallback_commands = []
        for number in sorted(accepted_issues - available_issues):
            fallback_commands.append(("issues", number,
                                      ["issue", "view", str(number), "--repo", repo, "--json", "number,createdAt"]))
        required_prs = {_number(unit.get("pr")) for unit in units
                        if _number(unit.get("issue")) in accepted_issues and _number(unit.get("pr")) is not None}
        available_prs = {_number(pr.get("number")) for pr in rows["prs"] if _number(pr.get("number")) is not None}
        for number in sorted(required_prs - available_prs):
            fallback_commands.append(("prs", number,
                                      ["pr", "view", str(number), "--repo", repo, "--json",
                                       "number,mergedAt,mergeCommit"]))
        results = _parallel_gh_json([command for _, _, command in fallback_commands], GH_DELIVERY_CALL_TIMEOUT)
        for (key, number, _), row in zip(fallback_commands, results):
            if not isinstance(row, dict) or _number(row.get("number")) != number:
                rows[key] = None
            elif rows[key] is not None:
                rows[key].append(row)
    return rows["issues"], rows["prs"]


def _gh_json(command, timeout):
    try:
        result = subprocess.run(["gh", *command], capture_output=True, text=True, timeout=timeout)
        return json.loads(result.stdout or "null") if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def _parallel_gh_json(commands, call_timeout):
    """Run independent gh reads with bounded concurrency and a deadline for the batch."""
    if not commands:
        return []
    pool = ThreadPoolExecutor(max_workers=min(GH_DELIVERY_FANOUT, len(commands)))
    futures = {pool.submit(_gh_json, command, call_timeout): index for index, command in enumerate(commands)}
    done, pending = wait(futures, timeout=GH_DELIVERY_BATCH_TIMEOUT)
    results = [None] * len(commands)
    for future in done:
        results[futures[future]] = future.result()
    for future in pending:
        future.cancel()
    pool.shutdown(wait=False, cancel_futures=True)
    return results


def _number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _merge_time(unit):
    times = [ts(event.get("at")) for event in unit.get("history") or []
             if event.get("stage") in ("merged", "landed")]
    times = [value for value in times if value]
    return max(times) if times else None


def git_revert_times(root, tip="HEAD"):
    """Map reverted merge SHAs to their newest revert commit time on a Git tip."""
    try:
        result = subprocess.run(
            ["git", "-C", root, "log", "--format=%ct%x00%B%x1e", "--grep=This reverts commit", tip],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0:
            return None
    except (OSError, subprocess.TimeoutExpired):
        return None
    reverted = {}
    for record in result.stdout.split("\x1e"):
        epoch, separator, message = record.partition("\x00")
        if not separator:
            continue
        try:
            at = datetime.fromtimestamp(int(epoch.strip()), timezone.utc)
        except (ValueError, OverflowError, OSError):
            continue
        for merge_sha in re.findall(r"This reverts commit ([0-9a-f]{40})\.", message):
            if merge_sha not in reverted or at > reverted[merge_sha]:
                reverted[merge_sha] = at
    return reverted


def delivery_metrics(units, issue_rows, pr_rows, release_events, incidents, now, repo="",
                     reverted_merge_times=None, window_hours=None):
    """Join recorded issue/unit/PR/merge/release IDs and summarize the last 7/30 days."""
    since_7d, since_30d = (now - timedelta(hours=window_hours),) * 2 if window_hours else (now - timedelta(days=7), now - timedelta(days=30))
    values = {key: None for key in CRITERIA if key.startswith("delivery.")}
    details = {
        "accepted_units_7d": None, "accepted_units_30d": None, "merged_units_30d": None,
        "unlinked_units_30d": None, "incident_records_30d": None, "unlinked_incidents_30d": None,
    }

    accepted = []
    release_events_by_issue = None
    accepted_release_issues_30d = None
    if release_events is not None:
        release_events_by_issue = {}
        release_events_7d_by_issue = {}
        for event in release_events:
            issue_number, at = _number(event.get("issue")), ts(event.get("at"))
            if issue_number is None or not at or at > now or at < since_30d:
                continue
            release_events_by_issue.setdefault(issue_number, []).append(event)
            if at >= since_7d:
                release_events_7d_by_issue.setdefault(issue_number, []).append(event)
        accepted_release_issues_30d = set(release_events_by_issue)
        details["accepted_units_7d"] = len(release_events_7d_by_issue)
        details["accepted_units_30d"] = len(accepted_release_issues_30d)

    if issue_rows is not None and pr_rows is not None and release_events_by_issue is not None:
        issues = {_number(row.get("number")): row for row in issue_rows if _number(row.get("number")) is not None}
        prs = {_number(pr.get("number")): pr for pr in pr_rows if _number(pr.get("number")) is not None}
        units_by_issue = {}
        for unit in units:
            # Older units carry no issue field; their branch agent/issue-N names the issue.
            branch = re.fullmatch(r"agent/issue-(\d+)", str(unit.get("branch") or ""))
            for issue_number in {_number(unit.get("issue")), int(branch[1]) if branch else None} - {None}:
                units_by_issue.setdefault(issue_number, []).append(unit)
        unlinked, lead_hours = 0, []
        for issue_number, events in release_events_by_issue.items():
            issue = issues.get(issue_number)
            created_at = ts((issue or {}).get("createdAt") or (issue or {}).get("created_at"))
            acceptance_event = events[0] if len(events) == 1 else None
            accepted_at = ts((acceptance_event or {}).get("at"))
            # Lead time needs only the issue's creation and its one acceptance; the unit join below is an
            # integrity check and must not choose the sample (50 of 64 accepted issues predate the ledger).
            if created_at and accepted_at and created_at <= accepted_at:
                lead_hours.append((accepted_at, (accepted_at - created_at).total_seconds() / 3600))
            candidates = units_by_issue.get(issue_number, [])
            unit = candidates[0] if len(candidates) == 1 else None
            merge_at = _merge_time(unit) if unit else None
            pr_number = _number((unit or {}).get("pr"))
            pr = prs.get(pr_number)
            pr_merge_at = ts((pr or {}).get("mergedAt") or (pr or {}).get("merged_at"))
            unit_merge_sha = (unit or {}).get("merge_sha") or (unit or {}).get("land_sha")
            pr_merge_sha = ((pr or {}).get("mergeCommit") or {}).get("oid")
            release_sha = (acceptance_event or {}).get("sha")
            if (len(events) != 1 or not created_at or not accepted_at or created_at > accepted_at or
                    not unit or pr_number is None or not pr or not merge_at or not pr_merge_at or
                    not re.fullmatch(r"[0-9a-f]{40}", str(unit_merge_sha or "")) or
                    unit_merge_sha != pr_merge_sha or merge_at > accepted_at or pr_merge_at > accepted_at or
                    not release_sha):
                unlinked += 1
                continue
            accepted.append({"issue": issue_number, "unit": unit, "accepted_at": accepted_at,
                             "created_at": created_at, "release_sha": release_sha})

        accepted = [row for row in accepted if row["accepted_at"] <= now]
        details["unlinked_units_30d"] = unlinked
        for since, target in ((since_7d, "7d"), (since_30d, "30d")):
            window = [hours for at, hours in lead_hours if at >= since]
            values[f"delivery.issue_to_accept_p50_{target}_hours"] = pct(window, .5)
            values[f"delivery.issue_to_accept_p95_{target}_hours"] = pct(window, .95)
        if accepted and reverted_merge_times is not None:
            reverted = 0
            for row in accepted:
                merge_sha = row["unit"].get("merge_sha") or row["unit"].get("land_sha")
                reverted_at = reverted_merge_times.get(merge_sha)
                if reverted_at and row["accepted_at"] <= reverted_at <= now:
                    reverted += 1
            values["delivery.revert_rate_30d_pct"] = 100 * reverted / len(accepted)

    if incidents is not None:
        incident_rows = []
        seen = set()
        for incident in incidents:
            incident_id = incident.get("id")
            if incident_id and incident_id in seen:
                continue
            if incident_id:
                seen.add(incident_id)
            date = str(incident.get("date") or "")[:10]
            incident_at = ts(date + "T00:00:00Z") if re.fullmatch(r"\d{4}-\d\d-\d\d", date) else None
            if incident_at and since_30d <= incident_at <= now:
                incident_rows.append(incident)
        details["incident_records_30d"] = len(incident_rows)
        if accepted_release_issues_30d is not None:
            def _incident_issue(incident):
                direct = _number(incident.get("issue") or incident.get("issue_number"))
                if direct is not None:
                    return direct
                found = re.search(r"\bIssues?\s+#(\d+)", str(incident.get("what_happened") or ""))
                return int(found.group(1)) if found else None
            named = [_incident_issue(incident) for incident in incident_rows]
            details["incident_unreferenced_30d"] = sum(issue is None for issue in named)
            # An empty accepted set means no release acceptance was observed in 30 d: with no
            # acceptance baseline, whether a named incident is unlinked is unknown (NO-DATA),
            # not "every incident is unlinked".
            if accepted_release_issues_30d:
                unlinked_incidents = sum(issue not in accepted_release_issues_30d for issue in named)
                details["unlinked_incidents_30d"] = unlinked_incidents
                values["delivery.unlinked_incidents_30d"] = unlinked_incidents
                values["delivery.incident_rate_30d_pct"] = 100 * len(accepted_release_issues_30d.intersection(named)) / len(accepted_release_issues_30d)
    if details["unlinked_units_30d"] is not None:
        values["delivery.unlinked_units_30d"] = details["unlinked_units_30d"]

    merged_units = []
    for unit in units:
        merged_at = _merge_time(unit)
        if merged_at and since_30d <= merged_at <= now:
            merged_units.append((unit, merged_at))
    details["merged_units_30d"] = len(merged_units)
    review_rounds, approval_counts = [], []
    review_stages = {"review-approve", "review-request-changes", "review-block"}
    for unit, merged_at in merged_units:
        reviews = sorted((at, event.get("stage")) for event in unit.get("history") or []
                         if event.get("stage") in review_stages and (at := ts(event.get("at"))) and at <= merged_at)
        approvals = sum(1 for _, stage in reviews if stage == "review-approve")
        approval_counts.append(approvals)
        first_approval = next((index for index, (_, stage) in enumerate(reviews) if stage == "review-approve"), None)
        if first_approval is not None:
            review_rounds.append(first_approval + 1)
    values["delivery.cycles_to_pass_30d"] = sum(review_rounds) / len(review_rounds) if review_rounds else None
    values["delivery.approvals_per_merge_30d"] = sum(approval_counts) / len(approval_counts) if approval_counts else None

    return {"values": values, "details": details}


def file_issues(a, rows, now):
    """Escalate persistently UNHEALTHY metrics into pipeline-system issues (the pipeline fixes itself)."""
    path = os.path.join(a, "node-health-state.json")
    state = read_json(path)
    for node, mid, desc, v, healthy, unhealthy, higher, status in rows:
        # A failed size fetch is unknown, not recovery. Preserve the episode
        # until a complete sample establishes whether the metric recovered.
        if mid == "review.large_pr_pct" and status == "NO-DATA":
            continue
        if status != "UNHEALTHY":
            state.pop(mid, None)
            continue
        entry = state.setdefault(mid, {"since": f"{now:%Y-%m-%dT%H:%M:%SZ}"})
        since, filed = ts(entry.get("since")), ts(entry.get("filed"))
        if not since or (now - since).total_seconds() < ESCALATE_HOURS * 3600:
            continue
        if filed and (now - filed).total_seconds() < REFILE_HOURS * 3600:
            continue
        title = f"pipeline health: {mid} unhealthy"
        # #4487: per-metric symptom fixes twice replaced the behaviour fix (bound/criteria edits in
        # eee674e0c, 6362c5486). The template routes the worker to the behavioural root cause first.
        body = (f"<!-- vecta-agent-comment -->\nnode_health.py at {now:%Y-%m-%dT%H:%MZ}: **{desc}** = {live_delivery.display_value(v)} "
                f"(healthy {'>=' if higher else '<='} {healthy}, unhealthy {'<=' if higher else '>='} {unhealthy}), "
                f"unhealthy since {entry['since']}.\n\nNode: {node}. Criteria and human baseline: "
                f"{health_doc_reference()}. Fix the behaviour, not the metric (#4487): "
                "first find the behavioural root cause that keeps this metric unhealthy and fix that with "
                "a regression test. If a root-cause ticket already covers it, link this issue there and "
                "close it here instead of repairing per metric. Changing this metric's definition or bounds "
                "is a fix only when the metric itself is proven wrong, with that evidence in the PR. "
                "Close this issue when the metric is back to OK.")
        found = subprocess.run(["gh", "issue", "list", "--state", "all", "--search", f'"{title}" in:title',
                                "--json", "number,title,state,closedAt"], capture_output=True, text=True)
        try:
            matches = sorted((i for i in json.loads(found.stdout or "[]") if i.get("title") == title),
                             key=lambda i: _number(i.get("number")) or 0)
        except ValueError:
            continue
        # A closed issue counts only inside the unhealthy episode that filed it; a later
        # episode (state was popped on recovery, entry["since"] restarted) files afresh.
        triaged = [i for i in matches if i.get("state") == "CLOSED" and ts(i.get("closedAt"))
                   and ts(i.get("closedAt")) >= since]
        number = next((_number(i.get("number")) for i in reversed(matches) if i.get("state") != "CLOSED"), None)
        if number is None and triaged:
            # #4487: already escalated for this episode and linked to its root-cause ticket;
            # re-filing would recreate the per-metric symptom loop this triage closed.
            continue
        if number:
            done = subprocess.run(["gh", "issue", "comment", str(number), "--body", body], capture_output=True)
        else:
            repo_root = Path(os.environ.get("MAC_AUTOPILOT_ROOT") or Path(__file__).resolve().parents[2])
            roadmap_helper = repo_root / "engine" / "roadmap-issue-create.sh"
            done = subprocess.run(["bash", str(roadmap_helper), "gh", "issue", "create",
                                   "--repo", os.environ.get("ZF_REPO", ""),
                                   "--title", title, "--body-file", "-",
                                   "--label", "pipeline-system", "--label", "priority:top"],
                                  input=body, capture_output=True, text=True)
        if done.returncode == 0:
            entry["filed"] = f"{now:%Y-%m-%dT%H:%M:%SZ}"
    with open(path, "w") as out:
        json.dump(state, out, indent=1)


def flow_inbox(a, rows, now, agent_home, repo_root):
    """One supervisor-inbox event per flow metric per threshold crossing (#4366).

    Regular flow samples only reach the dashboard (node-health.json); the inbox is reserved
    for actionable crossings. The crossing record in flow-inbox-state.json clears when the
    metric recovers, so the next crossing emits again."""
    state_path = os.path.join(a, "flow-inbox-state.json")
    state = read_json(state_path)
    bad = {row[1]: row for row in rows if row[1].startswith("flow.") and row[7] == "UNHEALTHY"}
    for mid in list(state):
        if mid not in bad:
            del state[mid]
    lib = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib.sh")
    for mid, (node, _, desc, v, healthy, unhealthy, higher, status) in sorted(bad.items()):
        if mid in state:
            continue
        text = (f"flow metric={mid} status=UNHEALTHY value={v:.1f} bound={unhealthy:g} "
                f"{desc}; thresholds and sources: {health_doc_reference()}")
        done = subprocess.run(["bash", "-c", 'source "$1" && supervisor_inbox_append flow-metric "$2"',
                               "bash", lib, text],
                              capture_output=True, env={**os.environ, "AGENT_HOME": agent_home})
        if done.returncode == 0:
            state[mid] = f"{now:%Y-%m-%dT%H:%M:%SZ}"
    tmp = state_path + ".tmp"
    with open(tmp, "w") as out:
        json.dump(state, out, indent=1)
    os.replace(tmp, state_path)


# Rows that read None only because no event happened: shown N/A, not NO-DATA. land-direct-main appends a
# row only when a landing rebase touches a shared-append file; this host's runtime has no such log.
NOT_APPLICABLE_WITHOUT_EVENTS = frozenset({"ci.shared_append_rebase_conflict_pct", "landing.post_land_runs_ratio"})


def score(metrics, criteria):
    rows = []
    for mid, (node, desc, healthy, unhealthy, higher) in criteria.items():
        v = metrics.get(mid)
        status = live_delivery.no_data_status(mid, v) or (
            "N/A" if v is None and mid in NOT_APPLICABLE_WITHOUT_EVENTS else status_of(v, healthy, unhealthy, higher))
        rows.append((node, mid, desc, v, healthy, unhealthy, higher, status))
    return rows


def source_commit(here):
    source_dir = Path(here).resolve()
    parts = source_dir.parts
    if "autopi-versions" in parts:
        return parts[parts.index("autopi-versions") + 1]
    if "engine-versions" in parts:  # immutable engine version dir (no git tree): its id names the build
        return parts[parts.index("engine-versions") + 1]
    return subprocess.run(
        ["git", "-C", str(source_dir.parents[1]), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def main():
    here = os.path.dirname(os.path.realpath(__file__))
    agent_home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or os.path.expanduser("~/.zenoforge")
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=5)
    ap.add_argument("--runtime", default=os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR") or (
        os.path.join(here.split("/autopi-versions/", 1)[0], "autopi") if "/autopi-versions/" in here else here))
    ap.add_argument("--audit", default=os.path.join(agent_home, "logs", "actions-run-cancellations.jsonl"))
    ap.add_argument("--now")
    ap.add_argument("--alert", action="store_true")
    ap.add_argument("--file-issues", action="store_true")
    ap.add_argument("--inbox", action="store_true")
    ap.add_argument("--main-red-dir", default=os.path.join(agent_home, "main-red"),
                    help="bisect session records; empty/absent means no main-red observation")
    ap.add_argument("--json", help="also write the scorecard, meanings and work-order standards here (dashboard)")
    args = ap.parse_args()
    a = args.runtime
    sup = os.path.dirname(os.path.abspath(a))
    now = ts(args.now) if args.now else datetime.now(timezone.utc)
    since = now - timedelta(hours=args.hours)

    criteria = dict(CRITERIA)
    try:
        overrides = json.load(open(os.path.join(a, "config.json"))).get("node_health") or {}
    except (OSError, ValueError):
        overrides = {}
    for mid, bounds in overrides.items():
        if mid in criteria and isinstance(bounds, list) and len(bounds) == 2:
            node, desc, _, _, higher = criteria[mid]
            criteria[mid] = (node, desc, bounds[0], bounds[1], higher)

    units = ledger_history.load_units(a)
    cost_rows = worker_cost.run_rows(sup); worker_cost.attach_provider_usage(cost_rows, units)  # every row: a ticket's fresh total needs all its runs
    token_efficiency = worker_cost.token_efficiency_kpis(cost_rows, units, now)
    runs = worker_runs(cost_rows, since, now)
    metrics = {"efficiency.fresh_tokens_per_merged_7d": token_efficiency["fresh_tokens_per_merged"], "efficiency.unmerged_waste_pct_7d": token_efficiency["waste_pct"], "efficiency.first_pass_yield_pct_7d": token_efficiency["first_pass_pct"], "efficiency.repair_phase_pct_7d": token_efficiency["repair_pct"]}
    # Implement and repair run minutes are per-run samples (no time weighting): a 5 h window held 20 to 45 runs
    # and swung on the model mix, so they read the 24 h window.
    day_runs = worker_runs(cost_rows, now - timedelta(hours=WALL_WINDOW_HOURS), now)
    for node in ("implement", "review", "repair"):
        pool = runs if node == "review" else day_runs
        done = [r["minutes"] for r in pool if r["node"] == node and r["output"]]
        metrics[f"{node}.wall_p50"] = pct(done, .5)
    impl = [r for r in runs if r["node"] == "implement"]
    impl = [r for r in impl if not r["running"]]
    metrics["implement.no_output_pct"] = 100 * sum(not r["output"] for r in impl) / len(impl) if impl else None
    tokens = sum(r["tokens"] for r in runs) if runs and all(r["tokens"] is not None for r in runs) else None
    metrics["loop.rework_token_pct"] = rework_token_pct(runs)
    # A repair should be checked against its own delta; a fresh full review per round re-samples the whole diff and never converges (L63).
    # Pair each repair with the next review of the same unit: dividing all rereviews by all repairs read 107 %
    # once arbiter rereviews (no repair before them) counted too.
    reviews = sorted((r for r in runs if r["node"] in ("review", "rereview")), key=lambda r: r["start"])
    followed = [next((v["node"] for v in reviews if v["unit"] == r["unit"] and v["start"] > r["start"]), None)
                for r in runs if r["node"] == "repair" and r["output"] and not r["self_fix"]]
    followed = [n for n in followed if n]
    metrics["loop.incremental_rereview_pct"] = 100 * followed.count("rereview") / len(followed) if followed else None
    station_windows = station_standards.collect_windows(now, units, runs, a, agent_home, cost_rows); ledger_windows = metric_windows.ledger(ledger_metrics, units, now); metrics.update({**ledger_metrics(units, since, now), **station_standards.collect(now, units, runs, a, agent_home, cost_rows)})
    # Advisor asks are rare: the 5 h window is usually empty, so this one reads 24 h.
    metrics["loop.advisor_fail_pct"] = ledger_metrics(units, now - timedelta(hours=24), now)["loop.advisor_fail_pct"]
    repo = os.environ.get("ZF_REPO", "")
    release_events = release_acceptances(a)
    issue_rows, pr_rows = gh_delivery_rows(repo, now, units, release_events)
    incidents = load_prod_incidents(agent_home)
    repo_root = os.environ.get("MAC_AUTOPILOT_ROOT") or os.path.abspath(os.path.join(here, "..", "..", ".."))
    reverted_merge_times = git_revert_times(repo_root, "refs/remotes/origin/main")
    delivery = delivery_metrics(units, issue_rows, pr_rows, release_events, incidents, now, repo, reverted_merge_times); delivery_windows = metric_windows.delivery(delivery_metrics, (units, issue_rows, pr_rows, release_events, incidents, now, repo, reverted_merge_times)); short_windows = {**station_windows, **ledger_windows, **delivery_windows}
    metrics.update(delivery["values"]); metrics.update(live_delivery.collect_health_metrics(agent_home, now)); merge_metrics, merge_details = merge_wait.collect(repo, now, here, _gh_json); metrics.update(merge_metrics)
    metrics["merge.conflict_repairs_per_day"] = ledger_history.conflict_repairs(units, now - timedelta(hours=24), now, ts)
    sa_attempts, sa_conflict = shared_append_rebase_metrics(
        os.path.join(agent_home, "logs", "shared-append-rebases.jsonl"), repo,
        now - timedelta(hours=24), now)
    metrics["ci.shared_append_rebase_conflict_pct"] = sa_conflict
    metrics["landing.post_land_runs_ratio"] = post_land_runs_ratio(
        os.path.join(agent_home, "land-queue", "requests"), repo, now - timedelta(hours=24), now, _gh_json)
    metrics["workers.local_test_db"] = local_test_db()
    metrics["advisor.last_answer_age_hours"] = advisor_answer_age_hours(agent_home, repo, now)
    host_missing = host_prereqs_missing()
    metrics["host.prereqs_missing"] = None if host_missing is None else len(host_missing)
    metrics["host.github_net_failures_per_hour"] = github_net_failures_per_hour(since, now)
    metrics["host.stale_worktrees"] = stale_worktrees(now)
    closed_open = ledger_history.closed_units_open_issues(a, agent_home, units)
    metrics["intake.closed_units_open_issues"] = None if closed_open is None else len(closed_open)
    metrics["engine.follow_lag_hours"] = engine_follow_lag_hours(agent_home, now)
    orders = work_orders(units, unit_spend(cost_rows), now, workorder_cost.recent_units(cost_rows, since),
                         unit_spend(cost_rows, since))
    metrics["workorders.over_standard"] = sum(1 for o in orders if o["over"])
    # Per-ticket spend from the same cost rows; token values and bounds use only complete fresh
    # splits. Bounds use the 30 days of closed tickets before the 7-day window (p50 x 1.5 healthy,
    # p90 x 2 unhealthy, worker_cost.ticket_bound); provisional or fewer than 10 samples keep
    # the static criteria.
    tickets = worker_cost.ticket_spend(cost_rows, units)
    ticket_bounds = {}
    for mid, field, key in (("workorders.ticket_tokens_p90", "fresh", "token"),
                            ("workorders.ticket_wall_p90", "wall_min", "wall")):
        recent, history = [], []
        for t in tickets:
            closed = ts(t.get("closed_at"))
            if closed is None:
                continue
            value = t.get(field)
            if value is None:
                continue
            if now - timedelta(days=7) <= closed <= now:
                recent.append(value)
            elif now - timedelta(days=37) <= closed < now - timedelta(days=7):
                history.append(value)
        metrics[mid] = pct(recent, .9)
        ticket_bounds[key] = worker_cost.ticket_bound(history)
        if (ticket_bounds[key] and not ticket_bounds[key]["provisional"]
                and ticket_bounds[key]["samples"] >= 10 and mid not in overrides):
            node, desc, _, _, higher = criteria[mid]
            criteria[mid] = (node, desc, ticket_bounds[key]["healthy"],
                             ticket_bounds[key]["unhealthy"], higher)
    size_doc = read_json(os.path.join(a, "pr-sizes.json"))
    sizes = size_doc.get("lines") or {}
    nontest_added = size_doc.get("nontest_added") or {}
    by_size, metrics["review.large_pr_pct"] = rework_by_size(
        units, sizes, nontest_added, now - timedelta(days=LARGE_PR_WINDOW_DAYS), now)
    log = os.path.join(a, "scheduler.log")
    _, future_stamped = ledger_history.scheduler_log_lines(log, now)
    sinks, queue_waits = time_sinks(units, log,
                                    now - timedelta(hours=TIME_SINK_HOURS), now)
    metrics["flow.merge_rate_per_hour"] = merge_flow(units, now - timedelta(hours=24), now)[0]
    _, entered, merged = merge_flow(units, since, now)
    metrics["flow.in_out_imbalance"] = abs(entered - merged)
    wip_rows, metrics["flow.wip_age_stage_p90_hours"] = wip_stage_ages(units, now)
    metrics["flow.wait_stage_p90_hours"], metrics["flow.wait_stage_units"] = wait_stage(units, now)
    metrics["flow.slot_idle_hours"] = slot_idle_hours(queue_waits, cost_rows, since)
    metrics["flow.main_red_hours"] = main_red_hours(args.main_red_dir, since, now)
    flow_details = {"entered": entered, "merged": merged, "wip_age": wip_rows}
    metrics["ci.held_ready_pct"] = held_ready_pct(units, ledger_history.live_ledger_readable(a))
    spend = read_json(os.path.join(a, "ci-spend.json"))
    fresh = ts(spend.get("sampled_at"))
    metrics["ci.waste_runner_pct"] = spend.get("waste_pct") if fresh and (now - fresh).total_seconds() < 7200 else None
    audit = read_cancel_audit(args.audit, repo)
    metrics.update(cancel_metrics(audit, now - timedelta(hours=24), now)[0])  # a 5 h window scaled to a day read one event as 4.8
    _, metrics["ci.priority_hold_runs_48h"] = cancel_metrics(audit, now - timedelta(hours=48), now)
    metrics["ci.gated_pr_pct"] = gated_agent_pr_share(repo)
    ticks = []
    log_rows, _ = ledger_history.scheduler_log_lines(log, now)
    for raw in log_rows or []:
        m = LINE_RE.match(raw)
        if m and (t := ts(m.group(1))) and t >= since:
            ticks.append(t)
    metrics["scheduler.tick_gap_p50"] = pct([(b - x).total_seconds() for x, b in zip(ticks, ticks[1:])], .5)
    metrics.update({"scheduler.merge_pass_gap_min": merge_pass_gap_min(units, ledger_history.live_ledger_readable(a), a, now), **harvest_health.metrics(log, since, now, ts, pct), **existing_walk_health.metrics(log, since, now, ts, pct)})

    train = read_json(os.path.join(a, "release-train.json"))
    if not train:
        metrics["release.hours_waiting"] = None
    elif train.get("status") in ("released", "no-image-change"):
        metrics["release.hours_waiting"] = 0
    else:
        waiting_since = ts(train.get("started_at"))
        metrics["release.hours_waiting"] = (
            max(0, (now - waiting_since).total_seconds() / 3600) if waiting_since else None
        )
    release_retained.collect(metrics, a, now, ts(train.get("started_at")) if train else None)
    blockers = read_json(os.path.join(a, "release-blockers.json"))
    metrics["release.hotpatch_blockers"] = len(blockers["blockers"]) if isinstance(blockers.get("blockers"), list) else None
    line_holds.collect(metrics, a, agent_home, now)
    rulings_copies.collect(metrics, agent_home)
    release_found = release_age.collect(metrics, now)
    registry = (zf_mechanism_registry() or {}).get("mechanisms")
    if isinstance(registry, list) and registry:
        mechanism_rows, metrics["mechanism.silent"] = mechanism_heartbeat(registry, a, agent_home, now)
    else:
        mechanism_rows, metrics["mechanism.silent"] = [], None
    try:
        m = re.search(r"agent=(\d+)", open(os.path.join(a, "orphan-prs.count")).read())
        metrics["pipeline.orphan_prs"] = int(m.group(1)) if m else None
    except OSError:
        metrics["pipeline.orphan_prs"] = None

    short_windows = metric_windows.fill(metrics, short_windows, criteria, SOURCE, args.hours); rows = score(metrics, criteria)
    future_note = f" future_stamped={future_stamped}" if future_stamped else ""
    print(f"node health {now:%Y-%m-%dT%H:%MZ} window={args.hours:g}h tokens={tokens} runs={len(runs)}{future_note}")
    print(f"  {'node':<12} {'metric':<48} {'value':>7}  healthy  unhealthy  status")
    for node, mid, desc, v, healthy, unhealthy, higher, status in rows:
        shown = "-" if v is None else f"{v:.0f}"
        op = ">=" if higher else "<="
        print(f"  {node:<12} {desc:<48} {shown:>7}  {op}{healthy:<6} {'<=' if higher else '>='}{unhealthy:<8} {status}")
    bad = [r for r in rows if r[7] == "UNHEALTHY"]
    print("unhealthy nodes: " + (", ".join(sorted({r[0] for r in bad})) or "none"))
    if host_missing:
        print("host missing: " + "; ".join(host_missing))
    if closed_open:
        print("closed units under open issues: " + " ".join(f"#{n}" for n in closed_open))

    if args.file_issues:
        file_issues(a, rows, now)

    if args.inbox:
        flow_inbox(a, rows, now, agent_home, repo_root)
        line_holds.alert(a, agent_home, repo_root, now)
        release_age.alert(a, agent_home, repo_root, now, release_found)

    if args.json:
        sampled_at = f"{now:%Y-%m-%dT%H:%M:%SZ}"; scorecard_metrics = [{"id": mid, "node": node, "desc": desc, "meaning": MEANING.get(mid, ""), "value": v,
            "healthy": healthy, "unhealthy": unhealthy, "higher_is_better": higher, "status": status, "source": SOURCE.get(mid, ""), **short_windows[mid]}
            for node, mid, desc, v, healthy, unhealthy, higher, status in rows]
        doc = {"generated": sampled_at, "generated_at": sampled_at,
               "source_commit": source_commit(here), "paused": line_holds.pause_state(agent_home),
               "window_hours": args.hours, "future_stamped": future_stamped,
               "metrics": scorecard_metrics, "trend_metrics": [m for m in scorecard_metrics if "_30d" in m["id"]],
               "time_sinks": sinks, "time_sink_hours": TIME_SINK_HOURS, "rework_by_size": by_size,
               "rework_token_measured": [sum(r["tokens"] is not None for r in runs), len(runs)],
               "delivery": delivery["details"], "red_after_approve": red_after_approve(units, since)[1], "merge_wait": merge_details, "flow": flow_details, "mechanisms": mechanism_rows,
               "ci_standards": {k: {"desc": d, "healthy": h, "unhealthy": u, "higher_is_better": hi, "meaning": m, "source": src}
                                for k, (d, h, u, hi, m, src) in CI_STANDARDS.items()},
               "unit_standards": {k: {"desc": d, "healthy": h, "bug": b} for k, (d, h, b) in UNIT_STANDARDS.items()},
               "work_orders": orders, "ticket_spend": tickets[:60], "ticket_bounds": ticket_bounds,
               "ci_spend": spend, "host_missing": host_missing}
        tmp = args.json + ".tmp"
        with open(tmp, "w") as out:
            json.dump(doc, out, ensure_ascii=False)
        os.replace(tmp, args.json)

    if args.alert and bad:
        path = os.path.join(a, "alerts", "node-health.md")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        hour = f"{now:%Y-%m-%dT%H}"
        seen = open(path, errors="ignore").read() if os.path.exists(path) else ""
        with open(path, "a") as out:
            for node, mid, desc, v, healthy, unhealthy, higher, status in bad:
                if f"[{hour}" in seen and f"NODE-UNHEALTHY metric={mid} " in seen.split(f"[{hour}", 1)[1]:
                    continue
                out.write(f"[{now:%Y-%m-%dT%H:%M:%SZ}] NODE-UNHEALTHY metric={mid} node={node} value={live_delivery.display_value(v)} "
                          f"unhealthy-bound={unhealthy} ({desc}; see {health_doc_reference()})\n")


if __name__ == "__main__":
    main()
