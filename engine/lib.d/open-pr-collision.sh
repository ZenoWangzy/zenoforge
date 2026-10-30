_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# Both scheduler and HEALTH share only identity-bound details; checks stay fresh.
open_pr_snapshot_read() {
  python3 "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")/open-pr-snapshot.py" --repo "$REPO" \
    --cache "${NIGHT:-$AGENT_HOME/night}/pr-details-cache.json" "$@"
}


load_open_pr_file_collision_cache() {
  local prs_stream="$1" snapshot
  if [ "$OPEN_PR_FILE_COLLISION_CACHE_READY" = 1 ] \
    && [ "$OPEN_PR_FILE_COLLISION_CACHE_SOURCE" = "$prs_stream" ]; then
    return 0
  fi
  if ! snapshot="$(jq -sc '[.[] | if type == "array" then .[] else . end]' <<< "$prs_stream")"; then
    OPEN_PR_FILE_COLLISION_CACHE_SOURCE="$prs_stream"
    OPEN_PR_FILE_COLLISION_CACHE_JSON='[]'
    OPEN_PR_FILE_COLLISION_CACHE_READY=1
    OPEN_PR_FILE_COLLISION_CACHE_COMPLETE=0
    return 1
  fi
  OPEN_PR_FILE_COLLISION_CACHE_SOURCE="$prs_stream"
  OPEN_PR_FILE_COLLISION_CACHE_JSON="$snapshot"
  OPEN_PR_FILE_COLLISION_CACHE_READY=1
  if jq -e 'all(.[]; (.files | type == "array"))' <<< "$snapshot" >/dev/null 2>&1; then
    OPEN_PR_FILE_COLLISION_CACHE_COMPLETE=1
  else
    OPEN_PR_FILE_COLLISION_CACHE_COMPLETE=0
  fi
}


open_pr_file_collision() {
  local expected_json="$1" open_prs_stream="$2" exclude_head_ref="${3:-}" pr_json pr f files head_ref
  OPEN_PR_FILE_COLLISION_PR=""
  OPEN_PR_FILE_COLLISION_PATH=""
  OPEN_PR_FILE_COLLISION_OWNER=""
  OPEN_PR_FILE_COLLISION_UPDATED_AT=""

  if load_open_pr_file_collision_cache "$open_prs_stream" \
    && [ "$OPEN_PR_FILE_COLLISION_CACHE_COMPLETE" = 1 ]; then
    local collision
    collision="$(jq -r --argjson expected "$expected_json" --arg exclude "$exclude_head_ref" '
      def in_scope($path):
        any($expected[]?; . as $item | ($path == $item or ($path | startswith($item + "/"))));
      def shared_path($path):
        $path == "package.json" or ($path | endswith("/package.json"))
        or $path == "pnpm-lock.yaml" or ($path | endswith("/pnpm-lock.yaml"))
        or $path == "package-lock.json" or ($path | endswith("/package-lock.json"))
        or $path == "yarn.lock" or ($path | endswith("/yarn.lock"))
        or ($path | endswith("/src/index.ts")) or ($path | endswith("/src/index.tsx"))
        or ($path | endswith("/src/index.js")) or ($path | endswith("/src/index.mjs"))
        or ($path | test("^packages/.+/index\\.(ts|tsx|js|mjs)$"));
      first(
        .[] as $pr
        | ($pr.headRefName // "") as $head
        | select($exclude == "" or $head != $exclude)
        | $pr.files[]? as $file
        | (if ($file | type) == "object" then ($file.path // "") else $file end) as $path
        | select(($path | type) == "string" and $path != "")
        | select(in_scope($path))
        | select((shared_path($path) | not) or any($expected[]?; . == $path))
        | [($pr.number // "" | tostring), $path,
           (if ($head | test("^agent/issue-[0-9]+$")) then ($head | sub("^agent/issue-"; "")) else "" end),
           ($pr.updatedAt // "")] | join("\u001f")
      ) // empty
    ' <<< "$OPEN_PR_FILE_COLLISION_CACHE_JSON")"
    if [ -n "$collision" ]; then
      IFS=$'\037' read -r OPEN_PR_FILE_COLLISION_PR OPEN_PR_FILE_COLLISION_PATH \
        OPEN_PR_FILE_COLLISION_OWNER OPEN_PR_FILE_COLLISION_UPDATED_AT <<< "$collision"
      return 0
    fi
    return 1
  fi

  while IFS= read -r pr_json; do
    [ -n "$pr_json" ] || continue
    pr="$(echo "$pr_json" | jq -r '.number // empty' 2>/dev/null)"
    [ -n "$pr" ] || continue
    head_ref="$(echo "$pr_json" | jq -r '.headRefName // empty' 2>/dev/null)"
    [ -n "$exclude_head_ref" ] && [ "$head_ref" = "$exclude_head_ref" ] && continue
    # issue-pipeline.sh supplies the list snapshot so a candidate census does
    # not issue the same GitHub files query once for every candidate. Other
    # callers without files keep the live lookup behavior.
    if echo "$pr_json" | jq -e '.files | type == "array"' >/dev/null 2>&1; then
      files="$(echo "$pr_json" | jq -r '.files[] | if type == "object" then .path // empty else . end')"
    else
      files="$(gh pr view "$pr" --repo "$REPO" --json files -q '.files[].path')"
    fi
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if path_in_selection_scope "$expected_json" "$f"; then
        if shared_collision_path "$f" && ! selection_scope_has_exact_path "$expected_json" "$f"; then
          continue
        fi
        OPEN_PR_FILE_COLLISION_PR="$pr"
        OPEN_PR_FILE_COLLISION_PATH="$f"
        if [[ "$head_ref" =~ ^agent/issue-([0-9]+)$ ]]; then
          OPEN_PR_FILE_COLLISION_OWNER="${BASH_REMATCH[1]}"
        fi
        OPEN_PR_FILE_COLLISION_UPDATED_AT="$(echo "$pr_json" | jq -r '.updatedAt // empty' 2>/dev/null)"
        return 0
      fi
    done <<< "$files"
  done <<< "$open_prs_stream"
  return 1
}


# 2026-09-12 bug this replaces: the old finish-first collision branch
# (issue-pipeline.sh) labeled an issue finish-first on a transient overlap
# with another in-flight implement run and nothing in the codebase ever
# removed that label again — an issue parked there permanently. A
# still-running implement dispatch has no PR yet (up to 2 hours before it
# ever pushes), so a file-based scan of open PRs can't see it either. This
# derives the exclusion set instead of storing anything: true (collides) if
# any candidate selection-scope entry ($1, optional exact paths or normalized
# packages) overlaps an in-flight run's selection scope ($2, built by the
# caller from stage_active_issues plus each state file). Compare both prefix
# directions: exact paths can be siblings in one package, while a legacy
# package scope still contains all of its descendants.
expected_packages_collide() {
  local candidate_json="$1" union_json="$2" candidate active
  EXPECTED_SCOPE_COLLISION_CANDIDATE=""
  EXPECTED_SCOPE_COLLISION_ACTIVE=""
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    while IFS= read -r active; do
      [ -z "$active" ] && continue
      if [ "$candidate" = "$active" ] \
        || [[ "$candidate" == "$active/"* ]] \
        || [[ "$active" == "$candidate/"* ]]; then
        EXPECTED_SCOPE_COLLISION_CANDIDATE="$candidate"
        EXPECTED_SCOPE_COLLISION_ACTIVE="$active"
        return 0
      fi
    done < <(echo "$union_json" | jq -r '.[]?')
  done < <(echo "$candidate_json" | jq -r '.[]?')
  return 1
}


# Defect (d), 2026-09-12: which issue numbers does a merge-commit range
# actually cover? Every agent PR's merge-commit subject is `fix(#N): ...`
# (run-implement.sh's MERGE_SUBJECT, itself the PR title it sets at create
# time) — used by run-release.sh to relabel every issue a failed deploy's
# image build actually included, not just the one that happened to trigger
# the run. A human-authored commit in the range matches nothing here and is
# deliberately NOT returned — it maps to no tracked issue, so the caller
# names it "unattributed" in its comment instead of silently dropping it.
issue_numbers_in_range() {
  local range="$1" dir="${2:-$REPO_DIR}"
  git -C "$dir" log --format=%s "$range" \
    | sed -nE 's/^fix\(#([0-9]+)\):.*/\1/p'
}
