#!/usr/bin/env bash
# Landing check: engine/**/*.test.sh in a PR must carry the test-env bootstrap. Sourced by tools/merge-pr.sh, which supplies merge_pr_root, merge_pr_view and merge_pr_refuse.
# Same scope as run-engine-tests.sh (every engine/**/*.test.sh). A suite without the bootstrap runs nothing in its shard: #972 reached main red that way.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/engine/lib.d/gh-key-cache.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/merge-pr-view.sh"
merge_pr_red_receipt_ci_superseded() {
  local pr="$1" head_sha="$2" bad="$3" line first_red details count url
  [[ -n "$bad" ]] || return 1
  while IFS= read -r line; do [[ "$line" =~ ^.+\ \(exit\ [1-9][0-9]*\)$ ]] || return 1; done <<<"$bad"
  first_red="${bad%%$'\n'*}"
  details="$(merge_pr_ci_green_check_count "$pr" "$head_sha" false true)" || return 1
  IFS=$'\t' read -r count url <<<"$details"
  [[ "$count" =~ ^[1-9][0-9]*$ && "$url" =~ ^https://[^[:space:]]+$ ]] || return 1
  printf 'merge-pr: receipt: local receipt superseded by CI %s (%s checks green at %.12s; local red: %s)\n' "$url" "$count" "$head_sha" "$first_red" >&2
}

merge_pr_export_suites() { # pr dir paths...: copy the PR head's version of each path that exists there
  local pr="$1" dir="$2" root ref="refs/zf-merge-pr/$1" path
  shift 2
  root="$(merge_pr_root)" || return 1
  git -C "$root" fetch -q origin "+pull/$pr/head:$ref" || return 1
  for path in "$@"; do
    git -C "$root" cat-file -e "$ref:$path" 2>/dev/null || continue
    mkdir -p "$dir/$(dirname "$path")" || return 1
    git -C "$root" show "$ref:$path" >"$dir/$path" || return 1
  done
}
merge_pr_bootstrap_ok() {
  local pr="$1" root tree path out bare='' files_bad hint rc=0
  local view files
  local -a suites=() present=()
  view="$(merge_pr_view "$pr" body,files,commits)" && files="$(jq -r '.files[].path' <<<"$view")" || {
    merge_pr_refuse "$pr" 'could not read PR files for the test bootstrap check'
    return 1
  }
  while IFS= read -r path; do
    [[ "$path" == engine/*.test.sh ]] && suites+=("$path")
  done <<<"$files"
  (( ${#suites[@]} > 0 )) || return 0
  root="$(merge_pr_root)" || {
    merge_pr_refuse "$pr" 'no git checkout: cannot run the test bootstrap check'
    return 1
  }
  tree="$(mktemp -d)" || return 1
  if ! merge_pr_export_suites "$pr" "$tree" "${suites[@]}"; then
    rm -rf -- "$tree"
    merge_pr_refuse "$pr" 'could not read the PR head test suites for the bootstrap check'
    return 1
  fi
  for path in "${suites[@]}"; do
    [[ -f "$tree/$path" ]] && present+=("$path")
  done
  if (( ${#present[@]} > 0 )); then
    out="$(cd "$tree" && bash "$root/engine/test-bootstrap-check.sh" "${present[@]}" 2>&1)" || rc=$?
    bare="$(cd "$tree" && bash "$root/engine/test-exit-trap-check.sh" "${present[@]}")"
  fi
  rm -rf -- "$tree"
  if (( rc == 0 )) && [[ -n "$bare" ]]; then
    merge_pr_refuse "$pr" "test suite EXIT trap must name \"\$test_env_root\": $(paste -sd' ' - <<<"$bare")"
    return 1
  fi
  (( rc == 0 )) && return 0
  files_bad="$(sed -n 's/^invalid test bootstrap: //p' <<<"$out" | paste -sd' ' -)"
  hint='source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"'
  merge_pr_refuse "$pr" "test suite lacks the test-env bootstrap: ${files_bad:-$out}; add this line after set -euo pipefail: $hint"
}
