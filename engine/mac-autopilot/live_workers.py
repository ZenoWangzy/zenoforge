"""Every agent process doing pipeline work right now, for the dashboard front page.
Sources: scheduler workers (pid in /proc), ad-hoc luna/zc/worker scopes, advisor batch units, release batch.
Reads /proc/<pid>/{comm,cwd}, file mtimes and systemctl properties only; never process args."""
import calendar, glob, json, os, re, subprocess, time

STEPS = {"pipeline": ["implement", "review", "repair", "rereview", "land"], "opt": ["run", "land"], "hotfix": ["run", "land"],
         "advisor": ["ask", "answer"], "release": []}
# typical wall seconds per kind; shortcut: fixed scale, no history p50 yet, replace with ledger medians when they exist
TYPICAL = {"implement": 2700, "repair": 1500, "review": 900, "rereview": 600, "triage": 300,
           "opt": 1800, "hotfix": 1800, "advisor": 600, "release": 1200}


def _systemctl(args):
    try:
        return subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True, timeout=8).stdout
    except Exception:
        return ""


def _active_units(patterns):
    out = _systemctl(["list-units", *patterns, "--state=active", "--no-legend", "--plain", "--all"])
    return [l.split()[0] for l in out.splitlines() if l.strip()]


def _unit_props(names):
    props, cur = {}, {}
    out = _systemctl(["show", *names, "-p", "Id", "-p", "ActiveEnterTimestampMonotonic", "-p", "ControlGroup"]) if names else ""
    for line in out.splitlines() + [""]:
        if not line.strip():
            if cur.get("Id"): props[cur["Id"]] = cur
            cur = {}
        elif "=" in line:
            k, v = line.split("=", 1); cur[k] = v
    return props


def _first_line(path, limit=120):
    try:
        with open(path, errors="replace") as f: return f.readline().strip()[:limit]
    except OSError:
        return ""


def _fresh_age(paths, now):
    """Seconds since the newest write among paths; None when none exists."""
    ts = [os.path.getmtime(p) for p in paths if os.path.exists(p)]
    return int(now - max(ts)) if ts else None


def _health(age):
    return "none" if age is None else "ok" if age < 300 else "warn" if age <= 1800 else "bad"


def _under_hotfix(cgroup, root="/sys/fs/cgroup"):
    """True when any process in the unit's cgroup has its cwd (via /proc, never args) under .scratch/hotfix/."""
    try: pids = open(f"{root}{cgroup}/cgroup.procs").read().split()
    except OSError: return False
    for pid in pids:
        try:
            if "/.scratch/hotfix/" in os.readlink(f"/proc/{int(pid)}/cwd") + "/": return True
        except (OSError, ValueError):
            pass
    return False


def _backend(model_or_name):
    m = (model_or_name or "").lower()
    return "zc" if "zc" in m or "glm" in m else "cl" if re.search(r"claude|sonnet|opus|haiku", m) else "cx"


def _brief(luna_dir, key):
    """(task title, issue number) from the worker's brief: first heading, else first line; Refs #N or the key's number."""
    base = re.sub(r"-r\d+$", "", key)
    scratch = os.path.dirname(luna_dir)
    for p in (f"{luna_dir}/briefs/{key}.md", f"{luna_dir}/briefs/{base}.md", f"{scratch}/research/{base}-brief.md", f"{luna_dir}/{key}/brief.md"):
        try:
            lines = [l.strip() for l in open(p, errors="replace").read().splitlines()[:40] if l.strip()]
        except OSError:
            continue
        if not lines: continue
        title = re.sub(r"^#+\s*", "", lines[0])
        if ":" in title and len(title.split(":")[0]) >= 12: title = title.split(":")[0]
        m = re.search(r"Refs?\s+#(\d+)", "\n".join(lines))
        return title[:60], int(m.group(1)) if m else None
    m = re.search(r"(\d{3,5})", key)
    return "", int(m.group(1)) if m else None


def _worker_tokens(w, root):
    """Tokens this pipeline run used so far: the session's cumulative total minus the total when the run started."""
    p = _rollout_for(root, session_id=w.get("session_id")) if root and w.get("session_id") else None
    cur = _tail_total(p) if p else None
    return None if cur is None else max(0, cur - ((w.get("token_usage_start") or {}).get("raw") or 0))


def _bytes(traffic, key):
    """rx/tx from the traffic monitor's per-worker totals; None (shown as —) when the monitor never saw the worker."""
    t = traffic.get(key)
    return {"rx": t.get("rx"), "tx": t.get("tx")} if isinstance(t, dict) else {"rx": None, "tx": None}


def _tail_total(path, size=262144):
    """Latest cumulative input+output tokens from a codex rollout (reads only the last `size` bytes); None when absent."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2); f.seek(max(0, f.tell() - size))
            lines = [l for l in f.read().decode("utf-8", "replace").splitlines() if '"token_count"' in l]
        for l in reversed(lines):
            try: u = (json.loads(l).get("payload") or {}).get("info", {}).get("total_token_usage") or {}
            except ValueError: continue
            if isinstance(u.get("input_tokens"), int) and isinstance(u.get("output_tokens"), int): return u["input_tokens"] + u["output_tokens"]
    except OSError: pass
    return None


def _zc_total(path):
    """Sum of per-request totalTokens in a ZCode events.jsonl; None when no request finished yet."""
    tot = None
    try:
        for l in open(path, errors="replace"):
            if '"model_request_completed"' in l:
                m = re.search(r'"usage":\s*\{[^}]*?"totalTokens":\s*(\d+)', l)
                if m: tot = (tot or 0) + int(m[1])
    except OSError: pass
    return tot


def _rollout_for(root, session_id=None, cwd=None, now=None):
    """Codex rollout of a worker: by session id, else the newest recently written one whose session_meta cwd matches."""
    if session_id:
        hit = sorted(glob.glob(f"{root}/*/*/*/rollout-*-{session_id}.jsonl"))
        return hit[-1] if hit else None
    if not cwd: return None
    now = now or time.time()
    for p in sorted(glob.glob(f"{root}/*/*/*/rollout-*.jsonl"), key=os.path.getmtime, reverse=True)[:60]:
        if now - os.path.getmtime(p) > 900: break
        try: meta = json.loads(open(p, errors="replace").readline()).get("payload") or {}
        except (OSError, ValueError): continue
        if meta.get("cwd") == cwd: return p
    return None


def _epoch(iso):
    try: return calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception: return None


def collect(pipeline_workers, units, prefix, luna_dir, jobs_dir, sup="", traffic=None, codex_root=""):
    """pipeline_workers: dashboard `wl` rows; units: ledger rows."""
    now = time.time()
    traffic = traffic or {}
    uptime = float(open("/proc/uptime").read().split()[0])
    by_unit = {u.get("id"): u for u in units}
    by_issue = {u.get("issue"): u for u in units if u.get("issue")}
    items = []
    for w in pipeline_workers:
        if not w.get("alive"): continue
        u = by_unit.get(w.get("unit")) or {}
        typ = w.get("type") or "implement"
        log = os.path.join(sup, w.get("log") or "x")
        # real unit chain: implement -> review -> repair <-> rereview -> land; other kinds (triage, supervise) get a one-step track
        steps = STEPS["pipeline"] if typ in STEPS["pipeline"] else [typ]
        step = steps.index(typ) if typ in steps else 0
        items.append({"owner": "pipeline", "task": (u.get("title") or w.get("unit") or "")[:60], "issue": u.get("issue"), "pr": u.get("pr"),
                      "backend": _backend(w.get("model")), "steps": steps, "step": step, "kind": typ,
                      "tokens": _worker_tokens(w, codex_root) or w.get("tokens") or None, **_bytes(traffic, "wt:" + (os.path.basename(w.get("workdir") or "")[3:] or w.get("unit") or "")),
                      "started_epoch": _epoch(w.get("started") or ""), "typical_s": TYPICAL.get(typ, 1800),
                      "health": _health(_fresh_age([log], now)), "tip": f"{w.get('unit')} · {typ} · {w.get('started') or ''}"})
    pats = ["luna-*.scope", f"{prefix}-w-*", "opt-*", f"{prefix}-web-advisor-provider-*", f"{prefix}-advisor-batch*", f"{prefix}-release-batch*"]
    names = [n for n in _active_units(pats) if not n.endswith("-feeder.service")]
    # opt-<key>.service is the wrapper of luna-*-opt-<key>-N.scope: one card, not two
    names = [n for n in names if not (n.startswith("opt-") and any(m.startswith("luna-") and f"-{n[:-8]}-" in m for m in names))]
    props = _unit_props(names)
    for n in names:
        try: started = now - max(0, uptime - int(props[n]["ActiveEnterTimestampMonotonic"]) / 1e6)
        except Exception: started = None
        base = re.sub(r"\.(scope|service)$", "", n)
        it = {"issue": None, "pr": None, "backend": "cx", "started_epoch": int(started) if started else None, "tip": n, "tokens": None, **_bytes(traffic, "unit:" + n)}
        if "advisor" in base:
            job = re.sub(rf"^{re.escape(prefix)}-(web-advisor-provider-)?advisor-(batch-)?", "", base)
            d = os.path.join(jobs_dir, "advisor-batch-" + job)
            it.update(owner="advisor", task="顾问批处理", kind="advisor", backend="cl", health=_health(_fresh_age([d + "/state.json"], now)))
        elif "release-batch" in base:
            it.update(owner="release", task="发布", kind="release", health="none")
        else:
            key = re.sub(r"-\d+$", "", re.sub(r"^luna-(zc-)?|^opt-|^" + re.escape(prefix) + r"-w-", "", base))
            d = os.path.join(luna_dir, key)
            owner = "hotfix" if re.search(r"hotfix|(^|-)hf(-|$)", key) or _under_hotfix(props.get(n, {}).get("ControlGroup", "")) \
                or any(os.path.isdir(f"{os.path.dirname(luna_dir)}/hotfix/wt-{k}") for k in (key, re.sub(r"-r\d+$", "", key))) else "opt"
            title, num = _brief(luna_dir, key)
            ref = by_issue.get(num) or {}
            bk = _first_line(os.path.join(d, "backend"), 20) or ("zc" if base.startswith("luna-zc-") else "luna")
            tk = _zc_total(d + "/events.jsonl") if bk.startswith("zc") else None
            if tk is None and bk == "luna":
                try: tk = _tail_total(_rollout_for(codex_root, cwd=os.readlink(f"/proc/{int(_first_line(d + '/codex.pid', 12))}/cwd"), now=now) or "")
                except (OSError, ValueError): pass
            it.update(owner=owner, task=(ref.get("title") or title or key)[:60], issue=num, pr=ref.get("pr"), kind=owner, tokens=tk,
                      backend="zc" if bk.startswith("zc") else "cx" if bk == "luna" else _backend(bk),
                      health=_health(_fresh_age([d + "/events.jsonl", d + "/stderr.log", d + "/stdout.log"], now)),
                      tip=f"{key} · {n}")
        it.update(steps=STEPS[it["owner"]], step=0, typical_s=TYPICAL.get(it["kind"], 1800))
        items.append(it)
    try: mem = int([l for l in open("/proc/meminfo") if l.startswith("MemAvailable")][0].split()[1]) // 1024
    except Exception: mem = None
    try: load = float(open("/proc/loadavg").read().split()[1])
    except Exception: load = None
    return {"items": items, "load5": load, "mem_avail_mb": mem, "generated_epoch": int(now)}
