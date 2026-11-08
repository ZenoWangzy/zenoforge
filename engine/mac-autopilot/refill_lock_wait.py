"""Refill lock wait: how long a refill waited for the scheduler lock or the ledger lock, p50 over 24 h.

A refill that waits for a lock it does not get starts no worker, so a slot sits idle (2026-11-08: stopped at 291 s in lock_wait, killed at 300 s).
Each finished refill logs its wait as lock_wait= on its tick-phases line (the scheduler lock plus the ledger lock). A refill killed while waiting
prints no such line, so loop.sh's REFILL-TIMEOUT line naming phase lock_wait counts at its kill second. A refill stopped by its own deadline still
prints tick-phases, so the stop line is not counted twice.

node_health.py sits at its size-ratchet baseline, so the row tables and the check live here and merge at import.
"""
import os, re
from datetime import datetime, timedelta, timezone

METRIC = "scheduler.refill_lock_wait_s"
CRITERIA = {METRIC: ("scheduler", "seconds a refill waited for the scheduler and ledger locks p50, 24 h", 5, 30, False)}
MEANING = {METRIC: "补派等锁的秒数（24 小时中位）：包括调度锁和台账锁。越长，空槽越久没人补。补派不再等整拍的调度锁，只在写台账的几秒里取台账锁。"}
SOURCE = {METRIC: "scheduler.log 近 24 小时 tick-phases kind=refill 行的 lock_wait=；在等锁阶段被杀的补派（REFILL-TIMEOUT refill tick killed after N s in phase lock_wait）按 N 秒计；没有补派行时记 NO-DATA"}
LINE_RE = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] (?:tick-phases kind=refill .*? lock_wait=(\d+)"
                     r"|REFILL-TIMEOUT refill tick killed after (\d+)s in phase lock_wait)")


def waits(log, since, now):
    out = []
    if os.path.exists(log):
        for raw in open(log, errors="ignore"):
            m = LINE_RE.match(raw)
            if m:
                t = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                if since <= t <= now:
                    out.append(int(m.group(2) or m.group(3)))
    return out


def collect(metrics, log, now):
    w = sorted(waits(log, now - timedelta(hours=24), now))
    metrics[METRIC] = w[int(round(.5 * (len(w) - 1)))] if w else None
