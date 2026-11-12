"""Harvest station scorecard row: seconds between station pass starts (scheduler.sh --harvest-station), p50."""
import re
import ledger_history

ID = "scheduler.harvest_gap_p50"
# The line's stamp is the pass start, as the tick's is.
LINE_RE = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] harvest-station done")
CRITERIA = {ID: ("scheduler", "seconds between harvest station pass starts p50", 120, 300, False)}
MEANING = {ID: "收割站两次运行之间的秒数（中位）：越长，做完的 worker 越晚被收走、槽位越晚空出。"}
SOURCE = {ID: "scheduler.log 相邻两条 harvest-station done 的间隔"}


def metrics(log, since, now, ts, pct, sample_counts=None):
    starts = []
    lines, _ = ledger_history.scheduler_log_lines(log, now) if isinstance(log, str) else (log, 0)
    if lines is None:
        return {ID: None}
    for raw in lines:
        m = LINE_RE.match(raw)
        if m and (t := ts(m.group(1))) and t >= since:
            starts.append(t)
    gaps = [(b - a).total_seconds() for a, b in zip(starts, starts[1:])]
    if sample_counts is not None:
        sample_counts[ID] = len(gaps)
    return {ID: pct(gaps, .5)}
