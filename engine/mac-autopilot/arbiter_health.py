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
    # Healthy 0, unhealthy 1: 1 = workers finished in the last 6 h and no unit holds a spend_runs record from that window.
    "supervisor.spend_ledger_blind": ("supervisor", "token gate input empty while workers ran (6 h, 1 = blind)", 0, 1, False),
}

MEANING = {
    "supervisor.arbiter_dispatches_24h": "24 小时内派出的 supervisor 仲裁 run 数（supervisor-arbiter 历史，固定滚动 24h）。高 = 仲裁在空转：单元反复升级而裁决不收敛；单单元总量由 supervisor_arbiter.unit_cap 终身上限约束。",
    "supervisor.cap_default_24h": "24 小时内触顶后由调度器按默认决定（obsolete/recut/park）收尾的单元数。只测量不设界：每个默认决定都省下一次模型 run，也无人被问到。",
    "supervisor.repeat_guard_24h": "24 小时内重复仲裁被拦下的次数：同一单元、同一升级原因（去掉数字和 SHA 后相同），两次仲裁之间没有交付、批准、ready-to-merge、合并或新 PR head，调度器改走触顶路线（recut 一次，否则 park），不再派第二个只会 requeue 的仲裁 run。高 = 仍有升级类别在空转，而且是还没有专门规则的类别。",
    "supervisor.token_parks_24h": "24 小时内因终身 fresh token 超线而停下的单元数（soft 线 1.2M 停下等一次仲裁，hard 线 2.4M 永久停；每个单元每条线只记一次）。0 = 健康；出现 = 有单元在烧 token 而不收敛，看事件里的 class（report-gate-loop、hot-file-churn、undersized、unclassified）找成因。",
    "supervisor.spend_ledger_blind": "token spend gate 的输入（单元的 spend_runs）在最近 6 小时内为空，而这 6 小时里有 worker 收割过：1 = 门在对空数据求和、永远返回 ok（仪表盘死线路）。0 = 健康。出现时先看 scheduler.log 的 \"spend ledger\" 行和 spend_ledger.py sweep 的返回。",
}

SOURCE = {
    "supervisor.arbiter_dispatches_24h": "units.json（含 units-archive.json 退休行）的 supervisor-arbiter 历史事件，固定滚动 24h（不看 --hours 窗口）",
    "supervisor.cap_default_24h": "units.json（含 units-archive.json 退休行）的 supervisor-cap-default 历史事件，固定滚动 24h",
    "supervisor.repeat_guard_24h": "units.json（含 units-archive.json 退休行）里 result 以 \"supervisor repeat guard:\" 开头的历史事件（路线自己的 recut/park/obsolete 事件，没有新阶段），固定滚动 24h",
    "supervisor.token_parks_24h": "units.json（含 units-archive.json 退休行）的 token-park 历史事件（调度器 token spend gate 写入，终身 fresh token 来自 spend_runs，与 workorders 同口径），固定滚动 24h",
    "supervisor.spend_ledger_blind": "units.json 的 history（worker 收割类事件，见 SPEND_WORKER_STAGES）与 spend_runs[].start，固定滚动 6h",
}

REPEAT_GUARD_PREFIX = "supervisor repeat guard:"
# History events a finished worker leaves; each one means a worker log that spend_ledger.py should have turned into a spend_runs record.
SPEND_WORKER_STAGES = {"pr-opened", "repair-delivered", "repair-no-push", "self-fix-delivered", "delivered", "implement-no-push",
                       "implement-no-changes", "review-approve", "review-request-changes", "review-block", "worker-no-output"}


def ledger_metrics(units, now, timestamp):
    """Count arbitration dispatches and defaults over a fixed rolling 24-hour window."""
    day = now - timedelta(hours=24)
    counts = {"supervisor.arbiter_dispatches_24h": 0, "supervisor.cap_default_24h": 0, "supervisor.repeat_guard_24h": 0,
              "supervisor.token_parks_24h": 0, "supervisor.spend_ledger_blind": 0}
    stages = {"supervisor-arbiter": "supervisor.arbiter_dispatches_24h",
              "supervisor-cap-default": "supervisor.cap_default_24h",
              "token-park": "supervisor.token_parks_24h"}
    for unit in units:
        for event in unit.get("history") or []:
            metric = stages.get(event.get("stage"))
            if str(event.get("result") or "").startswith(REPEAT_GUARD_PREFIX):
                metric = "supervisor.repeat_guard_24h"
            at = timestamp(event.get("at")) if metric else None
            if at is not None and day <= at <= now:
                counts[metric] += 1
    window = now - timedelta(hours=6)
    ran = recorded = False
    for unit in units:
        ran = ran or any(e.get("stage") in SPEND_WORKER_STAGES and (timestamp(e.get("at")) or window) > window for e in unit.get("history") or [])
        recorded = recorded or any(isinstance(r, dict) and (timestamp(r.get("start")) or window) > window for r in unit.get("spend_runs") or [])
    counts["supervisor.spend_ledger_blind"] = int(ran and not recorded)
    return counts
