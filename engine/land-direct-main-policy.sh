source "$land_script_dir/rule-file-paths.sh"

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
  local base="$1" head="$2" actor="${ZF_AGENT_NAME-}"
  case "$actor" in
    supervisor) printf supervisor; return 0 ;;
    ''|head) ;;
    *) printf '%s' "$actor"; return 0 ;;
  esac
  if syntax_only_landing "$base" "$head" && land_direct_main_judging_landing "$base" "$head"; then
    printf supervisor
  else
    printf '%s' "${actor:-unit}"
  fi
}
