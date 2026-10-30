#!/usr/bin/env bash

verification_plan_unavailable_json() {
  local phase="$1" reason="$2" head_sha="${3:-}"
  local reason_file result_status=0
  reason_file="$(mktemp)" || return 1
  printf '%s' "$reason" >"$reason_file" || { rm -f "$reason_file"; return 1; }
  jq -nc --arg phase "$phase" --rawfile reason "$reason_file" --arg head_sha "$head_sha" '
    {status:"unavailable",phase:$phase,reason:$reason}
    + (if $head_sha == "" then {} else {head_sha:$head_sha} end)
  ' || result_status=$?
  rm -f "$reason_file"
  return "$result_status"
}

build_verification_intent_plan_json() {
  local root="$1" script_dir="$2" entry_surface="$3" expected_paths_json="$4"
  local output reason error_file expected_path
  local -a planner_args=(--root "$root")

  if [ -n "$entry_surface" ]; then
    planner_args+=(--entry-surface "$entry_surface")
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 <<< "$expected_paths_json"; then
    verification_plan_unavailable_json intent "expected_paths is not a string array"
    return 0
  fi
  while IFS= read -r expected_path; do
    [ -n "$expected_path" ] && planner_args+=(--expected-path "$expected_path")
  done < <(jq -r '.[]' <<< "$expected_paths_json")

  error_file="$(mktemp)"
  if output="$(node "$script_dir/verification-plan.mjs" "${planner_args[@]}" 2>"$error_file")" \
    && jq -e 'type == "object" and (.matched_features | type) == "array"' >/dev/null 2>&1 <<< "$output"; then
    rm -f "$error_file"
    jq -c '. + {status:"available",phase:"intent"}' <<< "$output"
    return 0
  fi

  reason="$(<"$error_file")"
  rm -f "$error_file"
  [ -n "$reason" ] || reason="verification planner returned invalid output"
  verification_plan_unavailable_json intent "$reason"
}

build_verification_exact_plan_json() {
  local root="$1" script_dir="$2" base="$3" head="$4"
  local output reason error_file

  error_file="$(mktemp)"
  if output="$(node "$script_dir/verification-plan.mjs" --root "$root" --base "$base" --head "$head" 2>"$error_file")" \
    && jq -e 'type == "object" and (.matched_features | type) == "array"' >/dev/null 2>&1 <<< "$output"; then
    rm -f "$error_file"
    jq -c --arg head_sha "$head" '. + {status:"available",phase:"exact-head",head_sha:$head_sha}' <<< "$output"
    return 0
  fi

  reason="$(<"$error_file")"
  rm -f "$error_file"
  [ -n "$reason" ] || reason="verification planner could not build an exact-head plan"
  verification_plan_unavailable_json exact-head "$reason" "$head"
}
