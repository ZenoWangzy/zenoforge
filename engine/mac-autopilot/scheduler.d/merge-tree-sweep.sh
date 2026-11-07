# ---------- merge-tree sweep: when origin/main moves, find text conflicts on every open PR and start the repair then ----------
# Runs in the CI admission station after ci_admission, never in the full tick or the refill. Sources: MergeGym (arXiv 2610.04779,
# local `git merge-tree` median 0.02 s) and linux-next (all pending changes merged continuously to see conflicts early).
# Before this, a conflict surfaced only when a PR reached review dispatch, a CI slot or the merge lane, or via aged_pr_lifecycle
# (aged PRs only, at most 6 an hour). It reuses merge_conflict_to_repair, the route those places share, and builds no new one.
# shortcut: this proves a TEXT conflict with main and nothing about builds, tests or semantics (two clean merges can still break
# each other: Google's "mid-air collision"); main-moved is read from the local origin/main the station just fetched, so no gh call per PR.
# Bounds: PRs already checked at this (head, main) are skipped from the memo, a pass stops at MERGE_SWEEP_LIMIT_SECONDS or
# MERGE_SWEEP_MAX PRs, and only idle PR stages are touched. A head is sent to repair once (.merge_sweep_head); two repair rounds stop it.
MERGE_SWEEP_STAGES='["review-pending","rereview-pending","ready-to-merge"]'
merge_tree_sweep() {
  local memo="$A/merge-tree-sweep.json" prs rows id pr head branch issue u rounds rc mt checked=0 started=$SECONDS missing=""
  local max="${MERGE_SWEEP_MAX:-60}" limit="${MERGE_SWEEP_LIMIT_SECONDS:-30}" updates
  [[ "${MAIN_HEAD:-}" =~ $SHA_RE ]] || return 0
  prs="$(tick_prs 2>/dev/null)" || return 0
  [[ -s "$memo" ]] || echo '{}' > "$memo"
  # Idle units only: a unit in repair, repair-pending or a live review is already in flight. hand/ branches, session-owned PRs and
  # supervisor-owned units are not the factory's to repair; a handoff wait (hold) is checked only once a conflict is found.
  rows="$(jqf -r --slurpfile census <(printf '%s' "$prs") --slurpfile memo "$memo" --arg main "$MAIN_HEAD" --arg owned "$SESSION_OWNED_LABEL" \
      --argjson stages "$MERGE_SWEEP_STAGES" '
      ($census[0] | map({key:(.number | tostring), value:.}) | from_entries) as $c
      | .units[] | select((.pr | type) == "number" and (.stage | IN($stages[])) and (.supervisor_owned // false) == false)
      | ($c[(.pr | tostring)] // empty) as $p
      | select($p.baseRefName == "main" and ($p.headRefName | test("^agent/")) and ($p.labels | any(.name == $owned) | not))
      | select(($memo[0][(.pr | tostring)] // "") != "\($p.headRefOid) \($main)" and (.merge_sweep_head // "") != $p.headRefOid)
      | [.id, .pr, $p.headRefOid, $p.headRefName, (.issue // 0)] | @tsv' "$UNITS")" || return 0
  [[ -n "$rows" ]] || return 0
  # One batched fetch for the heads this clone lacks; everything after is local. The PR ref exists while the PR is open, so a
  # deleted or fork branch name cannot fail the whole batch; FETCH_HEAD is shared and is neither read nor written here.
  while IFS=$'\t' read -r id pr head branch issue; do
    git -C "$ROOT" cat-file -e "$head^{commit}" 2>/dev/null || missing+=" refs/pull/$pr/head"
  done <<<"$rows"
  [[ -z "$missing" ]] || timeout 60 git -C "$ROOT" fetch -q --no-write-fetch-head origin $missing 2>/dev/null || :
  updates="$(mktemp)" || return 0
  while IFS=$'\t' read -r id pr head branch issue; do
    (( checked < max && SECONDS - started < limit )) || break
    [[ ! -e "$PAUSE_FILE" ]] || break
    git -C "$ROOT" cat-file -e "$head^{commit}" 2>/dev/null || continue # not fetchable now: retry next pass, no memo
    rc=0
    mt="$(git -C "$ROOT" merge-tree --write-tree "$MAIN_HEAD" "$head" 2>/dev/null)" || rc=$?
    (( rc <= 1 )) || continue
    checked=$((checked + 1))
    if (( rc == 1 )); then
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id == $id)][0] // empty' "$UNITS")"
      rounds="$(repair_rounds_since_ruling "$u")" || continue
      if (( rounds >= 2 )); then
        say "merge-tree sweep PR#$pr conflicts with main; repair cap reached ($rounds rounds), left to the cap path"
      elif handoff_pr_waiting "$pr" "$issue"; then
        say "merge-tree sweep PR#$pr conflicts with main; handoff wait holds it"
      else
        set_unit "$id" ".merge_sweep_head=$(js "$head")" || continue
        say "merge-tree sweep PR#$pr conflicts with main $MAIN_HEAD"
        merge_conflict_to_repair "$id" "$pr" "merge-tree sweep: text conflict with main after main moved" \
          "PR 与最新 main 冲突，main 前进后的 merge-tree 预检发现（只证文本冲突）。git merge --no-edit origin/main，按两边意图解决冲突，跑受影响测试，推送。" "$head"
      fi
    fi
    printf '%s\t%s\n' "$pr" "$head $MAIN_HEAD" >> "$updates"
  done <<<"$rows"
  # The memo keeps only open PRs, so it cannot grow past the census.
  jqf -Rn --slurpfile old "$memo" --slurpfile census <(printf '%s' "$prs") '
    [inputs | split("\t") | {key:.[0], value:.[1]}] as $new
    | ($census[0] | map(.number | tostring)) as $open
    | ($old[0] | with_entries(select(.key | IN($open[])))) + ($new | from_entries)' < "$updates" > "$memo.tmp" && mv -f -- "$memo.tmp" "$memo"
  rm -f -- "$updates"
  (( checked == 0 )) || say "merge-tree sweep: checked=$checked secs=$((SECONDS - started)) main=${MAIN_HEAD:0:9}"
  return 0
}
