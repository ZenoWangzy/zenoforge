#!/usr/bin/env bash
# Dispatch build operations to the target repository's configured hook.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/config.sh"
config=$(zf_config_file build.json) || { echo 'engine-sync: build.json not found' >&2; exit 1; }
hook=$(jq -er '.hook | select(type == "string" and length > 0)' "$config")
engine=$(jq -er '.engine | select(type == "string" and length > 0)' "$config")
export ZF_BUILD_ENGINE="$engine"
if [[ "${1:-}" == --preflight ]]; then
  shift
  if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && -z "$2" ) ]]; then
    echo "usage: engine-sync.sh --preflight <new version dir> [intended-change list]" >&2
    exit 2
  fi
  new_version_dir=$(cd -- "$1" 2>/dev/null && pwd -P) || {
    echo "engine-sync: new version directory not found: $1" >&2
    exit 1
  }
  live_engine_dir=$(readlink -e -- "$AGENT_HOME/engine-live") || {
    echo "engine-sync: cannot resolve $AGENT_HOME/engine-live" >&2
    exit 1
  }
  live_version_dir=$(dirname -- "$live_engine_dir")
  [[ -d "$live_engine_dir" && -d "$new_version_dir/engine" ]] || {
    echo "engine-sync: preflight expects engine directories in the live and new versions" >&2
    exit 1
  }
  # Compare against the target commit each version was built from: at converge time HEAD is already the new commit.
  # A hook that knows the commit the live checkout ran can pass it in ZF_PREFLIGHT_LIVE_REF.
  build_ref() { sed -n -e 's/^product_sha=//p' -e 's/^pack_sha=\([0-9a-f]*\):.*/\1/p' "$1/BUILD-INFO" 2>/dev/null | head -n 1; }
  live_ref=${ZF_PREFLIGHT_LIVE_REF:-$(build_ref "$live_version_dir")}
  new_ref=$(build_ref "$new_version_dir")
  [[ -n "$live_ref" ]] || { echo "engine-sync: cannot tell which target commit the live version ran; set ZF_PREFLIGHT_LIVE_REF" >&2; exit 1; }
  preflight_args=("$live_version_dir" "$new_version_dir" "$ZF_REPO_DIR" "$live_ref" "${new_ref:-HEAD}")
  [[ $# -eq 1 ]] || preflight_args+=("$2")
  exec bash "$here/publish-preflight/run.sh" "${preflight_args[@]}"
fi
exec "$ZF_REPO_DIR/$hook" "$@"
