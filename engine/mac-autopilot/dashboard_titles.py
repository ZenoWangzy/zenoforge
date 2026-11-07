"""Dashboard card titles: cards whose task is only an id get the issue or PR title (gen_dashboard fill_titles)."""
import json, os, re


def read_cache(path):
    try:
        with open(path) as stream:
            return json.load(stream)
    except (OSError, ValueError):
        return None


def fill_titles(rows, known, cache_path, run):
    """Cards whose task is only an id (opt-i4727, 4631) get the issue / PR title: ledger and stage-tile titles first, then a
    persistent cache, then ONE batched GraphQL call for the numbers still missing (titles never change, so cached forever)."""
    idish = lambda t: not t or re.fullmatch(r"[\w.-]+", t) is not None
    need = {r["issue"] for r in rows if r.get("issue") and idish(r.get("task"))}
    cache = read_cache(cache_path) or {}
    titles = {**cache, **{str(k): v for k, v in known.items() if v}}
    miss = sorted(n for n in need if str(n) not in titles)[:30]
    if miss:
        try:
            query = ("query($owner:String!,$name:String!){repository(owner:$owner,name:$name){" +
                     "".join(f"r{n}:issueOrPullRequest(number:{int(n)}){{... on Issue{{title}} ... on PullRequest{{title}}}} " for n in miss) + "}}")
            repo = ((json.loads(run(["gh", "api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-f", "query=" + query], 30)) or {}).get("data") or {}).get("repository") or {}
            for n in miss:
                t = (repo.get(f"r{n}") or {}).get("title")
                if t: titles[str(n)] = cache[str(n)] = t
            with open(cache_path + ".tmp", "w", encoding="utf-8") as out: json.dump(cache, out, ensure_ascii=False)
            os.replace(cache_path + ".tmp", cache_path)
        except Exception:
            pass
    for r in rows:
        if not r.get("issue"): continue  # a card with no issue has no title to look up (str(None) would match "None")
        t = titles.get(str(r.get("issue")))
        if t and idish(r.get("task")): r["task"] = t[:60]
