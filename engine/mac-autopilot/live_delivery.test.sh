#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -I - "$script_dir" "$test_env_root" <<'PY'
import json, os, pathlib, re, subprocess, sys, tempfile, time
from datetime import datetime, timedelta, timezone
sys.path.insert(0, sys.argv[1])
import live_delivery as live

root = pathlib.Path(sys.argv[2])
agent_home = root / "agent"
assert live.read_live_sha(agent_home) is None
sha = "a" * 40
record = live.write_live_sha(agent_home, sha, "post-deploy-success", at="2026-11-01T00:00:00Z")
assert record == {"sha": sha, "at": "2026-11-01T00:00:00Z", "source": "post-deploy-success"}, record
assert live.read_live_sha(agent_home) == record
(agent_home / "state" / "live-sha.json").write_text('{"sha":"bad","at":"now","source":"test"}')
assert live.read_live_sha(agent_home) is None

# Production's deployment record decides the live sha; live-sha.json only covers an unreadable one.
# release-train.json is never read: it keeps an older sha after a hand release.
(root / "runtime").mkdir()
(root / "runtime" / "release-train.json").write_text(json.dumps({"released_sha": "c" * 40, "released_at": "2026-10-23T01:57:55Z"}))
seen = []
def production(repo):
    seen.append(repo)
    return {"id": 7, "sha": "b" * 40, "at": datetime(2026, 10, 31, 3, 57, 58, tzinfo=timezone.utc)}
calls = []
real = live.health_metrics
live.health_metrics = lambda repo_root, record, now=None: calls.append(record) or {}
now_dt = datetime.now(timezone.utc)
live.collect_health_metrics(agent_home, now_dt, "o/r", production)
assert seen == ["o/r"] and calls[-1] == {"sha": "b" * 40, "at": "2026-10-31T03:57:58Z", "source": "production-deployments"}, calls
live.write_live_sha(agent_home, sha, "post-deploy-success", at="2026-11-01T00:00:00Z")
live.collect_health_metrics(agent_home, now_dt, "o/r", lambda repo: None)
assert calls[-1]["sha"] == sha, calls
live.collect_health_metrics(agent_home, now_dt, "o/r", lambda repo: {"sha": "bad", "at": now_dt})
assert calls[-1]["sha"] == sha, calls
live.health_metrics = real
(agent_home / "state" / "live-sha.json").write_text('{"sha":"bad","at":"now","source":"test"}')

repo = root / "repo"
repo.mkdir()
def git(*args, env=None):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, env=env)
git("init", "-q")
git("config", "user.name", "Fixture")
git("config", "user.email", "fixture@example.invalid")
source_root = pathlib.Path(live.__file__).resolve().parents[2]
scheduler = (source_root / "engine" / "mac-autopilot" / "scheduler.sh").read_text()
match = re.search(r"^NONPRODUCT_PATHS_RE='([^']+)'$", scheduler, re.MULTILINE)
assert match and match.group(1) == live.NONPRODUCT_PATHS_RE.pattern, match
assert not live.is_product_change(["docs/readme.md", "README.md", ".github/workflows/ci.yml", "scripts/tool.sh"])
assert live.is_product_change(["packages/app/source.py"])
def commit(path, contents, hours_ago=0):
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(contents)
    git("add", "--", path)
    stamp = (datetime.now(timezone.utc) - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%S%z")
    env = {**os.environ, "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp}
    git("commit", "-q", "-m", path, env=env)
    return git("rev-parse", "HEAD").stdout.strip()

base = commit("packages/app.txt", "base\n")
commit("docs/readme.md", "docs\n", 4)
commit("packages/feature.txt", "feature\n", 80)
head = commit("packages/new-feature.txt", "new\n", 12)
git("branch", "main", head)
git("checkout", "-q", "main")
git("checkout", "-q", "-b", "feature")
feature_sha = commit("packages/side-feature.txt", "side\n", 2)
git("checkout", "-q", "main")
commit("docs/after-branch.md", "later docs\n", 1)
git("merge", "--no-ff", "-q", "-m", "merge feature", "feature")
merge_sha = git("rev-parse", "HEAD").stdout.strip()
git("update-ref", "refs/remotes/origin/main", merge_sha)
metrics = live.health_metrics(repo, {"sha": base}, now=time.time())
assert metrics["delivery.merged_not_live"] == 3, metrics
assert metrics["delivery.oldest_merged_not_live_hours"] >= 79, metrics
first_parent = git("rev-list", "--first-parent", "--reverse", f"{base}..origin/main").stdout.splitlines()
assert feature_sha not in first_parent and merge_sha in first_parent, first_parent
missing = live.health_metrics(repo, None, now=0)
assert missing == {"delivery.merged_not_live": None, "delivery.oldest_merged_not_live_hours": None}, missing

calls = []
real_run = live.subprocess.run
def counted_run(*args, **kwargs):
    calls.append(args[0])
    return real_run(*args, **kwargs)
live.subprocess.run = counted_run
ancestors = live.ancestor_shas(repo, head)
assert {base, head}.issubset(ancestors), ancestors
assert sum(call[:4] == ["git", "-C", str(repo), "rev-list"] for call in calls) == 1, calls
print("live_delivery: PASS")
PY
echo 'live_delivery.test.sh: PASS'
