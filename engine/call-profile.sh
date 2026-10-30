# Optional command-level scheduler profiling. Source after lib.sh; never call
# it from a hot loop. Records contain fixed metadata only, never argv/output.
ZF_PIPELINE_CALL_PROFILE_ENABLED=0
[ -n "${ZF_PIPELINE_CALL_PROFILE_FILE:-}" ] || return 0
if ! { : >> "$ZF_PIPELINE_CALL_PROFILE_FILE"; } 2>/dev/null; then
  echo 'issue-pipeline: call profiling disabled; profile file is not writable' >&2
  return 0
fi

ZF_PIPELINE_CALL_PROFILE_ENABLED=1
ZF_PIPELINE_CALL_PROFILE_BOUNDARY=section-v2

_call_profile_classify_write() {
  local i name dispatch=0 record=0
  for ((i = 2; i < ${#FUNCNAME[@]}; i++)); do
    name="${FUNCNAME[i]}"
    case "$name" in
      dispatch|dispatch_*|route_pipeline*|run_intake_dispatch|scheduler_requeue_issue)
        dispatch=1 ;;
      record_*|state_merge*|state_write*|efficiency_metrics_*|supervisor_inbox_append*|issue_transition|ensure_state_labels|route_to_*|ticket_stage_record_gh_write)
        record=1 ;;
    esac
  done
  if [ "$dispatch" = 1 ]; then
    _CALL_PROFILE_EFFECT=dispatch-write
  elif [ "$record" = 1 ]; then
    _CALL_PROFILE_EFFECT=record-write
  else
    _CALL_PROFILE_EFFECT=other-write
  fi
}

_call_profile_classify_effect() {
  local tool="$1" verb subverb method="" has_fields=0 arg graphql_query="" graphql_first_line
  shift
  _CALL_PROFILE_EFFECT=local
  case "$tool" in
    gh)
      verb="${1:-}"
      subverb="${2:-}"
      case "$verb:$subverb" in
        issue:view|issue:list|pr:view|pr:list|pr:checks|pr:diff|pr:status|run:view|run:list|label:list|repo:view|repo:list|workflow:view|workflow:list|release:view|release:list|variable:get|variable:list|auth:status)
          _CALL_PROFILE_EFFECT=api-read ;;
        api:*)
          while (($#)); do
            arg="$1"
            case "$arg" in
              --method|-X)
                if (($# >= 2)); then method="$2"; shift 2; else method=invalid; shift; fi
                continue ;;
              --method=*|-X=*) method="${arg#*=}" ;;
              -X?*) method="${arg#-X}" ;;
              -f|--field|-F|--raw-field|--input)
                has_fields=1
                if (($# >= 2)) && [[ "$2" == query=* ]]; then graphql_query="${2#query=}"; fi
                shift
                (($#)) && shift
                continue ;;
              --field=*|--raw-field=*|--input=*|-f?*|-F?*)
                has_fields=1
                case "$arg" in
                  --field=query=*|--raw-field=query=*) graphql_query="${arg#*=query=}" ;;
                  -fquery=*) graphql_query="${arg#-fquery=}" ;;
                  -Fquery=*) graphql_query="${arg#-Fquery=}" ;;
                esac ;;
            esac
            shift
          done
          graphql_first_line="${graphql_query//$'\r'/}"
          while [[ "$graphql_first_line" =~ ^[[:space:]]*# ]]; do
            [[ "$graphql_first_line" == *$'\n'* ]] || { graphql_first_line=""; break; }
            graphql_first_line="${graphql_first_line#*$'\n'}"
          done
          graphql_first_line="${graphql_first_line#"${graphql_first_line%%[!$' \t\n']*}"}"
          if [[ "$subverb" == graphql && "$graphql_first_line" =~ ^mutation([[:space:]{]|$) ]]; then
            _call_profile_classify_write
          elif [[ "$subverb" == graphql && ( "$graphql_first_line" =~ ^query([[:space:]{]|$) || "$graphql_first_line" == \{* ) ]]; then
            _CALL_PROFILE_EFFECT=api-read
          else
            case "${method^^}:$has_fields" in
              GET:*|HEAD:*|OPTIONS:*) _CALL_PROFILE_EFFECT=api-read ;;
              :0) _CALL_PROFILE_EFFECT=api-read ;;
              POST:*|PUT:*|PATCH:*|DELETE:*|:1) _call_profile_classify_write ;;
              *) _CALL_PROFILE_EFFECT=api-unknown ;;
            esac
          fi
          ;;
        issue:create|issue:edit|issue:close|issue:delete|issue:reopen|issue:comment|pr:create|pr:edit|pr:close|pr:reopen|pr:comment|pr:merge|pr:review|pr:ready|pr:update-branch|run:rerun|run:cancel|workflow:run|label:create|label:edit|label:delete|variable:set|variable:delete|release:create|release:edit|release:delete)
          _call_profile_classify_write ;;
        *) _CALL_PROFILE_EFFECT=api-unknown ;;
      esac
      ;;
    git)
      case " ${*:1} " in
        *' fetch '*|*' ls-remote '*|*' status '*|*' show '*|*' log '*|*' diff '*|*' rev-parse '*|*' merge-base '*|*' branch --list '*|*' worktree list '*|*' remote -v '*)
          _CALL_PROFILE_EFFECT=external-read ;;
        *' push '*|*' commit '*|*' merge '*|*' rebase '*|*' checkout '*|*' reset '*|*' worktree add '*|*' worktree remove '*|*' add '*|*' clean '*)
          _call_profile_classify_write ;;
        *) _CALL_PROFILE_EFFECT=local ;;
      esac
      ;;
    systemd-run) _CALL_PROFILE_EFFECT=dispatch-write ;;
    jq|node) _CALL_PROFILE_EFFECT=local ;;
  esac
}

_call_profile_ticket_category() {
  local category="${ZF_CALL_PROFILE_TICKET_CATEGORY:-}" section="${TICK_PROFILE_SECTION:-${ZF_CALL_PROFILE_SECTION:-}}"
  local name value has_ticket=0
  case "$category" in product|pipeline-system|unclassified|tick) _CALL_PROFILE_CATEGORY="$category"; return ;; esac
  case "${candidate_lane:-}" in product|pipeline-system) _CALL_PROFILE_CATEGORY="$candidate_lane"; return ;; esac
  for name in n next_triage next_advisor next_recut next_release candidate_issue; do
    value="${!name-}"
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then has_ticket=1; break; fi
  done
  if [ "$has_ticket" = 0 ]; then
    _CALL_PROFILE_CATEGORY=tick
    return
  fi
  case "$section" in
    fastlane) _CALL_PROFILE_CATEGORY=pipeline-system ;;
    triage|advisor|recut|release|maintenance) _CALL_PROFILE_CATEGORY=product ;;
    *) _CALL_PROFILE_CATEGORY=unclassified ;;
  esac
}

_call_profile_record() {
  local tool="$1" started_us="$2" ended_us="$3" result="$4" source="$5" function="$6" line="$7"
  local tick stage section site elapsed_ms
  shift 7
  [[ "$started_us" =~ ^[0-9]+$ && "$ended_us" =~ ^[0-9]+$ ]] || return 0
  tick="${IMPLEMENT_TICK_ID:-${ZF_CALL_PROFILE_TICK_ID:-unknown}}"
  stage="${PIPELINE_STAGE:-${ZF_CALL_PROFILE_STAGE:-runner}}"
  section="${TICK_PROFILE_SECTION:-${ZF_CALL_PROFILE_SECTION:-preflight}}"
  [[ "$tick" =~ ^[A-Za-z0-9_.-]+$ ]] || tick=unknown
  [[ "$stage" =~ ^[A-Za-z0-9_.-]+$ ]] || stage=unknown
  [[ "$section" =~ ^[A-Za-z0-9_.-]+$ ]] || section=unknown
  [[ "$source" =~ ^[A-Za-z0-9_.-]+$ ]] || source=unknown
  [[ "$function" =~ ^[A-Za-z0-9_.-]+$ ]] || function=main
  [[ "$line" =~ ^[0-9]+$ ]] || line=0
  [[ "$result" =~ ^[0-9]+$ || "$result" = dry-run ]] || result=unknown
  site="$source:$function:$line"
  elapsed_ms=$(((ended_us - started_us) / 1000))
  (( elapsed_ms >= 0 )) || elapsed_ms=0
  _call_profile_classify_effect "$tool" "$@"
  local effect="$_CALL_PROFILE_EFFECT"
  _call_profile_ticket_category
  {
    printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ZF_PIPELINE_CALL_PROFILE_BOUNDARY" "$tick" "$stage" "$section" \
      "$_CALL_PROFILE_CATEGORY" "$tool" "$effect" "$site" "$elapsed_ms" "$result"
  } >> "$ZF_PIPELINE_CALL_PROFILE_FILE" 2>/dev/null || true
}

_call_profile_external() {
  local tool="$1" source="$2" function="$3" line="$4" started_us ended_us status=0
  shift 4
  started_us="${EPOCHREALTIME/./}"
  if command "$tool" "$@"; then status=0; else status=$?; fi
  ended_us="${EPOCHREALTIME/./}"
  _call_profile_record "$tool" "$started_us" "$ended_us" "$status" \
    "$source" "$function" "$line" "$@"
  return "$status"
}

_call_profile_guarded_dry_run() {
  local source="${BASH_SOURCE[2]:-}" function="${FUNCNAME[2]:-main}" line="${BASH_LINENO[1]:-0}"
  local started_us="${EPOCHREALTIME/./}"
  case "${1:-}" in gh|git|jq|node|systemd-run) ;; *) return 0 ;; esac
  source="${source##*/}"
  _call_profile_record "${1:-unknown}" "$started_us" "$started_us" dry-run \
    "$source" "$function" "$line" "${@:2}"
}

git() {
  local source="${BASH_SOURCE[1]:-}" function="${FUNCNAME[1]:-main}" line="${BASH_LINENO[0]:-0}"
  if [ "$function" = guarded_write ]; then
    source="${BASH_SOURCE[2]:-}"; function="${FUNCNAME[2]:-main}"; line="${BASH_LINENO[1]:-0}"
  fi
  source="${source##*/}"
  _call_profile_external git "$source" "$function" "$line" "$@"
}

jq() {
  local source="${BASH_SOURCE[1]:-}" function="${FUNCNAME[1]:-main}" line="${BASH_LINENO[0]:-0}"
  source="${source##*/}"
  _call_profile_external jq "$source" "$function" "$line" "$@"
}

node() {
  local source="${BASH_SOURCE[1]:-}" function="${FUNCNAME[1]:-main}" line="${BASH_LINENO[0]:-0}"
  source="${source##*/}"
  _call_profile_external node "$source" "$function" "$line" "$@"
}
