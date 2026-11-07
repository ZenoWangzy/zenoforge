"""Production-failure episodes from head-watch's alert log, grouped as the owner mail groups them (node_health)."""
import re
from datetime import datetime, timezone

GAP = 30 * 60  # alerts less than 30 minutes apart are one episode, counted at its first alert
LINE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) PROD-DB-TIMEOUT(?: |$)")


def episode_dates(path):
    """UTC dates (YYYY-MM-DD) of each episode's first alert, oldest first; None if the log is unreadable."""
    try:
        with open(path, encoding="utf-8", errors="replace") as source:
            stamps = sorted(int(datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
                            for m in map(LINE.match, source) if m)
    except OSError:
        return None
    firsts = [at for i, at in enumerate(stamps) if i == 0 or at - stamps[i - 1] >= GAP]
    return [datetime.fromtimestamp(at, timezone.utc).strftime("%Y-%m-%d") for at in firsts]
