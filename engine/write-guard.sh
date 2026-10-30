#!/usr/bin/env bash

agent_test_write_guard() {
  [[ "${ZF_AGENT_TEST_MODE:-0}" == 1 ]] || return 0
  local operation="${1:-pipeline write}" root="${ZF_AGENT_TEST_ROOT:-}" target root_real target_real
  shift || true
  if [[ -z "$root" || ! -d "$root" ]]; then
    printf '%s: test write guard: refusing write without isolated test root\n' "$operation" >&2
    return 1
  fi
  root_real="$(realpath -m -- "$root")" || return 1
  for target in "$@"; do
    [[ -n "$target" ]] || continue
    target_real="$(realpath -m -- "$target")" || return 1
    if [[ "$target_real" == "$root_real" || "$target_real" == "$root_real/"* ]]; then
      continue
    fi
    printf '%s: test write guard: refusing write outside isolated root (%s)\n' "$operation" "$target" >&2
    return 1
  done
}

agent_pipeline_write_guard() {
  local operation="${1:-pipeline write}" agent_home="${AGENT_HOME:-${ZF_HOME:-}}" expected_agent_home expected_checkout source_dir source_root source_root_real
  shift || true
  agent_test_write_guard "$operation" "$@" || return 1
  [[ "${ZF_AGENT_TEST_MODE:-0}" == 1 ]] && return 0
  if [[ -z "$agent_home" ]]; then
    agent_home="${HOME:-}/.zenoforge"
  fi
  # Only a live agent home (one with a runtime checkout) needs protecting. CI and
  # `AGENT_HOME="$(mktemp -d)"` preflights have none; refusing them broke every PR's
  # static-rulings step and every hand's check-rulings preflight on 2026-10-11.
  [[ -e "$agent_home/checkout" ]] || return 0
  if [[ -z "${_AGENT_WRITE_GUARD_SOURCE_ROOT+x}" ]]; then
    source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
    case "$source_dir" in
      # An engine installed by the zenoforge CLI lives in $AGENT_HOME/engine/<version>, outside the checkout it serves.
      "$(realpath -m -- "$agent_home")/engine/"*) _AGENT_WRITE_GUARD_SOURCE_ROOT="$agent_home/checkout" ;;
      # An engine deployed as an immutable version dir under $AGENT_HOME/engine-versions/<id> serves the checkout.
      "$(realpath -m -- "$agent_home")/engine-versions/"*) _AGENT_WRITE_GUARD_SOURCE_ROOT="$agent_home/checkout" ;;
      *) _AGENT_WRITE_GUARD_SOURCE_ROOT="$(git -C "$source_dir" rev-parse --show-toplevel 2>/dev/null || true)" ;;
    esac
    # An engine run from an immutable, non-git version directory has no toplevel: the repo it works on stands in.
    [[ -n "$_AGENT_WRITE_GUARD_SOURCE_ROOT" ]] || _AGENT_WRITE_GUARD_SOURCE_ROOT="${ZF_REPO_DIR:-}"
  fi
  source_root="${_AGENT_WRITE_GUARD_SOURCE_ROOT:-}"
  if [[ -z "$source_root" ]]; then
    printf '%s: test write guard: refusing write outside runtime checkout (expected %s, found unknown)\n' \
      "$operation" "$(realpath -m -- "$agent_home/checkout")" >&2
    return 1
  fi
  source_root_real="$(realpath -m -- "$source_root")" || return 1
  expected_agent_home="$(realpath -m -- "$agent_home")" || return 1
  expected_checkout="$(realpath -m -- "$agent_home/checkout")" || return 1
  if [[ "$source_root_real" != "$expected_checkout" || "${source_root_real%/*}" != "$expected_agent_home" ]]; then
    printf '%s: test write guard: refusing write outside runtime checkout (expected %s, found %s)\n' \
      "$operation" "$expected_checkout" "${source_root:-unknown}" >&2
    return 1
  fi
}
