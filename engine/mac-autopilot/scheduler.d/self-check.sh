self_check_main_fresh() { # clone head [main-sha] → whether the head contains the fetched main
  local main="${3:-}"
  [[ -n "$main" ]] || main="$(git -C "$1" rev-parse --verify refs/remotes/origin/main^{commit} 2>/dev/null)" || return 1
  git -C "$1" merge-base --is-ancestor "$main" "$2" 2>/dev/null
}
self_check_deferred_count() { jqf -r --arg id "$1" --arg sha "$2" 'def entry_sha: .sha // ((.result // "") | (try capture("self-check-.*-(?<sha>[0-9a-f]{40})-[0-9]+-").sha catch "")); ([.units[] | select(.id==$id) | (.history // [])][0] // []) | reverse | reduce .[] as $entry ({count:0,stopped:false}; if .stopped then . elif $entry.stage=="self-check-deferred" and ($entry | entry_sha)==$sha then if $entry.defer_rc==125 then .count+=1 elif $entry.defer_rc==75 then . else .stopped=true end else .stopped=true end) | .count' "$UNITS"; }
self_check_run() (
  set -o pipefail
  local dir="$1" sha="$2" lane="${3:-}" pr_base="${4:-}" base paths pkg targets test_targets cached_tests tree selection selection_dir selection_log manifest part changed_helpers=0 rc=0 marker target runner_source runner_path
  local unit_id="${5:-}" branch="${6:-}" pr="${7:-}" main_head merge_rc checked_head branch_head initial_sha="$2" unit_json="${8:-}"
  local entry_fallback="${ZF_ENGINE_DIR:-$ROOT/engine}/cihost-exec.py"
  local entry="${ZF_CIHOST_EXEC:-$(source "$HERE/../config.sh" && zf_host_ops_file "scripts/agent/${ZF_CIHOST_FILE_STEM:-cihost}-exec.py" "$entry_fallback")}"
  local step_s="${SELF_CHECK_STEP_TIMEOUT:-900}" srg test_started
  local delegate_tests=0
  local run_main_pr_tests="${SELF_CHECK_RUN_TESTS_ON_MAIN_PR:-0}"
  local -a builds=()
  runner_path="$(dirname -- "${BASH_SOURCE[0]}")/escape-suite-runner.mjs"
  runner_source="$(<"$runner_path")" || return 1
  cd "$dir" || return 1
  main_head="$(git rev-parse --verify refs/remotes/origin/main^{commit})" || return 1
  if self_check_main_fresh "$dir" "$sha" "$main_head"; then
    echo "self-check main sync: already fresh head=$sha main=$main_head"
  else
    checked_head="$(git rev-parse HEAD)"; branch="${branch:-$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)}"; branch_head="$(git rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null || true)"
    [[ "$checked_head" == "$sha" ]] || { echo "self-check main sync: refused candidate head mismatch expected=$sha actual=$checked_head"; return 125; }
    [[ -n "$branch" && "$branch" != main ]] && git check-ref-format --branch "$branch" >/dev/null 2>&1 || { echo "self-check main sync: refused invalid candidate branch branch=${branch:-missing}"; return 125; }
    if [[ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)" != "$branch" ]]; then [[ -z "$branch_head" || "$branch_head" == "$sha" ]] || { echo "self-check main sync: refused branch mismatch branch=$branch expected=$sha actual=$branch_head"; return 125; }; git checkout -q -B "$branch" "$sha" || { echo "self-check main sync: branch attachment failed branch=$branch sha=$sha"; return 125; }; fi
    if git merge --no-edit "$main_head"; then
      sha="$(git rev-parse HEAD)" || return 1
      if [[ "$lane" == pr ]]; then
        git push -q origin "HEAD:refs/heads/$branch" || { echo "self-check main sync: merged clean but push failed branch=$branch"; return 1; }
      fi
      echo "self-check main sync: merged clean head=$sha main=$main_head"
    else
      merge_rc=$?
      if [[ -n "$(git ls-files -u)" ]]; then
        git merge --abort || { echo "self-check main sync: conflict abort failed"; return 1; }
        if [[ -n "$unit_id" && "$pr" =~ ^[1-9][0-9]*$ ]] && declare -F merge_conflict_to_repair >/dev/null; then
          echo "self-check main sync: conflict routed unit=$unit_id pr=$pr head=$sha main=$main_head"
          merge_conflict_to_repair "$unit_id" "$pr" "self-check: conflicts with main before builds" \
            "PR 与最新 main 冲突，自检开始前发现。git merge --no-edit origin/main，按两边意图解决冲突，跑受影响测试，推送。" "$sha" || return 1
          return 76
        fi
        echo "self-check main sync: conflict cannot route unit=$unit_id pr=$pr"
        return 1
      fi
      echo "self-check main sync: merge failed rc=$merge_rc"
      return "$merge_rc"
    fi
  fi
  tree="$(git rev-parse "$sha^{tree}")" || return 1
  base="$(git merge-base "$main_head" "$sha")" || return 1; [[ "$sha" == "$initial_sha" || -z "$unit_json" ]] || acceptance_criteria_coverage_check "$unit_json" "$dir" "$base" "$sha" || return 1
  # CI preserves candidate edits and backfills the remaining helpers from main.
  # Never execute a candidate helper on the controller: use the isolated cihost
  # checkout, where the full candidate module environment is available.
  for part in scripts/ci/touched-package-selection.mjs scripts/checks/authenticated-origin-contract-packages.mjs; do
    if [[ -f "$dir/$part" ]] && ! git diff --quiet "$base" "$sha" -- "$part"; then changed_helpers=1; fi
  done
  if (( changed_helpers )); then
    selection_log="$(mktemp "${TMPDIR:-/tmp}/self-check-selection.XXXXXX")" || return 1
    if "$entry" "$dir" -- bash -c '
      set -e
      for part in scripts/ci/touched-package-selection.mjs scripts/checks/authenticated-origin-contract-packages.mjs; do
        if [[ ! -f "$part" ]] || git diff --quiet "$1" "$2" -- "$part"; then
          mkdir -p "$(dirname "$part")"
          git show "refs/remotes/origin/main:$part" > "$part"
        fi
      done
      if selected="$(timeout -k 10 "$3" node --experimental-strip-types scripts/ci/touched-package-selection.mjs --repo "$PWD" --base "$1" --head "$2")"; then :
      else
        status=$?; (( status != 124 )) || echo "self-check: package selector timed out after ${3}s"
        exit "$status"
      fi
      printf "ZF_PACKAGE_SELECTION %s\n" "$(printf %s "$selected" | base64 -w0)"' self-check-selector "$base" "$sha" "$step_s" > "$selection_log" 2>&1; then
      selection="$(sed -n 's/^ZF_PACKAGE_SELECTION //p' "$selection_log" | tail -1 | base64 -d)"
      sed '/^ZF_PACKAGE_SELECTION /d' "$selection_log"
      rm -f "$selection_log"
      [[ -n "$selection" ]] || return 1
    else
      rc=$?; cat "$selection_log"; rm -f "$selection_log"; return "$rc"
    fi
  else
    selection_dir="$(mktemp -d "${TMPDIR:-/tmp}/self-check-selector.XXXXXX")" || return 1
    mkdir -p "$selection_dir/scripts/ci" "$selection_dir/scripts/checks" || { rm -rf "$selection_dir"; return 1; }
    for part in scripts/ci/touched-package-selection.mjs scripts/checks/authenticated-origin-contract-packages.mjs; do
      command git -C "$ROOT" show "refs/remotes/origin/main:$part" > "$selection_dir/$part" \
        || { rm -rf "$selection_dir"; return 1; }
    done
    selection="$(node --experimental-strip-types "$selection_dir/scripts/ci/touched-package-selection.mjs" --repo "$dir" --base "$base" --head "$sha")" \
      || { rm -rf "$selection_dir"; return 1; }
    rm -rf "$selection_dir"
  fi
  if [[ "$(jq '.rootNames | length' <<<"$selection")" == 0 ]]; then
    echo 'self-check: no workspace package touched'
    targets=""
  else
    targets="$(jq -r '.affectedNames[]' <<<"$selection")" || return 1
  fi
  test_targets=""
  if [[ -n "$targets" ]]; then
    while IFS= read -r paths; do
      # Selection from candidate code may be untrusted: read manifests only from
      # the candidate Git tree, never from an arbitrary controller filesystem path.
      manifest="$(command git -C "$dir" show "$sha:$paths/package.json")" || return 1
      if [[ -n "$(jq -r '.scripts.test // empty' <<<"$manifest")" ]]; then
        test_targets+="$(jq -r '.name' <<<"$manifest")"$'\n'
      fi
    done < <(jq -r '.affectedPaths[]' <<<"$selection")
  fi
  [[ "$lane" == pr && "$pr_base" == main && "$run_main_pr_tests" != 1 ]] && delegate_tests=1
  while read -r pkg; do [[ -n "$pkg" ]] || continue; builds+=(--filter "$pkg..."); done <<<"$targets"
  cached_tests=""
  while read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if (( ! delegate_tests )) && test_evidence_has_pass "$tree" "test:$pkg"; then cached_tests+="$pkg"$'\n'; fi
  done <<<"$test_targets"
  echo "self-check head=$sha tree=$tree base=$base affected=$targets"
  # Every step is bounded: a hung test becomes a red result, not a unit stuck in review-pending.
  if [[ "${ZF_SELF_CHECK_LOCAL:-}" != 1 ]]; then
    local builds_arg="" remote_output
    for pkg in "${builds[@]}"; do builds_arg+=" $pkg"; done
    remote_output="$(mktemp "${TMPDIR:-/tmp}/self-check-evidence.XXXXXX")" || return 1
    if "$entry" "$dir" -- bash -c '
      set -o pipefail
      export VITEST_MAX_WORKERS=2 VITEST_MAX_FORKS=2 VITEST_MAX_THREADS=2 VITEST_MIN_FORKS=1
      export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 BASE_SHA="$1"
      step_s="$6" tree="$7" delegate_tests="$8"
      rc=0
      if [[ -n "$2" ]]; then
        # shellcheck disable=SC2086
        timeout -k 10 "$step_s" pnpm $2 --workspace-concurrency=2 --if-present run build || { srg=$?; rc=1; (( srg != 124 )) || echo "self-check: build timed out after ${step_s}s"; }
      fi
      for paths in typecheck test lint; do
        if [[ "$paths" == test ]]; then test_started=$SECONDS; fi
        while read -r pkg; do
          [[ -n "$pkg" ]] || continue
          if [[ "$paths" == test ]] && grep -Fxq "$pkg" <<<"$4"; then
            if (( delegate_tests )); then
              echo "self-check: test $pkg delegated to Touched packages PR gate tree=$tree"
              continue
            fi
            if grep -Fxq "$pkg" <<<"$5"; then
              echo "self-check: test $pkg reused tree=$tree"
              continue
            fi
          fi
          echo "self-check: $paths $pkg"
          if timeout -k 10 "$step_s" pnpm --filter "$pkg" --if-present run "$paths"; then
            if [[ "$paths" == test ]] && grep -Fxq "$pkg" <<<"$4"; then echo "ZF_TEST_EVIDENCE_PASS test:$pkg"; fi
          else
            srg=$?; rc=1; (( srg != 124 )) || echo "self-check: $paths $pkg timed out after ${step_s}s"
          fi
        done <<<"$3"
        if [[ "$paths" == test ]]; then echo "self-check: test duration=$((SECONDS-test_started))s"; fi
      done
      if ZF_ESCAPE_SUITE_RUNNER=1 ZF_ESCAPE_SUITE_BASE="$1" ZF_ESCAPE_SUITE_HEAD="$9" ZF_ESCAPE_SUITE_TIMEOUT_S="$step_s" node --input-type=module -e "${10}"; then :; else srg=$?; rc=1; fi; if [[ -f "${ZF_PACK_REL:-engine}/lesson-lints.mjs" ]]; then if node "${ZF_PACK_REL:-engine}/lesson-lints.mjs" --repo "$PWD" --base "$1" --head "$9"; then echo "risk-review-check: lesson-lints rc=0"; else srg=$?; echo "risk-review-check: lesson-lints rc=$srg"; rc=1; fi; else echo "risk-review-check: lesson-lints unavailable"; fi
      exit "$rc"' self-check "$base" "$builds_arg" "$targets" "$test_targets" "$cached_tests" "$step_s" "$tree" "$delegate_tests" \
      "$sha" "$runner_source" \
      | tee "$remote_output"; then
      rc=0
    else
      rc=$?
    fi
    while IFS= read -r marker; do
      [[ "$marker" == 'ZF_TEST_EVIDENCE_PASS test:'* ]] || continue
      target="${marker#ZF_TEST_EVIDENCE_PASS }"
      pkg="${target#test:}"
      grep -Fxq "$pkg" <<<"$test_targets" && test_evidence_record_pass "$tree" "$target" self-check
    done < "$remote_output"
    rm -f "$remote_output"
    return "$rc"
  fi
  if [[ -n "$targets" ]]; then
    export VITEST_MAX_WORKERS=2 VITEST_MAX_FORKS=2 VITEST_MAX_THREADS=2 VITEST_MIN_FORKS=1
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 BASE_SHA="$base"
    timeout 900 pnpm install --frozen-lockfile --offline || timeout 900 pnpm install --frozen-lockfile || return 1
    timeout -k 10 "$step_s" pnpm "${builds[@]}" --workspace-concurrency=2 --if-present run build || { srg=$?; rc=1; (( srg != 124 )) || echo "self-check: build timed out after ${step_s}s"; }
    for paths in typecheck test lint; do
      if [[ "$paths" == test ]]; then test_started=$SECONDS; fi
      while read -r pkg; do
        [[ -n "$pkg" ]] || continue
        if [[ "$paths" == test ]] && grep -Fxq "$pkg" <<<"$test_targets"; then
          if (( delegate_tests )); then
            echo "self-check: test $pkg delegated to Touched packages PR gate tree=$tree"
            continue
          fi
          if test_evidence_has_pass "$tree" "test:$pkg"; then
            echo "self-check: test $pkg reused tree=$tree"
            continue
          fi
        fi
        echo "self-check: $paths $pkg"
        if timeout -k 10 "$step_s" pnpm --filter "$pkg" --if-present run "$paths"; then
          if [[ "$paths" == test ]] && grep -Fxq "$pkg" <<<"$test_targets"; then test_evidence_record_pass "$tree" "test:$pkg" self-check; fi
        else
          srg=$?; rc=1; (( srg != 124 )) || echo "self-check: $paths $pkg timed out after ${step_s}s"
        fi
      done <<<"$targets"
      if [[ "$paths" == test ]]; then echo "self-check: test duration=$((SECONDS-test_started))s"; fi
    done
  else
    echo 'self-check: test duration=0s'
  fi
  if ZF_ESCAPE_SUITE_RUNNER=1 ZF_ESCAPE_SUITE_BASE="$base" ZF_ESCAPE_SUITE_HEAD="$sha" ZF_ESCAPE_SUITE_TIMEOUT_S="$step_s" node --input-type=module -e "$runner_source"; then :
  else rc=1; fi
  return "$rc"
)
pid_start() { pid_start_id "$1"; } # start ticks: tells a reused pid from the gate
self_check_verification_run() ( # unit head clone config output metadata; success writes the verification evidence record
  local id="$1" sha="$2" dir="$3" config="$4" command_output="$5" metadata="$6" argv_json timeout_s evidence_dir files_json rc=0 arg
  local -a argv=() evidence_files=() overlaid=()
  local base="${7:-}"
  set -o pipefail
  if [[ ! -r "$config" ]]; then printf 'verification refused unit=%s: config is unreadable\n' "$id"; return 1; fi
  if ! jq . "$config" >/dev/null 2>&1; then printf 'verification refused unit=%s: state/verification.json is not valid JSON\n' "$id"; return 1; fi
  if ! jq -e 'type=="object" and (.argv|type=="array" and length>0 and all(.[]; type=="string" and (contains("\u0000")|not)))' "$config" >/dev/null 2>&1; then
    printf 'verification refused unit=%s: argv must be a non-empty array of strings\n' "$id"; return 1
  fi
  if ! jq -e 'has("timeout_s") and (.timeout_s|type=="number" and .>0 and floor==.)' "$config" >/dev/null 2>&1; then
    printf 'verification refused unit=%s: timeout_s must be a positive integer\n' "$id"; return 1
  fi
  if ! jq -e '(.evidence_dir|type=="string" and length>0 and (startswith("/")|not) and (split("/")|index("..") == null) and (contains("\u0000")|not))' "$config" >/dev/null 2>&1; then
    printf 'verification refused unit=%s: evidence_dir must be a relative path inside the clone\n' "$id"; return 1
  fi
  argv_json="$(jq -c '.argv' "$config")"; timeout_s="$(jq -r '.timeout_s|floor' "$config")"; evidence_dir="$(jq -r '.evidence_dir' "$config")"
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < <(jq -j '.argv[] | ., "\u0000"' "$config")
  # argv paths tracked at the trusted base run that base copy, not the unit head; the head copy is restored after the run.
  for arg in "${argv[@]}"; do
    [[ -n "$base" && -n "$arg" && "$arg" != /* && "$arg" != *..* ]] || continue
    [[ "$(git -C "$dir" cat-file -t "$base:$arg" 2>/dev/null)" == blob ]] || continue
    if ! git -C "$dir" diff --quiet "$base" "$sha" -- "$arg"; then say "verification: ignored head copy for this run unit=$id path=$arg"; fi
    mkdir -p "$(dirname "$dir/$arg")" && git -C "$dir" show "$base:$arg" > "$dir/$arg" \
      || { printf 'verification refused unit=%s: could not write base copy path=%s\n' "$id" "$arg"; return 1; }
    overlaid+=("$arg")
  done
  if (cd "$dir" && timeout -k 10 "$timeout_s" "${argv[@]}") 2>&1 | awk 'NR <= 20' > "$command_output"; then rc=0; else rc=$?; fi
  for arg in "${overlaid[@]}"; do
    if git -C "$dir" cat-file -e "$sha:$arg" 2>/dev/null; then
      git -C "$dir" checkout -q "$sha" -- "$arg" || { printf 'verification failed unit=%s: could not restore head copy path=%s\n' "$id" "$arg"; return 1; }
    else
      rm -f -- "$dir/$arg"
    fi
  done
  if (( rc != 0 )); then
    printf 'verification failed unit=%s exit_code=%s argv=%s evidence=%s\n' "$id" "$rc" "$argv_json" "$evidence_dir"
    if [[ -s "$command_output" ]]; then sed -n '1,20p' "$command_output"; else printf '(no command output)\n'; fi
    return 1
  fi
  while IFS= read -r -d '' arg; do evidence_files+=("$arg"); done < <(git -C "$dir" ls-files -z --cached --others -- "$evidence_dir")
  files_json='[]'
  if (( ${#evidence_files[@]} )); then files_json="$(printf '%s\0' "${evidence_files[@]}" | jq -Rs 'split("\u0000")[:-1]')" || return 1; fi
  jq -cn --argjson argv "$argv_json" --argjson files "$files_json" --arg dir "$evidence_dir" --arg sha "$sha" \
    '{argv:$argv,exit_code:0,evidence_dir:$dir,evidence_files:$files,sha:$sha}' > "$metadata" \
    || { printf 'verification failed unit=%s: could not record evidence path=%s\n' "$id" "$evidence_dir"; return 1; }
  for arg in "${evidence_files[@]:0:5}"; do # evidence is often untracked, so the review clone lacks it: keep a bounded excerpt now
    [[ -f "$dir/$arg" && ! -L "$dir/$arg" ]] || continue
    { printf '\n=== evidence %s (first 4000 bytes) ===\n' "$arg"; head -c 4000 -- "$dir/$arg" | tr -d '\0' || true; printf '\n'; } >> "$command_output"
  done
  printf 'verification passed unit=%s exit_code=0 argv=%s evidence=%s files=%s\n' "$id" "$argv_json" "$evidence_dir" "$files_json"
)
self_check_verification_body() { # unit JSON → the PR's verification section when this head passed
  [[ -n "$1" ]] || return 0
  jq -e '.self_check_status=="pass" and .verification.exit_code==0 and .verification.sha==.self_check_sha' <<<"$1" >/dev/null 2>&1 || return 0
  printf '\n\n## verification\nCommand argv (JSON): %s\nExit code: %s\nEvidence files (relative to clone): %s\n' \
    "$(jq -c '.verification.argv' <<<"$1")" "$(jq -r '.verification.exit_code' <<<"$1")" "$(jq -c '.verification.evidence_files' <<<"$1")"
}
self_check_before_review() { # unit sha clone; false means wait for the gate/self-fix
  local id="$1" sha="$2" dir="$3" u="${4:-}" out result pid rc lane pr pr_base="" reason gate config_file="" config_base="" config_temp="" incident_reason report_hash
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  lane="$(jqf -r '.lane // empty' <<<"$u")"; report_hash="$(self_check_report_fingerprint "$u")"
  if [[ "$lane" == pr ]]; then
    pr="$(jqf -r '.pr // empty' <<<"$u")"
    pr_base="$(tick_pr_base "$pr")" || pr_base=""
  fi
  if [[ "$(jqf -r '.self_check_sha // empty' <<<"$u")" == "$sha" && -n "$(jqf -r '.self_check_status // empty' <<<"$u")" \
      && "$(jqf -r '.self_check_lane // empty' <<<"$u")" == "$lane" \
      && "$(jqf -r '.self_check_base // empty' <<<"$u")" == "$pr_base" && "$(jqf -r '.self_check_report_hash // empty' <<<"$u")" == "$report_hash" ]]; then
    if [[ "$(jqf -r '.self_check_status // empty' <<<"$u")" == red ]]; then self_check_red_to_repair "$id" "$(jqf -r '.self_check_output // empty' <<<"$u")"; return 1; fi
    # No fetched main ref can establish staleness; self_check_run requires one before it runs.
    if self_check_main_fresh "$dir" "$sha" || ! git -C "$dir" rev-parse --verify refs/remotes/origin/main^{commit} >/dev/null 2>&1; then return 0; fi
  fi
  out="$SUP/self-check-$id-$sha-$(jqf -r '.self_check_fixes // 0' <<<"$u")-$TAG.log"; result="$out.result"
  config_base=origin/main
  [[ "$lane" == pr ]] && config_base="$pr_base"
  if [[ -n "$config_base" ]] && git -C "$dir" rev-parse --verify "$config_base^{commit}" >/dev/null 2>&1; then
    config_temp="$(mktemp "${out}.verification-config.XXXXXX")" || return 1
    if git -C "$dir" show "$config_base:.zenoforge/state/verification.json" > "$config_temp" 2>/dev/null; then
      config_file="$config_temp"
    else
      rm -f "$config_temp"; config_temp=""
    fi
    if ! git -C "$dir" diff --quiet "$config_base" "$sha" -- .zenoforge/state/verification.json; then
      say "verification: ignored head copy for this run unit=$id path=.zenoforge/state/verification.json"
    fi
  fi
  [[ -n "$config_file" ]] || config_file="$( (unset ZF_CONFIG_ROOT; sched_config_file state/verification.json 2>/dev/null) || true)"
  if [[ -z "$config_file" && "$(jqf -r '.verification_skip_logged // false' <<<"$u")" != true ]]; then
    incident_reason="$(incident_report_gate_reason "$u")"
    if [[ -z "$incident_reason" ]]; then
      set_unit "$id" '.verification_skip_logged=true' || return 1
      say "verification: skipped unit=$id (no state/verification.json)"
    fi
  fi
  rm -f "$out.verification.json" "$out.verification-output"
  (
    # Run report gates before checks so the original session can repair the report via self-fix.
    reason="$(decision_log_gate_reason "$u")"
    if [[ -n "$reason" ]]; then gate=decision-log; else
      reason="$(how_why_gate_reason "$u")"
      if [[ -n "$reason" ]]; then gate='how/why'; else gate='incident report'; reason="$(incident_report_gate_reason "$u")"; fi
    fi
    if [[ -n "$reason" ]]; then
      printf '%s check failed: %s\nreport: %s\n' "$gate" "$reason" "$(jqf -r '.implementation_report // .report // empty' <<<"$u")"
      printf 'red\n' > "$result"
    elif ! acceptance_criteria_coverage_check "$u" "$dir" "$config_base" "$sha"; then printf 'red\n' > "$result"
    elif [[ -n "$config_file" ]] && ! self_check_verification_run "$id" "$sha" "$dir" "$config_file" "$out.verification-output" "$out.verification.json" "$config_base"; then
      printf 'red\n' > "$result"
    elif self_check_run "$dir" "$sha" "$lane" "$pr_base" "$id" "$(jqf -r '.branch // empty' <<<"$u")" "$(jqf -r '.pr // empty' <<<"$u")" "$u"; then
      printf 'pass\n' > "$result"
    else
      rc=$?
      # 75 (cihost admission queue) and 125 (transfer/setup) are not verdicts.
      if (( rc == 76 )); then printf 'conflict\n' > "$result"
      elif (( rc == 75 || rc == 125 )); then printf '%s\n' "$rc" > "$result.rc"; printf 'defer\n' > "$result"
      else printf 'red\n' > "$result"; fi
    fi
    [[ -z "$config_temp" ]] || rm -f "$config_temp"
    git -C "$dir" rev-parse HEAD > "$out.head" 2>/dev/null || :
  ) > "$out" 2>&1 < /dev/null &
  pid=$!
  set_unit "$id" ".self_check_pid=$pid | .self_check_start=$(js "$(pid_start "$pid")") | .self_check_sha=$(js "$sha") | .self_check_lane=$(js "$lane") | .self_check_base=$(js "$pr_base") | .self_check_report_hash=$(js "$report_hash") | .self_check_status=null | .self_check_output=$(js "$out") | .self_check_workdir=$(js "$dir") | .self_check_return_stage=.stage"
  say "self-check pid=$pid unit=$id head=$sha (before review)"
  return 1
}
self_check_failure_class() { # log → short class of the first failure line
  local line
  line="$(grep -a -m1 -E '^[^:]{1,80} check failed:|^verification failed|AssertionError|^not ok [0-9]+|^FAIL([[:space:]]|$)|ERR_PNPM|ELIFECYCLE|timed out|(^|[[:space:]])error:' "$1" 2>/dev/null || true)"
  case "$line" in
    *" check failed:"*) printf '%s\n' "${line%%:*}" ;;
    'verification failed'*) printf 'verification failed\n' ;;
    *AssertionError*) printf 'assertion failure\n' ;;
    *'not ok '*|FAIL*) printf 'test failure\n' ;;
    *ERR_PNPM*|*ELIFECYCLE*) printf 'package script failure\n' ;;
    *'timed out'*) printf 'timeout\n' ;;
    *error:*|*Error:*) printf 'command error\n' ;;
    *) printf 'self-check failure\n' ;;
  esac
}
self_check_red_to_repair() { local hint="The deterministic self-check failed. Full output from $2:"$'\n'"$(cat "$2" 2>/dev/null || true)"
  set_unit "$1" ".self_fix_pending=false | .self_fix_active=false | .approved_sha=null | .reviewed_sha=null | .reviewed_pr_head=null | .repair_hint=$(js "$hint") | .stage=\"repair-pending\""; }
self_check_harvest() {
  local id pid out start status fixes sid model verification_json verification_update reason_update checked_head sha defer_rc defer_rc_update
  while IFS=$'\t' read -r id pid out start; do
    scheduler_lock_yield_between_units || return 1
    [[ "${SCHEDULER_LOCK_YIELDED:-false}" != true \
      || ( "$(unit_field "$id" '.self_check_pid // empty')" == "$pid" \
        && "$(unit_field "$id" '.self_check_output // empty')" == "$out" \
        && "$(unit_field "$id" '.self_check_start // empty')" == "$start" ) ]] || continue
    if [[ ! -s "$out.result" ]]; then
      if kill -0 "$pid" 2>/dev/null && { [[ -z "$start" || "$(pid_start "$pid")" == "$start" ]]; }; then continue; fi
      # Gate died (reboot, SIGKILL) before any verdict: the check never failed, so run it again.
      say "self-check interrupted without a result unit=$id: rerun"
      set_unit "$id" "$(hist self-check-interrupted "$out") | del(.self_check_pid, .self_check_start, .self_check_sha, .self_check_status)"
      continue
    fi
    status="$(cat "$out.result")"; reason_update=""
    if [[ "$status" == defer ]]; then sha="$(unit_field "$id" '.self_check_sha // empty')"; defer_rc="$(cat "$out.result.rc" 2>/dev/null || true)"; if [[ "$defer_rc" == 125 ]] && (( $(self_check_deferred_count "$id" "$sha") >= 3 )); then status=red; reason_update=" | .history[-1].reason=$(js "self-check retry limit reached after 3 rc 125 deferrals for sha=$sha")"; printf 'self-check retry limit reached after 3 rc 125 deferrals for sha=%s\n' "$sha" >> "$out"; say "self-check red unit=$id: self-check retry limit reached after 3 rc 125 deferrals for sha=$sha"; else defer_rc_update=""; [[ "$defer_rc" != 125 ]] || defer_rc_update=' | .history[-1].defer_rc=125'; [[ "$defer_rc" != 75 ]] || defer_rc_update=' | .history[-1].defer_rc=75'; say "self-check deferred unit=$id: rc=$defer_rc; rerun next tick"; set_unit "$id" "$(hist self-check-deferred "$out") | .history[-1].sha=$(js "$sha")$defer_rc_update | del(.self_check_pid, .self_check_start, .self_check_sha, .self_check_status)"; continue; fi
    fi
    if [[ "$status" == conflict ]]; then
      set_unit "$id" 'del(.self_check_pid, .self_check_start) | .self_check_status="conflict"'
      continue
    fi
    verification_update=""
    if [[ "$status" == pass && -s "$out.verification.json" ]] && verification_json="$(jq -c . "$out.verification.json" 2>/dev/null)"; then
      verification_update=" | .verification=$verification_json"
    fi
    [[ "$status" != red || -n "$reason_update" ]] || reason_update=" | .history[-1].reason=$(js "$(self_check_failure_class "$out")")"
    checked_head="$(cat "$out.head" 2>/dev/null || true)"
    [[ "$checked_head" =~ $SHA_RE ]] || checked_head="$(unit_field "$id" '.self_check_sha // empty')"
    set_unit "$id" "$(hist "self-check-$status" "$out") | del(.self_check_pid, .self_check_start) | .self_check_sha=$(js "$checked_head") | .self_check_status=$(js "$status")$verification_update$reason_update"
    [[ "$status" == red ]] || continue
    fixes="$(unit_field "$id" '.self_check_fixes // 0')"
    sid="$(unit_field "$id" '.session_ids.repair')"; model="$(unit_field "$id" .implement_model)"
    if (( fixes < 2 )) && [[ "$sid" =~ $SESSION_RE && -n "$model" && "$model" != claude-* ]]; then set_unit "$id" '.self_fix_pending=true'
    else self_check_red_to_repair "$id" "$out"; say "self-check red unit=$id: routed to repair (fixes=$fixes, original session=${sid:-unavailable})"; fi
  done < <(jqf -r '.units[] | select(.self_check_pid!=null) | [.id,.self_check_pid,.self_check_output,(.self_check_start // "")] | @tsv' "$UNITS")
  scheduler_lock_yield_between_units || return 1
}
self_fix_dispatch() { # unit JSON; keep its selected provider/session unless quota or hard-tier routing changes it
  local u="$1" id dir branch out rep impl_report prompt model effort provider hard_escalation route_reason route_provider deliver key failure
  id="$(jqf -r .id <<<"$u")"
  room_for "$id" repair "$u" false || return 1
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  pick implement "$u" || return 1
  model="$PICK_MODEL"; effort="$PICK_EFFORT"; provider="$PICK_PROVIDER"
  hard_escalation="$PICK_HARD"; route_reason="$PICK_REASON"; route_provider="$PICK_ROUTE_PROVIDER"
  dir="$(jqf -r .self_check_workdir <<<"$u")"; branch="$(jqf -r .branch <<<"$u")"
  git -C "$dir" checkout -q "$branch" || return 1
  out="$(jqf -r .self_check_output <<<"$u")"; key="$(jqf -r '.pr // .id' <<<"$u")"
  rep="impl-${key}-selfcheck$(( $(jqf -r '.self_check_fixes // 0' <<<"$u") + 1 ))-fix-${TAG}.md"
  if [[ "$(jqf -r .lane <<<"$u")" == direct-main ]]; then
    deliver="node scripts/branch-delivery-preflight.mjs --mode commit 通过后在原分支提交，不 push。"
  else
    deliver="node scripts/branch-delivery-preflight.mjs --mode push --publish-topic，通过后交付原分支。"
  fi
  failure="实现后的确定性自检失败。完整输出：$out
$(cat "$out")"
  prompt="实现后的确定性自检失败，尚未派出评审。这是原实现会话的自修复，保持原任务范围，修复下列失败，不弱化断言。$failure
在当前隔离 clone ${dir}、原分支 $branch 修复；$deliver 禁止 merge PR、部署或修改 GitHub 状态。把修复和验证证据写到 $SUP/${rep}，然后结束，流水线会重跑同一自检。
$(matt_method_rule "$dir")"
  # The incident sections live in the unit's implementation report, so an incident report failure is repaired there in place; the fix note keeps its own path.
  if grep -q '^incident report check failed' "$out"; then
    impl_report="$(jqf -r '.implementation_report // empty' <<<"$u")"
    prompt+="
失败项是事故报告结构检查：请就地修改原实现报告 $SUP/${impl_report:-$rep}（保留原有内容，补齐 ## root-cause、带 kind: 行的 ## recurrence-guard、带 http(s) 来源 URL 的 ## prior-art），不要另写一份替代它；$SUP/${rep} 只写修复说明。"
  elif grep -q '^acceptance-criteria coverage check failed' "$out"; then prompt+="$(acceptance_criteria_coverage_repair_prompt "$u" "$rep")"
  elif grep -q '^decision-log check failed' "$out"; then
    impl_report="$(jqf -r '.implementation_report // .report // empty' <<<"$u")"
    prompt+="
失败项是决策日志结构检查：请就地修改原实现报告 $SUP/${impl_report:-$rep}，在 ## decision-log 中简要写明试过什么、失败原因、最终选择和验证方式；保留原有内容，不要另写替代报告。$SUP/${rep} 只写修复说明。"
  elif grep -q '^how/why check failed' "$out"; then
    impl_report="$(jqf -r '.implementation_report // .report // empty' <<<"$u")"
    prompt+="
失败项是 how/why 结构检查：请就地修改原实现报告 $SUP/${impl_report:-$rep}，补齐非空 ## how（说明触及代码当前如何工作）和 ## why（说明设计原因，并引用至少一个 7 位以上十六进制 commit SHA 或 #N issue）；保留原有内容，不要另写替代报告。$SUP/${rep} 只写修复说明。"
  fi
  if [[ "$(jqf -r '.implement_model // empty' <<<"$u")" == "$model" \
      && "$(jqf -r '.implement_effort // empty' <<<"$u")" == "$effort" \
      && "$(jqf -r '.implement_provider // empty' <<<"$u")" == "$provider" ]]; then
    set_unit "$id" '.self_fix_active=true'
  else
    set_unit "$id" '.self_fix_active=false'
  fi
  if dispatch_if_room "$id" repair repair "${rep%.md}.worker.log" "$rep" "$model" "$effort" "$prompt" "" "$dir" "" "$failure" "$u" true "$provider" "$hard_escalation" "$route_reason" "$route_provider"; then
    set_unit "$id" "$(hist self-fix-dispatched) | .self_fix_pending=false | .self_check_fixes=((.self_check_fixes // 0)+1)"
  else
    set_unit "$id" '.self_fix_active=false'
    return 1
  fi
}
unit_dispatch_priority() { # unit-json → hotfix|opt|normal
  if [[ "$(jqf -r '.hotpatch // false' <<<"$1")" == true ]]; then printf 'hotfix\n'
  elif [[ "$(jqf -r '.lane // empty' <<<"$1")" == direct-main ]]; then printf 'opt\n'
  else printf 'normal\n'; fi
}
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../bin" && pwd -P)/luna-capacity.sh"
higher_priority_waiting() { # priority → sets waiter and age; always drops stale files
  local priority="$1" f pid name hotfix="" opt="" hotfix_age=0 opt_age=0 max age mtime now=""
  max="${AUTOPI_PRIORITY_HOLD_MAX_SECONDS:-1200}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=1200
  PRIORITY_WAITING_WAITER=""
  PRIORITY_WAITING_AGE_SECONDS=0
  for f in "$LUNA_SLOTS"/wait-hotfix-* "$LUNA_SLOTS"/wait-opt-*; do
    [[ -e "$f" ]] || continue
    pid="${f##*-}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      name="${f##*/}"
      age=0
      mtime="$(stat -c %Y -- "$f" 2>/dev/null)" || mtime=""
      if [[ "$mtime" =~ ^[0-9]+$ ]]; then
        [[ -n "$now" ]] || now="$(date +%s)"
        age=$((now - mtime)); if (( age < 0 )); then age=0; fi
        if (( age > max )); then
          if [[ -z "${TICK_PRIORITY_HOLD_EXPIRED[$name]:-}" ]]; then
            say "priority hold expired for $name after ${age}s; normal dispatch resumes"
            TICK_PRIORITY_HOLD_EXPIRED[$name]=1
          fi
          continue
        fi
      fi
      case "$name" in
        wait-hotfix-*) if [[ -z "$hotfix" ]]; then hotfix="$name"; hotfix_age="$age"; fi ;;
        wait-opt-*) if [[ -z "$opt" ]]; then opt="$name"; opt_age="$age"; fi ;;
      esac
    else
      rm -f -- "$f"
    fi
  done
  case "$priority" in
    hotfix) return 1 ;;
    opt) [[ -n "$hotfix" ]] && { PRIORITY_WAITING_WAITER="$hotfix"; PRIORITY_WAITING_AGE_SECONDS="$hotfix_age"; return 0; } ;;
    *)
      [[ -n "$hotfix" ]] && { PRIORITY_WAITING_WAITER="$hotfix"; PRIORITY_WAITING_AGE_SECONDS="$hotfix_age"; return 0; }
      [[ -n "$opt" ]] && { PRIORITY_WAITING_WAITER="$opt"; PRIORITY_WAITING_AGE_SECONDS="$opt_age"; return 0; }
      ;;
  esac
  return 1
}

declare -gA TICK_PRIORITY_ADMISSION_CACHE=()
priority_admission_has_room() { # priority age [backend]; dispatch_pending caches one resource sample per priority, waiter age and backend between starts
  local priority="$1" age="$2" backend="${3:-}" result cache_key
  if [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]]; then
    LUNA_PRIORITY="$priority" box_has_room "$age" "$backend"
    return $?
  fi
  cache_key="$priority:$age:$backend:${LUNA_CPU_TARGET:-85}" # the host-capacity start and the priority-wait check use different CPU targets
  result="${TICK_PRIORITY_ADMISSION_CACHE[$cache_key]:-}"
  # An admit at a stricter CPU target implies an admit at a looser one: one host sample per start (#1129); the backend is part of the match (row 905): each backend's ask is its own peak.
  local k
  for k in "${!TICK_PRIORITY_ADMISSION_CACHE[@]}"; do
    [[ -z "$result" && "$k" == "$priority:$age:$backend:"* && "${TICK_PRIORITY_ADMISSION_CACHE[$k]%%|*}" == admit && "${k##*:}" -le "${LUNA_CPU_TARGET:-85}" ]] && result=admit
  done
  if [[ -z "$result" ]]; then
    if LUNA_PRIORITY="$priority" box_has_room "$age" "$backend"; then result=admit; else result="hold|$BOX_ROOM_WHY"; fi
    TICK_PRIORITY_ADMISSION_CACHE[$cache_key]="$result"
  fi
  if [[ "$result" == admit ]]; then BOX_ROOM_WHY=""; return 0; fi
  BOX_ROOM_WHY="${result#hold|}"
  return 1
}

priority_wait_should_hold() { # normal dispatch yields only while the selected waiter is also blocked
  local priority="$1" waiter="$2" waiter_priority age="${PRIORITY_WAITING_AGE_SECONDS:-0}"
  [[ "$priority" == normal ]] || return 0 # preserve strict hotfix-over-opt ordering
  waiter_priority="${waiter#wait-}"; waiter_priority="${waiter_priority%%-*}"
  if [[ "$waiter_priority" == hotfix ]] && priority_admission_has_room hotfix "$age"; then return 1; fi
  priority_admission_has_room normal "$age" || return 0
  return 1
}

dispatch_capacity_free() { # worker slot available; the same predicate room_for enforces per unit
  local cur; cur="$(live_workers)"
  (( cur < MAX ))
}
# Apart from the predicate: the pack's dispatch-queue-footprint test stubs that false and must still reach footprint_room.
dispatch_walk_full() { ! dispatch_capacity_free; }
# Walk passes that drop a pending unit without a log line are counted by reason; the refill and tick summaries name them.
declare -gA TICK_DISPATCH_SKIPS=()
declare -gA TICK_PRIORITY_HOLD_EXPIRED=()
# 11-20: parked/blocked units are stopped work, not flow; counting them (152 live at 08:40Z) would stop every new implement.
STARTED_WIP_STAGES='["implement","review","review-pending","rereview","rereview-pending","repair","repair-pending","supervise","supervisor-review","ready-to-merge","landing"]'
dispatch_skip() { TICK_DISPATCH_SKIPS[$1]=$(( ${TICK_DISPATCH_SKIPS[$1]:-0} + 1 )); dispatch_why "${why_unit:-}" "$1"; }
dispatch_skip_summary() { # name:count,... for the reasons that fired this pass, sorted; empty when none
  local k out=""
  (( ${#TICK_DISPATCH_SKIPS[@]} )) || return 0
  for k in $(printf '%s\n' "${!TICK_DISPATCH_SKIPS[@]}" | sort); do out+="${out:+,}$k:${TICK_DISPATCH_SKIPS[$k]}"; done
  printf '%s' "$out"
}
declare -F dmark >/dev/null || dmark() { :; } # dispatch-queue.sh defines the step timer; a unit test that loads this file alone gets a no-op
room_for() { # unit-id type [unit-json] [fresh-footprint=true] [check-footprint=true] [report-only=false]：焦点与并发检查
  local u="${3:-}" priority backend="" waiter n_impl n_repair started_wip hold_now hold_since hold_elapsed hold_alerted hold_line hold_max fresh_footprint="${4:-true}" check_footprint="${5:-true}" gate_started gate_elapsed gate_waiting=false why_unit="$1"
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$1" '.units[] | select(.id==$id)' "$UNITS")"
  # A report-only continuation writes no code and starts no write-start: the repair round cap and the Dagger runtime gate do not apply to it.
  if [[ "$2" == repair && "${6:-false}" != true ]]; then repair_cap_admission "$1" "$u" || { dispatch_skip repair-cap; return 1; }; fi
  if [[ "$2" == repair && "${6:-false}" != true ]]; then repair_runtime_admission "$1" "$u" || { dispatch_skip repair-runtime; return 1; }; fi
  if [[ "$2" == review || "$2" == rereview ]]; then
    jqf -e '(.self_check_pid // null)==null and (.self_fix_pending // false)!=true' <<<"$u" >/dev/null || { dispatch_skip self-check; return 1; }
  fi
  [[ "${TICK_DISPATCH_PAST_DEADLINE:-false}" != true ]] || { dispatch_skip tick-deadline; return 1; }
  if [[ "$FOCUS_MODE" == "release" && "$(unit_is_critical "$u")" != "true" && "$(critical_pending_count)" -gt 0 ]]; then
    FOCUS_SKIPPED+=("$1")
    say "skip dispatch unit=$1 focus=release critical=false"
    dispatch_why "$1" focus-release
    return 1
  fi
  priority="$(unit_dispatch_priority "$u")"
  if [[ "$2" == implement || "$2" == repair ]] && dispatch_known_zcode_start "$u"; then backend=zc; fi # row 905: a known-zcode start asks with the zc backend
  dmark room_pre
  gate_started=$SECONDS
  if [[ "$2" != review && "$2" != rereview ]] && higher_priority_waiting "$priority" \
    && priority_wait_should_hold "$priority" "$PRIORITY_WAITING_WAITER"; then
    waiter="$PRIORITY_WAITING_WAITER"; hold_now="$(date +%s)"
    hold_since="$(jqf -r '.priority_hold.since_epoch // 0' <<<"$u")"; hold_alerted="$(jqf -r '.priority_hold.alerted // false' <<<"$u")"
    if ! [[ "$hold_since" =~ ^[0-9]+$ ]] || (( hold_since == 0 )); then
      hold_since="$hold_now"; hold_alerted=false
      set_unit "$1" ".priority_hold={since_epoch:$hold_since,alerted:false}" || :
    fi
    hold_elapsed=$((hold_now - hold_since))
    hold_max="${AUTOPI_PRIORITY_HOLD_MAX_SECONDS:-1200}"
    [[ "$hold_max" =~ ^[0-9]+$ ]] || hold_max=1200
    if (( hold_elapsed > hold_max )) && [[ "$hold_alerted" != true ]]; then
      hold_line="PRIORITY-HOLD-STARVE unit=$1 waiter=$waiter secs=$hold_elapsed"
      say "$hold_line"
      [[ -f "$A/alerts/waste.md" ]] && echo "[$STAMP] $hold_line" >> "$A/alerts/waste.md"
      set_unit "$1" '.priority_hold.alerted=true' || :
    fi
    gate_waiting=true
  elif [[ "$u" == *'"priority_hold":'* ]]; then
    set_unit "$1" 'del(.priority_hold)' || return 1
  fi
  dmark room_priority_gate
  gate_elapsed=$((SECONDS - gate_started))
  [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || (( gate_elapsed < 2 )) || say "dispatch detail priority_gate unit=$1 secs=${gate_elapsed}s"
  if [[ "$gate_waiting" == true ]]; then
    say "skip dispatch unit=$1 priority=$priority (higher-priority run waiting at luna/zc gate: $waiter)"
    dispatch_why "$1" priority-wait
    return 1
  fi
  if ! dispatch_capacity_free; then say "skip dispatch unit=$1 (capacity $(live_workers)/$MAX)"; dispatch_why "$1" capacity; return 1; fi
  dmark room_live_workers
  # Same host gate as bin/luna (CPU, memory, PSI, run cap); the waiter age keeps an aged waiter's admission rule.
  # 11-13: CPU busy sat over 85% at the host baseline (load ~20 on 12 cores) and held live=0-2 of 8 with 31 pending for hours.
  # Scheduler workers run at CPUWeight=10 (worker-scope.sh), so they already yield the CPU to sessions: this start ignores
  # the CPU sample (AUTOPI_DISPATCH_CPU_TARGET, default 101 = never) while memory, PSI and the run cap stay hard.
  # The priority-wait check above keeps the CPU target, because a waiter at bin/luna is still held by it.
  # Review and report-only resumes are exempt: a refused report resume would fall through to review with the stale report.
  # shortcut: no /proc/meminfo means no gate (box_has_room would refuse every start, issue #9), upgrade when the portable readers land
  if [[ "$2" != review && "$2" != rereview && "${6:-false}" != true && -r "${LUNA_PROC_MEMINFO:-/proc/meminfo}" ]] && ! LUNA_CPU_TARGET="${AUTOPI_DISPATCH_CPU_TARGET:-101}" priority_admission_has_room "$priority" "${PRIORITY_WAITING_AGE_SECONDS:-0}" "$backend"; then
    say "skip dispatch unit=$1 priority=$priority (host capacity: ${BOX_ROOM_WHY:-unknown})"; dispatch_why "$1" host-capacity; return 1
  fi
  dmark room_host_capacity
  if [[ "$2" == implement ]]; then
    started_wip="${TICK_STARTED_WIP_COUNT:-}"
    if [[ ! "$started_wip" =~ ^[0-9]+$ ]]; then
      started_wip="$(jqf -r --argjson stages "$STARTED_WIP_STAGES" '[.units[] | select(.stage as $stage | ($stages | index($stage)) != null)] | length' "$UNITS")"
      [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || TICK_STARTED_WIP_COUNT="$started_wip"
    fi
    if (( started_wip >= STARTED_WIP_LIMIT )); then say "skip dispatch unit=$1 (started WIP $started_wip/$STARTED_WIP_LIMIT)"; dispatch_why "$1" wip-limit; return 1; fi
  fi
  if [[ ( "$2" == "implement" || "$2" == "repair" ) && "$check_footprint" == true ]]; then
    footprint_room "$1" "$u" "$fresh_footprint" || { dmark room_footprint; return 1; }
    dmark room_footprint
  fi
  if [[ "$2" == implement ]]; then
    n_impl=$(live_by_type implement)
    if (( n_impl >= IMPLEMENT_CAP )); then say "skip dispatch unit=$1 (implement at cap $n_impl/$IMPLEMENT_CAP)"; dispatch_why "$1" implement-cap; return 1; fi
  elif [[ "$2" == repair ]]; then
    n_repair=$(live_by_type repair)
    if (( n_repair >= REPAIR_DISPATCH_CAP )); then say "skip dispatch unit=$1 (repair at cap $n_repair/$REPAIR_DISPATCH_CAP)"; dispatch_why "$1" repair-cap; return 1; fi
  fi
}

footprint_recurrence_brief() { # unit JSON → up to 3 ranked CATALOG rules, bounded to 1 KB
  local footprint count brief
  footprint_scope_for "$1" footprint || return 0
  count="$(jqf 'length' <<<"$footprint")" || return 0
  (( count > 0 )) || return 0
  if brief="$(node "${ZF_ENGINE_DIR:-$ROOT/engine}/lesson-recurrence-ranking.mjs" --repo "$ROOT" --footprint-json "$footprint" 2>/dev/null)"; then
    [[ -z "$brief" ]] || printf '%s\n' "$brief"
  fi
  return 0
}

# Each write-start entry names its attempt (the worker log, the key spend_runs and the run's tokens share), the model and the
# dispatch size estimate size_admission_write_start gated on (unit field, else issue state). Recorded for measurement only.
attempt_estimate() { # unit-json → estimated changed lines, empty when unknown
  local issue state est
  est="$(jqf -r '.estimated_changed_lines // empty' <<<"$1")"
  if [[ ! "$est" =~ ^[0-9]+$ ]]; then
    issue="$(jqf -r '.issue // empty' <<<"$1")"
    if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
      state="$(scheduler_issue_state "$issue" 2>/dev/null || true)"
      est="$(jqf -r '.estimated_changed_lines // empty' <<<"$state")"
    fi
  fi
  printf '%s\n' "$est"
}
dispatch_attempt_fields() { # log model unit-json → jq fields for the write-start entry just appended (.history[-1])
  local est band=unknown
  est="$(attempt_estimate "$3")"
  if [[ "$est" =~ ^[0-9]+$ ]]; then
    if (( est <= 300 )); then band='<=300'
    elif (( est <= 480 )); then band='301-480'
    elif (( est <= 640 )); then band='481-640'
    elif (( est <= 800 )); then band='641-800'
    else band='>800'; fi
  else
    est=null
  fi
  printf '.history[-1].attempt=%s | .history[-1].model=%s | .history[-1].estimate_lines=%s | .history[-1].estimate_band=%s' \
    "$(js "$(basename "$1")")" "$(js "$2")" "$est" "$(js "$band")"
}

# 开工前复查（write-start）：PR-less 单元的 issue 已关、或它的修复已合并，就退役而不派 worker（row 161：这类单元烧掉 2100 万 raw token）。
# 只读派发门禁的依赖缓存（dep_cache_info，DEP_CHECK_SECONDS 批量刷新），不逐单元调 GitHub。
# shortcut: 未覆盖 c 姊妹 PR、d 事件签名、e 事件源/严重度（缓存与单元里没有这些数据）; upgrade when a per-issue timeline or signature field exists.
pre_dispatch_skip() { # unit-json → 0 when retired (one log line), 1 to dispatch
  local id issue reason evidence issue_state state closer f=()
  id="$(jqf -r '.id // empty' <<<"$1")"; issue="$(jqf -r '.issue // empty' <<<"$1")"
  [[ -n "$id" && "$issue" =~ ^[0-9]+$ ]] || return 1
  mapfile -t f < <(jqf -r '(.issue_state // ""), (.state // ""), (.merged_closer // "")' <<<"$(dep_cache_info "$issue")")
  issue_state="${f[0]:-}"; state="${f[1]:-}"; closer="${f[2]:-}"
  if [[ "$issue_state" == CLOSED ]]; then
    reason=a-issue-closed; evidence="issue#$issue"
  elif [[ -n "$closer" || "$state" == MERGED ]] && ! jqf -e '(.hold_handoff_episode // "") | startswith("ruling-")' <<<"$1" >/dev/null; then # row 1002: a resuming ruling asks for the work again
    reason=b-linked-fix-merged; evidence="issue#$issue"; [[ -z "$closer" ]] || evidence="PR#$closer"
  else return 1; fi
  if [[ "$reason" == b-* ]] && ! obsolete_issue_close "$issue" "pre-dispatch $reason $evidence"; then # row 1002: the issue closes with its unit (7447 stayed open); obsolete_close_retry retries
    set_unit "$id" "$(hist obsolete-close-failed "pre-dispatch $reason $evidence") | .stage=\"parked\" | .parked_reason=\"obsolete-close-failed\" | .unpark_condition=\"the issue close succeeds\""
  else set_unit "$id" "$(hist obsolete "pre-dispatch $reason $evidence") | .stage=\"closed\""; fi
  say "pre-dispatch skip unit=$id reason=$reason evidence=$evidence"
}

dispatch_if_room() { # unit stage type log report model effort prompt [sha] [workdir] [pr-head] [new-failure] [unit-json] [check-footprint] [provider] [hard] [route-reason] [route-provider] [worker-context-json]
  local ledger_filter="" unit_json="${13:-}" prompt="$8" check_output check_status footprint footprint_summary lesson_brief write_start_filter repair_head trigger merge_rebase_head="" \
    check_footprint="${14:-true}" provider hard_escalation="${16:-false}" route_reason="${17:-configured}" route_provider \
    worker_context="${19:-}" report_only=false failure_prompt="${12-$8}"
  provider="${15:-$(provider_of "$6")}"; route_provider="${18:-$provider}"
  refill_stopped && return 1 # never start a worker once a ledger write was refused: its stage write would be refused too
  [[ -n "$unit_json" ]] || unit_json="$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  if [[ "$3" == repair && "$(jqf -r '.merge_rebase_pending // false' <<<"$unit_json")" == true ]]; then merge_rebase_head="$(jqf -r '.merge_rebase_head // empty' <<<"$unit_json")"; [[ "$merge_rebase_head" =~ $SHA_RE ]] || { say "merge rebase start refused unit=$1: invalid PR head"; return 1; }; fi
  if [[ -n "$worker_context" ]]; then
    report_only="$(jqf -r '.incident_report_resume // false' <<<"$worker_context")"
  fi
  prompt="$(incident_worker_prompt "$3" "$unit_json" "$prompt")"
  [[ "$report_only" != true ]] || failure_prompt="$prompt"
  if [[ "$report_only" != true && ( "$3" == implement || "$3" == repair ) ]] && jqf -e '.pr == null' <<<"$unit_json" >/dev/null && pre_dispatch_skip "$unit_json"; then return 1; fi
  room_for "$1" "$3" "$unit_json" true "$check_footprint" "$report_only" || { dmark dispatch_room_for; return 1; }
  dmark dispatch_room_for
  if [[ "$report_only" != true && ( "$3" == implement || "$3" == repair ) ]]; then
    local sa_rc=0
    size_admission_write_start "$1" "${10:-}" "$unit_json" || sa_rc=$?
    dmark dispatch_size_admission
    if (( sa_rc == 2 )); then dispatch_why "$1" size-admission-deferred; return 1; fi # local refill: the slow tick records the rejection
    (( sa_rc == 0 )) || { dispatch_why "$1" size-admission-start; return 1; }
  fi
  if [[ "$3" == implement ]]; then
    lesson_brief="$(footprint_recurrence_brief "$unit_json")"
    [[ -z "$lesson_brief" ]] || prompt+=$'\n'"$lesson_brief"
  fi
  [[ "$3" != review && "$3" != rereview ]] || pr_body_refresh "$unit_json"
  if [[ "$3" == review || "$3" == rereview ]] && [[ "${9:-}" =~ $SHA_RE ]]; then
    self_check_before_review "$1" "$9" "${10:-$ROOT}" "$unit_json" || return 1
    check_output="$(jqf -r '.self_check_output // empty' <<<"$unit_json")"
    check_status="$(jqf -r '.self_check_status // empty' <<<"$unit_json")"
    prompt+="
流水线确定性自检（当前 head $9）：${check_status}。完整输出 $check_output
$(tail -80 "$check_output" 2>/dev/null)"
  fi
  if [[ ( "$3" == review || "$3" == rereview ) && -n "${10:-}" ]] \
    && git -C "${10}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    reviewer_git_identity_configure "${10}" "$provider" "$6" || return 1
  fi
  dispatch "$3" "$6" "$7" "$1" "$4" "$5" "$prompt" "${9:-}" "${10:-}" "${11:-}" "$failure_prompt" "$provider" "$hard_escalation" "$route_reason" "$worker_context" || { dmark dispatch_call; return 1; }
  dmark dispatch_call
  if [[ "$3" == implement && "$report_only" != true && "${TICK_DISPATCH_PENDING_ACTIVE:-false}" == true && "${TICK_STARTED_WIP_COUNT:-}" =~ ^[0-9]+$ ]]; then
    TICK_STARTED_WIP_COUNT=$((TICK_STARTED_WIP_COUNT + 1))
  fi
  # A successful start can change whether later candidates fit; only reuse admission samples between starts.
  TICK_PRIORITY_ADMISSION_CACHE=()
  [[ "${TICK_DISPATCH_HOST_CAPACITY_BLOCKED:-false}" != true ]] || TICK_DISPATCH_HOST_CAPACITY_BLOCKED=false
  dispatch_why_clear "$1"
  if [[ "$report_only" != true && ( "$3" == implement || "$3" == repair ) ]]; then
    if [[ "$3" == repair ]]; then
      # A repair worker edits the unit's existing report in place; its own report path only holds the fix note.
      ledger_filter+=" | .repair_note_report=$(js "$5") | .implementation_report=(if (.implementation_report // \"\")==\"\" then $(js "$5") else .implementation_report end)"
    else
      ledger_filter+=" | .implementation_report=$(js "$5") | del(.repair_note_report)"
    fi
  fi
  if [[ "$3" == review || "$3" == rereview ]]; then ledger_filter+=' | .self_check_fixes=0'; fi
  if [[ "$report_only" != true && ( "$3" == implement || "$3" == repair ) ]]; then
    if [[ -n "${TICK_FOOTPRINT_CACHE[$1]+cached}" ]]; then
      footprint="${TICK_FOOTPRINT_CACHE[$1]}"
    else
      footprint="$(unit_field "$1" '.footprint // []')"
    fi
    footprint_summary="$(jqf -c '{count:length,first_paths:.[0:5]}' <<<"$footprint")" || return 1
    write_start_filter="$(STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" hist write-start "$footprint_summary")"
    write_start_filter+=" | .history[-1].work_type=$(js "$3") | .history[-1].provider=$(js "$provider") | .history[-1].hard_escalation=$hard_escalation"
    write_start_filter+=" | $(dispatch_attempt_fields "$4" "$6" "$unit_json")"
    if [[ "$3" == repair ]]; then
      trigger="$(unit_field "$1" '
        # newest trigger-class event, not history[-1]: unblocked/hold-handoff/approval-carried often land after it
        ([(.history // [])[] | .stage // "" | select(IN("review-request-changes", "review-block", "review-finding", "ci-test-red",
            "ci-red-behind-main-update", "merge-conflict", "self-check-red", "supervisor-requeue", "repair-no-push", "no-push",
            "worker-rc75"))] | last // "")
        | if . == "ci-red-behind-main-update" then "behind-main"
          elif . == "review-request-changes" or . == "review-block" or . == "review-finding" then "review-finding"
          elif . == "ci-test-red" then "ci-test-red"
          elif . == "merge-conflict" then "merge-conflict"
          elif . == "self-check-red" then "self-check-red"
          elif . == "supervisor-requeue" then "supervisor-requeue"
          elif . == "repair-no-push" or . == "no-push" then "no-push"
          elif . == "worker-rc75" then "worker-rc75"
          else "unknown"
          end')"
      write_start_filter+=" | .history[-1].trigger=$(js "$trigger")$([[ -z "$merge_rebase_head" ]] || printf ' | .history[-1].merge_rebase_head=%s' "$(js "$merge_rebase_head")")"
    fi
    # The PR head a repair starts from, so harvest can tell a run that pushed nothing (repair_head_class); unreadable = unclassified.
    if [[ "$3" == repair && "$report_only" != true && "$(unit_field "$1" '.lane // "pr"')" != direct-main && "$(unit_field "$1" '.pr // empty')" =~ ^[0-9]+$ ]] \
      && repair_head="$(tick_pr_head "$(unit_field "$1" .pr)" 2>/dev/null)"; then write_start_filter+=" | .history[-1].pr_head=$(js "$repair_head")"; fi
    ledger_filter+=" | $write_start_filter | .implement_route_provider=(.implement_route_provider // $(js "$route_provider")) | .implement_provider=$(js "$provider") | .implement_backend=$(js "$provider") | .implement_model=$(js "$6") | .implement_effort=$(js "$7") | .implement_identity=$(js "$provider:$6:$7")"
    [[ "$hard_escalation" != true ]] || ledger_filter+=' | .hard_escalated=true'
    # Same-tick admission widens the active footprint set (write-start just landed).
    # Fold the dispatched unit into the tick snapshot and extend the preflight
    # conflict map from cached data, so later candidates hit "footprint wait" at
    # room_for — before clone preparation and failure-evidence fetch — instead of
    # at the fresh admission check after that work was already done (05:10:42Z
    # tick: 6 of 8 clone_preparations were wasted on footprint-blocked units).
    if [[ "$TICK_ACTIVE_FOOTPRINTS_VALID" == true ]]; then
      TICK_ACTIVE_FOOTPRINTS="$(printf '%s\n' "$TICK_ACTIVE_FOOTPRINTS" "$footprint" | jqf -cs --arg id "$1" \
        '.[0] as $active | .[1] as $footprint | ($active | map(select(.id != $id))) + [{id:$id,footprint:$footprint}]')" \
        && footprint_merge_changed_owners || :
    fi
  fi
  local extra=""
  [[ "$report_only" != true && "${9:-}" =~ $SHA_RE ]] && extra=" | .review_sha=\"$9\""
  if [[ "$report_only" != true && ( "$3" == implement || "$3" == repair ) && -n "$(jqf -r '.handoff_start_ref // empty' <<<"$unit_json")" ]]; then
    extra+=' | .handoff_start_applied=true'
  fi
  if [[ "$report_only" != true && ( "$3" == implement || "$3" == repair ) ]] && [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$unit_json")" ]]; then
    extra+=' | .handoff_worktree_applied=true'
  fi
  # The three trailing ledger writes of a started worker (report, write-start, stage) are one rewrite of the whole ledger: same filters, same order.
  ledger_filter="${ledger_filter# | }"
  set_unit "$1" "${ledger_filter:+$ledger_filter | }.stage=\"$2\"$extra$([[ -z "$merge_rebase_head" ]] || printf ' | .merge_rebase_pending=false')" || return
  [[ -z "$merge_rebase_head" ]] || say "merge rebase started PR#$(jqf -r '.pr // empty' <<<"$unit_json") head=$merge_rebase_head attempt=$(unit_field "$1" '[(.history // [])[] | select(.merge_rebase_head != null)] | length')"
}
