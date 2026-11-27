import glob, json, os, re, time

STAMP = re.compile(r"^\[?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]?\s+(.*)$")
ISSUE = re.compile(r"\bissue\s*#?(\d+)\b|(?<![\w])#(\d+)\b", re.I)
ACTIONS = (
    ("skipped", re.compile(r"\bskip(?:ped)?\b", re.I)),
    ("dispatched", re.compile(r"\bdispatch(?:ed|ing)?\b", re.I)),
    ("claimed", re.compile(r"\bclaim(?:ed)?\b", re.I)),
    ("deferred", re.compile(r"\bdefer(?:red)?\b", re.I)),
    ("held", re.compile(r"\bheld\b", re.I)),
    ("rejected", re.compile(r"\breject(?:ed)?\b", re.I)),
)


def _issue(key, run_dir, luna_root):
    match = re.search(r"(?:^|[-_])(?:issue[-_])?(\d{3,6})(?=$|[-_])", key, re.I)
    if match:
        return int(match.group(1))
    for path in (os.path.join(run_dir, "brief.md"), os.path.join(luna_root, "briefs", f"{key}.md"), os.path.join(luna_root, key, key, "brief.md")):
        try:
            with open(path, encoding="utf-8", errors="replace") as source:
                match = ISSUE.search(source.read(8192))
            if match:
                return int(match.group(1) or match.group(2))
        except OSError:
            pass
    return None


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError):
        return False


def _rc(path):
    try:
        with open(path, encoding="utf-8") as source:
            value = source.readline().strip()
        return int(value) if re.fullmatch(r"-?\d+", value) else None
    except OSError:
        return None


def read_pause_marker(path):
    try:
        with open(path, encoding="utf-8") as source:
            raw = source.read(8192).strip()
    except FileNotFoundError:
        return None
    except OSError:
        return {"error": "unreadable"}
    try:
        value = json.loads(raw) if raw else {}
    except ValueError:
        value = {}
    if not isinstance(value, dict):
        value = {}
    return {"since": value.get("timestamp"), "reason": value.get("reason") or (raw[:240] if raw else None)}


def read_pause_states(line_pause_file, factory_pause_file, now=None):
    now = time.time() if now is None else float(now)
    fetched_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    line_pause = read_pause_marker(line_pause_file)
    factory_pause = read_pause_marker(factory_pause_file)
    def status(value):
        return {"paused": None if value and value.get("error") else value is not None,
                "since": (value or {}).get("since"), "reason": (value or {}).get("reason"), "fetched_at": fetched_at}
    return {
        "fetched_at": fetched_at,
        "vecta_line": status(line_pause),
        "zenoforge_factory": status(factory_pause),
    }


def engine_live_pin(agent_home):
    target = os.path.realpath(os.path.join(agent_home, "engine-live"))
    match = re.search(r"(?:^|/)engine-versions/([0-9a-f]{7,40})(?:-[0-9a-f]{7,40}(?:-[0-9a-f]{7,40}){2})?/engine/?$", target)
    if match:
        return match.group(1)
    version = os.path.basename(os.path.dirname(target))
    return version if re.fullmatch(r"[0-9a-f]{7,40}", version) else None


def read_luna_workers(agent_home, now=None, pid_alive=None):
    now = time.time() if now is None else float(now)
    alive = pid_alive or _pid_alive
    root = os.path.join(agent_home, "scratch", "luna")
    rows = []
    for run_dir in sorted(glob.glob(os.path.join(root, "*"))):
        key = os.path.basename(run_dir)
        if not os.path.isdir(run_dir) or not re.fullmatch(r"[\w.-]{1,160}", key):
            continue
        pid_path = None
        for filename in ("wrapper.pid", "codex.pid"):
            candidate = os.path.join(run_dir, filename)
            try:
                with open(candidate, encoding="utf-8") as source:
                    pid = source.readline().strip()
                if pid.isdigit() and alive(pid):
                    pid_path = candidate
                    break
            except OSError:
                pass
        if pid_path is None:
            continue
        try:
            started = os.path.getmtime(pid_path)
        except OSError:
            continue
        rows.append({
            "key": key,
            "issue": _issue(key, run_dir, root),
            "age_s": max(0, int(now - started)),
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
            "state": "gate-wait" if os.path.exists(os.path.join(run_dir, "gate-wait")) else "running",
            "rc": _rc(os.path.join(run_dir, "rc")),
        })
    return sorted(rows, key=lambda row: (row["age_s"], row["key"]), reverse=True)[:40]


def read_dispatch_decisions(agent_home, limit=8):
    path = os.path.join(agent_home, "zenoforge-dispatch.log")
    try:
        with open(path, "rb") as source:
            source.seek(0, 2)
            size = source.tell()
            source.seek(max(0, size - 131072))
            lines = source.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        match = STAMP.match(line.strip())
        if not match:
            continue
        at, detail = match.groups()
        issue_match = ISSUE.search(detail)
        issue = int(issue_match.group(1) or issue_match.group(2)) if issue_match else None
        decision = next((name for name, pattern in ACTIONS if pattern.search(detail)), "recorded")
        if issue is None and decision == "recorded":
            continue
        rows.append({"at": at, "issue": issue, "decision": decision})
    return rows[-max(0, int(limit)):]


def merge_lane_merges_today(units, today, date_of):
    merged = set()
    for unit in units if isinstance(units, list) else []:
        if not isinstance(unit, dict):
            continue
        pr = unit.get("pr")
        try:
            pr = int(pr)
        except (TypeError, ValueError):
            continue
        if pr <= 0:
            continue
        for event in unit.get("history") or []:
            if isinstance(event, dict) and event.get("stage") == "merged" and date_of(event.get("at")) == today:
                merged.add(pr)
    return sorted(merged)


def read_live(agent_home, units, now, today, date_of, pid_alive=None):
    return {
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "luna_workers": read_luna_workers(agent_home, now, pid_alive),
        "dispatch_decisions": read_dispatch_decisions(agent_home),
        "merge_lane_today": merge_lane_merges_today(units, today, date_of),
    }
