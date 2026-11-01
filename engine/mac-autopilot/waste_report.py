#!/usr/bin/env python3
"""Pipeline waste and rule-use report from the pipeline's own records (read-only).

Usage: waste_report.py [--runtime DIR] [--audit FILE] [--since ISO] [--until ISO]
                       [--lesson-zero-hit-days N] [--codex-sessions DIR]
                       [--claude-projects DIR --clone-root DIR] [--tokens-json FILE]
With --codex-sessions the report adds token usage, empty-input polls and scoped document reads from the Codex rollouts;
--claude-projects adds Claude review usage. --tokens-json writes those same numbers as JSON. Without those options the
report prints the recorded T6 baseline and the T7 CI-repair and review events from the ledger and audit log.

Sources (all read, nothing written; not synced to the runtime, never run from a tick):
  <runtime>/scheduler.log and scheduler.log.1   default report window (the log rotates at 5 MB into .1)
  <runtime>/units.json                          the ledger (CI repair, review and session events)
  <runtime>/ci-spend-cache.json                 ci_spend.py's per-run job minutes (24 h), for linked T7 events
  repository lessons/RULES.md                   IDs reported as zero-hit candidates
  <audit>                                       logs/actions-run-cancellations.jsonl under the agent home
The window defaults to the time range the scheduler log files cover; --since/--until can select another window.
Lesson rule matches and footprint observations are events in that same log; zero-hit candidates are withheld when the retained observation span is shorter than the requested interval.
"""
import argparse, json, math, os, re, sys
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usage_reader
from env_config import zf_env
from datetime import datetime, timedelta, timezone

LINE_RE = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] (.*)$")
TS_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d")
UNFILTERED_EMPTY_POLL_BASELINE = 19_466
TOKEN_CI_BASELINE = [
    "T6 recorded baseline, 2026-10-20 through 2026-10-23 (fixed reference figures, not measured by this run; T7 and T8 below are measured)",
    "  CI repairs: 346 turns, 2,425M raw, 91.7M fresh",
    "  no patch call: 156 turns, 663M raw, 31.4M fresh; no write: 115 turns; about 41 wrote through the shell",
    "  causes: cancellation, stale-base, attributable, infrastructure, missing-log, unclassified (fix-report pattern attribution is noisy)",
    "  approval churn: 667 approvals, 473 re-approvals; 133 of 194 approved units needed another repair, 66 needed three or more",
    "  approve to merge: median 13.3h, p90 39.9h",
    "  review loop: six or more rejections 35 of 235 units; rounds after five 15.6% raw, 15.7% fresh",
    "  findings-block coverage: 36% before Claude reviews, 19% since the Claude switch",
]
SCOPED_DOCUMENT_LABELS = {
    "docs/agents/issue-tracker.md": "issue tracker",
    "docs/agents/branch-delivery-preflight.md": "branch delivery preflight",
    ".agents/skills/ask-matt/SKILL.md": "Matt entry skill",
    "docs/agents/development-flow.md": "development flow",
    "docs/agents/issue-pipeline.md": "issue pipeline",
}
LANE_ORDER = ("product", "pipeline-system", "direct-main", "main-red", "hot-patch", "unknown")
CI_REPAIR_STAGES = {"ci-red", "ci-test-red"}
REVIEW_SWITCH = "2026-10-22T05:39:00Z"
CI_CAUSES = ("cancellation", "stale-base", "attributable", "infrastructure", "missing-log", "unclassified")
LESSON_HIT_RE = re.compile(r"(?:^|\s)lesson-rule-hit lesson=((?:V|D)\d+)(?:\s|$)")
LESSON_OBSERVED_RE = re.compile(r"(?:^|\s)lesson-rule-observed matches=(\d+)(?:\s|$)")
RULE_ID_RE = re.compile(r"^\*\*((?:V|D)\d+)\*\*", re.MULTILINE)


def parse_ts(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def nearest_rank(values, p):
    """Smallest value with at least p percent of the values at or below it."""
    values = sorted(values)
    return values[max(0, math.ceil(p / 100 * len(values)) - 1)]


def read_log(path):
    """[(timestamp text, message)] of a timestamped log, or None when the file is absent."""
    if not os.path.exists(path):
        return None
    with open(path, errors="replace") as handle:
        return [(m.group(1), m.group(2)) for m in map(LINE_RE.match, handle.read().splitlines()) if m]


def norm_ts(value):
    """A ledger timestamp as YYYY-MM-DDTHH:MM:SSZ, or None."""
    return str(value)[:19] + "Z" if TS_RE.match(str(value)) else None


def approval_to_merge_minutes(units, since, until):
    """Minutes from each approval to the merge it led to (same pairing as node_health's approve-to-ship), merges inside the window."""
    minutes = []
    for u in units:
        events = [(h.get("stage") or "", norm_ts(h.get("at"))) for h in u.get("history") or []]
        events = [(k, t) for k, t in events if t]
        for i, (kind, approved) in enumerate(events):
            if kind != "review-approve":
                continue
            for later, at in events[i + 1:]:
                if later in ("review-request-changes", "review-approve"):
                    break  # the head was sent back or approved again: that approval did not lead to a merge
                if later in ("merged", "landed"):
                    if since <= at <= until:
                        minutes.append((parse_ts(at) - parse_ts(approved)).total_seconds() / 60)
                    break
    return minutes


def share(part, whole):
    return f"{100 * part / whole:.1f}%" if whole else "n/a"


def read_audit(path):
    """The cancel audit records (one JSON object per line), or None when the file is absent."""
    if not os.path.exists(path):
        return None
    records = []
    with open(path, errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict) and record.get("when") and record.get("run_id"):
                records.append(record)
    return records


def read_json(path):
    if not os.path.exists(path):
        return None
    with open(path, errors="replace") as handle:
        return json.load(handle)


def _window_events(units, since, until):
    return [
        (unit, event)
        for unit in units
        for event in unit.get("history") or []
        if (at := norm_ts(event.get("at"))) and since <= at <= until
    ]


def _ci_cause(event, audit_by_run):
    """Classify observed CI repair text; fix-report pattern attribution is intentionally labelled noisy."""
    values = [event.get("cause"), event.get("result"), event.get("reason")]
    run_id = str(event.get("run_id") or "")
    if run_id in audit_by_run:
        values.append(audit_by_run[run_id].get("reason"))
    text = " ".join(str(value) for value in values if value).lower()
    if re.search(r"cancel(?:led|ed|lation)?|upstream cancellation", text):
        return "cancellation"
    if re.search(r"stale[ -]base|behind main|main (?:already )?fixed|update[ -]branch", text):
        return "stale-base"
    if re.search(r"pr[- ]owned|introduced by (?:this|the) pr|caused by (?:this|the) pr|attributable", text):
        return "attributable"
    if re.search(r"infrastruct|runner|network|timed? ?out|github outage", text):
        return "infrastructure"
    if re.search(r"(?:log|logs).{0,30}(?:missing|unavailable|absent)|(?:missing|no).{0,30}(?:failing|test|failure)?.{0,12}log", text):
        return "missing-log"
    return "unclassified"


def _third_rejections(events):
    """Third review rejection in each round group; an advisor/arbiter outcome starts the next group."""
    by_unit = {}
    for unit, event in events:
        by_unit.setdefault(unit.get("id") or id(unit), []).append(event)
    found = []
    for history in by_unit.values():
        history.sort(key=lambda event: norm_ts(event.get("at")) or "")
        count = 0
        for event in history:
            stage = event.get("stage") or event.get("ev") or ""
            if stage == "review-request-changes":
                count += 1
                if count == 3:
                    found.append(event)
            elif stage in {"advisor-ruling", "advisor-unavailable", "arbiter-review"}:
                count = 0
    return found


def ci_review_events_section(units, audit, cache, since, until, units_available=True):
    """CI repair causes, approval churn and review-loop outcomes from the local ledger and audit sources."""
    header = f"T7 observed CI and review events ({since} .. {until})"
    if not units_available:
        return [header, "  unit ledger unavailable; event outcomes are unavailable"]

    events = _window_events(units, since, until)
    repairs = [(unit, event) for unit, event in events if (event.get("stage") or event.get("ev")) in CI_REPAIR_STAGES]
    audit_by_run = {}
    for record in audit or []:
        run_id = str(record.get("run_id") or "")
        if run_id:
            audit_by_run[run_id] = record
    causes = {cause: 0 for cause in CI_CAUSES}
    for unit, event in repairs:
        cause = _ci_cause(event, audit_by_run)
        if cause == "unclassified":
            event_at = norm_ts(event.get("at"))
            updated_after_failure = any(
                (hop.get("stage") or hop.get("ev")) == "ci-red-update-branch"
                and (hop_at := norm_ts(hop.get("at"))) and event_at and event_at <= hop_at <= until
                for hop in unit.get("history") or []
            )
            if updated_after_failure:
                cause = "stale-base"
        causes[cause] += 1

    approvals_by_unit = {}
    rejections_by_unit = {}
    review_units = set()
    verdicts = {"review-approve": 0, "review-request-changes": 0, "review-block": 0}
    hops = 0
    ci_run_ids = set()
    for unit, event in events:
        stage = event.get("stage") or event.get("ev") or ""
        key = unit.get("id") or id(unit)
        if stage in verdicts:
            verdicts[stage] += 1
            review_units.add(key)
        if stage == "review-approve":
            approvals_by_unit[key] = approvals_by_unit.get(key, 0) + 1
        if stage == "review-request-changes":
            rejections_by_unit[key] = rejections_by_unit.get(key, 0) + 1
        if stage == "ci-red-update-branch":
            hops += 1
        if stage in CI_REPAIR_STAGES | {"ci-red-rerun", "ci-red-update-branch"} and event.get("run_id") is not None:
            ci_run_ids.add(str(event["run_id"]))

    approvals = sum(approvals_by_unit.values())
    approved_units = set(approvals_by_unit)
    reapprovals = sum(max(count - 1, 0) for count in approvals_by_unit.values())
    post_approval_repairs = {}
    for unit in units:
        key = unit.get("id") or id(unit)
        if key not in approved_units:
            continue
        approval_times = [norm_ts(event.get("at")) for event in unit.get("history") or []
                          if (event.get("stage") or event.get("ev")) == "review-approve"
                          and (at := norm_ts(event.get("at"))) and since <= at <= until]
        if not approval_times:
            continue
        first_approval = min(approval_times)
        later_repairs = [event for event in unit.get("history") or []
                         if (event.get("stage") or event.get("ev")) == "repair-delivered"
                         and (at := norm_ts(event.get("at"))) and first_approval < at <= until]
        post_approval_repairs[key] = len(later_repairs)

    merge_minutes = approval_to_merge_minutes(units, since, until)
    merge_text = (f"median {nearest_rank(merge_minutes, 50) / 60:.1f}h, p90 {nearest_rank(merge_minutes, 90) / 60:.1f}h "
                  f"across {len(merge_minutes)} approvals" if merge_minutes else "n/a")
    rejections = sum(rejections_by_unit.values())
    six_plus = sum(1 for count in rejections_by_unit.values() if count >= 6)

    era = {"before Claude reviews": [0, 0], "since Claude switch": [0, 0]}
    for unit in units:
        for finding_record in unit.get("review_findings") or []:
            at = norm_ts(finding_record.get("at"))
            if not at or not since <= at <= until:
                continue
            group = era["since Claude switch"] if at >= REVIEW_SWITCH else era["before Claude reviews"]
            group[1] += 1
            group[0] += finding_record.get("block") == "ok"
    coverage = "before Claude reviews {} ({}); since Claude switch {} ({})".format(
        f"{era['before Claude reviews'][0]}/{era['before Claude reviews'][1]}",
        share(*era["before Claude reviews"]),
        f"{era['since Claude switch'][0]}/{era['since Claude switch'][1]}",
        share(*era["since Claude switch"]),
    )
    third_rejections = _third_rejections(events)
    outcome_counts = {"advisor-ruling": 0, "advisor-unavailable": 0, "arbiter-review": 0}
    for _, event in events:
        stage = event.get("stage") or event.get("ev") or ""
        if stage in outcome_counts:
            outcome_counts[stage] += 1

    if ci_run_ids:
        linked = [(run_id, cache[run_id]) for run_id in ci_run_ids if run_id in cache]
        if linked:
            minutes = sum(float(minutes) for _, record in linked for _, minutes in record.get("jobs", []))
            run_count = f"{len(linked)} linked runs" if len(linked) == len(ci_run_ids) else f"{len(linked)} of {len(ci_run_ids)} linked runs"
            ci_minutes = f"{minutes:.1f} across {run_count}"
        else:
            ci_minutes = f"n/a ({len(ci_run_ids)} linked run IDs have no cached jobs)"
    else:
        ci_minutes = "n/a (no CI run IDs on unit events)"

    return [
        header,
        f"  CI repair events: {len(repairs)}; causes cancellation {causes['cancellation']}, stale-base {causes['stale-base']}, "
        f"attributable {causes['attributable']}, infrastructure {causes['infrastructure']}, "
        f"missing-log {causes['missing-log']}, unclassified {causes['unclassified']} (fix-report pattern attribution is noisy)",
        f"  approvals: {approvals} events, {reapprovals} re-approvals across {len(approved_units)} units",
        f"  post-approval repair: {sum(count > 0 for count in post_approval_repairs.values())} of {len(approved_units)} approved units; "
        f"{sum(count >= 3 for count in post_approval_repairs.values())} needed three or more",
        f"  approve to merge: {merge_text}",
        f"  review rejections: {rejections} across {len(rejections_by_unit)} units; six or more {six_plus} of {len(review_units)}",
        f"  findings-block coverage: {coverage}",
        f"  verdicts: approve {verdicts['review-approve']}, request-changes {verdicts['review-request-changes']}, "
        f"block {verdicts['review-block']}; stale-base hops {hops}",
        f"  CI runner minutes: {ci_minutes}",
        f"  third rejections: {len(third_rejections)}; advisor rulings {outcome_counts['advisor-ruling']}, "
        f"unavailable {outcome_counts['advisor-unavailable']}, arbiter fallbacks {outcome_counts['arbiter-review']}",
    ]


def tokens_section(units, codex, claude, since, until):
    """Session, turn, raw and fresh tokens per class, and first-call input of fresh and resumed launches.
    The class of a Codex session is the ledger role that recorded its id (review or repair), else unattributed.
    Returns (lines, data)."""
    role_of = {sid: role for u in units for role, sid in (u.get("session_ids") or {}).items()}
    classes = {}
    fresh_first, resumed_first = [], []
    for sid, st in (codex or {}).items():
        row = classes.setdefault(role_of.get(sid, "unattributed"), {"sessions": 0, "turns": 0, "units": set(), "usage": usage_reader.Usage(0, 0, 0)})
        row["sessions"] += 1
        row["turns"] += st["turns"]
        row["usage"] += st["usage"]
        fresh_first += st["first_input"][:1]
        resumed_first += st["first_input"][1:]
    total = sum((r["usage"] for r in classes.values()), usage_reader.Usage(0, 0, 0))
    lines = ["T1 Codex usage per class (raw = input + output, fresh = uncached input + output)"]
    data = {"codex": {"sessions": sum(r["sessions"] for r in classes.values()), "turns": sum(r["turns"] for r in classes.values()),
                      "raw": total.raw, "fresh": total.fresh, "classes": {}}}
    for name, row in sorted(classes.items(), key=lambda kv: (-kv[1]["usage"].raw, kv[0])):
        u = row["usage"]
        lines.append(f"  {name:<14}{row['sessions']:>6} sessions {row['turns']:>6} turns {u.raw / 1e6:>10.1f}M raw {u.fresh / 1e6:>9.1f}M fresh")
        data["codex"]["classes"][name] = {"sessions": row["sessions"], "turns": row["turns"], "raw": u.raw, "fresh": u.fresh}
    lines.append(f"  {'total':<14}{data['codex']['sessions']:>6} sessions {data['codex']['turns']:>6} turns {total.raw / 1e6:>10.1f}M raw {total.fresh / 1e6:>9.1f}M fresh")

    def stat(values):
        return {"calls": len(values), "median": nearest_rank(values, 50), "p90": nearest_rank(values, 90)} if values else {"calls": 0}
    data["first_call_input"] = {"fresh": stat(fresh_first), "resumed": stat(resumed_first)}
    lines.append("T2 first-call input tokens (first model call of a turn; turn 1 is the fresh launch, later turns are resumed)")
    for label, values in (("fresh", fresh_first), ("resumed", resumed_first)):
        lines.append(f"  {label:<14}" + (f"{len(values):>6} launches, median {nearest_rank(values, 50)}, p90 {nearest_rank(values, 90)}" if values else "no launches in the window"))
    if claude is not None:
        usage = sum((u for _, u in claude), usage_reader.Usage(0, 0, 0))
        data["claude_review"] = {"sessions": len(claude), "raw": usage.raw, "fresh": usage.fresh}
        lines.append(f"T3 Claude review usage: {len(claude)} sessions, {usage.raw / 1e6:.1f}M raw, {usage.fresh / 1e6:.1f}M fresh")
    if codex is not None:
        poll_lines, poll_data = empty_polls_section(codex)
        lines.extend(poll_lines)
        data["empty_input_polls"] = poll_data
        doc_lines, doc_data = scoped_document_reads_section(units, codex)
        lines.extend(doc_lines)
        data["scoped_document_reads"] = doc_data
        repair_lines, repair_data = ci_repair_usage_section(units, codex, since, until)
        lines.extend(repair_lines)
        data["ci_repair_usage"] = repair_data
    return lines, data


def _turn_usage(turns):
    usages = [turn["usage"] for turn in turns if turn.get("usage") is not None]
    if len(usages) != len(turns):
        return None, None
    return sum(usage.raw for usage in usages), sum(usage.fresh for usage in usages)


def ci_repair_usage_section(units, codex, since, until):
    """Codex repair usage linked by the unit ledger, split by observed patch and shell-write calls."""
    repair_sids = set()
    for unit in units:
        has_ci_repair = any(
            (event.get("stage") or event.get("ev")) in CI_REPAIR_STAGES
            and (at := norm_ts(event.get("at"))) and since <= at <= until
            for event in unit.get("history") or []
        )
        sid = (unit.get("session_ids") or {}).get("repair")
        if has_ci_repair and isinstance(sid, str) and sid in codex:
            repair_sids.add(sid)

    turns = [turn for sid in repair_sids for turn in codex[sid].get("turn_facts", [])]
    if not turns:
        data = {"linked_turns": 0, "raw": None, "fresh": None, "no_patch_call": {"turns": 0, "raw": None, "fresh": None},
                "no_write": {"turns": 0, "raw": None, "fresh": None}, "shell_writes_without_patch": 0}
        return ["T8 linked Codex CI-repair turns: no linked sessions in the window"], data

    no_patch = [turn for turn in turns if turn.get("patch_calls", 0) == 0]
    no_write = [turn for turn in no_patch if turn.get("shell_write_calls", 0) == 0]
    shell_write = [turn for turn in no_patch if turn.get("shell_write_calls", 0) > 0]
    total_raw, total_fresh = _turn_usage(turns)
    no_patch_raw, no_patch_fresh = _turn_usage(no_patch)
    no_write_raw, no_write_fresh = _turn_usage(no_write)

    def token_text(raw, fresh):
        return f"{raw:,} raw, {fresh:,} fresh" if raw is not None else "n/a raw/fresh"

    data = {
        "linked_turns": len(turns), "raw": total_raw, "fresh": total_fresh,
        "no_patch_call": {"turns": len(no_patch), "raw": no_patch_raw, "fresh": no_patch_fresh},
        "no_write": {"turns": len(no_write), "raw": no_write_raw, "fresh": no_write_fresh},
        "shell_writes_without_patch": len(shell_write),
    }
    lines = [
        f"T8 linked Codex CI-repair turns: {len(turns)} turns, {token_text(total_raw, total_fresh)} "
        "(the ledger keeps one repair session per unit; an earlier session replaced by a fresh retry is not linked)",
        f"  no patch call: {len(no_patch)} turns, {token_text(no_patch_raw, no_patch_fresh)}",
        f"  no write call observed: {len(no_write)} {'turn' if len(no_write) == 1 else 'turns'}, {token_text(no_write_raw, no_write_fresh)}; "
        f"shell writes among no-patch turns: {len(shell_write)}",
    ]
    return lines, data


def empty_polls_section(codex):
    """T4: empty stdin writes, their requested waits and measured token cost from the same Codex rollouts as T1."""
    polls = [(sid, index, poll) for sid, stats in codex.items()
             for index, poll in enumerate(stats.get("polls", []))]
    known_yields = [poll["yield_time_ms"] for _, _, poll in polls if poll["yield_time_ms"] is not None]
    under_30 = [(sid, index, poll) for sid, index, poll in polls
                if poll["yield_time_ms"] is not None and poll["yield_time_ms"] < 30_000]
    full_wait = [(sid, index, poll) for sid, index, poll in under_30 if poll["full_wait"]]
    usage_known = [poll["usage"] for _, _, poll in polls if poll["usage"] is not None]
    raw = sum(usage.raw for usage in usage_known)
    fresh = sum(usage.fresh for usage in usage_known)
    full_wait_usage = [poll["usage"] for _, _, poll in full_wait if poll["usage"] is not None]
    full_wait_raw = sum(usage.raw for usage in full_wait_usage)
    full_wait_fresh = sum(usage.fresh for usage in full_wait_usage)
    histogram = {}
    for value in known_yields:
        histogram[str(value)] = histogram.get(str(value), 0) + 1

    groups = {}
    for sid, index, poll in full_wait:
        session_id = poll["session_id"]
        key = (sid, session_id) if session_id is not None else (sid, f"poll-{index}")
        groups.setdefault(key, []).append(poll)
    projected = 0
    saved_polls = []
    for group in groups.values():
        group.sort(key=lambda poll: poll["called_at_ms"] or 0)
        windows = sum(poll["yield_time_ms"] for poll in group)
        calls_at_30s = math.ceil(windows / 30_000)
        projected += min(len(group), calls_at_30s)
        saved_polls.extend(group[min(len(group), calls_at_30s):])

    avoided_usage_known = [poll["usage"] for poll in saved_polls if poll["usage"] is not None]
    avoided_polls = len(saved_polls)
    saved_raw = sum(usage.raw for usage in avoided_usage_known) if len(avoided_usage_known) == avoided_polls else None
    saved_fresh = sum(usage.fresh for usage in avoided_usage_known) if len(avoided_usage_known) == avoided_polls else None
    under_share = len(under_30) / len(known_yields) if known_yields else None
    hours = sum(poll["yield_time_ms"] for _, _, poll in full_wait) / 3_600_000
    data = {
        "count": len(polls),
        "historical_unfiltered": UNFILTERED_EMPTY_POLL_BASELINE,
        "yield_histogram_ms": dict(sorted(histogram.items(), key=lambda item: int(item[0]))),
        "under_30_seconds": {"count": len(under_30), "eligible": len(known_yields), "share": under_share},
        "full_wait_small_yield": {"count": len(full_wait), "hours": hours,
                                  "raw": full_wait_raw if len(full_wait_usage) == len(full_wait) else None,
                                  "fresh": full_wait_fresh if len(full_wait_usage) == len(full_wait) else None},
        "raw_resent": raw if len(usage_known) == len(polls) else None,
        "fresh_resent": fresh if len(usage_known) == len(polls) else None,
        "priced_polls": len(usage_known),
        "counterfactuals": {"30_seconds": {"polls": projected, "avoided_polls": avoided_polls,
                                             "raw_saved": saved_raw, "fresh_saved": saved_fresh}},
    }
    histogram_text = ", ".join(
        f"{int(value) // 1000}s {count}" if int(value) % 1000 == 0 else f"{value}ms {count}"
        for value, count in data["yield_histogram_ms"].items()
    ) or "no recorded yields"
    token_text = f"{raw} / {fresh}" if len(usage_known) == len(polls) else f"n/a ({len(usage_known)} of {len(polls)} polls priced)"
    saved_text = f"{saved_raw} / {saved_fresh}" if saved_raw is not None else "n/a"
    lines = [
        f"T4 empty-input polls: {len(polls)} filtered (historical unfiltered baseline {UNFILTERED_EMPTY_POLL_BASELINE:,})",
        f"  yield histogram: {histogram_text}",
        f"  under 30 seconds: {len(under_30)} of {len(known_yields)} polls with recorded yields "
        f"({share(len(under_30), len(known_yields))})",
        f"  full-wait under 30 seconds: {len(full_wait)} polls, {hours:.3g} hours",
        f"  raw/fresh tokens resent: {token_text}",
        f"  30-second counterfactuals: {len(full_wait)} full-wait polls become {projected}; "
        f"{avoided_polls} fewer, raw/fresh saved {saved_text}",
    ]
    return lines, data


def unit_lane(unit):
    if not unit.get("id"):
        return "unknown"
    if unit.get("main_red") is True:
        return "main-red"
    if unit.get("hotpatch") is True:
        return "hot-patch"
    if unit.get("lane") == "direct-main":
        return "direct-main"
    if any(event.get("stage") == "needs-pr" for event in unit.get("history") or []):
        return "pipeline-system"
    if unit.get("lane") == "pr":
        return "product"
    return "unknown"


def scoped_document_reads_section(units, codex):
    """T5: unique Codex sessions that read each scoped process document, grouped by the unit lane."""
    lane_of_session = {
        sid: unit_lane(unit)
        for unit in units
        for sid in (unit.get("session_ids") or {}).values()
        if isinstance(sid, str)
    }
    by_lane = {}
    for sid, stats in codex.items():
        lane = lane_of_session.get(sid, "unknown")
        group = by_lane.setdefault(lane, {"sessions": 0, "reads": {path: set() for path in SCOPED_DOCUMENT_LABELS}})
        group["sessions"] += 1
        for path in stats.get("document_reads", []):
            if path in group["reads"]:
                group["reads"][path].add(sid)

    data = {}
    lines = ["T5 scoped document reads by lane (unique sessions / lane sessions)"]
    for lane in sorted(by_lane, key=lambda name: LANE_ORDER.index(name) if name in LANE_ORDER else len(LANE_ORDER)):
        group = by_lane[lane]
        session_count = group["sessions"]
        data[lane] = {"sessions": session_count, "documents": {}}
        lines.append(f"  {lane} ({session_count} sessions)")
        for path, label in SCOPED_DOCUMENT_LABELS.items():
            read_count = len(group["reads"][path])
            ratio = read_count / session_count if session_count else None
            data[lane]["documents"][path] = {"read_sessions": read_count, "share": ratio}
            lines.append(f"    {label:<31} {read_count}/{session_count} ({share(read_count, session_count)})")
    return lines, data


def lesson_rule_hits_section(scheduler_rows, until, zero_hit_days):
    """Show rules not selected into an implement brief during the requested retained-log window."""
    end = parse_ts(until)
    cutoff = end - timedelta(days=zero_hit_days)
    retained = [(parse_ts(stamp), message) for stamp, message in scheduler_rows
                if parse_ts(stamp) <= end]
    observations = [at for at, message in retained if LESSON_OBSERVED_RE.search(message)]
    repo_root = zf_env("REPO_DIR") or os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    rules_path = os.path.join(repo_root, "lessons", "RULES.md")
    with open(rules_path, encoding="utf-8", errors="replace") as source:
        rule_ids = sorted(set(RULE_ID_RE.findall(source.read())))

    header = f"T8 lesson rule matches (zero-hit lookback {zero_hit_days} days ending {until}; match = selected into implement brief)"
    if not observations:
        return [header, "  no footprint observations in retained scheduler logs; zero-hit candidates withheld"]
    oldest = min(observations)
    covered_days = max(0.0, (end - oldest).total_seconds() / 86400)
    if oldest > cutoff:
        return [header,
                f"  retained observations span {covered_days:.2f} days from {oldest.strftime('%Y-%m-%dT%H:%M:%SZ')}; need {zero_hit_days} days, candidates withheld"]

    recorded = Counter()
    windowed = Counter()
    last_hit = {}
    observation_rows = [(at, message) for at, message in retained if at >= oldest]
    for at, message in observation_rows:
        match = LESSON_HIT_RE.search(message)
        if not match:
            continue
        lesson_id = match.group(1)
        recorded[lesson_id] += 1
        last_hit[lesson_id] = at
        if at >= cutoff:
            windowed[lesson_id] += 1

    zero_hit = [lesson_id for lesson_id in rule_ids if windowed[lesson_id] == 0]
    matched_rules = sum(1 for lesson_id in rule_ids if windowed[lesson_id] > 0)
    lines = [header,
             f"  retained observation coverage {covered_days:.2f} days; observations={len(observations)} rules={len(rule_ids)} matched={matched_rules} zero-hit candidates={len(zero_hit)}"]
    for lesson_id in zero_hit:
        last = last_hit.get(lesson_id)
        last_text = last.strftime("%Y-%m-%dT%H:%M:%SZ") if last else "not-recorded"
        lines.append(f"  {lesson_id} hits_{zero_hit_days}d=0 last_hit={last_text} retained_hits={recorded[lesson_id]}")
    return lines


def main():
    agent_home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or os.path.expanduser("~/.zenoforge")
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", default=os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR")
                    or os.path.join(agent_home, "checkout", ".scratch-supervisor", "autopi"))
    ap.add_argument("--audit", default=os.path.join(agent_home, "logs", "actions-run-cancellations.jsonl"))
    ap.add_argument("--codex-sessions", help="Codex sessions root (the YYYY/MM/DD tree); adds the token section")
    ap.add_argument("--claude-projects", help="Claude projects root; adds Claude review usage (needs --clone-root)")
    ap.add_argument("--clone-root", help="the worker clone root whose wt-<unit> directories name the Claude logs")
    ap.add_argument("--tokens-json", help="write the token section as JSON to this file")
    ap.add_argument("--lesson-zero-hit-days", type=int, default=30,
                    help="lookback for lesson rules never selected into an implement brief (default: 30)")
    ap.add_argument("--since")
    ap.add_argument("--until")
    args = ap.parse_args()
    if args.lesson_zero_hit_days < 1:
        ap.error("--lesson-zero-hit-days must be at least 1")

    covered = []  # (file, what was read) for the "read" lines: which files and which time range the report covers

    def path(name):
        return os.path.join(args.runtime, name)

    def read_logs(*names):  # the rotated file, then the live one
        merged = []
        for name in names:
            lines = read_log(path(name))
            if lines is None:
                covered.append((name, "absent"))
                continue
            merged += lines
            covered.append((name, f"{len(lines):>3} lines  {lines[0][0]} .. {lines[-1][0]}" if lines else "  0 lines"))
        return merged

    def note(name, found, count, unit, first="", last=""):
        covered.append((name, "absent" if not found else f"{count:>3} {unit}  {first} .. {last}" if count else f"  0 {unit}"))

    sched = read_logs("scheduler.log.1", "scheduler.log")
    units_doc = read_json(path("units.json"))
    units = (units_doc or {}).get("units", [])
    covered.append(("units.json", f"{len(units):>3} units" if units_doc is not None else "absent"))
    audit = read_audit(args.audit)
    note("audit", audit is not None, len(audit or []), "lines", min((r["when"] for r in audit or []), default=""), max((r["when"] for r in audit or []), default=""))
    cache = read_json(path("ci-spend-cache.json"))
    created = [v.get("created") or "" for v in (cache or {}).values()]
    note("ci-spend-cache.json", cache is not None, len(cache or {}), "runs", min(created, default=""), max(created, default=""))

    if not sched and not (args.since and args.until):
        sys.exit(f"waste_report: no scheduler log lines under {args.runtime}; pass --runtime (and --since/--until to report other sources alone)")
    since = args.since or min(t for t, _ in sched)
    until = args.until or max(t for t, _ in sched)
    all_sched = sched
    days = (parse_ts(until) - parse_ts(since)).total_seconds() / 86400
    sched = [(t, m) for t, m in sched if since <= t <= until]
    audit = [r for r in audit or [] if since <= r["when"] <= until]

    out = ["waste report", f"window  {since} .. {until} ({days:.2f} days)"]
    out += [f"read    {name:<19} {text}" for name, text in covered]
    out += TOKEN_CI_BASELINE
    out += ci_review_events_section(units, audit, cache or {}, since, until, units_doc is not None)
    out += lesson_rule_hits_section(all_sched, until, args.lesson_zero_hit_days)
    if args.codex_sessions or args.claude_projects:
        try:
            codex = usage_reader.codex_sessions_between(args.codex_sessions, since, until) if args.codex_sessions else None
            claude = (usage_reader.claude_unit_sessions(args.claude_projects, args.clone_root, since, until)
                      if args.claude_projects and args.clone_root else None)
        except usage_reader.Unavailable as error:
            sys.exit(f"waste_report: {error}")
        lines, data = tokens_section(units, codex, claude, since, until)
        out += lines
        if args.tokens_json:
            with open(args.tokens_json, "w", encoding="utf-8") as handle:
                json.dump({"window": {"since": since, "until": until}, **data}, handle, indent=1)
                handle.write("\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
