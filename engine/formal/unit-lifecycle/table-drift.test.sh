#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ ! -f "$HERE/UnitLifecycle.tla" ]]; then
  echo 'DRIFT: run gen-edges.sh and paste between the markers' >&2
  exit 1
fi
if ! diff <(bash "$HERE/gen-edges.sh") <(sed -n '/BEGIN EDGES/,/END EDGES/p' "$HERE/UnitLifecycle.tla" | sed '1d;$d'); then
  echo 'DRIFT: run gen-edges.sh and paste between the markers' >&2
  exit 1
fi
stages="$(sed -n 's/^Stages == {\(.*\)}$/\1/p' "$HERE/UnitLifecycle.tla")"
edge_states="$(sed -n '/^Edges == {/,/^}$/p' "$HERE/UnitLifecycle.tla" | grep -oE '"[^"]+"' | tr -d '"')"
while IFS= read -r state; do
  [[ "$stages" == *"\"$state\""* ]] || { echo "DRIFT: edge uses undeclared stage $state" >&2; exit 1; }
done <<< "$edge_states"
