"""Supervisor arbitration scorecard definitions and fixed 24-hour ledger counts."""
from datetime import timedelta


CRITERIA = {
    "supervisor.arbiter_dispatches_24h": ("supervisor", "arbiter dispatches in 24 h", 48, 120, False),
    # The sentinel bounds (healthy 0, unhealthy -1, higher is better) leave any measured count OK.
    "supervisor.cap_default_24h": ("supervisor", "supervisor-cap-default decisions in 24 h (measured, no bound)", 0, -1, True),
    # Provisional: a replay of the 24 h to 2026-11-07 put the guard at 16 firings; tune after a week of live samples.
    "supervisor.repeat_guard_24h": ("supervisor", "repeat-arbitration guard firings in 24 h", 8, 24, False),
}

MEANING = {
    "supervisor.arbiter_dispatches_24h": "24 小时内派出的 supervisor 仲裁 run 数（supervisor-arbiter 历史，固定滚动 24h）。高 = 仲裁在空转：单元反复升级而裁决不收敛；单单元总量由 supervisor_arbiter.unit_cap 终身上限约束。",
    "supervisor.cap_default_24h": "24 小时内触顶后由调度器按默认决定（obsolete/recut/park）收尾的单元数。只测量不设界：每个默认决定都省下一次模型 run，也无人被问到。",
    "supervisor.repeat_guard_24h": "24 小时内重复仲裁被拦下的次数：同一单元、同一升级原因（去掉数字和 SHA 后相同），两次仲裁之间没有交付、批准、ready-to-merge、合并或新 PR head，调度器改走触顶路线（recut 一次，否则 park），不再派第二个只会 requeue 的仲裁 run。高 = 仍有升级类别在空转，而且是还没有专门规则的类别。",
}

SOURCE = {
    "supervisor.arbiter_dispatches_24h": "units.json（含 units-archive.json 退休行）的 supervisor-arbiter 历史事件，固定滚动 24h（不看 --hours 窗口）",
    "supervisor.cap_default_24h": "units.json（含 units-archive.json 退休行）的 supervisor-cap-default 历史事件，固定滚动 24h",
    "supervisor.repeat_guard_24h": "units.json（含 units-archive.json 退休行）里 result 以 \"supervisor repeat guard:\" 开头的历史事件（路线自己的 recut/park/obsolete 事件，没有新阶段），固定滚动 24h",
}

REPEAT_GUARD_PREFIX = "supervisor repeat guard:"


def ledger_metrics(units, now, timestamp):
    """Count arbitration dispatches and defaults over a fixed rolling 24-hour window."""
    day = now - timedelta(hours=24)
    counts = {"supervisor.arbiter_dispatches_24h": 0, "supervisor.cap_default_24h": 0, "supervisor.repeat_guard_24h": 0}
    stages = {"supervisor-arbiter": "supervisor.arbiter_dispatches_24h",
              "supervisor-cap-default": "supervisor.cap_default_24h"}
    for unit in units:
        for event in unit.get("history") or []:
            metric = stages.get(event.get("stage"))
            if str(event.get("result") or "").startswith(REPEAT_GUARD_PREFIX):
                metric = "supervisor.repeat_guard_24h"
            at = timestamp(event.get("at")) if metric else None
            if at is not None and day <= at <= now:
                counts[metric] += 1
    return counts
