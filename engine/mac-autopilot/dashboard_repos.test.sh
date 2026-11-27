#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -I - "$script_dir" <<'PY'
import sys
from datetime import datetime, timezone
sys.path.insert(0, sys.argv[1])
import dashboard_repos as D

primary = "ZenoWangzy/zenoforge"
other = "example-maintainer/other-repo"
factory = "example/factory-repo"
workers = [
    {"key": "zen-worker", "repo": primary},
    {"key": "other-worker", "repo": other},
    {"key": "zen-waiter", "repo": primary, "waiting": True, "waiter_ahead": "other-waiter"},
]
front = {
    "search_counts": {"issues_open": 21, "stages": {"ready-for-agent": 8}, "prs_open": 4, "prs_merged_24h": 3},
    "github": {"stale": False, "fetched_at": "2026-11-27T17:59:00Z"},
}
factory_live = {"fetched_at": "2026-11-27T17:59:30Z", "luna_workers": [{"key": "luna-2718", "started_at": "2026-11-27T17:58:00Z"}], "dispatch_decisions": [], "merge_lane_today": []}
loaded = []

def load_counts(repo):
    loaded.append(repo)
    return {}, {"issues_open": 55, "stages": {"ready-for-agent": 12}, "prs_open": 7, "prs_merged_24h": 1}, {"stale": False, "fetched_at": "2026-11-27T17:40:00Z", "freshness_window_s": 300}

now = datetime(2026, 11, 27, 18, 0, tzinfo=timezone.utc).timestamp()
sections = D.sections(f"{primary},{other},{factory}", primary, other, workers, front, load_counts, factory_live, now, factory_repo=factory)
assert [section["repo"] for section in sections] == [other, primary, factory], sections
assert sections[0]["counts"] == {"issues_open": 55, "ready_for_agent": 12, "prs_open": 7, "prs_merged_24h": 1}, sections
assert sections[1]["counts"] == {"issues_open": 21, "ready_for_agent": 8, "prs_open": 4, "prs_merged_24h": 3}, sections
assert sections[1]["fetched_at"] == "2026-11-27T17:59:00Z", sections
assert sections[1]["stale"] is False, sections
assert sections[1]["factory_live"] is None, sections
assert sections[2]["factory_live"] == factory_live, sections
assert sections[0]["fetched_at"] == "2026-11-27T17:40:00Z", sections
assert sections[0]["stale"] is True, sections
assert sections[0]["factory_live"] is None, sections
assert [worker["key"] for worker in sections[1]["workers"]] == ["zen-worker"], sections
assert [worker["key"] for worker in sections[1]["waiters"]] == ["zen-waiter"], sections
assert [worker["key"] for worker in sections[0]["workers"]] == ["other-worker"], sections
assert loaded == [other, factory], loaded
print("dashboard_repos.test.sh: PASS")
PY
node --input-type=module - "$script_dir/../focused-test-paths.mjs" <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { RELATED_TESTS, focusedTestPaths } = await import(pathToFileURL(process.argv[2]));
const repos = ['engine/mac-autopilot/dashboard-front.test.sh', 'engine/mac-autopilot/dashboard_repos.test.sh'];
assert.deepEqual(RELATED_TESTS.get('engine/mac-autopilot/dashboard_repos.py'), repos);
assert.deepEqual(focusedTestPaths(['engine/mac-autopilot/dashboard_repos.py'], new Set(repos)), repos);
assert.deepEqual(RELATED_TESTS.get('engine/mac-autopilot/repo_identity.py'), ['engine/mac-autopilot/live_workers.test.sh']);
console.log('dashboard_repos.test.sh: focused-test map PASS');
JS
