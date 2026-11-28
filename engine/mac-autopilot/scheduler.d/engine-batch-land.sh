engine_batch_land() {
  local repo script merge_root limit max_prs mtimeout deadline fd list n head draft mergeable try out rc landed=0 skipped=0
  [[ "$(jqf -r '.engine_batch_land.enabled // false' <<<"$CFG")" == true ]] || return 0
  repo="$(jqf -r '.engine_batch_land.repo // "ZenoWangzy/zenoforge"' <<<"$CFG")"
  script="$(jqf -r '.engine_batch_land.merge_script // empty' <<<"$CFG")"
  limit="$(jqf -r '.engine_batch_land.limit_seconds // 240' <<<"$CFG")"; [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=240
  max_prs="$(jqf -r '.engine_batch_land.max_per_pass // 5' <<<"$CFG")"; [[ "$max_prs" =~ ^[1-9][0-9]*$ ]] || max_prs=5
  mtimeout="$(jqf -r '.engine_batch_land.merge_timeout_seconds // 560' <<<"$CFG")"; [[ "$mtimeout" =~ ^[1-9][0-9]*$ ]] || mtimeout=560
  if [[ ! -f "$script" ]]; then
    say "engine batch land: merge_script ${script:-unset} is missing; nothing landed"
    return 0
  fi
  merge_root="$(git -C "$(dirname -- "$script")" rev-parse --show-toplevel 2>/dev/null)" || merge_root=''
  if [[ -z "$merge_root" ]]; then
    say "engine batch land: merge_script $script is outside a Git checkout; nothing landed"
    return 0
  fi
  exec {fd}>"$A/.engine-batch-land.lock" || return 0
  if ! flock -n "$fd"; then exec {fd}>&-; say "engine batch land busy: pass skipped"; return 0; fi
  deadline=$((SECONDS + limit))
  if ! list="$(gh pr list -R "$repo" --state open --base main --limit 50 --json number,headRefOid,isDraft,mergeable 2>/dev/null)" \
    || ! jqf -e 'type == "array"' <<<"$list" >/dev/null 2>&1; then
    exec {fd}>&-; say "engine batch land: could not list open PRs of $repo"; return 0
  fi
  while IFS=$'\t' read -r n head draft mergeable; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    if (( SECONDS >= deadline || landed >= max_prs )); then say "engine batch land: pass limit reached before PR#$n; it waits for the next pass"; break; fi
    if [[ "$draft" == true ]]; then say "engine batch land PR#$n skipped: draft"; skipped=$((skipped + 1)); continue; fi
    # GitHub recomputes mergeability after each merge: UNKNOWN is read again, a few seconds apart.
    for try in 1 2 3 4 5 6; do
      [[ "$mergeable" == UNKNOWN ]] || break
      read -r -t "${ENGINE_BATCH_LAND_UNKNOWN_WAIT:-5}" <> <(:) || :
      mergeable="$(gh pr view "$n" -R "$repo" --json mergeable -q .mergeable 2>/dev/null)" || mergeable=UNKNOWN
    done
    if [[ "$mergeable" != MERGEABLE ]]; then say "engine batch land PR#$n skipped: mergeable=${mergeable:-unknown}"; skipped=$((skipped + 1)); continue; fi
    rc=0; out="$(cd "$merge_root" && timeout -k 10 "$mtimeout" bash "$script" "$n" 2>&1)" || rc=$?
    if (( rc == 0 )); then
      landed=$((landed + 1)); say "engine batch land PR#$n merged (head ${head:0:12})"
    else
      skipped=$((skipped + 1)); say "engine batch land PR#$n skipped: merge-pr rc=$rc: $(grep -m1 -E 'refusing|error|failed' <<<"$out" | cut -c1-200)"
    fi
  done < <(jqf -r 'sort_by(.number) | .[] | [.number, .headRefOid, (.isDraft | tostring), .mergeable] | @tsv' <<<"$list")
  exec {fd}>&-
  say "engine batch land done landed=$landed skipped=$skipped"
}
