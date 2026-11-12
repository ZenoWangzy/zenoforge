#!/usr/bin/env bash
# Read-only: print which config layer wins. No argument: every overriding file, then the ZF_/prefix environment.
# One <relative path> argument: its target, pack and engine copies and the winner.
set -euo pipefail
# config.sh writes the host-id file when ZF_HOST_ID is unset; a placeholder keeps this command read-only.
: "${ZF_HOST_ID:=config-dump}"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/config.sh"

layer_names=(target pack engine)

# resolve <relative path>: sets layer_paths (path or -, in layer order) and winner (index, -1 for none).
# The winner is whatever zf_config_file returns; this function only matches that answer to a layer.
resolve() {
  local rc=0 chosen i p
  chosen="$(zf_config_file "$1")" || rc=$?
  (( rc != 2 )) || return 2
  layer_paths=(- - -) winner=-1
  if [[ -n ${ZF_CONFIG_ROOT-} && -f "$ZF_CONFIG_ROOT/$1" ]]; then layer_paths[0]="$ZF_CONFIG_ROOT/$1"; fi
  if p="$(pack_file "$1")"; then layer_paths[1]="$p"; fi
  if [[ -f "$ZF_ENGINE_DIR/$1" ]]; then layer_paths[2]="$ZF_ENGINE_DIR/$1"; fi
  (( rc == 0 )) || return 0
  for i in 2 1 0; do
    if [[ ${layer_paths[i]} == "$chosen" ]]; then winner=$i; fi
  done
}

# Relative paths of the files below $1; with $2, only those that also exist below $2.
list_files() {
  local f
  [[ -d $1 ]] || return 0
  while IFS= read -r -d '' f; do
    if [[ -z ${2-} ]] || [[ -f "$2/${f#./}" ]]; then printf '%s\n' "${f#./}"; fi
  done < <(cd -- "$1" && find -L . -type f -print0 2>/dev/null)
}

env_names() {
  local v prefix=
  # Same lookup as zf_env_get: .env_prefix of config.json.
  if [[ -n ${ZF_CONFIG_ROOT-} && -f "$ZF_CONFIG_ROOT/config.json" ]]; then
    prefix="$(jq -r 'if type == "object" and (.env_prefix | type) == "string" then .env_prefix else "" end' \
      "$ZF_CONFIG_ROOT/config.json" 2>/dev/null)" || prefix=
  fi
  while IFS= read -r v; do
    if [[ -n $prefix && $v == "$prefix"* ]]; then printf '%s\n' "${v#"$prefix"}"
    elif [[ $v == ZF_* ]]; then printf '%s\n' "${v#ZF_}"; fi
  done < <(compgen -e)
}

if (( $# > 1 )); then echo 'usage: config-dump.sh [relative-path]' >&2; exit 2; fi

if (( $# == 1 )); then
  resolve "$1" || { echo "config-dump: refused path: $1" >&2; exit 2; }
  for i in 0 1 2; do
    mark=; if (( i == winner )); then mark=winner; fi
    printf '%s\t%s\t%s\n' "${layer_names[i]}" "${layer_paths[i]}" "$mark"
  done
  exit 0
fi

while IFS= read -r rel; do
  resolve "$rel"
  (( winner == 0 || winner == 1 )) || continue
  shadowed=
  for i in 0 1 2; do
    if (( i != winner )) && [[ ${layer_paths[i]} != - ]]; then shadowed+="${shadowed:+,}${layer_names[i]}"; fi
  done
  printf '%s\t%s\t%s\n' "$rel" "${layer_names[winner]}" "${shadowed:--}"
done < <({ list_files "${ZF_CONFIG_ROOT-}"; list_files "${ZF_PACK_DIR-}" "$ZF_ENGINE_DIR"; } | LC_ALL=C sort -u)

echo
while IFS= read -r name; do
  value="$(zf_env_get "$name" 2>/dev/null)" || continue
  source_name=ZF extra=
  # With the public variable unset, only a prefixed one can still answer, so a hit means the prefix won.
  if (unset -v "ZF_$name"; zf_env_get "$name" >/dev/null 2>&1); then
    source_name=prefix
    public="ZF_$name"
    if [[ -n ${!public+x} ]]; then extra="shadows $public"; fi
  fi
  case $name in *TOKEN*|*SECRET*|*KEY*|*PASSWORD*|*CREDENTIAL*) value='<set>' ;; esac
  printf '%s\t%s\t%s%s\n' "$name" "$source_name" "$value" "${extra:+$'\t'$extra}"
done < <(env_names | LC_ALL=C sort -u)
