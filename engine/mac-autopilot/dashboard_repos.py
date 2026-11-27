import json, os, re, time
from datetime import datetime

REPO = re.compile(r"^[\w.-]+/[\w.-]+$")


def cache_get(path, repo, primary, now, max_age, read_json):
    main = repo.casefold() == primary.casefold(); cache = read_json(path if main else path + ".repos") or {}
    entry = cache.get("github") if main else (cache.get("github_by_repo") or {}).get(repo)
    epoch = entry.get("fetched_epoch") if isinstance(entry, dict) else None
    if not isinstance(epoch, (int, float)) or not isinstance(entry.get("stages"), list): return None, None
    age = now - epoch
    return (entry, age) if 0 <= age < max_age else (None, None)


def cache_store(path, repo, primary, now, stages, counts, read_json):
    main = repo.casefold() == primary.casefold(); cache_path = path if main else path + ".repos"
    cache = read_json(cache_path) or {}; entry = {"fetched_epoch": now, "stages": stages, "search_counts": counts}
    if main: cache["github"] = entry
    else: cache.setdefault("github_by_repo", {})[repo] = entry
    try:
        with open(cache_path + ".tmp", "w", encoding="utf-8") as out: json.dump(cache, out, ensure_ascii=False)
        os.replace(cache_path + ".tmp", cache_path)
    except OSError: pass


def fetched_stale(fetched_at, window_s, now):
    try:
        parsed = datetime.fromisoformat(str(fetched_at).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return True
        age = now - parsed.timestamp()
        return age < 0 or age >= window_s
    except (OverflowError, TypeError, ValueError):
        return True


def configured_repos(raw, default_repo, engine_repo):
    configured = raw is not None and bool(raw.strip())
    repos = [part.strip() for part in raw.split(",") if part.strip()] if configured else [repo for repo in (engine_repo, default_repo) if repo]
    if not repos: raise ValueError("dashboard repo list is empty")
    if any(not REPO.fullmatch(repo) for repo in repos):
        raise ValueError("ZF_DASHBOARD_REPOS entries must be owner/repo")
    unique = []
    seen = set()
    for repo in repos:
        if repo.casefold() not in seen:
            unique.append(repo); seen.add(repo.casefold())
    engine = engine_repo.casefold() if engine_repo else ""
    if engine and any(repo.casefold() == engine for repo in unique):
        unique = [next(repo for repo in unique if repo.casefold() == engine)] + [repo for repo in unique if repo.casefold() != engine]
    return unique


def sections(raw, default_repo, engine_repo, workers, front, load_counts, factory_live=None, now=None, factory_repo=None):
    output = []
    try: repos = configured_repos(raw, default_repo, engine_repo)
    except ValueError as exc: return [{"repo": "ZF_DASHBOARD_REPOS", "counts": {"issues_open": None, "ready_for_agent": None, "prs_open": None, "prs_merged_24h": None}, "workers": [], "waiters": [], "error": str(exc), "stale": False, "fetched_at": None, "freshness_window_s": 300, "factory_live": None}]
    factory_repo = factory_repo or default_repo or engine_repo
    now = time.time() if now is None else float(now)
    for repo in repos:
        counts, error, stale = {"issues_open": None, "ready_for_agent": None, "prs_open": None, "prs_merged_24h": None}, None, False
        meta = {}
        try:
            if repo.casefold() == str(default_repo).casefold():
                if not isinstance(front.get("search_counts"), dict): raise RuntimeError((front.get("errors") or {}).get("stages") or "GitHub counts unavailable")
                search_counts, meta = front["search_counts"], front.get("github") or {}
            else:
                _, search_counts, meta = load_counts(repo)
            counts = {"issues_open": search_counts.get("issues_open"),
                      "ready_for_agent": (search_counts.get("stages") or {}).get("ready-for-agent"),
                      "prs_open": search_counts.get("prs_open"),
                      "prs_merged_24h": search_counts.get("prs_merged_24h")}
            error, stale = meta.get("error"), bool(meta.get("stale"))
        except Exception as exc:
            error = (str(exc).strip().splitlines() or [type(exc).__name__])[-1][:240]
        own = [dict(worker) for worker in workers if str(worker.get("repo") or "").casefold() == repo.casefold()]
        fetched_at = meta.get("fetched_at")
        freshness_window_s = meta.get("freshness_window_s", 300)
        if not isinstance(freshness_window_s, (int, float)) or freshness_window_s <= 0:
            freshness_window_s = 300
        stale = bool(stale or meta.get("stale") or fetched_stale(fetched_at, freshness_window_s, now))
        output.append({"repo": repo, "counts": counts, "workers": [w for w in own if not w.get("waiting")],
                       "waiters": [w for w in own if w.get("waiting")], "error": error, "stale": stale,
                       "fetched_at": fetched_at,
                       "freshness_window_s": freshness_window_s,
                       "factory_live": factory_live if repo.casefold() == str(factory_repo).casefold() else None})
    return output
