# Sourced by bell.sh. Needs its globals: now, STATE_JSON, SUPERVISOR_DIR, mtime_epoch.

# 重启台账：1 小时内最多 3 次，之后间隔按次数递增（第 2 次 300s 后、第 3 次 600s 后）；通过即记账。
# 暂停和 CHECK_ONLY 由调用方先判定，所以暂停时不计数（#122）。
restart_allowed() {
  local recent n last
  recent="$(jq -c --argjson now "$now" '[(.scheduler_restarts // [])[] | select($now - . < 3600)]' <<<"$STATE_JSON")"
  n="$(jq 'length' <<<"$recent")"
  last="$(jq 'max // 0' <<<"$recent")"
  (( n < 3 && now - last >= 300 * n )) || return 1
  STATE_JSON="$(jq -c --argjson recent "$recent" --argjson now "$now" '.scheduler_restarts = ($recent + [$now])' <<<"$STATE_JSON")"
}

# worker 进程死了但报告还在落盘：日志 10 分钟内写过就先不立 worker-died，下一拍再看（#542）。
worker_log_fresh() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != *".."* && -f "$SUPERVISOR_DIR/$1" ]] || return 1
  (( now - $(mtime_epoch "$SUPERVISOR_DIR/$1") < 600 ))
}
