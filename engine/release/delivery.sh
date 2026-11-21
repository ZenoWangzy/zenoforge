SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
DEPLOY_TRANSPORT_DROP=0

remote() { ssh "${SSH_OPTS[@]}" "$DEPLOY_HOST" "$1"; }

remote_up() {
  local rc=0
  remote "$1" || rc=$?
  [[ "$rc" -eq 255 ]] || return "$rc"
  echo 'run-release: deploy transport drop: retrying once' >&2
  sleep "${RELEASE_SSH_RETRY_WAIT:-10}"
  rc=0
  remote "$1" || rc=$?
  [[ "$rc" -ne 255 ]] || DEPLOY_TRANSPORT_DROP=1
  return "$rc"
}
