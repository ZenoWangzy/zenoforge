"""Founder requirements for the dashboard front page: every issue or unit labelled founder-test, hotfix or focus,
with the founder's words (rulings.json references, else the issue title), a stage that only pipeline events and release
acceptance advance (never an agent's note), owner, blocker and the time the stage was established.
A stage change appends one supervisor-inbox line; the head supervisor session turns it into the PushNotification."""
import calendar, json, os, re, subprocess, time

LABELS = ("founder-test", "hotfix", "focus")
STAGES = ["提出", "热修生效", "进 main", "上线", "真人验收"]
MERGED = {"merged", "landed", "done"}
STUCK = {"blocked-external", "parked", "needs-human", "supervisor-review"}
ACCEPTED_KEEP_S = 3 * 86400  # an accepted requirement stays listed for 3 days


def _epoch(iso):
    try: return calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception: return None


def stage_of(unit, labels, accepted_at):
    """(stage index, ISO time of the event that set it). Acceptance = release-closer event; 上线 = the issue's `released` label;
    进 main = unit merged; 热修生效 = a `hotfix-live` history event (shortcut: no producer yet, hotfix items skip it until the hotfix lane records one)."""
    hist = (unit or {}).get("history") or []
    at_of = lambda names: next((h.get("at") for h in reversed(hist) if h.get("stage") in names), None)
    merged_at = at_of({"merged", "pr-merged"})
    if accepted_at: return 4, accepted_at
    if "released" in labels: return 3, None
    if unit and (unit.get("stage") in MERGED or merged_at): return 2, merged_at
    if at_of({"hotfix-live"}): return 1, at_of({"hotfix-live"})
    return 0, None


def build(units, issues, rulings, accepted, now):
    """Pure core. issues: gh rows {number,title,state,labels:[{name}]} or None when GitHub was unreachable (units only)."""
    words = {}
    for r in rulings or []:
        for ref in r.get("references") or []:
            if re.fullmatch(r"#\d+", str(ref)): words[int(ref[1:])] = r.get("verbatim") or ""
    done = {}
    for a in accepted or []: done[a["issue"]] = max(done.get(a["issue"], ""), a["at"])
    by_issue = {}
    for u in units:
        try: by_issue[int(u.get("issue"))] = u
        except (TypeError, ValueError): pass
    cand = {}
    for i in issues or []:
        n = i["number"]
        at = _epoch(done.get(n) or "")
        if i["state"] == "OPEN" or (at is not None and now - at < ACCEPTED_KEEP_S):
            cand[n] = (i["title"], {l["name"] for l in i.get("labels") or []})
    known = {i["number"] for i in issues or []}
    for n, u in by_issue.items():
        if n not in known and set(u.get("labels") or []) & set(LABELS) and u.get("stage") != "closed":
            cand[n] = (u.get("title") or "", set(u["labels"]))
    items = []
    for n, (title, labels) in cand.items():
        u = by_issue.get(n)
        stage, at = stage_of(u, labels, done.get(n))
        blocked = (u or {}).get("blocked_on")
        items.append({"issue": n, "title": title[:120], "text": (words.get(n) or title)[:300], "from_ruling": n in words,
                      "labels": sorted(labels & set(LABELS)), "stage": stage,
                      "owner": (u or {}).get("handed_off_to") or ("热修值班" if "hotfix" in labels else "pipeline" if u else "未接单"),
                      "blocker": f"等 #{blocked}" if blocked else (u or {}).get("stage") if (u or {}).get("stage") in STUCK else "",
                      "verified_epoch": _epoch(at or "")})
    items.sort(key=lambda x: (x["stage"] == len(STAGES) - 1, -x["issue"]))
    return {"stages": STAGES, "items": items, "partial": issues is None}


def push_changes(items, state_path, lib, agent_home):
    """First run records the stages silently; afterwards each stage change appends one inbox line (key freq-<issue>-<stage>).
    A failed append leaves the old stage recorded so the next beat retries it."""
    try: old = json.load(open(state_path))
    except (OSError, ValueError): old = None
    new = dict(old or {})
    for it in items:
        k = str(it["issue"])
        if old is not None and old.get(k) != it["stage"]:
            was = STAGES[old[k]] if isinstance(old.get(k), int) and old[k] < len(STAGES) else "新增"
            msg = f"founder-req #{k} {was} → {STAGES[it['stage']]}：{it['title'][:80]}（请 PushNotification 通知创始人）"
            try:
                ok = subprocess.run(["bash", "-c", 'source "$1" && supervisor_inbox_append_once "$2" "$3"', "bash", lib, f"freq-{k}-{it['stage']}", msg],
                                    capture_output=True, timeout=30, env={**os.environ, "AGENT_HOME": agent_home}).returncode == 0
            except Exception: ok = False
            if not ok: continue
        new[k] = it["stage"]
    if new != old:
        with open(state_path + ".tmp", "w") as f: json.dump(new, f)
        os.replace(state_path + ".tmp", state_path)


def _fetch_issues(repo, cache_path):
    """One GitHub call for all three labels (comma = OR), cached 15 minutes; a stale cache beats nothing."""
    try:
        if time.time() - os.path.getmtime(cache_path) < 900: return json.load(open(cache_path))
    except (OSError, ValueError): pass
    try:
        out = subprocess.run(["gh", "issue", "list", *(["--repo", repo] if repo else []), "--state", "all", "--limit", "300", "--json", "number,title,state,labels",
                              "--search", "label:" + ",".join(LABELS) + " sort:updated-desc"], capture_output=True, text=True, timeout=60)
        if out.returncode: raise RuntimeError(out.stderr[-200:])
        rows = json.loads(out.stdout)
    except Exception:
        try: return json.load(open(cache_path))
        except (OSError, ValueError): return None
    with open(cache_path + ".tmp", "w") as f: json.dump(rows, f)
    os.replace(cache_path + ".tmp", cache_path)
    return rows


def collect(units, repo, rulings_path, runtime, agent_home, lib):
    import node_health
    try: rulings = json.load(open(rulings_path)).get("rulings") or []
    except (OSError, ValueError): rulings = []
    out = build(units, _fetch_issues(repo, os.path.join(runtime, "founder-reqs.cache.json")), rulings, node_health.release_acceptances(runtime), time.time())
    push_changes(out["items"], os.path.join(agent_home, "founder-req-stage.json"), lib, agent_home)
    return out
