#!/usr/bin/env bash

# Check Node files changed by head against the tree Git would produce when merging it into base.
merge_result_node_check() { # repo-dir base-rev head-rev
  local repo_dir="$1" base_rev="$2" head_rev="$3"
  local merge_output result_tree merge_base changed_paths temp_dir path extension temp_file check_output syntax_line failed=0

  merge_output="$(git -C "$repo_dir" merge-tree --write-tree "$base_rev" "$head_rev" 2>/dev/null)" || return 0
  result_tree="${merge_output%%$'\n'*}"
  merge_base="$(git -C "$repo_dir" merge-base "$base_rev" "$head_rev" 2>/dev/null)" || return 0
  changed_paths="$(git -C "$repo_dir" diff --name-only --diff-filter=AM "$merge_base" "$head_rev" -- '*.mjs' '*.cjs' 2>/dev/null)" || return 0
  [[ -n "$changed_paths" ]] || return 0
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zf-merge-result-check.XXXXXX")" || return 0

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    extension="${path##*.}"
    temp_file="$temp_dir/check.$extension"
    # Deleted in the merge result (base removed it): nothing to parse.
    git -C "$repo_dir" show "$result_tree:$path" > "$temp_file" 2>/dev/null || continue
    if check_output="$(node --check "$temp_file" 2>&1)"; then
      continue
    fi
    syntax_line="$(grep -m 1 'SyntaxError:' <<<"$check_output" || true)"
    printf '%s: %s\n' "$path" "$syntax_line" >&2
    failed=1
  done <<< "$changed_paths"

  rm -rf -- "$temp_dir"
  (( failed )) || printf 'merge_result_node_check: ok %s file(s) base=%s head=%s\n' "$(grep -c . <<<"$changed_paths")" \
    "$(git -C "$repo_dir" rev-parse --short=12 "$base_rev" 2>/dev/null || printf '%s' "$base_rev")" \
    "$(git -C "$repo_dir" rev-parse --short=12 "$head_rev" 2>/dev/null || printf '%s' "$head_rev")" >&2
  return "$failed"
}
