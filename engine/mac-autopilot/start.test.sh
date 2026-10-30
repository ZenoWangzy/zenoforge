#!/usr/bin/env bash
# start.sh --sync-only / runtime-env.sh / loop 与 systemd 单元接线（WSL 接管）回归。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "start.test.sh: $*" >&2; exit 1; }
fixture="$test_env_root/start"
root="$fixture/root"
mkdir -p "$root/.scratch-supervisor/autopi" "$fixture/bin"
export AGENT_HOME="$fixture/agent-home"
for tool in pkill systemctl nohup; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/started"\nexit 1\n' "$tool" "$fixture" > "$fixture/bin/$tool"
done
chmod +x "$fixture/bin/"*
echo '{"max_workers":1,"keep":"operator"}' > "$root/.scratch-supervisor/autopi/config.json"

# Materialize committed tree contents, including future modules, without a file manifest.
mkdir -p "$root/engine"
cp -a "$script_dir" "$root/engine/mac-autopilot"
copy_agent_library "$root/engine"
git -C "$root" init -q
git -C "$root" add engine
git -C "$root" -c user.name=t -c user.email=t@e commit -qm one
first="$(git -C "$root" rev-parse HEAD)"
PATH="$fixture/bin:$PATH" MAC_AUTOPILOT_ROOT="$root" bash "$script_dir/start.sh" --sync-only > "$fixture/out"
[[ ! -e "$fixture/started" ]] || fail "--sync-only started something: $(cat "$fixture/started")"
state="$root/.scratch-supervisor/autopi"
live="$root/.scratch-supervisor/autopi-live"
versions="$root/.scratch-supervisor/autopi-versions"
[[ "$(readlink "$live")" == "autopi-versions/$first/engine/mac-autopilot" ]] || fail 'live pointer not pinned to HEAD'
diff -r "$root/engine/mac-autopilot" "$live" || fail 'committed runtime tree not materialized'
cmp -s "$root/engine/production-deployment-read.sh" "$live/../production-deployment-read.sh" || fail 'relative deployment reader missing'
cmp -s "$root/engine/closing-keywords.sh" "$live/../closing-keywords.sh" || fail 'shared closing-keyword helper missing'
cmp -s "$root/engine/state/mechanism-registry.json" "$live/../state/mechanism-registry.json" || fail 'mechanism registry missing from versioned runtime'
cmp -s "$root/engine/open-pr-snapshot.py" "$live/../open-pr-snapshot.py" || fail 'PR snapshot client missing from pinned runtime'
diff -u "$live/config.template.json" "$state/config.json" || fail 'install did not reconcile runtime config to repository config'
grep -Fq 'config-reconcile' "$fixture/out" || fail 'install did not report detected config drift'
grep -Fq 'config-reconcile keys=' "$state/scheduler.log" || fail 'install did not record config drift in the scheduler log'
grep -Fq 'config-reconcile' "$AGENT_HOME/supervisor-inbox" || fail 'install did not send config drift to the supervisor inbox'
[[ "$(grep -c 'config-reconcile' "$AGENT_HOME/supervisor-inbox")" == 1 ]] || fail 'install emitted more than one drift event'
rm "$state/config.json"
PATH="$fixture/bin:$PATH" MAC_AUTOPILOT_ROOT="$root" bash "$script_dir/start.sh" --sync-only >/dev/null
diff -u "$live/config.template.json" "$state/config.json" || fail 'install did not initialize a missing runtime config'
[[ "$(grep -c 'config-reconcile' "$AGENT_HOME/supervisor-inbox")" == 1 ]] || fail 'missing runtime config emitted a drift event'
jq -e '.units == []' "$state/units.json" >/dev/null || fail 'empty ledger not initialised'
[[ "$(readlink "$state/dashboard.html")" == ../autopi-live/dashboard.html ]] || fail 'dashboard not linked next to state data'
grep -Fq "dashboard: $state/dashboard.html" "$fixture/out" || fail 'dashboard path not printed'

# A dirty checkout cannot alter the committed version, or overwrite legacy running code/state.
printf '# legacy loop still running\n' > "$state/loop.sh"
printf '# uncommitted change\n' > "$root/engine/mac-autopilot/loop.sh"
PATH="$fixture/bin:$PATH" MAC_AUTOPILOT_ROOT="$root" bash "$script_dir/start.sh" --sync-only >/dev/null
[[ "$(cat "$state/loop.sh")" == '# legacy loop still running' ]] || fail 'legacy code changed during transition'
git -C "$root" show "$first:engine/mac-autopilot/loop.sh" > "$fixture/committed-loop"
cmp -s "$fixture/committed-loop" "$live/loop.sh" || fail 'dirty checkout leaked into pinned runtime'
printf 'new module\n' > "$root/engine/mac-autopilot/future-module.txt"
git -C "$root" add engine
git -C "$root" -c user.name=t -c user.email=t@e commit -qm two
second="$(git -C "$root" rev-parse HEAD)"
PATH="$fixture/bin:$PATH" MAC_AUTOPILOT_ROOT="$root" bash "$script_dir/start.sh" --sync-only >/dev/null
[[ "$(readlink "$live")" == "autopi-versions/$second/engine/mac-autopilot" ]] || fail 'second commit not activated'
[[ -d "$versions/$first" && "$(cat "$live/future-module.txt")" == 'new module' ]] || fail 'previous version or new module missing'
git -C "$root" -c user.name=t -c user.email=t@e commit -qm three --allow-empty
third="$(git -C "$root" rev-parse HEAD)"
PATH="$fixture/bin:$PATH" MAC_AUTOPILOT_ROOT="$root" bash "$script_dir/start.sh" --sync-only >/dev/null
[[ -d "$versions/$second" && -d "$versions/$third" && ! -e "$versions/$first" ]] || fail 'did not retain exactly current and previous versions'
PATH="$fixture/bin:$PATH" MAC_AUTOPILOT_ROOT="$root" bash "$script_dir/start.sh" --sync-only >/dev/null
[[ -d "$versions/$second" ]] || fail 'same-HEAD sync removed previous version'
diff -u "$live/config.template.json" "$state/config.json" || fail 'resync left runtime config different from repository config'
[[ "$(grep -c 'config-reconcile' "$AGENT_HOME/supervisor-inbox")" == 1 ]] || fail 'unchanged config emitted a duplicate drift event'
[[ -z "$(find "$versions" -maxdepth 1 -name '.stage.*')" ]] || fail 'stage left behind'

# nohup fallback (no systemd units): stop legacy autopi/ loops as well as autopi-live/ ones before starting new ones.
rm -f "$fixture/started"
PATH="$fixture/bin:$PATH" MAC_AUTOPILOT_ROOT="$root" bash "$script_dir/start.sh" >/dev/null 2>&1 || true
for loop in loop bell-loop zombie-loop; do
  grep -Fq "pkill -f autopi(-live)?/$loop[.]sh" "$fixture/started" || fail "nohup fallback does not stop legacy and live $loop"
done
rm -f "$fixture/started"

# live 副本（未设环境变量）从自身位置解析根目录。
resolved="$(env -u MAC_AUTOPILOT_ROOT -u MAC_AUTOPILOT_SUPERVISOR_DIR -u MAC_AUTOPILOT_RUNTIME_DIR \
  bash -c 'source "$1/runtime-env.sh"; printf "%s|%s" "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR"' _ "$live")"
[[ "$resolved" == "$root|$state" ]] || fail "live runtime resolved $resolved"
resolved="$(env -u MAC_AUTOPILOT_ROOT -u MAC_AUTOPILOT_SUPERVISOR_DIR -u MAC_AUTOPILOT_RUNTIME_DIR \
  bash -c 'source "$1/runtime-env.sh"; printf "%s" "$MAC_AUTOPILOT_ROOT"' _ "$script_dir")"
[[ "$resolved" == "$repo_root" ]] || fail "repo copy resolved $resolved"

# L27：已知年龄的旧时间戳必须解析出正确 epoch（age>0），不能静默回退 now。
source "$script_dir/runtime-env.sh"
[[ "$(ap_iso_epoch 2026-10-18T00:00:00Z)" == 1792281600 ]] || fail 'ap_iso_epoch wrong for a Z timestamp'
[[ -z "$(ap_iso_epoch not-a-time)" ]] || fail 'ap_iso_epoch must return empty on garbage'
[[ "$(ap_oom_command 5)" == journalctl* ]] || fail 'Linux OOM probe not journalctl'
declare -F platform_require pid_live pid_start_id >/dev/null || fail 'runtime-env.sh did not load the platform layer and the process helpers'

# worker 继承本机测试库地址；显式给出的 PGTEST_URL 优先。
[[ "$(env -u PGTEST_URL bash -c 'source "$1/runtime-env.sh"; printf %s "$PGTEST_URL"' _ "$script_dir")" == postgresql://example@127.0.0.1:5432/postgres ]] || fail 'runtime env does not give workers the local test Postgres'
[[ "$(PGTEST_URL=postgresql://x@h:1/postgres bash -c 'source "$1/runtime-env.sh"; printf %s "$PGTEST_URL"' _ "$script_dir")" == postgresql://x@h:1/postgres ]] || fail 'runtime env overrode an explicit PGTEST_URL'

echo 'start.test.sh: PASS'
