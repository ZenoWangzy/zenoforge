#!/usr/bin/env bash
# web-advisor-provider advisor provider -- the advisor role's default transport: the
# a logged-in browser session driven over CDP. Its script, endpoint,
# lease executable, topic, job directory, and unit prefix come from config.
# Source-only module; engine/lib.sh loads it
# through its provider seam -- file present -> sourced, file absent -> the
# advisor role simply has no web rung. Keep this file deletable as one unit:
# a distribution that must not carry web-session automation drops this file and the
# skill directory it points at, with no other pipeline change.
#
# This module contains job-state helpers, CDP health checks, fault
# classification, dispatch gate, config, question/answer codecs, sync and
# async call machinery, stale-job reconciliation, and topic policy.

# web_advisor_provider_job_ids -- issue ids whose state still carries an advisor
# job marker. This is deliberately the raw scan; callers that dispatch or
# reconcile jobs apply the liveness rules below.
web_advisor_provider_job_ids() {
  local f
  [ -d "$STATE_DIR" ] || return 0
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -e '(.web_advisor_provider_job_id? // "") | (type == "string" and length > 0)' "$f" >/dev/null 2>&1 || continue
    basename "$f" .json
  done | sort -n
}

# web_advisor_provider_job_candidates [needs-advisor-ids] -- issue ids with a
# dispatched advisor job that is still eligible for single-ticket polling.
# Finished, expired, or no-longer-queued jobs are not pending work and must not
# suppress batch dispatch. The optional snapshot avoids one GitHub query per
# state file when issue-pipeline.sh already fetched the queue; a direct caller
# fetches the same open needs-advisor pool itself and fails closed on read error.
web_advisor_provider_job_candidates() {
  local needs_advisor_ids="" f n job_id started_at job_dir now
  if [ "$#" -eq 0 ]; then
    if ! needs_advisor_ids="$(gh issue list --repo "$REPO" --limit 1000 --label needs-advisor --state open --json number -q '.[].number' 2>/dev/null)"; then
      return 0
    fi
  else
    needs_advisor_ids="$1"
  fi
  now="$(date +%s)"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$(state_file "$n")"
    [ -f "$f" ] || continue
    job_id="$(jq -r '.web_advisor_provider_job_id // empty' "$f" 2>/dev/null || true)"
    [ -n "$job_id" ] || continue
    if ! grep -qx -- "$n" <<< "$needs_advisor_ids"; then
      continue
    fi
    started_at="$(jq -r '.web_advisor_provider_job_started_at // empty' "$f" 2>/dev/null || true)"
    case "$started_at" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$((now - started_at))" -gt "$WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS" ]; then
      continue
    fi
    job_dir="$WEB_ADVISOR_PROVIDER_JOB_DIR/$job_id"
    [ -f "$job_dir/done" ] && continue
    printf '%s\n' "$n"
  done < <(web_advisor_provider_job_ids)
}

# web_advisor_provider_clear_job_state <issue> -- remove the local async-job
# ownership marker before its ticket changes consumer or reaches a terminal
# outcome. A finished job may remain archived for evidence; its id must not
# remain in ticket state where it can suppress a later batch.
web_advisor_provider_clear_job_state() {
  state_merge "$1" 'del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)'
}

# --- CDP health checks, wired into lib.sh's env-fault machinery -------------
# lib.sh's env_fault_probe()/env_fault_repair() dispatch the env:web-advisor-provider-
# advisor:* signature families here; the arm bodies moved unchanged.

# Run the browser health operation under the one physical-browser lease.
# Inside an existing lease, reuse it; otherwise a busy lease returns 75 so
# quarantine reconcile can defer without consuming repair_tried.
web_advisor_provider_cdp_command() {
  if [ "${ZF_WEB_SESSION_LEASE_HELD:-0}" = "1" ]; then
    node "$WEB_ADVISOR_PROVIDER_SCRIPT" "$1"
  else
    ZF_CDP_ADVISOR=1 "$ZF_CDP_BROWSER_LEASE_SCRIPT" --nonblocking node "$WEB_ADVISOR_PROVIDER_SCRIPT" "$1"
  fi
}
# web_advisor_provider_env_fault_probe <signature> -> 0 fault gone, 1 still
# present, 2 no probe known -- lib.sh env_fault_probe()'s web-advisor-provider arm.
# 10=still wedged; no tab or wrong account means this signature is gone.
# A lost context (a second CDP driver without the lease)
# clears as soon as the tab answers; exponential canaries kept the
# advisor quarantined 5.5h after the other driver had stopped.
web_advisor_provider_env_fault_probe() {
  local tab_status=0
  case "$1" in
    env:web-advisor-provider:tab-unresponsive|env:web-advisor-provider:browser-context-lost)
      web_advisor_provider_cdp_command --probe-account-tab || tab_status=$?
      case "$tab_status" in
        0|11|12) return 0 ;;
        10) return 1 ;;
        *) return 2 ;;
      esac
      ;;
    *) return 2 ;;
  esac
}

# web_advisor_provider_env_fault_repair <signature> -> 0 repaired, 1 no repair
# allowlisted, 2 repair failed, 75 CDP lease busy -- lib.sh
# env_fault_repair()'s web-advisor-provider arm. Only tab-unresponsive has a machine
# repair derivable without a human's choice.
web_advisor_provider_env_fault_repair() {
  local tab_status=0
  case "$1" in
    env:web-advisor-provider:tab-unresponsive)
      web_advisor_provider_cdp_command --recover-account-tab || tab_status=$?
      [ "$tab_status" -eq 0 ] && return 0
      [ "$tab_status" -eq 75 ] && return 75
      return 2
      ;;
    *) return 1 ;;
  esac
}

# web_advisor_provider_fault_signature <detail> -> one stable advisor-only
# signature. Keep the categories coarse: their job is to distinguish a
# recurring failure family in HEALTH, not to preserve every
# volatile browser/CDP error string.
web_advisor_provider_fault_pattern_matches() {
  local category="$1" normalized="$2" config_file pattern
  if declare -F zf_config_file >/dev/null 2>&1; then
    config_file="$(zf_config_file providers/web-advisor-provider-fault-patterns.json 2>/dev/null || true)"
  else
    config_file="${ZF_CONFIG_ROOT:-${ZF_REPO_DIR:-${REPO_DIR:-}}/.zenoforge}/providers/web-advisor-provider-fault-patterns.json"
  fi
  [[ -n "$config_file" && -r "$config_file" ]] || return 1
  while IFS= read -r pattern; do
    [[ -n "$pattern" && "$normalized" == *"$pattern"* ]] && return 0
  done < <(jq -r --arg category "$category" '.[$category][]? | select(type == "string")' "$config_file" 2>/dev/null)
  return 1
}

web_advisor_provider_fault_signature() {
  local detail="${1:-}" normalized
  normalized="${detail,,}"
  case "$normalized" in
    *'advisor_tab_unresponsive'*|*'tab-unresponsive'*|*'tab unresponsive'*)
      echo env:web-advisor-provider:tab-unresponsive ;;
    *'cdp unreachable'*)
      echo env:web-advisor-provider:cdp-unreachable ;;
    *'still had no result after '*)
      echo env:web-advisor-provider:job-timeout ;;
    *'streaming len=0'*)
      echo env:web-advisor-provider:streaming-stall ;;
    *)
      if web_advisor_provider_fault_pattern_matches model_slug_mismatch "$normalized" ||
         [[ "$normalized" == *'model slug'* || "$normalized" == *'model-slug'* ]]; then
        echo env:web-advisor-provider:model-slug-mismatch
      elif web_advisor_provider_fault_pattern_matches picker_not_found "$normalized" ||
           [[ "$normalized" == *'picker'* ]]; then
        echo env:web-advisor-provider:picker-not-found
      elif web_advisor_provider_fault_pattern_matches browser_context_lost "$normalized" ||
           [[ "$normalized" == *'browser context'* ]]; then
        echo env:web-advisor-provider:browser-context-lost
      else
        echo env:web-advisor-provider:call-failed
      fi ;;
  esac
}

# web_advisor_provider_update_open_quarantine <signature> <detail> -- a
# quarantine is keyed by scope, while advisor faults now have finer
# signatures. If another advisor failure lands before the scope lifts, keep
# its existing quarantine attached to the newest failure family; otherwise a
# later canary could mistake a different-category fault for silence.
web_advisor_provider_update_open_quarantine() {
  agent_pipeline_write_guard web_advisor_provider_update_open_quarantine "$AGENT_HOME" "$QUARANTINE_DIR" || return 1
  local signature="$1" detail="$2" f detail_file
  [ "$DRY_RUN" = "1" ] && return 0
  f="$(quarantine_file advisor)"
  [ -f "$f" ] || return 0
  [ "$(jq -r '.scope // empty' "$f" 2>/dev/null)" = "advisor" ] || return 0
  detail_file="$(jq_arg_file "$detail")"
  jq --arg sig "$signature" --rawfile d "$detail_file" \
    '.signature = $sig | .detail = $d' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  rm -f "$detail_file"
}

# web_advisor_provider_migrate_legacy_faults -- re-bucket the old bare advisor
# ledger exactly once before recording the first classified fault. Keeping
# the old rows active would make generic reconciliation recreate the old
# catch-all quarantine; moving them to an archive preserves evidence without
# letting it participate as a shared signature.
web_advisor_provider_migrate_legacy_faults() {
  agent_pipeline_write_guard web_advisor_provider_migrate_legacy_faults "$AGENT_HOME" "$ENV_FAULT_DIR" || return 1
  local legacy lock_file lock_fd at stage n old_signature detail signature archive
  [ "$DRY_RUN" = "1" ] && return 0
  legacy="$ENV_FAULT_DIR/$(env_fault_key env:web-advisor-provider).log"
  [ -f "$legacy" ] || return 0
  mkdir -p "$ENV_FAULT_DIR"
  lock_file="$legacy.migrate.lock"
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"
  if [ -f "$legacy" ]; then
    while IFS=$'\t' read -r at stage n old_signature detail; do
      [ "$old_signature" = "env:web-advisor-provider" ] || continue
      signature="$(web_advisor_provider_fault_signature "$detail")"
      record_env_fault "$signature" "$stage" "$n" "$detail" "" "$at"
    done < "$legacy"
    archive="$legacy.legacy.$(date +%s%N)"
    mv "$legacy" "$archive"
  fi
  unlock_fd "$lock_fd"
}

# record_web_advisor_provider_fault <issue> <detail> [now] -- advisor-only adapter
# around the shared ledger. Other legs keep record_env_fault's existing
# signature semantics unchanged.
record_web_advisor_provider_fault() {
  local n="$1" detail="$2" now="${3:-$(date +%s)}" signature
  web_advisor_provider_migrate_legacy_faults
  signature="$(web_advisor_provider_fault_signature "$detail")"
  record_env_fault "$signature" advisor "$n" "$detail" "" "$now"
  web_advisor_provider_update_open_quarantine "$signature" "$detail"
}

# web_advisor_provider_dispatch_allowed [now] -- async advisor jobs wait for the
# shared browser lease; the tick must not require it to be free at dispatch.
web_advisor_provider_dispatch_allowed() {
  local now="${1:-$(date +%s)}"
  if model_config_fault_blocked advisor "$(model_policy identity advisor)"; then
    STAGE_DISPATCH_BLOCKING_SCOPES=advisor
    return 1
  fi
  stage_dispatch_allowed advisor "[]" "$now"
}

# WEB_ADVISOR_PROVIDER_SCRIPT -- env-first, same convention as other
# AGENT_MODEL*/AGENT_*_SCRIPT variable in lib.sh. Defaults to the real
# skill script; a test points this at a throwaway fixture .cjs instead of
# faking `node` itself, because advisor_footprint_risky() already depends
# on a REAL node process running risk-class.mjs elsewhere in this same
# ladder walk (run-advisor.test.sh's own header comment) -- shadowing node
# globally would break that unrelated dependency.
WEB_ADVISOR_PROVIDER_SCRIPT="${WEB_ADVISOR_PROVIDER_SCRIPT:-$ZF_WEB_ADVISOR_PROVIDER_SCRIPT}"
# Advisor requests use a configured topic. Ticket-specific callers append their ticket id.
WEB_ADVISOR_PROVIDER_TOPIC="${WEB_ADVISOR_PROVIDER_TOPIC:-$ZF_WEB_ADVISOR_PROVIDER_TOPIC}"
WEB_ADVISOR_PROVIDER_TIMEOUT_SECONDS="${WEB_ADVISOR_PROVIDER_TIMEOUT_SECONDS:-$ZF_WEB_ADVISOR_PROVIDER_CALL_TIMEOUT_SECONDS}"

# web_advisor_provider_usable -> exit 0 when the web advisor is worth attempting
# at all this run. Deliberately cheap (a 2s-timeout local curl, no CDP
# round-trip through a real page) so an unavailable endpoint costs
# this ladder walk a couple of seconds, not a chunk of its own bounded
# LADDER_SECONDS budget discovering that the hard way -- same reasoning as
# gating a whole sub-ladder before the loop, not inside it. This is availability only (is the CDP endpoint even up); it
# says nothing about login state, account match, or DOM shape -- those can
# still fail inside run_web_advisor_provider_json() itself, and that failure
# advances the ladder exactly like any other rung's failure does, no
# special case needed here.
WEB_ADVISOR_PROVIDER_CDP_PORT="$ZF_WEB_ADVISOR_PROVIDER_CDP_PORT"
web_advisor_provider_usable() {
  [ -f "$WEB_ADVISOR_PROVIDER_SCRIPT" ] || { echo "advisor script missing: $WEB_ADVISOR_PROVIDER_SCRIPT" >&2; return 1; }
  curl -s --max-time 2 "http://127.0.0.1:$WEB_ADVISOR_PROVIDER_CDP_PORT/json/version" >/dev/null 2>&1 || {
    echo "advisor CDP port unreachable: $WEB_ADVISOR_PROVIDER_CDP_PORT" >&2; return 1
  }
}

# run_web_advisor_provider_json <schema_file> <prompt_file> -- normalizes to the
# SAME {is_error, structured_output} shape run_codex_json() (lib.sh) already
# produces, so run-advisor.sh applies the same result checks:
# model_call_failure_kind() classifies it,
# RESULT="$(echo "$OUTPUT" | jq -c '.structured_output // {}')" extracts it,
# nothing downstream of the dispatch case statement needed a special case.
#
# Unlike Codex's --output-schema, the web
# The browser UI enforces nothing: there is no schema parameter to pass, only a
# strong instruction prepended to the question and a best-effort extraction
# of whatever comes back. That is a real, permanent gap versus the other
# two rungs, deliberately not papered over with a fragile brace-matching
# fallback -- a reply that does not parse fails CLOSED (is_error: true,
# subtype web_advisor_provider_malformed); the persisted policy determines its
# next state without changing model identity.
#
# WEB_ADVISOR_PROVIDER_TIMEOUT_SECONDS (env; the caller passes the ladder's own
# remaining budget, same convention as run_codex_json()'s CODEX_JSON_
# TIMEOUT_SECONDS) bounds the whole call: the provider script has internal
# answer-wait and page-load deadlines, but neither
# protects against a hung CDP connection that never resolves at all, so this
# still needs its own outer `timeout` -- a kill here returns 124, which
# model_call_failure_kind() already reads as "transient" and the ladder
# advances past exactly like it would past a real one.
#
# The default call timeout is configured alongside the other provider
# settings. It bounds a stalled request while leaving room for slow endpoint
# startup and answer generation.
# web_advisor_provider_build_question <schema_file> <prompt_file> -- the question
# text sent to the web conversation, shared by the synchronous caller below
# and the async dispatcher further down so the two never drift.
#
# The request builder preserves the bundled skill's default context gathering.
# Responses without current workspace evidence follow the same failure policy as
# any other unusable advisor answer.
web_advisor_provider_build_question() {
  local schema_file="$1" prompt_file="$2"
  echo 'You are answering as this pipeline'"'"'s automated advisor. Reply with EXACTLY one fenced code block, language "json", containing a single JSON object that validates against the JSON Schema given below -- no text before or after that one code block, no other commentary. Every key below MUST be present even when your verdict does not use it (empty string "" or empty array [] for an unused one).'
  echo
  echo 'JSON Schema:'
  echo '```json'
  cat "$schema_file"
  echo '```'
  echo
  echo 'Ticket context and instructions follow:'
  echo
  cat "$prompt_file"
}

# The batch transport name is retained for persisted jobs, but new runs make
# one web message and require one structured JSON envelope for the frozen
# cohort. Legacy jobs remain readable by run-advisor-batch.sh's NDJSON parser.
web_advisor_provider_build_ndjson_question() {
  local prompt_file="$1"
  echo 'You are answering as this pipeline'"'"'s automated advisor. Reply with exactly one valid JSON object matching the batch prompt'"'"'s advisor_batch_result envelope. Include the exact requested_issues manifest and one complete ruling for every issue. Do not use Markdown fences, NDJSON, or prose.'
  echo
  cat "$prompt_file"
}

# Measures the exact UTF-8 request the provider script receives, including the NDJSON
# transport instruction that batch admission must not forget.
web_advisor_provider_ndjson_request_bytes() {
  local prompt_file="$1" question_file bytes
  question_file="$(mktemp)" || return 1
  if ! web_advisor_provider_build_ndjson_question "$prompt_file" > "$question_file"; then
    rm -f "$question_file"
    return 1
  fi
  bytes="$(wc -c < "$question_file" | tr -d '[:space:]')"
  rm -f "$question_file"
  printf '%s\n' "$bytes"
}

# web_advisor_provider_model_used <provider stderr> -> verified pre-send model setting.
# The endpoint does not expose per-reply model identity; accept the old marker only
# for jobs created before that UI change.
web_advisor_provider_model_used() {
  sed -n 's/^VERIFIED_MODEL: //p' "$1" 2>/dev/null | tail -n 1
}

# web_advisor_provider_model_fallback <provider stderr> -> fallback reason.
web_advisor_provider_model_fallback() {
  sed -n 's/^MODEL_FALLBACK: //p' "$1" 2>/dev/null | tail -n 1
}

# web_advisor_provider_normalize_batch_json < raw reply -> stdout
# The browser UI occasionally inserts a citation token into JSON string content,
# and may emit a bare quoted control attribute inside a string. Repair only
# these two observed serialization artifacts; the original answer file stays
# untouched and callers must still validate the full batch envelope/manifest.
web_advisor_provider_normalize_batch_json() {
  node -e '
    let text = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => { text += chunk; });
    process.stdin.on("end", () => {
      text = text.replace(/:web-content-reference\{index=\"\d+\"\}/g, "");
      text = text.replaceAll("service_tier=\"fast\"", "service_tier=\\\"fast\\\"");
      process.stdout.write(text);
    });
  '
}

# web_advisor_provider_parse_answer <raw answer text> [verified pre-send picker setting] -> the
# SAME {is_error, structured_output} envelope run_codex_json() produces, on
# stdout; returns
# 0 on a parseable answer, 1 on one that isn't (fails CLOSED, is_error:
# true, subtype web_advisor_provider_malformed -- never invents a verdict).
# Shared by the synchronous caller and the async poller so extraction logic
# exists in exactly one place.
web_advisor_provider_parse_answer() {
  local answer="$1" model_used="${2:-}" candidate parsed=""
  # Try the whole trimmed answer as JSON first (a model that ignored the
  # "one fenced block" instruction but still replied with bare JSON), then
  # the content of the first ```json fence, then a bare "JSON" label line
  # and the object, which neither of the first two candidates catches -- the
  # the object, which neither of the first two candidates catches -- the
  # widest, LAST-resort strategy: from the first `{` to the last `}` in the
  # whole text. This one candidate is genuinely fragile (prose mentioning
  # `{like this}` around the real object would break it), which is exactly
  # why it is tried last, not first, and still goes through the SAME
  # verdict-shape check every other candidate does before being accepted.
  local brace_span="" after_last_brace
  case "$answer" in
    *'{'*'}'*)
      brace_span="{${answer#*\{}"
      after_last_brace="${brace_span##*\}}"
      brace_span="${brace_span%"$after_last_brace"}"
      ;;
  esac
  for candidate in \
    "$(jq -c . <<< "$answer" 2>/dev/null)" \
    "$(awk '/```json/{f=1;next} /```/{if(f)exit} f' <<< "$answer" | jq -c . 2>/dev/null)" \
    "$(jq -c . <<< "$brace_span" 2>/dev/null)"
  do
    if [ -n "$candidate" ] && jq -e 'type == "object" and (.verdict // "") != ""' >/dev/null 2>&1 <<< "$candidate"; then
      parsed="$candidate"
      break
    fi
  done
  if [ -z "$parsed" ]; then
    jq -nc --arg result "$(tail -c 2000 <<< "$answer")" \
      '{is_error: true, subtype: "web_advisor_provider_malformed", result: $result}'
    return 1
  fi
  jq -nc --argjson so "$parsed" --arg model_used "$model_used" \
    '{is_error: false, structured_output: $so, reply_model_identity: "not_exposed_by_ui"} + (if $model_used == "" then {} else {model_used: $model_used} end)'
  return 0
}

run_web_advisor_provider_json() {
  local schema_file="$1" prompt_file="$2"
  local question_file answer_file err_file status=0 answer model_used

  question_file="$(mktemp)"; answer_file="$(mktemp)"; err_file="$(mktemp)"
  web_advisor_provider_build_question "$schema_file" "$prompt_file" > "$question_file"

  # The advisor runs through the configured CDP endpoint under its own lock, and
  # the configured lease executable owns that choice, as for the async job. Taking the agent lease
  # here sent synchronous calls to a different browser endpoint without the expected session.
  ZF_CDP_ADVISOR=1 "$ZF_CDP_BROWSER_LEASE_SCRIPT" --nonblocking \
    timeout "${WEB_ADVISOR_PROVIDER_TIMEOUT_SECONDS}s" \
    node "$WEB_ADVISOR_PROVIDER_SCRIPT" "$question_file" --topic "$WEB_ADVISOR_PROVIDER_TOPIC" \
    > "$answer_file" 2> "$err_file" || status=$?
  rm -f "$question_file"

  if [ "$status" -eq 75 ]; then
    rm -f "$answer_file" "$err_file"
    jq -nc '{is_error: true, subtype: "web_advisor_provider_busy", result: "CDP browser lease busy"}'
    return 75
  fi
  if [ "$status" -ne 0 ]; then
    answer="$(tail -c 2000 "$err_file" 2>/dev/null)"
    rm -f "$answer_file" "$err_file"
    jq -nc --arg result "$answer" --arg status "$status" \
      '{is_error: true, subtype: "web_advisor_provider_call_failed", result: $result, web_advisor_provider_exit_status: ($status|tonumber)}'
    return "$status"
  fi
  model_used="$(web_advisor_provider_model_used "$err_file")"
  rm -f "$err_file"
  answer="$(cat "$answer_file" 2>/dev/null)"
  rm -f "$answer_file"
  web_advisor_provider_parse_answer "$answer" "$model_used"
}

# --- async dispatch/poll -----------------------------------------------------
# Slow browser requests run in detached systemd units so the caller can return
# promptly. The wrapper stores request phase in the configured job directory
# and resumes polling if its unit stops before writing `done`.
WEB_ADVISOR_PROVIDER_JOB_DIR="$ZF_WEB_ADVISOR_PROVIDER_JOB_DIR"
# The wrapper and polling side share this deadline, including after a restart.
WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS="${WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS:-$ZF_WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS}"
WEB_ADVISOR_PROVIDER_POLL_INTERVAL_SECONDS="${WEB_ADVISOR_PROVIDER_POLL_INTERVAL_SECONDS:-$ZF_WEB_ADVISOR_PROVIDER_POLL_INTERVAL_SECONDS}"

# web_advisor_provider_dispatch_async <job_id> <schema_file> <prompt_file> --
# fires the job and returns immediately; does not report success/failure of
# the WEB CALL itself (that is what polling later discovers), only of the
# dispatch mechanism (systemd-run either created the unit or it didn't).
#
# -E HOME/PATH and the provider settings keep the detached process on the
# same user configuration and executable paths as its caller.
web_advisor_provider_start_job_unit() {
  local job_id="$1" node_timeout_seconds answer_timeout_ms
  local -a ask_env=()
  # Preserve the old 5-minute contention allowance and two-minute completion
  # reserve inside the unchanged detached job deadline.
  node_timeout_seconds=$((WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS - 360))
  (( node_timeout_seconds > 0 )) || node_timeout_seconds=1
  answer_timeout_ms=$(((node_timeout_seconds - 60) * 1000))
  (( answer_timeout_ms > 0 )) || answer_timeout_ms=1000
  if [[ -n "${ADVISOR_BATCH_CONTEXT_CHUNK_BYTES:-}" ]]; then
    ask_env=(-E "ADVISOR_BATCH_CONTEXT_CHUNK_BYTES=$ADVISOR_BATCH_CONTEXT_CHUNK_BYTES")
  fi
  guarded_write systemd-run --user --unit "${ZF_WEB_ADVISOR_PROVIDER_UNIT_PREFIX}-web-advisor-provider-$job_id" --collect \
    -E HOME -E PATH -E "AGENT_HOME=$AGENT_HOME" \
    -E "WEB_SESSION_LEASE_FILE=$WEB_SESSION_LEASE_FILE" \
    -E "ZF_CDP_BROWSER_LEASE_SCRIPT=$ZF_CDP_BROWSER_LEASE_SCRIPT" \
    -E "WEB_ADVISOR_PROVIDER_JOB_DIR=$WEB_ADVISOR_PROVIDER_JOB_DIR" \
    -E "WEB_ADVISOR_PROVIDER_POLL_INTERVAL_SECONDS=$WEB_ADVISOR_PROVIDER_POLL_INTERVAL_SECONDS" \
    -E "WEB_ADVISOR_PROVIDER_SCRIPT=$WEB_ADVISOR_PROVIDER_SCRIPT" \
    -E "ADVISOR_ANSWER_MAX_MS=$answer_timeout_ms" "${ask_env[@]}" \
    -p "RuntimeMaxSec=$WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS" \
    -- bash "${ZF_ENGINE_DIR:-$REPO_DIR/engine}/web-advisor-provider-job.sh" "$job_id" \
    "$WEB_ADVISOR_PROVIDER_SCRIPT" "$WEB_ADVISOR_PROVIDER_TOPIC"
}

web_advisor_provider_resume_job_if_stopped() {
  local job_id="$1" job_dir="$WEB_ADVISOR_PROVIDER_JOB_DIR/$1" unit="${ZF_WEB_ADVISOR_PROVIDER_UNIT_PREFIX}-web-advisor-provider-$1.service" deadline phase
  [ -f "$job_dir/question.txt" ] || return 0
  [ -f "$job_dir/done" ] && return 0
  deadline="$(cat "$job_dir/deadline" 2>/dev/null || true)"
  if systemctl --user is-active --quiet "$unit" >/dev/null 2>&1; then return 0; fi
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 0
  phase="$(jq -r '.phase // empty' "$job_dir/state.json" 2>/dev/null || true)"
  if [ "$phase" != answered ] && [ "$(date +%s)" -ge "$deadline" ]; then
    printf 'web-advisor-provider advisor job %s answer deadline exceeded while its unit was stopped\n' "$job_id" >> "$job_dir/answer.err"
    printf '124\n' > "$job_dir/done.$$.tmp"
    mv "$job_dir/done.$$.tmp" "$job_dir/done"
    return 0
  fi
  web_advisor_provider_start_job_unit "$job_id"
}

web_advisor_provider_dispatch_question_async() {
  local job_id="$1" question_file="$2" mode="${3:-single}"
  local job_dir="$WEB_ADVISOR_PROVIDER_JOB_DIR/$job_id"
  case "$mode" in
    single|single-request-ndjson) ;;
    *) echo "web_advisor_provider_dispatch_question_async: unsupported mode '$mode'" >&2; return 2 ;;
  esac
  mkdir -p "$job_dir"
  rm -f "$job_dir/answer.out" "$job_dir/answer.err" "$job_dir/done" "$job_dir/state.json"
  cp "$question_file" "$job_dir/question.txt"
  printf '%s\n' "$mode" > "$job_dir/mode"
  printf '%s\n' "$(( $(date +%s) + WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS ))" > "$job_dir/deadline"
  web_advisor_provider_start_job_unit "$job_id"
}

web_advisor_provider_dispatch_async() {
  local job_id="$1" schema_file="$2" prompt_file="$3" question_file status=0
  question_file="$(mktemp)"
  web_advisor_provider_build_question "$schema_file" "$prompt_file" > "$question_file"
  web_advisor_provider_dispatch_question_async "$job_id" "$question_file" || status=$?
  rm -f "$question_file"
  return "$status"
}

web_advisor_provider_dispatch_ndjson_async() {
  local job_id="$1" prompt_file="$2" question_file status=0
  question_file="$(mktemp)"
  web_advisor_provider_build_ndjson_question "$prompt_file" > "$question_file"
  # Freeze every currently eligible ticket into one attached prompt and one
  # assistant reply. The provider must send a large question in one request;
  # it must not split the cohort into context turns.
  web_advisor_provider_dispatch_question_async "$job_id" "$question_file" single-request-ndjson || status=$?
  rm -f "$question_file"
  return "$status"
}

# Dry-run still asks the real advisor but leaves no persistent job/state for
# a later tick. It is intentionally synchronous because dry-run's contract
# is one command that prints its complete would-apply result.
run_web_advisor_provider_ndjson() {
  local prompt_file="$1" question_file answer_file err_file status=0
  question_file="$(mktemp)"; answer_file="$(mktemp)"; err_file="$(mktemp)"
  web_advisor_provider_build_ndjson_question "$prompt_file" > "$question_file"
  # Same browser and lock choice as run_web_advisor_provider_json above.
  ZF_CDP_ADVISOR=1 "$ZF_CDP_BROWSER_LEASE_SCRIPT" --nonblocking \
    timeout "${WEB_ADVISOR_PROVIDER_TIMEOUT_SECONDS}s" \
    node "$WEB_ADVISOR_PROVIDER_SCRIPT" "$question_file" --topic "$WEB_ADVISOR_PROVIDER_TOPIC" --single-request-ndjson \
    > "$answer_file" 2> "$err_file" || status=$?
  rm -f "$question_file"
  if [ "$status" -eq 75 ]; then
    rm -f "$answer_file" "$err_file"
    echo "CDP browser lease busy" >&2
    return 75
  fi
  if [ "$status" -ne 0 ]; then
    tail -c 2000 "$err_file" >&2
    rm -f "$answer_file" "$err_file"
    return "$status"
  fi
  cat "$answer_file"
  rm -f "$answer_file" "$err_file"
}

# Raw batch poll keeps the job directory until batch persistence has finished.
# The JSON poller below retains its old consume-on-read behavior for the
# one-ticket path.
web_advisor_provider_poll_ndjson() {
  local job_id="$1" job_dir="$WEB_ADVISOR_PROVIDER_JOB_DIR/$1" node_status err_tail
  if [ ! -f "$job_dir/done" ]; then
    web_advisor_provider_resume_job_if_stopped "$job_id" || true
    return 2
  fi
  node_status="$(cat "$job_dir/done" 2>/dev/null || echo 1)"
  if [ "$node_status" = "75" ]; then
    echo "web-advisor-provider batch job $job_id deferred: CDP browser lease busy" >&2
    rm -f "$job_dir/done"
    web_advisor_provider_resume_job_if_stopped "$job_id" || true
    return 2
  fi
  if [ "$node_status" != "0" ]; then
    err_tail="$(tail -c 2000 "$job_dir/answer.err" 2>/dev/null)"
    if [[ "$err_tail" == *ADVISOR_ANSWER_TIMEOUT* || "$err_tail" == *'answer deadline exceeded'* ]]; then
      local partial=""
      # Only newline-terminated, independently parseable NDJSON records are safe
      # to pass to the existing per-ticket validation and missing-member retry.
      if [ -s "$job_dir/answer.out" ]; then
        partial="$(jq -Rsc 'split("\n")[:-1] | map(fromjson? | select(type == "object" and (.kind == "ruling" or .kind == "cross_ticket_findings"))) | .[] | @json' "$job_dir/answer.out" | jq -r .)"
      elif [ -s "$job_dir/answer.txt" ]; then
        partial="$(jq -Rsc 'split("\n")[:-1] | map(fromjson? | select(type == "object" and (.kind == "ruling" or .kind == "cross_ticket_findings"))) | .[] | @json' "$job_dir/answer.txt" | jq -r .)"
      elif [ -f "$job_dir/state.json" ]; then
        partial="$(jq -rj '.lastText // ""' "$job_dir/state.json" | jq -Rsc 'split("\n")[:-1] | map(fromjson? | select(type == "object" and (.kind == "ruling" or .kind == "cross_ticket_findings"))) | .[] | @json' | jq -r .)"
      fi
      if [ -n "$partial" ] && jq -se 'any(.[]; .kind == "ruling")' >/dev/null 2>&1 <<< "$partial"; then
        echo "web-advisor-provider batch job $job_id timed out; harvesting complete NDJSON records" >&2
        printf '%s\n' "$partial"
        return 0
      fi
    fi
    echo "web-advisor-provider batch job $job_id failed (exit $node_status): $err_tail" >&2
    return 1
  fi
  cat "$job_dir/answer.out" 2>/dev/null
}

web_advisor_provider_forget_job() {
  local job_id="$1"
  rm -rf "$WEB_ADVISOR_PROVIDER_JOB_DIR/$job_id"
}

# web_advisor_provider_poll <job_id> -- exit 2 with nothing on stdout while the
# job is pending, including lease contention; exit 0 with the
# {is_error, structured_output} envelope after a terminal result. Cleans up
# the job directory only once a terminal result is consumed.
web_advisor_provider_poll() {
  local job_id="$1" job_dir="$WEB_ADVISOR_PROVIDER_JOB_DIR/$1" node_status answer err_tail model_used
  if [ ! -f "$job_dir/done" ]; then
    web_advisor_provider_resume_job_if_stopped "$job_id" || true
    return 2
  fi
  node_status="$(cat "$job_dir/done" 2>/dev/null || echo 1)"
  if [ "$node_status" = "75" ]; then
    echo "web-advisor-provider advisor job $job_id deferred: CDP browser lease busy" >&2
    rm -f "$job_dir/done"
    web_advisor_provider_resume_job_if_stopped "$job_id" || true
    return 2
  fi
  if [ "$node_status" != "0" ]; then
    err_tail="$(tail -c 2000 "$job_dir/answer.err" 2>/dev/null)"
    rm -rf "$job_dir"
    jq -nc --arg result "$err_tail" --arg status "$node_status" \
      '{is_error: true, subtype: "web_advisor_provider_call_failed", result: $result, web_advisor_provider_exit_status: ($status|tonumber)}'
    return 0
  fi
  answer="$(cat "$job_dir/answer.out" 2>/dev/null)"
  model_used="$(web_advisor_provider_model_used "$job_dir/answer.err")"
  rm -rf "$job_dir"
  web_advisor_provider_parse_answer "$answer" "$model_used"
}

reconcile_stale_web_advisor_provider_jobs() {
  local n f job_id started_at issue_json issue_state now age reason
  now="$(date +%s)"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$(state_file "$n")"
    [ -f "$f" ] || continue
    job_id="$(jq -r '.web_advisor_provider_job_id // empty' "$f" 2>/dev/null || true)"
    [ -n "$job_id" ] || continue
    reason=""
    if jq -e '(.state // "") == "concluded"' "$f" >/dev/null 2>&1; then
      reason="local state concluded"
    else
      if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json state,labels 2>/dev/null)"; then
        echo "supervise-pipeline: cannot verify issue #$n state; leaving web-advisor-provider job $job_id untouched" >&2
        continue
      fi
      if jq -e '(.state == "CLOSED") or any((.labels // [])[]; .name == "concluded")' \
        <<< "$issue_json" >/dev/null 2>&1; then
        reason="ticket closed or concluded"
      else
        issue_state="$(jq -r '.state // empty' <<< "$issue_json" 2>/dev/null || true)"
        case "$issue_state" in
          OPEN)
            started_at="$(jq -r '.web_advisor_provider_job_started_at // empty' "$f" 2>/dev/null || true)"
            case "$started_at" in
              ''|*[!0-9]*) continue ;;
            esac
            age=$((now - started_at))
            [ "$age" -gt "$WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS" ] || continue
            reason="job age ${age}s exceeds timeout ${WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS}s"
            ;;
          *)
            echo "supervise-pipeline: cannot verify issue #$n state=$issue_state; leaving web-advisor-provider job $job_id untouched" >&2
            continue
            ;;
        esac
      fi
    fi
    [ -n "$reason" ] || continue
    if [ "$MODE" != act ] || [ "$DRY_RUN" = 1 ]; then
      echo "supervise-pipeline: would clear orphan web-advisor-provider job $job_id for #$n ($reason)" >&2
      continue
    fi
    if web_advisor_provider_clear_job_state "$n"; then
      echo "supervise-pipeline: cleared orphan web-advisor-provider job $job_id for #$n ($reason)" >&2
    else
      echo "supervise-pipeline: failed to clear orphan web-advisor-provider job $job_id for #$n ($reason)" >&2
    fi
  done < <(web_advisor_provider_job_ids)
}

# --- per-ticket conversation policy ----------------------------------------
# Give each ticket its own topic so unrelated requests do not share context.
web_advisor_provider_per_ticket_topic() {
  WEB_ADVISOR_PROVIDER_TOPIC="$WEB_ADVISOR_PROVIDER_TOPIC-$1"
}
