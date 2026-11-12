#!/usr/bin/env bash
# start.sh --sync-only in an immutable engine deployment（engine-versions/<id>/engine，经 engine-live）：
#   1) head 移动后一次干净同步退出 0，loop.sh 的 sync_from_main 记录 .synced-head（checkout 不留 engine 副本时
#      经 live runtime 的 start.sh 同步）；2) 失败的步骤在 scheduler.log 恰好写一行并点名步骤；3) engine 内容
#      未变的同步不切 live 指针（2026-11-03 20:01Z 一次内容未变的 engine-live 切换打断了演示 harness）。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "start-sync-only.test.sh: $*" >&2; exit 1; }
fixture="$test_env_root/start-sync-only"
home="$fixture/agent-home"
root="$fixture/repo"
sup="$root/.scratch-supervisor"
state="$sup/autopi"
mkdir -p "$home/engine-versions" "$state" "$fixture/bin" "$root/.zenoforge/build"
export AGENT_HOME="$home"
for tool in pkill systemctl nohup; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/started"\nexit 1\n' "$tool" "$fixture" > "$fixture/bin/$tool"
done
cat > "$fixture/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '[{"number":1,"headRefOid":"1111111111111111111111111111111111111111","headRefName":"agent/issue-1","baseRefName":"main","isDraft":false,"title":"t","labels":[],"body":"","statusCheckRollup":[]}]'
SH
chmod +x "$fixture/bin/"*

# The engine tree every version directory and the self-check run against (same construction as start.test.sh).
stage="$fixture/engine-stage"
mkdir -p "$stage"
cp -a "$script_dir" "$stage/mac-autopilot"
copy_agent_library "$stage" mac-autopilot/scheduler.sh
mkdir -p "$stage/ci" "$stage/prompts"
cp "$repo_root/engine/ci/pr-required-aggregate.mjs" "$stage/ci/"
cp "$repo_root/engine/prompts/supervisor-arbiter.md" "$stage/prompts/"

# The product checkout: only git HEAD and the build hook config; the engine deployment is the version tree.
git -C "$root" init -q
git -C "$root" -c user.name=t -c user.email=t@e commit -qm base --allow-empty
ZF_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '{"hook":".zenoforge/build/hook.sh","engine":"%s"}\n' "$ZF_SHA" > "$root/.zenoforge/build.json"
hook_calls="$fixture/hook-calls"; hook_fail="$fixture/hook-fail"
cat > "$root/.zenoforge/build/hook.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$hook_calls"
[[ \$1 == --check ]] || exit 0
if [[ -e "$hook_fail" ]]; then echo "hook check failed (fixture)" >&2; exit 1; fi
exit 0
SH
chmod +x "$root/.zenoforge/build/hook.sh"

make_version() { # id zenoforge_sha ；第三个参数存在时不写 BUILD-INFO（diff 回退用例）
  mkdir -p "$home/engine-versions/$1"
  cp -a "$stage" "$home/engine-versions/$1/engine"
  [[ $# -ge 3 ]] || printf 'id=%s\nzenoforge_sha=%s\nproduct_sha=cccccccccccccccccccccccccccccccccccccccc\n' "$1" "$2" \
    > "$home/engine-versions/$1/BUILD-INFO"
}
engine_live_at() { ln -sfn "engine-versions/$1/engine" "$home/engine-live"; }

# The live loop's environment: the engine is the immutable version engine-live points at, never a checkout copy.
export MAC_AUTOPILOT_ROOT="$root"
run_sync() { # → start.sh 的退出码；输出进 fixture 日志
  PATH="$fixture/bin:$PATH" ZF_ENGINE_DIR="$home/engine-live" ZF_PACK_DIR="$home/engine-live" \
    bash "$home/engine-live/mac-autopilot/start.sh" --sync-only >> "$fixture/sync-out" 2>&1 || return $?
}
sync_log_new_lines() { # before-count → scheduler.log 新增行
  tail -n "+$(( $1 + 1 ))" "$state/scheduler.log" 2>/dev/null || true
}

# 1. 干净同步退出 0；head 移动后经 loop.sh 的 sync_from_main（无 checkout engine 副本 → live runtime 的
#    start.sh）记录 .synced-head。
VID_A1=aaaaaaaaaaaa-111111111111-222222222222-333333333333
make_version "$VID_A1" "$ZF_SHA"; engine_live_at "$VID_A1"
run_sync || fail "clean sync of a fresh immutable engine failed (rc=$?)"
[[ "$(readlink "$sup/autopi-live")" == "$home/engine-live/mac-autopilot" ]] || fail 'first sync did not point live at the engine'
[[ -e "$fixture/started" ]] && fail '--sync-only started a loop'
git -C "$root" -c user.name=t -c user.email=t@e commit -qm two --allow-empty
head2="$(git -C "$root" rev-parse HEAD)"
VID_A2=aaaaaaaaaaaa-444444444444-222222222222-333333333333
make_version "$VID_A2" "$ZF_SHA"; engine_live_at "$VID_A2"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$state" \
  ZF_ENGINE_DIR="$home/engine-live" ZF_PACK_DIR="$home/engine-live"
AUTOPI_LOOP_LIBRARY_ONLY=true source "$script_dir/loop.sh"
sync_from_main
[[ "$(cat "$state/.synced-head" 2>/dev/null)" == "$head2" ]] || fail 'sync_from_main did not record the moved head'
grep -Fq "SYNC runtime from main $head2" "$state/scheduler.log" || fail 'successful resync not logged in scheduler.log'

# 2. 失败的步骤恰好写一行 SYNC-FAIL 并点名步骤；.synced-head 与 live 指针不动。
touch "$hook_fail"
git -C "$root" -c user.name=t -c user.email=t@e commit -qm three --allow-empty
VID_A3=aaaaaaaaaaaa-555555555555-222222222222-333333333333
make_version "$VID_A3" "$ZF_SHA"; engine_live_at "$VID_A3"
before="$(grep -c '' "$state/scheduler.log")"
live_before="$(readlink "$sup/autopi-live")"
if run_sync; then fail 'a failed engine self-check passed the sync'; fi
new_fail_lines="$(sync_log_new_lines "$before" | grep -c 'SYNC-FAIL step=self-check' || true)"
[[ "$new_fail_lines" == 1 ]] || fail "expected exactly one SYNC-FAIL step=self-check line, got $new_fail_lines"
[[ "$(cat "$state/.synced-head")" == "$head2" ]] || fail 'a failed sync advanced .synced-head'
[[ "$(readlink "$sup/autopi-live")" == "$live_before" ]] || fail 'a failed sync moved the live pointer'
rm -f "$hook_fail"; engine_live_at "$VID_A2"

# 3. engine 内容未变（BUILD-INFO zenoforge_sha 相同；或无 BUILD-INFO 时目录树相同）不切 live 指针；
#    engine 真变了才切。
ln -sfn "$home/engine-versions/$VID_A1/engine/mac-autopilot" "$sup/autopi-live"
: > "$state/scheduler.log"
run_sync || fail "sync of an engine-identical version failed (rc=$?)"
[[ "$(readlink "$sup/autopi-live")" == "$home/engine-versions/$VID_A1/engine/mac-autopilot" ]] \
  || fail 'engine-identical sync swapped the live pointer'
grep -Fq 'SYNC-SKIP engine content unchanged' "$state/scheduler.log" || fail 'engine-identical sync did not log the skip'
VID_B=bbbbbbbbbbbb-444444444444-222222222222-333333333333
make_version "$VID_B" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; engine_live_at "$VID_B"
: > "$state/scheduler.log"
run_sync || fail "sync of a changed engine failed (rc=$?)"
[[ "$(readlink "$sup/autopi-live")" == "$home/engine-live/mac-autopilot" ]] || fail 'a real engine change did not switch live'
grep -Fq 'SYNC-SKIP engine content unchanged' "$state/scheduler.log" && fail 'a real engine change was skipped'
VID_C1=cccccccccccc-666666666666-222222222222-333333333333
VID_C2=cccccccccccc-777777777777-222222222222-333333333333
make_version "$VID_C1" "$ZF_SHA" no-build-info; make_version "$VID_C2" "$ZF_SHA" no-build-info
engine_live_at "$VID_C2"
ln -sfn "$home/engine-versions/$VID_C1/engine/mac-autopilot" "$sup/autopi-live"
: > "$state/scheduler.log"
run_sync || fail "sync of identical trees without BUILD-INFO failed (rc=$?)"
[[ "$(readlink "$sup/autopi-live")" == "$home/engine-versions/$VID_C1/engine/mac-autopilot" ]] \
  || fail 'identical-tree sync (no BUILD-INFO) swapped the live pointer'

echo 'start-sync-only.test.sh: PASS'
