handle_worker_guard_refusal() { # unit refusal-file head work-type attempt → requeue twice; escalate a third same-head refusal unless delivered
  local unit="$1" refusal_file="$2" head="${3:-}" work_type="${4:-}" attempt="${5:-}" marker signature refusals delivered re pending_stage filter
  re="^non-product-test-guard: refused unit=$unit command=[[:alnum:]_-]+ reason=[[:alnum:]_-]+ recorded=[01]$"
  marker="$(grep -E "$re" "$refusal_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$marker" ]] || return 1
  signature="${marker#* unit=$unit }"; signature="${signature% recorded=*}"
  refusals="$(jqf -r --arg id "$unit" --arg head "$head" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage=="worker-guard-refused" and (.head // "")==$head)] | length' "$UNITS")"
  delivered="$(jqf -r --arg id "$unit" --arg head "$head" '[.units[] | select(.id==$id) | (.history // [])[] | select($head!="" and .stage=="repair-delivered" and (.head // "")==$head)] | length' "$UNITS")"
  filter="$(hist worker-guard-refused "$signature") | .history[-1].head=$(js "$head")"
  [[ -z "$work_type" ]] || filter+=" | .history[-1].work_type=$(js "$work_type")"
  if [[ -n "$attempt" ]]; then
    filter+=" | .history[-1].attempt=$(js "$attempt") | .history |= map(if .stage == \"write-start\" and .attempt == $(js "$attempt") then . + {worker_guard_refused:true} else . end)"
  fi
  set_unit "$unit" "$filter"
  if (( refusals >= 2 && delivered == 0 )); then
    to_supervisor "$unit" "test-shim refusal loop after 3 refusals on head ${head:-unknown}: $signature"
  else
    case "$work_type" in
      implement) pending_stage=implement-pending ;;
      repair) pending_stage=repair-pending ;;
      review) pending_stage=review-pending ;;
      rereview) pending_stage=rereview-pending ;;
      *) pending_stage="" ;;
    esac
    [[ -z "$pending_stage" ]] || set_unit "$unit" ".stage=$(js "$pending_stage") | .note=null"
    say "worker-guard-refused unit=$unit $signature${pending_stage:+ requeued=$pending_stage}"
  fi
  return 0
}

handle_worker_no_output() {
  local w="$1" unit="$2" wtype="$3" lg="$4" pid="$5" head="${6:-}"
  if handle_worker_guard_refusal "$unit" "$lg.guard-refusals" "$head" "$wtype" "${lg##*/}"; then return 0; fi
  handle_worker_death "$w" "$unit" "$wtype" "$lg"
}
