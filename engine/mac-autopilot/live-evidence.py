#!/usr/bin/env python3
"""Check merged engine PR evidence against the first live pin that carries it."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


PR_QUERY = (
    "query($q:String!,$after:String){search(query:$q,type:ISSUE,first:100,after:$after){"
    "pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number body mergedAt}}}}"
)
LIVE_LINE = re.compile(r"^\s*(?:[-*]\s*)?Live evidence:\s*(\S.*)\s*$", re.IGNORECASE)
PIN_LINE = re.compile(r"\bPINNED\s+([0-9a-f]{12,40})(?=\s|$)")
LOG_TIME = re.compile(r"^\[?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\]?")
LEGACY_PATTERNS = {926: "intake-priority: applied"}
WINDOW_SECONDS = 24 * 60 * 60
BOOTSTRAP_SECONDS = 30 * 24 * 60 * 60
KEEP_DONE_SECONDS = 14 * 24 * 60 * 60


class EvidenceUnavailable(RuntimeError):
    pass


def epoch(value):
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return int(parsed.timestamp())
        except ValueError:
            return None
    return None


def iso_time(value):
    return datetime.fromtimestamp(int(value), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as stream:
            value = json.load(stream)
    except FileNotFoundError:
        return default
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceUnavailable(f"could not read {Path(path).name}") from error
    return value


def live_pattern(body, number):
    if isinstance(body, str):
        for line in body.splitlines():
            match = LIVE_LINE.fullmatch(line)
            if match:
                pattern = match.group(1).strip()
                if len(pattern) <= 500 and not any(ord(ch) < 32 for ch in pattern):
                    return pattern
    return LEGACY_PATTERNS.get(number)


def gh_prs(repo, lower_bound):
    lower_date = iso_time(lower_bound)[:10]
    search = f"repo:{repo} is:pr is:merged base:main merged:>={lower_date}"
    after = None
    rows = []
    for _ in range(20):
        command = ["gh", "api", "graphql", "-f", f"query={PR_QUERY}", "-f", f"q={search}"]
        if after:
            command += ["-f", f"after={after}"]
        try:
            result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=15)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise EvidenceUnavailable("GitHub merged PR query timed out or could not start") from error
        if result.returncode != 0:
            raise EvidenceUnavailable("GitHub merged PR query failed")
        try:
            data = json.loads(result.stdout)
            search_result = data["data"]["search"]
            nodes = search_result["nodes"]
            page = search_result["pageInfo"]
            if not isinstance(nodes, list) or not isinstance(page, dict):
                raise ValueError
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            raise EvidenceUnavailable("GitHub merged PR query returned invalid data") from error
        rows.extend(node for node in nodes if isinstance(node, dict))
        if not page.get("hasNextPage"):
            return rows
        after = page.get("endCursor")
        if not isinstance(after, str) or not after:
            raise EvidenceUnavailable("GitHub merged PR pagination is incomplete")
    raise EvidenceUnavailable("GitHub merged PR query exceeded its page bound")


def journal_rows(since, until, unit=None):
    command = ["journalctl", "--user"]
    if unit:
        command += ["-u", unit]
    command += ["--since", iso_time(since), "--until", iso_time(until), "--no-pager", "-o", "json"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EvidenceUnavailable("user journal query timed out or could not start") from error
    if result.returncode != 0:
        raise EvidenceUnavailable("user journal query failed")
    rows = []
    for line in result.stdout.splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise EvidenceUnavailable("user journal returned invalid data") from error
        if isinstance(row, dict):
            rows.append(row)
    return rows


def fixture_rows(variable):
    path = os.environ.get(variable)
    if not path:
        return None
    value = read_json(path, [])
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        raise EvidenceUnavailable(f"{variable} must name a JSON array of objects")
    return value


def row_epoch(row):
    if "timestamp" in row:
        return epoch(row.get("timestamp"))
    raw = row.get("__REALTIME_TIMESTAMP")
    try:
        return int(raw) // 1_000_000
    except (TypeError, ValueError):
        return None


def pin_events(rows):
    events = []
    for row in rows:
        at = row_epoch(row)
        message = row.get("message", row.get("MESSAGE", ""))
        if at is None or not isinstance(message, str):
            continue
        match = PIN_LINE.search(message)
        if match:
            events.append({"at": at, "sha": match.group(1)})
    return sorted(events, key=lambda item: item["at"])


def active_engine_logs(runtime_dir, agent_home):
    paths = [Path(runtime_dir) / "scheduler.log", Path(runtime_dir) / "scheduler.log.1",
             Path(runtime_dir) / "bell.log"]
    for directory in (Path(runtime_dir) / "alerts", Path(agent_home) / "logs"):
        try:
            paths.extend(path for path in directory.iterdir() if path.is_file() and path.suffix in (".log", ".md"))
        except OSError:
            pass
    fixture = os.environ.get("ZF_LIVE_EVIDENCE_ENGINE_LOGS")
    if fixture:
        paths = [Path(path) for path in fixture.split(os.pathsep) if path]
    return list(dict.fromkeys(paths))


def line_epoch(line, fallback):
    match = LOG_TIME.match(line)
    return epoch(match.group(1)) if match else fallback


def matching_patterns(watches, journal, log_paths, now):
    matches = set()
    for row in journal:
        at = row_epoch(row)
        message = row.get("message", row.get("MESSAGE", ""))
        if at is None or not isinstance(message, str):
            continue
        for key, watch in watches.items():
            if watch["pin_at"] <= at <= min(now, watch["pin_at"] + WINDOW_SECONDS):
                if watch["pattern"] in message:
                    matches.add(key)

    if not watches:
        return matches
    start = min(item["pin_at"] for item in watches.values())
    end = min(now, max(item["pin_at"] + WINDOW_SECONDS for item in watches.values()))
    for path in log_paths:
        try:
            stat = path.stat()
            if stat.st_mtime < start or stat.st_size > 20 * 1024 * 1024:
                continue
            with path.open("r", encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    at = line_epoch(line, int(stat.st_mtime))
                    if at < start or at > end:
                        continue
                    for key, watch in watches.items():
                        if watch["pin_at"] <= at <= min(now, watch["pin_at"] + WINDOW_SECONDS):
                            if watch["pattern"] in line:
                                matches.add(key)
        except OSError:
            continue
    return matches


def write_state(path, state):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, separators=(",", ":"), sort_keys=True)
            stream.write("\n")
        os.replace(temporary, target)
    except OSError:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def scan(args):
    now = args.now if args.now is not None else int(datetime.now(timezone.utc).timestamp())
    state = read_json(args.state, {})
    if not isinstance(state, dict) or (state and state.get("schema") != 1):
        raise EvidenceUnavailable("live evidence state is invalid")
    if state.get("repo") not in (None, args.repo):
        state = {}
    first_scan = "last_merge_seen" not in state
    lower = int(state.get("last_merge_seen", now - BOOTSTRAP_SECONDS))
    prs = fixture_rows("ZF_LIVE_EVIDENCE_PR_FIXTURE")
    rows = prs if prs is not None else gh_prs(args.repo, max(0, lower - 1))
    tracked = state.get("prs", {})
    if not isinstance(tracked, dict):
        raise EvidenceUnavailable("live evidence PR state is invalid")
    for row in rows:
        try:
            number = int(row.get("number"))
        except (TypeError, ValueError):
            continue
        merged = epoch(row.get("mergedAt"))
        if number < 1 or merged is None or merged > now or (not first_scan and merged < lower - 1):
            continue
        pattern = live_pattern(row.get("body"), number)
        if not pattern:
            continue
        key = str(number)
        tracked.setdefault(key, {"number": number, "merged_at": merged, "pattern": pattern, "status": "awaiting-pin"})

    unpinned = [item for item in tracked.values() if item.get("status") == "awaiting-pin"]
    if unpinned:
        since = min(item["merged_at"] for item in unpinned)
        pin_rows = fixture_rows("ZF_LIVE_EVIDENCE_PIN_FIXTURE")
        if pin_rows is None:
            pin_rows = journal_rows(since, now, "zf-auto-pin.service")
        events = [event for event in pin_events(pin_rows) if event["at"] >= since]
        for item in unpinned:
            event = next((pin for pin in events if pin["at"] >= item["merged_at"]), None)
            if event:
                item["pin_at"] = event["at"]
                item["pin_sha"] = event["sha"]
                item["status"] = "watching"

    watches = {
        key: item for key, item in tracked.items()
        if item.get("status") == "watching" and int(item.get("pin_at", now + 1)) <= now
    }
    matched = set()
    if watches:
        start = min(item["pin_at"] for item in watches.values())
        end = min(now, max(item["pin_at"] + WINDOW_SECONDS for item in watches.values()))
        journal = fixture_rows("ZF_LIVE_EVIDENCE_JOURNAL_FIXTURE")
        if journal is None:
            journal = journal_rows(start, end)
        matched = matching_patterns(watches, journal, active_engine_logs(args.runtime_dir, args.agent_home), now)

    missing = []
    watching_count = 0
    for key, item in tracked.items():
        if item.get("status") != "watching":
            continue
        if key in matched:
            item["status"] = "matched"
        elif now >= item["pin_at"] + WINDOW_SECONDS:
            item["status"] = "missing"
            missing.append({"number": item["number"], "pattern": item["pattern"],
                            "pin_at": iso_time(item["pin_at"]), "pin_sha": item["pin_sha"]})
        else:
            watching_count += 1

    for key, item in list(tracked.items()):
        terminal_at = item.get("pin_at", item.get("merged_at", now))
        if item.get("status") in ("matched", "missing") and now - terminal_at > KEEP_DONE_SECONDS:
            del tracked[key]
    state = {"schema": 1, "repo": args.repo, "last_merge_seen": now, "prs": tracked}
    if not args.check_only:
        write_state(args.state, state)
    checked_count = sum(item.get("status") in ("matched", "missing") for item in tracked.values())
    matched_total = sum(item.get("status") == "matched" for item in tracked.values())
    missing_total = sum(item.get("status") == "missing" for item in tracked.values())
    print(json.dumps({"missing": missing, "watching": watching_count, "matched": matched_total,
                      "missing_count": missing_total, "checked": checked_count}, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scan", choices=("scan",))
    parser.add_argument("--state", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--runtime-dir", required=True)
    parser.add_argument("--agent-home", required=True)
    parser.add_argument("--now", type=int)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    try:
        scan(args)
    except (EvidenceUnavailable, OSError) as error:
        print(f"live-evidence: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
