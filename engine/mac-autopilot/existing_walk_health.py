"""Existing-walk station scorecard row: seconds between station pass starts (scheduler.sh --existing-walk), p50."""
import re
import ledger_history

ID = "scheduler.existing_walk_gap_p50"
# The line's stamp is the pass start, as the tick's is.
LINE_RE = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] existing-walk done")
CRITERIA = {ID: ("scheduler", "seconds between existing-walk station pass starts p50", 120, 300, False)}
MEANING = {ID: "已知单元的接单遍历站两次运行之间的秒数（中位）：越长，已在台账里的单元越晚被走完交接那一段、越晚派下一步。"}
SOURCE = {ID: "scheduler.log 相邻两条 existing-walk done 的间隔"}


def metrics(log, since, now, ts, pct):
    starts = []
    lines, _ = ledger_history.scheduler_log_lines(log, now)
    if lines is None:
        return {ID: None}
    for raw in lines:
        m = LINE_RE.match(raw)
        if m and (t := ts(m.group(1))) and t >= since:
            starts.append(t)
    return {ID: pct([(b - a).total_seconds() for a, b in zip(starts, starts[1:])], .5)}
