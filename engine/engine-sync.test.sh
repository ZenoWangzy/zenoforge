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

# A tick skipped on .scheduler.lock never ran: not a failure, not a pass; a real tick that dies without
# 'tick done' still rolls back.
make_swap_fixture canary-skipped-tick
slow_tick
slow_tick
ZF_REPO_DIR="$CF_TARGET" AGENT_HOME="$CF_AGENT" MAC_AUTOPILOT_SUPERVISOR_DIR="$CF_SUP" \
  "$here/engine-sync.sh" --converge >/dev/null
canary tick-begin
printf '[2026-11-05T08:01:07Z] scheduler tick skipped: another tick holds .scheduler.lock\n' >> "$CF_RUNTIME/scheduler.log"
canary tick-complete
[[ "$(readlink -e "$CF_AGENT/engine-live")" == "$CF_AGENT/engine-versions/candidate/engine" ]] \
  || { echo 'FAIL: tick skipped on the lock rolled the engine back' >&2; exit 1; }
[[ "$(jq -r '"\(.status) \(.remaining_ticks)"' "$CF_AGENT/engine-versions/.swap-record.json")" == 'pending 2' ]] \
  || { echo 'FAIL: tick skipped on the lock changed the canary state' >&2; exit 1; }
[[ ! -e "$CF_AGENT/engine-versions/.failed-candidate" && ! -e "$CF_RUNTIME/.engine-canary-tick.json" ]] \
  || { echo 'FAIL: tick skipped on the lock left a failure marker or a tick record' >&2; exit 1; }
canary tick-begin
canary tick-complete
[[ "$(readlink -e "$CF_AGENT/engine-live")" == "$CF_AGENT/engine-versions/old/engine" ]] \
  || { echo 'FAIL: a real tick without tick done did not roll back' >&2; exit 1; }
grep -Fq 'ROLLBACK engine candidate -> old: no tick done within tick limit' "$CF_RUNTIME/scheduler.log" \
  || { echo 'FAIL: no-tick-done rollback event missing' >&2; exit 1; }

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

echo 'engine-sync.test.sh: canary and rollback PASS'
