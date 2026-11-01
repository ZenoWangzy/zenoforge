#!/usr/bin/env bash
# Release failure attribution. Print "issue commit" only when one tracked
# merge touched the exact failed migration or production image.

# Target-repo specifics come from state/deploy-culprit.json through the config seam ({ migration_path: "dir/%s.sql",
# infrastructure_signatures: [...] }): the target's config root first, then pack values retained during migration;
# without either the generic defaults apply (migrations at migrations/<stage>.sql, only the built-in infrastructure signatures).
deploy_culprit_pack_value() {
  local file
  file="$(zf_config_file state/deploy-culprit.json 2>/dev/null)" || file=/dev/null
  jq -r -n --slurpfile pack "$file" "(\$pack[0] // {}) | $1"
}
# shellcheck disable=SC2153 # REPO is set by lib.sh before this file is sourced.
deploy_culprit() {
  local repo="$1" range="$2" kind="$3" detail="$4" path="" image=""
  local sha subject changed commits owner="" culprit="" matches=0
  case "$kind" in
    migration)
      # Missing credentials and SQL privilege/connection failures describe
      # the host role, not the SQL author's product behavior.
      [[ "$detail" != *MIGRATION_DATABASE_URL* ]] || return 1
      [[ "$detail" != *code=42501* && "$detail" != *SQLSTATE\ 42501* ]] || return 1
      [[ "$detail" =~ stage=([A-Za-z0-9_-]+)-[0-9]+[[:space:]]code=([A-Za-z0-9_-]+) ]] || return 1
      case "${BASH_REMATCH[2]}" in
        08*|28*|42501|wrong-role|missing|unknown) return 1 ;;
      esac
      path="$(deploy_culprit_pack_value '.migration_path // "migrations/%s.sql"')"
      path="${path//%s/${BASH_REMATCH[1]}}"
      ;;
    service) image="$detail" ;;
    *) return 1 ;;
  esac
  commits="$(git -C "$repo" log --first-parent --format='%H%x09%s' --reverse "$range")" || return 1
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    if [ -n "$path" ]; then
      changed="$(git -C "$repo" diff --name-only "$sha^1" "$sha" -- "$path")" || return 1
      [ "$changed" = "$path" ] || continue
    else
      changed="$(cd "$repo" && node "$repo/scripts/release/changed-images.mjs" "$sha^" "$sha")" || return 1
      grep -Fxq "$image" <<< "$changed" || continue
    fi
    [[ "$subject" =~ ^fix\(\#([0-9]+)\): ]] || return 1
    owner="${BASH_REMATCH[1]}"
    culprit="$sha"
    matches=$((matches + 1))
  done <<< "$commits"
  [ "$matches" -eq 1 ] || return 1
  printf '%s %s\n' "$owner" "$culprit"
}

# Return the only service named by a single readback failure. Generic Compose,
# registry and proxy failures remain unattributed.
deploy_failed_service() {
  local log="$1" svc container found="" count=0
  [ "$(grep -c '^readback:' <<< "$log" || true)" -eq 1 ] || return 1
  [[ "$log" != *'docker inspect failed'* && "$log" != *'docker image inspect failed'* ]] || return 1
  for svc in "${SERVICES[@]}"; do
    container="$(container_for "$svc")"
    if [[ "$log" == *"readback: $container "* ]] || [[ "$log" == *"readback: docker inspect failed for $container"* ]]; then
      found="$svc"
      count=$((count + 1))
    fi
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$found"
}

# Acceptance-regression attribution (spec #4355 f3): a batch acceptance names
# the regressed catalog feature IDs; exactly one cohort ticket may own them.
# feature_map lines are "issue<TAB>merge-sha<TAB>comma,ids" (run-release.sh's
# release_batch_feature_map). Prints "issue commit" like deploy_culprit, or
# refuses when zero or several tickets own the regressed features.
deploy_acceptance_culprit() {
  local feature_map="$1" regressions="$2"
  local line issue merge_sha ids f owner="" culprit=""
  local -A regressed=() owners=()
  while IFS= read -r f; do
    [[ "$f" =~ ^[A-Za-z0-9._-]+$ ]] && regressed["$f"]=1
  done < <(sed -n 's/^ACCEPTANCE REGRESSION \([^:]*\):.*/\1/p' <<< "$regressions")
  [ "${#regressed[@]}" -gt 0 ] || return 1
  while IFS=$'\t' read -r issue merge_sha ids; do
    [[ "$issue" =~ ^[0-9]+$ ]] || continue
    [[ "$merge_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || continue
    local IFS=','
    for f in $ids; do
      [ -n "${regressed[$f]:-}" ] || continue
      owners["$issue"]=1
      owner="$issue" culprit="$merge_sha"
    done
  done <<< "$feature_map"
  [ "${#owners[@]}" -eq 1 ] || return 1
  printf '%s %s\n' "$owner" "$culprit"
}

deploy_failure_class() {
  local kind="$1" detail="$2"
  if [[ "$detail" == *MIGRATION_DATABASE_URL* || "$detail" == *code=42501* || "$detail" == *SQLSTATE\ 42501* || "$detail" == *'docker inspect failed'* || "$detail" == *'docker image inspect failed'* || "$detail" == *'pg_dump'* || "$detail" == *'docker compose up'* ]]; then
    echo infrastructure
    return 0
  fi
  local signature
  while IFS= read -r signature; do
    [[ -n "$signature" && "$detail" == *"$signature"* ]] && { echo infrastructure; return 0; }
  done < <(deploy_culprit_pack_value '.infrastructure_signatures[]?')
  echo ambiguous
}

deploy_supervisor_notice() {
  local detail="${1//$'\n'/ }"
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] deploy-culprit supervisor notice: $detail" >&2
  else
    supervisor_inbox_append deploy-culprit "$detail" || return 1
  fi
}

# Prepare a normal product revert PR from a throwaway worktree. `kind` is
# `deploy` (the release rollback) or `main` (the Postsubmit bisect). Never
# mutate the live pipeline checkout. The merge sweeper adds the exact revert
# trailer to its squash message after required PR checks pass.
open_deploy_revert_pr() {
  local issue="$1" culprit="$2" failed="$3" kind="${4:-deploy}" red_run_id="${5:-}"
  local wt branch body url parents result=0 existing_pr reused_branch=0 title
  [ "$DRY_RUN" != 1 ] || return 1
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$culprit" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "$kind" in deploy|main) ;; *) return 64 ;; esac
  branch="agent/revert-$kind-$issue-${culprit:0:12}"
  existing_pr="$(gh pr list --repo "$REPO" --head "$branch" --state open --json number \
    -q '.[0].number // empty' 2>/dev/null)" || existing_pr=""
  if [[ "$existing_pr" =~ ^[1-9][0-9]*$ ]]; then
    printf 'https://github.com/%s/pull/%s\n' "$REPO" "$existing_pr"
    return 0
  fi
  wt="$(mktemp -d "$AGENT_HOME/$kind-revert.XXXXXX")" || return 1
  body="$(mktemp "$AGENT_HOME/$kind-revert-body.XXXXXX")" || { rmdir "$wt"; return 1; }
  rmdir "$wt"
  case "$kind" in
    deploy)
      title="Revert fix(#$issue) after failed production deploy"
      cat > "$body" <<EOF
Automated revert after production release $failed failed verification for this change.

This reverts commit $culprit.

Issue #$issue returns to implementation. Other merged issues remain queued for release.
EOF
      ;;
    main)
      title="Revert fix(#$issue) after red main Postsubmit"
      cat > "$body" <<EOF
Automated revert after main's Postsubmit went red and the bisect named this commit.

main Postsubmit run $red_run_id failed at $failed; the same SHA rerun once stayed
red (not flaky); the bisect over the window since the last green Postsubmit
named $culprit, whose subject carries fix(#$issue).

This reverts commit $culprit.

Issue #$issue returns to implementation with the bisect evidence on its
timeline. Other merged issues remain queued for release.
EOF
      ;;
  esac
  git -C "$REPO_DIR" worktree add -q --detach "$wt" origin/main || result=1
  if [ "$result" -eq 0 ]; then
    # Reuse a branch left by an interrupted PR-create call. The exact revert
    # trailer prevents an unrelated same-name branch from entering the lane.
    if git -C "$wt" fetch -q origin "refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null; then
      if git -C "$wt" log -1 --format=%B "origin/$branch" | grep -Fxq "This reverts commit $culprit."; then
        git -C "$wt" switch -q -C "$branch" "origin/$branch" || result=1
        [ "$result" -ne 0 ] || reused_branch=1
      else
        result=1
      fi
    else
      git -C "$wt" switch -q -c "$branch" || result=1
    fi
  fi
  if [ "$result" -eq 0 ] && [ "$reused_branch" -eq 0 ]; then
    read -r -a parents <<< "$(git -C "$wt" rev-list --parents -n 1 "$culprit")"
    if [ "${#parents[@]}" -eq 3 ]; then
      git -C "$wt" -c user.name='the product Agent' -c user.email='zenoforge-agent@users.noreply.github.com' revert --no-edit -m 1 "$culprit" || result=1
    elif [ "${#parents[@]}" -eq 2 ]; then
      git -C "$wt" -c user.name='the product Agent' -c user.email='zenoforge-agent@users.noreply.github.com' revert --no-edit "$culprit" || result=1
    else
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    guarded_write git -C "$wt" push origin "HEAD:refs/heads/$branch" || result=1
  fi
  if [ "$result" -eq 0 ]; then
    url="$(guarded_write gh pr create --repo "$REPO" --base main --head "$branch" \
      --title "$title" --body-file "$body")" || result=1
    [ -n "${url:-}" ] || result=1
  fi
  git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -f "$body"
  [ "$result" -eq 0 ] || return 1
  printf '%s\n' "$url"
}

# Direct-main pipeline landings use the same exact git-revert trailer as the PR
# path, but publish with main's fast-forward compare-and-swap. A concurrent
# landing is fetched and retried; a revert conflict stays manual.
open_direct_main_revert() {
  local issue="$1" culprit="$2" red_sha="$3" run_id="$4"
  local attempt base wt revert_sha status message
  local max_attempts="${ZF_MAIN_RED_DIRECT_REVERT_ATTEMPTS:-3}"
  [ "$DRY_RUN" != 1 ] || return 1
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$culprit" =~ ^[0-9a-f]{40}$ \
    && "$red_sha" =~ ^[0-9a-f]{40}$ && "$run_id" =~ ^[1-9][0-9]*$ \
    && "$max_attempts" =~ ^[1-9][0-9]*$ ]] || return 2

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    git_fetch_bounded "$REPO_DIR" main >/dev/null 2>&1 || return 1
    base="$(git -C "$REPO_DIR" rev-parse --verify 'origin/main^{commit}')" || return 1
    if ! git -C "$REPO_DIR" merge-base --is-ancestor "$culprit" "$base" 2>/dev/null; then
      echo "main-red-bisect: direct revert refused; culprit $culprit is no longer on main" >&2
      return 2
    fi
    revert_sha="$(git -C "$REPO_DIR" log origin/main --format='%H' --fixed-strings \
      --grep="This reverts commit $culprit." | head -n 1)"
    if [[ "$revert_sha" =~ ^[0-9a-f]{40}$ ]]; then
      printf '%s\n' "$revert_sha"
      return 0
    fi

    wt="$(mktemp -d "$AGENT_HOME/main-red-direct-revert.XXXXXX")" || return 1
    rmdir "$wt" || return 1
    if ! git -C "$REPO_DIR" worktree add -q --detach "$wt" "$base"; then
      rm -rf -- "$wt"
      return 1
    fi
    local -a parents=()
    read -r -a parents <<< "$(git -C "$wt" rev-list --parents -n 1 "$culprit")"
    if [ "${#parents[@]}" -eq 3 ]; then
      if ! git -C "$wt" -c user.name='the product Agent' -c user.email='zenoforge-agent@users.noreply.github.com' \
          revert --no-edit -m 1 "$culprit" >/dev/null 2>&1; then
        git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
        echo "main-red-bisect: direct revert conflict for culprit=$culprit issue=#$issue; leaving it for arbitration" >&2
        return 2
      fi
    elif [ "${#parents[@]}" -eq 2 ]; then
      if ! git -C "$wt" -c user.name='the product Agent' -c user.email='zenoforge-agent@users.noreply.github.com' \
          revert --no-edit "$culprit" >/dev/null 2>&1; then
        git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
        echo "main-red-bisect: direct revert conflict for culprit=$culprit issue=#$issue; leaving it for arbitration" >&2
        return 2
      fi
    else
      git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
      echo "main-red-bisect: direct revert refused unsupported parent count for culprit=$culprit; leaving it for arbitration" >&2
      return 2
    fi
    if ! git -C "$wt" -c user.name='the product Agent' -c user.email='zenoforge-agent@users.noreply.github.com' \
        commit --amend --no-edit --trailer "Refs: #$issue" --trailer "Pipeline-Suite-Run: $run_id" >/dev/null; then
      git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
      return 1
    fi
    message="$(git -C "$wt" show -s --format=%B HEAD)" || message=""
    if ! grep -Fxq "This reverts commit $culprit." <<< "$message"; then
      git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
      return 1
    fi
    revert_sha="$(git -C "$wt" rev-parse HEAD)" || revert_sha=""
    if [[ ! "$revert_sha" =~ ^[0-9a-f]{40}$ ]]; then
      git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
      return 1
    fi
    if guarded_write git -C "$wt" push origin HEAD:refs/heads/main >/dev/null 2>&1; then
      git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
      echo "main-red-bisect: direct revert landed issue=#$issue culprit=$culprit revert=$revert_sha red=$red_sha run=$run_id" >&2
      printf '%s\n' "$revert_sha"
      return 0
    else
      status=$?
    fi
    git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
    if ((attempt < max_attempts)); then
      echo "main-red-bisect: main advanced or push failed during direct revert attempt=$attempt/$max_attempts exit=$status; retrying from its current tip" >&2
    fi
  done
  echo "main-red-bisect: direct revert did not land after $max_attempts compare-and-swap attempts for culprit=$culprit" >&2
  return 1
}
