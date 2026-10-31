#!/usr/bin/env bash
# Migration gate settings come from the target release configuration.
migration_gate_setting() {
  local file value
  file="$(zf_config_file release.json)" || return 1
  value="$(jq -er --arg key "$1" '.migration[$key] | select(type == "string" and length > 0)' "$file")" || return 1
  printf '%s\n' "$value"
}
migration_gate_renumber() {
  local pr="$1" env_name
  shift
  env_name="$(migration_gate_setting prEnvironment)" || return 1
  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  env "$env_name=$pr" GITHUB_REPOSITORY="$REPO" ZF_PACK_DIR="${ZF_PACK_DIR-}" node "$ZF_ENGINE_DIR/migration-script.mjs" renumber "$@"
}

MIGRATION_PR_HEAD_REF=""
MIGRATION_PR_HEAD_OID=""
check_agent_pr_migration_numbers() {
  local pr_number="$1" expected_head="$2" pr_json changed_files listed_files scratch checked_head rc=0 migration_path
  migration_path="$(migration_gate_setting path)" || return 2
  MIGRATION_PR_HEAD_REF=""
  MIGRATION_PR_HEAD_OID=""
  if ! pr_json="$(gh pr view "$pr_number" --repo "$REPO" \
    --json changedFiles,headRefName,headRefOid,files 2>/dev/null)"; then
    return 2
  fi
  changed_files="$(jq -r '.changedFiles // empty' <<< "$pr_json")"
  listed_files="$(jq -r '.files | length' <<< "$pr_json")"
  [[ "$changed_files" =~ ^[0-9]+$ ]] && [ "$changed_files" = "$listed_files" ] || return 2
  if ! jq -e --arg path "${migration_path%/}/" '[.files[]?.path | select(startswith($path)) | select(ltrimstr($path) | test("^[0-9]{4}_[^/]+\\.sql$"))] | length > 0' \
    <<< "$pr_json" >/dev/null; then
    return 0
  fi
  MIGRATION_PR_HEAD_REF="$(jq -r '.headRefName // empty' <<< "$pr_json")"
  MIGRATION_PR_HEAD_OID="$(jq -r '.headRefOid // empty' <<< "$pr_json")"
  [[ "$MIGRATION_PR_HEAD_REF" =~ ^[A-Za-z0-9._/-]+$ ]] \
    && [[ "$MIGRATION_PR_HEAD_OID" =~ ^[0-9a-f]{40}$ ]] || return 2
  [ -z "$expected_head" ] || [ "$MIGRATION_PR_HEAD_OID" = "$expected_head" ] || return 2

  scratch="$(mktemp -d)"
  if ! git_fetch_bounded "$REPO_DIR" main "$MIGRATION_PR_HEAD_REF" \
    || ! git -C "$REPO_DIR" worktree add -q --detach "$scratch" "origin/$MIGRATION_PR_HEAD_REF" 2>/dev/null; then
    worktree_lifecycle_finish "$scratch" "$REPO_DIR" || true
    rmdir "$scratch" 2>/dev/null || true
    return 2
  fi
  checked_head="$(git -C "$scratch" rev-parse HEAD 2>/dev/null)" || checked_head=""
  if [ "$checked_head" != "$MIGRATION_PR_HEAD_OID" ]; then
    rc=2
  elif (cd "$scratch" && migration_gate_renumber "$pr_number" --check); then
    rc=0
  else
    rc=$?
  fi
  worktree_lifecycle_finish "$scratch" "$REPO_DIR" || rc=2
  rmdir "$scratch" 2>/dev/null || true
  case "$rc" in
    0|1) return "$rc" ;;
    *) return 2 ;;
  esac
}

merge_agent_pr_migration_gate() {
  local issue="$1" pr_number="$2" expected_head="$3" check_rc rebase_rc=0
  if check_agent_pr_migration_numbers "$pr_number" "$expected_head"; then
    return 0
  else
    check_rc=$?
  fi
  case "$check_rc" in
    1)
      if is_on_hold "$issue"; then
        MERGE_GATE_FAILURE_KIND="on-hold"
        MERGE_GATE_FAILURE_REASON="#$issue is on-hold -- refusing migration rebase"
        return 1
      fi
      rebase_agent_pr_onto_main "$MIGRATION_PR_HEAD_REF" "$MIGRATION_PR_HEAD_OID" "$pr_number" \
        || rebase_rc=$?
      case "$rebase_rc" in
        0)
          MERGE_GATE_FAILURE_KIND="migration-renumbered"
          MERGE_GATE_FAILURE_REASON="Migration numbers were renumbered after rebase; CI must pass on the new PR head"
          ;;
        1)
          MERGE_GATE_FAILURE_KIND="migration-content-conflict"
          MERGE_GATE_FAILURE_REASON="Migration renumber required a rebase, but it hit a content conflict; the branch was left unchanged"
          ;;
        *)
          MERGE_GATE_FAILURE_KIND="migration-rebase"
          MERGE_GATE_FAILURE_REASON="Migration renumber rebase failed during fetch, tool execution, or push"
          ;;
      esac
      return 1
      ;;
    *)
      MERGE_GATE_FAILURE_KIND="migration-check"
      MERGE_GATE_FAILURE_REASON="could not verify migration numbering against the PR head and open reservations"
      return 1
      ;;
  esac
}

# pack_rebase_hook <scratch-worktree> <pr_number> -- run by rebase_agent_pr_onto_main after a clean rebase onto origin/main and
# before the push: assign migration numbers, verify them, commit the result. Non-zero = the rebase result is not pushed.
pack_rebase_hook() {
  local scratch="$1" pr_number="${2:-}" name email message name_env email_env
  name="$(migration_gate_setting gitUserName)" || return 1
  email="$(migration_gate_setting gitUserEmail)" || return 1
  message="$(migration_gate_setting commitMessage)" || return 1
  name_env="$(migration_gate_setting gitUserNameEnvironment)" || return 1
  email_env="$(migration_gate_setting gitUserEmailEnvironment)" || return 1
  [[ "$name_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$email_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  name="${!name_env:-$name}"
  email="${!email_env:-$email}"
  (cd "$scratch" && migration_gate_renumber "$pr_number") \
    && (cd "$scratch" && migration_gate_renumber "$pr_number" --check) \
    && git -C "$scratch" add -A \
    && { git -C "$scratch" diff --cached --quiet \
      || git -C "$scratch" -c user.name="$name" \
        -c user.email="$email" \
        commit -m "$message"; }
}

# fruit_migration_order_gate <pr> [head]
#
# Drizzle applies a Migration journal entry only when its `when` is later than the
# last applied migration, so a lower-numbered migration merged after a higher
# one can be skipped in production forever. Refuses while another
# open, non-draft PR adds a lower-numbered Migration, or while this PR's
# new journal entry is not later than every `when` on main. Shared by
# merge_agent_pr and the night tick's green-PR merge. Fails closed.
fruit_migration_order_gate() {
  local pr="$1" head="${2:-}" out rc=0
  out="$(node "$ZF_ENGINE_DIR/check-fruit-migration-order.mjs" --merge-gate --pr "$pr" \
    ${head:+--head "$head"} --repo "$REPO" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  MERGE_GATE_FAILURE_KIND="migration-order"
  MERGE_GATE_FAILURE_REASON="$(sed -n 's/^migration-order: //p' <<< "$out" | paste -sd ';' -)"
  [ -n "$MERGE_GATE_FAILURE_REASON" ] \
    || MERGE_GATE_FAILURE_REASON="Migration order check failed (status=$rc): ${out:0:300}"
  return 1
}
