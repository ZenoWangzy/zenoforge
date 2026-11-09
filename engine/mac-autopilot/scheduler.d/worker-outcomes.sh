worker_guard_refusal() { # unit log → explicit refusal outcome; identical consecutive refusals park
  local unit="$1" log="$2" marker signature previous evidence
  marker="$(grep -F "non-product-test-guard: refused unit=$unit " "$log" 2>/dev/null \
    | grep -Eo 'command=[[:alnum:]_-]+ reason=[[:alnum:]_-]+ recorded=[01]$' | tail -n 1 || true)"
  [[ -n "$marker" ]] || return 1
  signature="${marker% recorded=*}"
  previous="$(unit_field "$unit" '.history[-1].result // empty')"
  if [[ "$(unit_field "$unit" '.history[-1].stage // empty')" == worker-guard-refused && "$previous" == "$signature" ]]; then
    evidence="repeated non-product-test-guard refusal: $signature"
    set_unit "$unit" "$(hist worker-guard-refused "$signature") | .stage=\"parked\" | .note=$(js "$evidence") | $(park_fields "non-product-test-guard: $signature" "a changed unit head or supervisor decision")"
    say "worker-guard-refused unit=$unit repeated=$signature -> parked"
  else
    set_unit "$unit" "$(hist worker-guard-refused "$signature")"
    say "worker-guard-refused unit=$unit $signature"
  fi
  return 0
}

handle_worker_no_output() { # worker-json unit type log: a guard refusal is an outcome, otherwise diagnose the worker death
  local w="$1" unit="$2" wtype="$3" lg="$4"
  if worker_guard_refusal "$unit" "$lg"; then return 0; fi
  handle_worker_death "$w" "$unit" "$wtype" "$lg"
}
