#!/usr/bin/env python3
"""Fresh PR census, carried-over complete details. No unknown-as-empty output."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

IDENTITY = "number headRefOid updatedAt"
PAGE_INFO = "pageInfo { hasNextPage endCursor }"
DEFAULT_GRAPHQL_REQUEST_BUDGET = 120
METADATA = IDENTITY + " headRefName title createdAt isDraft headRepository { name owner { login } }"
DETAILS = (IDENTITY + " state body changedFiles files(first:100) { nodes { path } " + PAGE_INFO
           + " } closingIssuesReferences(first:100) { nodes { number } " + PAGE_INFO + " }")
CHECKS = """commits(last:1) { nodes { commit { oid statusCheckRollup { contexts(first:100) {
  nodes { __typename ... on CheckRun { name status conclusion startedAt completedAt detailsUrl }
    ... on StatusContext { context state createdAt targetUrl } } pageInfo { hasNextPage }
} } } } }"""
REFS_DIRECTIVE = re.compile(
    r"^[ \t]*Refs[ \t]+(#[1-9][0-9]*(?:[ \t]*,[ \t]*#[1-9][0-9]*)*)(?:[ \t]*[.;].*)?[ \t\r]*$",
    re.IGNORECASE | re.MULTILINE,
)
ISSUE_NUMBER = re.compile(r"#([1-9][0-9]*)")


def linked_issue_numbers(body, closing_references):
    """Preserve the product's non-closing `Refs #N` links for owner recovery."""
    numbers = []
    for link in closing_references:
        number = link["number"]
        if number not in numbers:
            numbers.append(number)
    for directive in REFS_DIRECTIVE.finditer(body):
        for match in ISSUE_NUMBER.finditer(directive.group(1)):
            number = int(match.group(1))
            if number not in numbers:
                numbers.append(number)
    return numbers


def connection(value):
    if not isinstance(value, dict) or not isinstance(value.get("nodes"), list):
        raise ValueError("missing connection nodes")
    page = value.get("pageInfo", {})
    if type(page.get("hasNextPage")) is not bool:
        raise ValueError("missing pagination evidence")
    if page["hasNextPage"] and not isinstance(page.get("endCursor"), str):
        raise ValueError("missing next cursor")
    return value["nodes"], page


class Snapshot:
    def __init__(self, repo, cache=None, query=None, page_size=100):
        self.repo, self.cache, self.page_size = repo, cache, page_size
        self.query = query or self.github
        configured_budget = os.environ.get("ZF_OPEN_PR_GRAPHQL_BUDGET", "")
        self.request_budget = int(configured_budget) if configured_budget.isdigit() and int(configured_budget) > 0 else DEFAULT_GRAPHQL_REQUEST_BUDGET
        self.request_count = 0

    def github(self, fields):
        if self.request_count >= self.request_budget:
            error = f"GraphQL request budget exhausted ({self.request_count}/{self.request_budget})"
            raise ValueError(error)
        owner, name = self.repo.split("/", 1)
        query = "query { repository(owner:" + json.dumps(owner) + ",name:" + json.dumps(name) + ") { " + fields + " } }"
        self.request_count += 1
        try:
            result = subprocess.run(["gh", "api", "graphql", "-f", "query=" + query],
                                    capture_output=True, text=True, timeout=20)
        except subprocess.TimeoutExpired:
            raise
        if result.returncode:
            message = result.stderr.strip() or "GitHub query failed"
            raise ValueError(message)
        try:
            response = json.loads(result.stdout)
        except ValueError as error:
            raise ValueError("invalid GraphQL JSON response") from error
        if not isinstance(response, dict):
            kind = "null" if response is None else type(response).__name__
            raise ValueError(f"invalid GraphQL response: expected object, got {kind}")
        if response.get("errors"):
            messages = "; ".join(str(item.get("message", "GraphQL error")) for item in response["errors"] if isinstance(item, dict))
            message = messages or "GraphQL errors"
            raise ValueError(message)
        data = response.get("data")
        if not isinstance(data, dict) or not isinstance(data.get("repository"), dict):
            raise ValueError("missing GraphQL repository")
        return data["repository"]

    def key(self, row):
        if (type(row.get("number")) is not int or row["number"] <= 0
                or not isinstance(row.get("headRefOid"), str) or len(row["headRefOid"]) != 40
                or any(char not in "0123456789abcdef" for char in row["headRefOid"])
                or not isinstance(row.get("updatedAt"), str) or not row["updatedAt"]):
            raise ValueError("missing PR identity")
        return json.dumps([self.repo, row["number"], row["headRefOid"], row["updatedAt"]])

    def save(self, details):
        fd, tmp = tempfile.mkstemp(prefix=".pr-details-", dir=self.cache.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump({"repo": self.repo, "details": details}, stream)
            os.replace(tmp, self.cache)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def batch(self, rows, fields, head_only=False, batch_size=20):
        # ponytail: 20 PRs per detail query; tune only if measured query latency changes.
        for start in range(0, len(rows), batch_size):
            chunk = rows[start:start + batch_size]
            result = self.query(" ".join(f'p{row["number"]}:pullRequest(number:{row["number"]}) {{ {fields} }}' for row in chunk))
            if set(result) != {f'p{row["number"]}' for row in chunk}:
                raise ValueError("incomplete PR batch")
            for row in chunk:
                detail = result[f'p{row["number"]}']
                if not isinstance(detail, dict):
                    raise ValueError("missing PR detail")
                detail_key, row_key = self.key(detail), self.key(row)
                if ((detail["number"], detail["headRefOid"]) != (row["number"], row["headRefOid"])
                        or (not head_only and detail_key != row_key)):
                    raise ValueError(f'PR #{row["number"]} changed during snapshot')
                yield row, detail

    def detail(self, row, value):
        if value.get("state") != "OPEN" or not isinstance(value.get("body"), str):
            raise ValueError("missing body or PR closed during snapshot")
        files, page = connection(value.get("files"))
        cursors = set()
        while page["hasNextPage"]:
            cursor = page["endCursor"]
            if cursor in cursors:
                raise ValueError("repeated files cursor")
            cursors.add(cursor)
            fields = IDENTITY + " state files(first:100,after:" + json.dumps(cursor) + ") { nodes { path } " + PAGE_INFO + " }"
            _, next_value = next(self.batch([row], fields))
            if next_value.get("state") != "OPEN":
                raise ValueError("PR closed during files pagination")
            nodes, page = connection(next_value.get("files"))
            files += nodes
        count = value.get("changedFiles")
        if (type(count) is not int or count != len(files)
                or any(not isinstance(f, dict) or not isinstance(f.get("path"), str) or not f["path"] for f in files)
                or len({f["path"] for f in files}) != count):
            raise ValueError("incomplete changed files")
        links, page = connection(value.get("closingIssuesReferences"))
        if page["hasNextPage"] or any(not isinstance(link, dict) or type(link.get("number")) is not int or link["number"] <= 0 for link in links):
            raise ValueError("incomplete closing references")
        return {"body": value["body"], "files": files, "changedFiles": count, "closingIssuesReferences": links}

    def read(self, checks=False):
        rows, cursors, cursor, total = [], set(), None, None
        while True:
            after = ",after:" + json.dumps(cursor) if cursor else ""
            fields = f"pullRequests(states:OPEN,first:{self.page_size}{after},orderBy:{{field:CREATED_AT,direction:ASC}}) {{ totalCount nodes {{ {METADATA} }} {PAGE_INFO} }}"
            result = self.query(fields).get("pullRequests")
            nodes, page = connection(result)
            if type(result.get("totalCount")) is not int or (total is not None and total != result["totalCount"]):
                raise ValueError("PR census changed during pagination")
            total = result["totalCount"]
            rows += nodes
            if len(rows) >= 1000:
                raise ValueError("PR census reached 1000-item bound")
            if not page["hasNextPage"]:
                break
            cursor = page["endCursor"]
            if cursor in cursors or not nodes:
                raise ValueError("PR census pagination truncated")
            cursors.add(cursor)
        if len(rows) != total or len({self.key(row) for row in rows}) != total or len({row["number"] for row in rows}) != total:
            raise ValueError("incomplete PR census")
        if any(not isinstance(row.get("headRefName"), str) or type(row.get("isDraft")) is not bool for row in rows):
            raise ValueError("missing PR metadata")
        try:
            old = json.loads(self.cache.read_text())
            details = old["details"] if old["repo"] == self.repo and isinstance(old["details"], dict) else {}
        except (OSError, ValueError, KeyError, TypeError):
            details = {}
        keys = {self.key(row) for row in rows}
        details = {key: value for key, value in details.items() if key in keys
                   and isinstance(value, dict) and isinstance(value.get("body"), str)
                   and isinstance(value.get("files"), list)
                   and type(value.get("changedFiles")) is int and value["changedFiles"] == len(value["files"])
                   and all(isinstance(f, dict) and isinstance(f.get("path"), str) and f["path"] for f in value["files"])
                   and len({f["path"] for f in value["files"]}) == value["changedFiles"]
                   and isinstance(value.get("closingIssuesReferences"), list)
                   and all(isinstance(link, dict) and type(link.get("number")) is int and link["number"] > 0
                           for link in value["closingIssuesReferences"])}
        # Prune closed/changed identities even if a later details read fails.
        self.save(details)
        missing = [row for row in rows if self.key(row) not in details]
        for row, value in self.batch(missing, DETAILS):
            details[self.key(row)] = self.detail(row, value)
        self.save(details)
        for row in rows:
            row.update(details[self.key(row)])
            row["linkedIssues"] = linked_issue_numbers(row["body"], row["closingIssuesReferences"])
        if checks:
            for row, value in self.batch([row for row in rows if not row["isDraft"]], IDENTITY + " state " + CHECKS, head_only=True):
                if value.get("state") != "OPEN":
                    raise ValueError("PR closed during checks read")
                commits = value.get("commits", {}).get("nodes", [])
                if len(commits) != 1 or commits[0].get("commit", {}).get("oid") != row["headRefOid"]:
                    raise ValueError("missing current-head checks")
                rollup = commits[0]["commit"].get("statusCheckRollup")
                if rollup is None:
                    row["statusCheckRollup"] = []
                else:
                    nodes, page = connection(rollup.get("contexts"))
                    if page["hasNextPage"]:
                        raise ValueError("truncated status checks")
                    if any(not isinstance(node, dict) or node.get("__typename") not in ("CheckRun", "StatusContext")
                           or (node["__typename"] == "CheckRun" and (not isinstance(node.get("name"), str)
                               or not isinstance(node.get("status"), str)))
                           or (node["__typename"] == "StatusContext" and (not isinstance(node.get("context"), str)
                               or not isinstance(node.get("state"), str))) for node in nodes):
                        raise ValueError("invalid status checks")
                    row["statusCheckRollup"] = nodes
                row["checksHeadRefOid"] = row["headRefOid"]
        return rows

    def mergeability(self, rows):
        for row, value in self.batch(rows, IDENTITY + " state baseRefOid mergeable mergeStateStatus", head_only=True, batch_size=100):
            if value.get("state") != "OPEN":
                raise ValueError("PR closed during mergeability read")
            if not isinstance(value.get("mergeable"), str) or not isinstance(value.get("mergeStateStatus"), str):
                raise ValueError("missing mergeability")
            row.update({key: value[key] for key in ("mergeable", "mergeStateStatus", "baseRefOid")})
        return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--checks", action="store_true")
    parser.add_argument("--mergeability", action="store_true")
    args = parser.parse_args()
    client = Snapshot(args.repo, args.cache)
    if args.mergeability:
        result = client.mergeability(json.load(sys.stdin))
    else:
        args.cache.parent.mkdir(parents=True, exist_ok=True)
        with args.cache.with_suffix(".lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = client.read(args.checks)
    json.dump(result, sys.stdout)
    print()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        message = re.sub(r"(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)", "[redacted]", str(error))
        message = re.sub(r"(Bearer\s+)[^\s]+", r"\1[redacted]", message, flags=re.IGNORECASE)
        print("open-pr-snapshot: " + message, file=sys.stderr)
        sys.exit(1)
