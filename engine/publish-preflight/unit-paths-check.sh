#!/usr/bin/env bash
# Fail if a new version drops an engine file still used by a unit or host-ops fallback.
# Unit Exec* paths under engine-live or checkout/scripts/agent are checked; host-ops paths are excluded.
set -uo pipefail
base=${1:?base version dir} new=${2:?new version dir} units=${3:-$HOME/.config/systemd/user}
[[ -d $base/engine && -d $new/engine ]] || { echo "unit-paths-check: missing engine dir" >&2; exit 2; }
# grep exit 1 means no match; anything above means the scan itself failed, which must not read as "nothing missing".
g() { grep "$@"; local rc=$?; ((rc <= 1)) || { echo "unit-paths-check: scan failed: grep $*" >&2; exit 2; }; }
# An explicit unit dir must exist; the default one may be absent on a host without user units. Unreadable fails.
if [[ -n ${3-} || -e $units ]]; then
  [[ -d $units && -r $units && -x $units ]] || { echo "unit-paths-check: unit dir not readable: $units" >&2; exit 2; }
fi
shopt -s nullglob
unit_files=("$units"/*.service)
exec_lines=''
if ((${#unit_files[@]})); then
  exec_lines=$(g -hE '^Exec' -- "${unit_files[@]}") || exit 2
fi
unit_paths=$(printf '%s\n' "$exec_lines" | g -oE '(engine-live|checkout/scripts/agent)"?\}?/[A-Za-z0-9_./-]+|\$\{e:-[^}]*\}/[A-Za-z0-9_./-]+' \
  | sed -E 's#^\$\{e:-[^}]*\}/##; s#^(engine-live|checkout/scripts/agent)"?\}?/##' | sort -u) || exit 2
fallbacks=$( { g -rhoE 'zf_host_ops_file "[^"]+" "[^"]+"' "$new/engine" | sed -E 's/.*" "([^"]+)"$/\1/' || exit 2
  g -rhoE '[A-Za-z_]*fallback="[^"]+"' "$new/engine"; } | g -oE '[A-Za-z0-9_.-]+\.(sh|py|mjs|cjs|service|timer)"?$' | tr -d '"' | sort -u) || exit 2
missing=()
while IFS= read -r p; do
  [[ -n $p && -e $base/engine/$p && ! -e $new/engine/$p ]] && missing+=("unit path: $p")
done <<< "$unit_paths"
while IFS= read -r f; do
  [[ -n $f && -n $(find "$base/engine" -name "$f" -print -quit) && -z $(find "$new/engine" -name "$f" -print -quit) ]] && missing+=("host-ops fallback: $f")
done <<< "$fallbacks"
((${#missing[@]} == 0)) && { echo "unit-paths-check: OK"; exit 0; }
printf 'unit-paths-check: MISSING %s\n' "${missing[@]}" >&2
exit 1
