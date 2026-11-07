"""Merged PRs for the delivery census, read through GitHub GraphQL pages (node_health.gh_delivery_rows)."""

# `gh pr list --json commits` asks GitHub for commits x authors per PR: --limit 1000 is over GraphQL's 500,000-node
# cap and returns nothing, and any limit above 49 is refused too. The census pages search results 50 at a time instead.
PR_CENSUS_QUERY = ("query($q:String!,$after:String){search(query:$q,type:ISSUE,first:50,after:$after){"
                   "pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number mergedAt body mergeCommit{oid} "
                   "reviews(first:100){totalCount nodes{author{login} body state submittedAt}} "
                   "commits(first:100){totalCount nodes{commit{messageHeadline messageBody}}}}}}}")
PAGES = 40  # 2,000 merged PRs in the window; past that the census is unavailable, not cut short


def fetch(repo, cutoff, gh_json, timeout):
    """Merged PRs since cutoff in the shape gh pr list gave (number, mergedAt, body, mergeCommit, reviews, commits), or None."""
    rows, after = [], None
    for _ in range(PAGES):
        args = ["api", "graphql", "-f", f"query={PR_CENSUS_QUERY}",
                "-f", f"q=repo:{repo} is:pr is:merged merged:>={cutoff}"]
        if after:
            args += ["-f", f"after={after}"]
        page = gh_json(args, timeout)
        search = ((page or {}).get("data") or {}).get("search") if isinstance(page, dict) else None
        if not isinstance(search, dict):
            return None
        for node in search.get("nodes") or []:
            if not isinstance(node, dict) or node.get("number") is None:
                continue
            reviews, commits = node.get("reviews") or {}, node.get("commits") or {}
            if reviews.get("totalCount", 0) > 100 or commits.get("totalCount", 0) > 100:
                return None  # a PR past the page size would be read short, so the census is unavailable
            rows.append({"number": node["number"], "mergedAt": node.get("mergedAt"), "body": node.get("body"),
                         "mergeCommit": node.get("mergeCommit"),
                         "reviews": reviews.get("nodes") or [], "commits": commits.get("nodes") or []})
        info = search.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            return rows
        after = info.get("endCursor")
    return None
