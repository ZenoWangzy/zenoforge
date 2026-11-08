# ---------- deterministic resolver for hot shared files: a repeat merge conflict skips the LLM repair ----------
# issue-4706 spent 2.06M fresh tokens, most of it on repeated repairs of conflicts in files two PRs always touch together
# (the Drizzle journal, an append-only catalog). Called from merge_conflict_to_repair when the unit already had a
# merge-conflict and EVERY conflicting path is in a class below; any other conflict still goes to repair untouched.
#   journal  <migration.path>/meta/_journal.json, migration.path from the target's release.json: the one directory the pack's
#            renumber script owns. Take main's journal, re-append this PR's own new entries, then the pack's renumber hook
#            (pack_rebase_hook) assigns the next free number; without that hook nothing is resolved. Any other
#            migrations/ journal is not resolved: a merged journal whose files nobody renumbered is the 2026-11 schema-parity shape.
#   union    one-line-per-entry append-only lists (lessons/CATALOG.md): keep both sides' lines (git merge-file --union).
#            lessons/RULES.md stays out: its entries span lines and a union there could drop or split a lesson.
# The result is a merge commit (no rebase, no force) pushed with a lease on the observed head; the approval is cleared.
# shortcut: a text resolver proves nothing about semantics, so the new head is re-reviewed and CI runs again; upgrade when
# one of these files gets a structural merge driver in the target repo.
# Bounds: first conflict goes to repair as before (CONFLICT_AUTO_MIN_PRIOR=1), at most CONFLICT_AUTO_MAX resolutions per
# unit, a failed attempt falls through to repair at once and leaves the clone at the observed head.
CONFLICT_UNION_RE="${CONFLICT_UNION_RE:-(^|/)lessons/CATALOG\.md$}"
CONFLICT_AUTO_MIN_PRIOR="${CONFLICT_AUTO_MIN_PRIOR:-1}"
CONFLICT_AUTO_MAX="${CONFLICT_AUTO_MAX:-3}"

# The target's migration directory, read the way the real hook reads it (lib.sh's config, release.json migration.path).
conflict_migration_path() ( # → path, or nothing when the target configures no migration gate
  REPO_DIR="$ROOT"; source "$SCHEDULER_AGENT_LIB" >/dev/null 2>&1 || exit 1
  jq -er '.migration.path | select(type == "string" and length > 0)' "$(zf_config_file release.json)" 2>/dev/null
)
conflict_hot_class() { # path → journal | union | (nothing); needs CONFLICT_JOURNAL_PATH from conflict_auto_resolve
  # shortcut: root migrations/ journal is not resolved because pack_rebase_hook does not renumber its files; extend once the hook renumbers root migrations/.
  if [[ -n "${CONFLICT_JOURNAL_PATH:-}" && "$1" == "${CONFLICT_JOURNAL_PATH%/}/meta/_journal.json" ]]; then echo journal
  elif [[ "$1" =~ $CONFLICT_UNION_RE ]]; then echo union; fi
}

# main's journal plus the entries this PR added to the merge base's journal (placeholder idx/when: the renumber hook fixes them).
conflict_journal_merge() { # base pr main (files) → merged journal on stdout
  jq -n --slurpfile b "$1" --slurpfile p "$2" --slurpfile m "$3" '
    ($b[0].entries | map(.tag)) as $old
    | [$p[0].entries[] | select(.tag as $t | $old | index($t) | not)] as $add
    | $m[0] | (.entries | map(.idx) | max) as $ix | (.entries | map(.when) | max) as $wh
    | .entries += [range(0; $add | length) as $i | $add[$i] | .idx = ($ix + 1 + $i) | .when = (if .when > $wh then .when else $wh + 1 + $i end)]'
}

# The pack hook lives in lib.sh's migration gate; a subshell keeps lib.sh out of the scheduler (see lib-bridge.sh).
conflict_pack_hook() ( # dir pr
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"; source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  declare -F pack_rebase_hook >/dev/null || return 1
  pack_rebase_hook "$1" "$2"
)

conflict_resolve_files() { # dir paths(newline list) → 0 = every unmerged path resolved and staged
  local dir="$1" p class b o t
  b="$(mktemp)" o="$(mktemp)" t="$(mktemp)" || return 1
  while IFS= read -r p; do
    class="$(conflict_hot_class "$p")"
    git -C "$dir" show ":2:$p" > "$o" 2>/dev/null && git -C "$dir" show ":3:$p" > "$t" 2>/dev/null || { rm -f -- "$b" "$o" "$t"; return 1; }
    if [[ "$class" == union ]]; then
      git -C "$dir" show ":1:$p" > "$b" 2>/dev/null || : > "$b" # add/add: empty base keeps both sides
      git merge-file --union "$o" "$b" "$t" >/dev/null 2>&1 || { rm -f -- "$b" "$o" "$t"; return 1; }
      cp -- "$o" "$dir/$p"
    elif [[ "$class" == journal ]]; then
      git -C "$dir" show ":1:$p" > "$b" 2>/dev/null || { rm -f -- "$b" "$o" "$t"; return 1; }
      conflict_journal_merge "$b" "$o" "$t" > "$dir/$p" || { rm -f -- "$b" "$o" "$t"; return 1; }
    else
      rm -f -- "$b" "$o" "$t"; return 1
    fi
    git -C "$dir" add -- "$p" || { rm -f -- "$b" "$o" "$t"; return 1; }
  done <<<"$2"
  rm -f -- "$b" "$o" "$t"
}

conflict_auto_resolve() { # id pr head paths(newline list of every conflicting path) → 0 = resolved and pushed, 1 = fall through to repair
  local id="$1" pr="$2" head="$3" paths="$4" p class classes="" branch dir new_head unmerged
  [[ "$head" =~ $SHA_RE && -n "$paths" ]] || return 1
  (( $(unit_retries "$id" merge-conflict) >= CONFLICT_AUTO_MIN_PRIOR )) || return 1
  (( $(unit_retries "$id" conflict-auto-resolved) < CONFLICT_AUTO_MAX )) || return 1
  [[ "$(unit_field "$id" '.supervisor_owned // false')" != true ]] || return 1
  branch="$(unit_field "$id" '.branch // empty')"; [[ "$branch" =~ ^agent/[A-Za-z0-9._/-]+$ ]] || return 1
  [[ -n "${CONFLICT_JOURNAL_PATH+x}" ]] || CONFLICT_JOURNAL_PATH="$(conflict_migration_path)" || CONFLICT_JOURNAL_PATH=""
  while IFS= read -r p; do
    class="$(conflict_hot_class "$p")"; [[ -n "$class" ]] || return 1
    [[ "$classes" == *"$class"* ]] || classes+="${classes:+,}$class"
  done <<<"$paths"
  dir="$(ensure_clone "$id" "$branch" 1 "$head")" || return 1
  [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$head" ]] || return 1
  if git -C "$dir" merge --no-commit --no-ff -q refs/remotes/origin/main >/dev/null 2>&1; then
    git -C "$dir" merge --abort >/dev/null 2>&1 || git -C "$dir" reset -q --hard "$head"; return 1 # no conflict now: not ours to push
  fi
  unmerged="$(git -C "$dir" diff --name-only --diff-filter=U)"
  if [[ "$(sort -u <<<"$unmerged")" != "$(sort -u <<<"$paths")" ]] || ! conflict_resolve_files "$dir" "$unmerged"; then
    git -C "$dir" merge --abort >/dev/null 2>&1; git -C "$dir" reset -q --hard "$head"; return 1
  fi
  if ! git -C "$dir" commit -q -m "Merge origin/main (deterministic conflict resolution: $classes)" \
    || { [[ "$classes" == *journal* ]] && ! conflict_pack_hook "$dir" "$pr" >/dev/null 2>&1; } \
    || [[ -n "$(git -C "$dir" status --porcelain)" ]] \
    || ! git -C "$dir" push -q --force-with-lease="refs/heads/$branch:$head" origin "HEAD:refs/heads/$branch" 2>/dev/null; then
    git -C "$dir" merge --abort >/dev/null 2>&1; git -C "$dir" reset -q --hard "$head"
    say "conflict-auto-resolve PR#$pr ($classes) failed; falling through to repair"
    return 1
  fi
  new_head="$(git -C "$dir" rev-parse HEAD)"
  tick_prs_changed
  set_unit "$id" "$(hist conflict-auto-resolved "PR#$pr $classes: $(paste -sd, - <<<"$paths"); head ${head:0:9} -> ${new_head:0:9}") | .approved_sha=null | .conflict_update_head=$(js "$new_head") | (if .stage == \"review-pending\" then . else .stage=\"rereview-pending\" end)"
  say "merge-conflict-auto-resolved unit=$id pr=$pr classes=$classes head=$head new_head=$new_head main_sha=${MAIN_HEAD:-unknown}"
}
