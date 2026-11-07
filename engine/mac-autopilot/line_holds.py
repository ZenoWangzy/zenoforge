"""Line holds: the switches that stop the whole delivery line, and their required metadata.

A line hold is `release_train.enabled=false` in the runtime config, or a valid PAUSE file.
Issue holds already require --holder/--release/--expires (hold_issue); a line hold is the
same kind of decision and owes the same metadata: an owner, and an expiry that has not
passed. A violation (no owner, no expiry, past expiry) is counted in `holds.line_violations`
and fails loud once per hold per day — expiry never re-enables anything, the hold stays held
until a person releases it or re-registers it (11-03: a demo disabled the train "until after
the demo"; nobody reverted it and 217 h of delivery went dark with no alarm).

node_health.py sits at its size-ratchet baseline, so these rows' metric tables, the check
and the once-per-day alerting live here and merge into node_health at import.
"""
import json, os, re, subprocess
from datetime import datetime, timezone

CRITERIA = {
    "holds.line_violations": ("holds", "line holds without owner/expiry, or past expiry", 0, 1, False),
}
MEANING = {
    "holds.line_violations": "把整条线停住的 hold（release_train.enabled=false 或有效 PAUSE）里，缺负责人、缺到期时间或已过期的数量。issue 级 hold 早就有 owner 和 expiry（hold_issue），线级 hold 之前可以无限期：一次演示关掉 release train 说好事后恢复，没人恢复，217 小时无人发现。过期只每天告警，绝不自动恢复。",
}
SOURCE = {
    "holds.line_violations": "runtime config.json 的 release_train（enabled=false 而 hold 缺 owner/reason/expires_at 或已过期）与 $AGENT_HOME/PAUSE（纯文本 = 没有 owner；JSON 的 owner/expires_at 可选，缺了或已过期同样违规；空/坏 JSON 的 PAUSE 流水线本身就不理会，不算 hold）",
}
CONFIG_HOLD_ID = "release_train.enabled"
PAUSE_HOLD_ID = "PAUSE"


def _read_json(path):
    try:
        value = json.load(open(path))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _ts(value):
    try:
        return datetime.strptime(str(value)[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def pause_state(agent_home):
    """Scorecard PAUSE summary (moved from node_health.py for the size ratchet)."""
    path = os.path.join(agent_home, "PAUSE")
    if not os.path.exists(path):
        return None
    try:
        state = json.load(open(path))
    except (OSError, ValueError):
        return None
    return {"since": state.get("timestamp"), "reason": state.get("reason")}


def _hold_row(hold_id, hold, now):
    """One violating line hold's row, or None when the hold is registered and unexpired.

    expires_at is ISO UTC (…Z); anything unparseable counts as no expiry and fails loud."""
    owner = str((hold or {}).get("owner") or "").strip()
    reason = " ".join(str((hold or {}).get("reason") or "").split())[:120]
    expiry = _ts((hold or {}).get("expires_at") or "")
    expired_ago_hours = int((now - expiry).total_seconds() // 3600) if expiry is not None and expiry <= now else None
    problem = None
    if not owner:
        problem = "no-owner"
    elif expiry is None:
        problem = "no-expiry"
    elif expiry <= now:
        problem = "expired"
    if problem is None:
        return None
    return {"hold": hold_id, "owner": owner or "missing", "reason": reason or "missing",
            "problem": problem, "expired_ago_hours": expired_ago_hours}


def _config_hold(config, now):
    train = config.get("release_train") if isinstance(config, dict) else None
    if not isinstance(train, dict) or train.get("enabled") is not False:
        return None
    hold = train.get("hold")
    return _hold_row(CONFIG_HOLD_ID, hold if isinstance(hold, dict) else None, now)


def _pause_hold(path, now):
    """The PAUSE line hold: plain text pauses with no owner; a JSON PAUSE follows
    manual_pause_is_valid (caller=operator, complete strings, ISO UTC timestamp), so an
    empty or malformed file that the pipelines ignore is not a hold at all."""
    try:
        raw = open(path, errors="replace").read()
    except OSError:
        return None
    if not raw.strip():
        return None
    try:
        doc = json.loads(raw)
    except ValueError:
        return _hold_row(PAUSE_HOLD_ID, None, now)
    if not isinstance(doc, dict) or doc.get("caller") != "operator":
        return None
    if any(not isinstance(doc.get(key), str) or not doc.get(key)
           for key in ("reason", "issue", "provider", "model", "timestamp")):
        return None
    if _ts(doc.get("timestamp")) is None:
        return None
    return _hold_row(PAUSE_HOLD_ID, doc, now)


def line_violations(config, pause_path, now):
    """Rows for every violating line hold, in a fixed order (config first, then PAUSE)."""
    rows = []
    config_row = _config_hold(config, now)
    if config_row:
        rows.append(config_row)
    pause_row = _pause_hold(pause_path, now)
    if pause_row:
        rows.append(pause_row)
    return rows


def collect(metrics, runtime, agent_home, now):
    """Score the line holds into the shared metrics dict; returns the violation rows."""
    rows = line_violations(_read_json(os.path.join(runtime, "config.json")),
                           os.path.join(agent_home, "PAUSE"), now)
    metrics["holds.line_violations"] = len(rows)
    return rows


def _alert_line(row, now):
    expired = f" expired_ago={row['expired_ago_hours']}h" if row["expired_ago_hours"] is not None else ""
    return (f"hold={row['hold']} owner={row['owner']} reason={row['reason']} "
            f"problem={row['problem']}{expired} action=re-register-with-owner-and-expiry-or-release")


def alert(runtime, agent_home, repo_root, now):
    """One alerts/events.md line and one supervisor inbox line per violating hold per day.

    The inbox goes through supervisor_inbox_append_once keyed by hold and day, exactly like
    a founder-req stage change; lib.sh's same-text dedup rolls with the real day, so a
    still-violating hold wakes the supervisor once every day until it is fixed. The inbox
    append is attempted first and the events line only follows a success (a repeat call is
    a no-op once the once-key exists), so a failed append retries on the next tick."""
    rows = line_violations(_read_json(os.path.join(runtime, "config.json")),
                           os.path.join(agent_home, "PAUSE"), now)
    if not rows:
        return
    day = f"{now:%Y-%m-%d}"
    events = os.path.join(runtime, "alerts", "events.md")
    seen = ""
    try:
        seen = open(events, errors="ignore").read()
    except OSError:
        pass
    lib = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib.sh")
    os.makedirs(os.path.dirname(events), exist_ok=True)
    for row in rows:
        if re.search(rf"^\[{re.escape(day)}T.*LINE-HOLD-VIOLATION hold={re.escape(row['hold'])}\b",
                     seen, re.M):
            continue
        done = subprocess.run(
            ["bash", "-c", 'source "$1" && supervisor_inbox_append_once "$2" "$3"',
             "bash", lib, f"line-hold:{row['hold']}:{day}", f"line-hold {_alert_line(row, now)}"],
            capture_output=True, env={**os.environ, "AGENT_HOME": agent_home})
        if done.returncode != 0:
            continue
        with open(events, "a") as out:
            out.write(f"[{now:%Y-%m-%dT%H:%M:%SZ}] LINE-HOLD-VIOLATION {_alert_line(row, now)}\n")
