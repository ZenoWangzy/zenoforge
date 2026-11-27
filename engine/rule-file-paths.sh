rule_manifest_aliases=()

rule_manifest_path_matches() {
  local path="$1" rule_file="$2"
  if [[ "$rule_file" == */ ]]; then
    [[ "$path" == "$rule_file"* ]]
  else
    [[ "$path" == "$rule_file" ]]
  fi
}

rule_manifest_mandatory_paths() {
  jq -er '
    if .schema == "zf-rule-files/v1" and (.mandatory | type == "object")
    then .mandatory | keys[] | strings
    else error("manifest must be zf-rule-files/v1 with a mandatory object") end' "$1"
}

rule_manifest_path_aliases() {
  local rule_file="$1" repo_dir="$2" pack_rel="${ZF_PACK_REL:-engine}" config_root="${ZF_CONFIG_ROOT-}"
  local config_relative="" pack_candidate config_candidate config_path
  rule_manifest_aliases=("$rule_file")
  case "$rule_file" in
    "$pack_rel"/*) config_relative="${rule_file#"$pack_rel"/}" ;;
    engine/*) config_relative="${rule_file#engine/}" ;;
  esac
  [[ -n "$config_relative" ]] || return 0
  pack_candidate="$pack_rel/$config_relative"
  [[ "$pack_candidate" == "$rule_file" ]] || rule_manifest_aliases+=("$pack_candidate")
  [[ -n "$config_root" ]] || return 0
  [[ "$config_root" == /* ]] || config_root="$repo_dir/$config_root"
  config_candidate="${config_root%/}/$config_relative"
  case "$config_candidate" in
    "$repo_dir"/*) ;;
    *) return 0 ;;
  esac
  if [[ "$config_relative" == */ ]]; then
    [[ -d "$config_candidate" ]] || return 0
  else
    [[ -f "$config_candidate" ]] || return 0
  fi
  config_path="${config_candidate#"$repo_dir"/}"
  if [[ "$config_path" != "$rule_file" && "$config_path" != "$pack_candidate" ]]; then
    rule_manifest_aliases+=("$config_path")
  fi
}
