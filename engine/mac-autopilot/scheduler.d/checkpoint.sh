scheduler_unit_restore() {
  local id="${1:-}" values="${2:-}" keys="${3:-}"
  [[ -n "$id" && -n "$values" && -n "$keys" ]] || return 2
  jq -e --arg id "$id" 'type == "object" and (.units | type == "array") and any(.units[]; .id == $id)' \
    "$UNITS" >/dev/null 2>&1 || return 1
  jq -e --argjson values "$values" --argjson keys "$keys" \
    '($values | type == "object") and ($keys | type == "array")
      and all($keys[]; type == "string") and ((($values | keys) - $keys) | length) == 0' \
    <<<"{}" >/dev/null 2>&1 || return 1
  units_update --arg id "$id" --argjson values "$values" --argjson keys "$keys" \
    '.units |= map(if .id == $id then (reduce $keys[] as $key (. ; del(.[$key])) | . + $values) else . end)'
}
