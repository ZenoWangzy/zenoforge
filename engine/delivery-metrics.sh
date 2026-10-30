#!/usr/bin/env bash
# Observation only. Call after atomic request/receipt persistence, never instead of it.
# The existing sink is at-least-once; readers deduplicate stable event_id values.

delivery_metrics_writer_id() {
  local boot ticks pid="${1:-$$}"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  boot="$(cat /proc/sys/kernel/random/boot_id)" || return 1
  ticks="$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $20}')" || return 1
  [[ "$boot" =~ ^[0-9a-f-]{36}$ && "$ticks" =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s:%s\n' "$boot" "$pid" "$ticks"
}

delivery_metrics_record() (
  # Library initialization and telemetry errors must not alter the delivery shell.
  local kind="$1" file="$2" row
  case "$kind" in land-enqueued|source-landed|land-terminal) ;; *) return 2 ;; esac
  if ! declare -F efficiency_metrics_append_rows >/dev/null; then
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh" 2>/dev/null || return 1
  fi
  row="$(jq -ce --arg kind "$kind" '
    def id: if type == "string" and test("^[a-zA-Z0-9_.:-]{1,160}$") then . else null end;
    def sha: if type == "string" and test("^[0-9a-f]{40}$") then . else null end;
    def num: if type == "number" and . >= 0 then . else null end;
    . as $r |
    select(.ticket | type == "string" and test("^[0-9]{20}$")) |
    (if $kind == "land-enqueued" then .enqueued_epoch else .finished_epoch end) as $at |
    select($at | type == "number" and . >= 0) |
    (if .direct_landing == true then
       ([.ticket,"direct",(.lander_pid|tostring),(.lander_start_ticks|tostring)]|join(":"))
     else (.metrics_attempt_id // null | id) end) as $attempt |
    {schema_version:1,record_type:"event",event_type:$kind,
     ts:($at|todateiso8601),ticket:.ticket,owner:(.owner|id),
     owned_issues:((.owned_issues // "") | tostring | [scan("[0-9]+") | tonumber]),
     base:((.base // .base_sha)|sha),head:((.head // .head_sha)|sha),
     source_sha:(.landed_sha|sha),batch_head:(.batch_head|sha),
     entry_kind:(if .direct_landing == true then "direct" else "queued" end),
     state:(.state|id),attempt_id:$attempt,
     attempt_scope:(if $attempt != null then "land-worker" else null end),
     outcome:(.outcome|id),status:(.status|num),failure_stage:(.failure_stage|id),
     enqueued_epoch:(.enqueued_epoch|num),started_epoch:(.started_epoch|num),
     queue_wait_seconds:(.queue_wait_seconds|num),
     enqueue_to_main_seconds:(.enqueue_to_main_seconds|num),
     suite_elapsed_seconds:(.suite_elapsed_seconds|num)} |
    # Enqueue is one durable ticket; land state publications correlate the captured
    # worker identity when available. No attempt sequence is inferred from old files.
    .event_id=([.event_type,.ticket,
      (if $kind == "land-enqueued" then ($r.enqueued_epoch|tostring)
       else [$attempt,.state,.source_sha]|tojson end)]|tojson)
    ' "$file")" || return 1
  efficiency_metrics_append_rows "$row"
)

delivery_metrics_observe() {
  timeout --signal=TERM --kill-after=1s 2s bash "${BASH_SOURCE[0]}" "$@" \
    || echo 'delivery metrics: append failed after durable persistence' >&2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  delivery_metrics_record "$@"
fi
