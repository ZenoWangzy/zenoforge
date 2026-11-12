"""Release batch duration: minutes from a release-batch unit start to its verdict, for the latest batch.

issue-pipeline.sh dispatch_release_batch starts the transient unit `<ZF_UNIT_PREFIX>-release-batch`. One journal read
gives each run's start (`Started <unit>.service`) and its end (`Failed with result` or `Deactivated successfully`).
A run's verdict is the first release-retained or release-closer line in alerts/events.md after its start
(release_retained.read); a verdict belongs to the latest start at or before it. A batch still active with no verdict
reads as its age so far. A batch that ended with no verdict is not counted in minutes; the failed ones among them are
counted in release.batch_failed_no_verdict (0 is OK, 1 or more is UNHEALTHY and goes to the node-health alert).
Bounds are TENTATIVE (head, 2026-11-08): re-derive after 10 batches with a verdict.
"""
import bisect, os, subprocess
from datetime import datetime, timedelta

import release_retained

METRIC = "release.batch_minutes"
FAILED = "release.batch_failed_no_verdict"
FAILED_14D = "release.batch_failed_14d"  # info only, not scored: the 14-day count behind FAILED
CRITERIA = {
    METRIC: ("release", "minutes of the latest release batch, start to verdict (running: age so far)", 120, 240, False),
    FAILED: ("release", "failed release batch runs with no verdict after the last verdict", 0, 1, False),
}
MEANING = {
    METRIC: "最近一次发布批次从启动到结论（release-retained 或 release-closer）的分钟数；批次仍在运行时显示已经跑了多少分钟。暂定标准（2026-11-08 head），满 10 个有结论的批次后重新校准。",
    FAILED: "最近一次有结论的发布之后，没有结论且单元运行以失败结束的批次数；大于 0 即 UNHEALTHY，会进入节点体检告警。没有结论的 14 天内则按整个窗口计。",
}
SOURCE = {
    METRIC: "journalctl --user 的 <前缀>-release-batch 单元 Started 行（启动）；alerts/events.md 的 release-retained / release-closer 行（结论）；systemctl --user is-active（是否仍在运行）",
    FAILED: "同一份 journalctl 读取的单元结束行（Failed with result 为失败，Deactivated successfully 为正常）对照 events.md 的结论行",
}
JOURNAL_SINCE = "14 days ago"


def _journal_runs(unit):
    """[(time, kind)] with kind 'start', 'failed' or 'ok', from one user-journal read; None when unreadable."""
    pattern = f"Started {unit}\\.service|{unit}\\.service: (Failed with result|Deactivated successfully)"
    try:
        out = subprocess.run(["journalctl", "--user", "--no-pager", "-o", "short-iso", "--since", JOURNAL_SINCE,
                              "-u", f"{unit}*", "-g", pattern],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    runs = []
    for line in out.stdout.splitlines():
        try:
            at = datetime.fromisoformat(line.split(" ", 1)[0])
        except ValueError:
            continue
        if "Started " in line:
            runs.append((at, "start"))
        elif "Failed with result" in line:
            runs.append((at, "failed"))
        elif "Deactivated successfully" in line:
            runs.append((at, "ok"))
    return runs


def _active(unit):
    try:
        return subprocess.run(["systemctl", "--user", "is-active", "--quiet", f"{unit}.service"], timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _starts(runs):
    return sorted(at for at, kind in runs if kind == "start")


def batch_minutes(starts, verdicts, now, active):
    """Minutes for the latest batch: its age while active with no verdict, else start to first verdict of the
    latest batch that has one. None when no batch has a verdict or is running."""
    if not starts:
        return None
    starts = sorted(starts)
    verdicts = sorted(verdicts)
    last = starts[-1]
    if active and not (verdicts and verdicts[-1] >= last):
        return (now - last).total_seconds() / 60
    first_verdict = {}  # batch start -> first verdict that landed while it was the latest start
    for v in verdicts:
        i = bisect.bisect_right(starts, v)
        if i:
            first_verdict.setdefault(starts[i - 1], v)
    if not first_verdict:
        return None
    s = max(first_verdict)
    return (first_verdict[s] - s).total_seconds() / 60


def failed_no_verdict(runs, verdicts, since=None):
    """(after the last verdict, all in the window): no-verdict batches whose unit run ended failed.
    A run's end is its first end line before the next start. The scored count keeps only the runs that started
    after the latest verdict in the window; with no verdict in the window it is the whole window."""
    starts = _starts(runs)
    ends = sorted((at, kind) for at, kind in runs if kind != "start")
    window = [v for v in verdicts if since is None or v >= since]
    last = max(window) if window else None
    after = total = 0
    for i, s in enumerate(starts):
        nxt = starts[i + 1] if i + 1 < len(starts) else None
        if any(s <= v and (nxt is None or v < nxt) for v in verdicts):
            continue
        end = next(((at, kind) for at, kind in ends if at >= s and (nxt is None or at < nxt)), None)
        if end and end[1] == "failed":
            total += 1
            after += last is None or s > last
    return after, total


def collect(metrics, runtime, now, runs=None, active=None):
    """Score METRIC and FAILED (None = no data: journal, events.md or the unit state unreadable)."""
    unit = f"{os.environ.get('ZF_UNIT_PREFIX') or 'zf'}-release-batch"
    events = release_retained.read(runtime)
    runs = _journal_runs(unit) if runs is None else runs
    if events is None or runs is None:
        metrics[METRIC] = metrics[FAILED] = metrics[FAILED_14D] = None
        return
    retained, closed = events
    verdicts = [at for at, _, _ in retained] + [at for at, _ in closed]
    active = _active(unit) if active is None else active
    metrics[METRIC] = batch_minutes(_starts(runs), verdicts, now, active)
    metrics[FAILED], metrics[FAILED_14D] = failed_no_verdict(runs, verdicts, now - timedelta(days=14))
