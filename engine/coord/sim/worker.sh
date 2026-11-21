#!/usr/bin/env bash
set -euo pipefail
source "$SIM_HARNESS_DIR/lib.sh"

sim_claim_ref() { printf 'refs/claims/%s\n' "$1"; }

sim_ref_oid() {
  local output
  output="$(git -C "$SIM_HOST_REPO" ls-remote --refs origin "$1")"
  awk 'NR == 1 { print $1 }' <<< "$output"
}

sim_read_ref() {
  local oid
  git -C "$SIM_HOST_REPO" fetch --quiet origin "$1" >/dev/null 2>&1
  oid="$(git -C "$SIM_HOST_REPO" rev-parse --verify FETCH_HEAD)"
  git -C "$SIM_HOST_REPO" cat-file blob "$oid"
}

sim_write_ref() {
  local ref="$1" expected="$2" payload="$3" blob
  blob="$(printf '%s\n' "$payload" | git -C "$SIM_HOST_REPO" hash-object -w --stdin)"
  git -C "$SIM_HOST_REPO" push --quiet --force-with-lease="$ref:$expected" origin "$blob:$ref"
}

sim_dispatch_log() {
  exec 9>>"$SIM_WORLD/dispatch.log"
  flock -x 9
  printf '%s\t%s\t%s\n' "$1" "$2" "$SIM_HOST_ID" >&9
}

sim_race_barrier() {
  [[ -n ${SIM_RACE_DIR:-} ]] || return 0
  mkdir -p -- "$SIM_RACE_DIR"
  : > "$SIM_RACE_DIR/$SIM_HOST_ID.ready"
  local attempt
  for ((attempt = 0; attempt < 1000; attempt++)); do
    [[ -e $SIM_RACE_DIR/go ]] && return 0
    sleep 0.01
  done
  echo "race barrier timed out for $SIM_HOST_ID" >&2
  return 1
}

sim_claim_payload() {
  jq -cn --arg ticket "$1" --arg stage "$2" --arg owner "$SIM_HOST_ID" \
    --argjson generation "$3" --argjson expires_at "$4" \
    '{ticket:$ticket,stage:$stage,owner:$owner,generation:$generation,expires_at:$expires_at}'
}

sim_dispatch() {
  local ticket="$1" stage="$2" ref oid payload
  ref="$(sim_claim_ref "$ticket")"
  oid="$(sim_ref_oid "$ref")"
  if [[ -n $oid ]]; then
    printf '%s already claimed\n' "$ticket"
    return 0
  fi
  sim_race_barrier
  payload="$(sim_claim_payload "$ticket" "$stage" 1 "$(($(sim_now) + SIM_LEASE_S))")"
  if sim_write_ref "$ref" '' "$payload" 2>"$SIM_HOST_DIR/push.err"; then
    sim_dispatch_log "$ticket" "$stage"
    printf '%s dispatched by %s\n' "$ticket" "$SIM_HOST_ID"
    return 0
  fi
  payload="$(sim_read_ref "$ref")"
  [[ $(jq -r '.owner' <<< "$payload") != "$SIM_HOST_ID" ]] || {
    cat "$SIM_HOST_DIR/push.err" >&2
    return 1
  }
  printf '%s lost race to %s\n' "$ticket" "$(jq -r '.owner' <<< "$payload")"
}

sim_hold_claim() {
  local ticket="$1" stage="$2" ref payload
  ref="$(sim_claim_ref "$ticket")"
  [[ -z $(sim_ref_oid "$ref") ]] || { echo "$ticket already has a claim" >&2; return 1; }
  payload="$(sim_claim_payload "$ticket" "$stage" 1 "$(($(sim_now) + SIM_LEASE_S))")"
  sim_write_ref "$ref" '' "$payload"
  : "${SIM_HOLD_READY:?hold requires SIM_HOLD_READY}"
  : "${SIM_HOLD_RELEASE:?hold requires SIM_HOLD_RELEASE}"
  : > "$SIM_HOLD_READY"
  while [[ ! -e $SIM_HOLD_RELEASE ]]; do sleep 0.02; done
}

sim_takeover() {
  local ticket="$1" stage="$2" ref old_oid payload owner expires now generation updated
  ref="$(sim_claim_ref "$ticket")"
  old_oid="$(sim_ref_oid "$ref")"
  [[ -n $old_oid ]] || { echo "$ticket has no claim to take over" >&2; return 1; }
  payload="$(sim_read_ref "$ref")"
  owner="$(jq -r '.owner' <<< "$payload")"
  expires="$(jq -r '.expires_at' <<< "$payload")"
  now="$(sim_now)"
  [[ $owner != "$SIM_HOST_ID" && $expires =~ ^[0-9]+$ && $now -ge $expires ]] || {
    echo "$ticket claim is not eligible for takeover" >&2
    return 1
  }
  generation="$(jq -r '.generation' <<< "$payload")"
  [[ $generation =~ ^[0-9]+$ ]] || { echo "$ticket claim has invalid generation" >&2; return 1; }
  updated="$(jq -c --arg owner "$SIM_HOST_ID" --argjson generation "$((generation + 1))" \
    --argjson expires_at "$((now + SIM_LEASE_S))" \
    '.owner=$owner | .generation=$generation | .expires_at=$expires_at' <<< "$payload")"
  sim_write_ref "$ref" "$old_oid" "$updated"
  sim_dispatch_log "$ticket" "$stage"
  printf '%s taken over by %s\n' "$ticket" "$SIM_HOST_ID"
}

sim_publish_status() {
  local instance caps payload ref old_oid
  source "$SIM_ENGINE_DIR/coord/status.sh"
  instance="$(<"$SIM_HOST_DIR/instance")"
  caps='{"os":"linux","arch":"sim","wsl":false,"cpus":1,"mem_mb":1,"cli":{}}'
  payload="$(ZF_COORD=on status_record "$SIM_HOST_ID" "$instance" "$(sim_now)" "$caps")"
  ref="refs/status/$SIM_HOST_ID"
  old_oid="$(sim_ref_oid "$ref")"
  sim_write_ref "$ref" "$old_oid" "$payload"
}

case "${1:-}" in
  dispatch) shift; sim_dispatch "${1:?ticket required}" "${2:?stage required}" ;;
  hold) shift; sim_hold_claim "${1:?ticket required}" "${2:?stage required}" ;;
  takeover) shift; sim_takeover "${1:?ticket required}" "${2:?stage required}" ;;
  status) sim_publish_status ;;
  *) echo 'usage: worker.sh {dispatch|hold|takeover|status} [ticket stage]' >&2; exit 2 ;;
esac
