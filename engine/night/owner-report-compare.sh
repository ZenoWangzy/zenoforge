#!/usr/bin/env bash

# Send window, station facts, daily snapshots and comparison glue for the owner report.
# The logic is in owner-report-compare.py beside this file; both are found from this
# file's own path, never from MAC_AUTOPILOT_ROOT (on a deployed host that is the
# product checkout and has no engine/lib.sh).

OWNER_REPORT_COMPARE_PY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/owner-report-compare.py"
# The report goes out from 09:00 Beijing (01:00 UTC) and may still go out up to this many seconds later
# (a timer that fired late or after a reboot); after that the day is skipped, never sent in the evening.
OWNER_REPORT_SEND_FROM_UTC_SECONDS=3600
OWNER_REPORT_SEND_WINDOW_SECONDS=21600

owner_report_in_send_window() { # <epoch>
  local at=$(( $1 % 86400 ))
  (( at >= OWNER_REPORT_SEND_FROM_UTC_SECONDS && at < OWNER_REPORT_SEND_FROM_UTC_SECONDS + OWNER_REPORT_SEND_WINDOW_SECONDS ))
}

# One file per Beijing day, beside the mail ledger: a directory no run recreates.
owner_report_snapshot_dir() { # <home>
  printf '%s\n' "${ZF_OWNER_REPORT_SNAPSHOT_DIR:-$1/night/owner-report-snapshots}"
}

owner_report_anomaly_owners_file() {
  printf '%s\n' "${ZF_ANOMALY_OWNERS_FILE:-$HOME/.zenoforge/state/work/anomaly-owners.json}"
}

owner_report_station_facts() { # <home> <now> -> JSON rows or null
  python3 "$OWNER_REPORT_COMPARE_PY" station "$(maintainer_health_mail_runtime_dir "$1")" "$2"
}

owner_report_compare() { # <facts> <home> <now> <repo_root> -> {lines,station_lines,causes}
  python3 "$OWNER_REPORT_COMPARE_PY" compare "$(owner_report_snapshot_dir "$2")" "$3" "$4" "$(owner_report_anomaly_owners_file)" <<< "$1"
}

owner_report_snapshot_write() { # <facts> <home> <now>
  python3 "$OWNER_REPORT_COMPARE_PY" write "$(owner_report_snapshot_dir "$2")" "$3" <<< "$1"
}

# owner_report_backfill <home> <ledger> <anchor> <days> <repo_root>
# Stores the snapshot of each of the <days> days before <anchor> (same time of day) from the records
# that can be re-read for a past day. Existing days are kept. Prints one line per day.
owner_report_backfill() {
  local home="$1" ledger="$2" anchor="$3" days="$4" repo_root="$5" k at facts
  for (( k = 1; k <= days; k++ )); do
    at=$(( anchor - k * 86400 ))
    facts="$(maintainer_health_mail_daily_facts "$home" "$ledger" "$at" "$repo_root")" || { printf '%s not rebuilt\n' "$(TZ=Asia/Shanghai date -d "@$at" +%F)"; continue; }
    printf '%s %s\n' "$(TZ=Asia/Shanghai date -d "@$at" +%F)" \
      "$(python3 "$OWNER_REPORT_COMPARE_PY" backfill "$(owner_report_snapshot_dir "$home")" "$at" "$home" "$(maintainer_health_mail_runtime_dir "$home")" <<< "$facts")"
  done
}

# Repository root for the rollback and landed-change reads: ZF_REPO_DIR, else the checkout this file lives in.
owner_report_repo_root() {
  printf '%s\n' "${ZF_REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
}

# owner_report_material <home> <ledger> <now>: the material changes of today's report as one JSON line, for the cause worker.
owner_report_material() {
  local facts
  facts="$(maintainer_health_mail_daily_facts "$1" "$2" "$3" "$(owner_report_repo_root)")" || return 1
  jq -c '.compare.material // []' <<< "$facts"
}

# owner_report_backfill_cli <home> <ledger> <days> [anchor]: anchor defaults to the latest 01:00 UTC slot start.
owner_report_backfill_cli() {
  local now anchor="${4:-}" days="$3"
  now="$(date +%s)"
  [[ -n "$anchor" ]] || anchor=$(( now / 86400 * 86400 + OWNER_REPORT_SEND_FROM_UTC_SECONDS ))
  [[ "$days" =~ ^[0-9]+$ && "$anchor" =~ ^[0-9]+$ ]] || { printf 'usage: backfill-snapshots [days] [anchor-epoch]\n' >&2; return 2; }
  (( anchor <= now )) || anchor=$(( anchor - 86400 ))
  owner_report_backfill "$1" "$2" "$anchor" "$days" "$(owner_report_repo_root)"
}
