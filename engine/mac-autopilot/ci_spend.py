#!/usr/bin/env python3
"""CI runner minutes, and the share that could not change a verdict (writes ci-spend.json for node_health).

Usage: ci_spend.py [--runtime DIR] [--hours N] [--audit FILE] [--fixture FILE] [--repo OWNER/NAME]

Waste is runner time on work whose result nobody can use:
  cancelled            a job that held a runner and was then cancelled (L64: mostly our own cancellations)
  superseded_unapproved a PR run on a head that was replaced before anyone approved it
  nonproduct_postsubmit the product Postsubmit on a [skip ci] main commit: no product code changed (L65)
Completed runs never change, so their job minutes are cached (ci-spend-cache.json); each sample only
fetches jobs of runs that completed since the last one. --fixture reads {"runs": [...], "jobs": {id: [...]}}
instead of calling gh (tests); its optional "prs" list stands in for the PR sizes (pr-sizes.json).
When the shared cancel audit is present, the sample also reports runner minutes by its stable reason.
"""
import argparse, importlib.util, json, os, re, subprocess
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta
import ledger_history
from node_health import LARGE_PR_WINDOW_DAYS, cancel_reason, is_test_path, read_cancel_audit, size_window_units

PR_EVENTS = ("pull_request", "pull_request_target")
JOB_WORKERS = 8  # bounded: a serial job fetch per run took longer than the 300 s sampler limit on a cold cache
BREAKDOWN_ROWS = 15
SHA_RE = re.compile(r"\b[0-9a-f]{40}\b")
CANCEL_AUDIT_REASON_KEYS = (
    "deferred", "slot_wait", "repair_dispatched", "superseded_main_head",
    "review_blocked", "parked", "other",
)


def cancel_audit_minutes(runs, minutes, records, since, until, repo):
    """Runner minutes in cancelled jobs, grouped by the shared audit's stable cancel cause."""
    by_run = {}
    for index, row in enumerate(records):
        at = ts(row.get("when"))
        if not at or not since <= at <= until:
            continue
        if row.get("repo") and row["repo"] != repo:
            continue
        key = (row.get("repo") or "", str(row["run_id"]))
        previous = by_run.get(key)
        reason = row.get("reason") or (previous[2] if previous else "")
        if previous is None or (at, index) >= (previous[0], previous[1]):
            by_run[key] = (at, index, reason)

    buckets = {key: 0.0 for key in CANCEL_AUDIT_REASON_KEYS}
    run_ids = {str(run["id"]) for run in runs}
    labels = {
        "deferred": "deferred",
        "slot_wait": "slot_wait",
        "repair": "repair_dispatched",
        "superseded": "superseded_main_head",
        "review_blocked": "review_blocked",
        "parked": "parked",
    }
    for (_, run_id), (_, _, reason) in by_run.items():
        if run_id not in run_ids:
            continue
        cause = cancel_reason(reason)
        key = labels.get(cause, "other")
        buckets[key] += sum(value for conclusion, value in minutes.get(run_id, []) if conclusion == "cancelled")
    return {key: round(value) for key, value in buckets.items()}



def ts(value):
    try:
        return datetime.strptime(str(value)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def gh_json(path):
    done = subprocess.run(["gh", "api", "--paginate", "--slurp", path], capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip()[:200])
    return json.loads(done.stdout)


def _nontest_added(total_additions, total_count, nodes):
    if (type(total_count) is not int or total_count < 0 or not isinstance(nodes, list)
            or len(nodes) != min(total_count, 100)):
        return None
    test_additions, product_additions = 0, 0
    for file in nodes:
        if (not isinstance(file, dict) or not isinstance(file.get("path"), str)
                or type(file.get("additions")) is not int):
            return None
        if is_test_path(file["path"]):
            test_additions += file["additions"]
        else:
            product_additions += file["additions"]
    if total_count > 100:
        if type(total_additions) is not int:
            return None
        # shortcut: test additions after the first 100 files are unknown, so this can only overcount.
        return total_additions - test_additions
    return product_additions


def fetch_job_minutes(runs, base):
    """{run id: {created, jobs}} for completed runs; JOB_WORKERS calls at a time. A failed call aborts the sample, as before."""
    def one(r):
        key = str(r["id"])
        jobs = [j for page in gh_json(f"{base}/actions/runs/{key}/jobs?filter=all&per_page=100") for j in page.get("jobs", [])]
        return key, {"created": r["created"], "jobs": job_minutes(jobs)}
    with ThreadPoolExecutor(max_workers=JOB_WORKERS) as pool:
        futures = [pool.submit(one, r) for r in runs]
        try:
            return [f.result() for f in futures]
        except Exception:
            for f in futures:
                f.cancel()
            raise


def breakdown(runs, minutes):
    """(conclusion, branch, workflow) -> job minutes, largest first."""
    by = {}
    for r in runs:
        for conclusion, m in minutes.get(str(r["id"]), []):
            key = (conclusion or "none", r["branch"], r["name"])
            by[key] = by.get(key, 0.0) + m
    return sorted(by.items(), key=lambda kv: -kv[1])


def gh_pr_sizes(units, now, previous, repo):
    """Fetch the window's ledger PRs in batches; completed PR sizes are reusable."""
    selected = list(size_window_units(units, now - timedelta(days=LARGE_PR_WINDOW_DAYS), now))
    ids = {str(u["pr"]) for u in selected if str(u.get("pr", "")).isdigit()}
    lines = {k: v for k, v in (previous.get("lines") or {}).items() if k in ids}
    states = {k: v for k, v in (previous.get("states") or {}).items() if k in ids}
    nontest_added = {k: v for k, v in (previous.get("nontest_added") or {}).items()
                     if k in ids and type(v) is int}
    # Open PRs can grow; unknown states include the old 500-entry cache. Closed
    # PRs are refreshed if active, and old cache entries need one non-test count.
    active = {str(u["pr"]) for u in selected if u.get("stage") not in ("closed", "merged", "landed", "done")}
    needed = sorted((n for n in ids if n not in lines or states.get(n) not in ("MERGED", "CLOSED")
                     or n in active or n not in nontest_added), key=int)
    spec = importlib.util.spec_from_file_location("open_pr_snapshot", os.path.join(os.path.dirname(__file__), "..", "open-pr-snapshot.py"))
    snapshot = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(snapshot)
    client = snapshot.Snapshot(repo or os.environ.get("ZF_REPO", ""))
    for start in range(0, len(needed), 25):
        batch = needed[start:start + 25]
        fields = " ".join(
            f"p{n}:pullRequest(number:{n}) {{ additions deletions state files(first:100)"
            "{ totalCount nodes { path additions } } }" for n in batch)
        try:
            response = client.github(fields)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            response = {}
        for n in batch:
            pr = response.get(f"p{n}") or {}
            if type(pr.get("additions")) is int and type(pr.get("deletions")) is int and pr.get("state") in ("OPEN", "CLOSED", "MERGED"):
                lines[n] = pr["additions"] + pr["deletions"]
                states[n] = pr["state"]
                files = pr.get("files")
                count = files.get("totalCount") if isinstance(files, dict) else None
                nodes = files.get("nodes") if isinstance(files, dict) else None
                value = _nontest_added(pr["additions"], count, nodes)
                if value is None:
                    nontest_added.pop(n, None)
                else:
                    nontest_added[n] = value
            else:
                # Missing or failed data must not masquerade as a complete sample.
                if n in active or states.get(n) not in ("MERGED", "CLOSED") or n not in lines:
                    lines.pop(n, None)
                    states.pop(n, None)
                    nontest_added.pop(n, None)
    return {"lines": lines, "states": states, "nontest_added": nontest_added}


def job_minutes(jobs):
    """[[conclusion, minutes]] for jobs that actually held a runner."""
    out = []
    for j in jobs:
        start, end = ts(j.get("started_at")), ts(j.get("completed_at"))
        if start and end and j.get("runner_name"):
            out.append([j.get("conclusion") or "", max(0.0, (end - start).total_seconds() / 60)])
    return out


def approved_heads(units):
    """Heads the ledger approved at ANY time, not just now: a run on them could change a verdict.

    ci_red and the review rejections scrub .approved_sha when they dispatch a repair, but the CI
    that ran on that head is exactly what produced the red verdict the repair acted on — counting
    it as waste inflated the 2026-11-03 sample: 436 of 440 waste-minutes were classified as
    superseded_unapproved. The approval-carried entries name both the carried head and its approved
    base in the result text ("clean main merge <sha> on approved <sha>"), so both stay visible after
    the scrub."""
    heads = set()
    for u in units:
        if u.get("approved_sha"):
            heads.add(u["approved_sha"])
        for h in u.get("history") or []:
            stage, result = h.get("stage"), str(h.get("result") or "")
            if stage in ("review-approve", "supervisor-approve", "merged") and len(result) == 40:
                heads.add(result)
            elif stage == "approval-carried":
                heads.update(SHA_RE.findall(result))
    return heads


def classify(runs, minutes, approved):
    """runs: newest first. minutes: run id -> [[conclusion, min]] for completed runs only."""
    newest = {}
    for r in runs:
        newest.setdefault(r["branch"], r["head"])
    total, by = 0.0, {"cancelled": 0.0, "superseded_unapproved": 0.0, "nonproduct_postsubmit": 0.0}
    for r in runs:
        rows = minutes.get(str(r["id"]))
        if rows is None:
            continue
        run_min = sum(m for _, m in rows)
        total += run_min
        cancelled = sum(m for c, m in rows if c == "cancelled")
        if r["event"] == "workflow_dispatch" and r["branch"] == "main" and r["name"] == "CI" and r["skip_ci"]:
            by["nonproduct_postsubmit"] += run_min
        elif r["event"] in PR_EVENTS and r["head"] != newest.get(r["branch"]) and r["head"] not in approved:
            by["superseded_unapproved"] += run_min
        else:
            by["cancelled"] += cancelled
    waste = sum(by.values())
    return {"total_min": round(total), "waste_min": round(waste),
            "waste_pct": round(100 * waste / total, 1) if total else None,
            "by_reason": {k: round(v) for k, v in by.items()}}


def main():
    here = os.path.dirname(os.path.realpath(__file__))
    agent_home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or os.path.expanduser("~/.zenoforge")
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", default=os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR") or (
        os.path.join(here.split("/autopi-versions/", 1)[0], "autopi") if "/autopi-versions/" in here else here))
    ap.add_argument("--hours", type=float, default=5)
    ap.add_argument("--fixture")
    ap.add_argument("--audit", default=os.path.join(agent_home, "logs", "actions-run-cancellations.jsonl"))
    ap.add_argument("--now")
    ap.add_argument("--repo", help="OWNER/NAME; default: the repo of the current directory")
    args = ap.parse_args()
    if args.repo and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        ap.error("--repo must be OWNER/NAME")
    # gh api has no -R, so the repo goes into the path; the default keeps gh's {owner}/{repo} from cwd.
    base = f"repos/{args.repo}" if args.repo else "repos/{owner}/{repo}"
    a = args.runtime
    now = ts(args.now) if args.now else datetime.now(timezone.utc)
    since = now - timedelta(hours=args.hours)
    fixture = json.load(open(args.fixture)) if args.fixture else None
    cache_path = os.path.join(a, "ci-spend-cache.json")
    try:
        cache = json.load(open(cache_path))
    except (OSError, ValueError):
        cache = {}

    if fixture:
        raw = fixture["runs"]
    else:
        pages = gh_json(f"{base}/actions/runs?per_page=100&created=>={since:%Y-%m-%dT%H:%M:%SZ}")
        raw = [r for page in pages for r in page.get("workflow_runs", [])]
    runs = sorted(({"id": r["id"], "name": r.get("name") or "", "event": r.get("event") or "",
                    "branch": r.get("head_branch") or "", "head": r.get("head_sha") or "",
                    "created": r.get("created_at") or "", "status": r.get("status"),
                    "skip_ci": ((r.get("head_commit") or {}).get("message") or "").startswith("[skip ci]")}
                   for r in raw), key=lambda r: r["created"], reverse=True)
    todo = [r for r in runs if r["status"] == "completed" and str(r["id"]) not in cache]
    if fixture:
        for r in todo:
            key = str(r["id"])
            cache[key] = {"created": r["created"], "jobs": job_minutes(fixture["jobs"].get(key, []))}
    else:
        cache.update(fetch_job_minutes(todo, base))
    keep = now - timedelta(hours=max(24, args.hours))
    cache = {k: v for k, v in cache.items() if (ts(v.get("created")) or now) >= keep}

    units = ledger_history.load_units(a)
    minutes = {k: v["jobs"] for k, v in cache.items()}
    doc = classify(runs, minutes, approved_heads(units))
    audit = read_cancel_audit(args.audit, os.environ.get("ZF_REPO", ""))
    if audit is not None:
        doc["cancel_audit_min_by_reason"] = cancel_audit_minutes(
            runs, minutes, audit, since, now, os.environ.get("ZF_REPO", ""))
    doc.update({"sampled_at": f"{now:%Y-%m-%dT%H:%M:%SZ}", "window_hours": args.hours, "runs": len(runs)})
    outputs = [(cache_path, cache), (os.path.join(a, "ci-spend.json"), doc)]
    # PR sizes for node_health's rework-by-size table (bigger PRs need more repair rounds).
    size_path = os.path.join(a, "pr-sizes.json")
    if fixture:
        prs = fixture.get("prs")
        if prs is not None:
            sizes = {"lines": {}, "nontest_added": {}}
            for p in prs:
                number = str(p["number"])
                additions, deletions = p.get("additions"), p.get("deletions")
                if type(additions) is int and type(deletions) is int:
                    sizes["lines"][number] = additions + deletions
                files = p.get("files")
                if isinstance(files, list):
                    value = _nontest_added(additions, len(files), files[:100])
                    if value is not None:
                        sizes["nontest_added"][number] = value
        else:
            sizes = None
    else:
        try:
            previous = json.load(open(size_path))
        except (OSError, ValueError):
            previous = {}
        sizes = gh_pr_sizes(units, now, previous, args.repo)
    if sizes is not None:
        outputs.append((size_path, {"sampled_at": doc["sampled_at"], **sizes}))
    for path, value in outputs:
        with open(path + ".tmp", "w") as out:
            json.dump(value, out)
        os.replace(path + ".tmp", path)
    print(f"ci spend {doc['sampled_at']} window={args.hours:g}h total={doc['total_min']}min "
          f"waste={doc['waste_min']}min ({doc['waste_pct']}%) {doc['by_reason']}")
    rows = breakdown(runs, minutes)
    for (conclusion, branch, name), m in rows[:BREAKDOWN_ROWS]:
        print(f"  {conclusion} {branch} {name} {round(m)}min")
    if len(rows) > BREAKDOWN_ROWS:
        print(f"  ... {len(rows) - BREAKDOWN_ROWS} more rows")


if __name__ == "__main__":
    main()
