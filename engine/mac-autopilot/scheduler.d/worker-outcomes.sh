handle_worker_guard_refusal() { # unit log → explicit refusal outcome; identical consecutive refusals park
  local unit="$1" log="$2" marker signature previous re
  re="^non-product-test-guard: refused unit=$unit command=[[:alnum:]_-]+ reason=[[:alnum:]_-]+ recorded=[01]$"
  marker="$(if [[ "$(head -n 1 -- "$log" 2>/dev/null || true)" == \{* ]]; then jqf -r '[.. | strings] | .[]' "$log" 2>/dev/null; else cat -- "$log" 2>/dev/null; fi | grep -E "$re" | tail -n 1 || true)"
  [[ -n "$marker" ]] || return 1
  signature="${marker% recorded=*}"
  previous="$(unit_field "$unit" '[(.history // [])[] | select(.stage != "write-start")] | last | select(.stage == "worker-guard-refused") | .result // empty')"
  if [[ "$previous" == "$signature" ]]; then
    set_unit "$unit" "$(hist worker-guard-refused "$signature") | .stage=\"parked\" | .note=$(js "repeated non-product-test-guard refusal: $signature") | $(park_fields "non-product-test-guard: $signature" "a supervisor decision")"
    say "worker-guard-refused unit=$unit repeated=$signature -> parked"
  else
    set_unit "$unit" "$(hist worker-guard-refused "$signature")"
    say "worker-guard-refused unit=$unit $signature"
  fi
  return 0
}

handle_worker_no_output() { # worker-json unit type log: a guard refusal is an outcome, otherwise diagnose the worker death
  local w="$1" unit="$2" wtype="$3" lg="$4"
  if handle_worker_guard_refusal "$unit" "$lg"; then return 0; fi
  handle_worker_death "$w" "$unit" "$wtype" "$lg"
}
