# A finished worker's run-p scope can outlive its leader: a background wait loop kept one alive for 2 h 29 m on 2026-11-14
# (issue-6581). When harvest finishes a worker, stop its own scope if processes still sit in it. Never stops a scope whose
# leader is alive, and only the run-p scope recorded at dispatch (luna and zc scopes have other names).
harvest_scope_stop() { # worker JSON; called where harvest finishes the worker
  local w="$1" scope unit procs_file="" f n rc=0
  scope="$(jqf -r '.scope // empty' <<<"$w")"
  [[ "$scope" =~ ^run-p[1-9][0-9]*-i[^/]*\.scope$ ]] || return 0
  harvest_worker_alive "$w" && return 0
  for f in "${HARVEST_CGROUP_ROOT:-/sys/fs/cgroup}"/user.slice/user-$UID.slice/user@$UID.service/*/"$scope"/cgroup.procs; do
    [[ -r "$f" ]] && { procs_file="$f"; break; }
  done
  [[ -n "$procs_file" ]] || return 0 # the scope is already gone
  n="$(awk 'NF { c++ } END { print c + 0 }' "$procs_file")"
  (( n > 0 )) || return 0
  unit="$(jqf -r '.unit // empty' <<<"$w")"
  systemctl --user stop "$scope" >/dev/null 2>&1 || rc=$?
  say "harvest scope stop unit=$unit scope=$scope leftover=$n rc=$rc"
}
