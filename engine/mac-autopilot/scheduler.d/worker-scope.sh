worker_scope_systemd_run_path() { type -P systemd-run 2>/dev/null; }

worker_scope_unavailable() { # reason; one warning for this scheduler tick
  local reason="$1"
  WORKER_SCOPE_MODE=unavailable
  if [[ "${WORKER_SCOPE_WARNED:-false}" != true ]]; then
    say "worker scope unavailable: $reason"
    WORKER_SCOPE_WARNED=true
  fi
}

worker_scope_prepare() { # config/systemd probe, cached for this scheduler tick
  local configured probe status config="${CFG:-}"
  [[ "${WORKER_SCOPE_PREPARED:-false}" == true ]] && return 0
  WORKER_SCOPE_PREPARED=true
  WORKER_SCOPE_MODE=disabled
  [[ -n "$config" ]] || config='{}'
  configured="$(jq -r '.engine.worker_tasks_max // 2000' <<<"$config" 2>/dev/null)" || configured=2000
  [[ "$configured" =~ ^[0-9]+$ ]] || configured=2000
  WORKER_TASKS_MAX="$configured"
  (( WORKER_TASKS_MAX > 0 )) || return 0
  if ! command -v setsid >/dev/null 2>&1; then
    worker_scope_unavailable 'setsid unavailable'
    return 0
  fi
  WORKER_SCOPE_SYSTEMD_RUN="$(worker_scope_systemd_run_path || true)"
  if [[ -z "$WORKER_SCOPE_SYSTEMD_RUN" ]]; then
    worker_scope_unavailable 'systemd-run unavailable'
    return 0
  fi
  probe="$(type -P true 2>/dev/null || true)"
  [[ -n "$probe" ]] || probe=true
  status=0
  "$WORKER_SCOPE_SYSTEMD_RUN" --user --scope --quiet -p "TasksMax=$WORKER_TASKS_MAX" -- "$probe" \
    >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    worker_scope_unavailable "systemd-run --user probe failed (exit $status)"
    return 0
  fi
  WORKER_SCOPE_MODE=scope
}

# Runs beside the worker in its scope (own session, so a group kill of the worker does not take it down) and
# reports the first fork the scope's TasksMax refused (pids.events "max"). Builtins only: a fork-bound scope cannot spawn `sleep`.
read -r -d '' WORKER_SCOPE_WATCH <<'WATCH' || :
leader=$1 max=$2 label=$3 sched_log=$4 hit=0 ev=${WORKER_SCOPE_EVENTS_FILE:-}
if [[ -z $ev ]]; then read -r ev < /proc/self/cgroup && ev=/sys/fs/cgroup${ev#0::}/pids.events; fi
[[ -r $ev ]] || exit 0
exec {fd}<> <(:)
while :; do
  alive=1; [[ -d /proc/$leader ]] || alive=0
  n=0; while read -r k v; do [[ $k == max ]] && n=$v; done < "$ev"
  if (( n > 0 && !hit )); then
    hit=1; printf -v now '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    echo "[worker-scope] TasksMax=$max reached ($n refused forks): this worker failed on its own task limit, not a host problem" >&2
    [[ -z $sched_log ]] || echo "[$now] worker-tasksmax-hit pid=$leader tasksmax=$max refused_forks=$n log=$label" >> "$sched_log"
  fi
  (( alive )) || break
  read -r -t 1 -u "$fd" || :
done
WATCH

worker_scope_exec() { # pid-file output-file launcher... -- command...; executed inside the worker's output/session wrapper
  local pid_file="$1" label="${2##*/}"; shift 2
  local -a launcher=() worker_command=()
  while (($#)) && [[ "$1" != -- ]]; do launcher+=("$1"); shift; done
  [[ "${1:-}" == -- ]] || return 2
  shift
  worker_command=("$@")
  if [[ "$WORKER_SCOPE_MODE" == scope ]]; then
    exec "$WORKER_SCOPE_SYSTEMD_RUN" --user --scope --quiet -p "TasksMax=$WORKER_TASKS_MAX" -- \
      setsid bash -c 'pid_file=$1; st=$(</proc/$$/stat); st=(${st##*) }); printf "%s %s\n" "$$" "${st[19]}" > "$pid_file" || exit 125
        setsid bash -c "$5" worker-scope-watch "$$" "$2" "$3" "$4" & shift 5; exec "$@"' \
      worker-scope "$pid_file" "$WORKER_TASKS_MAX" "$label" "${LOG:-}" "$WORKER_SCOPE_WATCH" "${worker_command[@]}"
  fi
  exec "${launcher[@]}" "${worker_command[@]}"
}

worker_scope_launch() { # pid-file workdir output-file launcher... -- command...; sets WORKER_SCOPE_PID, WORKER_SCOPE_PID_START (scope only) and WORKER_SCOPE_LAUNCHER_PID
  local pid_file="$1" workdir="$2" output_file="$3" scope_client status state
  shift 3
  local -a launcher=() worker_command=()
  while (($#)) && [[ "$1" != -- ]]; do launcher+=("$1"); shift; done
  [[ "${1:-}" == -- ]] || return 2
  shift
  worker_command=("$@")
  ((${#worker_command[@]})) || return 2
  worker_scope_prepare
  WORKER_SCOPE_PID_START=

  if [[ "$WORKER_SCOPE_MODE" == scope ]]; then
    rm -f -- "$pid_file"
    (cd "$workdir" && worker_scope_exec "$pid_file" "$output_file" "${launcher[@]}" -- "${worker_command[@]}") \
      >"$output_file" 2>&1 < /dev/null &
    scope_client=$!
    WORKER_SCOPE_LAUNCHER_PID="$scope_client"
    while [[ ! -s "$pid_file" ]]; do
      state="$(ps -o stat= -p "$scope_client" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -z "$state" || "$state" == Z* ]]; then
        [[ ! -s "$pid_file" ]] || break # wrote its PID, then died before this check: the worker did start
        status=0
        wait "$scope_client" || status=$?
        worker_scope_unavailable "systemd-run scope launch failed (exit $status)"
        rm -f -- "$pid_file"
        break
      fi
      sleep 0.02
    done
    if [[ -s "$pid_file" ]]; then
      # "pid start-ticks": the start time is read before the worker runs, so a worker that dies at once still has an identity.
      read -r WORKER_SCOPE_PID WORKER_SCOPE_PID_START < "$pid_file" || true
      if [[ "$WORKER_SCOPE_PID" =~ ^[1-9][0-9]*$ ]]; then
        rm -f -- "$pid_file"
        return 0
      fi
      # The scoped launcher only writes this file before it execs the worker; no worker can be running without it.
      status=0
      wait "$scope_client" || status=$?
      worker_scope_unavailable "systemd-run worker PID unavailable (exit $status)"
      rm -f -- "$pid_file"
    fi
  fi

  (cd "$workdir" && exec "${launcher[@]}" "${worker_command[@]}") >"$output_file" 2>&1 < /dev/null &
  WORKER_SCOPE_PID=$!
  WORKER_SCOPE_LAUNCHER_PID="$WORKER_SCOPE_PID"
}

# A launched worker keeps the stdout/stderr redirect to its $SUP/*.worker.log and the cwd of its unit worktree
# (dispatch.sh: `(cd $workdir && ...) >$SUP/$log`, scope or not). A claim can lack a pid because the tick died between
# worker_scope_launch and coord_renew, so this finds the worker without the claim.
# shortcut: a process of ours whose /proc cwd or fd is unreadable (systemd --user, ssh-agent here: ptrace-denied) is skipped,
# so a worker that drops dumpable or leaves its worktree is not seen; upgrade to a pid or scope recorded on the claim if one does.
worker_running_for_unit() { # unit -> 0 a launched worker runs / 1 none / 2 cannot tell
  local unit="$1" wt sup p cwd fd target
  wt="$(cd "${WT_ROOT:-}" 2>/dev/null && pwd -P)" && sup="$(cd "${SUP:-}" 2>/dev/null && pwd -P)" || return 2 # /proc shows real paths
  [[ -n "$unit" ]] && readlink /proc/self/cwd >/dev/null 2>&1 || return 2
  wt="$wt/wt-$unit"
  for p in /proc/[0-9]*; do
    [[ -O "$p" ]] || continue
    cwd="$(readlink "$p/cwd" 2>/dev/null)" || continue
    [[ "$cwd" == "$wt" || "$cwd" == "$wt"/* ]] || continue
    for fd in 1 2; do
      target="$(readlink "$p/fd/$fd" 2>/dev/null || true)"
      [[ "$target" == "$sup"/*.worker.log || "$target" == "$sup"/*.worker.log' (deleted)' ]] && return 0
    done
  done
  return 1
}

unit_has_no_worker() { # unit owner -> 0 only when no launched worker exists for the unit; logs why not otherwise
  local running=0
  worker_running_for_unit "$1" || running=$?
  (( running == 1 )) && return 0
  say "claim expiry $( ((running == 0)) && echo 'found a live worker' || echo 'cannot check workers') for unit=$1 owner=$2; retaining claim"
  return 1
}
