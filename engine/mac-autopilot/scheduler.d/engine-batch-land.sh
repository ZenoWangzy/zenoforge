# ---------- Zenoforge engine batch lander (ruling zenoforge-batch-land-2026-11-08), hosted by the merge station ----------
# Each merge-station pass (merge_entry) lands every ready engine PR of the Zenoforge repo through tools/merge-pr.sh: open, not a draft, MERGEABLE,
# and a test receipt for its head that is green (tools/test-receipt.sh records one per head in the clone where the author ran the tests). The prior-art
# section, failed checks, the size ratchet and the other landing checks stay merge-pr.sh's own: a refusal is logged with its first line and the lander
# goes on to the next PR. No human step and no per-PR rerun. Off unless engine_batch_land.enabled is true in the config; "merge_script" (the path of
# tools/merge-pr.sh in a Zenoforge clone; tools/ is not part of the pinned engine) must be set too.
# One lander at a time: the pass holds an exclusive flock (.engine-batch-land.lock) and a second pass skips. A PR merged by another session meanwhile is
# safe: merge-pr.sh's merge call fails on a merged PR and the next listing no longer shows it.
# shortcut: receipts are searched in the sibling clones under clones_dir (one git call per clone and PR), upgrade if the clone count makes a pass slow.
engine_batch_receipt_clone() { # head clones_dir -> the clone whose receipt for that head is non-empty and whose last run of every command is rc 0
  local clone gd
  for clone in "$2"/*/; do
    gd="$(git -C "$clone" rev-parse --git-common-dir 2>/dev/null)" || continue
    case "$gd" in /*) ;; *) gd="${clone%/}/$gd" ;; esac
    [[ -s "$gd/zf-test-receipts/$1" ]] || continue
    awk -F'\t' 'NF >= 2 && $1 ~ /^[0-9]+$/ { last[$2] = $1; n++ } END { bad = (n == 0); for (c in last) if (last[c] + 0 != 0) bad = 1; exit bad }' \
      "$gd/zf-test-receipts/$1" && { printf '%s\n' "${clone%/}"; return 0; }
  done
  return 1
}
engine_batch_land() {
  local repo clones script limit max_prs mtimeout deadline fd list n head draft mergeable try clone out rc landed=0 skipped=0
  [[ "$(jqf -r '.engine_batch_land.enabled // false' <<<"$CFG")" == true ]] || return 0
  repo="$(jqf -r '.engine_batch_land.repo // "ZenoWangzy/zenoforge"' <<<"$CFG")"
  clones="$(jqf -r '.engine_batch_land.clones_dir // empty' <<<"$CFG")"; clones="${clones:-$HOME/.zenoforge/clones}"
  script="$(jqf -r '.engine_batch_land.merge_script // empty' <<<"$CFG")"
  limit="$(jqf -r '.engine_batch_land.limit_seconds // 240' <<<"$CFG")"; [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=240
  max_prs="$(jqf -r '.engine_batch_land.max_per_pass // 5' <<<"$CFG")"; [[ "$max_prs" =~ ^[1-9][0-9]*$ ]] || max_prs=5
  mtimeout="$(jqf -r '.engine_batch_land.merge_timeout_seconds // 560' <<<"$CFG")"; [[ "$mtimeout" =~ ^[1-9][0-9]*$ ]] || mtimeout=560
  if [[ ! -f "$script" || ! -d "$clones" ]]; then
    say "engine batch land: merge_script ${script:-unset} or clones_dir $clones is missing; nothing landed"
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
    if ! clone="$(engine_batch_receipt_clone "$head" "$clones")"; then
      say "engine batch land PR#$n skipped: no green test receipt for head ${head:0:12}"; skipped=$((skipped + 1)); continue
    fi
    rc=0; out="$(cd "$clone" && timeout -k 10 "$mtimeout" bash "$script" "$n" 2>&1)" || rc=$?
    if (( rc == 0 )); then
      landed=$((landed + 1)); say "engine batch land PR#$n merged (head ${head:0:12}, receipt in ${clone##*/})"
    else
      skipped=$((skipped + 1)); say "engine batch land PR#$n skipped: merge-pr rc=$rc: $(grep -m1 -E 'refusing|error|failed' <<<"$out" | cut -c1-200)"
    fi
  done < <(jqf -r 'sort_by(.number) | .[] | [.number, .headRefOid, (.isDraft | tostring), .mergeable] | @tsv' <<<"$list")
  exec {fd}>&-
  say "engine batch land done landed=$landed skipped=$skipped"
}
