handle_worker_guard_refusal() { # unit refusal-file head → explicit refusal outcome; two refusals on one head go to supervisor
  local unit="$1" refusal_file="$2" head="${3:-}" marker signature refusals re
  re="^non-product-test-guard: refused unit=$unit command=[[:alnum:]_-]+ reason=[[:alnum:]_-]+ recorded=[01]$"
  marker="$(grep -E "$re" "$refusal_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$marker" ]] || return 1
  signature="${marker#* unit=$unit }"; signature="${signature% recorded=*}"
  refusals="$(jqf -r --arg id "$unit" --arg head "$head" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage=="worker-guard-refused" and (.head // "")==$head)] | length' "$UNITS")"
  set_unit "$unit" "$(hist worker-guard-refused "$signature") | .history[-1].head=$(js "$head")"
  if (( refusals >= 1 )); then
    to_supervisor "$unit" "repeated non-product-test-guard refusal on head ${head:-unknown}: $signature"
  else
    say "worker-guard-refused unit=$unit $signature"
  fi
  return 0
}

handle_worker_no_output() {
  local w="$1" unit="$2" wtype="$3" lg="$4" pid="$5" head="${6:-}"
  if handle_worker_guard_refusal "$unit" "$lg.guard-refusals" "$head"; then return 0; fi
  handle_worker_death "$w" "$unit" "$wtype" "$lg"
}
