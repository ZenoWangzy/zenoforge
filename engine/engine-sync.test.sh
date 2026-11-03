#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
target=$test_env_root/target
mkdir -p "$target/.zenoforge" "$target/bin"
printf '{"hook":"bin/build", "engine":"abc123"}\n' > "$target/.zenoforge/build.json"
cat > "$target/bin/build" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$ZF_BUILD_ENGINE" "$@"
HOOK
chmod +x "$target/bin/build"
for mode in --build --check --converge; do
  result=$(ZF_REPO_DIR="$target" "$here/engine-sync.sh" "$mode" 'argument with spaces')
  [[ $result == "$(printf 'abc123\n%s\nargument with spaces' "$mode")" ]]
done
mkdir -p "$test_env_root/agent/engine-versions/live/engine" "$test_env_root/new-version/engine"
ln -s "$test_env_root/agent/engine-versions/live/engine" "$test_env_root/agent/engine-live"
echo '{"pipeline_suite_roots":[]}' > "$target/.zenoforge/ci.json"
git -C "$target" init -q && git -C "$target" config user.email test && git -C "$target" config user.name test
git -C "$target" add -A && git -C "$target" commit -qm initial
preflight() { ZF_REPO_DIR="$target" AGENT_HOME="$test_env_root/agent" "$here/engine-sync.sh" --preflight "$test_env_root/new-version"; }
# Without BUILD-INFO the live target commit is unknown: preflight refuses instead of comparing HEAD with itself.
if preflight >/dev/null 2>&1; then echo 'FAIL: preflight ran without the live target commit' >&2; exit 1; fi
# The new version may lack BUILD-INFO (falls back to HEAD). product_sha wins over pack_sha in any order: the pack
# commit here does not exist, so reading it would fail the preflight.
printf 'pack_sha=%s:.zenoforge/build/pack\nproduct_sha=%s\n' "$(printf '0%.0s' {1..40})" "$(git -C "$target" rev-parse HEAD)" \
  > "$test_env_root/agent/engine-versions/live/BUILD-INFO"
result=$(preflight)
grep -q 'publish-preflight: OK' <<<"$result"
printf 'pack_sha=%s:.zenoforge/build/pack\n' "$(git -C "$target" rev-parse HEAD)" > "$test_env_root/agent/engine-versions/live/BUILD-INFO"
printf 'product_sha=%s\n' "$(git -C "$target" rev-parse HEAD)" > "$test_env_root/new-version/BUILD-INFO"
result=$(preflight)
grep -q 'publish-preflight: OK' <<<"$result"

make_swap_fixture() {
  local name="$1"
  CF_ROOT="$test_env_root/$name"
  CF_TARGET="$CF_ROOT/target"
  CF_AGENT="$CF_ROOT/agent"
  CF_SUP="$CF_AGENT/supervisor"
  CF_RUNTIME="$CF_SUP/autopi"
  mkdir -p "$CF_TARGET/.zenoforge" "$CF_TARGET/bin" "$CF_RUNTIME" \
    "$CF_AGENT/engine-versions/old/engine" "$CF_AGENT/engine-versions/candidate/engine" \
    "$CF_AGENT/engine-versions/candidate/engine/mac-autopilot" \
    "$CF_SUP/autopi-versions/old/engine/mac-autopilot" \
    "$CF_SUP/autopi-versions/candidate/engine/mac-autopilot"
  cp "$here/mac-autopilot/engine-canary.sh" "$CF_AGENT/engine-versions/candidate/engine/mac-autopilot/"
  cp "$here/mac-autopilot/runtime-env.sh" "$CF_AGENT/engine-versions/candidate/engine/mac-autopilot/"
  cp "$here/platform-env.sh" "$CF_AGENT/engine-versions/candidate/engine/"
  cp "$here/proc.sh" "$CF_AGENT/engine-versions/candidate/engine/"
  printf '{"hook":"bin/build", "engine":"candidate"}\n' > "$CF_TARGET/.zenoforge/build.json"
  printf '{"engine":{"canary_ticks":2}}\n' > "$CF_RUNTIME/config.json"
  cat > "$CF_TARGET/bin/build" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --converge)
    printf 'converge\n' >> "$AGENT_HOME/hook.calls"
    ln -sfn "$AGENT_HOME/engine-versions/candidate/engine" "$AGENT_HOME/.engine-live.$$"
    mv -Tf "$AGENT_HOME/.engine-live.$$" "$AGENT_HOME/engine-live"
    ln -sfn "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-versions/candidate/engine/mac-autopilot" \
      "$MAC_AUTOPILOT_SUPERVISOR_DIR/.autopi-live.$$"
    mv -Tf "$MAC_AUTOPILOT_SUPERVISOR_DIR/.autopi-live.$$" "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live"
    ;;
  --check) printf 'check\n' >> "$AGENT_HOME/hook.calls" ;;
  *) printf '%s\n' "$*" ;;
esac
HOOK
  chmod +x "$CF_TARGET/bin/build"
  cat > "$CF_AGENT/engine-versions/old/engine/lib.sh" <<'LIB'
supervisor_inbox_append_once() {
  local key="$1"
  grep -Fq -- "$key" "$AGENT_HOME/supervisor-inbox" 2>/dev/null && return 0
  printf '%s\n' "$2" >> "$AGENT_HOME/supervisor-inbox"
}
LIB
  ln -s "$CF_AGENT/engine-versions/old/engine" "$CF_AGENT/engine-live"
  ln -s "$CF_SUP/autopi-versions/old/engine/mac-autopilot" "$CF_SUP/autopi-live"
  : > "$CF_RUNTIME/scheduler.log"
  : > "$CF_RUNTIME/loop.out"
}

canary() {
  AGENT_HOME="$CF_AGENT" ZF_REPO_DIR="$CF_TARGET" MAC_AUTOPILOT_ROOT="$CF_TARGET" \
    MAC_AUTOPILOT_SUPERVISOR_DIR="$CF_SUP" MAC_AUTOPILOT_RUNTIME_DIR="$CF_RUNTIME" \
    bash "$here/mac-autopilot/engine-canary.sh" "$@"
}

slow_tick() {
  canary tick-begin
  if [[ -n "${1:-}" ]]; then
    printf '[2026-11-02T00:00:00Z] %s\n' "$1" >> "$CF_RUNTIME/scheduler.log"
    printf '%s\n' "$1" >> "$CF_RUNTIME/loop.out"
  fi
  printf '[2026-11-02T00:00:01Z] tick done units=0\n' >> "$CF_RUNTIME/scheduler.log"
  canary tick-complete
}

# A first new jqf function/return-code signature rolls both live links back and marks the bad version.
make_swap_fixture canary-failure
slow_tick
slow_tick
ZF_REPO_DIR="$CF_TARGET" AGENT_HOME="$CF_AGENT" MAC_AUTOPILOT_SUPERVISOR_DIR="$CF_SUP" \
  "$here/engine-sync.sh" --converge >/dev/null
slow_tick 'jqf error (rc=5) in f: invalid regular expression'
[[ "$(readlink -e "$CF_AGENT/engine-live")" == "$CF_AGENT/engine-versions/old/engine" ]] \
  || { echo 'FAIL: new jqf signature did not roll engine-live back' >&2; exit 1; }
[[ "$(readlink -e "$CF_SUP/autopi-live")" == "$CF_SUP/autopi-versions/old/engine/mac-autopilot" ]] \
  || { echo 'FAIL: canary rollback did not restore autopi-live' >&2; exit 1; }
[[ -e "$CF_AGENT/engine-versions/.failed-candidate" ]] \
  || { echo 'FAIL: canary rollback did not mark the failed engine' >&2; exit 1; }
grep -Fq 'ROLLBACK engine candidate -> old: jqf error (rc=5) in f' "$CF_RUNTIME/scheduler.log" \
  || { echo 'FAIL: rollback event missing from scheduler.log' >&2; exit 1; }
grep -Fq 'ROLLBACK engine candidate -> old: jqf error (rc=5) in f' "$CF_AGENT/supervisor-inbox" \
  || { echo 'FAIL: rollback event missing from supervisor inbox' >&2; exit 1; }
ZF_REPO_DIR="$CF_TARGET" AGENT_HOME="$CF_AGENT" MAC_AUTOPILOT_SUPERVISOR_DIR="$CF_SUP" \
  "$here/engine-sync.sh" --converge >/dev/null
[[ "$(wc -l < "$CF_AGENT/hook.calls" | tr -d '[:space:]')" == 1 ]] \
  || { echo 'FAIL: converge re-flipped a previously failed engine' >&2; exit 1; }

# Repeating a signature already seen in the equal pre-swap window passes the full canary.
make_swap_fixture canary-repeat
known='jqf error (rc=5) in f: previously seen'
slow_tick "$known"
slow_tick "$known"
ZF_REPO_DIR="$CF_TARGET" AGENT_HOME="$CF_AGENT" MAC_AUTOPILOT_SUPERVISOR_DIR="$CF_SUP" \
  "$here/engine-sync.sh" --converge >/dev/null
slow_tick "$known"
slow_tick "$known"
[[ "$(readlink -e "$CF_AGENT/engine-live")" == "$CF_AGENT/engine-versions/candidate/engine" ]] \
  || { echo 'FAIL: repeated pre-existing signature caused rollback' >&2; exit 1; }
[[ "$(jq -r '.status' "$CF_AGENT/engine-versions/.swap-record.json")" == passed ]] \
  || { echo 'FAIL: repeated-signature canary did not complete its configured ticks' >&2; exit 1; }
[[ ! -e "$CF_AGENT/engine-versions/.failed-candidate" ]] \
  || { echo 'FAIL: repeated pre-existing signature marked the engine failed' >&2; exit 1; }

# A product pin rollback to a previously-live version skips only config/ref comparisons.
return_root="$test_env_root/previously-live"
return_target="$return_root/target"
return_agent="$return_root/agent"
mkdir -p "$return_target/.zenoforge" "$return_target/bin" \
  "$return_target/.zenoforge/mac-autopilot" \
  "$return_agent/engine-versions/current/engine" "$return_agent/engine-versions/return-version/engine"
printf '{"hook":"bin/build", "engine":"return-version"}\n' > "$return_target/.zenoforge/build.json"
cat > "$return_target/bin/build" <<'HOOK'
#!/usr/bin/env bash
printf 'check %s\n' "$ZF_BUILD_ENGINE"
HOOK
chmod +x "$return_target/bin/build"
printf '{"pipeline_suite_roots":[]}\n' > "$return_target/.zenoforge/ci.json"
printf '{"config":"old"}\n' > "$return_target/.zenoforge/mac-autopilot/config.template.json"
git -C "$return_target" init -q
git -C "$return_target" config user.email test
git -C "$return_target" config user.name test
git -C "$return_target" add -A
git -C "$return_target" commit -qm old-config
old_ref="$(git -C "$return_target" rev-parse HEAD)"
printf '{"config":"new"}\n' > "$return_target/.zenoforge/mac-autopilot/config.template.json"
git -C "$return_target" add -A
git -C "$return_target" commit -qm new-config
new_ref="$(git -C "$return_target" rev-parse HEAD)"
for version in current return-version; do
  printf 'value="$(zf_config_file mac-autopilot/config.template.json)"\n' \
    > "$return_agent/engine-versions/$version/engine/config-reader.sh"
done
printf 'product_sha=%s\n' "$new_ref" > "$return_agent/engine-versions/current/BUILD-INFO"
printf 'product_sha=%s\n' "$old_ref" > "$return_agent/engine-versions/return-version/BUILD-INFO"
ln -s "$return_agent/engine-versions/current/engine" "$return_agent/engine-live"
printf '{"old_id":"return-version","new_id":"current","swapped_at":"2026-11-02T00:00:00Z"}\n' \
  > "$return_agent/engine-versions/.swap-history.jsonl"
result="$(ZF_REPO_DIR="$return_target" AGENT_HOME="$return_agent" \
  "$here/engine-sync.sh" --preflight "$return_agent/engine-versions/return-version" 2>&1)"
grep -Fq 'skipping resolved-config and dropped-file-refs comparisons' <<<"$result" \
  || { echo 'FAIL: previously-live preflight exception was not selected' >&2; exit 1; }
grep -Fq 'publish-preflight: skipping resolved-config comparison' <<<"$result" \
  || { echo 'FAIL: resolved-config comparison was not skipped' >&2; exit 1; }
grep -Fq 'publish-preflight: skipping dropped-file-refs comparison' <<<"$result" \
  || { echo 'FAIL: dropped-file-refs comparison was not skipped' >&2; exit 1; }
grep -Fq 'publish-preflight: checking unit paths' <<<"$result" \
  && grep -Fq 'publish-preflight: checking suite set' <<<"$result" \
  || { echo 'FAIL: previously-live preflight skipped retained checks' >&2; exit 1; }
grep -Fq 'publish-preflight: OK' <<<"$result" \
  || { echo 'FAIL: previously-live preflight did not pass: '"$result" >&2; exit 1; }
check_result="$(ZF_REPO_DIR="$return_target" AGENT_HOME="$return_agent" "$here/engine-sync.sh" --check)"
[[ "$check_result" == 'check return-version' ]] \
  || { echo 'FAIL: previously-live rollback path stopped delegating --check' >&2; exit 1; }

# ---- eval on pin: a new engine id is evaluated before engine-live flips ----
export ENGINE_SYNC="$here/engine-sync.sh"

make_gate_fixture() { # name, then the paths the pin's commit touches
  local name="$1" diff_path version dir
  shift
  GF_ROOT="$test_env_root/$name"
  GF_TARGET="$GF_ROOT/target"
  GF_AGENT="$GF_ROOT/agent"
  GF_SUP="$GF_AGENT/supervisor"
  GF_RUNTIME="$GF_SUP/autopi"
  GF_OLD="$GF_AGENT/engine-versions/old"
  GF_CAND="$GF_AGENT/engine-versions/candidate"
  mkdir -p "$GF_TARGET/.zenoforge/mac-autopilot" "$GF_TARGET/bin" "$GF_RUNTIME" \
    "$GF_OLD/engine/mac-autopilot" "$GF_CAND/engine/mac-autopilot" \
    "$GF_SUP/autopi-versions/old/engine/mac-autopilot" "$GF_SUP/autopi-versions/candidate/engine/mac-autopilot" \
    "$GF_AGENT/eval/accepted-old"
  printf '{"hook":"bin/build", "engine":"candidate"}\n' > "$GF_TARGET/.zenoforge/build.json"
  printf '{"pipeline_suite_roots":[]}' > "$GF_TARGET/.zenoforge/ci.json"
  printf '{"config":"stable"}\n' > "$GF_TARGET/.zenoforge/mac-autopilot/config.template.json"
  git -C "$GF_TARGET" init -q && git -C "$GF_TARGET" config user.email test && git -C "$GF_TARGET" config user.name test
  git -C "$GF_TARGET" add -A && git -C "$GF_TARGET" commit -qm base
  GF_OLD_REF="$(git -C "$GF_TARGET" rev-parse HEAD)"
  for diff_path in "$@"; do
    mkdir -p "$(dirname "$GF_TARGET/$diff_path")"
    printf 'changed\n' > "$GF_TARGET/$diff_path"
  done
  git -C "$GF_TARGET" add -A && git -C "$GF_TARGET" commit -qm pin-change
  GF_NEW_REF="$(git -C "$GF_TARGET" rev-parse HEAD)"
  for version in old candidate; do
    dir="$GF_AGENT/engine-versions/$version"
    mkdir -p "$dir/engine/eval"
    cp "$here/mac-autopilot/engine-canary.sh" "$dir/engine/mac-autopilot/"
    cp "$here/mac-autopilot/runtime-env.sh" "$dir/engine/mac-autopilot/"
    cp "$here/eval/decision-stages.sh" "$dir/engine/eval/"
    cp "$here/platform-env.sh" "$dir/engine/"
    cp "$here/proc.sh" "$dir/engine/"
    printf 'value="$(zf_config_file mac-autopilot/config.template.json)"\n' > "$dir/engine/config-reader.sh"
    cat > "$dir/engine/lib.sh" <<'LIB'
supervisor_inbox_append_once() {
  local key="$1"
  grep -Fq -- "$key" "$AGENT_HOME/supervisor-inbox" 2>/dev/null && return 0
  printf '%s\n' "$2" >> "$AGENT_HOME/supervisor-inbox"
}
LIB
  done
  printf 'product_sha=%s\n' "$GF_OLD_REF" > "$GF_OLD/BUILD-INFO"
  printf 'product_sha=%s\n' "$GF_NEW_REF" > "$GF_CAND/BUILD-INFO"
  ln -s "$GF_OLD/engine" "$GF_AGENT/engine-live"
  ln -s "$GF_SUP/autopi-versions/old/engine/mac-autopilot" "$GF_SUP/autopi-live"
  printf '{"engine":{"canary_ticks":2,"eval_on_pin":{"enabled":true,"stages":null,"timeout_minutes":45}}}\n' \
    > "$GF_RUNTIME/config.json"
  printf '{"results":[]}\n' > "$GF_AGENT/eval/accepted-old/results.json"
  printf '{"old":"accepted-old"}\n' > "$GF_AGENT/engine-versions/.eval-baselines.json"
  printf 'pass\n' > "$GF_ROOT/verdict"
  : > "$GF_ROOT/gate-calls"
  : > "$GF_RUNTIME/scheduler.log"
  : > "$GF_RUNTIME/loop.out"
  cat > "$GF_TARGET/bin/build" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  --converge)
    printf 'converge\n' >> "\$AGENT_HOME/hook.calls"
    # documented hook contract: preflight after building and checking, before the flip
    bash "\$ENGINE_SYNC" --preflight "$GF_CAND"
    ln -sfn "$GF_CAND/engine" "\$AGENT_HOME/.engine-live.\$\$"
    mv -Tf "\$AGENT_HOME/.engine-live.\$\$" "\$AGENT_HOME/engine-live"
    ln -sfn "$GF_SUP/autopi-versions/candidate/engine/mac-autopilot" "\$MAC_AUTOPILOT_SUPERVISOR_DIR/.autopi-live.\$\$"
    mv -Tf "\$MAC_AUTOPILOT_SUPERVISOR_DIR/.autopi-live.\$\$" "\$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live"
    ;;
  --check) printf 'check %s\n' "\$ZF_BUILD_ENGINE" ;;
  *) printf '%s\n' "\$*" ;;
esac
HOOK
  chmod +x "$GF_TARGET/bin/build"
  cat > "$GF_ROOT/gate-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
label='' output='' stages='' baseline=''
while (($#)); do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --stages) stages="$2"; shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'label=%s stages=%s baseline=%s\n' "$label" "$stages" "$baseline" >> "$GATE_CALLS"
verdict="$(cat "$GATE_VERDICT")"
case "$verdict" in
  pass) printf '{"status":"passed","label":"%s","baseline":"%s"}\n' "$label" "$baseline" > "$output" ;;
  fail:*) printf '{"status":"failed","label":"%s","regressions":["%s"]}\n' "$label" "${verdict#fail:}" > "$output" ;;
  *) printf '{"status":"error","error":"stub cannot run"}\n' > "$output" ;;
esac
STUB
  chmod +x "$GF_ROOT/gate-stub.sh"
}

gate_converge() {
  ZF_REPO_DIR="$GF_TARGET" AGENT_HOME="$GF_AGENT" MAC_AUTOPILOT_SUPERVISOR_DIR="$GF_SUP" \
  MAC_AUTOPILOT_ROOT="$GF_TARGET" MAC_AUTOPILOT_RUNTIME_DIR="$GF_RUNTIME" \
  ZF_EVAL_GATE="$GF_ROOT/gate-stub.sh" GATE_VERDICT="$GF_ROOT/verdict" GATE_CALLS="$GF_ROOT/gate-calls" \
  bash "$here/engine-sync.sh" --converge
}

gate_wait_for_report() {
  local i
  for i in $(seq 1 100); do
    [[ -s "$GF_AGENT/engine-versions/.eval-on-pin-candidate.report.json" ]] && return 0
    sleep 0.1
  done
  echo 'FAIL: the eval gate stub never wrote its report' >&2
  return 1
}

# A gate that reports a regression holds the flip, marks the engine failed and does not retry it.
make_gate_fixture gate-reject 'engine/prompts/triage.md'
printf 'fail:triage/zf-4186/run-1\n' > "$GF_ROOT/verdict"
gate_converge >/dev/null 2>&1 || true
[[ "$(readlink -e "$GF_AGENT/engine-live")" == "$GF_OLD/engine" ]] \
  || { echo 'FAIL: pending eval gate did not hold the flip on its first tick' >&2; exit 1; }
gate_wait_for_report
gate_converge >/dev/null 2>&1 || true
[[ "$(readlink -e "$GF_AGENT/engine-live")" == "$GF_OLD/engine" ]] \
  || { echo 'FAIL: eval-rejected engine was flipped live' >&2; exit 1; }
[[ -e "$GF_AGENT/engine-versions/.failed-candidate" ]] \
  || { echo 'FAIL: eval reject did not mark the failed engine' >&2; exit 1; }
grep -Fq 'EVAL-REJECT engine candidate: triage/zf-4186/run-1' "$GF_RUNTIME/scheduler.log" \
  || { echo 'FAIL: EVAL-REJECT missing from scheduler.log' >&2; exit 1; }
grep -Fq 'EVAL-REJECT engine candidate: triage/zf-4186/run-1' "$GF_AGENT/supervisor-inbox" \
  || { echo 'FAIL: EVAL-REJECT missing from the supervisor inbox' >&2; exit 1; }
gate_converge >/dev/null 2>&1 || true
[[ "$(wc -l < "$GF_AGENT/hook.calls" | tr -d '[:space:]')" == 2 ]] \
  || { echo 'FAIL: converge retried an eval-rejected engine' >&2; exit 1; }

# A passing gate flips on the tick after the verdict and stores the pin label as the baseline.
make_gate_fixture gate-pass 'engine/prompts/triage.md'
gate_converge >/dev/null 2>&1 || true
[[ "$(readlink -e "$GF_AGENT/engine-live")" == "$GF_OLD/engine" ]] \
  || { echo 'FAIL: flip was not held until the gate verdict existed' >&2; exit 1; }
gate_wait_for_report
gate_converge >/dev/null
[[ "$(readlink -e "$GF_AGENT/engine-live")" == "$GF_CAND/engine" ]] \
  || { echo 'FAIL: gate-passing engine did not flip on the next tick' >&2; exit 1; }
[[ "$(jq -r '.candidate' "$GF_AGENT/engine-versions/.eval-baselines.json")" == pin-candidate ]] \
  || { echo 'FAIL: passing gate label was not stored as the accepted baseline' >&2; exit 1; }
[[ "$(head -n1 "$GF_ROOT/gate-calls")" == 'label=pin-candidate stages=triage,end-to-end baseline=accepted-old' ]] \
  || { echo "FAIL: gate ran with unexpected inputs: $(head -n1 "$GF_ROOT/gate-calls")" >&2; exit 1; }
[[ ! -e "$GF_AGENT/engine-versions/.failed-candidate" ]] \
  || { echo 'FAIL: passing gate still wrote a failure marker' >&2; exit 1; }

# A diff that touches only tests and docs skips the eval and flips in the same tick.
make_gate_fixture gate-docdiff 'engine/engine-sync.test.sh' 'docs/release-note.md'
gate_converge >/dev/null
[[ "$(readlink -e "$GF_AGENT/engine-live")" == "$GF_CAND/engine" ]] \
  || { echo 'FAIL: doc-only pin did not flip' >&2; exit 1; }
grep -Fq 'EVAL-SKIP engine candidate: diff touches no stage prompt or stage code' "$GF_RUNTIME/scheduler.log" \
  || { echo 'FAIL: doc-only pin did not log EVAL-SKIP' >&2; exit 1; }
[[ ! -s "$GF_ROOT/gate-calls" ]] \
  || { echo 'FAIL: eval ran on a doc-only diff' >&2; exit 1; }
[[ ! -e "$GF_AGENT/engine-versions/.eval-on-pin-candidate.json" ]] \
  || { echo 'FAIL: doc-only pin left eval gate state behind' >&2; exit 1; }
[[ "$(jq -r '.candidate' "$GF_AGENT/engine-versions/.eval-baselines.json")" == accepted-old ]] \
  || { echo 'FAIL: doc-only pin did not carry the accepted baseline forward' >&2; exit 1; }

# A return to a previously live id never runs the gate (#162 rollback path).
make_gate_fixture gate-return 'engine/prompts/triage.md'
printf '{"old_id":"candidate","new_id":"old","swapped_at":"2026-11-02T00:00:00Z"}\n' \
  > "$GF_AGENT/engine-versions/.swap-history.jsonl"
gate_converge >/dev/null
[[ "$(readlink -e "$GF_AGENT/engine-live")" == "$GF_CAND/engine" ]] \
  || { echo 'FAIL: return to a previously live engine did not flip' >&2; exit 1; }
grep -Fq 'EVAL-SKIP engine candidate: returning to a previously live engine' "$GF_RUNTIME/scheduler.log" \
  || { echo 'FAIL: previously-live return did not log EVAL-SKIP' >&2; exit 1; }
[[ ! -s "$GF_ROOT/gate-calls" ]] \
  || { echo 'FAIL: eval ran on a return to a previously live engine' >&2; exit 1; }
[[ ! -e "$GF_AGENT/engine-versions/.eval-on-pin-candidate.json" ]] \
  || { echo 'FAIL: previously-live return left eval gate state behind' >&2; exit 1; }

echo 'engine-sync.test.sh: canary, rollback and eval-on-pin PASS'
