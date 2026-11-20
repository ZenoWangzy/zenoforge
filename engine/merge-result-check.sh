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

# Run the merge result's focused suites before the caller merges the PR. The
# synthetic commit lets the existing selector and tests see the exact tree.
merge_result_focused_tests() { # repo-dir pr-number expected-head
  local repo_dir="$1" pr_number="$2" expected_head="$3"
  local suffix refs_base refs_head base_sha head_sha merge_output result_tree merge_sha
  local temp_dir worktree selected suite suite_log latest_main failure='' rc index=0
  local result=1
  local -a suites=() suite_command=()

  MERGE_RESULT_FOCUSED_FAILURE=''
  if [[ ! "$pr_number" =~ ^[1-9][0-9]*$ || ! "$expected_head" =~ ^[0-9a-f]{40,64}$ ]]; then
    MERGE_RESULT_FOCUSED_FAILURE='PR number or pinned head is invalid'
    return 1
  fi
  suffix="${BASHPID:-$$}-$pr_number"
  refs_base="refs/zf/merge-validation/$suffix/main"
  refs_head="refs/zf/merge-validation/$suffix/head"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zf-merge-result.XXXXXX")" || {
    MERGE_RESULT_FOCUSED_FAILURE='could not create the merge-result test directory'
    return 1
  }
  worktree="$temp_dir/tree"
  mkdir -p "$temp_dir/tmp"

  while :; do
    if ! git -C "$repo_dir" fetch --quiet --no-tags origin \
      "+refs/heads/main:$refs_base" "+refs/pull/$pr_number/head:$refs_head"; then
      failure='could not fetch origin/main and the pinned PR head for merge-result validation'
      break
    fi
    base_sha="$(git -C "$repo_dir" rev-parse -q --verify "$refs_base" 2>/dev/null)" || {
      failure='could not resolve origin/main for merge-result validation'
      break
    }
    head_sha="$(git -C "$repo_dir" rev-parse -q --verify "$refs_head" 2>/dev/null)" || {
      failure='could not resolve the PR head for merge-result validation'
      break
    }
    if [[ "$head_sha" != "$expected_head" ]]; then
      failure="PR head moved before merge-result validation (expected $expected_head, fetched $head_sha)"
      break
    fi
    if ! merge_output="$(git -C "$repo_dir" merge-tree --write-tree "$base_sha" "$head_sha" 2>&1)"; then
      failure="could not build the merge result for PR #$pr_number: ${merge_output:0:240}"
      break
    fi
    result_tree="${merge_output%%$'\n'*}"
    if [[ ! "$result_tree" =~ ^[0-9a-f]{40,64}$ ]]; then
      failure="git merge-tree returned no result tree for PR #$pr_number"
      break
    fi
    if ! merge_sha="$(GIT_AUTHOR_NAME='Zenoforge merge validation' \
      GIT_AUTHOR_EMAIL='merge-validation@users.noreply.github.com' \
      GIT_COMMITTER_NAME='Zenoforge merge validation' \
      GIT_COMMITTER_EMAIL='merge-validation@users.noreply.github.com' \
      git -C "$repo_dir" commit-tree "$result_tree" -p "$base_sha" -p "$head_sha" \
        -m "Merge PR #$pr_number for focused validation")"; then
      failure="could not create a local merge commit for PR #$pr_number"
      break
    fi
    if ! git -C "$repo_dir" worktree add --quiet --detach "$worktree" "$merge_sha"; then
      failure="could not check out the merge result for PR #$pr_number"
      break
    fi
    if [[ -d "$repo_dir/node_modules" && ! -e "$worktree/node_modules" ]] \
      && ! ln -s "$repo_dir/node_modules" "$worktree/node_modules"; then
      failure="could not link the existing dependencies into the merge result for PR #$pr_number"
      break
    fi
    if ! selected="$(cd -- "$worktree" && node engine/focused-test-paths.mjs \
      --range "$base_sha" "$merge_sha" 2>&1)"; then
      failure="focused-test-paths failed on the merge result for PR #$pr_number: ${selected:0:240}"
      break
    fi
    if [[ -n "$selected" ]]; then mapfile -t suites <<< "$selected"; fi
    for suite in "${suites[@]}"; do
      case "$suite" in
        *.test.sh|test-*.sh) suite_command=(bash "$suite") ;;
        *.test.mjs) suite_command=(node --test --test-concurrency=1 "$suite") ;;
        *.test.py) suite_command=(python3 "$suite") ;;
        *) failure="unsupported focused suite on merge result: $suite"; break ;;
      esac
      suite_log="$temp_dir/suite-$index.log"
      printf 'merge-result: running focused suite %s\n' "$suite" >&2
      if (cd -- "$worktree" && LC_ALL=C TMPDIR="$temp_dir/tmp" \
        timeout -k 10 3600 "${suite_command[@]}") > "$suite_log" 2>&1; then
        index=$((index + 1))
        continue
      else
        rc=$?
        failure="focused suite $suite failed (status=$rc)"
        printf 'merge-result: FAILED suite=%s status=%s\n' "$suite" "$rc" >&2
        tail -n 30 "$suite_log" >&2 || :
        break
      fi
    done
    [[ -z "$failure" ]] || break
    if ! git -C "$repo_dir" fetch --quiet --no-tags origin "+refs/heads/main:$refs_base"; then
      failure='could not recheck origin/main after merge-result validation'
      break
    fi
    latest_main="$(git -C "$repo_dir" rev-parse -q --verify "$refs_base" 2>/dev/null)" || {
      failure='could not resolve origin/main after merge-result validation'
      break
    }
    if [[ "$latest_main" != "$base_sha" ]]; then
      failure="origin/main advanced from ${base_sha:0:12} to ${latest_main:0:12} during merge-result validation"
      break
    fi
    result=0
    break
  done

  if [[ -d "$worktree" ]] && ! git -C "$repo_dir" worktree remove --force "$worktree" >/dev/null 2>&1; then
    [[ "$result" != 0 ]] || failure="could not remove the merge-result worktree for PR #$pr_number"
    result=1
  fi
  rm -rf -- "$temp_dir"
  git -C "$repo_dir" update-ref -d "$refs_head" >/dev/null 2>&1 || :
  git -C "$repo_dir" update-ref -d "$refs_base" >/dev/null 2>&1 || :
  if ((result == 0)); then
    printf 'merge-result: passed %s focused suite(s) base=%s\n' "$index" "${base_sha:0:12}" >&2
    return 0
  fi
  MERGE_RESULT_FOCUSED_FAILURE="${failure:-merge-result validation failed}"
  printf 'merge-result: refused PR #%s: %s\n' "$pr_number" "$MERGE_RESULT_FOCUSED_FAILURE" >&2
  return 1
}
