"""Traffic readers for the dashboard: today's hourly samples and the multi-day trend.
Both read the sampler's metrics/traffic-<UTC day>.jsonl files. The last line of a day's file holds that day's totals.
Readers skip what they cannot read and never raise, so one bad day cannot break the dashboard."""
import json, os
from datetime import datetime, timedelta, timezone

def _day_path(agent_home, day):
    return os.path.join(agent_home, f"metrics/traffic-{day:%Y-%m-%d}.jsonl")

def _partial(coverage):
    # shortcut: the daily coverage schema is written by the sampler, which is not in this repo; only explicit gap markers count as partial, upgrade when the producer's schema is pinned.
    if isinstance(coverage, dict):
        return bool(coverage.get("gaps") or coverage.get("partial") or coverage.get("complete") is False)
    return isinstance(coverage, str) and ("gap" in coverage.lower() or "partial" in coverage.lower())

def history(agent_home):
    """Today's hourly samples, last 180 rows: [{"t", "gbh"}]."""
    rows = []
    try:
        with open(_day_path(agent_home, datetime.now(timezone.utc).date())) as stream:
            for line in stream.read().splitlines()[-180:]:
                row = json.loads(line)
                rows.append({"t": row.get("sampled_epoch"), "gbh": row.get("gb_per_hour")})
    except (OSError, ValueError):
        pass
    return rows

def days(agent_home, count=14):
    """The last `count` UTC days, oldest first. A day with no readable totals is left out."""
    out = []
    today = datetime.now(timezone.utc).date()
    for back in range(count - 1, -1, -1):
        day = today - timedelta(days=back)
        try:
            with open(_day_path(agent_home, day)) as stream:
                last = [line for line in stream.read().splitlines() if line.strip()][-1]
            daily = json.loads(last)["daily"]
            out.append({
                "day": day.isoformat(),
                "rx_gb": daily["rx_bytes"] / 1e9,
                "tx_gb": daily["tx_bytes"] / 1e9,
                "category_rx_gb": {k: v / 1e9 for k, v in (daily.get("category_rx_bytes") or {}).items()},
                "coverage": daily.get("coverage"),
                "partial": _partial(daily.get("coverage")),
            })
        except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError):
            continue
    return out
