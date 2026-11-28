source "$land_script_dir/rule-file-paths.sh"

refuse_skip_ci_test_references() {
  local range="$1" commit subject changed_file basename grep_status test_file
  local matches_file
  local -a test_files=()
  local commits
  commits="$(git rev-list --reverse "$range")" || return 1
  [[ -n "$commits" ]] || return 0
  matches_file="$(mktemp "${TMPDIR:-/tmp}/zf-land-skip-ci-tests.XXXXXX")" || return 1
  while IFS= read -r commit; do
    subject="$(git show -s --format=%s "$commit")" || { rm -f -- "$matches_file"; return 1; }
    [[ "${subject,,}" == '[skip ci]'* ]] || continue
    while IFS= read -r -d '' changed_file; do
      basename="${changed_file##*/}"
      if git grep -z -I -l -F -e "$changed_file" -e "$basename" "$commit" -- \
        ':(glob)**/*.test.*' ':(glob)**/tests/**' > "$matches_file"; then
        mapfile -d '' -t test_files < "$matches_file"
        printf 'land-direct-main: refusing [skip ci] commit=%s changed file %s is referenced by test files:\n' \
          "$commit" "$changed_file" >&2
        for test_file in "${test_files[@]}"; do
          printf '  %s\n' "${test_file#"$commit":}" >&2
        done
        printf 'land-direct-main: next step: land without [skip ci] (PR or CI-running commit) instead\n' >&2
        rm -f -- "$matches_file"
        return 1
      else
        grep_status=$?
        if ((grep_status != 1)); then
          printf 'land-direct-main: could not check [skip ci] test references for commit=%s changed file=%s\n' \
            "$commit" "$changed_file" >&2
          rm -f -- "$matches_file"
          return "$grep_status"
        fi
      fi
    done < <(git diff-tree --root --no-commit-id --name-only --no-renames -r -z "$commit")
  done <<< "$commits"
  rm -f -- "$matches_file"
}

syntax_only_landing() {
  local base="$1" head="$2" pack_rel="${ZF_PACK_REL:-engine}" path found=0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    found=1
    case "$path" in packages/*|infra/*|deploy/*|migrations/*) return 1 ;; esac
    case "$path" in
      *.md|docs/*|lessons/*|"$pack_rel"/state/*.json|.zenoforge/state/hand-priority.json|.zenoforge/state/incident-guards.json|.zenoforge/state/incident-guards.d/*.json|\
        "$pack_rel"/prompts/*|.zenoforge/prompts/*|\
        "$pack_rel"/mac-autopilot/config.template.json|.zenoforge/mac-autopilot/config.template.json|.agents/skills/*) ;;
      *) land_direct_main_judging_path "$path" || return 1 ;;
    esac
  done < <(git diff --name-only --no-renames "$base...$head")
  (( found == 1 ))
}

land_direct_main_judging_path() {
  local path="$1" rule_file manifest_path repo_dir
  local mandatory_list
  mandatory_list="$(rule_manifest_mandatory_paths "$land_script_dir/state/rule-files.json")" || return 1
  repo_dir="$(git rev-parse --show-toplevel)" || return 1
  while IFS= read -r rule_file; do
    [[ -n "$rule_file" ]] || continue
    rule_manifest_path_aliases "$rule_file" "$repo_dir"
    for manifest_path in "${rule_manifest_aliases[@]}"; do
      rule_manifest_path_matches "$path" "$manifest_path" && return 0
    done
  done <<< "$mandatory_list"
  return 1
}

land_direct_main_judging_landing() {
  local base="$1" head="$2" path
  while IFS= read -r path; do
    land_direct_main_judging_path "$path" && return 0
  done < <(git diff --name-only --no-renames "$base...$head")
  return 1
}

land_direct_main_rule_actor() {
  local actor="${ZF_AGENT_NAME-}" branch
  case "$actor" in
    supervisor) printf supervisor; return 0 ;;
    ''|head) ;;
    *) printf '%s' "$actor"; return 0 ;;
  esac
  branch="$(git branch --show-current 2>/dev/null || true)"
  if [[ -n "$branch" ]]; then
    printf 'unit:%s' "$branch"
  else
    printf unit
  fi
}
