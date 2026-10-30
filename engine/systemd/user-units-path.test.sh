#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../test-env.sh"
# WSL user units run pipeline scripts that call jq/gh from ~/.local/bin, which
# the systemd user manager's default PATH lacks (marker sync failed every run
# from 2026-10-08 until it set PATH).
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bad=0
for unit in "$dir"/*.service; do
  grep -q '^ExecStart=.*/\.zenoforge/checkout/engine/' "$unit" || continue
  grep -Eq '^Environment=PATH=($HOME|%h)/\.local/bin:' "$unit" && continue
  echo "FAIL: ${unit##*/} runs a checkout script without Environment=PATH including ~/.local/bin" >&2
  bad=1
done
((bad == 0)) && echo "PASS user-units-path"
exit "$bad"
