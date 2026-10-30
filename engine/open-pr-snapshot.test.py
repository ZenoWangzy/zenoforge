#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("snapshot", Path(__file__).with_name("open-pr-snapshot.py"))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)

rows = [{"number": n, "headRefName": f"agent/issue-{n}", "headRefOid": "a" * 40,
         "updatedAt": "2026-10-12T21:00:00Z", "title": "PR", "createdAt": "2026-10-01T00:00:00Z",
         "isDraft": False, "headRepository": {"name": "example", "owner": {"login": "owner"}}}
        for n in (3704, 3572, 3588)]
body_by_pr = {
    3704: "LIVE-FINAL source: #3677 `bb3a3b2a4d`\n\nRefs #3649. Registry maps the old 3677 row to this PR.",
    3572: "Summary\r\n\r\nRefs #3582\r\n",
    3588: "Summary\n\nRefs #3475, #3570, #3605",
}
calls = []
fault = None

def query(fields):
    calls.append(fields)
    if fault == "network":
        raise ValueError("Bad Gateway")
    if fields.startswith("pullRequests"):
        page = rows[:2] if 'after:' not in fields else rows[2:]
        page = [{key: value for key, value in row.items() if key in (
            "number", "headRefName", "headRefOid", "updatedAt", "title", "createdAt", "isDraft", "headRepository")}
                for row in page]
        if fault == "census-truncated": page = []
        return {"pullRequests": {"totalCount": len(rows), "nodes": page,
                "pageInfo": {"hasNextPage": len(rows) > 2 and 'after:' not in fields, "endCursor": "next"}}}
    result = {}
    for row in rows:
        if f"p{row['number']}:" not in fields:
            continue
        r = dict(row, state="OPEN", body=body_by_pr[row["number"]], changedFiles=1,
                 files={"nodes": [{"path": f"packages/{row['number']}/x.ts"}],
                        "pageInfo": {"hasNextPage": False, "endCursor": None}},
                 closingIssuesReferences={"nodes": [], "pageInfo": {"hasNextPage": False}})
        if "commits(last:1)" in fields:
            r["commits"] = {"nodes": [{"commit": {"oid": row["headRefOid"], "statusCheckRollup": {
                "contexts": {"nodes": [{"__typename": "CheckRun", "name": "build", "status": "COMPLETED",
                                        "conclusion": "SUCCESS"}], "pageInfo": {"hasNextPage": fault == "checks-truncated"}}}}}]}
            if fault == "checks-update":
                r["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"][0]["conclusion"] = "FAILURE"
        if "mergeable" in fields:
            r.update(mergeable="MERGEABLE", mergeStateStatus="CLEAN", baseRefOid="d" * 40)
        if fault == "file-pages":
            r["changedFiles"] = 101
            after = "after:" in fields
            r["files"] = {"nodes": [{"path": f"file-{i}.ts"} for i in (range(100,101) if after else range(100))],
                          "pageInfo": {"hasNextPage": not after, "endCursor": "files-next"}}
        if fault == "truncated": r["changedFiles"] = 2
        if fault == "race": r["headRefOid"] = "b" * 40
        if fault == "missing": del r["body"]
        result[f"p{row['number']}"] = r
    return result

with tempfile.TemporaryDirectory() as root:
    cache = Path(root) / "cache.json"
    assert snapshot.Snapshot("owner/example").request_budget == 120
    with patch.dict(os.environ, {"ZF_OPEN_PR_GRAPHQL_BUDGET": ""}):
        budget_client = snapshot.Snapshot("owner/example")
        assert budget_client.request_budget == 120
        good_response = subprocess.CompletedProcess(
            ["gh"], 0, '{"data":{"repository":{"probe":true}}}', "")
        with patch.object(snapshot.subprocess, "run", return_value=good_response) as request:
            for _ in range(120):
                assert budget_client.github("probe") == {"probe": True}
            try:
                budget_client.github("secondProbe")
                raise AssertionError("GraphQL request budget was not enforced")
            except ValueError as error:
                assert "budget exhausted (120/120)" in str(error)
            assert request.call_count == 120, "the 121st query must not issue a request"

    client = snapshot.Snapshot("owner/example", cache, query=query, page_size=2)
    github_client = snapshot.Snapshot("owner/example")
    for stdout, kind in (("[]", "list"), ("null", "null"), ('"bad"', "str"),
                         ("0", "int"), ("false", "bool")):
        with patch.object(snapshot.subprocess, "run",
                          return_value=subprocess.CompletedProcess(["gh"], 0, stdout, "")):
            try:
                github_client.github("pullRequests { nodes { number } }")
                raise AssertionError(f"{kind} GraphQL response admitted")
            except ValueError as error:
                assert "invalid GraphQL response" in str(error)
                assert f"got {kind}" in str(error)
    with patch.object(snapshot.subprocess, "run", return_value=subprocess.CompletedProcess(
        ["gh"], 0, '{"data":{"repository":{"pullRequests":{}}}}', "")):
        assert github_client.github("pullRequests { nodes { number } }") == {"pullRequests": {}}
    with patch.object(snapshot.subprocess, "run", return_value=subprocess.CompletedProcess(
        ["gh"], 0, '{"errors":[{"message":"denied"}],"data":null}', "")):
        try:
            github_client.github("pullRequests { nodes { number } }")
            raise AssertionError("GraphQL errors admitted")
        except ValueError as error:
            assert str(error) == "denied"
    first = client.read()
    assert first[0]["linkedIssues"] == [3649], "only #3704's explicit Refs directive owns recovery"
    assert first[1]["linkedIssues"] == [3582], "CRLF-terminated Refs #N remains associated without a closing keyword"
    assert first[2]["linkedIssues"] == [3475, 3570, 3605], "multiple Refs stay explicit and ordered"
    for unsupported in (
        "Refs #3649 and #3650",
        "Refs #3649 — explanation",
        "Refs #3649 #3650",
        "Refs: #3649",
    ):
        assert snapshot.linked_issue_numbers(unsupported, []) == [], f"unsupported Refs syntax admitted: {unsupported}"
    detail_calls = len([q for q in calls if "body" in q])
    assert len(first) == 3 and detail_calls == 1
    client.read()
    client.read()
    assert len([q for q in calls if "body" in q]) == detail_calls, "unchanged ticks repeat details"
    rows[0]["headRefOid"] = "c" * 40
    client.read()
    assert len([q for q in calls if "body" in q]) == detail_calls + 1
    rows[1]["updatedAt"] = "2026-10-12T21:01:00Z"
    client.read()
    assert len([q for q in calls if "body" in q]) == detail_calls + 2
    rows.pop()
    client.read()
    assert len(json.loads(cache.read_text())["details"]) == 2
    for version, fault in enumerate(("network", "truncated", "race", "missing", "census-truncated"), 2):
        rows[0]["updatedAt"] = f"2026-10-12T21:{version:02d}:00Z"
        try:
            client.read()
            raise AssertionError(f"{fault} admitted snapshot")
        except ValueError:
            pass
    fault = None
    cache.write_text("broken")
    assert len(client.read()) == 2
    assert snapshot.Snapshot("other/example", cache, query=query).read()
    assert json.loads(cache.read_text())["repo"] == "other/example"
    client.read()
    cached = json.loads(cache.read_text())
    del next(iter(cached["details"].values()))["body"]
    cache.write_text(json.dumps(cached))
    client.read()
    fault = "file-pages"
    rows[0]["updatedAt"] = "2026-10-12T22:01:00Z"
    assert len(client.read()[0]["files"]) == 101
    fault = None
    before = len(calls)
    client.read(checks=True)
    client.read(checks=True)
    assert len([q for q in calls[before:] if "commits(last:1)" in q]) == 2, "CI checks must stay fresh"
    assert not any("mergeable" in q for q in calls), "census fetched mergeability"
    detail_count = len([q for q in calls if "body" in q])
    fault = "checks-update"
    updated = client.read(checks=True)
    assert updated[0]["statusCheckRollup"][0]["conclusion"] == "FAILURE"
    assert updated[0]["checksHeadRefOid"] == updated[0]["headRefOid"]
    assert len([q for q in calls if "body" in q]) == detail_count
    fault = None
    assert client.mergeability(client.read())[0]["mergeable"] == "MERGEABLE"
    fault = "checks-truncated"
    try:
        client.read(checks=True)
        raise AssertionError("truncated checks were accepted")
    except ValueError:
        pass
print("ok - pagination, unchanged ticks, identity/body invalidation, removal, corruption and failures")
print("ok - 101 files paginate completely; checks refresh unchanged PRs; mergeability only at gate")
print("ok - non-object GraphQL responses fail with diagnostics; valid objects pass and GraphQL errors fail closed")
