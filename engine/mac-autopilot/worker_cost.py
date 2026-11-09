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
  claude         the claude CLI prints no usage to its worker log, and zcode print mode prints none either:
                 attach_provider_usage() reads each CLI's own record instead (Claude project
                 transcripts, the zcode session database), joined by the unit's clone directory and
                 the run interval. A resumed codex stream with no dispatch baseline takes the
                 thread's counters at the end of its previous log (_chain_baselines).

A dispatch counts as a failover when its pipeline.execution reason names a switch away from
the preferred path. Eval runs are not worker logs: their runner already records per-call
usage in <agent-home>/eval/<label>/results.json, and eval_costs() reads that file instead of
re-parsing streams.
"""
import glob
import json
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone

from usage_reader import Usage, claude_unit_responses, codex_stream_facts, zcode_stream_usage, Unavailable

LOG_RE = re.compile(r"^(impl|review|land|triage|supervise)-(.+?)-(\d{8}T\d{6})Z\.worker\.log$")
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


def _usage_delta(last, baseline):
    """This invocation's own usage: a resumed thread's cumulative counters minus the baseline; None
    when there is no baseline or a counter went backwards."""
    if baseline is None or last.input < baseline.input or last.output < baseline.output:
        return None
    cached = None if last.cached is None or baseline.cached is None else last.cached - baseline.cached
    return Usage(last.input - baseline.input, cached, last.output - baseline.output,
                 reasoning=_counter_delta(last.reasoning, baseline.reasoning),
                 cache_write=_counter_delta(last.cache_write, baseline.cache_write))


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
    session, last, need_base = None, None, False
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
        session, last = facts["session_id"], facts["snapshots"][-1] if facts["snapshots"] else None
        if last is not None:
            # A resume stream's counters carry the whole thread: only the delta past the
            # dispatch baseline is this invocation. The mode comes from the log's own
            # pipeline.execution marker, or from the ledger row for pre-marker logs; a
            # marker rewritten by a failover (mode=fresh) resets the baseline to zero, and
            # with neither marker nor row fresh-vs-resume is unknowable, not fresh -- except
            # the supervisor arbiter, whose command never resumes (supervisor-arbiter.sh).
            mode = marker.get("mode") if marker else worker.get("mode")
            if marker is None and not worker and kind != "supervise":
                usage = None
            elif mode == "resume" and (marker is None
                                       or marker.get("reason") != "resume-startup-failed"):
                baseline = _baseline(worker)
                usage, need_base = _usage_delta(last, baseline), baseline is None
            else:
                usage = last  # fresh session: its counters start at zero
    elif text and '"type":"assistant"' in text:
        backend = "claude"  # a claude review log has no usage in the worker log itself; a stream-json implement log ends in a result line
        try:
            usage = zcode_stream_usage(path)
        except Exception:
            usage = None
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
            "session": session, "last": last, "need_base": need_base,
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
    _chain_baselines(rows)
    return rows


def _chain_baselines(rows):
    """A resumed stream whose dispatch baseline is gone (workers.json keeps 60 rows): the thread's
    cumulative counters at the end of its previous log are the baseline. Rows are oldest first."""
    ended = {}
    for row in rows:
        last = row["last"]
        if row["need_base"] and row["session"] in ended and last is not None:
            row["usage"] = _usage_delta(last, ended[row["session"]])
        if row["session"] and last is not None:
            ended[row["session"]] = last


def _stamp(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except (AttributeError, ValueError):
        return None


def _zcode_turns(db, clone_root):
    """{clone directory: [(start, Usage)]} from the zcode session database, read only."""
    like = clone_root.rstrip("/").replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "/wt-%"
    turns = {}
    try:
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as con:
            query = ("select s.directory, t.started_at, t.input_tokens, t.cache_read_input_tokens, "
                     "t.output_tokens, t.reasoning_tokens, t.cache_creation_input_tokens "
                     "from turn_usage t join session s on s.id = t.session_id "
                     "where s.directory like ? escape '\\'")
            for directory, started, inp, cached, out, reasoning, write in con.execute(query, (like,)):
                if all(type(v) is int and v >= 0 for v in (started, inp, out)) and (cached or 0) <= inp:
                    turns.setdefault(directory, []).append((
                        datetime.fromtimestamp(started / 1000, timezone.utc),
                        Usage(inp, cached, out, reasoning=reasoning, cache_write=write)))
    except sqlite3.Error:
        pass
    return turns


def attach_provider_usage(rows, units=(), projects_root=None, clone_root=None, zcode_db=None):
    """Give a row its own usage from the CLI's own record when the worker log carries none.

    Claude (review runs print only the report) and zcode print mode (stdout is the report) keep their
    per-call usage in ~/.claude/projects transcripts and the zcode session database, keyed by
    the unit's clone directory wt-<unit>. A row owns the entries that started inside its
    interval; an entry joins one row only. A bare PR number (trimmed log) maps to pr-<n> and to
    every unit that carries that PR. The interval ends at the latest of log, report and ledger
    finish: a stdout-report run writes its log at the start. Rows already measured, codex rows
    and phases without a model run are left alone."""
    agent_home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or os.path.expanduser("~/.zenoforge")
    projects_root = projects_root or os.environ.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects")
    clone_root = clone_root or os.environ.get("MAC_AUTOPILOT_WT_ROOT") or os.path.join(agent_home, "autopilot-wt")
    zcode_db = zcode_db or os.environ.get("ZCODE_DB") or os.path.expanduser("~/.zcode/cli/db/db.sqlite")
    by_pr = {}
    for unit in units:
        if isinstance(unit, dict) and unit.get("pr") and unit.get("id"):
            by_pr.setdefault(str(unit["pr"]), []).append(unit["id"])
    claude, zcode = {}, None
    for row in rows:
        if row["usage"] is not None or row["footer_tokens"] is not None \
                or row["backend"] not in (None, "claude", "zcode") \
                or row["phase"] not in ("implement", "repair", "review", "rereview"):
            continue
        key = row["unit"]
        names = [key] + ([f"pr-{key}"] + by_pr.get(key, []) if key.isdigit() else [])
        end = max(row["end"], row["finished_at"] or row["end"])
        try:
            end = max(end, datetime.fromtimestamp(os.path.getmtime(row["path"][:-len(".worker.log")] + ".md"), timezone.utc))
        except OSError:
            pass
        for name in names:
            if name not in claude:
                try:
                    claude[name] = [(_stamp(at), u) for at, u in claude_unit_responses(projects_root, clone_root, name)]
                except Unavailable:
                    claude[name] = []
            if zcode is None:
                zcode = _zcode_turns(zcode_db, clone_root)
            for pool, backend, source in ((claude[name], "claude", "claude-project"),
                                          (zcode.get(f"{clone_root.rstrip('/')}/wt-{name}", []), "zcode", "zcode-db")):
                hit = [e for e in pool if e[0] is not None and row["start"] <= e[0] <= end]
                if hit:
                    for e in hit:
                        pool.remove(e)
                    row["usage"] = sum((u for _, u in hit), Usage(0, 0, 0))
                    row["backend"], row["usage_source"] = backend, source
                    break
            if row["usage"] is not None:
                break


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
        # The legacy blended footer has no cache split; its fresh total is unknown.
        total["footer_tokens"] += footer
        total["cached_known"] = False
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


def units_index(units):
    """Units by id, plus each unit's PR under its pr-N key (an id already named pr-N wins), so a
    bare PR number from a trimmed log's file name finds the issue-N unit that owns that PR."""
    by_id = {u.get("id"): u for u in units if isinstance(u, dict) and u.get("id")}
    for unit in list(by_id.values()):
        if unit.get("pr"):
            by_id.setdefault(f"pr-{unit['pr']}", unit)
    return by_id


def ticket_of(unit_key, units_by_id):
    """The issue number a unit key belongs to, or None. issue-N keys carry it directly; a bare
    PR number (the file-name form of a trimmed log) maps through units_index's pr-N key."""
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
    units_by_id = units_index(units)
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


def token_efficiency_kpis(rows, units, now):
    """Seven-day completed-unit token KPIs from the cost ledger and full unit history.

    The window selects units by their merge/terminal history event. Each selected unit carries
    its lifetime worker spend, so all four measures share the same completed-unit cohort. Raw
    PR-number keys resolve through the unit's PR; ambiguous or missing keys stay in 未归属.
    """
    stop = now if isinstance(now, datetime) else datetime.fromtimestamp(now, timezone.utc)
    if stop.tzinfo is None:
        stop = stop.replace(tzinfo=timezone.utc)
    stop = stop.astimezone(timezone.utc)
    start = stop - timedelta(days=7)
    ledger = aggregate(rows, units, stop.timestamp())

    by_id = {str(u.get("id")): u for u in units if isinstance(u, dict) and u.get("id")}
    by_pr, by_issue = {}, {}
    issue_ids = {}
    for unit_id, unit in by_id.items():
        pr = unit.get("pr")
        if pr is not None:
            by_pr.setdefault(str(pr), unit)
        issue = unit.get("issue")
        if issue is not None:
            issue_ids.setdefault(str(issue), set()).add(unit_id)
    for issue, unit_ids in issue_ids.items():
        if len(unit_ids) == 1:
            by_issue[issue] = by_id[next(iter(unit_ids))]

    def resolve(key, ticket=None):
        key = str(key or "")
        if key in by_id:
            return by_id[key]
        if key.startswith("pr-"):
            return by_pr.get(key[3:])
        if key.isdigit():
            return by_pr.get(key) or by_issue.get(key)
        if ticket is not None:
            return by_issue.get(str(ticket))
        return None

    unit_cost = {}
    unattributed = []
    for item in ledger["by_unit"]:
        unit = resolve(item.get("unit"), item.get("ticket"))
        if unit is None:
            unattributed.append(item)
            continue
        total = unit_cost.setdefault(str(unit["id"]), {
            "tokens": 0, "raw": 0, "fresh": 0, "fresh_known": True, "ledger_keys": 0,
        })
        total["tokens"] += item.get("tokens") or 0
        total["raw"] += item.get("raw") or 0
        total["ledger_keys"] += 1
        if item.get("fresh") is None:
            total["fresh_known"] = False
        else:
            total["fresh"] += item["fresh"]

    merged_ids, waste_ids = set(), set()
    first_pass_ids = set()
    merge_stages = {"merged", "landed"}
    waste_stages = {"closed", "parked"}
    for unit_id, unit in by_id.items():
        history = [event for event in (unit.get("history") or []) if isinstance(event, dict)]
        parsed = []
        for event in history:
            value = event.get("at")
            try:
                at = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
                if at.tzinfo is not None:
                    parsed.append((at.astimezone(timezone.utc), event.get("stage") or ""))
            except (TypeError, ValueError, OverflowError):
                continue
        merge_events = [(at, stage) for at, stage in parsed if stage in merge_stages]
        if any(start <= at <= stop for at, _ in merge_events):
            merged_ids.add(unit_id)
            if not any(event.get("stage") in ("review-request-changes", "review-block") for event in history):
                first_pass_ids.add(unit_id)
        elif not merge_events:
            stage = str(unit.get("stage") or "")
            end_at = max((at for at, _ in parsed), default=None)
            if (stage in waste_stages or stage.startswith("blocked")) and end_at and start <= end_at <= stop:
                waste_ids.add(unit_id)

    cohort_ids = merged_ids | waste_ids
    merged_tokens = sum(unit_cost.get(unit_id, {}).get("tokens", 0) for unit_id in merged_ids)
    merged_raw = sum(unit_cost.get(unit_id, {}).get("raw", 0) for unit_id in merged_ids)
    merged_fresh_known = sum(unit_cost.get(unit_id, {}).get("fresh", 0) for unit_id in merged_ids)
    measured_merged = sum(
        unit_id in unit_cost and unit_cost[unit_id]["fresh_known"] for unit_id in merged_ids
    )
    merged_fresh_complete = bool(merged_ids) and measured_merged == len(merged_ids)
    window_tokens = sum(unit_cost.get(unit_id, {}).get("tokens", 0) for unit_id in cohort_ids)
    waste_tokens = sum(unit_cost.get(unit_id, {}).get("tokens", 0) for unit_id in waste_ids)
    repair_tokens = 0
    for row in rows:
        unit = resolve(row.get("unit"))
        if unit is None or str(unit["id"]) not in cohort_ids or row.get("phase") != "repair":
            continue
        usage = row.get("usage")
        if usage is not None:
            repair_tokens += usage.raw
        elif row.get("footer_tokens") is not None:
            repair_tokens += row["footer_tokens"]

    all_tokens = sum(item.get("tokens") or 0 for item in ledger["by_unit"])
    unattributed_fresh = sum(item.get("fresh") or 0 for item in unattributed)
    unattributed_fresh_known = sum(item.get("fresh") is not None for item in unattributed)
    unattributed_count = len(unattributed)
    merged_count = len(merged_ids)
    return {
        "window_days": 7,
        "window_start": start.isoformat().replace("+00:00", "Z"),
        "window_end": stop.isoformat().replace("+00:00", "Z"),
        "merged_units": merged_count,
        "merged_fresh_tokens": merged_fresh_known if merged_fresh_complete else None,
        "merged_fresh_known_tokens": merged_fresh_known,
        "merged_fresh_measured_units": measured_merged,
        "fresh_tokens_per_merged": merged_fresh_known / merged_count if merged_fresh_complete else None,
        "merged_raw_tokens": merged_tokens,
        "raw_tokens_per_merged": merged_tokens / merged_count if merged_count else None,
        "waste_units": len(waste_ids),
        "waste_tokens": waste_tokens,
        "window_tokens": window_tokens,
        "waste_pct": 100 * waste_tokens / window_tokens if window_tokens else None,
        "first_pass_units": len(first_pass_ids),
        "first_pass_pct": 100 * len(first_pass_ids) / merged_count if merged_count else None,
        "repair_tokens": repair_tokens,
        "repair_pct": 100 * repair_tokens / window_tokens if window_tokens else None,
        "matched_ledger_tokens": all_tokens - sum(item.get("tokens") or 0 for item in unattributed),
        "all_ledger_tokens": all_tokens,
        "unattributed": {
            "ledger_keys": unattributed_count,
            "tokens": sum(item.get("tokens") or 0 for item in unattributed),
            "raw_tokens": sum(item.get("raw") or 0 for item in unattributed),
            "fresh_tokens": unattributed_fresh if unattributed_fresh_known == unattributed_count else None,
            "fresh_measured_keys": unattributed_fresh_known,
        },
    }


TOKEN_EFFICIENCY_CRITERIA = {
    "efficiency.fresh_tokens_per_merged_7d": ("efficiency", "fresh tokens per merged unit, rolling 7 d", 800_000, 4_800_000, False),
    "efficiency.unmerged_waste_pct_7d": ("efficiency", "tokens on unmerged terminal units / terminal cohort tokens, rolling 7 d %", 35, 50, False),
    "efficiency.first_pass_yield_pct_7d": ("efficiency", "merged units with no review changes or blocks, rolling 7 d %", 65, 50, True),
    "efficiency.repair_phase_pct_7d": ("efficiency", "repair phase share of terminal cohort tokens, rolling 7 d %", 30, 45, False),
}
TOKEN_EFFICIENCY_MEANING = {
    "efficiency.fresh_tokens_per_merged_7d": "近 7 天合并单元的生命周期 fresh token（未缓存输入 + 输出）均值；cache split 不完整时为 NO-DATA。健康线沿用工作单 fresh token p90 的静态尺度 800k，异常线为历史 p90 的两倍 4.8M。",
    "efficiency.unmerged_waste_pct_7d": "近 7 天终态单元 cohort 中，closed / parked / blocked 且从未合并的 token 占比；越低越好。健康线 35% 要比已测匹配台账 43% 少 8 个百分点；50% 比基线高 7 个百分点，作为异常线。",
    "efficiency.first_pass_yield_pct_7d": "近 7 天合并单元中，历史从未出现 review-request-changes 或 review-block 的比例；高说明少返工。健康线 65% 接近最近窗口的 67% / 前一窗口的 71%；异常线 50% 低于 58% 的全时基线。",
    "efficiency.repair_phase_pct_7d": "近 7 天终态单元 cohort 中 repair phase token ÷ 全部 token；越低越好。健康线 30% 比已测全时 36.4% 少 6.4 个百分点；45% 高于基线 8.6 个百分点，作为异常线。",
}
TOKEN_EFFICIENCY_SOURCE = {
    "efficiency.fresh_tokens_per_merged_7d": "cost_ledger.by_unit 的 lifetime fresh（缓存读取除外）按 units.json + units-archive.json 的 merged/landed 历史事件筛选近 7 天，再除以窗口合并单元数。",
    "efficiency.unmerged_waste_pct_7d": "cost_ledger.by_unit 按 units.json + units-archive.json 的终态历史筛选近 7 天；从未合并的 closed / parked / blocked token ÷ 同 cohort 全部 token。未归属 key 单列，不并入分子或分母。",
    "efficiency.first_pass_yield_pct_7d": "units.json + units-archive.json 的 merged/landed 事件筛选近 7 天；合并单元全历史中没有 review-request-changes / review-block 的比例。",
    "efficiency.repair_phase_pct_7d": "worker_cost repair phase 用量 + units.json / units-archive.json 的近 7 天终态单元 cohort；repair token ÷ 同 cohort cost_ledger token。",
}


def ticket_spend(rows, units):
    """Lifetime spend per ticket with its close time (latest merged/landed event). A ticket
    with no merged/landed unit anywhere is open."""
    units_by_id = units_index(units)
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
    out = []
    for ticket, total in spend.items():
        complete = total
        if total["unknown_runs"]:
            # Per-ticket fresh spend is complete only when every worker row was measurable.
            complete = {**total, "cached_known": False}
        out.append({"ticket": ticket, **_finish(complete),
                    "closed_at": closes[ticket].strftime("%Y-%m-%dT%H:%M:%SZ") if ticket in closes else None,
                    "open": ticket not in closes})
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
