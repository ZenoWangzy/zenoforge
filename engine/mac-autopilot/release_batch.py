"""Release batch duration: minutes from a release-batch unit start to its verdict, for the latest batch.

issue-pipeline.sh dispatch_release_batch starts the transient unit `<ZF_UNIT_PREFIX>-release-batch`; its start is the
journal's `Started <unit>.service` line. Its verdict is the first release-retained or release-closer line in
alerts/events.md after that start (release_retained.read). A batch still active with no verdict reads as its age so
far, not as a duration. A batch that ended with no verdict (no release) is not counted. Bounds are TENTATIVE
(head, 2026-11-08): re-derive after 10 batches with a verdict.
"""
import bisect, os, subprocess
from datetime import datetime

import release_retained

METRIC = "release.batch_minutes"
CRITERIA = {METRIC: ("release", "minutes of the latest release batch, start to verdict (running: age so far)", 120, 240, False)}
MEANING = {METRIC: "最近一次发布批次从启动到结论（release-retained 或 release-closer）的分钟数；批次仍在运行时显示已经跑了多少分钟。暂定标准（2026-11-08 head），满 10 个有结论的批次后重新校准。"}
SOURCE = {METRIC: "journalctl --user 的 <前缀>-release-batch 单元 Started 行（启动）；alerts/events.md 的 release-retained / release-closer 行（结论）；systemctl --user is-active（是否仍在运行）"}
JOURNAL_SINCE = "14 days ago"


def _journal_starts(unit):
    """Start times of the unit from the user journal (aware datetimes), or None when it cannot be read."""
    try:
        out = subprocess.run(["journalctl", "--user", "--no-pager", "-o", "short-iso", "--since", JOURNAL_SINCE,
                              "-u", f"{unit}*", "-g", f"Started {unit}.service"],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    starts = []
    for line in out.stdout.splitlines():
        stamp = line.split(" ", 1)[0]
        try:
            starts.append(datetime.fromisoformat(stamp))
        except ValueError:
            continue
    return starts


def _active(unit):
    try:
        return subprocess.run(["systemctl", "--user", "is-active", "--quiet", f"{unit}.service"], timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


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


def collect(metrics, runtime, now, starts=None, active=None):
    """Score METRIC (None = no data: journal, events.md or the unit state unreadable, or no batch yet)."""
    unit = f"{os.environ.get('ZF_UNIT_PREFIX') or 'zf'}-release-batch"
    events = release_retained.read(runtime)
    starts = _journal_starts(unit) if starts is None else starts
    if events is None or starts is None:
        metrics[METRIC] = None
        return
    retained, closed = events
    verdicts = [at for at, _, _ in retained] + [at for at, _ in closed]
    active = _active(unit) if active is None else active
    metrics[METRIC] = batch_minutes(starts, verdicts, now, active)
