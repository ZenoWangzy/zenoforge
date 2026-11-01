#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ZF_ENGINE_DIR="$SCRIPT_DIR"

die() {
  printf 'run-release: %s\n' "$*" >&2
  exit 1
}

# Resolve config in a subshell so config.sh's defaults do not become part of
# the target runner's startup environment.
if ! dispatch_context="$(
  set -euo pipefail
  export ZF_ENGINE_DIR="$SCRIPT_DIR"
  source "$SCRIPT_DIR/config.sh"

  release_config="$ZF_CONFIG_ROOT/release.json"
  [[ -f "$release_config" ]] || {
    printf 'run-release: release.json is missing: %s\n' "$release_config" >&2
    exit 1
  }
  jq -e . "$release_config" >/dev/null 2>&1 || {
    printf 'run-release: release.json is invalid: %s\n' "$release_config" >&2
    exit 1
  }
  runner_rel="$(jq -er '.release.runner | select(type == "string" and length > 0)' "$release_config" 2>/dev/null)" || {
    printf 'run-release: release.json has no configured release.runner: %s\n' "$release_config" >&2
    exit 1
  }
  case "$runner_rel" in
    /*|*\\*|..|../*|*/../*|*/..)
      printf 'run-release: release.json has an invalid runner path: %s\n' "$runner_rel" >&2
      exit 1
      ;;
  esac
  runner="$ZF_REPO_DIR/$runner_rel"
  printf '%s\n%s\n%s\n' "$ZF_REPO_DIR" "$ZF_CONFIG_ROOT" "$runner"
)"; then
  exit 1
fi
context_fields=()
mapfile -t context_fields <<< "$dispatch_context"
[[ ${#context_fields[@]} -eq 3 ]] || die 'could not resolve release runner configuration'
ZF_CONFIG_ROOT="${context_fields[1]}"
runner="${context_fields[2]}"
export ZF_ENGINE_DIR ZF_CONFIG_ROOT

[[ "$runner" -ef "$SCRIPT_DIR/run-release.sh" ]] && die 'release.json points back to the engine dispatcher'
[[ -f "$runner" && -x "$runner" ]] || die "configured runner is not a regular executable file: $runner"
exec "$runner" "$@"
