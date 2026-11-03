#!/usr/bin/env bash
# Dispatch build operations to the target repository's configured hook.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/config.sh"
config=$(zf_config_file build.json) || { echo 'engine-sync: build.json not found' >&2; exit 1; }
hook=$(jq -er '.hook | select(type == "string" and length > 0)' "$config")
engine=$(jq -er '.engine | select(type == "string" and length > 0)' "$config")
export ZF_BUILD_ENGINE="$engine"
engine_versions="$AGENT_HOME/engine-versions"
engine_failed_marker() {
  [[ "$engine" =~ ^[A-Za-z0-9._-]+$ ]] && [[ -e "$engine_versions/.failed-$engine" ]]
}
engine_version_id() {
  local path="$1"
  if [[ "$path" =~ /engine-versions/([^/]+)/engine/?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$(basename -- "$(dirname -- "$path")")"
  fi
}
engine_version_was_live() {
  local id="$1" history="$engine_versions/.swap-history.jsonl"
  [[ -r "$history" ]] || return 1
  jq -e -s --arg id "$id" 'any(.[]; .old_id == $id or .new_id == $id)' "$history" >/dev/null 2>&1
}

# Eval-on-pin gate (founder ruling 2026-11-03): a new engine pin is evaluated before it
# goes live. The gate reuses the eval suite's decision gate, launched from inside the
# built version directory, and holds the engine-live flip until a verdict exists; the
# #162 canary then watches the swap exactly as before. State lives beside the engine
# versions, keyed by version id, so a gate runs once per id and survives a restart.
engine_eval_runtime_dir() {
  printf '%s' "${MAC_AUTOPILOT_RUNTIME_DIR:-${MAC_AUTOPILOT_SUPERVISOR_DIR:-$ZF_REPO_DIR/.scratch-supervisor}/autopi}"
}

engine_eval_config() { # key, default → runtime config value for engine.eval_on_pin.<key>
  local config="$(engine_eval_runtime_dir)/config.json"
  if [[ -r "$config" ]]; then
    jq -r --arg fallback "$2" ".engine.eval_on_pin.$1 // \$fallback" "$config" 2>/dev/null || printf '%s\n' "$2"
  else
    printf '%s\n' "$2"
  fi
}

engine_eval_log() { # event line without stamp → the scheduler log the canary also writes
  local runtime
  runtime="$(engine_eval_runtime_dir)"
  mkdir -p "$runtime"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$runtime/scheduler.log"
}

engine_eval_inform_supervisor() { # live engine dir, key, message → one inbox line through the live engine's lib
  AGENT_HOME="$AGENT_HOME" ZF_ENGINE_DIR="$1" ZF_REPO_DIR="$ZF_REPO_DIR" \
    bash -c 'source "$ZF_ENGINE_DIR/lib.sh" && supervisor_inbox_append_once "$1" "$2"' \
    engine-sync "$2" "$3" || echo "engine-sync: supervisor inbox append failed for $2" >&2
}

engine_eval_accepted_label() { # live engine id → its accepted label: per-id registry, then the pipeline's accepted label, then 'baseline'
  local label=''
  if [[ -r "$engine_versions/.eval-baselines.json" ]]; then
    label="$(jq -r --arg id "$1" '.[$id] // empty' "$engine_versions/.eval-baselines.json" 2>/dev/null || true)"
  fi
  [[ -n "$label" ]] || label="$(head -n1 "$AGENT_HOME/eval-accepted-label" 2>/dev/null || true)"
  printf '%s' "${label:-baseline}"
}

engine_eval_accept_label() { # engine id, label → the passing gate label becomes this id's accepted baseline
  local base='{}' tmp
  [[ -r "$engine_versions/.eval-baselines.json" ]] && base="$(cat "$engine_versions/.eval-baselines.json" 2>/dev/null || printf '{}')"
  tmp="$(mktemp "$engine_versions/.eval-baselines.XXXXXX")" || return 1
  jq -c --arg id "$1" --arg label "$2" '. + {($id): $label}' <<<"$base" > "$tmp" \
    && mv -f -- "$tmp" "$engine_versions/.eval-baselines.json" || { rm -f -- "$tmp"; return 1; }
}

engine_eval_state() { # state file, key=value... → atomic in-place update (numbers stay numbers)
  local file="$1" kv name value base='{}' tmp program=''
  shift
  local -a jq_args=()
  for kv in "$@"; do
    name="${kv%%=*}"
    value="${kv#*=}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "$value" =~ ^[0-9]+$ ]]; then jq_args+=(--argjson "$name" "$value"); else jq_args+=(--arg "$name" "$value"); fi
    program+=".${name} = \$${name} | "
  done
  [[ -n "$program" ]] || return 0
  [[ -s "$file" ]] && base="$(cat "$file" 2>/dev/null || printf '{}')"
  tmp="$(mktemp "${file%/*}/.eval-on-pin-state.XXXXXX")" || return 1
  jq -c ${jq_args[@]+"${jq_args[@]}"} "${program% | }" <<<"$base" > "$tmp" \
    && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

engine_eval_stages_for_pin() { # built version dir, live ref, new ref → comma-separated stages; empty when no stage surface is touched
  local dir="$1" paths stages stage csv=''
  if ! paths="$(git -C "$ZF_REPO_DIR" diff --name-only "$2" "$3" 2>/dev/null)"; then
    return 1
  fi
  [[ -r "$dir/engine/eval/decision-stages.sh" ]] || return 1
  stages="$(bash "$dir/engine/eval/decision-stages.sh" --pin <<<"$paths")" || return 1
  for stage in triage advisor implement review supervisor end-to-end; do
    grep -qw "$stage" <<<"$stages" && csv="${csv:+$csv,}$stage"
  done
  printf '%s\n' "$csv"
}

engine_eval_configured_stages() { # null/missing means derive from the diff; otherwise accept a JSON array or comma-separated string
  local config="$(engine_eval_runtime_dir)/config.json"
  [[ -r "$config" ]] || { printf '__derive__\n'; return 0; }
  jq -er '
    (.engine.eval_on_pin.stages // null) as $stages
    | if $stages == null then "__derive__"
      elif ($stages | type) == "array" and ($stages | length) > 0 and all($stages[]; type == "string") then ($stages | join(","))
      elif ($stages | type) == "string" and ($stages | length) > 0 then $stages
      else error("engine.eval_on_pin.stages must be null or a nonempty list of stage names") end
  ' "$config" 2>/dev/null
}

engine_eval_valid_stages() { # comma-separated stages → 0 when every name is a selectable eval stage
  local stage
  [[ -n "$1" && "$1" != ,* && "$1" != *, && "$1" != *,,* ]] || return 1
  for stage in ${1//,/ }; do
    case "$stage" in
      triage|advisor|implement|review|supervisor|end-to-end) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

engine_eval_gate_start() { # version dir, sha, tree, stages, baseline, label, seconds, report, log → background pid
  local dir="$1" sha="$2" tree="$3" stages="$4" baseline="$5" label="$6" seconds="$7" report="$8" log_file="$9"
  local -a gate=(node "$dir/engine/eval/decision-gate.mjs")
  # ZF_EVAL_GATE swaps the gate process itself, so tests exercise the state machine without model calls.
  [[ -z "${ZF_EVAL_GATE:-}" ]] || gate=(bash "$ZF_EVAL_GATE")
  local -a launcher=()
  command -v setsid >/dev/null 2>&1 && launcher=(setsid)
  (
    cd "$dir" || exit 1
    # The gate must outlive this converge tick; `timeout` bounds it at the configured deadline.
    exec ${launcher[@]+"${launcher[@]}"} timeout -k 30 "$seconds" "${gate[@]}" \
      --repo "$dir" --sha "$sha" --tree "$tree" --stages "$stages" \
      --baseline "$baseline" --label "$label" --subset --output "$report"
  ) > "$log_file" 2>&1 < /dev/null &
  printf '%s' "$!"
}

engine_eval_on_pin() { # new version dir/id, live engine dir/id, live ref, new ref, previously-live flag
  # → 0 = the flip may proceed, 1 = hold it (gate pending, rejected or timed out)
  local new_dir="$1" new_id="$2" live_dir="$3" live_id="$4" live_ref="$5" new_ref="$6" previously_live="$7"
  if [[ "$(engine_eval_config enabled true)" != true ]]; then
    engine_eval_log "EVAL-SKIP engine $new_id: engine.eval_on_pin disabled"
    return 0
  fi
  if [[ "$previously_live" == 1 ]]; then
    # The #162 rollback path: this id already ran live under its own accepted baseline.
    engine_eval_log "EVAL-SKIP engine $new_id: returning to a previously live engine"
    return 0
  fi
  if ! [[ "$new_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    engine_eval_log "EVAL-HOLD engine $new_id: unsafe version id for eval state"
    return 1
  fi
  local state="$engine_versions/.eval-on-pin-$new_id.json"
  local report="$engine_versions/.eval-on-pin-$new_id.report.json"
  local gate_log="$engine_versions/.eval-on-pin-$new_id.log"
  local timeout_min now started pid stages_csv baseline label gate_sha gate_tree
  timeout_min="$(engine_eval_config timeout_minutes 45)"
  [[ "$timeout_min" =~ ^[1-9][0-9]*$ ]] || timeout_min=45

  local status=''
  [[ -r "$state" ]] && status="$(jq -r '.status // empty' "$state" 2>/dev/null || true)"
  case "$status" in
    passed) return 0 ;;
    # failed: the .failed marker keeps converge from retrying the id; timed-out: hold without a marker.
    failed|timed-out) return 1 ;;
  esac

  if [[ -s "$report" ]]; then
    local verdict first_regression passed_label passed_baseline expected_baseline
    verdict="$(jq -r '.status // empty' "$report" 2>/dev/null || true)"
    if [[ "$verdict" == passed ]]; then
      passed_label="$(jq -r '.label // empty' "$report" 2>/dev/null || true)"
      passed_baseline="$(jq -r '.baseline // empty' "$report" 2>/dev/null || true)"
      label="$(jq -r '.label // empty' "$state" 2>/dev/null || true)"
      expected_baseline="$(jq -r '.baseline // empty' "$state" 2>/dev/null || true)"
      if [[ -z "$passed_label" || "$passed_label" != "$label" || "$passed_baseline" != "$expected_baseline" ]] \
        || ! engine_eval_accept_label "$new_id" "$passed_label"; then
        engine_eval_log "EVAL-HOLD engine $new_id: passing result did not match its saved gate state"
        return 1
      fi
      if ! engine_eval_state "$state" status=passed; then
        engine_eval_log "EVAL-HOLD engine $new_id: passing gate state could not be stored"
        return 1
      fi
      return 0
    fi
    if [[ "$verdict" == failed ]]; then
      first_regression="$(jq -r '.regressions[0] // .criticalFailures[0] // .supervisor.failures[0] // "eval gate failed"' "$report" 2>/dev/null || true)"
      if ! engine_eval_state "$state" status=failed "first_regression=$first_regression"; then
        engine_eval_log "EVAL-HOLD engine $new_id: reject state could not be stored"
        return 1
      fi
      : > "$engine_versions/.failed-$new_id"
      engine_eval_log "EVAL-REJECT engine $new_id: $first_regression"
      engine_eval_inform_supervisor "$live_dir" "engine-eval-reject:$new_id" "EVAL-REJECT engine $new_id: $first_regression"
      return 1
    fi
    # Any other verdict is a gate infrastructure error, not a decision: keep waiting below.
  fi

  local now started pid
  now="$(date +%s)"
  if [[ "$status" == running ]]; then
    started="$(jq -r '.started_at // 0' "$state" 2>/dev/null || true)"
    [[ "$started" =~ ^[0-9]+$ ]] || started=0
    if (( now - started > timeout_min * 60 )); then
      pid="$(jq -r '.pid // 0' "$state" 2>/dev/null || true)"
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      fi
      engine_eval_state "$state" status=timed-out || return 1
      engine_eval_log "EVAL-TIMEOUT engine $new_id: no gate result within ${timeout_min} minutes"
      engine_eval_inform_supervisor "$live_dir" "engine-eval-timeout:$new_id" "EVAL-TIMEOUT engine $new_id: no gate result within ${timeout_min} minutes"
      return 1
    fi
    pid="$(jq -r '.pid // 0' "$state" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      return 1 # a gate launched on an earlier tick is still running
    fi
    # The gate process is gone (e.g. a restart): resume the same label; decision-gate keeps
    # finished case/runs and only runs the missing ones.
    gate_sha="$(jq -r '.sha // empty' "$state")"
    gate_tree="$(jq -r '.tree // empty' "$state")"
    stages_csv="$(jq -r '.stages // empty' "$state")"
    baseline="$(jq -r '.baseline // empty' "$state")"
    label="$(jq -r '.label // empty' "$state")"
    if [[ -n "$gate_tree" && -n "$stages_csv" && -n "$baseline" && -n "$label" ]]; then
      pid="$(engine_eval_gate_start "$new_dir" "$gate_sha" "$gate_tree" "$stages_csv" "$baseline" "$label" \
        "$((timeout_min * 60))" "$report" "$gate_log")"
      engine_eval_state "$state" "pid=$pid" || { kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true; return 1; }
    fi
    return 1
  fi

  # First preflight for this id: derive the gate inputs, start the eval, hold the flip.
  if ! stages_csv="$(engine_eval_configured_stages)"; then
    engine_eval_log "EVAL-HOLD engine $new_id: invalid engine.eval_on_pin.stages configuration"
    return 1
  fi
  if [[ "$stages_csv" == __derive__ ]]; then
    if ! stages_csv="$(engine_eval_stages_for_pin "$new_dir" "$live_ref" "$new_ref")"; then
      engine_eval_log "EVAL-HOLD engine $new_id: cannot read the live-to-pin diff"
      return 1
    fi
  fi
  stages_csv="${stages_csv//[[:space:]]/}"
  if [[ -n "$stages_csv" ]] && ! engine_eval_valid_stages "$stages_csv"; then
    engine_eval_log "EVAL-HOLD engine $new_id: invalid engine.eval_on_pin.stages: $stages_csv"
    return 1
  fi
  if [[ -z "$stages_csv" ]]; then
    engine_eval_log "EVAL-SKIP engine $new_id: diff touches no stage prompt or stage code"
    # Decisions are unchanged, so the live id's accepted baseline keeps describing the new id.
    local carried
    carried="$(engine_eval_accepted_label "$live_id")"
    if ! engine_eval_accept_label "$new_id" "$carried"; then
      engine_eval_log "EVAL-HOLD engine $new_id: could not carry accepted baseline $carried forward"
      return 1
    fi
    return 0
  fi
  baseline="$(engine_eval_accepted_label "$live_id")"
  if [[ ! -s "$AGENT_HOME/eval/$baseline/results.json" ]]; then
    if [[ "$status" != waiting-baseline ]]; then
      engine_eval_state "$state" "engine=$new_id" "live_id=$live_id" "baseline=$baseline" status=waiting-baseline || return 1
      engine_eval_log "EVAL-HOLD engine $new_id: accepted baseline label $baseline for live engine $live_id is missing"
    fi
    return 1
  fi
  label="pin-$(tr -c 'A-Za-z0-9._-' '-' <<<"$new_id" | sed 's/-$//')"
  gate_sha="$new_ref"
  gate_tree="$(git -C "$ZF_REPO_DIR" rev-parse "${gate_sha}^{tree}" 2>/dev/null || true)"
  engine_eval_state "$state" "engine=$new_id" "live_id=$live_id" "baseline=$baseline" "label=$label" \
    "stages=$stages_csv" "sha=$gate_sha" "tree=$gate_tree" "started_at=$now" status=running || return 1
  if [[ -n "$gate_tree" ]]; then
    pid="$(engine_eval_gate_start "$new_dir" "$gate_sha" "$gate_tree" "$stages_csv" "$baseline" "$label" \
      "$((timeout_min * 60))" "$report" "$gate_log")"
    engine_eval_state "$state" "pid=$pid" || { kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true; return 1; }
    engine_eval_log "EVAL-START engine $new_id: stages=$stages_csv baseline=$baseline label=$label timeout=${timeout_min}m"
  else
    # Without a resolvable candidate identity the gate cannot run; the deadline still bounds the hold.
    engine_eval_log "EVAL-HOLD engine $new_id: cannot resolve git identity for $new_ref in $ZF_REPO_DIR"
  fi
  return 1
}
if [[ "${1:-}" == --preflight ]]; then
  shift
  if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && -z "$2" ) ]]; then
    echo "usage: engine-sync.sh --preflight <new version dir> [intended-change list]" >&2
    exit 2
  fi
  new_version_dir=$(cd -- "$1" 2>/dev/null && pwd -P) || {
    echo "engine-sync: new version directory not found: $1" >&2
    exit 1
  }
  new_version_id="$(basename -- "$new_version_dir")"
  live_engine_dir=$(readlink -e -- "$AGENT_HOME/engine-live") || {
    echo "engine-sync: cannot resolve $AGENT_HOME/engine-live" >&2
    exit 1
  }
  live_version_dir=$(dirname -- "$live_engine_dir")
  [[ -d "$live_engine_dir" && -d "$new_version_dir/engine" ]] || {
    echo "engine-sync: preflight expects engine directories in the live and new versions" >&2
    exit 1
  }
  # Compare against the target commit each version was built from: at converge time HEAD is already the new commit.
  # A hook that knows the commit the live checkout ran can pass it in ZF_PREFLIGHT_LIVE_REF.
  build_ref() { # product_sha, else the commit in pack_sha; empty when the version has no BUILD-INFO
    local info="$1/BUILD-INFO" ref
    [[ -r "$info" ]] || return 0
    ref=$(sed -n 's/^product_sha=//p' "$info")
    [[ -n "$ref" ]] || ref=$(sed -n 's/^pack_sha=\([0-9a-f]*\):.*/\1/p' "$info")
    printf '%s' "${ref%%$'\n'*}"
  }
  live_ref=${ZF_PREFLIGHT_LIVE_REF:-$(build_ref "$live_version_dir")}
  new_ref=$(build_ref "$new_version_dir")
  [[ -n "$live_ref" ]] || { echo "engine-sync: cannot tell which target commit the live version ran; set ZF_PREFLIGHT_LIVE_REF" >&2; exit 1; }
  preflight_args=("$live_version_dir" "$new_version_dir" "$ZF_REPO_DIR" "$live_ref" "${new_ref:-HEAD}")
  [[ $# -eq 1 ]] || preflight_args+=("$2")
  if engine_version_was_live "$new_version_id"; then
    export ZF_PREFLIGHT_PREVIOUSLY_LIVE=1
    echo "engine-sync: returning to previously live engine $new_version_id; skipping resolved-config and dropped-file-refs comparisons" >&2
  fi
  bash "$here/publish-preflight/run.sh" "${preflight_args[@]}"
  # Manual preflight remains a build-integrity check; converge marks the hook call so
  # only a live pin attempt starts the asynchronous decision gate.
  [[ "${ZF_ENGINE_SYNC_CONVERGE:-0}" == 1 ]] || exit 0
  # The hook calls this preflight after building and checking the new version and before it
  # flips engine-live, so the eval-on-pin gate is the last step of that check: it holds the
  # flip (nonzero) until the eval verdict exists, and never blocks the tick itself — the
  # eval runs in the background and a later converge flips on the verdict.
  if ! engine_eval_on_pin "$new_version_dir" "$new_version_id" "$live_engine_dir" "$(engine_version_id "$live_engine_dir")" \
    "$live_ref" "${new_ref:-HEAD}" "${ZF_PREFLIGHT_PREVIOUSLY_LIVE:-0}"; then
    exit 1
  fi
  exit 0
fi
if [[ "${1:-}" == --converge ]] && engine_failed_marker; then
  echo "engine-sync: skipping previously failed engine $engine"
  exit 0
fi

if [[ "${1:-}" == --converge ]]; then
  live_link="$AGENT_HOME/engine-live"
  autopi_link="${MAC_AUTOPILOT_SUPERVISOR_DIR:-$ZF_REPO_DIR/.scratch-supervisor}/autopi-live"
  old_engine_target="$(readlink -- "$live_link" 2>/dev/null || true)"
  old_engine_dir="$(readlink -e -- "$live_link" 2>/dev/null || true)"
  old_autopi_target="$(readlink -- "$autopi_link" 2>/dev/null || true)"
  hook_status=0
  ZF_ENGINE_SYNC_CONVERGE=1 "$ZF_REPO_DIR/$hook" "$@" || hook_status=$?
  new_engine_dir="$(readlink -e -- "$live_link" 2>/dev/null || true)"
  new_engine_target="$(readlink -- "$live_link" 2>/dev/null || true)"
  new_autopi_target="$(readlink -- "$autopi_link" 2>/dev/null || true)"
  if [[ -n "$old_engine_target" && -n "$old_engine_dir" && -n "$new_engine_dir" && "$old_engine_dir" != "$new_engine_dir" ]]; then
    old_engine_id="$(engine_version_id "$old_engine_dir")"
    new_engine_id="$(engine_version_id "$new_engine_dir")"
    if [[ -n "$old_engine_dir" && "$old_engine_id" != "$new_engine_id" ]]; then
      ZF_ENGINE_DIR="$new_engine_dir" ZF_REPO_DIR="$ZF_REPO_DIR" AGENT_HOME="$AGENT_HOME" \
        MAC_AUTOPILOT_ROOT="$ZF_REPO_DIR" \
        MAC_AUTOPILOT_SUPERVISOR_DIR="${MAC_AUTOPILOT_SUPERVISOR_DIR:-$ZF_REPO_DIR/.scratch-supervisor}" \
        MAC_AUTOPILOT_RUNTIME_DIR="${MAC_AUTOPILOT_RUNTIME_DIR:-${MAC_AUTOPILOT_SUPERVISOR_DIR:-$ZF_REPO_DIR/.scratch-supervisor}/autopi}" \
        bash "$new_engine_dir/mac-autopilot/engine-canary.sh" record-swap \
          "$old_engine_id" "$new_engine_id" "$old_engine_target" "$new_engine_target" \
          "$old_autopi_target" "$new_autopi_target"
    fi
  fi
  exit "$hook_status"
fi
exec "$ZF_REPO_DIR/$hook" "$@"
