#!/usr/bin/env python3
"""Worker cost ledger: what each unit, ticket, phase and backend spent (read-only, stateless).

The supervisor's *.worker.log files are the durable record: the file name carries kind, unit
key and the start stamp, the mtime is the end of the run, and the content carries that
invocation's own usage. workers.json only maps the recent window (its harvested tail is
trimmed to 60 rows), so a log without a worker row is attributed from its file name and
reports unknown usage -- never zero.

Usage formats, one per backend (usage_reader.py is the single reader):
  codex --json   turn.completed usage snapshots are cumulative thread counters. A resume
                 marker (the first pipeline.execution line) subtracts the dispatch baseline,
                 so the earlier session's tokens are never counted again. A stream
                 overwritten after a failed resume startup (codex-repair-run.sh truncates the
                 log and rewrites the marker to mode=fresh, reason=resume-startup-failed)
                 belongs wholly to the cold run: the stale baseline is not subtracted and the
                 truncated attempt adds nothing. A fresh stream needs no baseline -- the
                 session's counters start at zero.
  codex legacy   the "tokens used" footer is one blended total; the split stays unknown.
  zcode          the usage of the last {"type":"result"} line, per invocation.
  claude         the claude CLI prints no usage to its worker log; usage stays unknown here
                 (the daily meter reads Claude from the projects directory).

A dispatch counts as a failover when its pipeline.execution reason names a switch away from
the preferred path. Eval runs are not worker logs: their runner already records per-call
usage in <agent-home>/eval/<label>/results.json, and eval_costs() reads that file instead of
re-parsing streams.
"""
import glob
import json
import os
import re
from datetime import datetime, timezone

from usage_reader import Usage, codex_stream_facts, zcode_stream_usage

LOG_RE = re.compile(r"^(impl|review|land|triage)-(.+?)-(\d{8}T\d{6})Z\.worker\.log$")
UNIT_KEY_RE = re.compile(r"-(?:selfcheck[0-9]+-)?(?:fix|r)$")
FOOTER_RE = re.compile(r"tokens used\n([\d,]+)")
# build_codex_command's reasons for not taking the preferred path; initial, no-recorded-session,
# no-new-failure and session-too-large are ordinary dispatches, not switches.
FAILOVER_REASONS = frozenset(("provider-changed", "model-changed", "session-files-missing",
                              "resume-startup-failed"))
UNKNOWN = "unattributed"


def _read_workers(sup):
    try:
        with open(os.path.join(sup, "autopi", "workers.json"), encoding="utf-8") as source:
            workers = json.load(source).get("workers") or []
    except (OSError, ValueError, AttributeError):
        workers = []
    return {w.get("log"): w for w in workers if isinstance(w, dict) and w.get("log")}


def _marker(text):
    """The last pipeline.execution marker of a log (it rides at the top; a failover rewrites it)."""
    marker = None
    for line in text.splitlines():
        if '"pipeline.execution"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and record.get("type") == "pipeline.execution":
            marker = record
    return marker


def _baseline(worker):
    start = worker.get("token_usage_start")
    if not isinstance(start, dict):
        return None
    values = [start.get(name) for name in ("input_tokens", "cached_input_tokens", "output_tokens")]
    if any(type(v) is not int or v < 0 for v in values):
        return None
    reasoning = start.get("reasoning_tokens")
    cache_write = start.get("cache_write_input_tokens")
    return Usage(*values, reasoning=reasoning if type(reasoning) is int and reasoning >= 0 else None,
                 cache_write=cache_write if type(cache_write) is int and cache_write >= 0 else None)


def _counter_delta(value, baseline):
    if value is None or baseline is None or value < baseline:
        return None
    return value - baseline


def measure(path, worker):
    """One worker log's facts: phase, unit key, wall clock, that invocation's own usage, failover.

    `worker` is the log's workers.json row, or None once trimmed. usage is None when the
    invocation's own counters cannot be read; footer_tokens carries the legacy blended total."""
    match = LOG_RE.match(os.path.basename(path))
    if not match:
        return None
    kind, name, stamp = match.groups()
    start = datetime.strptime(stamp, "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc)
    end = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc)
    worker = worker or {}
    unit = worker.get("unit") or UNIT_KEY_RE.sub("", name)
    if worker.get("type"):
        phase = worker["type"]
    elif kind == "impl":  # trimmed ledger rows keep the phase in the file name
        phase = "repair" if name.endswith("-fix") else "implement"
    elif kind == "review":
        phase = "rereview" if name.endswith("-r") else "review"
    else:
        phase = kind
    self_fix = bool(re.search(r"-selfcheck[0-9]+-fix$", name))
    # The legacy "tokens used" footer is the log's last lines: a tail read is enough, so the
    # per-tick walk keeps the old unit_spend cost for footer logs. Anything else needs the
    # full stream (marker at the head, snapshots throughout).
    try:
        with open(path, "rb") as source:
            source.seek(max(0, os.path.getsize(path) - 8192))
            tail = source.read().decode(errors="ignore")
    except OSError:
        tail = ""
    usage, footer, backend = None, None, None
    marker, text, json_stream = None, None, False
    footers = FOOTER_RE.findall(tail)
    if footers:
        footer, backend = int(footers[-1].replace(",", "")), "codex"
    else:
        try:
            with open(path, encoding="utf-8", errors="ignore") as source:
                text = source.read()
        except OSError:
            text = None
    if text and ('"turn.completed"' in text or '"thread.started"' in text):
        backend = "codex"
        json_stream = True
        marker = _marker(text)
        facts = codex_stream_facts(path)
        last = facts["snapshots"][-1] if facts["snapshots"] else None
        if last is not None:
            # A resume stream's counters carry the whole thread: only the delta past the
            # dispatch baseline is this invocation. The mode comes from the log's own
            # pipeline.execution marker, or from the ledger row for pre-marker logs; a
            # marker rewritten by a failover (mode=fresh) resets the baseline to zero, and
            # with neither marker nor row fresh-vs-resume is unknowable, not fresh.
            mode = marker.get("mode") if marker else worker.get("mode")
            if marker is None and not worker:
                usage = None
            elif mode == "resume" and (marker is None
                                       or marker.get("reason") != "resume-startup-failed"):
                baseline = _baseline(worker)
                if baseline is not None and last.input >= baseline.input \
                        and last.output >= baseline.output:
                    cached = None if last.cached is None or baseline.cached is None \
                        else last.cached - baseline.cached
                    usage = Usage(last.input - baseline.input, cached,
                                  last.output - baseline.output,
                                  reasoning=_counter_delta(last.reasoning, baseline.reasoning),
                                  cache_write=_counter_delta(last.cache_write, baseline.cache_write))
            else:
                usage = last  # fresh session: its counters start at zero
    elif text and '"type":"assistant"' in text:
        backend = "claude"  # a claude review log; no usage in the worker log itself
    elif text:
        try:
            usage, backend = zcode_stream_usage(path), "zcode"
        except Exception:
            usage, backend = None, None
    # workers.json trims old harvested rows; the dispatch marker is durable in the log and
    # carries the selected model for those rows. Prefer the live worker record when present.
    model = worker.get("model") or (marker or {}).get("model") or ""
    if model.startswith("claude-"):
        backend = "claude"
    return {"log": os.path.basename(path), "path": path, "unit": unit, "phase": phase,
            "self_fix": self_fix, "backend": backend, "model": model,
            "start": start, "end": end, "minutes": max(0.0, (end - start).total_seconds() / 60),
            "finished_at": _parse_ts(worker.get("finished_at")) if worker else None,
            "usage": usage, "footer_tokens": footer, "json_stream": json_stream,
            "failover": bool(marker and marker.get("reason") in FAILOVER_REASONS),
            "harvested": worker.get("harvested") is True}


def run_rows(sup, finished_only=False):
    """Cost rows of every worker log in the supervisor dir, oldest first. Stateless: reading
    the same files again yields the same rows, so a re-scan cannot double-count. In finished-only
    mode, a present unharvested worker row is still running; an absent row has been trimmed from
    the harvested tail and the durable worker log remains the source."""
    by_log = _read_workers(sup)
    rows = []
    for path in glob.glob(os.path.join(sup, "*.worker.log")):
        worker = by_log.get(os.path.basename(path))
        if finished_only and worker is not None and worker.get("harvested") is not True:
            continue
        row = measure(path, worker)
        if row is not None:
            rows.append(row)
    rows.sort(key=lambda r: r["start"])
    return rows


def _new_total():
    return {"in": 0, "cached": 0, "cached_known": True, "out": 0, "raw": 0,
            "footer_tokens": 0, "unknown_runs": 0, "wall_min": 0.0, "runs": 0, "failovers": 0}


def _add_total(total, row):
    usage, footer = row["usage"], row["footer_tokens"]
    if usage is not None:
        total["in"] += usage.input
        total["cached"] += usage.cached or 0
        total["cached_known"] &= usage.cached is not None
        total["out"] += usage.output
        total["raw"] += usage.raw
    elif footer is not None:
        total["footer_tokens"] += footer
    else:
        total["unknown_runs"] += 1
    total["wall_min"] += row["minutes"]
    total["runs"] += 1
    total["failovers"] += 1 if row["failover"] else 0


def _finish(total):
    """Public shape: fresh (uncached input + output) is None when any cached counter is missing."""
    out = dict(total)
    out["wall_min"] = round(total["wall_min"], 1)
    out["uncached"] = total["in"] - total["cached"] if total["cached_known"] else None
    out["fresh"] = total["raw"] - total["cached"] if total["cached_known"] else None
    if not total["cached_known"]:
        out["cached"] = None
    out["tokens"] = total["raw"] + total["footer_tokens"]
    return out


def ticket_of(unit_key, units_by_id):
    """The issue number a unit key belongs to, or None. issue-N keys carry it directly; a bare
    PR number (the file-name form of a trimmed log) maps through the unit's pr-N record."""
    for key in (unit_key, f"pr-{unit_key}" if str(unit_key or "").isdigit() else None):
        unit = units_by_id.get(key)
        if unit is not None and unit.get("issue"):
            try:
                return int(unit["issue"])
            except (TypeError, ValueError):
                return None
    match = re.fullmatch(r"issue-(\d+)", unit_key or "")
    return int(match.group(1)) if match else None


def aggregate(rows, units, now):
    """Rows grouped by unit, ticket, phase and backend, plus the last-24h totals.

    A log whose unit key has no ticket (triage runs, trimmed ledgers) lands in no by_ticket
    bucket; its tokens still count toward by_phase, by_backend and the 24h totals."""
    units_by_id = {u.get("id"): u for u in units if isinstance(u, dict) and u.get("id")}
    now = datetime.fromtimestamp(now, timezone.utc)
    by_unit, by_ticket, by_phase, by_backend = {}, {}, {}, {}
    unit_phases = {}
    window = _new_total()
    for row in rows:
        _add_total(by_unit.setdefault(row["unit"], _new_total()), row)
        unit_phases.setdefault(row["unit"], set()).add(row["phase"])
        _add_total(by_phase.setdefault(row["phase"], _new_total()), row)
        _add_total(by_backend.setdefault(row["backend"] or UNKNOWN, _new_total()), row)
        if (now - row["end"]).total_seconds() <= 24 * 3600:
            _add_total(window, row)
        ticket = ticket_of(row["unit"], units_by_id)
        if ticket is not None:
            _add_total(by_ticket.setdefault(ticket, _new_total()), row)
    units_out = [{"unit": key, "ticket": ticket_of(key, units_by_id),
                  "phases": sorted(unit_phases[key]), **_finish(total)}
                 for key, total in by_unit.items()]
    units_out.sort(key=lambda r: -r["raw"])
    tickets_out = [{"ticket": ticket, **_finish(total)}
                   for ticket, total in by_ticket.items()]
    tickets_out.sort(key=lambda r: -r["raw"])
    return {"by_unit": units_out, "by_ticket": tickets_out,
            "by_phase": {k: _finish(v) for k, v in sorted(by_phase.items())},
            "by_backend": {k: _finish(v) for k, v in sorted(by_backend.items())},
            "last_24h": _finish(window),
            "unknown_runs": sum(t["unknown_runs"] for t in by_unit.values())}


def ticket_spend(rows, units):
    """Lifetime spend per ticket with its close time (latest merged/landed event). A ticket
    with no merged/landed unit anywhere is open."""
    units_by_id = {u.get("id"): u for u in units if isinstance(u, dict) and u.get("id")}
    done = ("merged", "landed")
    spend, closes = {}, {}
    for row in rows:
        ticket = ticket_of(row["unit"], units_by_id)
        if ticket is not None:
            _add_total(spend.setdefault(ticket, _new_total()), row)
    for unit in units:
        ticket = ticket_of(unit.get("id"), units_by_id)
        if ticket is None:
            continue
        for event in unit.get("history") or []:
            if event.get("stage") in done:
                stamp = _parse_ts(event.get("at"))
                if stamp is not None:
                    closes[ticket] = max(closes.get(ticket, stamp), stamp)
    out = [{"ticket": ticket, **_finish(total),
            "closed_at": closes[ticket].strftime("%Y-%m-%dT%H:%M:%SZ") if ticket in closes else None,
            "open": ticket not in closes}
           for ticket, total in spend.items()]
    out.sort(key=lambda r: -r["raw"])
    return out


def _parse_ts(value):
    try:
        return datetime.strptime(str(value)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def ticket_bound(history):
    """Per-ticket bounds from completed tickets' history: healthy near p50 x 1.5 and unhealthy
    near p90 x 2 -- the same convention as usage_reader.daily_bound. None without any sample."""
    values = sorted(v for v in history if v is not None and v >= 0)
    if not values:
        return None

    def percentile(fraction):
        return values[min(len(values) - 1, int(fraction * len(values)))]
    return {"healthy": int(percentile(0.5) * 1.5), "unhealthy": int(percentile(0.9) * 2),
            "samples": len(values), "provisional": len(values) < 7}


def eval_costs(eval_home, now):
    """Per eval label: the tokens and wall clock its runner already recorded in results.json.

    A label's tokens stay None when any row is unknown (the runner's own null-propagation).
    The 24h window is the results.json modification time -- rows are appended as runs finish."""
    now = datetime.fromtimestamp(now, timezone.utc)
    labels = []
    for path in glob.glob(os.path.join(eval_home, "*", "results.json")):
        try:
            with open(path, encoding="utf-8") as source:
                results = json.load(source)
            rows = results.get("results") or []
        except (OSError, ValueError, AttributeError):
            continue
        if not isinstance(rows, list) or not rows:
            continue
        known = [r for r in rows if isinstance(r, dict)]
        tokens = sum(r["tokens"] for r in known if type(r.get("tokens")) is int) \
            if all(type(r.get("tokens")) is int for r in known) else None
        labels.append({
            "label": results.get("label") or os.path.basename(os.path.dirname(path)),
            "runs": len(known),
            "tokens": tokens,
            "unknown_tokens": sum(1 for r in known if type(r.get("tokens")) is not int),
            "wall_seconds": round(sum(r.get("wallSeconds") or 0 for r in known), 1),
            "model_wall_seconds": round(sum(r.get("modelWallSeconds") or 0 for r in known), 1),
            "finished_at": datetime.fromtimestamp(os.path.getmtime(path), timezone.utc).isoformat(),
        })
    labels.sort(key=lambda r: r["finished_at"], reverse=True)
    recent = [l for l in labels
              if (now - datetime.fromisoformat(l["finished_at"])).total_seconds() <= 24 * 3600]
    window = {"labels": len(recent), "runs": sum(l["runs"] for l in recent),
              "tokens": sum(l["tokens"] for l in recent if l["tokens"] is not None)
              if all(l["tokens"] is not None for l in recent) else None,
              "unknown_tokens": sum(l["unknown_tokens"] for l in recent),
              "wall_seconds": round(sum(l["wall_seconds"] for l in recent), 1),
              "model_wall_seconds": round(sum(l["model_wall_seconds"] for l in recent), 1)}
    return {"labels": labels[:20], "last_24h": window}
