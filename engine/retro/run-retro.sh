#!/usr/bin/env bash
# Unattended /retro run (slice 1): writes a candidates file only. Nothing is filed, labelled or landed.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine="$(cd -- "$here/.." && pwd -P)"
repo="$(cd -- "$engine/.." && pwd -P)"
root="${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}"
out_dir="${RETRO_OUT_DIR:-${HOME:-/tmp}/.zenoforge/retro}"
stamp="$(date -u +%Y%m%dT%H%MZ)"
key="retro-$stamp"
mkdir -p "$out_dir"
keys="$out_dir/$stamp.keys"
python3 -B "$here/retro.py" select "$root" 10 > "$keys"
[[ -s "$keys" ]] || { echo "run-retro: no finished worker sessions under $root/luna" >&2; exit 0; }
prompt="$out_dir/$stamp.prompt.md"
{
  cat "$engine/prompts/retro.md"
  echo
  echo "Sessions (events.jsonl has one JSON event per line; the line number is the event position):"
  while read -r k; do echo "- $k: $root/luna/$k/events.jsonl and $root/luna/$k/last.md"; done < "$keys"
} > "$prompt"
rc=0
"$engine/bin/luna" "$key" "$repo" "$prompt" "$engine/prompts/retro.schema.json" || rc=$?
raw="$root/luna/$key/last.md"
[[ -s "$raw" ]] || { echo "run-retro: $key wrote no output (luna rc=$rc)" >&2; exit 1; }
python3 -B "$here/retro.py" filter "$root" "$keys" "$raw" "$out_dir/$stamp.candidates.json"
