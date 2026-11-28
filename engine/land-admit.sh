# Shared admission checks for every landing entry point.
# Each function returns 0 to admit and 1 to refuse.
land_always_loaded_text_byte_budget_check() {
  local root="${1:-}" changed="${2:-}" path budget=8192 bytes total=0 files=''
  [[ -d "$root" ]] || { printf 'always-loaded text byte budget: repository root is unavailable\n' >&2; return 1; }
  [[ -z "$changed" ]] || grep -Eq '^(CLAUDE\.md|AGENTS\.md|AGENTS\.override\.md)$' <<<"$changed" || return 0
  for path in CLAUDE.md AGENTS.md AGENTS.override.md; do
    [[ -f "$root/$path" ]] || continue
    bytes="$(wc -c <"$root/$path" | tr -d ' ')" || return 1
    total=$((total + bytes))
    files+="${files:+ + }$path"
  done
  if (( total > budget )); then
    printf '%s is %s bytes, budget %s bytes; remove or demote lower-value text\n' "$files" "$total" "$budget" >&2
    return 1
  fi
}

land_candidate_eval_admission_check() {
  local root="${1:-}" changed="${2:-}" output map
  [[ -n "$changed" ]] || return 0
  [[ -d "$root" ]] || { printf 'paired evaluation admission: repository root is unavailable\n' >&2; return 1; }
  map="$root/engine/eval/decision-stages.sh"
  [[ -r "$map" ]] || map="$root/eval/decision-stages.sh"
  [[ -r "$map" ]] || {
    printf 'paired evaluation admission: stage mapping is unavailable\n' >&2
    return 1
  }
  if ! output="$(bash "$map" --pin <<<"$changed" 2>&1)"; then
    printf 'paired evaluation admission: candidate input is unmeasurable; leave it as an observation\n%s\n' "$output" >&2
    return 1
  fi
}

land_prompt_byte_budget_check() {
  local root="${1:-}" base="${2:-}" head="${3:-}" changed="${4:-}" table path name budget bytes map_root="${5:-${1:-}}"
  local scan_all=0
  local -a prompt_paths=()
  [[ -d "$root" ]] || { printf 'prompt byte budget: repository root is unavailable\n' >&2; return 1; }
  if [[ -n "$base" || -n "$head" ]]; then
    [[ -n "$base" && -n "$head" ]] || { printf 'prompt byte budget: both base and head are required\n' >&2; return 1; }
    changed="$(git -C "$root" diff --no-renames --name-only "$base...$head" 2>/dev/null)" \
      || { printf 'prompt byte budget: could not read the landing diff\n' >&2; return 1; }
  elif [[ -z "$changed" ]]; then
    scan_all=1
  fi
  land_always_loaded_text_byte_budget_check "$root" "$changed" || return 1
  if ! grep -q '^engine/prompts/' <<<"$changed" && (( scan_all == 0 )); then
    land_candidate_eval_admission_check "$map_root" "$changed" || return 1
    return 0
  fi
  table="$root/engine/prompts/byte-budgets.tsv"
  [[ -f "$table" ]] || { printf 'prompt byte budget: missing engine/prompts/byte-budgets.tsv\n' >&2; return 1; }
  if (( scan_all == 1 )) || grep -Fxq 'engine/prompts/byte-budgets.tsv' <<<"$changed"; then
    for path in "$root"/engine/prompts/*.md; do
      [[ -f "$path" ]] && prompt_paths+=("$path")
    done
  else
    while IFS= read -r path; do
      [[ "$path" =~ ^engine/prompts/[^/]+\.md$ && -f "$root/$path" ]] && prompt_paths+=("$root/$path")
    done <<<"$changed"
  fi
  if ((${#prompt_paths[@]} == 0)); then
    land_candidate_eval_admission_check "$map_root" "$changed"
    return $?
  fi
  for path in "${prompt_paths[@]}"; do
    name="${path##*/}"
    budget="$(awk -F '\t' -v name="$name" '$1 == name { count++; value=$2 } END { if (count == 1 && value ~ /^[0-9]+$/) print value; else exit 1 }' "$table")" \
      || { printf 'engine/prompts/%s has no unique byte budget in engine/prompts/byte-budgets.tsv\n' "$name" >&2; return 1; }
    bytes="$(wc -c <"$path" | tr -d ' ')" || return 1
    if (( bytes > budget )); then
      printf 'engine/prompts/%s is %s bytes, budget %s bytes\n' "$name" "$bytes" "$budget" >&2
      return 1
    fi
  done
  land_candidate_eval_admission_check "$map_root" "$changed" || return 1
}

land_pr_prompt_byte_budget_check() {
  local pr="$1" head_sha="$2" repo="${3:-}" files root ref tree actual_sha prompt_paths path output='' rc=0
  local -a repo_args=()
  [[ -n "$repo" ]] && repo_args=(--repo "$repo")
  files="$(gh api --paginate "${repo_args[@]}" --jq '.[] | .filename, (.previous_filename // empty)' \
    "repos/{owner}/{repo}/pulls/$pr/files?per_page=100" 2>/dev/null)" || {
    printf 'prompt byte budget: could not read PR #%s files\n' "$pr" >&2
    return 1
  }
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'prompt byte budget: repository checkout is unavailable\n' >&2
    return 1
  }
  land_candidate_eval_admission_check "$root" "$files" || return 1
  if ! grep -q '^engine/prompts/' <<<"$files" && ! grep -Eq '^(CLAUDE\.md|AGENTS\.md|AGENTS\.override\.md)$' <<<"$files"; then
    return 0
  fi
  ref="refs/zf-land-prompt-budget/$pr"
  git -C "$root" fetch -q origin "+refs/pull/$pr/head:$ref" 2>/dev/null || {
    printf 'prompt byte budget: could not fetch PR #%s head\n' "$pr" >&2
    return 1
  }
  actual_sha="$(git -C "$root" rev-parse "$ref^{commit}" 2>/dev/null)" || actual_sha=
  if [[ "$actual_sha" != "$head_sha" ]]; then
    git -C "$root" update-ref -d "$ref" 2>/dev/null || true
    printf 'prompt byte budget: PR #%s changed after its head was pinned\n' "$pr" >&2
    return 1
  fi
  tree="$(mktemp -d)" || return 1
  mkdir -p "$tree/engine/prompts" || { rc=1; output="prompt byte budget: could not stage PR #$pr prompt files"; }
  if git -C "$root" cat-file -e "$ref:engine/prompts/byte-budgets.tsv" 2>/dev/null; then
    git -C "$root" show "$ref:engine/prompts/byte-budgets.tsv" > "$tree/engine/prompts/byte-budgets.tsv" \
      || { rc=1; output="prompt byte budget: could not read PR #$pr budget table"; }
  fi
  if grep -Fxq 'engine/prompts/byte-budgets.tsv' <<<"$files"; then
    prompt_paths="$(git -C "$root" ls-tree -r --name-only "$ref" -- engine/prompts 2>/dev/null)" \
      || { rc=1; output="prompt byte budget: could not list PR #$pr prompt templates"; }
    prompt_paths="$(grep -E '^engine/prompts/[^/]+\.md$' <<<"$prompt_paths" || true)"
  else
    prompt_paths="$(grep -E '^engine/prompts/[^/]+\.md$' <<<"$files" || true)"
  fi
  for path in CLAUDE.md AGENTS.md AGENTS.override.md; do
    if git -C "$root" cat-file -e "$ref:$path" 2>/dev/null; then
      git -C "$root" show "$ref:$path" > "$tree/$path" \
        || { rc=1; output="always-loaded text byte budget: could not read PR #$pr $path"; }
    fi
  done
  while IFS= read -r path; do
    [[ "$path" =~ ^engine/prompts/[^/]+\.md$ ]] || continue
    if git -C "$root" cat-file -e "$ref:$path" 2>/dev/null; then
      git -C "$root" show "$ref:$path" > "$tree/$path" \
        || { rc=1; output="prompt byte budget: could not read PR #$pr template $path"; }
    fi
  done <<<"$prompt_paths"
  if (( rc == 0 )); then
    output="$(land_prompt_byte_budget_check "$tree" '' '' "$files" "$root" 2>&1)" || rc=$?
  fi
  rm -rf -- "$tree"
  git -C "$root" update-ref -d "$ref" 2>/dev/null || true
  if (( rc != 0 )); then
    printf '%s\n' "$output" >&2
    return "$rc"
  fi
}

land_receipt_green() {
  local receipt="${1-}"
  if [[ ! -f "$receipt" ]]; then
    printf 'refuse:receipt:missing\n' >&2
    return 1
  fi
  if [[ ! -s "$receipt" ]]; then
    printf 'refuse:receipt:empty\n' >&2
    return 1
  fi
  awk -F'\t' -v strict="${LAND_RECEIPT_STRICT:-0}" '
    {
      if (strict == 1) {
        tab = index($0, "\t")
        rc = substr($0, 1, tab - 1)
        cmd = substr($0, tab + 1)
        if (tab == 0 || rc !~ /^[0-9]+$/ || cmd == "") {
          print "malformed receipt line " NR
          bad = 1
          next
        }
      } else {
        if (NF < 2 || $1 !~ /^[0-9]+$/) next
        rc = $1
        cmd = $2
      }
      last[cmd] = rc
      n++
    }
    END {
      if (strict == 1) {
        for (cmd in last) if (last[cmd] + 0 != 0) {
          print cmd " (exit " last[cmd] ")"
          bad = 1
        }
        exit bad
      }
      if (n == 0) {
        print "refuse:receipt:no-valid-lines"
        exit 1
      }
      for (c in last) if (last[c] + 0 != 0) {
        print "refuse:receipt:failed:" c
        exit 1
      }
    }
  ' "$receipt" >&2
}

land_receipt_file() {
  local clone="${1-}" head_sha="${2-}" git_common_dir
  git_common_dir="$(git -C "$clone" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$git_common_dir" in /*) ;; *) git_common_dir="${clone%/}/$git_common_dir" ;; esac
  printf '%s/zf-test-receipts/%s\n' "${git_common_dir%/}" "$head_sha"
}

land_merge_lane_assert() {
  local status
  [[ "${ZF_COORD:-off}" == on ]] || return 0
  if [[ "${ZF_COORD_LANE:-}" != merge || -z "${ZF_COORD_LANE_OWNER:-}" ]] \
      || ! declare -F coord_assert_owned >/dev/null; then
    printf 'refuse:merge:lane-ownership\n' >&2
    return 3
  fi
  if coord_assert_owned lane-merge "$ZF_COORD_LANE_OWNER"; then return 0; else status=$?; fi
  printf 'refuse:merge:lane-ownership\n' >&2
  return "$status"
}

land_merge_pr() {
  local pr="${1-}" head_sha="${2-}" repo="" gh_rc head_json head_ref out
  local -a merge_args=() repo_args=() view_args=() api_args=()
  if [[ ! "$pr" =~ ^[0-9]+$ || ! "$pr" =~ [1-9] ]]; then
    printf 'refuse:merge:bad-pr\n' >&2
    return 64
  fi
  if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'refuse:merge:bad-head\n' >&2
    return 64
  fi
  shift 2
  merge_args=(pr merge "$pr" --squash)
  while (($#)); do
    case "$1" in
      --repo|--subject|--body)
        if (($# < 2)); then
          printf 'refuse:merge:bad-option\n' >&2
          return 64
        fi
        merge_args+=("$1" "$2")
        if [[ "$1" == --repo ]]; then
          repo="$2"
          repo_args=(--repo "$repo")
        fi
        shift 2
        ;;
      --delete-branch)
        merge_args+=("$1")
        shift
        ;;
      *)
        printf 'refuse:merge:bad-option\n' >&2
        return 64
        ;;
    esac
  done
  merge_args+=(--match-head-commit "$head_sha")
  land_pr_prompt_byte_budget_check "$pr" "$head_sha" "$repo" || return 1
  land_merge_lane_assert || return $?
  if gh "${merge_args[@]}"; then
    return 0
  else
    gh_rc=$?
  fi
  [[ "${LAND_MERGE_REST_FALLBACK:-}" == 1 ]] || return "$gh_rc"
  land_merge_lane_assert || return $?
  view_args=(pr view "$pr")
  view_args+=("${repo_args[@]}" --json headRefName)
  if ! head_json="$(gh "${view_args[@]}" 2>/dev/null)" || [[ -z "$head_json" ]]; then
    api_args=(api)
    api_args+=("${repo_args[@]}" "repos/{owner}/{repo}/pulls/$pr")
    head_json="$(gh "${api_args[@]}" 2>/dev/null)" || return 1
    head_json="$(jq -ce '{headRefName: .head.ref}' <<<"$head_json" 2>/dev/null)" || return 1
  fi
  head_ref="$(jq -er '.headRefName | select(type == "string" and length > 0)' <<<"$head_json")" || return 1
  api_args=(api)
  api_args+=("${repo_args[@]}" -X PUT "repos/{owner}/{repo}/pulls/$pr/merge" -f merge_method=squash -f "sha=$head_sha")
  land_merge_lane_assert || return $?
  if out="$(gh "${api_args[@]}" 2>&1)"; then
    api_args=(api)
    api_args+=("${repo_args[@]}" -X DELETE "repos/{owner}/{repo}/git/refs/heads/$head_ref")
    land_merge_lane_assert || return $?
    if gh "${api_args[@]}" >/dev/null 2>&1; then
      :
    fi
    return 0
  fi
  if [[ "$out" == *409* ]]; then
    if [[ "${LAND_MERGE_PR_REFUSAL:-}" == 1 ]]; then
      printf 'refusing to merge PR #%s: head moved after the gate: %s is no longer the head, not merged\n' "$pr" "$head_sha" >&2
    else
      printf 'refuse:merge:head-moved:%s is no longer the head, not merged\n' "$head_sha" >&2
    fi
  fi
  return 1
}
