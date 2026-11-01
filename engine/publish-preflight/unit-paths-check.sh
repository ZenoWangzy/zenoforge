#!/usr/bin/env bash
# Fail if a new version drops an engine file still used by a unit or host-ops fallback.
# Unit Exec* paths under engine-live or checkout/scripts/agent are checked; host-ops paths are excluded.
set -uo pipefail
base=${1:?base version dir} new=${2:?new version dir} units=${3:-$HOME/.config/systemd/user}
[[ -d $base/engine && -d $new/engine ]] || { echo "unit-paths-check: missing engine dir" >&2; exit 2; }
missing=()
while IFS= read -r p; do
  [[ -e $base/engine/$p && ! -e $new/engine/$p ]] && missing+=("unit path: $p")
done < <(cat "$units"/*.service 2>/dev/null | grep -E '^Exec' | grep -oE '(engine-live|checkout/scripts/agent)"?\}?/[A-Za-z0-9_./-]+|\$\{e:-[^}]*\}/[A-Za-z0-9_./-]+' \
  | sed -E 's#^\$\{e:-[^}]*\}/##; s#^(engine-live|checkout/scripts/agent)"?\}?/##' | sort -u)
while IFS= read -r f; do
  [[ -n $(find "$base/engine" -name "$f" -print -quit) && -z $(find "$new/engine" -name "$f" -print -quit) ]] && missing+=("host-ops fallback: $f")
done < <({ grep -rhoE 'zf_host_ops_file "[^"]+" "[^"]+"' "$new/engine" | sed -E 's/.*" "([^"]+)"$/\1/'
  grep -rhoE '[A-Za-z_]*fallback="[^"]+"' "$new/engine"; } | grep -oE '[A-Za-z0-9_.-]+\.(sh|py|mjs|cjs|service|timer)"?$' | tr -d '"' | sort -u)
((${#missing[@]} == 0)) && { echo "unit-paths-check: OK"; exit 0; }
printf 'unit-paths-check: MISSING %s\n' "${missing[@]}" >&2
exit 1
