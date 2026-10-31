#!/usr/bin/env bash
# Dispatch build operations to the target repository's configured hook.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/config.sh"
config=$(zf_config_file build.json) || { echo 'engine-sync: build.json not found' >&2; exit 1; }
hook=$(jq -er '.hook | select(type == "string" and length > 0)' "$config")
engine=$(jq -er '.engine | select(type == "string" and length > 0)' "$config")
export ZF_BUILD_ENGINE="$engine"
exec "$ZF_REPO_DIR/$hook" "$@"
