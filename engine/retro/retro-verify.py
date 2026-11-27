#!/usr/bin/env python3
"""Verify merged retro changes against equal session windows."""
import datetime
import glob
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mac-autopilot"))
import gh_caller
import retro

WINDOW = 10
# A change whose merged PR cannot be found after this long is surfaced every run, not silently skipped.
STALE_BOUND = datetime.timedelta(days=14)


def finished_sessions(root):
    sessions = []
    for directory in glob.glob(os.path.join(root, "luna", "*")):
        key = os.path.basename(directory)
        rc = os.path.join(directory, "rc")
        if key.startswith("retro-") or not os.path.isfile(rc):
            continue
        sessions.append((os.path.getmtime(rc), key))
    sessions.sort()
    return sessions


def session_windows(root, merged_at):
    timestamp = datetime.datetime.fromisoformat(merged_at.replace("Z", "+00:00")).timestamp()
    sessions = finished_sessions(root)
    before = [key for ended, key in sessions if ended < timestamp][-WINDOW:]
    after = [key for ended, key in sessions if ended > timestamp][:WINDOW]
    if len(before) != WINDOW or len(after) != WINDOW:
        return None
    for key in before + after:
        if not os.path.isfile(os.path.join(root, "luna", key, "events.jsonl")):
            return None
    return before, after


def count_category(root, out_dir, category, session_keys, merged_at, before):
    timestamp = datetime.datetime.fromisoformat(merged_at.replace("Z", "+00:00")).timestamp()
    wanted = set(session_keys)
    covered = set()
    events = set()
    for keys_path in glob.glob(os.path.join(out_dir, "*.keys")):
        candidates_path = os.path.splitext(keys_path)[0] + ".candidates.json"
        if not os.path.isfile(candidates_path):
            continue
        run_at = os.path.getmtime(keys_path)
        if (before and run_at >= timestamp) or (not before and run_at <= timestamp):
            continue
        with open(keys_path, encoding="utf-8") as keys_file:
            keys = {line.strip() for line in keys_file if line.strip()}
        covered.update(keys & wanted)
        if not keys & wanted:
            continue
        with open(candidates_path, encoding="utf-8") as candidates_file:
            document = json.load(candidates_file)
        # Reuse retro.py's candidate validation and event-position rule.
        kept = retro.filter_candidates(root, keys, document)["candidates"]
        events.update(
            (candidate["session_key"], candidate["event_line"])
            for candidate in kept
            if candidate["category"] == category and candidate["session_key"] in wanted
        )
    return len(events) if covered == wanted else None


def merged_at(repo, issue):
    result = gh_caller.run_gh(
        ["gh", "issue", "view", str(issue), "--repo", repo,
         "--json", "closedByPullRequestsReferences"],
        check=True, capture_output=True, text=True,
    )
    document = json.loads(result.stdout)
    references = document.get("closedByPullRequestsReferences", [])
    times = [reference["mergedAt"] for reference in references if reference.get("mergedAt")]
    if times:
        return max(times)
    # Retro implementation PRs say "Refs #N" and do not close the issue, so they never
    # appear in closedByPullRequestsReferences. Search merged PR bodies the same way
    # engine/factory/feeder.sh and issue-pipeline.sh search open ones.
    result = gh_caller.run_gh(
        ["gh", "pr", "list", "--repo", repo, "--state", "merged",
         "--search", f'"Refs #{issue}" in:body', "--json", "mergedAt"],
        check=True, capture_output=True, text=True,
    )
    pulls = json.loads(result.stdout)
    times = [pull["mergedAt"] for pull in pulls if pull.get("mergedAt")]
    return max(times) if times else None


def warn_stale_change(change):
    filed_at = change.get("filed_at")
    if not filed_at:
        return
    try:
        filed = datetime.datetime.fromisoformat(filed_at.replace("Z", "+00:00"))
    except ValueError:
        return
    if filed.tzinfo is None:
        filed = filed.replace(tzinfo=datetime.timezone.utc)
    if datetime.datetime.now(datetime.timezone.utc) - filed > STALE_BOUND:
        print(f"retro-verify: issue #{change.get('issue')} ({change.get('category')}, "
              f"class {change.get('class')}) filed {filed_at} still has no merged PR "
              f"after {STALE_BOUND.days} days")


def issue_comment(repo, issue, body):
    fd, body_path = tempfile.mkstemp(prefix="retro-verify-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as body_file:
            body_file.write(body)
        gh_caller.run_gh(
            ["gh", "issue", "comment", str(issue), "--repo", repo, "--body-file", body_path],
            check=True,
        )
    finally:
        os.unlink(body_path)


def change_lineage_ids(change):
    ids = {value for value in (change.get("lineage_id"), change.get("class"), change.get("lesson"))
           if isinstance(value, str) and value}
    issue = change.get("issue")
    if isinstance(issue, int) and not isinstance(issue, bool) and issue > 0:
        ids.add(f"issue:{issue}")
    return ids


def descendants(state, change):
    known = change_lineage_ids(change)
    found = []
    included = {id(change)}
    updated = True
    while updated:
        updated = False
        for candidate in state["changes"]:
            if id(candidate) in included or not (set(candidate.get("derived_from", [])) & known):
                continue
            found.append(candidate)
            included.add(id(candidate))
            known.update(change_lineage_ids(candidate))
            updated = True
    return found


def file_retract_issue(engine, change, children):
    descendant_ids = [
        f"#{child['issue']} ({child.get('lineage_id') or child.get('class') or child.get('lesson')})"
        if isinstance(child.get("issue"), int)
        else str(child.get("lineage_id") or child.get("class") or child.get("lesson"))
        for child in children
    ]
    body = (
        "## Retract or rewrite\n\n"
        f"Merged retro change #{change['issue']} targeted category {change['category']} "
        f"(class {change['class']}) at {change['merged_at']}.\n\n"
        f"Descendants: {', '.join(descendant_ids) if descendant_ids else 'none recorded'}.\n\n"
        f"The same candidate rule found {change['before_count']} events in {len(change['before_sessions'])} "
        f"sessions before the merge and {change['after_count']} events in {len(change['after_sessions'])} "
        "sessions after it. The event count did not drop; retract or rewrite the change.\n"
    )
    fd, body_path = tempfile.mkstemp(prefix="retro-verify-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as body_file:
            body_file.write(body)
        env = os.environ.copy()
        env["ZF_REPO_DIR"] = os.path.abspath(os.path.join(engine, ".."))
        env["ZF_ENGINE_DIR"] = engine
        env["ZF_REPO_DIR"] = os.path.abspath(os.path.join(engine, ".."))
        subprocess.run(
            ["bash", os.path.join(engine, "pipeline-issue-upsert.sh"),
             "--lane", "product", "--class", change["class"],
             "--title", f"Retro: retract or rewrite {change['category']} change",
             "--body-file", body_path],
            check=True, env=env,
        )
    finally:
        os.unlink(body_path)


def verify_change(root, out_dir, repo, engine, state, change):
    if not change.get("merged_at"):
        merge_time = merged_at(repo, change["issue"])
        if not merge_time:
            warn_stale_change(change)
            return
        change["merged_at"] = merge_time
        retro.write_verify_state(out_dir, state)

    windows = session_windows(root, change["merged_at"])
    if windows is None:
        print(f"retro-verify: waiting for {WINDOW} retained sessions around issue #{change['issue']}")
        return
    before_sessions, after_sessions = windows
    if "before_count" not in change:
        count = count_category(root, out_dir, change["category"], before_sessions,
                               change["merged_at"], before=True)
        if count is None:
            print(f"retro-verify: waiting for before-window candidates for issue #{change['issue']}")
            return
        change["before_sessions"] = before_sessions
        change["before_count"] = count
        retro.write_verify_state(out_dir, state)
    if "after_count" not in change:
        count = count_category(root, out_dir, change["category"], after_sessions,
                               change["merged_at"], before=False)
        if count is None:
            print(f"retro-verify: waiting for after-window candidates for issue #{change['issue']}")
            return
        change["after_sessions"] = after_sessions
        change["after_count"] = count
        retro.write_verify_state(out_dir, state)

    if not change.get("reported_at"):
        body = (
            "## Retro verification\n\n"
            f"Target category: {change['category']}\n\n"
            f"Merged at: {change['merged_at']}\n\n"
            f"Before: {change['before_count']} candidate events in {len(change['before_sessions'])} sessions.\n\n"
            f"After: {change['after_count']} candidate events in {len(change['after_sessions'])} sessions.\n"
        )
        issue_comment(repo, change["issue"], body)
        change["reported_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        retro.write_verify_state(out_dir, state)
    if change["after_count"] >= change["before_count"] and not change.get("retraction_filed_at"):
        file_retract_issue(engine, change, descendants(state, change))
        change["retraction_filed_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        retro.write_verify_state(out_dir, state)


def verify(root, out_dir, repo):
    engine = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    # A bad state file fails the run loudly (main returns 1); past this point a gh or
    # read error only ends this follow-up, so the run's other results stand.
    state = retro.read_verify_state(out_dir)
    for change in state["changes"]:
        if change.get("verifiable") is False:
            continue
        try:
            verify_change(root, out_dir, repo, engine, state, change)
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            print(f"retro-verify: issue #{change.get('issue')}: {exc}; retrying next run")
            return


def main(argv):
    if len(argv) != 3:
        print("usage: retro-verify.py <scratch-root> <retro-output-dir>", file=sys.stderr)
        return 2
    repo = os.environ.get("ZF_GH_REPO") or os.environ.get("ZF_REPO")
    if not repo:
        print("retro-verify.py: ZF_GH_REPO or ZF_REPO is required", file=sys.stderr)
        return 2
    try:
        verify(argv[1], argv[2], repo)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"retro-verify.py: verification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
