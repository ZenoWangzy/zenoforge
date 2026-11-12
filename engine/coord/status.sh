#!/usr/bin/env bash
# Host status record and `status show` (DISTRIBUTED.md 4.9). A record is worker.json: proto, host, instance,
# heartbeat_at, draining and caps. Publishing it to refs/status/<host> is K2; this reads records from a directory.
# Usage: status.sh show <dir>   (dir holds one <host>.json per host)

# status_record <host> <instance> <heartbeat_at> <caps-json>: print one worker.json record.
status_record() {
  jq -n --arg host "$1" --arg instance "$2" --arg at "$3" --argjson caps "$4" \
    '{proto: 1, host: $host, instance: $instance, heartbeat_at: $at, draining: false, caps: $caps}'
}

# status_show <dir>: one line per host record, sorted by host.
status_show() {
  local -a files=("$1"/*.json)
  [[ -e ${files[0]} ]] || return 0
  printf '%-10s %-10s %-7s %-7s %5s %8s %-20s %s\n' HOST INSTANCE OS ARCH CPUS MEM_MB HEARTBEAT CLI
  jq -r '[.host, .instance, .caps.os, .caps.arch, (.caps.cpus | tostring), (.caps.mem_mb | tostring), .heartbeat_at,
          ([.caps.cli | to_entries[] | select(.value == "ok") | .key] | join(",") | if . == "" then "-" else . end)] | @tsv' \
    "${files[@]}" | sort | while IFS=$'\t' read -r host instance os arch cpus mem heartbeat cli; do
    printf '%-10s %-10s %-7s %-7s %5s %8s %-20s %s\n' "$host" "$instance" "$os" "$arch" "$cpus" "$mem" "$heartbeat" "$cli"
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case ${1:-} in
    show) status_show "${2:?usage: status.sh show <dir>}" ;;
    *) echo "usage: status.sh show <dir>" >&2; exit 2 ;;
  esac
fi
