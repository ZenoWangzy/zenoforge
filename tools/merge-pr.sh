#!/usr/bin/env bash
# Run the CI-equivalent local suites for this exact HEAD, record their exit
# codes under .git, then merge only if GitHub still reports the tested SHA.
set -uo pipefail

# Must match the shard matrix in .github/workflows/engine-tests.yml.
MERGE_PR_ENGINE_SHARDS=8
MERGE_PR_MAX_PARALLEL=4

merge_pr_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

merge_pr_result_dir() {
  local repo="$1" git_dir
  git_dir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)" || return 1
  case "$git_dir" in
    /*) ;;
    *) git_dir="$repo/$git_dir" ;;
  esac
  printf '%s/zenoforge-merge-pr\n' "$git_dir"
}

merge_pr_result_file() {
  local dir
  dir="$(merge_pr_result_dir "$1")" || return 1
  printf '%s/%s.json\n' "$dir" "$2"
}

merge_pr_receipt_file() {
  local repo="$1" git_dir
  git_dir="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$git_dir" in
    /*) ;;
    *) git_dir="$repo/$git_dir" ;;
  esac
  printf '%s/zf-test-receipts/%s\n' "$git_dir" "$2"
}

merge_pr_refuse() {
  printf 'refusing to merge PR #%s: %s\n' "$1" "$2" >&2
  return 1
}

merge_pr_join_checks() {
  local separator='' check_name
  for check_name in "$@"; do
    printf '%s%s' "$separator" "$check_name"
    separator=', '
  done
}

merge_pr_result_is_green() {
  local result_file="$1" sha="$2"
  jq -e --arg sha "$sha" '
    .sha == $sha
    and .green == true
    and .cli_exit_code == 0
    and (.engine_shards | type == "array"
      and length == 8
      and ([.[].shard] | sort == [0,1,2,3,4,5,6,7])
      and all(.[]; .exit_code == 0))
  ' "$result_file" >/dev/null 2>&1
}

# Ruling zenoforge-limited-allow-research-first-2026-11-05: a PR body must cite
# researched prior art. PRs that touch only test files are exempt.
merge_pr_prior_art_ok() {
  local pr="$1" view body section
  if ! view="$(merge_pr_view "$pr" body,files,commits 2>/dev/null)" || ! jq -e '
      (.body | type == "string") and (.files | type == "array"
        and all(.[]; (.path | type) == "string"))' <<<"$view" >/dev/null 2>&1; then
    merge_pr_refuse "$pr" 'could not read the PR body and file list as JSON'
    return 1
  fi
  # A reused branch name can turn a new PR into someone's old commits (#413).
  if jq -e '(.commits[-1].committedDate // null) as $at
      | $at != null and (now - ($at | fromdateiso8601)) > 86400' <<<"$view" >/dev/null 2>&1; then
    merge_pr_refuse "$pr" 'PR head commit is over 24 hours old: check the branch is yours, then rebase it'
    return 1
  fi
  # shortcut: test-file naming is a path heuristic, tighten if a non-test file matches it.
  if jq -e '(.files | length) > 0 and all(.files[].path;
      test("(^|/)(tests?|__tests__|fixtures)/") or test("\\.(test|spec)\\.[^/]+$"))' \
      <<<"$view" >/dev/null; then
    return 0
  fi
  body="$(jq -r '.body' <<<"$view" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  section="$(awk '/^##[ \t]+prior-art[ \t]*$/ {on=1; next}
    on && /^##?[ \t]/ {on=0}
    on' <<<"$body")"
  if ! grep -Eq '^##[[:space:]]+prior-art[[:space:]]*$' <<<"$body"; then
    merge_pr_refuse "$pr" 'PR body has no "## prior-art" section (see ruling zenoforge-limited-allow-research-first-2026-11-05)'
    return 1
  fi
  if ! grep -Eq 'https?://[^[:space:])>]+|^no external prior art:[[:space:]]*[^[:space:]]' <<<"$section"; then
    merge_pr_refuse "$pr" '"## prior-art" needs a source URL or a line "no external prior art: <reason>"'
    return 1
  fi
}

# A merge must not follow a failed test: tools/test-receipt.sh records each test
# command's exit code for the exact HEAD it ran at, and the merge needs every
# command's last recorded run green. A Markdown-only PR (the quick-land path)
# has no test run to prove, and a green full-suite result for the same SHA
# (merge_pr_main) is itself a receipt.
merge_pr_ci_green_check_count() {
  local pr="$1" head_sha="$2" success_only="${3:-false}" view count files path
  view="$(gh pr view "$pr" --json headRefOid,statusCheckRollup 2>/dev/null)" || view="$(merge_pr_rollup_rest "$pr" 2>/dev/null)" || return 1
  files="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/files" -q '.[].filename' 2>/dev/null)" || return 1
  [[ -n "$files" ]] || return 1
  while IFS= read -r path; do
    case "$path" in
      .github/*|tools/run-engine-tests.sh|.zenoforge/ci.json) return 1 ;;
      '') return 1 ;;
    esac
  done <<<"$files"
  # headRefOid anchors the rollup to this commit; GitHub CheckRuns have no per-check SHA.
  count="$(jq -er --arg sha "$head_sha" --arg strict "$success_only" --argjson shards "$MERGE_PR_ENGINE_SHARDS" '
    def check_run_time: .startedAt // .completedAt;
    def completed_success:
      if .__typename == "CheckRun" then
        .status == "COMPLETED"
        and (if $strict == "true" then .conclusion == "SUCCESS"
          else (.conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL") end)
      elif .__typename == "StatusContext" then .state == "SUCCESS" and $strict == "false"
      else false end;
    def required_check($need):
      .__typename == "CheckRun"
      and (.workflowName | type == "string" and length > 0)
      and .workflowName == (if $need == "cli" then "cli-tests" else "engine-tests" end)
      and .name == $need and .status == "COMPLETED" and .conclusion == "SUCCESS";
    . as $view
    | ($view.statusCheckRollup // null) as $checks
    | select($view.headRefOid == $sha)
    | select($checks | type == "array" and length > 0)
    | ([$checks[] | select(.__typename == "CheckRun" and check_run_time != null)]
      | group_by([.workflowName, .name])
      | map(max_by(check_run_time))) as $newest_check_runs
    | ([$checks[] | select(.__typename != "CheckRun" or check_run_time == null)]) as $single_checks
    | ($newest_check_runs + $single_checks) as $current_checks
    | select(all($current_checks[]; completed_success))
    | (["cli"] + [range(0;$shards) | "suites (\(.))"]) as $required
    | select(all($required[]; . as $need | any($current_checks[]; required_check($need))))
    | $checks | length
  ' <<<"$view" 2>/dev/null)" || return 1
  printf '%s\n' "$count"
}

# `gh pr view --json <fields>` for body,files,commits or headRefName. When GraphQL refuses (rate limit),
# REST builds the same JSON: body, files[].path, commits[].committedDate, headRefName.
merge_pr_view() {
  local pr="$1" fields="$2" out meta files commits
  if out="$(gh pr view "$pr" --json "$fields" 2>/dev/null)" && [[ -n "$out" ]]; then
    printf '%s\n' "$out"; return 0
  fi
  meta="$(gh api "repos/{owner}/{repo}/pulls/$pr" 2>/dev/null)" || return 1
  case "$fields" in
    headRefName) jq -ce '{headRefName: .head.ref}' <<<"$meta" ;;
    body,files,commits)
      files="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/files?per_page=100" 2>/dev/null)" || return 1
      commits="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/commits?per_page=100" 2>/dev/null)" || return 1
      files="$(jq -cs '[.[][] | {path: .filename}]' <<<"$files")" || return 1
      commits="$(jq -cs '[.[][] | {oid: .sha, messageHeadline: (.commit.message | split("\n")[0]), committedDate: .commit.committer.date}]' <<<"$commits")" || return 1
      jq -cn --argjson m "$meta" --argjson f "$files" --argjson c "$commits" '{body: ($m.body // ""), files: $f, commits: $c}' ;;
    *) return 1 ;;
  esac
}

merge_pr_test_receipt_ok() {
  local pr="$1" view head_sha root result_file='' receipt bad
  if ! view="$(merge_pr_view "$pr" body,files,commits 2>/dev/null)" \
    || ! jq -e '.files | type == "array" and length > 0' <<<"$view" >/dev/null 2>&1; then
    merge_pr_refuse "$pr" 'could not read the PR file list for the test receipt'
    return 1
  fi
  if jq -e 'all(.files[].path; test("\\.md$"))' <<<"$view" >/dev/null 2>&1; then
    return 0
  fi
  head_sha="$(merge_pr_head_sha "$pr")" || {
    merge_pr_refuse "$pr" 'could not read the PR head for the test receipt'
    return 1
  }
  root="$(merge_pr_root)" || {
    merge_pr_refuse "$pr" 'run this helper inside a Git checkout so test receipts can be found'
    return 1
  }
  if result_file="$(merge_pr_result_file "$root" "$head_sha")" \
    && [[ -e "$result_file" || -L "$result_file" ]]; then
    if merge_pr_result_is_green "$result_file" "$head_sha"; then
      printf 'merge-pr: receipt: local\n' >&2
      return 0
    fi
    if [[ -f "$result_file" ]] && jq -e --arg sha "$head_sha" '
      .sha == $sha and (.green == false
        or .cli_exit_code != 0
        or any(.engine_shards[]?; .exit_code != 0))
    ' "$result_file" >/dev/null 2>&1; then
      merge_pr_refuse "$pr" "full local suites are red for SHA $head_sha"
    else
      merge_pr_refuse "$pr" "the full-suite result for SHA $head_sha is incomplete or invalid"
    fi
    return 1
  fi
  receipt="$(merge_pr_receipt_file "$root" "$head_sha")" || {
    merge_pr_refuse "$pr" 'cannot locate the repository test-receipt directory'
    return 1
  }
  if [[ ! -s "$receipt" ]]; then
    if count="$(merge_pr_ci_green_check_count "$pr" "$head_sha")"; then
      printf 'merge-pr: receipt: ci-green %s checks at %.12s\n' "$count" "$head_sha" >&2
      return 0
    fi
    merge_pr_refuse "$pr" "no test receipt exists for $head_sha: run the tests at that HEAD through tools/test-receipt.sh <command...>"
    return 1
  fi
  if [[ ! -f "$receipt" || ! -s "$receipt" ]]; then
    merge_pr_refuse "$pr" "test receipt for $head_sha is empty or invalid"
    return 1
  fi
  bad="$(awk '
    index($0, "\t") == 0 { print "malformed receipt line " NR; next }
    {
      tab = index($0, "\t")
      rc = substr($0, 1, tab - 1)
      cmd = substr($0, tab + 1)
      if (rc !~ /^[0-9]+$/ || cmd == "") { print "malformed receipt line " NR; next }
      last[cmd] = rc
    }
    END { for (cmd in last) if (last[cmd] + 0 != 0) print cmd " (exit " last[cmd] ")" }
  ' "$receipt")"
  [[ -z "$bad" ]] || {
    merge_pr_refuse "$pr" "test receipt for $head_sha has a failed last run: $bad"
    return 1
  }
  printf 'merge-pr: receipt: local\n' >&2
}

# Only this PR's own files: a main already over its baseline must not stop other merges.
merge_pr_size_ok() {
  local pr="$1" root files over
  root="$(merge_pr_root)" || {
    merge_pr_refuse "$pr" 'no git checkout: cannot run size-ratchet'
    return 1
  }
  over="$({ bash "$root/tools/size-ratchet.sh" 2>&1 || true; } | grep '^FAIL ')" || return 0
  [[ "$(git -C "$root" rev-parse HEAD 2>/dev/null)" == "$(merge_pr_head_sha "$pr" 2>/dev/null)" ]] || return 0
  files="$(merge_pr_view "$pr" body,files,commits 2>/dev/null | jq -r '.files[].path')"
  # Exact path match: every FAIL line also names tools/size-baseline.txt.
  over="$(awk 'NR == FNR { own[$0] = 1; next } $2 in own' <(printf '%s\n' "$files") - <<<"$over")"
  [[ -n "$over" ]] || return 0
  merge_pr_refuse "$pr" "$over"
}


# The prelude of scheduler.test.sh holds the text assertions every shard runs, so one stale grep turns all eight red.
merge_pr_with_tree() { # pr function: run function on an export of the PR's head
  local pr="$1" fn="$2" root tree ref="refs/zf-merge-pr/$1" rc=0
  root="$(merge_pr_root)" || {
    printf 'no git checkout: cannot run %s on the PR head\n' "$fn"
    return 1
  }
  git -C "$root" fetch -q origin "+pull/$pr/head:$ref" 2>&1 || return
  tree="$(mktemp -d)"
  if git -C "$root" archive "$ref" | tar -x -C "$tree"; then
    "$fn" "$tree" || rc=$?
  else
    rc=1
  fi
  rm -rf -- "$tree"
  return "$rc"
}
merge_pr_prelude_in() {
  SCHED_TEST_CASE=prelude timeout 300 bash "$1/engine/mac-autopilot/scheduler.test.sh" 2>&1 | tail -3
  return "${PIPESTATUS[0]}"
}
merge_pr_scheduler_prelude() { merge_pr_with_tree "$1" merge_pr_prelude_in; }
merge_pr_scheduler_prelude_ok() {
  local pr="$1" out touched head_sha green rc timeout_note=
  touched="$(merge_pr_view "$pr" body,files,commits 2>/dev/null | jq '[.files[].path | select(test("^engine/mac-autopilot/(scheduler(\\.sh|\\.d/|\\.test\\.sh)|config\\.template\\.json)"))] | length')" || touched=
  if [[ -z "$touched" ]]; then
    merge_pr_refuse "$pr" 'could not read PR files for the scheduler prelude check'
    return 1
  fi
  (( touched > 0 )) || return 0
  if head_sha="$(merge_pr_head_sha "$pr")" \
    && green="$(merge_pr_ci_green_check_count "$pr" "$head_sha" true)"; then
    printf 'prelude: ci-green %s checks at %.12s\n' "$green" "$head_sha"
    return 0
  fi
  if out="$(merge_pr_scheduler_prelude "$pr")"; then return 0; else rc=$?; fi
  if [[ "$rc" == 124 ]]; then timeout_note=' (timeout 300s)'; fi
  merge_pr_refuse "$pr" "scheduler.test.sh prelude failed rc=$rc$timeout_note: $out"
}
# These scans take seconds, so they run here and hold no merge on CI: #502 reached main past jq-arg-safety.
merge_pr_static_scans_in() {
  local scan rc=0
  for scan in jq-arg-safety jq-regex-safety scheduler-gh-timeout-safety zcode-launch-set; do
    timeout 120 bash "$1/engine/$scan.test.sh" 2>&1 | tail -3
    [[ "${PIPESTATUS[0]}" == 0 ]] || rc=1
  done
  return "$rc"
}
merge_pr_static_scans() { merge_pr_with_tree "$1" merge_pr_static_scans_in; }
merge_pr_static_scans_ok() {
  local pr="$1" out touched
  touched="$(merge_pr_view "$pr" body,files,commits 2>/dev/null | jq '[.files[].path | select(test("^engine/.*\\.(sh|py|mjs)$"))] | length')" || touched=
  if [[ -z "$touched" ]]; then
    merge_pr_refuse "$pr" 'could not read PR files for the static scans'
    return 1
  fi
  (( touched > 0 )) || return 0
  out="$(merge_pr_static_scans "$pr")" && return 0
  merge_pr_refuse "$pr" "static scan failed: $out"
}
# review-family.test.sh greps the review dispatch lines: #599 changed one, its own CI was cancelled on merge, and main went red.
merge_pr_review_family_in() {
  timeout 200 bash "$1/engine/mac-autopilot/review-family.test.sh" 2>&1 | tail -5
  return "${PIPESTATUS[0]}"
}
merge_pr_review_family() { merge_pr_with_tree "$1" merge_pr_review_family_in; }
merge_pr_review_family_ok() {
  local pr="$1" out touched
  touched="$(merge_pr_view "$pr" body,files,commits 2>/dev/null | jq '[.files[].path | select(test("^engine/mac-autopilot/scheduler\\.d/(dispatch-queue|health-release|models)\\.sh$"))] | length')" || touched=
  if [[ -z "$touched" ]]; then
    merge_pr_refuse "$pr" 'could not read PR files for the review-family check'
    return 1
  fi
  (( touched > 0 )) || return 0
  out="$(merge_pr_review_family "$pr")" && return 0
  merge_pr_refuse "$pr" "review-family.test.sh failed: $out"
}
# The pin three-way merges every overridden engine file into the target's pack copy and refuses on a conflict (tools/pin-vecta.sh): #643 merged such a change and stopped every pin for 12 minutes.
# Same table, base blob, pack path and `git merge-file ours base theirs` as the pin; only files the PR touches are read, so a clean merge passes.
# Fails closed like the checks above: an unreadable target refuses, ZF_MERGE_OVERRIDE=override-merge skips (logged).
# shortcut: theirs is the PR head's file, not main plus the PR, so a head behind main can differ from what the pin sees; rebase before merging if it matters.
merge_pr_override_ok() {
  local pr="$1" files root home target ref="refs/zf-merge-pr/$1" hook table rel pack work ov_path ov_base ov_new rc bad=
  pack=.zenoforge/build/pack/scripts/agent
  if [[ ",${ZF_MERGE_OVERRIDE:-}," == *,override-merge,* ]]; then
    printf 'merge-pr: explicit ZF_MERGE_OVERRIDE skips the override merge check for PR #%s\n' "$pr" >&2
    return 0
  fi
  if ! files="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/files" 2>/dev/null \
    | jq -rs 'add // [] | [.[] | (.filename, .previous_filename // empty) | select(startswith("engine/"))] | unique | .[]')"; then
    merge_pr_refuse "$pr" 'could not read PR files for the override merge check'
    return 1
  fi
  [[ -n "$files" ]] || return 0
  home="${AGENT_HOME:-${ZF_HOME:-$HOME/.vecta-agent}}"
  target="$home/checkout"
  if [[ -z "$home" ]] || ! root="$(merge_pr_root)" \
    || ! git -C "$target" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main 2>/dev/null \
    || ! hook="$(git -C "$target" show origin/main:.zenoforge/build.json 2>/dev/null | jq -er '.hook | select(type == "string" and length > 0)')"; then
    merge_pr_refuse "$pr" "could not read the target's origin/main and build config at $target for the override merge check; the pin needs them too (ZF_MERGE_OVERRIDE=override-merge skips)"
    return 1
  fi
  rel="$(dirname -- "$hook")/overrides.tsv"
  table="$(git -C "$target" show "origin/main:$rel" 2>/dev/null)" || return 0 # no table: the pin merges nothing
  work="$(mktemp -d)"
  while IFS=$'\t' read -r ov_path ov_base _; do
    [[ -n "$ov_path" && "$ov_path" != '#'* ]] || continue
    grep -qxF "engine/$ov_path" <<<"$files" || continue
    if ! git -C "$root" fetch -q origin "+pull/$pr/head:$ref" 2>/dev/null; then
      bad='could not fetch the PR head for the override merge check'
      break
    fi
    if ! ov_new="$(git -C "$root" rev-parse --verify -q "$ref:engine/$ov_path")"; then
      bad="override $ov_path: the PR removes or moves engine/$ov_path, and the pin refuses an engine without it"
      break
    fi
    [[ "$ov_base" != "$ov_new" ]] || continue
    if ! git -C "$root" cat-file blob "$ov_base" > "$work/base" 2>/dev/null \
      || ! git -C "$root" cat-file blob "$ov_new" > "$work/theirs" \
      || ! git -C "$target" show "origin/main:$pack/$ov_path" > "$work/ours" 2>/dev/null; then
      bad="override $ov_path: base blob $ov_base, the PR's file or the pack copy $pack/$ov_path is unreadable"
      break
    fi
    rc=0
    git merge-file -p "$work/ours" "$work/base" "$work/theirs" > "$work/merged" 2>/dev/null || rc=$?
    if ((rc > 0 && rc < 128)); then
      bad="override $ov_path: three-way merge conflicts ($rc hunk(s)) between the pack copy and the PR's engine/$ov_path; the pin would refuse every pin after this merge, so resolve the pack copy first"
      break
    elif ((rc != 0)); then
      bad="override $ov_path: three-way merge failed (git merge-file exit $rc)"
      break
    fi
    if [[ "$ov_path" == *.sh ]] && ! bash -n "$work/merged" 2>/dev/null; then
      bad="override $ov_path: the merged result fails bash -n; the pin would refuse"
      break
    fi
  done <<<"$table"
  rm -rf -- "$work"
  [[ -z "$bad" ]] && return 0
  merge_pr_refuse "$pr" "$bad"
}
# suite-set-check.py refuses a pin that drops a baseline suite and has no retire path: a deleted suite merged, then stopped auto-pin (#614).
# A rename counts as a deletion unless it is a pure move (no changed lines) that stays a suite under engine/.
merge_pr_suite_delete_ok() {
  local pr="$1" files deleted
  if ! files="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/files" 2>/dev/null)"; then
    merge_pr_refuse "$pr" 'could not read PR file statuses for the suite check'
    return 1
  fi
  if ! deleted="$(jq -rs 'def t: test("^engine/.*\\.test\\.(sh|py|mjs)$");
    add // [] | [.[] | select((.status == "removed" and (.filename | t))
      or (.status == "renamed" and (.previous_filename | t) and (((.changes // 1) != 0) or (.filename | t | not))))
      | (.previous_filename // .filename)] | join(", ")' <<<"$files")"; then
    merge_pr_refuse "$pr" 'could not read PR file statuses for the suite check'
    return 1
  fi
  [[ -z "$deleted" ]] && return 0
  merge_pr_refuse "$pr" "deletes or renames away test suite(s) $deleted: keep the suite; a pin that drops a baseline suite has no retire path"
}
# Silent revert (incident 2026-11-07): a PR that removes lines a PR merged in the last 24 h added to the same file, unless its title or body says it is a revert.
# shortcut: reads only the 10 newest merged PRs of the last 24 h, a revert of an older one passes; raise the cap if one slips through.
# Any failed read warns and passes: the check must never stop the merge lane on a gh failure.
merge_pr_revert_ok() {
  local pr="$1" meta raw mine list merged num theirs hit file matched added
  if ! meta="$(gh api "repos/{owner}/{repo}/pulls/$pr" 2>/dev/null)" \
    || ! raw="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/files" 2>/dev/null)" \
    || ! mine="$(jq -cs 'add // []' <<<"$raw" 2>/dev/null)"; then
    printf 'merge-pr: warning: could not read PR #%s for the revert check; not refusing\n' "$pr" >&2
    return 0
  fi
  jq -e '((.title // "") + "\n" + (.body // "")) | test("revert"; "i")' <<<"$meta" >/dev/null 2>&1 && return 0
  if ! list="$(gh api 'repos/{owner}/{repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100' 2>/dev/null)" \
    || ! merged="$(jq -c --arg pr "$pr" --argjson since "$(date -u -d '24 hours ago' +%s)" \
      '[.[] | select(.merged_at != null and (.number | tostring) != $pr and (.merged_at | fromdateiso8601) >= $since) | .number] | .[0:10]' <<<"$list" 2>/dev/null)"; then
    printf 'merge-pr: warning: could not list merged PRs for the revert check; not refusing PR #%s\n' "$pr" >&2
    return 0
  fi
  for num in $(jq -r '.[]' <<<"$merged"); do
    if ! raw="$(gh api --paginate "repos/{owner}/{repo}/pulls/$num/files" 2>/dev/null)" \
      || ! theirs="$(jq -cs 'add // []' <<<"$raw" 2>/dev/null)"; then
      printf 'merge-pr: warning: could not read merged PR #%s files for the revert check; skipping it\n' "$num" >&2
      continue
    fi
    # A file both PRs touch: removed lines of this PR that equal lines the merged PR added, at least 5 and half its added lines.
    hit="$(printf '%s\n%s\n' "$mine" "$theirs" | jq -rs '
      def lines($s): [.patch // "" | split("\n")[] | select(startswith($s)) | .[1:] | select(test("\\S"))];
      .[0] as $mine | .[1] as $theirs
      | $mine[] as $m | ($m | lines("-")) as $r | select($r | length > 0)
      | $theirs[] | select(.filename == $m.filename) | lines("+") as $a | select($a | length > 0)
      | ([$r[] as $x | select(any($a[]; . == $x))] | length) as $hit
      | select($hit >= 5 and $hit * 2 >= ($a | length))
      | "\($m.filename)\t\($hit)\t\($a | length)"')"
    hit="${hit%%$'\n'*}"
    if [[ -n "$hit" ]]; then
      IFS=$'\t' read -r file matched added <<<"$hit"
      merge_pr_refuse "$pr" "removes $matched lines of $file that merged PR #$num added ($added lines): a revert must say so in the PR title or body"
      return 1
    fi
  done
  return 0
}
# Ruling zenoforge-instant-effect-2026-11-05: gates, evaluators, the pin, the watchdog and rollback keep CI before merge.
# Code that deletes clones and refs is held the same way: #485 reached main 95s into a CI run that then failed.
merge_pr_gate_ci_ok() {
  local pr="$1" checks_json="$2" gate waiting
  [[ ",${ZF_MERGE_OVERRIDE:-}," != *,gate-ci,* ]] || return 0
  gate="$(merge_pr_view "$pr" body,files,commits 2>/dev/null | jq -r '[.files[].path | select(test("^(tools/(merge-pr|pin-vecta|auto-pin)\\.sh|engine/eval/.*|engine/mac-autopilot/(bell|bell-loop|pin-lag)\\.sh|engine/lib\\.d/main-red(-bisect)?\\.sh|engine/deploy-culprit\\.sh|engine/worktree-lifecycle\\.sh|engine/mac-autopilot/rescued_gc\\.sh|engine/mac-autopilot/scheduler\\.d/(cleanup|units)\\.sh|engine/mac-autopilot/scheduler\\.d/review-rules\\.sh|engine/prompts/review-contract\\.md|engine/notify\\.sh|engine/ts-judge\\.sh|engine/redact-secrets\\.sh|engine/night/(authorization-readonly|production-tenant-marker-readonly|node-health-rules|maintainer-health-mail)\\.sh|engine/night/acceptance-login-probe\\.mjs|engine/systemd/zenoforge-(agent|daily-perf-report|health-mail|health-maintenance|label-churn|memory-check|owner-report-causes|roi-collector|supervisor)\\.service)$"))] | .[0] // ""')" || gate=unreadable
  [[ -n "$gate" ]] || return 0
  waiting="$(jq -r '[.[] | select(.bucket == "pending" or ((.name | startswith("suites")) and .bucket != "pass")) | .name] + (if any(.[]; .name | startswith("suites")) then [] else ["suites not started"] end) | join(", ")' <<<"$checks_json")"
  [[ -n "$waiting" ]] || return 0
  merge_pr_refuse "$pr" "gate file $gate waits for PR CI: $waiting"
}

# A merged PR's own CI proves nothing the main run will not, and it holds hosted slots through a merge burst.
merge_pr_cancel_ci() {
  local pr="$1" sha id runs
  sha="$(merge_pr_head_sha "$pr")" || return 0
  runs="$(gh run list --commit "$sha" --json databaseId,status 2>/dev/null)" \
    || runs="$(gh api --paginate "repos/{owner}/{repo}/actions/runs?head_sha=$sha&per_page=100" 2>/dev/null | jq -cs '[.[].workflow_runs[]? | {databaseId: .id, status}]')" \
    || runs='[]'
  jq -r '.[] | select(.status != "completed") | .databaseId' <<<"$runs" \
    | while read -r id; do gh run cancel "$id" >/dev/null 2>&1 || true; done
}

# GraphQL gh pr merge refused: squash over REST pinned to the head read here, then drop the head ref.
merge_pr_squash() {
  local pr="$1" sha="$2" head_ref out
  gh pr merge "$pr" --squash --delete-branch --match-head-commit "$sha" && return 0
  head_ref="$(merge_pr_view "$pr" headRefName 2>/dev/null | jq -er '.headRefName | select(type == "string" and length > 0)')" || return 1
  out="$(gh api -X PUT "repos/{owner}/{repo}/pulls/$pr/merge" -f merge_method=squash -f sha="$sha" 2>&1)" \
    || { [[ "$out" != *409* ]] || merge_pr_refuse "$pr" "head moved after the gate: $sha is no longer the head, not merged"; return 1; }
  gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$head_ref" >/dev/null 2>&1 || true
}

# --delete-branch removes the head branch, and GitHub then closes every open PR based on it.
# Retarget those children to the default branch first; refuse the merge if any retarget fails.
merge_pr_retarget_children() {
  local pr="$1" head_ref default_ref children_json child
  if ! head_ref="$(merge_pr_view "$pr" headRefName 2>/dev/null | jq -er '.headRefName | select(type == "string" and length > 0)')"; then
    merge_pr_refuse "$pr" 'could not read the PR head branch to find stacked child PRs'
    return 1
  fi
  default_ref="$(gh repo view --json defaultBranchRef 2>/dev/null | jq -er '.defaultBranchRef.name | select(type == "string" and length > 0)' 2>/dev/null)" \
    || default_ref="$(gh api "repos/{owner}/{repo}" 2>/dev/null | jq -er '.default_branch | select(type == "string" and length > 0)' 2>/dev/null)" || default_ref=
  if [[ -z "$default_ref" ]]; then
    merge_pr_refuse "$pr" 'could not read the default branch to retarget stacked child PRs'
    return 1
  fi
  children_json="$(gh pr list --state open --base "$head_ref" --json number 2>/dev/null)" \
    || children_json="$(gh api --paginate "repos/{owner}/{repo}/pulls?state=open&base=$head_ref&per_page=100" 2>/dev/null | jq -cs 'if length == 0 then error("no pages") else [.[][] | {number}] end')" || children_json=
  if ! jq -e 'type == "array"' <<<"$children_json" >/dev/null 2>&1; then
    merge_pr_refuse "$pr" "could not list open PRs based on $head_ref"
    return 1
  fi
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    if ! { gh pr edit "$child" --base "$default_ref" >/dev/null || gh api -X PATCH "repos/{owner}/{repo}/pulls/$child" -f base="$default_ref" >/dev/null; }; then
      merge_pr_refuse "$pr" "could not retarget child PR #$child to $default_ref; merging would close it"
      return 1
    fi
    printf 'merge-pr: retargeted child PR #%s from %s to %s before deleting %s\n' "$child" "$head_ref" "$default_ref" "$head_ref" >&2
  done < <(jq -r '.[].number' <<<"$children_json")
}

merge_pr_checks_valid() {
  jq -e 'type == "array" and all(.[]; type == "object" and (.name | type == "string" and length > 0) and (.bucket | type == "string"))' <<<"$1" >/dev/null 2>&1
}
# Head SHA: GraphQL first, REST pulls/<n> when GraphQL refuses (shared-account rate limit).
merge_pr_head_sha() {
  local pr="$1" sha
  sha="$(gh pr view "$pr" --json headRefOid 2>/dev/null | jq -er '.headRefOid | select(type == "string")' 2>/dev/null)" && [[ -n "$sha" ]] && { printf '%s\n' "$sha"; return 0; }
  sha="$(gh api "repos/{owner}/{repo}/pulls/$pr" -q .head.sha 2>/dev/null)" && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && printf '%s\n' "$sha"
}
# GraphQL-shaped rollup for the head from REST: CheckRun nodes take workflowName from the Actions run that owns their check suite.
merge_pr_rollup_rest() {
  local pr="$1" sha runs checks statuses
  sha="$(merge_pr_head_sha "$pr")" || return 1
  runs="$(gh api --paginate "repos/{owner}/{repo}/actions/runs?head_sha=$sha&per_page=100" 2>/dev/null)" || return 1
  checks="$(gh api --paginate "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" 2>/dev/null)" || return 1
  statuses="$(gh api "repos/{owner}/{repo}/commits/$sha/status" 2>/dev/null)" || return 1
  printf '%s\n%s\n%s\n' "$runs" "$checks" "$statuses" | jq -se --arg sha "$sha" '
    ([.[] | .workflow_runs[]? | {key: (.check_suite_id | tostring), value: .name}] | from_entries) as $wf
    | ([.[] | .check_runs[]? | {__typename: "CheckRun", name, workflowName: ($wf[(.check_suite.id | tostring)] // ""),
          status: (.status | ascii_upcase), conclusion: ((.conclusion // "") | ascii_upcase), startedAt: .started_at}]
      | group_by([.workflowName, .name]) | map(max_by(.startedAt // "")))
    + ([.[] | .statuses[]? | {__typename: "StatusContext", context, state: (.state | ascii_upcase)}])
    | {headRefOid: $sha, statusCheckRollup: .}'
}
# Same {name, bucket} list as `gh pr checks --json bucket,name`, from the REST rollup.
merge_pr_checks_rest() {
  merge_pr_rollup_rest "$1" | jq -e '.statusCheckRollup | if length == 0 then error("no checks") else . end
    | map({name: (.name // .context), bucket: (if .__typename == "CheckRun"
        then (if .status != "COMPLETED" then "pending" else (.conclusion | if . == "SUCCESS" then "pass"
          elif . == "NEUTRAL" or . == "SKIPPED" then "skipping" elif . == "CANCELLED" then "cancel" else "fail" end) end)
        else (.state | if . == "SUCCESS" then "pass" elif . == "PENDING" then "pending" else "fail" end) end)})'
}

merge_pr_checks_and_merge() {
  local pr="${1:-}" gate_sha="${2:-}" checks_json check_name override_name matched
  local -a override_names=() failed_names=() blocked_names=() overridden_names=()
  if [[ $# -lt 1 || $# -gt 2 || ! "$pr" =~ ^[0-9]+$ ]]; then
    printf 'usage: tools/merge-pr.sh <pr-number>\n' >&2
    return 2
  fi
  # The merge pins the head the gate started with, not a re-read at merge time.
  if [[ -z "$gate_sha" ]] && ! gate_sha="$(merge_pr_head_sha "$pr")"; then
    merge_pr_refuse "$pr" 'could not read the PR head to pin the merge'
    return 1
  fi

  # gh pr checks exits non-zero when checks are failed or pending. The JSON
  # buckets distinguish those valid results from a command/API error.
  # A fresh push registers its checks seconds late: until then gh prints
  # "no checks reported" on stderr with empty stdout. Retry that case only.
  local checks_err wait_max="${ZF_CHECKS_WAIT_SECS:-180}" waited=0
  checks_err="$(mktemp)"
  while :; do
    checks_json="$(gh pr checks "$pr" --json bucket,name 2>"$checks_err")" || :
    [[ -z "$checks_json" ]] && grep -q 'no checks reported' "$checks_err" && (( waited < wait_max )) || break
    sleep 10
    waited=$((waited + 10))
  done
  rm -f "$checks_err"
  # GraphQL refuses `gh pr checks` under a shared-account rate limit: read the same buckets over REST.
  merge_pr_checks_valid "$checks_json" || checks_json="$(merge_pr_checks_rest "$pr" 2>/dev/null)" || checks_json=
  if ! merge_pr_checks_valid "$checks_json"; then
    merge_pr_refuse "$pr" 'could not read PR checks as JSON'
    return 1
  fi

  if [[ -n "${ZF_MERGE_OVERRIDE:-}" ]]; then
    case "$ZF_MERGE_OVERRIDE" in
      ,*|*,|*,,*)
        merge_pr_refuse "$pr" 'ZF_MERGE_OVERRIDE must contain comma-separated check names'
        return 1
        ;;
    esac
    IFS=, read -r -a override_names <<<"$ZF_MERGE_OVERRIDE"
    for override_name in "${override_names[@]}"; do
      if [[ -z "$override_name" ]]; then
        merge_pr_refuse "$pr" 'ZF_MERGE_OVERRIDE must contain comma-separated check names'
        return 1
      fi
    done
  fi

  matched=0
  for override_name in "${override_names[@]}"; do
    [[ "$override_name" == prior-art ]] && matched=1
  done
  if (( matched )); then
    printf 'merge-pr: explicit ZF_MERGE_OVERRIDE skips the prior-art check for PR #%s\n' "$pr" >&2
  else
    merge_pr_prior_art_ok "$pr" || return 1
  fi
  merge_pr_test_receipt_ok "$pr" || return 1
  merge_pr_size_ok "$pr" || return 1
  merge_pr_gate_ci_ok "$pr" "$checks_json" || return 1
  merge_pr_scheduler_prelude_ok "$pr" || return 1
  merge_pr_static_scans_ok "$pr" || return 1
  merge_pr_review_family_ok "$pr" || return 1
  merge_pr_override_ok "$pr" || return 1
  merge_pr_suite_delete_ok "$pr" || return 1
  merge_pr_revert_ok "$pr" || return 1

  while IFS= read -r check_name; do
    [[ -n "$check_name" ]] || continue
    failed_names+=("$check_name")
    matched=0
    for override_name in "${override_names[@]}"; do
      if [[ "$check_name" == "$override_name" ]]; then
        matched=1
        break
      fi
    done
    if (( matched )); then
      overridden_names+=("$check_name")
    else
      blocked_names+=("$check_name")
    fi
  done < <(jq -r '.[] | select(.bucket == "fail") | .name' <<<"$checks_json")

  if ((${#blocked_names[@]})); then
    local failed_csv blocked_csv
    failed_csv="$(merge_pr_join_checks "${failed_names[@]}")"
    blocked_csv="$(merge_pr_join_checks "${blocked_names[@]}")"
    merge_pr_refuse "$pr" "failed checks: $failed_csv; checks without a matching ZF_MERGE_OVERRIDE: $blocked_csv"
    return 1
  fi
  if ((${#overridden_names[@]})); then
    local overridden_csv
    overridden_csv="$(merge_pr_join_checks "${overridden_names[@]}")"
    printf 'merge-pr: explicit ZF_MERGE_OVERRIDE allows failed checks: %s\n' "$overridden_csv" >&2
  fi

  merge_pr_retarget_children "$pr" || return 1
  merge_pr_squash "$pr" "$gate_sha" || return
  merge_pr_cancel_ci "$pr" || true
}

merge_pr_gate() {
  local pr="$1" sha="$2" repo="${3:-$(merge_pr_root)}"
  local result_file head_json head_sha
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    merge_pr_refuse "$pr" 'PR number must be numeric'
    return 1
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    merge_pr_refuse "$pr" 'tested SHA is not a full commit ID'
    return 1
  fi
  result_file="$(merge_pr_result_file "$repo" "$sha")" || {
    merge_pr_refuse "$pr" 'cannot locate the repository result directory'
    return 1
  }
  if [[ ! -f "$result_file" ]]; then
    merge_pr_refuse "$pr" "no full-suite result exists for SHA $sha"
    return 1
  fi
  if ! merge_pr_result_is_green "$result_file" "$sha"; then
    if jq -e --arg sha "$sha" '
      .sha == $sha and (.green == false
        or .cli_exit_code != 0
        or any(.engine_shards[]?; .exit_code != 0))
    ' "$result_file" >/dev/null 2>&1; then
      merge_pr_refuse "$pr" "full local suites are red for SHA $sha"
    else
      merge_pr_refuse "$pr" "the full-suite result for SHA $sha is incomplete or invalid"
    fi
    return 1
  fi
  head_sha="$(merge_pr_head_sha "$pr")" || {
    merge_pr_refuse "$pr" 'could not read the PR head'
    return 1
  }
  if [[ "$head_sha" != "$sha" ]]; then
    merge_pr_refuse "$pr" "PR head $head_sha does not match tested SHA $sha"
    return 1
  fi
  printf 'full local suites are green for %s and PR #%s still points to that SHA; checking PR checks before merge\n' "$sha" "$pr"
  merge_pr_checks_and_merge "$pr" "$sha"
}

merge_pr_main() {
  local pr="${1:-}" repo sha result_dir log_dir result_file cli_rc rc green current_sha engine_results='[]'
  local shard pid status_file
  local -a pids=()
  if [[ $# -ne 1 || ! "$pr" =~ ^[0-9]+$ ]]; then
    printf 'usage: tools/merge-pr.sh <pr-number>\n' >&2
    return 2
  fi
  repo="$(merge_pr_root)" || {
    merge_pr_refuse "$pr" 'run this helper inside a Git checkout'
    return 1
  }
  cd "$repo" || return 1
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    merge_pr_refuse "$pr" 'the working tree must be clean so the tested SHA identifies the source'
    return 1
  fi
  sha="$(git rev-parse HEAD 2>/dev/null)" || {
    merge_pr_refuse "$pr" 'could not read the current HEAD'
    return 1
  }
  result_dir="$(merge_pr_result_dir "$repo")" || {
    merge_pr_refuse "$pr" 'cannot locate the repository result directory'
    return 1
  }
  mkdir -p "$result_dir" || return 1
  result_file="$result_dir/$sha.json"
  log_dir="$result_dir/$sha-logs"
  rm -f "$result_file"
  rm -rf "$log_dir"
  mkdir -p "$log_dir" || return 1

  for ((shard=0; shard<MERGE_PR_ENGINE_SHARDS; shard++)); do
    (
      # The host is shared with production; shards yield to it under load.
      nice -n 10 bash "$repo/tools/run-engine-tests.sh" "$shard" "$MERGE_PR_ENGINE_SHARDS" \
        >"$log_dir/engine-$shard.log" 2>&1
      rc=$?
      printf '%s\n' "$rc" >"$log_dir/engine-$shard.exit"
      exit "$rc"
    ) &
    pids+=("$!")
    if (( ${#pids[@]} >= MERGE_PR_MAX_PARALLEL )); then
      wait "${pids[0]}" || :
      pids=("${pids[@]:1}")
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid" || :; done

  for ((shard=0; shard<MERGE_PR_ENGINE_SHARDS; shard++)); do
    status_file="$log_dir/engine-$shard.exit"
    if [[ -f "$status_file" ]]; then
      rc="$(cat "$status_file")"
      [[ "$rc" =~ ^[0-9]+$ ]] || rc=125
    else
      rc=125
    fi
    engine_results="$(jq -cn --argjson current "$engine_results" --argjson shard "$shard" --argjson rc "$rc" \
      '$current + [{shard:$shard,exit_code:$rc}]')"
  done

  npm test >"$log_dir/cli.log" 2>&1
  cli_rc=$?
  [[ "$cli_rc" =~ ^[0-9]+$ ]] || cli_rc=125
  green=false
  if [[ "$cli_rc" == 0 ]] && jq -e 'all(.[]; .exit_code == 0)' <<<"$engine_results" >/dev/null; then
    green=true
  fi
  jq -n --arg sha "$sha" --argjson engine_shards "$engine_results" \
    --argjson cli_exit_code "$cli_rc" --argjson green "$green" \
    '{sha:$sha,engine_shards:$engine_shards,cli_exit_code:$cli_exit_code,green:$green}' \
    >"$result_file.tmp" && mv -f "$result_file.tmp" "$result_file" || {
      merge_pr_refuse "$pr" "could not record full-suite results for SHA $sha"
      return 1
    }

  for ((shard=0; shard<MERGE_PR_ENGINE_SHARDS; shard++)); do
    rc="$(jq -r --argjson shard "$shard" '.[] | select(.shard==$shard) | .exit_code' <<<"$engine_results")"
    printf 'ENGINE_SHARD=%s/%s EXIT_CODE=%s\n' "$shard" "$MERGE_PR_ENGINE_SHARDS" "$rc"
    tail -n 15 "$log_dir/engine-$shard.log"
  done
  printf 'CLI_TEST=npm test EXIT_CODE=%s\n' "$cli_rc"
  tail -n 15 "$log_dir/cli.log"
  printf 'FULL_SUITE_SHA=%s GREEN=%s RESULT=%s\n' "$sha" "$green" "$result_file"

  current_sha="$(git rev-parse HEAD 2>/dev/null)" || current_sha=''
  if [[ "$current_sha" != "$sha" ]]; then
    merge_pr_refuse "$pr" "local HEAD changed during the suites (tested $sha, now ${current_sha:-unknown})"
    return 1
  fi
  merge_pr_gate "$pr" "$sha" "$repo"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${ZF_ALLOW_FULL_GATE:-}" == 1 ]]; then
    merge_pr_main "$@"
  else
    # Ruling zenoforge-no-local-gate-2026-11-04: only the focused tests run locally.
    merge_pr_checks_and_merge "$@"
  fi
fi
