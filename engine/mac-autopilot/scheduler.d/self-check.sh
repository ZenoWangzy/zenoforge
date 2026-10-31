self_check_run() (
  set -o pipefail
  local dir="$1" sha="$2" lane="${3:-}" pr_base="${4:-}" base paths pkg targets test_targets cached_tests tree selection selection_dir selection_log manifest part changed_helpers=0 rc=0 marker target
  local entry="${ZF_CIHOST_EXEC:-${ZF_ENGINE_DIR:-$ROOT/engine}/cihost-exec.py}"
  local step_s="${SELF_CHECK_STEP_TIMEOUT:-900}" srg
  local delegate_tests=0
  local -a builds=()
  cd "$dir" || return 1
  tree="$(git rev-parse "$sha^{tree}")" || return 1
  base="$(git merge-base origin/main "$sha")" || return 1
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
  if [[ "$(jq '.rootNames | length' <<<"$selection")" == 0 ]]; then echo 'self-check: no workspace package touched'; return 0; fi
  targets="$(jq -r '.affectedNames[]' <<<"$selection")" || return 1
  test_targets=""
  while IFS= read -r paths; do
    # Selection from candidate code may be untrusted: read manifests only from
    # the candidate Git tree, never from an arbitrary controller filesystem path.
    manifest="$(command git -C "$dir" show "$sha:$paths/package.json")" || return 1
    if [[ -n "$(jq -r '.scripts.test // empty' <<<"$manifest")" ]]; then
      test_targets+="$(jq -r '.name' <<<"$manifest")"$'\n'
    fi
  done < <(jq -r '.affectedPaths[]' <<<"$selection")
  [[ -n "$targets" ]] || return 1
  [[ "$lane" == pr && "$pr_base" == main ]] && delegate_tests=1
  while read -r pkg; do builds+=(--filter "$pkg..."); done <<<"$targets"
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
      # shellcheck disable=SC2086
      timeout -k 10 "$step_s" pnpm $2 --workspace-concurrency=2 --if-present run build || { srg=$?; rc=1; (( srg != 124 )) || echo "self-check: build timed out after ${step_s}s"; }
      for paths in typecheck test lint; do
        while read -r pkg; do
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
      done
      exit "$rc"' self-check "$base" "$builds_arg" "$targets" "$test_targets" "$cached_tests" "$step_s" "$tree" "$delegate_tests" \
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
  export VITEST_MAX_WORKERS=2 VITEST_MAX_FORKS=2 VITEST_MAX_THREADS=2 VITEST_MIN_FORKS=1
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 BASE_SHA="$base"
  timeout 900 pnpm install --frozen-lockfile --offline || timeout 900 pnpm install --frozen-lockfile || return 1
  timeout -k 10 "$step_s" pnpm "${builds[@]}" --workspace-concurrency=2 --if-present run build || { srg=$?; rc=1; (( srg != 124 )) || echo "self-check: build timed out after ${step_s}s"; }
  for paths in typecheck test lint; do
    while read -r pkg; do
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
  done
  return "$rc"
)

pid_start() { pid_start_id "$1"; } # start ticks: tells a reused pid from the gate
self_check_before_review() { # unit sha clone; false means wait for the gate/self-fix
  local id="$1" sha="$2" dir="$3" u="${4:-}" out result pid rc lane pr pr_base=""
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  lane="$(jqf -r '.lane // empty' <<<"$u")"
  if [[ "$lane" == pr ]]; then
    pr="$(jqf -r '.pr // empty' <<<"$u")"
    pr_base="$(tick_pr_base "$pr")" || pr_base=""
  fi
  if [[ "$(jqf -r '.self_check_sha // empty' <<<"$u")" == "$sha" && -n "$(jqf -r '.self_check_status // empty' <<<"$u")" \
      && "$(jqf -r '.self_check_lane // empty' <<<"$u")" == "$lane" \
      && "$(jqf -r '.self_check_base // empty' <<<"$u")" == "$pr_base" ]]; then return 0; fi
  out="$SUP/self-check-$id-$sha-$(jqf -r '.self_check_fixes // 0' <<<"$u")-$TAG.log"; result="$out.result"
  (
    if self_check_run "$dir" "$sha" "$lane" "$pr_base"; then printf 'pass\n' > "$result"
    else
      rc=$?
      # 75 (cihost admission queue) and 125 (transfer/setup) are not verdicts.
      if (( rc == 75 || rc == 125 )); then printf 'defer\n' > "$result"; else printf 'red\n' > "$result"; fi
    fi
  ) > "$out" 2>&1 < /dev/null &
  pid=$!
  set_unit "$id" ".self_check_pid=$pid | .self_check_start=$(js "$(pid_start "$pid")") | .self_check_sha=$(js "$sha") | .self_check_lane=$(js "$lane") | .self_check_base=$(js "$pr_base") | .self_check_status=null | .self_check_output=$(js "$out") | .self_check_workdir=$(js "$dir") | .self_check_return_stage=.stage"
  say "self-check pid=$pid unit=$id head=$sha (before review)"
  return 1
}
self_check_harvest() {
  local id pid out start status fixes sid model
  while IFS=$'\t' read -r id pid out start; do
    if [[ ! -s "$out.result" ]]; then
      if kill -0 "$pid" 2>/dev/null && { [[ -z "$start" || "$(pid_start "$pid")" == "$start" ]]; }; then continue; fi
      # Gate died (reboot, SIGKILL) before any verdict: the check never failed, so run it again.
      say "self-check interrupted without a result unit=$id: rerun"
      set_unit "$id" "$(hist self-check-interrupted "$out") | del(.self_check_pid, .self_check_start, .self_check_sha, .self_check_status)"
      continue
    fi
    status="$(cat "$out.result")"
    if [[ "$status" == defer ]]; then
      say "self-check deferred unit=$id: cihost admission or setup; rerun next tick"
      set_unit "$id" "$(hist self-check-deferred "$out") | del(.self_check_pid, .self_check_start, .self_check_sha, .self_check_status)"
      continue
    fi
    set_unit "$id" "$(hist "self-check-$status" "$out") | del(.self_check_pid, .self_check_start) | .self_check_status=$(js "$status")"
    [[ "$status" == red ]] || continue
    fixes="$(unit_field "$id" '.self_check_fixes // 0')"
    sid="$(unit_field "$id" '.session_ids.repair')"; model="$(unit_field "$id" .implement_model)"
    if (( fixes < 2 )) && [[ "$sid" =~ $SESSION_RE && -n "$model" && "$model" != claude-* ]]; then
      set_unit "$id" '.self_fix_pending=true'
    else
      say "self-check red unit=$id: normal review with failure attached (fixes=$fixes, original session=${sid:-unavailable})"
    fi
  done < <(jqf -r '.units[] | select(.self_check_pid!=null) | [.id,.self_check_pid,.self_check_output,(.self_check_start // "")] | @tsv' "$UNITS")
}
self_fix_dispatch() { # unit JSON; same session, model, branch and workdir
  local u="$1" id dir branch out rep prompt model effort deliver key failure
  id="$(jqf -r .id <<<"$u")"
  room_for "$id" repair "$u" false || return 1
  model="$(jqf -r .implement_model <<<"$u")"; effort="$(jqf -r .implement_effort <<<"$u")"
  cooling "$(provider_of "$model")" && return 1
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
$(tail -100 "$out")"
  prompt="实现后的确定性自检失败，尚未派出评审。这是原实现会话的自修复，保持原任务范围，修复下列失败，不弱化断言。$failure
在当前隔离 clone ${dir}、原分支 $branch 修复；$deliver 禁止 merge PR、部署或修改 GitHub 状态。把修复和验证证据写到 $SUP/${rep}，然后结束，流水线会重跑同一自检。
$(matt_method_rule "$dir")"
  set_unit "$id" '.self_fix_active=true'
  if dispatch_if_room "$id" repair repair "${rep%.md}.worker.log" "$rep" "$model" "$effort" "$prompt" "" "$dir" "" "$failure" "$u"; then
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
higher_priority_waiting() { # priority → higher-priority live waiter (stdout); always drops stale files
  local priority="$1" f pid name hotfix="" opt=""
  for f in "$LUNA_SLOTS"/wait-hotfix-* "$LUNA_SLOTS"/wait-opt-*; do
    [[ -e "$f" ]] || continue
    pid="${f##*-}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      name="${f##*/}"
      case "$name" in
        wait-hotfix-*) [[ -n "$hotfix" ]] || hotfix="$name" ;;
        wait-opt-*) [[ -n "$opt" ]] || opt="$name" ;;
      esac
    else
      rm -f -- "$f"
    fi
  done
  case "$priority" in
    hotfix) return 1 ;;
    opt) [[ -n "$hotfix" ]] && { printf '%s\n' "$hotfix"; return 0; } ;;
    *)
      [[ -n "$hotfix" ]] && { printf '%s\n' "$hotfix"; return 0; }
      [[ -n "$opt" ]] && { printf '%s\n' "$opt"; return 0; }
      ;;
  esac
  return 1
}

room_for() { # unit-id type [unit-json] [fresh-footprint=true]：焦点与并发检查
  local u="${3:-}" priority waiter cur impl_cap n_impl fresh_footprint="${4:-true}" check_footprint="${5:-true}" gate_started gate_elapsed gate_waiting=false
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$1" '.units[] | select(.id==$id)' "$UNITS")"
  if [[ "$2" == repair ]]; then repair_cap_admission "$1" "$u" || return 1; fi
  if [[ "$2" == review || "$2" == rereview ]]; then
    jqf -e '(.self_check_pid // null)==null and (.self_fix_pending // false)!=true' <<<"$u" >/dev/null || return 1
  fi
  if [[ "$FOCUS_MODE" == "release" && "$(unit_is_critical "$u")" != "true" && "$(critical_pending_count)" -gt 0 ]]; then
    FOCUS_SKIPPED+=("$1")
    say "skip dispatch unit=$1 focus=release critical=false"
    return 1
  fi
  priority="$(unit_dispatch_priority "$u")"
  gate_started=$SECONDS
  if waiter="$(higher_priority_waiting "$priority")"; then gate_waiting=true; fi
  gate_elapsed=$((SECONDS - gate_started))
  [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || (( gate_elapsed < 2 )) || say "dispatch detail priority_gate unit=$1 secs=${gate_elapsed}s"
  if [[ "$gate_waiting" == true ]]; then
    say "skip dispatch unit=$1 priority=$priority (higher-priority run waiting at luna/zc gate: $waiter)"
    return 1
  fi
  cur="$(live_workers)"
  if (( cur >= MAX )); then say "skip dispatch unit=$1 (capacity $cur/$MAX)"; return 1; fi
  impl_cap="$IMPLEMENT_CAP"
  if [[ ( "$2" == "implement" || "$2" == "repair" ) && "$check_footprint" == true ]]; then
    footprint_room "$1" "$u" "$fresh_footprint" || return 1
  fi
  if [[ "$2" == "implement" || "$2" == "repair" ]]; then
    n_impl=$(live_by_type "implement|repair")
    if (( n_impl >= impl_cap )); then say "skip dispatch unit=$1 (implement at cap $n_impl/$impl_cap)"; return 1; fi
  fi
}

footprint_recurrence_brief() { # unit JSON → up to 3 ranked CATALOG rules, bounded to 1 KB
  local footprint count brief
  footprint="$(scheduler_footprint "$1")" || return 0
  count="$(jqf 'length' <<<"$footprint")" || return 0
  (( count > 0 )) || return 0
  if brief="$(node "${ZF_ENGINE_DIR:-$ROOT/engine}/lesson-recurrence-ranking.mjs" --repo "$ROOT" --footprint-json "$footprint" 2>/dev/null)"; then
    [[ -z "$brief" ]] || printf '%s\n' "$brief"
  fi
  return 0
}

dispatch_if_room() { # unit stage type log report model effort prompt [sha] [workdir] [pr-head] [new-failure] [unit-json]
  local unit_json="${13:-}" prompt="$8" check_output check_status footprint lesson_brief write_start_filter check_footprint="${14:-true}"
  [[ -n "$unit_json" ]] || unit_json="$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  room_for "$1" "$3" "$unit_json" true "$check_footprint" || return 1
  if [[ "$3" == implement || "$3" == repair ]]; then
    size_admission_write_start "$1" "${10:-}" "$unit_json" || return 1
  fi
  if [[ "$3" == implement ]]; then
    lesson_brief="$(footprint_recurrence_brief "$unit_json")"
    [[ -z "$lesson_brief" ]] || prompt+=$'\n'"$lesson_brief"
  fi
  if [[ "$3" == review || "$3" == rereview ]] && [[ "${9:-}" =~ $SHA_RE ]]; then
    self_check_before_review "$1" "$9" "${10:-$ROOT}" "$unit_json" || return 1
    check_output="$(jqf -r '.self_check_output // empty' <<<"$unit_json")"
    check_status="$(jqf -r '.self_check_status // empty' <<<"$unit_json")"
    prompt+="
流水线确定性自检（当前 head $9）：${check_status}。完整输出 $check_output
$(tail -80 "$check_output" 2>/dev/null)"
  fi
  dispatch "$3" "$6" "$7" "$1" "$4" "$5" "$prompt" "${9:-}" "${10:-}" "${11:-}" "${12-$prompt}" || return 1
  if [[ "$3" == review || "$3" == rereview ]]; then set_unit "$1" '.self_check_fixes=0'; fi
  if [[ "$3" == implement || "$3" == repair ]]; then
    if [[ -n "${TICK_FOOTPRINT_CACHE[$1]+cached}" ]]; then
      footprint="${TICK_FOOTPRINT_CACHE[$1]}"
    else
      footprint="$(unit_field "$1" '.footprint // []')"
    fi
    write_start_filter="$(STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" hist write-start "$footprint")"
    write_start_filter+=" | .history[-1].work_type=$(js "$3")"
    set_unit "$1" "$write_start_filter | .implement_model=$(js "$6") | .implement_effort=$(js "$7")"
    # Same-tick admission widens the active footprint set (write-start just landed).
    # Fold the dispatched unit into the tick snapshot and recompute the preflight
    # conflict map from cached data, so later candidates hit "footprint wait" at
    # room_for — before clone preparation and failure-evidence fetch — instead of
    # at the fresh admission check after that work was already done (05:10:42Z
    # tick: 6 of 8 clone_preparations were wasted on footprint-blocked units).
    if [[ "$TICK_ACTIVE_FOOTPRINTS_VALID" == true ]]; then
      TICK_ACTIVE_FOOTPRINTS="$(jqf -c --arg id "$1" --argjson footprint "$footprint" \
        'map(select(.id != $id)) + [{id:$id,footprint:$footprint}]' <<<"$TICK_ACTIVE_FOOTPRINTS")" \
        && footprint_refresh_conflicts cached || :
    fi
  fi
  local extra=""
  [[ "${9:-}" =~ $SHA_RE ]] && extra=" | .review_sha=\"$9\""
  if [[ ( "$3" == implement || "$3" == repair ) && -n "$(jqf -r '.handoff_start_ref // empty' <<<"$unit_json")" ]]; then
    extra+=' | .handoff_start_applied=true'
  fi
  if [[ "$3" == implement || "$3" == repair ]] && [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$unit_json")" ]]; then
    extra+=' | .handoff_worktree_applied=true'
  fi
  set_unit "$1" ".stage=\"$2\"$extra"
}
