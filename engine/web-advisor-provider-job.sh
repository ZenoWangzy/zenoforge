#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -r "$SCRIPT_DIR/runtime-reload.sh" ]]; then
  source "$SCRIPT_DIR/runtime-reload.sh"
  agent_reload_init "$0" "$@"
  agent_reload_restore
fi
source "$SCRIPT_DIR/config.sh"
job_id="${1:?job id required}"
ask_script="${2:?advisor script required}"
topic="${3:-}"
job_dir="${WEB_ADVISOR_PROVIDER_JOB_DIR:?}/$job_id"
lease_script="$ZF_CDP_BROWSER_LEASE_SCRIPT"
export ZF_CDP_ADVISOR=1
state_file="$job_dir/state.json"
done_file="$job_dir/done"
answer_err="$job_dir/answer.err"
poll_seconds="${WEB_ADVISOR_PROVIDER_POLL_INTERVAL_SECONDS:-$ZF_WEB_ADVISOR_PROVIDER_POLL_INTERVAL_SECONDS}"

[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "web-advisor-provider-job: invalid poll interval" >&2; exit 64; }
[ -d "$job_dir" ] || { echo "web-advisor-provider-job: missing job directory" >&2; exit 66; }

write_done() {
  local status="$1" tmp="$done_file.$$.tmp"
  printf '%s\n' "$status" > "$tmp"
  mv "$tmp" "$done_file"
}

phase() {
  [ -f "$state_file" ] || { echo new; return; }
  jq -er '.phase | strings' "$state_file"
}

sleep_to_next_poll() {
  local now remaining
  now="$(date +%s)"
  remaining=$((deadline - now))
  if [ "$remaining" -gt 0 ]; then
    sleep "$((remaining < poll_seconds ? remaining : poll_seconds))"
  fi
}

deadline="$(cat "$job_dir/deadline" 2>/dev/null || true)"
if ! [[ "$deadline" =~ ^[0-9]+$ ]]; then
  echo "web-advisor-provider-job: invalid job deadline" >> "$answer_err"
  write_done 64
  exit 64
fi

while :; do
  if declare -F agent_reload_checkpoint >/dev/null; then agent_reload_checkpoint; fi
  current_phase="$(phase)"
  case "$current_phase" in
    answered)
      action=finalize
      ;;
    new)
      action=submit
      ;;
    submitting|submitted|polling)
      action=poll
      ;;
    *)
      echo "web-advisor-provider-job: unknown phase $current_phase" >> "$answer_err"
      write_done 1
      exit 1
      ;;
  esac

  if [ "$action" != finalize ] && [ "$(date +%s)" -ge "$deadline" ]; then
    echo "web-advisor-provider-job: answer deadline exceeded" >> "$answer_err"
    write_done 124
    exit 124
  fi

  out_file="$(mktemp "$job_dir/step-out.XXXXXX")"
  err_file="$(mktemp "$job_dir/step-err.XXXXXX")"
  set +e
  if [ "$action" = submit ]; then
    ask_args=(--job-submit "$job_dir" "$job_dir/question.txt" --topic "$topic" --reuse-existing-tab)
    case "$(cat "$job_dir/mode" 2>/dev/null || true)" in
      single-request-ndjson) ask_args+=(--single-request-ndjson) ;;
    esac
    "$lease_script" --nonblocking node "$ask_script" "${ask_args[@]}" > "$out_file" 2> "$err_file"
    status=$?
  elif [ "$action" = poll ]; then
    "$lease_script" --nonblocking node "$ask_script" --job-poll "$job_dir" > "$out_file" 2> "$err_file"
    status=$?
  else
    "$lease_script" --nonblocking node "$ask_script" --job-finalize "$job_dir" > "$out_file" 2> "$err_file"
    status=$?
  fi
  set -e

  if [ "$status" -eq 75 ] || [ "$status" -eq 10 ]; then
    rm -f "$out_file" "$err_file"
    sleep_to_next_poll
    continue
  fi
  cat "$err_file" >> "$answer_err"
  if [ "$status" -ne 0 ]; then
    # A send can race the rendered assistant turn. Once state.json records the
    # target, poll that exact target; never submit the potentially-sent prompt again.
    if [ "$action" = submit ] && grep -qF 'ADVISOR_SEND_NOT_CONFIRMED' "$err_file" \
      && [ "$(phase)" = submitting ] \
      && jq -e '.targetId | strings | length > 0' "$state_file" >/dev/null 2>&1; then
      rm -f "$out_file" "$err_file"
      echo "web-advisor-provider-job: send state uncertain; polling recorded target without resubmitting" >&2
      sleep_to_next_poll
      continue
    fi
    cat "$out_file" >> "$answer_err"
    rm -f "$out_file" "$err_file"
    write_done "$status"
    exit "$status"
  fi
  rm -f "$out_file" "$err_file"

  current_phase="$(phase)"
  if [ "$current_phase" = answered ]; then
    cp "$job_dir/answer.txt" "$job_dir/answer.out"
    write_done 0
    exit 0
  fi
  if [ "$current_phase" = submitting ] || [ "$current_phase" = new ]; then
    echo "web-advisor-provider-job: successful step did not persist submitted state" >> "$answer_err"
    write_done 1
    exit 1
  fi
  sleep_to_next_poll
done
