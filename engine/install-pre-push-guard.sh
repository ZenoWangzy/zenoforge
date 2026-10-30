#!/usr/bin/env bash
set -euo pipefail

repo="${1:-}"
if [[ -z "$repo" ]]; then repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"; fi
repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo" ]] || exit 0

common_dir="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$common_dir" && "$common_dir" != /* ]]; then common_dir="$repo/$common_dir"; fi
common_dir="$(cd -- "$common_dir" 2>/dev/null && pwd -P)" || exit 0
hook="$common_dir/hooks/pre-push"
log_file="${ZF_PUSH_GUARD_LOG:-${AGENT_HOME:-${ZF_HOME:-${HOME:-$HOME}/.zenoforge}}/night/night.log}"
script="$(realpath -m -- "${BASH_SOURCE[0]}")"
tmp="$(mktemp -d 2>/dev/null || true)"
[[ -n "$tmp" ]] || exit 0
trap 'rm -rf -- "$tmp"' EXIT

log_drift() {
  local reason="$1" at line
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(printf '%s\0' "$at" hook-drift-removed "$reason" \
    | jq -Rsc 'split("\u0000") | {at:.[0],event:.[1],reason:.[2]}')"
  mkdir -p -- "$(dirname -- "$log_file")" 2>/dev/null || true
  printf '%s\n' "$line" >> "$log_file" 2>/dev/null || true
}

disable_drifted_hook() {
  local reason="$1"
  if [[ -e "$hook" || -L "$hook" ]]; then
    rm -f -- "$hook" 2>/dev/null || true
    log_drift "$reason"
  fi
}

pack_rel="${ZF_PACK_REL:-engine}"
# A published engine copy is transformed and cannot match the target repository blob byte for byte.
# The target copy still has to match origin/main before it may install that repository's hook.
if [[ -n "${ZF_ENGINE_DIR:-}" && "$script" != "$repo/$pack_rel/install-pre-push-guard.sh" \
    && "$script" == "$(realpath -m -- "$ZF_ENGINE_DIR/install-pre-push-guard.sh")" ]]; then
  script="$repo/$pack_rel/install-pre-push-guard.sh"
fi
main_installer="$tmp/main-installer.sh"
main_guard="$tmp/main-pre-push-guard.sh"
if ! git -C "$repo" show "origin/main:$pack_rel/install-pre-push-guard.sh" > "$main_installer" 2>/dev/null \
  || ! cmp -s -- "$script" "$main_installer"; then
  disable_drifted_hook installer-not-on-origin-main
  exit 0
fi
if ! git -C "$repo" show "origin/main:$pack_rel/pre-push-guard.sh" > "$main_guard" 2>/dev/null \
  || ! cmp -s -- "$repo/$pack_rel/pre-push-guard.sh" "$main_guard"; then
  disable_drifted_hook guard-not-on-origin-main
  exit 0
fi

mkdir -p -- "$common_dir/hooks" 2>/dev/null || {
  disable_drifted_hook hook-directory-unavailable
  exit 0
}
if [[ -e "$hook" || -L "$hook" ]] && ! cmp -s -- "$hook" "$main_guard"; then
  rm -f -- "$hook" 2>/dev/null || true
  log_drift installed-hook-differs-from-origin-main
fi
if [[ ! -e "$hook" && ! -L "$hook" ]]; then
  install_tmp="$hook.$$"
  if cp -- "$main_guard" "$install_tmp" && chmod 755 "$install_tmp" && mv -f -- "$install_tmp" "$hook"; then
    printf 'pre-push guard: installed hook from origin/main\n' >&2
  else
    rm -f -- "$install_tmp"
    log_drift hook-install-failed
  fi
fi
