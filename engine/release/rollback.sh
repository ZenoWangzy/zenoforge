release_rollback_main_hashes() {
  local repo_dir="$1" path="$2" main_ref="$3" deployed_sha="${4:-}" old_sha="${5:-}" commits blobs
  local -a refs=("$main_ref")
  [[ -z "$deployed_sha" ]] || refs+=("$deployed_sha")
  [[ -z "$old_sha" ]] || refs+=("$old_sha")
  commits="$(git -C "$repo_dir" log --format=%H "${refs[@]}" -- "$path")" || return 1
  [[ -n "$commits" ]] || { printf 'run-release: no rollback history for configured file %s\n' "$path" >&2; return 1; }
  blobs="$(while IFS= read -r commit; do
    git -C "$repo_dir" rev-parse "$commit:$path" 2>/dev/null || true
  done <<< "$commits" | sort -u)" || return 1
  [[ -n "$blobs" ]] || { printf 'run-release: no rollback versions for configured file %s\n' "$path" >&2; return 1; }
  while IFS= read -r blob; do
    git -C "$repo_dir" cat-file blob "$blob" | md5sum | cut -c1-32
  done <<< "$blobs" | sort -u
}

release_rollback_pin_remote() {
  timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=10 "$DEPLOY_HOST" "$1"
}

release_run_rollback() {
  local repo_dir="${REPO_DIR:-$ZF_REPO_DIR}" sha="${1:?release SHA required}" mode="${2:?rollback mode required}"
  local deployed_sha="${3:-}" old_sha="${4:-}" script_rel hook_rel skill_rel known_dir remote_root main_ref
  local hook_hashes skill_hashes remote_dir remote_script remote_hook remote_skill remote_main_hook remote_main_skill path
  local q_known q_script q_hook q_skill q_main_hook q_main_skill env command output rc=0
  case "$mode" in check|restore) ;; *) printf 'run-release: invalid rollback mode %s\n' "$mode" >&2; return 1 ;; esac
  [[ "$sha" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || { printf 'run-release: invalid rollback source SHA\n' >&2; return 1; }
  script_rel="$(release_config_value rollbackScriptPath)" || return 1
  hook_rel="$(release_config_value rollbackHookPath)" || return 1
  skill_rel="$(release_config_value rollbackSkillPath)" || return 1
  known_dir="$(release_config_value rollbackKnownDirectory)" || return 1
  remote_root="$(release_config_value rollbackRemoteRoot)" || return 1
  main_ref="$(release_config_value rollbackMainReference)" || return 1
  for path in "$script_rel" "$hook_rel" "$skill_rel"; do
    case "$path" in /*|*\\*|..|../*|*/../*|*/..) printf 'run-release: invalid rollback source path\n' >&2; return 1 ;; esac
  done
  [[ "$known_dir" == /* && "$remote_root" == /* ]] || { printf 'run-release: rollback remote paths must be absolute\n' >&2; return 1; }
  case "$known_dir/$remote_root" in *'/../'*|*'/..') printf 'run-release: invalid rollback remote path\n' >&2; return 1 ;; esac
  [[ -r "$repo_dir/$script_rel" ]] || { printf 'run-release: configured rollback script is not readable\n' >&2; return 1; }
  git -C "$repo_dir" cat-file -e "$sha:$hook_rel" 2>/dev/null && git -C "$repo_dir" cat-file -e "$sha:$skill_rel" 2>/dev/null || {
    printf 'run-release: rollback source files are missing from configured SHA\n' >&2
    return 1
  }
  [[ "$main_ref" =~ ^[A-Za-z0-9._/-]+$ && "$main_ref" != -* ]] \
    && git -C "$repo_dir" rev-parse --verify --quiet "${main_ref}^{commit}" >/dev/null || {
    printf 'run-release: rollback main reference is unavailable\n' >&2
    return 1
  }
  hook_hashes="$(release_rollback_main_hashes "$repo_dir" "$hook_rel" "$main_ref" "$deployed_sha" "$old_sha")" || return 1
  skill_hashes="$(release_rollback_main_hashes "$repo_dir" "$skill_rel" "$main_ref" "$deployed_sha" "$old_sha")" || return 1
  remote_dir="${remote_root%/}/rollback-${BASHPID}-${sha:0:12}"
  remote_script="$remote_dir/rollback.sh"
  remote_hook="$remote_dir/source-hook"
  remote_skill="$remote_dir/source-skill"
  remote_main_hook="$remote_dir/main-hook-hashes"
  remote_main_skill="$remote_dir/main-skill-hashes"
  printf -v q_known '%q' "$known_dir"
  printf -v q_script '%q' "$remote_script"
  printf -v q_hook '%q' "$remote_hook"
  printf -v q_skill '%q' "$remote_skill"
  printf -v q_main_hook '%q' "$remote_main_hook"
  printf -v q_main_skill '%q' "$remote_main_skill"
  release_rollback_pin_remote "umask 077; mkdir -p $(printf '%q' "$remote_dir")" || return 1
  release_rollback_pin_remote "umask 077; cat > $q_script" < "$repo_dir/$script_rel" || return 1
  git -C "$repo_dir" show "$sha:$hook_rel" | release_rollback_pin_remote "umask 077; cat > $q_hook" || return 1
  git -C "$repo_dir" show "$sha:$skill_rel" | release_rollback_pin_remote "umask 077; cat > $q_skill" || return 1
  printf '%s\n' "$hook_hashes" | release_rollback_pin_remote "umask 077; cat > $q_main_hook" || return 1
  printf '%s\n' "$skill_hashes" | release_rollback_pin_remote "umask 077; cat > $q_main_skill" || return 1
  env="CHAIN_END_HOOK=$q_hook CHAIN_END_SKILL=$q_skill CHAIN_MAIN_HOOKS=$q_main_hook CHAIN_MAIN_SKILLS=$q_main_skill"
  case "$mode" in
    check)
      command="K=$q_known; sed 's/^/KNOWN hook /' \"\$K/hook.md5\" && sed 's/^/KNOWN skill /' \"\$K/skill.md5\" && CHECK=1 $env bash $q_script"
      output="$(release_rollback_pin_remote "$command" 2>&1)" || rc=$?
      ;;
    restore)
      command="K=$q_known; sed 's/^/KNOWN hook /' \"\$K/hook.md5\" && sed 's/^/KNOWN skill /' \"\$K/skill.md5\" && { $env bash $q_script >&2; CHECK=1 $env bash $q_script; }"
      output="$(release_rollback_pin_remote "$command")" || rc=$?
      ;;
  esac
  release_rollback_pin_remote "unlink $q_script && unlink $q_hook && unlink $q_skill && unlink $q_main_hook && unlink $q_main_skill && rmdir $(printf '%q' "$remote_dir")" >/dev/null 2>&1 ||
    printf 'run-release: could not remove temporary rollback files\n' >&2
  printf '%s\n' "$output"
  return "$rc"
}
