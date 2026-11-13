"""Supervisor arbitration scorecard definitions and fixed 24-hour ledger counts."""
from datetime import timedelta


CRITERIA = {
    "supervisor.arbiter_dispatches_24h": ("supervisor", "arbiter dispatches in 24 h", 48, 120, False),
    # The sentinel bounds (healthy 0, unhealthy -1, higher is better) leave any measured count OK.
    "supervisor.cap_default_24h": ("supervisor", "supervisor-cap-default decisions in 24 h (measured, no bound)", 0, -1, True),
    # Provisional: a replay of the 24 h to 2026-11-07 put the guard at 16 firings; tune after a week of live samples.
    "supervisor.repeat_guard_24h": ("supervisor", "repeat-arbitration guard firings in 24 h", 8, 24, False),
    # Healthy 0, unhealthy 1: a token park means a unit spent past its line, and each one needs an owner.
    "supervisor.token_parks_24h": ("supervisor", "token-spend parks in 24 h (soft and hard)", 0, 1, False),
    # A count of units now parked by a repeated-failure stop-loss; every one waits on a PR head change or a timed retry, so it is measured with no bound.
    "supervisor.stop_loss_same_failure_parked": ("supervisor", "units parked by a repeated-failure stop-loss now (measured, no bound)", 0, -1, True),
    # Healthy 0, unhealthy 1: 1 = workers finished in the last 6 h and no unit holds a spend_runs record from that window.
    "supervisor.spend_ledger_blind": ("supervisor", "token gate input empty while workers ran (6 h, 1 = blind)", 0, 1, False),
    # Healthy >= 50, unhealthy below: null under 6 decided outcomes in 7 days. The scheduler stops its fresh-signal requeues while this reads under 50.
    "supervisor.fresh_requeue_delivery_24h": ("supervisor", "scheduler fresh-signal requeues that delivered, % of the last 6 decided outcomes within 7 days (6 needed)", 50, 49.9, True),
}

MEANING = {
    "supervisor.arbiter_dispatches_24h": "24 小时内派出的 supervisor 仲裁 run 数（supervisor-arbiter 历史，固定滚动 24h）。高 = 仲裁在空转：单元反复升级而裁决不收敛；单单元总量由 supervisor_arbiter.unit_cap 终身上限约束。",
    "supervisor.cap_default_24h": "24 小时内触顶后由调度器按默认决定（obsolete/recut/park）收尾的单元数。只测量不设界：每个默认决定都省下一次模型 run，也无人被问到。",
    "supervisor.repeat_guard_24h": "24 小时内重复仲裁被拦下的次数：同一单元、同一升级原因（去掉数字和 SHA 后相同），两次仲裁之间没有交付、批准、ready-to-merge、合并或新 PR head，调度器改走触顶路线（recut 一次，否则 park），不再派第二个只会 requeue 的仲裁 run。高 = 仍有升级类别在空转，而且是还没有专门规则的类别。",
    "supervisor.token_parks_24h": "24 小时内因终身 fresh token 超线而停下的单元数（soft 线 1.2M 停下等一次仲裁，hard 线 2.4M 永久停；每个单元每条线只记一次）。0 = 健康；出现 = 有单元在烧 token 而不收敛，看事件里的 class（report-gate-loop、hot-file-churn、undersized、unclassified）找成因。",
    "supervisor.stop_loss_same_failure_parked": "当前因 stop-loss 遇到同一失败而停车的单元数（stage 为 parked 且 parked_reason 以 \"stop-loss same failure:\" 开头）。只测量不设界：每个都在等 PR head 变化，或 24 小时后 main 前进的一次定时重试；没有 PR 的停车只能等 supervisor。",
    "supervisor.spend_ledger_blind": "token spend gate 的输入（单元的 spend_runs）在最近 6 小时内为空，而这 6 小时里有 worker 收割过：1 = 门在对空数据求和、永远返回 ok（仪表盘死线路）。0 = 健康。出现时先看 scheduler.log 的 \"spend ledger\" 行和 spend_ledger.py sweep 的返回。",
    "supervisor.fresh_requeue_delivery_24h": "调度器在止损（rounds 3 of 3）遇到新信号（首次出现的红、合并冲突、review request-changes）时不经模型直接 requeue 一次；这些 requeue 在最近 7 天内、按 requeue 时间取最新 6 个已有结果的占比：交付（合并、ci-ready 或批准）/（交付 + 再次升级、停单、关闭，或再被 requeue 一次）。还没有结果的不计；7 天内不足 6 个结果时为空（门 fail-open）。低于 50% = 不再替 arbiter 做这件事，调度器停掉这条 requeue，新信号回到 arbiter（行 90：arbiter 同类 requeue 交付 16 of 22）。",
}

SOURCE = {
    "supervisor.arbiter_dispatches_24h": "units.json（含 units-archive.json 退休行）的 supervisor-arbiter 历史事件，固定滚动 24h（不看 --hours 窗口）",
    "supervisor.cap_default_24h": "units.json（含 units-archive.json 退休行）的 supervisor-cap-default 历史事件，固定滚动 24h",
    "supervisor.repeat_guard_24h": "units.json（含 units-archive.json 退休行）里 result 以 \"supervisor repeat guard:\" 开头的历史事件（路线自己的 recut/park/obsolete 事件，没有新阶段），固定滚动 24h",
    "supervisor.token_parks_24h": "units.json（含 units-archive.json 退休行）的 token-park 历史事件（调度器 token spend gate 写入，终身 fresh token 来自 spend_runs，与 workorders 同口径），固定滚动 24h",
    "supervisor.stop_loss_same_failure_parked": "units.json（含 units-archive.json 退休行）里 stage 为 parked、parked_reason 以 \"stop-loss same failure:\" 开头的单元数，当前状态，不是 24h 窗口",
    "supervisor.spend_ledger_blind": "units.json 的 history（worker 收割类事件，见 SPEND_WORKER_STAGES）与 spend_runs[].start，固定滚动 6h",
    "supervisor.fresh_requeue_delivery_24h": "units.json（含 units-archive.json 退休行）里 result 以 \"scheduler fresh-signal requeue:\" 开头的 supervisor-requeue 事件（stop-loss.sh 写入）及其后的事件，取 7 天内最新 6 个有结果的（指标 id 仍带 _24h，改名要动 stop-loss.sh 与仪表盘）",
}

REPEAT_GUARD_PREFIX = "supervisor repeat guard:"
SAME_FAILURE_PARK_PREFIX = "stop-loss same failure:"
# History events a finished worker leaves; each one means a worker log that spend_ledger.py should have turned into a spend_runs record.
SPEND_WORKER_STAGES = {"pr-opened", "repair-delivered", "repair-no-push", "self-fix-delivered", "delivered", "implement-no-push",
                       "implement-no-changes", "review-approve", "review-request-changes", "review-block", "worker-no-output"}

FRESH_REQUEUE_PREFIX = "scheduler fresh-signal requeue:"
FRESH_MIN_OUTCOMES = 6
FRESH_WINDOW_DAYS = 7  # 6 outcomes took 72 h on 2026-11-13: a 24 h window never reached 6, so the 50% gate never closed
# Row 90's outcome after a requeue: delivered, or escalated, parked or closed first (a second fresh requeue also ends the first one).
FRESH_DELIVERED = {"merged", "landed", "pr-merged", "ci-ready", "review-approve", "supervisor-approve"}
FRESH_FAILED = {"supervisor-escalated", "hard-escalation", "supervisor-review", "supervisor-arbiter", "supervisor-cap-triage-park", "supervisor-budget-park",
                "token-park", "supervisor-park", "supervisor-cap-founder", "supervisor-cap-default", "ci-main-red-park", "size-recut", "closed", "obsolete"}


def fresh_requeue_outcomes(units, now, timestamp):
    """(delivered, decided) over the last FRESH_MIN_OUTCOMES decided scheduler fresh-signal requeues of the last 7 days, newest by requeue time;
    a requeue still waiting for an outcome is not counted. Under that many decided in 7 days the caller reads no rate (fail-open)."""
    week = now - timedelta(days=FRESH_WINDOW_DAYS)
    fresh = lambda e: e.get("stage") == "supervisor-requeue" and str(e.get("result") or "").startswith(FRESH_REQUEUE_PREFIX)
    outcomes = []  # (requeue time, delivered)
    for unit in units:
        events = unit.get("history") or []
        for i, event in enumerate(events):
            at = timestamp(event.get("at")) if fresh(event) else None
            if at is None or not week <= at <= now:
                continue
            for later in events[i + 1:]:
                if later.get("stage") not in FRESH_DELIVERED and later.get("stage") not in FRESH_FAILED and not fresh(later):
                    continue
                outcomes.append((at, later.get("stage") in FRESH_DELIVERED))
                break
    last = sorted(outcomes, key=lambda o: o[0])[-FRESH_MIN_OUTCOMES:]
    return sum(d for _, d in last), len(last)


def ledger_metrics(units, now, timestamp, window_hours=None):
    """Count arbitration dispatches and defaults over a fixed rolling 24-hour window."""
    day = now - timedelta(hours=window_hours or 24)
    counts = {"supervisor.arbiter_dispatches_24h": 0, "supervisor.cap_default_24h": 0, "supervisor.repeat_guard_24h": 0,
              "supervisor.token_parks_24h": 0, "supervisor.spend_ledger_blind": 0, "supervisor.stop_loss_same_failure_parked": 0}
    stages = {"supervisor-arbiter": "supervisor.arbiter_dispatches_24h",
              "supervisor-cap-default": "supervisor.cap_default_24h",
              "token-park": "supervisor.token_parks_24h"}
    for unit in units:
        if unit.get("stage") == "parked" and str(unit.get("parked_reason") or "").startswith(SAME_FAILURE_PARK_PREFIX):
            counts["supervisor.stop_loss_same_failure_parked"] += 1
        for event in unit.get("history") or []:
            metric = stages.get(event.get("stage"))
            if str(event.get("result") or "").startswith(REPEAT_GUARD_PREFIX):
                metric = "supervisor.repeat_guard_24h"
            at = timestamp(event.get("at")) if metric else None
            if at is not None and day <= at <= now:
                counts[metric] += 1
    window = now - timedelta(hours=min(window_hours or 6, 6))
    ran = recorded = False
    for unit in units:
        ran = ran or any(e.get("stage") in SPEND_WORKER_STAGES and (timestamp(e.get("at")) or window) > window for e in unit.get("history") or [])
        recorded = recorded or any(isinstance(r, dict) and (timestamp(r.get("start")) or window) > window for r in unit.get("spend_runs") or [])
    counts["supervisor.spend_ledger_blind"] = int(ran and not recorded)
    delivered, decided = fresh_requeue_outcomes(units, now, timestamp)
    counts["supervisor.fresh_requeue_delivery_24h"] = round(100 * delivered / decided, 1) if decided >= FRESH_MIN_OUTCOMES else None
    return counts
