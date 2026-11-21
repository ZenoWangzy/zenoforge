# Shared remote hand-off for bin/luna and bin/zc: with ZF_WORKER_HOST naming a remote host,
# worker-remote.py ships the run there and mirrors its run files back into $out (the caller's
# variable, already created). A remote refusal falls back to the local capacity gate: the
# helper exits the wrapper after a remote run and returns 1 when the caller should run locally.
worker_remote_handoff() {
  local backend=$1 out=$2 key=$3 cwd=$4 prompt=$5 schema=${6:-} helper remote_rc remote_reason
  [[ ${ZF_WORKER_REMOTE_INNER:-0} != 1 && ${ZF_WORKER_HOST:-local} != local ]] || return 1
  helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/worker-remote.py"
  python3 "$helper" run "$ZF_WORKER_HOST" "$key" "$cwd" "$prompt" "$schema" "$backend"
  remote_rc=$?
  if [[ ! -s "$out/remote-refused" ]]; then exit "$remote_rc"; fi
  remote_reason=$(cat "$out/remote-refused"); rm -f "$out/remote-refused" "$out/remote.host" "$out/remote.scope"
  printf '%s: remote host %s refused (%s); falling back to local capacity gate\n' "$backend" "$ZF_WORKER_HOST" "$remote_reason" >&2
  return 1
}
