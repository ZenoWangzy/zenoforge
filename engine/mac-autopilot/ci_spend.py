#!/usr/bin/env python3
"""CI runner minutes, and the share that could not change a verdict (writes ci-spend.json for node_health).

Usage: ci_spend.py [--runtime DIR] [--hours N] [--fixture FILE]

Waste is runner time on work whose result nobody can use:
  cancelled            a job that held a runner and was then cancelled (L64: mostly our own cancellations)
  superseded_unapproved a PR run on a head that was replaced before anyone approved it
  nonproduct_postsubmit the product Postsubmit on a [skip ci] main commit: no product code changed (L65)
Completed runs never change, so their job minutes are cached (ci-spend-cache.json); each sample only
fetches jobs of runs that completed since the last one. --fixture reads {"runs": [...], "jobs": {id: [...]}}
instead of calling gh (tests); its optional "prs" list stands in for the PR sizes (pr-sizes.json).
"""
import argparse, importlib.util, json, os, subprocess
from datetime import datetime, timezone, timedelta
from node_health import LARGE_PR_WINDOW_DAYS, is_test_path, size_window_units

PR_EVENTS = ("pull_request", "pull_request_target")


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


def gh_pr_sizes(units, now, previous):
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
    client = snapshot.Snapshot(os.environ.get("ZF_REPO", ""))
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
    heads = set()
    for u in units:
        if u.get("approved_sha"):
            heads.add(u["approved_sha"])
        for h in u.get("history") or []:
            if h.get("stage") in ("review-approve", "supervisor-approve", "merged") and len(str(h.get("result", ""))) == 40:
                heads.add(h["result"])
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
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", default=os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR") or (
        os.path.join(here.split("/autopi-versions/", 1)[0], "autopi") if "/autopi-versions/" in here else here))
    ap.add_argument("--hours", type=float, default=5)
    ap.add_argument("--fixture")
    ap.add_argument("--now")
    args = ap.parse_args()
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
        pages = gh_json(f"repos/{{owner}}/{{repo}}/actions/runs?per_page=100&created=>={since:%Y-%m-%dT%H:%M:%SZ}")
        raw = [r for page in pages for r in page.get("workflow_runs", [])]
    runs = sorted(({"id": r["id"], "name": r.get("name") or "", "event": r.get("event") or "",
                    "branch": r.get("head_branch") or "", "head": r.get("head_sha") or "",
                    "created": r.get("created_at") or "", "status": r.get("status"),
                    "skip_ci": ((r.get("head_commit") or {}).get("message") or "").startswith("[skip ci]")}
                   for r in raw), key=lambda r: r["created"], reverse=True)
    for r in runs:
        key = str(r["id"])
        if r["status"] != "completed" or key in cache:
            continue
        jobs = (fixture["jobs"].get(key, []) if fixture else
                [j for page in gh_json(f"repos/{{owner}}/{{repo}}/actions/runs/{key}/jobs?filter=all&per_page=100")
                 for j in page.get("jobs", [])])
        cache[key] = {"created": r["created"], "jobs": job_minutes(jobs)}
    keep = now - timedelta(hours=max(24, args.hours))
    cache = {k: v for k, v in cache.items() if (ts(v.get("created")) or now) >= keep}

    units = json.load(open(os.path.join(a, "units.json")))["units"]
    doc = classify(runs, {k: v["jobs"] for k, v in cache.items()}, approved_heads(units))
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
        sizes = gh_pr_sizes(units, now, previous)
    if sizes is not None:
        outputs.append((size_path, {"sampled_at": doc["sampled_at"], **sizes}))
    for path, value in outputs:
        with open(path + ".tmp", "w") as out:
            json.dump(value, out)
        os.replace(path + ".tmp", path)
    print(f"ci spend {doc['sampled_at']} window={args.hours:g}h total={doc['total_min']}min "
          f"waste={doc['waste_min']}min ({doc['waste_pct']}%) {doc['by_reason']}")


if __name__ == "__main__":
    main()
