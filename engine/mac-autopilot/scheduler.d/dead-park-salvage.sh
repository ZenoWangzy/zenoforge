dead_park_guarded_push() { ( source "$SCHEDULER_AGENT_LIB" && guarded_write git -C "$1" push -q origin "$2:refs/heads/$3" ); }

dead_park_salvage_worktree() { # unit-id worktree -> comma-separated refs; push failures go to stderr
  local id="$1" wt="$2" stamp base remote_branches status stash_list stash_ref stash_index sha ref err tmp_index snapshot_rc
  local -a refs=()
  stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
  base="salvage/$id-$stamp"
  remote_branches="$(git -C "$wt" branch -r --contains HEAD 2>&1)" || { printf 'could not inspect remote branches: %s\n' "$remote_branches" >&2; return 1; }
  if [[ -z "$remote_branches" ]]; then
    sha="$(git -C "$wt" rev-parse HEAD 2>&1)" || { printf 'could not read HEAD: %s\n' "$sha" >&2; return 1; }
    ref="$base"
    err="$(dead_park_guarded_push "$wt" "$sha" "$ref" 2>&1)" || { printf 'push refs/heads/%s failed: %s\n' "$ref" "${err:-git push failed}" >&2; return 1; }
    refs+=("refs/heads/$ref")
  fi
  status="$(git -C "$wt" status --porcelain 2>&1)" || { printf 'could not inspect worktree status: %s\n' "$status" >&2; return 1; }
  if [[ -n "$status" ]]; then
    tmp_index="$(mktemp)" || { printf 'could not create temporary index for dirty worktree\n' >&2; return 1; }
    sha="$(GIT_INDEX_FILE="$tmp_index" git -C "$wt" read-tree HEAD 2>&1 && GIT_INDEX_FILE="$tmp_index" git -C "$wt" add -A 2>&1 && GIT_INDEX_FILE="$tmp_index" git -C "$wt" stash create 2>&1)"
    snapshot_rc=$?
    rm -f "$tmp_index"
    (( snapshot_rc == 0 )) || { printf 'git stash create failed: %s\n' "$sha" >&2; return 1; }
    if [[ ! "$sha" =~ ^[[:xdigit:]]{40,64}$ ]]; then
      printf 'git stash create did not produce a commit for dirty worktree\n' >&2
      return 1
    fi
    ref="$base-dirty"
    err="$(dead_park_guarded_push "$wt" "$sha" "$ref" 2>&1)" || { printf 'push refs/heads/%s failed: %s\n' "$ref" "${err:-git push failed}" >&2; return 1; }
    refs+=("refs/heads/$ref")
  fi
  stash_list="$(git -C "$wt" stash list --format='%gd' 2>&1)" || { printf 'could not list stashes: %s\n' "$stash_list" >&2; return 1; }
  while IFS= read -r stash_ref; do
    [[ -n "$stash_ref" ]] || continue
    stash_index="${stash_ref#stash@\{}"; stash_index="${stash_index%\}}"
    sha="$(git -C "$wt" rev-parse "$stash_ref" 2>&1)" || { printf 'could not read %s: %s\n' "$stash_ref" "$sha" >&2; return 1; }
    ref="$base-stash$stash_index"
    err="$(dead_park_guarded_push "$wt" "$sha" "$ref" 2>&1)" || { printf 'push refs/heads/%s failed: %s\n' "$ref" "${err:-git push failed}" >&2; return 1; }
    refs+=("refs/heads/$ref")
  done <<<"$stash_list"
  local IFS=,
  printf '%s\n' "${refs[*]}"
}

dead_park_salvage_notice() { # unit-id comma-separated refs
  local id="$1" refs="$2"
  say "dead-park salvage unit=$id refs=$refs"
  ( source "$SCHEDULER_AGENT_LIB" && supervisor_inbox_append_once "dead-park-salvage:$id" "dead-park-salvage unit=$id refs=$refs" ) >/dev/null 2>&1 || true
}

dead_park_cap_issue_create() { # unit-id pr → auto-file the missing issue and send one repair pass
  local id="$1" pr="$2" detail title branch body url issue
  detail="$(gh pr view "$pr" --json title,body,headRefName 2>/dev/null)" || return 1
  jqf -e 'type == "object" and (.title | type == "string") and (.body == null or (.body | type == "string"))' <<<"$detail" >/dev/null || return 1
  title="$(jqf -r '.title' <<<"$detail")"; branch="$(jqf -r '.headRefName // empty' <<<"$detail")"
  body="$(printf 'Automatically filed for capped PR #%s (branch %s).\n\n## PR intent\n%s\n\n%s' \
    "$pr" "${branch:-unknown}" "${title:-untitled}" "$(jqf -r '(.body // "")[0:2000]' <<<"$detail")")"
  url="$(scheduler_auto_filed_issue_create --title "Continue work from PR #$pr: ${title:-untitled}" --body "$body" --label ready-for-agent 2>/dev/null)" || return 1
  issue="${url##*/}"; [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  set_unit "$id" "$(hist supervisor-requeue "budget park repair pass: missing issue filed as #$issue from PR #$pr") | .issue=$issue | .stage=\"repair-pending\" | .note=null | del(.parked_reason,.unpark_condition)" \
    && say "supervisor budget-park repair pass unit=$id issue=#$issue pr=#$pr"
}

dead_park_exit_candidates() { # PR census → id<TAB>exit-class
  jqf -r --slurpfile census <(printf '%s' "$1") --arg owned "$SESSION_OWNED_LABEL" \
    --arg re "$SUPERVISOR_CAP_PARK_RESULT_RE" --argjson cap "${SUPERVISOR_ARBITER_UNIT_CAP:-4}" \
    --argjson since "$(($(date +%s) - 86400))" '
    [$census[0][] | select(any(.labels[]?; .name == $owned)) | .number] as $claimed
    | [$census[0][] | .number] as $open_prs
    | .units[] | (.history // []) as $h
    | ($h | map(select(.stage != "supervisor-cap-default")) | last // {}) as $l
    | select(.awaiting_release_pending == null and (.supervisor_owned // false) == false and (.hold_handoff_waiting // false) == false
        and ((.pr | type) != "number" or (.pr as $p | $claimed | index($p)) == null)
        and ((.stage == "parked" and all($h[]; .stage != "dead-park-exit" or (((.at // "") | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // 0)) < $since))
              and ((.parked_reason == "repair-breaker" and $l.stage == "repair-breaker")
                or ((.parked_reason | IN("supervisor-budget", "ticket-stop-loss")) and ($l.stage | IN("supervisor-budget-park", "supervisor-cap-triage-park", "supervisor-requeue-failed")))
                or (.parked_reason == "supervisor-budget" and any($h[]; .stage == "supervisor-cap-default")))
          or (.stage == "supervisor-review" and .recut_reopened_at != null and (.issue | type) == "number"
              and ([$h[] | select(.stage == "supervisor-arbiter")] | length) >= $cap))
    | (if .stage == "supervisor-review" then "reopened-cap-review"
       elif .parked_reason == "repair-breaker" and $l.stage == "repair-breaker" then "repair-breaker"
       elif (.parked_reason | IN("supervisor-budget", "ticket-stop-loss")) and ($l.stage | IN("supervisor-budget-park", "supervisor-cap-triage-park", "supervisor-requeue-failed")) then
         (if any($h[]; .stage == "supervisor-cap-default") then "cap-default"
          elif $l.stage == "supervisor-budget-park" and (($l.result // "") | test($re)) and
              (.pr as $p | $open_prs | index($p) != null) and
              (any($h[]; .stage == "supervisor-requeue" and ((.result // "") | startswith("budget park repair pass:"))) | not) then "budget-park-repair"
          elif ($l.stage | IN("supervisor-budget-park", "supervisor-requeue-failed")) and (($l.result // "") | test($re) | not) then "budget-park"
          else empty end)
       else empty end) as $class
    | [.id, $class] | @tsv' "$UNITS"
}
