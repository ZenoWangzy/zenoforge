"""Merged PRs for the delivery census, read through GitHub GraphQL pages (node_health.gh_delivery_rows)."""

# The delivery join needs only each PR's merge time and merge commit. `gh pr list --json commits` asks for commits x
# authors per PR and is refused past 49 PRs, so the census pages GraphQL search results instead. It reads no reviews
# or commits: a PR with over 100 of either (4 in the last window) used to blank the whole census.
PR_CENSUS_QUERY = ("query($q:String!,$after:String){search(query:$q,type:ISSUE,first:100,after:$after){"
                   "pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number mergedAt mergeCommit{oid}}}}}")
PAGES = 20  # 2,000 merged PRs in the window; past that the census is unavailable, not cut short


def fetch(repo, cutoff, gh_json, timeout, on_unavailable=None):
    """Merged PRs since cutoff in the shape gh pr list gave (number, mergedAt, mergeCommit), or None."""
    rows, after = [], None
    for _ in range(PAGES):
        args = ["api", "graphql", "-f", f"query={PR_CENSUS_QUERY}",
                "-f", f"q=repo:{repo} is:pr is:merged merged:>={cutoff}"]
        if after:
            args += ["-f", f"after={after}"]
        page = gh_json(args, timeout)
        search = ((page or {}).get("data") or {}).get("search") if isinstance(page, dict) else None
        if not isinstance(search, dict):
            if on_unavailable:
                on_unavailable("invalid json")
            return None
        for node in search.get("nodes") or []:
            if not isinstance(node, dict) or node.get("number") is None:
                continue
            rows.append({"number": node["number"], "mergedAt": node.get("mergedAt"),
                         "mergeCommit": node.get("mergeCommit")})
        info = search.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            return rows
        after = info.get("endCursor")
    if on_unavailable:
        on_unavailable(f"page limit {PAGES} reached")
    return None
