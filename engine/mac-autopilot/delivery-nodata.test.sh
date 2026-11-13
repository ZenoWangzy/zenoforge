#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -I - "$script_dir" "$test_env_root" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
from contextlib import redirect_stderr
import io
import json
import os
import subprocess
import sys
from unittest import mock

sys.path.insert(0, sys.argv[1])
import node_health as health

test_root = Path(sys.argv[2])

# Engine version directories are immutable and have no Git metadata of their own.
version_id = "engine-build-fixture"
version_source = test_root / "engine-versions" / version_id / "engine" / "mac-autopilot"
version_source.mkdir(parents=True)
real_run = health.subprocess.run

def unexpected_git(*args, **kwargs):
    raise AssertionError("source_commit tried git inside an immutable engine version")

health.subprocess.run = unexpected_git
try:
    assert health.source_commit(str(version_source)) == version_id
finally:
    health.subprocess.run = real_run

now = datetime(2026, 11, 13, 22, 24, 25, tzinfo=timezone.utc)
acceptances = [{"issue": 101, "sha": "b" * 40, "at": "2026-11-12T12:00:00Z"}]
timeout_bin = test_root / "timeout-gh-bin"
timeout_bin.mkdir()
timeout_gh = timeout_bin / "gh"
timeout_gh.write_text("#!/bin/sh\nexec python3 -c 'import time; time.sleep(2)'\n")
timeout_gh.chmod(0o755)
old_timeout = health.GH_DELIVERY_CENSUS_TIMEOUT
health.GH_DELIVERY_CENSUS_TIMEOUT = 0.05
unavailable = {}
stderr = io.StringIO()
with mock.patch.dict(os.environ, {"PATH": str(timeout_bin) + os.pathsep + os.environ["PATH"]}):
    with redirect_stderr(stderr):
        issue_rows, pr_rows = health.gh_delivery_rows(
            "example-maintainer/example-repo", now, units=[], release_events=acceptances,
            delivery_unavailable=unavailable)
health.GH_DELIVERY_CENSUS_TIMEOUT = old_timeout

assert issue_rows is None and pr_rows is None, (issue_rows, pr_rows)
timed_out_metrics = health.delivery_metrics(
    [], issue_rows, pr_rows, acceptances, [], now,
    "example-maintainer/example-repo", reverted_merge_times={}, delivery_unavailable=unavailable)
metric_id = "delivery.revert_rate_30d_pct"
value = timed_out_metrics["values"][metric_id]
assert value is None, timed_out_metrics
assert timed_out_metrics["details"]["accepted_units_30d"] == 1, timed_out_metrics
assert timed_out_metrics["details"]["lead_time_samples_30d"] is None, timed_out_metrics
timeout_reasons = {"issues": "timeout 0.05s", "prs": "timeout 0.05s"}
assert unavailable == timeout_reasons, unavailable
assert timed_out_metrics["details"]["delivery_unavailable"] == timeout_reasons, timed_out_metrics["details"]
assert json.loads(json.dumps({"delivery": timed_out_metrics["details"]}))["delivery"]["delivery_unavailable"] == timeout_reasons
assert stderr.getvalue().splitlines() == [
    "node_health: delivery input issues unavailable: timeout 0.05s",
    "node_health: delivery input prs unavailable: timeout 0.05s",
], stderr.getvalue()
assert health.status_of(value, *health.CRITERIA[metric_id][2:]) == "NO-DATA"

# A complete census with no matching revert markers is the distinct, measured 0.0 case.
merge_sha = "a" * 40
complete_inputs = (
    [{"id": "issue-101", "issue": 101, "pr": 201, "merge_sha": merge_sha,
      "history": [{"stage": "merged", "at": "2026-11-10T10:00:00Z"}]}],
    [{"number": 101, "createdAt": "2026-11-09T12:00:00Z"}],
    [{"number": 201, "mergedAt": "2026-11-10T10:00:00Z",
      "mergeCommit": {"oid": merge_sha}}],
    [{"issue": 101, "sha": "c" * 40, "at": "2026-11-10T12:00:00Z"}],
)
complete = health.delivery_metrics(
    *complete_inputs, [], now, "example-maintainer/example-repo", reverted_merge_times={})
assert complete["values"][metric_id] == 0.0, complete
assert health.status_of(complete["values"][metric_id], *health.CRITERIA[metric_id][2:]) == "OK"

# A failed Git revert census is different from a successful census with no revert markers.
unreadable_reverts = health.delivery_metrics(
    *complete_inputs, [], now, "example-maintainer/example-repo", reverted_merge_times=None)
assert unreadable_reverts["values"][metric_id] is None, unreadable_reverts
assert health.status_of(None, *health.CRITERIA[metric_id][2:]) == "NO-DATA"

real_run = health.subprocess.run
def timeout_git(command, *args, **kwargs):
    raise subprocess.TimeoutExpired(command, kwargs.get("timeout"))
health.subprocess.run = timeout_git
revert_unavailable = {}
revert_stderr = io.StringIO()
try:
    with redirect_stderr(revert_stderr):
        assert health.git_revert_times("missing-repo", delivery_unavailable=revert_unavailable) is None
finally:
    health.subprocess.run = real_run
revert_metrics = health.delivery_metrics(
    *complete_inputs, [], now, "example-maintainer/example-repo", reverted_merge_times=None,
    delivery_unavailable=revert_unavailable)
assert revert_unavailable == {"reverts": "timeout 20s"}, revert_unavailable
assert revert_metrics["details"]["delivery_unavailable"] == revert_unavailable, revert_metrics
assert revert_stderr.getvalue().splitlines() == [
    "node_health: delivery input reverts unavailable: timeout 20s"
], revert_stderr.getvalue()
print("delivery no-data causes: PASS")
PY
