#!/usr/bin/env bash
# One idempotent anomaly scan for the autopilot runtime.
set -o pipefail
shopt -s nullglob

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"
ROOT="$MAC_AUTOPILOT_ROOT"
A="${BELL_AUTOPI_DIR:-$MAC_AUTOPILOT_RUNTIME_DIR}"
CHECK_ONLY=0
TEST_NOTIFICATION=0
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --test-notification) TEST_NOTIFICATION=1; CHECK_ONLY=1 ;;
    *) echo "bell.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -d "$A" ]] || { echo "bell.sh: autopilot runtime is missing: $A" >&2; exit 1; }

# 不用 `// empty`：jq 的 // 把 false 当缺省，`auto_supervisor:false` 等开关会被静默改回默认 true。
cfg() { jq -r "($1) | if . == null then empty else . end" "$A/config.json" 2>/dev/null || true; }
cfg_bool() {
  local value
  value="$(cfg "$1")"
  case "$value" in true|false) ;; *) value="$2" ;; esac
  printf '%s' "$value"
}
ENABLED="$(cfg_bool '.bell.enabled' true)"
NOTIFY="$(cfg_bool '.bell.notify' true)"
AUTO_SUPERVISOR="$(cfg_bool '.bell.auto_supervisor' true)"
DEDUP_MINUTES="$(cfg '.bell.dedup_minutes')"
[[ "$DEDUP_MINUTES" =~ ^[0-9]+$ ]] || DEDUP_MINUTES=30
(( DEDUP_MINUTES > 0 )) || DEDUP_MINUTES=30
DEDUP_SECONDS=$((DEDUP_MINUTES * 60))
if [[ "$ENABLED" != true ]]; then
  [[ "$CHECK_ONLY" == 1 ]] && echo "bell check-only: disabled by config"
  exit 0
fi

STATE="$A/bell-state.json"
QUEUE="$A/BELL-QUEUE.md"
LOG="$A/bell.log"
SCAN_LOCK="$A/.bell.lock"
SUPERVISOR_LOCK="$A/.bell-supervisor.lock"
SCAN_PID=""
if [[ -s "$STATE" ]] && jq -e 'type=="object"' "$STATE" >/dev/null 2>&1; then
  STATE_JSON="$(jq -c '. + {monitor_initialized:(.monitor_initialized//false),scheduler_lines:(.scheduler_lines//0),alert_mtimes:(.alert_mtimes//{}),merge_events:(.merge_events//{}),signatures:(.signatures//{}),pending:(.pending//[]),network_down:(.network_down//false)}' "$STATE")"
else
  STATE_JSON='{"monitor_initialized":false,"scheduler_lines":0,"alert_mtimes":{},"merge_events":{},"signatures":{},"pending":[],"network_down":false}'
fi
MONITOR_INITIALIZED="$(jq -r '.monitor_initialized' <<<"$STATE_JSON")"

save_state() {
  [[ "$CHECK_ONLY" == 1 ]] && return 0
  local tmp="$STATE.tmp.$$"
  printf '%s\n' "$STATE_JSON" | jq -c . > "$tmp" && mv "$tmp" "$STATE"
}
acquire_lock() {
  if mkdir "$SCAN_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$SCAN_LOCK/pid"
    SCAN_PID="$$"
    return 0
  fi
  local old_pid=""
  [[ -r "$SCAN_LOCK/pid" ]] && old_pid="$(cat "$SCAN_LOCK/pid" 2>/dev/null || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then return 1; fi
  rm -f "$SCAN_LOCK/pid" 2>/dev/null || true
  rmdir "$SCAN_LOCK" 2>/dev/null || true
  mkdir "$SCAN_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$SCAN_LOCK/pid"
  SCAN_PID="$$"
}
release_lock() {
  [[ "$CHECK_ONLY" == 1 || -z "$SCAN_PID" ]] && return 0
  local pid=""
  [[ -r "$SCAN_LOCK/pid" ]] && pid="$(cat "$SCAN_LOCK/pid" 2>/dev/null || true)"
  if [[ "$pid" == "$SCAN_PID" ]]; then rm -f "$SCAN_LOCK/pid"; rmdir "$SCAN_LOCK" 2>/dev/null || true; fi
}
if [[ "$CHECK_ONLY" != 1 ]]; then
  acquire_lock || { echo "bell.sh: scan already active"; exit 0; }
  trap release_lock EXIT
fi

now="$(date +%s)"
stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SUPERVISOR_DIR="${BELL_SUPERVISOR_DIR:-$MAC_AUTOPILOT_SUPERVISOR_DIR}"
events=()
action_ids=()
action_severities=()
action_sigs=()
action_results=()
event_seq=0
clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }
add_event() { events+=("$1"$'\t'"$(clean "$2")"$'\t'"$(clean "$3")"$'\t'"$(clean "$4")"); }
mtime_ns() {
  python3 - "$1" <<'PY'
import os,sys
print(os.stat(sys.argv[1]).st_mtime_ns)
PY
}
to_epoch() {
  python3 - "$1" <<'PY'
from datetime import datetime,timezone
import sys
try:
 d=datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))
 print(int((d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp()))
except Exception: print("")
PY
}
mtime_epoch() {
  python3 - "$1" <<'PY'
import os,sys
print(int(os.stat(sys.argv[1]).st_mtime))
PY
}

# Read the candidate identities retained by the scheduler and both publishers.
# release.json is only a human checklist; without an authoritative publisher
# ledger, pending work cannot prove that an older CI run is disposable.
ci_protection() {
  python3 - "$A" "${AGENT_HOME:-}" <<'PY'
import glob,json,os,re,sys
a,agent_home=sys.argv[1:]
shas=set(); runs=set()
def read(path):
 with open(path,encoding="utf-8") as f: value=json.load(f)
 if not isinstance(value,dict): raise ValueError("state must be an object")
 return value
def sha(value,required=False):
 if value in (None,"") and not required: return
 if not isinstance(value,str) or not re.fullmatch(r"[0-9a-f]{40}",value):
  raise ValueError("active candidate SHA is missing or invalid")
 shas.add(value)
try:
 units=read(os.path.join(a,"units.json")).get("units")
 if not isinstance(units,list): raise ValueError("units array is missing")
 for unit in units:
  if not isinstance(unit,dict) or not isinstance(unit.get("stage"),str):
   raise ValueError("unit stage is missing or invalid")
 train_path=os.path.join(a,"release-train.json")
 has_train=os.path.lexists(train_path)
 if has_train:
  train=read(train_path)
  status=train.get("status")
  # release_train.sh retains old released_sha/build_run fields when it starts
  # another attempt. Only current status/candidate identify pending work.
  if status in ("building","deploying","held","blocked-credentials","deferred-busy"):
   sha(train.get("candidate"),required=True)
  # delegated: run-release.sh owns the candidate; its state/*.json release_candidate is read below.
  elif status not in ("released","failed","built","no-image-change","delegated"):
   raise ValueError("release train status is missing or unknown")
  # build_run belongs to example-infra; it is not a the product source CI run identity.
 if agent_home:
  state_dir=os.path.join(agent_home,"state")
  if not os.path.isdir(state_dir) or not os.access(state_dir,os.R_OK|os.X_OK):
   raise ValueError("configured run-release state directory is unavailable")
  for path in sorted(glob.glob(os.path.join(state_dir,"*.json"))):
   candidate=read(path).get("release_candidate")
   if candidate is None: continue
   if not isinstance(candidate,dict): raise ValueError("release candidate is invalid")
   status=candidate.get("status")
   if status == "invalidated": continue
   if status not in ("waiting","selected"): raise ValueError("release candidate status is unknown")
   sha(candidate.get("sha") or candidate.get("head_sha"),required=True)
   sha(candidate.get("head_sha"))
 elif not has_train:
  steps=read(os.path.join(a,"release.json")).get("steps")
  if not isinstance(steps,list): raise ValueError("release checklist is missing")
  if any(not isinstance(step,dict) or step.get("status") != "done" for step in steps):
   raise ValueError("unfinished release has no authoritative candidate ledger")
 print(json.dumps({"shas":sorted(shas),"run_ids":sorted(runs)}))
except (OSError,ValueError,TypeError) as exc:
 print(str(exc),file=sys.stderr)
 sys.exit(1)
PY
}

# Probe GitHub's main ref on every beat. Keep the last known outage in state so
# recovery is emitted once, even when the probe remains green on later beats.
network_down="$(jq -r '.network_down // false' <<<"$STATE_JSON")"
probe_error=""
if probe_error="$(cd "$ROOT" && timeout 8 git ls-remote origin refs/heads/main 2>&1 >/dev/null)"; then
  if [[ "$network_down" == true ]]; then
    add_event info "network-recovered" "network-recovered: GitHub probe is green again" "network probe recovered after an outage"
    STATE_JSON="$(jq -c '.network_down=false' <<<"$STATE_JSON")"
  fi
else
  probe_status=$?
  if (( probe_status != 0 )) && printf '%s' "$probe_error" | grep -Eiq '502|timed out|Connection'; then
    add_event high "network-down" "network-down: suites 裁决在此期间可能假阴性；网络恢复后应重跑在跑的失败 run" "timeout 8 git ls-remote origin refs/heads/main failed: $probe_error"
    STATE_JSON="$(jq -c '.network_down=true' <<<"$STATE_JSON")"
  fi
fi

lines=0
[[ -s "$A/scheduler.log" ]] && lines="$(wc -l < "$A/scheduler.log" | awk '{print $1}')"
alerts='{}'
for f in "$A"/alerts/*.md; do
  [[ -f "$f" ]] || continue
  rel="alerts/$(basename "$f")"
  mt="$(mtime_ns "$f" 2>/dev/null || echo 0)"
  [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
  alerts="$(jq -c --arg p "$rel" --argjson mt "$mt" '.[$p]=$mt' <<<"$alerts")"
done
merges='{}'
if [[ -r "$A/units.json" ]]; then
  merges="$(jq -c '[.units[]? as $u|($u.history//[])|to_entries[]?|select(.value.stage=="merge-reverted")|"\($u.id):\(.key):\(.value.at//"")"]|reduce .[] as $k ({};.[$k]=true)' "$A/units.json" 2>/dev/null || echo '{}')"
fi

if [[ "$MONITOR_INITIALIZED" == true ]]; then
  old_lines="$(jq -r '.scheduler_lines' <<<"$STATE_JSON")"
  [[ "$old_lines" =~ ^[0-9]+$ ]] || old_lines=0
  (( lines < old_lines )) && old_lines=0
  if (( lines > old_lines )); then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # tick done 行只是每拍汇总；它的阶段计时含 release_dependency_blocks，会被 BLOCK 误判成 high（2026-10-20 32 条）。
      [[ "$line" == *"] tick done "* ]] && continue
      printf '%s\n' "$line" | grep -Eiq 'SLOW|KILL|BLOCK|orphan-recover|budget|merge-revert|verdict=BLOCK|error' || continue
      clean_line="$(printf '%s\n' "$line" | sed -E 's/^\[[^]]+\][[:space:]]*//' | tr '\t\r\n' '   ')"
      sev=medium
      printf '%s\n' "$clean_line" | grep -Eiq 'KILL|BLOCK|verdict=BLOCK|merge-revert|error' && sev=high
      if printf '%s\n' "$clean_line" | grep -Eiq 'merge-reverted'; then
        unit="$(printf '%s\n' "$clean_line" | sed -nE 's/.*merge-reverted unit=([^ ]+).*/\1/p')"
        [[ -n "$unit" ]] || unit=unknown
        raw="merge-reverted unit=$unit"; sev=high
      else
        raw="scheduler:$clean_line"
      fi
      add_event "$sev" "$raw" "scheduler.log: $clean_line" "tail -n 120 '$A/scheduler.log'"
    done < <(sed -n "$((old_lines+1)),${lines}p" "$A/scheduler.log" 2>/dev/null)
  fi

  for f in "$A"/alerts/*.md; do
    [[ -f "$f" ]] || continue
    rel="alerts/$(basename "$f")"
    mt="$(jq -r --arg p "$rel" '.[$p]//empty' <<<"$alerts")"
    old_mt="$(jq -r --arg p "$rel" '.alert_mtimes[$p]//empty' <<<"$STATE_JSON")"
    [[ -n "$mt" && "$mt" != "$old_mt" ]] || continue
    last="$(tail -n 1 "$f" 2>/dev/null | tr '\t\r\n' '   ')"
    add_event medium "alerts-mtime:$rel" "alert changed: $rel $last" "tail -n 120 '$A/$rel'"
  done

  if [[ -r "$A/units.json" ]]; then
    while IFS=$'\t' read -r unit idx at result; do
      [[ -n "$unit" ]] || continue
      key="${unit}:${idx}:${at}"
      known="$(jq -r --arg k "$key" '.merge_events[$k]//false' <<<"$STATE_JSON")"
      [[ "$known" == true ]] && continue
      add_event high "merge-reverted unit=$unit" "merge-reverted unit=$unit $(clean "$result")" "tail -n 120 '$A/units.json'; tail -n 120 '$A/alerts/merge.md'"
    done < <(jq -r '.units[]? as $u|($u.history//[])|to_entries[]?|select(.value.stage=="merge-reverted")|[$u.id,(.key|tostring),(.value.at//""),(.value.result//"")]|@tsv' "$A/units.json" 2>/dev/null)
  fi
fi

tick=""
tick_epoch=""
if [[ -s "$A/scheduler.log" ]]; then
  last_line="$(tail -n 1 "$A/scheduler.log" 2>/dev/null || true)"
  if [[ "$last_line" =~ ^\[([^]]+)\] ]]; then tick="${BASH_REMATCH[1]}"; tick_epoch="$(to_epoch "$tick")"; fi
  # 行首时间是该拍开始的 STAMP：一拍 6 分钟 + sleep 120s 后最后一行看着有 8 分钟旧，其实刚写完。
  # 日志最后写入时刻才是存活信号（2026-10-21 02:07–02:20 连续三次误判重启）。
  log_epoch="$(mtime_epoch "$A/scheduler.log" 2>/dev/null || echo 0)"
  if [[ "$tick_epoch" =~ ^[0-9]+$ && "$log_epoch" =~ ^[0-9]+$ ]] && (( log_epoch > tick_epoch )); then tick_epoch="$log_epoch"; fi
fi
stale=0
if [[ ! "$tick_epoch" =~ ^[0-9]+$ ]] || (( now - tick_epoch > 360 )); then stale=1; fi
# 慢 tick 不是卡死：tick 锁的持有进程还活着且锁不到 30 分钟，就不算 stale。2026-10-20 tick 常要 6–7 分钟，
# bell 每次都判 stale 重启 scheduler 单元，连带杀光在跑的 worker（5 小时 40 个无产出死亡）。
if [[ "$stale" == 1 && -d "$A/.scheduler.lock" ]]; then
  lock_pid="$(cat "$A/.scheduler.lock/pid" 2>/dev/null || true)"
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null \
      && [[ -z "$(find "$A/.scheduler.lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]]; then
    stale=0
  fi
fi
if [[ "$stale" == 1 ]]; then
  restart="not attempted in check-only mode"
  sev=high
  if [[ "$CHECK_ONLY" != 1 && -n "${AUTOPILOT_LOOP_UNIT:-}" ]]; then
    # systemd 托管时由 systemd 重启，避免与 Restart=always 叠出第二个 loop。
    if systemctl --user restart "$AUTOPILOT_LOOP_UNIT" 2>/dev/null; then restart="loop restarted via systemd unit $AUTOPILOT_LOOP_UNIT"; else restart="systemd restart of $AUTOPILOT_LOOP_UNIT failed"; sev=critical; fi
  elif [[ "$CHECK_ONLY" != 1 ]]; then
    if [[ -r "$A/loop.pid" ]]; then
      old_pid="$(cat "$A/loop.pid" 2>/dev/null || true)"
      if [[ "$old_pid" =~ ^[0-9]+$ && "$old_pid" != "$$" ]]; then
        old_cmd="$(ps -p "$old_pid" -o command= 2>/dev/null || true)"
        [[ "$old_cmd" == *"loop.sh"* ]] && kill "$old_pid" 2>/dev/null || true
      fi
    fi
    pkill -f 'bash loop[.]sh' 2>/dev/null || true; pkill -f 'autopi-live/loop[.]sh' 2>/dev/null || true
    sleep 1
    (nohup bash "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live/loop.sh" >> "$A/loop.out" 2>&1 < /dev/null) &
    loop_pid=$!
    printf '%s\n' "$loop_pid" > "$A/loop.pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$loop_pid" 2>/dev/null; then restart="loop restarted pid=$loop_pid"; else restart="loop restart failed"; sev=critical; fi
  fi
  add_event "$sev" "scheduler-stale:last_tick=${tick:-missing}" "scheduler tick stale (${tick:-no readable tick}); $restart" "tail -n 120 '$A/scheduler.log'; ps -Ao pid,command"
fi

if [[ -r "$A/workers.json" && -r "$A/units.json" ]]; then
  while IFS=$'\t' read -r pid unit harvested log report; do
    [[ "$pid" =~ ^[0-9]+$ && -n "$unit" ]] || continue
    [[ "$harvested" == true ]] && continue
    kill -0 "$pid" 2>/dev/null && continue
    # 已交付报告的 worker 是正常结束、等下一拍回收，不是死亡（每次误报都会拉起一次付费调查）。
    [[ "$report" =~ ^[A-Za-z0-9._/-]+$ && "$report" != *".."* && -s "$SUPERVISOR_DIR/$report" ]] && continue
    stage="$(jq -r --arg id "$unit" '.units[]?|select(.id==$id)|.stage//empty' "$A/units.json" 2>/dev/null | head -n 1)"
    [[ -n "$stage" ]] || continue
    case "$stage" in merged|landed|done|wontfix|duplicate) continue ;; esac
    [[ "$log" =~ ^[A-Za-z0-9._/-]+$ && "$log" != *".."* ]] || log="[invalid path]"
    [[ "$report" =~ ^[A-Za-z0-9._/-]+$ && "$report" != *".."* ]] || report="[invalid path]"
    oom_output="$(ap_oom_evidence 5 | head -c 2048 || true)"
    [[ -n "$oom_output" ]] || oom_output="[no matching journal output]"
    evidence="tail -n 120 '$SUPERVISOR_DIR/$log'; tail -n 120 '$SUPERVISOR_DIR/$report'; $(ap_oom_command 5) output (max 2048 bytes): $oom_output"
    add_event high "worker-died unit=$unit" "worker-died unit=$unit pid=$pid stage=$stage log=$log report=$report" "$evidence"
  done < <(jq -r '.workers[]?|[(.pid|tostring),(.unit//""),((.harvested//false)|tostring),(.log//""),(.report//"")]|@tsv' "$A/workers.json" 2>/dev/null)
fi

# Repeated pipeline-suite failures are promoted when the same suite appears in
# either scheduler.log or alerts/gate.md at least twice in the last 24 hours.
suite_failures='{}'
record_suite_failures() {
  local file="$1" line timestamp epoch suite count
  [[ -r "$file" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^\[([^]]+)\] ]] || continue
    timestamp="${BASH_REMATCH[1]}"
    epoch="$(to_epoch "$timestamp")"
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    (( epoch >= now - 86400 && epoch <= now )) || continue
    [[ "$line" =~ \[pipeline[[:space:]]suites\].*FAILED[[:space:]]suite=([^[:space:]]+) ]] || continue
    suite="${BASH_REMATCH[1]}"
    count="$(jq -r --arg suite "$suite" '.[$suite] // 0' <<<"$suite_failures")"
    suite_failures="$(jq -c --arg suite "$suite" --argjson count "$((count + 1))" '.[$suite]=$count' <<<"$suite_failures")"
  done < <(grep -E '^\[[^]]+\].*\[pipeline[[:space:]]suites\].*FAILED[[:space:]]suite=' "$file" 2>/dev/null)
}
record_suite_failures "$A/scheduler.log"
record_suite_failures "$A/alerts/gate.md"
while IFS= read -r suite; do
  [[ -n "$suite" ]] || continue
  add_event high "suite-flake:$suite" "suite-flake:$suite failed at least twice in 24h; 隔离候选：在 engine/run-ci-suites.sh 的 nightly_suite_paths=(...) 中加入 '$suite'，再运行 bash engine/run-ci-suites.sh --nightly（按 nightly 层运行）" "FAILED suite=$suite repeated in scheduler.log or alerts/gate.md; add '$suite' to nightly_suite_paths, then run bash engine/run-ci-suites.sh --nightly"
done < <(jq -r 'to_entries[] | select(.value >= 2) | .key' <<<"$suite_failures")

# Old advisor verdict files with remaining FIX items stay visible as an
# actionable import queue item; no issue or repository writes happen here.
stale_verdict_files=()
unimported_fix_count=0
for f in "$SUPERVISOR_DIR"/advisor-verdicts-*.json; do
  [[ -f "$f" ]] || continue
  file_mtime="$(mtime_epoch "$f" 2>/dev/null || echo 0)"
  [[ "$file_mtime" =~ ^[0-9]+$ ]] || continue
  (( now - file_mtime > 172800 && file_mtime <= now )) || continue
  fix_count="$(jq '[.[]? | select(type=="object" and .verdict=="FIX")] | length' "$f" 2>/dev/null || echo 0)"
  [[ "$fix_count" =~ ^[0-9]+$ ]] || fix_count=0
  (( fix_count > 0 )) || continue
  stale_verdict_files+=("$(basename "$f"):$fix_count")
  unimported_fix_count=$((unimported_fix_count + fix_count))
done
if (( unimported_fix_count > 0 )); then
  file_list="$(printf '%s, ' "${stale_verdict_files[@]}")"
  file_list="${file_list%, }"
  add_event medium "verdicts-backlog-stale" "verdicts-backlog-stale: $unimported_fix_count unimported FIX item(s) in files older than 48h ($file_list); 批量导入模板：gh issue create --repo ${ZF_REPO:-<owner/name>} --title '<FIX 标题>' --body-file '<issue-body.md>' --label bug --label needs-triage（建成 issue 后由 auto_triage 接管）" "advisor FIX backlog: $unimported_fix_count unimported item(s) in $file_list; template: gh issue create --repo ${ZF_REPO:-<owner/name>} --title '<FIX 标题>' --body-file '<issue-body.md>' --label bug --label needs-triage"
fi

# S11 dashboard 心跳(dead man's switch):gen_dashboard 曾静默崩 3268 次
if [[ ! -f "$A/dashboard.data.js" ]]; then
  add_event high "dashboard-data-missing" "dashboard-data-missing: dashboard.data.js 不存在,检查生成器输出目录和最近退出日志" "expected heartbeat file: $A/dashboard.data.js"
else
  dash_mtime="$(ap_mtime_epoch "$A/dashboard.data.js" || true)"
  if [[ ! "$dash_mtime" =~ ^[0-9]+$ ]]; then
    add_event high "dashboard-data-unreadable" "dashboard-data-unreadable: 无法读取 dashboard.data.js 心跳时间" "unable to stat $A/dashboard.data.js"
  else
  dash_age=$(( now - dash_mtime ))
  if (( dash_age > 900 )); then
    add_event high "dashboard-data-stale" "dashboard-data-stale: dashboard.data.js 已 ${dash_age}s 未刷新(gen_dashboard 可能静默崩,查 autopilot.err;bell-loop 与 scheduler tick 每 2 分钟都会触发生成)" "dashboard.data.js mtime age ${dash_age}s > 900s"
  fi
  fi
fi

# The run lists come from the scheduler's per-tick snapshot (pr-run-snapshot.json); a missing or malformed one keeps every queue.
# S12 deduplicates CI and Pipeline suites waiting queues independently. Keep
# in_progress runs, waiting runs with started jobs, and each workflow's newest
# queued/pending/waiting run. GitHub can report queued while a shard is running.
# The replacement run supplies the SHA proof, so a [skip ci] main HEAD is safe.
# Check-only reports plans; candidate identity is re-read before cancellation.
if [[ "${BELL_STALE_CI_DISABLE:-0}" != "1" ]]; then
  cancelled=""
  for wf in CI "Pipeline suites"; do
    if ! ci_runs="$(pr_run_snapshot_section "$A" ".main_runs[\"$wf\"]")" \
      || ! jq -e 'type=="array" and all(.[]; (.databaseId|type)=="number" and (.databaseId>0) and (.databaseId|floor)==.databaseId and (.headSha|type)=="string" and (.headSha|test("^[0-9a-f]{40}$")) and (.status|type)=="string" and (.createdAt|type)=="string" and (.createdAt|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))' <<<"$ci_runs" >/dev/null 2>&1; then
      add_event medium "stale-main-ci-verdict-unknown:$wf" "stale-main-ci-verdict-unknown: 无法读取 $wf 的完整 run 列表,保留该队列" "the scheduler snapshot is missing or its run list is invalid"
      continue
    fi
    waiting_runs="$(jq -c '[.[] | select(.status=="queued" or .status=="pending" or .status=="waiting")] | sort_by(.createdAt,.databaseId)' <<<"$ci_runs")"
    [[ "$(jq 'length' <<<"$waiting_runs")" -gt 1 ]] || continue
    if ! protection="$(ci_protection 2>&1)"; then
      add_event medium "stale-main-ci-protection-unknown" "stale-main-ci-protection-unknown: 保留所有 CI run; $protection" "candidate identity must be readable before cancellation"
      break
    fi
    replacement_sha="$(jq -r '.[-1].headSha' <<<"$waiting_runs")"
    stale_runs=()
    while IFS=$'\t' read -r rid rsha; do
      [[ -n "$rid" ]] || continue
      git -C "$ROOT" merge-base --is-ancestor "$rsha" "$replacement_sha" >/dev/null 2>&1 || continue
      stale_runs+=("$rid:$rsha")
    done < <(jq -r --argjson protected "$protection" \
        '.[-1].createdAt as $latest | .[:-1][] | select(.createdAt < $latest)
         | select(.headSha as $sha | ($protected.shas|index($sha))==null)
         | select((.databaseId|tostring) as $id | ($protected.run_ids|index($id))==null)
         | "\(.databaseId)\t\(.headSha)"' <<<"$waiting_runs")
    if [[ "$CHECK_ONLY" == 1 ]]; then
      if (( ${#stale_runs[@]} > 0 )); then
        add_event info "stale-main-ci-would-cancel:$wf" "stale-main-ci: check-only would cancel $wf ${stale_runs[*]}" "no CI runs were canceled"
      fi
      continue
    fi
    for sr in "${stale_runs[@]}"; do
      rid="${sr%%:*}"; rsha="${sr#*:}"
      # The queued run may have started after the list response.
      if ! current_run="$(gh run view "$rid" -R "${ZF_REPO:?ZF_REPO is not set}" --json databaseId,headSha,status,jobs 2>/dev/null)" \
        || ! jq -e --argjson id "$rid" --arg sha "$rsha" 'type=="object" and .databaseId==$id and .headSha==$sha and (.status|type)=="string"' <<<"$current_run" >/dev/null 2>&1; then
        add_event medium "stale-main-ci-verdict-unknown:$wf" "stale-main-ci-verdict-unknown: 取消前无法确认 $wf run $rid 的状态,保留剩余队列" "run identity or status changed during scan"
        break
      fi
      jq -e '.status=="queued" or .status=="pending" or .status=="waiting"' <<<"$current_run" >/dev/null || continue
      if ! jq -e '(.jobs|type)=="array" and all(.jobs[]; type=="object" and (.status=="queued" or .status=="pending" or .status=="waiting" or .status=="in_progress" or .status=="completed"))' <<<"$current_run" >/dev/null 2>&1; then
        add_event medium "stale-main-ci-jobs-unknown:$wf" "stale-main-ci-jobs-unknown: 取消前无法确认 $wf run $rid 的 job 状态,保留剩余队列" "missing or unknown jobs cannot prove that no job has started"
        break
      fi
      jq -e 'any(.jobs[]; .status=="in_progress" or .status=="completed")' <<<"$current_run" >/dev/null && continue
      if ! protection="$(ci_protection 2>&1)"; then
        add_event medium "stale-main-ci-protection-unknown" "stale-main-ci-protection-unknown: 取消前保护信息失效,保留剩余 run; $protection" "candidate protection changed during scan"
        break
      fi
      if jq -e --arg sha "$rsha" --arg id "$rid" \
        '(.shas|index($sha))!=null or (.run_ids|index($id))!=null' <<<"$protection" >/dev/null; then
        continue
      fi
      bash "${ZF_ENGINE_DIR:-$ROOT/engine}/night/main-ci-recovery.sh" cancel-run "$rid" >/dev/null 2>&1 && cancelled="$cancelled $rid"
    done
  done
  [[ -n "$cancelled" ]] && add_event medium "stale-main-ci-canceled${cancelled}" "stale-main-ci: 取消被更新等待 run 取代、未被候选引用的祖先 run(在跑的不动):${cancelled}" "audited CI/Pipeline suites queue dedupe after candidate and ancestry checks: ${cancelled}"
fi

if [[ "$CHECK_ONLY" == 1 ]]; then
  echo "bell check-only: ${#events[@]} candidate event(s); runtime state and files were not changed"
  for item in "${events[@]}"; do
    IFS=$'\t' read -r sev raw summary evidence <<<"$item"
    h="$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')"
    echo "candidate severity=$sev sig=${h:0:16}"
  done
  if [[ "$TEST_NOTIFICATION" == 1 && "$NOTIFY" == true ]]; then
    if ap_notify "流水线异常" "the product bell: 验收测试"; then echo "test-notification=sent"; else echo "test-notification=failed (silent)"; fi
  fi
  exit 0
fi

for item in "${events[@]}"; do
  IFS=$'\t' read -r sev raw summary evidence <<<"$item"
  h="$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')"
  prev="$(jq -r --arg h "$h" '.signatures[$h].last//0' <<<"$STATE_JSON")"
  count="$(jq -r --arg h "$h" '.signatures[$h].count//0' <<<"$STATE_JSON")"
  event_id="$(jq -r --arg h "$h" '.signatures[$h].event_id//empty' <<<"$STATE_JSON")"
  [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  if [[ "$raw" != network-recovered ]] && (( prev > 0 && now - prev < DEDUP_SECONDS )); then
    count=$((count+1))
    STATE_JSON="$(jq -c --arg h "$h" --argjson now "$now" --argjson n "$count" --arg id "$event_id" '.signatures[$h].last=$now|.signatures[$h].count=$n|if $n>=2 and $id!="" then .pending|=map(if .id==$id and .status=="queued" then .needs_supervisor=true else . end) else . end' <<<"$STATE_JSON")"
    save_state
    continue
  fi

  event_seq=$((event_seq+1))
  event_id="${now}-$$-${event_seq}"
  needs=false
  case "$sev" in high|critical) needs=true ;; esac
  STATE_JSON="$(jq -c --arg h "$h" --arg raw "$raw" --arg id "$event_id" --arg sev "$sev" --arg summary "$summary" --arg evidence "$evidence" --argjson now "$now" --argjson needs "$needs" '.signatures[$h]={last:$now,count:1,event_id:$id}|.pending += [{id:$id,signature:$h,raw_signature:$raw,severity:$sev,summary:$summary,evidence:$evidence,needs_supervisor:$needs,status:"queued"}]' <<<"$STATE_JSON")"
  if ! grep -Fq "event_id=$event_id" "$QUEUE" 2>/dev/null; then
    printf '[%s] %s %s event_id=%s | %s | %s\n' "$stamp" "$sev" "$h" "$event_id" "$summary" "$evidence" >> "$QUEUE" || true
  fi
  if [[ "$NOTIFY" == true ]]; then
    if ap_notify "流水线异常" "the product bell: ${h:0:16}"; then notified=sent; else notified=failed; fi
  else notified=off
  fi
  sup=not-required
  [[ "$needs" == true ]] && sup=queued
  action_ids+=("$event_id"); action_severities+=("$sev"); action_sigs+=("$h")
  action_results+=("queue=append,notify=$notified,supervisor=$sup")
  save_state
done

if [[ -r "$A/BELL-RESOLUTION.md" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if grep -Fq "event_id: $id status: complete" "$A/BELL-RESOLUTION.md"; then
      STATE_JSON="$(jq -c --arg id "$id" '.pending|=map(if .id==$id then .status="done" else . end)' <<<"$STATE_JSON")"
    elif grep -Fq "event_id: $id status: failed" "$A/BELL-RESOLUTION.md"; then
      STATE_JSON="$(jq -c --arg id "$id" '.pending|=map(if .id==$id then .status="failed" else . end)' <<<"$STATE_JSON")"
    fi
  done < <(jq -r '.pending[]?.id' <<<"$STATE_JSON")
fi

lock_live=0
if [[ -d "$SUPERVISOR_LOCK" ]]; then
  spid="$(cat "$SUPERVISOR_LOCK/pid" 2>/dev/null || true)"
  if [[ "$spid" =~ ^[0-9]+$ ]] && kill -0 "$spid" 2>/dev/null; then lock_live=1
  else
    rm -f "$SUPERVISOR_LOCK/pid" 2>/dev/null || true; rmdir "$SUPERVISOR_LOCK" 2>/dev/null || true
    STATE_JSON="$(jq -c '.pending|=map(if .status=="running" then .status="queued" else . end)' <<<"$STATE_JSON")"
  fi
fi
trigger_pending="$(jq -r '[.pending[]?|select(.needs_supervisor==true and .status=="queued")]|length>0' <<<"$STATE_JSON")"
pending="$(jq -c '[.pending[]?|select(.status=="queued")]|.[0]//empty' <<<"$STATE_JSON")"
if [[ "$AUTO_SUPERVISOR" == true && "$trigger_pending" == true && -n "$pending" && "$lock_live" == 0 ]] && mkdir "$SUPERVISOR_LOCK" 2>/dev/null; then
  id="$(jq -r '.id' <<<"$pending")"
  h="$(jq -r '.signature' <<<"$pending")"
  summary="$(jq -r '.summary' <<<"$pending")"
  STATE_JSON="$(jq -c --arg id "$id" '.pending|=map(if .id==$id then .status="running" else . end)' <<<"$STATE_JSON")"
  save_state
  BELL_CODE="$HERE" BELL_A="$A" BELL_LOCK="$SUPERVISOR_LOCK" BELL_ID="$id" BELL_HASH="$h" BELL_SUMMARY="$summary" \
    nohup python3 - <<'PY' >/dev/null 2>&1 &
import datetime,os,signal,subprocess
a=os.environ["BELL_A"]; lock=os.environ["BELL_LOCK"]
event_id=os.environ["BELL_ID"]; signature=os.environ["BELL_HASH"]; summary=os.environ["BELL_SUMMARY"]
prompt=f"""Read {os.environ["BELL_CODE"]}/BELL-CHARTER.md, then read the first unresolved entry in {a}/BELL-QUEUE.md (event_id={event_id}, signature={signature}).
Classify the anomaly, gather evidence using only the permitted read tools, and return a concise resolution report with evidence paths and a recommended next action. Do not perform the recommendation. Do not deploy, push, delete data, change workers.json or units.json, or access production. The runner appends your response to BELL-RESOLUTION.md."""
allowed="Read,Grep,Bash(git log:*),Bash(tail:*),Bash(grep:*),Bash(ps:*),Bash(log show:*),Bash(journalctl:*)"
# 不加 --dangerously-skip-permissions：只读边界靠 allowedTools 强制，而不只靠提示词。
cmd=["claude","-p",prompt,"--max-turns","12","--tools","Read,Grep,Bash","--allowedTools",allowed]
out=""; code=1; timed_out=False
try:
 p=subprocess.Popen(cmd,cwd=a,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
 with open(os.path.join(lock,"pid"),"w") as f: f.write(str(p.pid))
 try: out,_=p.communicate(timeout=600); code=p.returncode
 except subprocess.TimeoutExpired:
  timed_out=True
  try: os.killpg(p.pid,signal.SIGTERM); out,_=p.communicate(timeout=5)
  except Exception:
   try: os.killpg(p.pid,signal.SIGKILL)
   except Exception: pass
   out,_=p.communicate()
  code=124
except Exception as e: out=f"Supervisor launch failed: {e}"
stamp=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
status="complete" if code==0 and out.strip() and not timed_out else "failed"
with open(os.path.join(a,"BELL-SUPERVISOR.log"),"a") as f:
 f.write(f"\n[{stamp}] event_id={event_id} signature={signature} status={status} exit={code}\n{out.rstrip()}\n")
with open(os.path.join(a,"BELL-RESOLUTION.md"),"a") as f:
 f.write(f"\n## {stamp} event_id: {event_id} status: {status}\nSignature: {signature}\nSummary: {summary}\n\n{out.rstrip()}\n")
 if timed_out: f.write("Runner stopped the supervisor after the 10 minute limit.\n")
try: os.remove(os.path.join(lock,"pid"))
except OSError: pass
try: os.rmdir(lock)
except OSError: pass
PY
  sup_pid=$!
  printf '%s\n' "$sup_pid" > "$SUPERVISOR_LOCK/pid" 2>/dev/null || true
  if kill -0 "$sup_pid" 2>/dev/null; then
    for i in "${!action_ids[@]}"; do
      if [[ "${action_ids[$i]}" == "$id" ]]; then action_results[$i]="${action_results[$i]/supervisor=queued/supervisor=started}"; fi
    done
  else
    STATE_JSON="$(jq -c --arg id "$id" '.pending|=map(if .id==$id then .status="queued" else . end)' <<<"$STATE_JSON")"
    rm -f "$SUPERVISOR_LOCK/pid" 2>/dev/null || true; rmdir "$SUPERVISOR_LOCK" 2>/dev/null || true
    for i in "${!action_ids[@]}"; do
      if [[ "${action_ids[$i]}" == "$id" ]]; then action_results[$i]="${action_results[$i]/supervisor=queued/supervisor=launch-failed}"; fi
    done
  fi
  save_state
fi

for i in "${!action_ids[@]}"; do
  printf '[%s] %s sig=%s event_id=%s action=%s\n' "$stamp" "${action_severities[$i]}" "${action_sigs[$i]}" "${action_ids[$i]}" "${action_results[$i]}" >> "$LOG"
done
# 状态瘦身:已完结 pending 只留最近 50 条,7 天未再出现的签名淘汰(防 bell-state 无界增长拖慢每拍)。
STATE_JSON="$(jq -c --argjson now "$now" '.pending |= ([.[] | select(.status != "done" and .status != "failed")] + ([.[] | select(.status == "done" or .status == "failed")] | .[-50:])) | .signatures |= with_entries(select((.value.last // 0) > ($now - 604800)))' <<<"$STATE_JSON")"
if [[ "$MONITOR_INITIALIZED" != true ]]; then
  STATE_JSON="$(jq -c --argjson lines "$lines" --argjson alerts "$alerts" --argjson merges "$merges" '.monitor_initialized=true|.scheduler_lines=$lines|.alert_mtimes=$alerts|.merge_events=$merges' <<<"$STATE_JSON")"
else
  STATE_JSON="$(jq -c --argjson lines "$lines" --argjson alerts "$alerts" --argjson merges "$merges" '.scheduler_lines=$lines|.alert_mtimes=$alerts|.merge_events=((.merge_events//{})+$merges)' <<<"$STATE_JSON")"
fi
save_state
