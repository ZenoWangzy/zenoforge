#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "mac-autopilot"))
from intake_laneless_health import ROADMAP_CONTAINER_LABELS


ISSUES_QUERY = """
query($owner:String!, $name:String!, $endCursor:String, $pageSize:Int!) {
  repository(owner:$owner, name:$name) {
    issues(first:$pageSize, after:$endCursor, states:[OPEN,CLOSED]) {
      nodes {
        number title body state parent { number }
        labels(first:30) { nodes { name } pageInfo { hasNextPage } }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"""
PULL_REQUESTS_QUERY = """
query($owner:String!, $name:String!, $endCursor:String, $pageSize:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequests(first:$pageSize, after:$endCursor, states:[OPEN,MERGED]) {
      nodes { number title body state mergedAt mergeCommit { oid } }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"""
WHY_HEADING = re.compile(r"^[ \t]{0,3}#{1,6}[ \t]+(?:why|problem|背景|为什么)[ \t]*#*[ \t]*$",
                         re.IGNORECASE | re.MULTILINE)
WHY_SETEXT_HEADING = re.compile(r"^[ \t]{0,3}(?:why|problem|背景|为什么)[ \t]*\n[ \t]{0,3}(?:=+|-+)[ \t]*$",
                                re.IGNORECASE | re.MULTILINE)
BODY_ISSUE_REF = re.compile(r"\b(?:refs|fixes|closes|part\s+of|slice\s+of)\s*:?\s+#([1-9][0-9]*)\b", re.IGNORECASE)
TITLE_ISSUE_REF = re.compile(r"\(#([1-9][0-9]*)\)")
REVERT_TITLE = re.compile(r'^\s*Revert\s+".*\(#([1-9][0-9]*)\)"\s*$', re.IGNORECASE)
SHA = re.compile(r"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")


class ReadFailed(Exception):
    pass


def parse_time(value):
    if not isinstance(value, str):
        raise ReadFailed("GitHub returned a missing timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ReadFailed("GitHub returned an invalid timestamp") from error
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def read_json(path):
    try:
        with Path(path).open(encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        raise ReadFailed(f"could not read {Path(path).name}") from error


def run_json(command, label, timeout=300):
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReadFailed(f"{label} timed out or could not start") from error
    if result.returncode != 0:
        raise ReadFailed(f"{label} failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ReadFailed(f"{label} returned invalid JSON") from error


def connection_rows(pages, connection_name, label):
    if not isinstance(pages, list) or not pages:
        raise ReadFailed(f"{label} pagination is empty or invalid")
    rows = []
    for index, page in enumerate(pages):
        try:
            if page.get("errors"):
                raise ValueError
            connection = page["data"]["repository"][connection_name]
            nodes = connection["nodes"]
            page_info = connection["pageInfo"]
            has_next = page_info["hasNextPage"]
        except (AttributeError, KeyError, TypeError, ValueError) as error:
            raise ReadFailed(f"{label} GraphQL response is incomplete") from error
        if not isinstance(nodes, list) or not isinstance(has_next, bool):
            raise ReadFailed(f"{label} GraphQL response is invalid")
        if has_next and (not isinstance(page_info.get("endCursor"), str) or not page_info["endCursor"]):
            raise ReadFailed(f"{label} pagination cursor is missing")
        if index < len(pages) - 1 and not has_next:
            raise ReadFailed(f"{label} pagination ended unexpectedly")
        if index == len(pages) - 1 and has_next:
            raise ReadFailed(f"{label} pagination is incomplete")
        rows.extend(nodes)
    return rows


def graphql_pages(repo, query, page_size, label):
    owner, name = repo.split("/", 1)
    return run_json([
        "gh", "api", "graphql", "--paginate", "--slurp",
        "-f", f"query={query}", "-F", f"owner={owner}", "-F", f"name={name}",
        "-F", f"pageSize={page_size}",
    ], label)


def valid_number(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def normalize_issues(rows, graphql=False):
    if not isinstance(rows, list):
        raise ReadFailed("issue list is invalid")
    issues = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or not valid_number(row.get("number")):
            raise ReadFailed("issue list contains an invalid issue")
        number = row["number"]
        if number in seen:
            raise ReadFailed("issue pagination contains a duplicate issue")
        seen.add(number)
        title = row.get("title")
        body = row.get("body")
        state = row.get("state")
        labels = row.get("labels")
        parent = row.get("parent")
        if not isinstance(title, str) or body is not None and not isinstance(body, str):
            raise ReadFailed("issue list contains invalid text")
        if state not in ("OPEN", "CLOSED"):
            raise ReadFailed("issue list contains an invalid state")
        if graphql:
            if not isinstance(labels, dict) or not isinstance(labels.get("nodes"), list):
                raise ReadFailed("issue labels are incomplete")
            if not isinstance(labels.get("pageInfo"), dict) or labels["pageInfo"].get("hasNextPage") is not False:
                raise ReadFailed("issue labels are truncated")
            label_rows = labels["nodes"]
        else:
            label_rows = labels
        if not isinstance(label_rows, list):
            raise ReadFailed("issue labels are invalid")
        label_names = []
        for label in label_rows:
            if graphql:
                label = label.get("name") if isinstance(label, dict) else None
            if not isinstance(label, str):
                raise ReadFailed("issue labels contain an invalid name")
            label_names.append(label)
        if parent is not None:
            if not isinstance(parent, dict) or not valid_number(parent.get("number")):
                raise ReadFailed("issue parent is invalid")
            parent = parent["number"]
        issues.append({
            "number": number,
            "title": title,
            "body": body or "",
            "state": state,
            "labels": set(label_names),
            "parent": parent,
        })
    return issues


def normalize_pull_requests(rows):
    if not isinstance(rows, list):
        raise ReadFailed("pull request list is invalid")
    prs = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or not valid_number(row.get("number")):
            raise ReadFailed("pull request list contains an invalid pull request")
        number = row["number"]
        if number in seen:
            raise ReadFailed("pull request pagination contains a duplicate pull request")
        seen.add(number)
        title = row.get("title")
        body = row.get("body")
        state = row.get("state")
        if not isinstance(title, str) or body is not None and not isinstance(body, str):
            raise ReadFailed("pull request list contains invalid text")
        if state not in ("OPEN", "MERGED"):
            raise ReadFailed("pull request list contains an invalid state")
        merged_at = parse_time(row.get("mergedAt")) if state == "MERGED" else None
        merge_commit = row.get("mergeCommit")
        if state == "MERGED":
            if not isinstance(merge_commit, dict) or not isinstance(merge_commit.get("oid"), str):
                raise ReadFailed("merged pull request has no merge commit")
            merge_commit = merge_commit["oid"]
            if not SHA.fullmatch(merge_commit):
                raise ReadFailed("merged pull request has an invalid merge commit")
        else:
            merge_commit = None
        prs.append({
            "number": number,
            "title": title,
            "body": body or "",
            "state": state,
            "merged_at": merged_at,
            "merge_commit": merge_commit,
        })
    return prs


def fetch_issues(repo):
    rows = connection_rows(graphql_pages(repo, ISSUES_QUERY, 20, "issue query"), "issues", "issue query")
    return normalize_issues(rows, graphql=True)


def fetch_pull_requests(repo):
    rows = connection_rows(graphql_pages(repo, PULL_REQUESTS_QUERY, 100, "pull request query"),
                           "pullRequests", "pull request query")
    return normalize_pull_requests(rows)


def fixture_rows(directory, filename):
    rows = read_json(Path(directory) / filename)
    if not isinstance(rows, list):
        raise ReadFailed(f"{filename} is not an array")
    return rows


def resolve_live_commit(git_dir, live_sha):
    if not SHA.fullmatch(live_sha):
        raise ReadFailed("live SHA is invalid")
    path = Path(git_dir)
    if not path.is_dir():
        raise ReadFailed("Git clone is unavailable")
    try:
        result = subprocess.run(["git", "-C", str(path), "rev-parse", "--verify", "--end-of-options",
                                 f"{live_sha}^{{commit}}"], capture_output=True, text=True, check=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReadFailed("live Git commit could not be read") from error
    if result.returncode != 0 or not SHA.fullmatch(result.stdout.strip()):
        raise ReadFailed("live Git commit could not be read")
    return result.stdout.strip().lower()


def commit_is_ancestor(git_dir, commit, live_commit, cache):
    commit = commit.lower()
    if commit in cache:
        return cache[commit]
    try:
        result = subprocess.run(["git", "-C", str(git_dir), "merge-base", "--is-ancestor", commit, live_commit],
                                capture_output=True, text=True, check=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReadFailed("Git ancestry read timed out or could not start") from error
    if result.returncode not in (0, 1):
        raise ReadFailed("Git ancestry read failed")
    cache[commit] = result.returncode == 0
    return cache[commit]


def issue_refs(pr):
    refs = {int(match) for match in BODY_ISSUE_REF.findall(pr["body"])}
    if not REVERT_TITLE.fullmatch(pr["title"]):
        refs.update(int(match) for match in TITLE_ISSUE_REF.findall(pr["title"]))
    return refs


def read_comments(repo, issue_number, merged_at, fixture_dir):
    if fixture_dir:
        rows = read_json(Path(fixture_dir) / "comments" / f"{issue_number}.json")
        if not isinstance(rows, list):
            raise ReadFailed("issue comment fixture is invalid")
    else:
        since = merged_at.isoformat(timespec="seconds").replace("+00:00", "Z")
        response = run_json([
            "gh", "api", "--paginate", "--slurp", "--method", "GET",
            f"repos/{repo}/issues/{issue_number}/comments", "-f", "per_page=100", "-f", f"since={since}",
        ], f"issue comments for #{issue_number}", timeout=120)
        if not isinstance(response, list) or any(not isinstance(page, list) for page in response):
            raise ReadFailed(f"issue comments for #{issue_number} are invalid")
        rows = [comment for page in response for comment in page]
    newer = False
    for row in rows:
        if not isinstance(row, dict):
            raise ReadFailed("issue comment list contains an invalid comment")
        if parse_time(row.get("created_at")) > merged_at:
            newer = True
    return newer


def has_why_in_ancestry(issue, issues_by_number):
    current = issue
    seen = set()
    while current is not None:
        number = current["number"]
        if number in seen:
            raise ReadFailed("issue parent tree contains a cycle")
        seen.add(number)
        if WHY_HEADING.search(current["body"]) or WHY_SETEXT_HEADING.search(current["body"]):
            return True
        parent_number = current["parent"]
        if parent_number is None:
            return False
        current = issues_by_number.get(parent_number)
        if current is None:
            raise ReadFailed("issue parent is missing from the complete issue list")
    return False


def finding_line(code, issue, detail=None):
    title = re.sub(r"[\x00-\x1f\x7f]+", " ", issue["title"]).strip()
    suffix = f": {detail}" if detail else (f": {title}" if title else "")
    return f"{code} #{issue['number']}{suffix}"


def analyze(issues, prs, git_dir, live_commit, repo, fixture_dir):
    issues_by_number = {issue["number"]: issue for issue in issues}
    direct_children = {}
    open_children = set()
    for issue in issues:
        parent = issue["parent"]
        if parent is not None:
            if parent not in issues_by_number:
                raise ReadFailed("issue parent is missing from the complete issue list")
            direct_children[parent] = direct_children.get(parent, 0) + 1
            if issue["state"] == "OPEN":
                open_children.add(parent)

    pr_by_number = {pr["number"]: pr for pr in prs}
    reverted = set()
    for pr in prs:
        match = REVERT_TITLE.fullmatch(pr["title"])
        if match and pr["state"] == "MERGED":
            original = pr_by_number.get(int(match.group(1)))
            if original and original["state"] == "MERGED" and pr["merged_at"] > original["merged_at"]:
                reverted.add(original["number"])

    merged_for_issue = {}
    open_for_issue = set()
    for pr in prs:
        refs = issue_refs(pr)
        if pr["state"] == "OPEN":
            open_for_issue.update(refs)
        elif pr["number"] not in reverted:
            for number in refs:
                merged_for_issue.setdefault(number, []).append(pr)

    ancestor_cache = {}
    findings = []
    for issue in issues:
        number = issue["number"]
        if issue["parent"] is None and "roadmap" not in issue["labels"]:
            findings.append((number, "NO-PARENT", finding_line("NO-PARENT", issue)))
        if issue["state"] == "OPEN" and not has_why_in_ancestry(issue, issues_by_number):
            findings.append((number, "NO-WHY", finding_line("NO-WHY", issue)))
        if direct_children.get(number, 0) >= 97:
            findings.append((number, "NEAR-LIMIT", finding_line(
                "NEAR-LIMIT", issue, f"{direct_children[number]} direct sub-issues")))
        if issue["state"] != "OPEN" or issue["labels"].intersection(ROADMAP_CONTAINER_LABELS) or number in open_children:
            continue
        related = merged_for_issue.get(number, [])
        if not related or number in open_for_issue:
            continue
        if not all(commit_is_ancestor(git_dir, pr["merge_commit"], live_commit, ancestor_cache) for pr in related):
            continue
        newest_merge = max(pr["merged_at"] for pr in related)
        if not read_comments(repo, number, newest_merge, fixture_dir):
            findings.append((number, "STATE-BEHIND", finding_line("STATE-BEHIND", issue)))
    return [line for _, _, line in sorted(findings)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--git-dir", required=True)
    parser.add_argument("--live-sha", required=True)
    parser.add_argument("--fixture")
    args = parser.parse_args()
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", args.repo):
        parser.error("--repo must be owner/name")
    try:
        live_commit = resolve_live_commit(args.git_dir, args.live_sha)
        if args.fixture:
            issues = normalize_issues(fixture_rows(args.fixture, "issues.json"))
            prs = normalize_pull_requests(fixture_rows(args.fixture, "pull-requests.json"))
        else:
            issues = fetch_issues(args.repo)
            prs = fetch_pull_requests(args.repo)
        findings = analyze(issues, prs, args.git_dir, live_commit, args.repo, args.fixture)
    except ReadFailed as error:
        print(f"roadmap-tree-check: read failed: {error}", file=sys.stderr)
        return 2
    for finding in findings:
        print(finding)
    print(f"roadmap-tree-check: findings={len(findings)}")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
