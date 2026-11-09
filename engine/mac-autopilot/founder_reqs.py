"""Founder requirements for the dashboard front page: every issue or unit labelled founder-test, hotfix or focus,
with the founder's words (rulings.json references, else the issue title), a stage that only pipeline events and release
acceptance advance (never an agent's note), owner, blocker and the time the stage was established.
A stage change appends one supervisor-inbox line; the head supervisor monitors it. Nothing per-requirement reaches the founder."""
import calendar, json, os, re, subprocess, time

LABELS = ("founder-test", "hotfix", "focus")
STAGES = ["提出", "热修生效", "进 main", "上线", "真人验收"]  # 上线 also = held by a release-retained deploy
MERGED = {"merged", "landed", "done"}
STUCK = {"blocked-external", "parked", "needs-human", "supervisor-review"}
ACCEPTED_KEEP_S = 3 * 86400  # an accepted requirement stays listed for 3 days
ISSUE_LIMIT = 1000  # gh search returns at most 1000 rows; a search result at this count is truncated (result partial)


def configured_anomaly_prefix():
    """Configured title prefix for production-log anomaly tickets, if available."""
    try:
        from config_paths import zf_config_file
        path = zf_config_file("night.json")
        if not path: return ""
        doc = json.load(open(path, encoding="utf-8"))
        prefix = doc.get("anomaly_rules", {}).get("production_logs", {}).get("issue_title_prefix", "")
        return prefix if isinstance(prefix, str) else ""
    except (OSError, ValueError, TypeError, AttributeError):
        return ""


def is_auto_filed_ticket(issue, anomaly_prefix=None):
    """Shared auto-filed predicate for GitHub issue rows and scheduler unit rows."""
    labels = issue.get("labels") or []
    names = set()
    for label in labels:
        name = label if isinstance(label, str) else label.get("name", "") if isinstance(label, dict) else ""
        if isinstance(name, str): names.add(name)
    if names & {"incident", "prod-anomaly", "auto-filed"}: return True
    title = issue.get("title") or ""
    if not isinstance(title, str): title = ""
    if title.startswith(("Incident: ", "factory-f")): return True
    prefix = configured_anomaly_prefix() if anomaly_prefix is None else anomaly_prefix
    return isinstance(prefix, str) and bool(prefix) and title.startswith(prefix)


def _epoch(iso):
    try: return calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception: return None


def _hotfix_live(path):
    """{issue: at} from the hotfix lane's event file ($AGENT_HOME/hotfix-live.jsonl, one JSON per line);
    latest `at` per issue wins, bad lines and a missing file change nothing."""
    live = {}
    try: lines = open(path).read().splitlines()
    except OSError: return live
    for ln in lines:
        try:
            o = json.loads(ln); n = int(o["issue"]); live[n] = max(live.get(n, ""), str(o["at"]))
        except Exception: pass
    return live


def stage_of(unit, labels, accepted_at, hotfix_live_at=None, live_merge_shas=None, retained_at=None):
    """(stage index, ISO time of the event that set it). Acceptance = release-closer event only; 上线 = `released` plus live merge ancestry,
    or a release-retained deploy that holds the ticket (retained_at, from an unclosed release-retained line; labels may lag the unit);
    进 main = unit merged; 热修生效 = a `hotfix-live` history event or the issue's line in hotfix-live.jsonl."""
    hist = (unit or {}).get("history") or []
    at_of = lambda names: next((h.get("at") for h in reversed(hist) if h.get("stage") in names), None)
    merged_at = at_of({"merged", "pr-merged"})
    if accepted_at: return 4, accepted_at
    if retained_at: return 3, retained_at
    merge_sha = (unit or {}).get("merge_sha") or (unit or {}).get("land_sha")
    if "released" in labels and merge_sha in (live_merge_shas or ()): return 3, None
    if unit and (unit.get("stage") in MERGED or merged_at): return 2, merged_at
    live_at = max(filter(None, (at_of({"hotfix-live"}), hotfix_live_at)), default=None)
    if live_at: return 1, live_at
    return 0, None


def build(units, issues, rulings, accepted, now, hotfix_live=None, live_merge_shas=None, retained=None, truncated=False):
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
        labels = {l["name"] for l in i.get("labels") or []}
        # Rows fetched by number (held and open-unit tickets, #771) include ops tickets: only founder labels make a requirement.
        if labels & set(LABELS) and (i["state"] == "OPEN" or (at is not None and now - at < ACCEPTED_KEEP_S)):
            cand[n] = (i["title"], labels)
    known = {i["number"] for i in issues or []}
    for n, u in by_issue.items():
        if n not in known and set(u.get("labels") or []) & set(LABELS) and u.get("stage") != "closed":
            cand[n] = (u.get("title") or "", set(u["labels"]))
    anomaly_prefix = configured_anomaly_prefix()
    items = []
    for n, (title, labels) in cand.items():
        if is_auto_filed_ticket({"title": title, "labels": labels}, anomaly_prefix): continue
        u = by_issue.get(n)
        stage, at = stage_of(u, labels, done.get(n), (hotfix_live or {}).get(n), live_merge_shas, (retained or {}).get(n))
        blocked = (u or {}).get("blocked_on")
        items.append({"issue": n, "title": title[:120], "text": (words.get(n) or title)[:300], "from_ruling": n in words,
                      "labels": sorted(labels & set(LABELS)), "stage": stage, "github_row": n in known,
                      "owner": (u or {}).get("handed_off_to") or ("热修值班" if "hotfix" in labels else "pipeline" if u else "未接单"),
                      "blocker": f"等 #{blocked}" if blocked else (u or {}).get("stage") if (u or {}).get("stage") in STUCK else "",
                      "verified_epoch": _epoch(at or "")})
    items.sort(key=lambda x: (x["stage"] == len(STAGES) - 1, -x["issue"]))
    return {"stages": STAGES, "items": items, "partial": issues is None or truncated}


def push_changes(items, state_path, lib, agent_home):
    """First run records stages silently; later changes append an inbox line. The founder gets no per-change mail;
    stage changes reach them through the daily owner report. A failed append leaves the old stage recorded so the next beat retries it."""
    try: old = json.load(open(state_path))
    except (OSError, ValueError): old = None
    new = dict(old or {})
    for it in items:
        k = str(it["issue"])
        recorded = (old or {}).get(k)
        if not it.get("github_row", True) and isinstance(recorded, int) and recorded > it["stage"]: continue  # unit-label fallback never steps down
        if old is not None and old.get(k) != it["stage"]:
            was = STAGES[old[k]] if isinstance(old.get(k), int) and old[k] < len(STAGES) else "新增"
            msg = f"founder-req #{k} {was} → {STAGES[it['stage']]}：{it['title'][:80]}"
            try:
                ok = subprocess.run(["bash", "-c", 'source "$1" && supervisor_inbox_append_once "$2" "$3"', "bash", lib, f"freq-{k}-{it['stage']}", msg],
                                    capture_output=True, timeout=30, env={**os.environ, "AGENT_HOME": agent_home}).returncode == 0
            except Exception: ok = False
            if not ok: continue
        new[k] = it["stage"]
    if new != old:
        with open(state_path + ".tmp", "w") as f: json.dump(new, f)
        os.replace(state_path + ".tmp", state_path)


def _load_cache(cache_path):
    """{rows, truncated} from the one cache file; a bare list is the older format (truncated when it hit the limit)."""
    try: doc = json.load(open(cache_path))
    except (OSError, ValueError): return None
    if isinstance(doc, list): return {"rows": doc, "truncated": len(doc) >= ISSUE_LIMIT}
    return doc if isinstance(doc, dict) and isinstance(doc.get("rows"), list) else None


def _write_cache(cache_path, cache):
    with open(cache_path + ".tmp", "w") as f: json.dump(cache, f)
    os.replace(cache_path + ".tmp", cache_path)


def _search_rows(repo, cache_path):
    """The label search (capped at ISSUE_LIMIT by gh); a stale cache beats nothing."""
    try:
        out = subprocess.run(["gh", "issue", "list", *(["--repo", repo] if repo else []), "--state", "all", "--limit", str(ISSUE_LIMIT), "--json", "number,title,state,labels",
                              "--search", "label:" + ",".join(LABELS) + " sort:updated-desc"], capture_output=True, text=True, timeout=60)
        if out.returncode: raise RuntimeError(out.stderr[-200:])
        rows = json.loads(out.stdout)
    except Exception:
        return _load_cache(cache_path)
    cache = {"rows": rows, "truncated": len(rows) >= ISSUE_LIMIT}
    _write_cache(cache_path, cache)
    return cache


def _fetch_by_number(repo, numbers):
    """Rows for the numbers the search window missed: GraphQL aliases in batches of 100 when repo is owner/name,
    else one `gh issue view` each. Failures drop only the affected rows."""
    rows = []
    if re.fullmatch(r"[\w.-]+/[\w.-]+", repo or ""):
        for start in range(0, len(numbers), 100):
            chunk = numbers[start:start + 100]
            fields = " ".join(f"i{n}: issue(number: {n}) {{ number title state labels(first: 50) {{ nodes {{ name }} }} }}" for n in chunk)
            owner, name = repo.split("/", 1)
            query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
            try:
                out = subprocess.run(["gh", "api", "graphql", "-f", "query=" + query], capture_output=True, text=True, timeout=60)
                data = json.loads(out.stdout).get("data", {}).get("repository") or {}
            except Exception:
                continue
            for n in chunk:
                node = data.get(f"i{n}")
                if node: rows.append({"number": node["number"], "title": node["title"], "state": node["state"],
                                      "labels": [{"name": x["name"]} for x in (node.get("labels") or {}).get("nodes") or []]})
        return rows
    for n in numbers:
        try:
            out = subprocess.run(["gh", "issue", "view", str(n), "--json", "number,title,state,labels"], capture_output=True, text=True, timeout=60)
            if out.returncode == 0: rows.append(json.loads(out.stdout))
        except Exception:
            pass
    return rows


def _fetch_issues(repo, cache_path, needed=()):
    """(rows, truncated). Search rows are cached 15 minutes in one cache file. Numbers in `needed` (held or open-unit tickets)
    that the rows lack are fetched by number and merged into the cache, so the ladder never depends on the search window.
    None rows when GitHub and the cache are both unavailable."""
    cache = None
    try:
        if time.time() - os.path.getmtime(cache_path) < 900: cache = _load_cache(cache_path)
    except OSError: pass
    if cache is None: cache = _search_rows(repo, cache_path)
    if cache is None: return None, False
    have = {r.get("number") for r in cache["rows"]}
    missing = sorted(set(needed) - have)
    if missing:
        fetched = _fetch_by_number(repo, missing)
        if fetched:
            cache = {"rows": cache["rows"] + fetched, "truncated": cache["truncated"]}
            _write_cache(cache_path, cache)
    return cache["rows"], cache["truncated"]


def collect(units, repo, rulings_path, runtime, agent_home, lib):
    import node_health, live_delivery, release_retained
    try: rulings = json.load(open(rulings_path)).get("rulings") or []
    except (OSError, ValueError): rulings = []
    live = live_delivery.read_live_sha(agent_home)
    live_merge_shas = live_delivery.ancestor_shas(live_delivery.repository_root(), live["sha"]) if live else set()
    held = release_retained.held_at(runtime)
    needed = set(held) | {int(u["issue"]) for u in units if set(u.get("labels") or []) & set(LABELS) and u.get("stage") != "closed"
                          and str(u.get("issue", "")).isdigit()}
    rows, truncated = _fetch_issues(repo, os.path.join(runtime, "founder-reqs.cache.json"), needed)
    out = build(units, rows, rulings, node_health.release_acceptances(runtime), time.time(),
                _hotfix_live(os.path.join(agent_home, "hotfix-live.jsonl")), live_merge_shas, held, truncated=truncated)
    push_changes(out["items"], os.path.join(agent_home, "founder-req-stage.json"), lib, agent_home)
    return out
