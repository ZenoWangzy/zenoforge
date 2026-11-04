#!/usr/bin/env bash
set -euo pipefail
usage() { echo 'usage: hf-supersede.sh [--dry-run] <remote-registry> <pr> <main-sha>' >&2; exit 2; }
dry=0
if [[ ${1:-} == --dry-run ]]; then dry=1; shift; fi
[[ $# == 3 && $1 == /* && $1 =~ ^[A-Za-z0-9_./-]+$ && $2 =~ ^[1-9][0-9]*$ && $3 =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || usage
registry=$1 pr=$2 sha=$3
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh"
config=$(zf_config_file hotfix.json) || { echo 'hf-supersede: hotfix.json unavailable' >&2; exit 1; }
jq -e '.apply_dist | (.host | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_.@-]*$")) and (.host_env | type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.repo_env | type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.repo_home_relative | type == "string" and test("^[A-Za-z0-9_./-]+$") and (startswith("/") | not)) and (.package_dir | type == "string" and test("^[A-Za-z0-9_./-]+$") and (startswith("/") | not)) and (.container_path | type == "string" and test("^/[A-Za-z0-9_./-]+$")) and ([.install,.build] | all(.[]; type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not))))' "$config" >/dev/null || { echo 'hf-supersede: invalid build configuration' >&2; exit 1; }
mapfile -t fields < <(jq -r '.apply_dist | .host,.host_env,.repo_env,.repo_home_relative,.package_dir,.container_path' "$config")
host=${fields[0]} host_env=${fields[1]} repo_env=${fields[2]} repo_relative=${fields[3]} package=${fields[4]} target=${fields[5]%/}
host=${!host_env:-$host}
repo=${!repo_env:-$HOME/$repo_relative}
[[ /$repo_relative/ != */../* && /$package/ != */../* && /$target/ != */../* ]] || { echo 'hf-supersede: invalid path' >&2; exit 1; }
mapfile -t install < <(jq -r '.apply_dist.install[]' "$config")
mapfile -t build < <(jq -r '.apply_dist.build[]' "$config")
git -C "$repo" fetch -q origin main
git -C "$repo" merge-base --is-ancestor "$sha" origin/main || { echo 'hf-supersede: SHA is not on main' >&2; exit 1; }
stage=
work=$(mktemp -d "${TMPDIR:-/tmp}/hf-supersede.XXXXXX")
cleanup() {
  git -C "$repo" worktree remove --force "$work/tree" >/dev/null 2>&1 || true
  rm -rf -- "$work"
  [[ -z $stage ]] || ssh -o ConnectTimeout=8 "$host" "rm -rf -- $stage" >/dev/null 2>&1 || true
}
trap cleanup EXIT
# This host has the product checkout and pnpm, so it builds; the production host has the containers and the
# registry, so it compares. Only the built dist crosses over (same split as hf-apply-dist.sh).
stage=$(ssh -o ConnectTimeout=8 "$host" bash -s -- "$registry" <<'STAGE'
set -euo pipefail
[[ -f $1 && -r $1 ]] || { echo "hf-supersede: registry is not a readable remote file: $1" >&2; exit 1; }
mktemp -d "${TMPDIR:-/tmp}/hf-supersede.XXXXXX"
STAGE
)
[[ $stage =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo 'hf-supersede: invalid remote staging directory' >&2; exit 1; }
git -C "$repo" worktree add -q --detach "$work/tree" "$sha"
(cd "$work/tree" && "${install[@]}" >/dev/null && "${build[@]}" >/dev/null)
tar -C "$work/tree/$package" -czf "$work/dist.tgz" dist
scp -q "$work/dist.tgz" "$host:$stage/dist.tgz"
# All remote arguments are validated shell-safe paths, identifiers or numbers.
ssh -o ConnectTimeout=8 "$host" "bash -s -- $pr $sha $registry $target $stage $dry" <<'REMOTE'
set -euo pipefail
pr=$1 sha=$2 registry=$3 target=$4 stage=$5 dry=$6
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/tree"
tar -C "$stage/tree" -xzf "$stage/dist.tgz"
remaining=0 matched=0 changed=0
: > "$stage/result"
cp -p -- "$registry" "$stage/original"
while :; do
  line=
  if IFS= read -r line; then newline=1; else newline=0; [[ -n $line ]] || break; fi
  tabs=${line//[^$'\t']/}
  IFS=$'\t' read -r container path carrier copy extra <<< "$line"
  if [[ ${#tabs} == 3 && $container != image && $carrier == "$pr" ]]; then
    matched=1
    [[ $container =~ ^[A-Za-z0-9_.-]+$ && $path == "$target/"* && /${path#"$target/"}/ != */../* && $copy == /* ]] || { echo "hf-supersede: invalid or out-of-scope row: $line" >&2; exit 1; }
    built="$stage/tree/dist/${path#"$target/"}"
    if [[ ! -f $built ]]; then
      printf 'DIFFERENT\t%s\t%s\n' "$container" "$path"; remaining=1
    elif ! docker exec "$container" cat -- "$path" > "$stage/live"; then
      echo "hf-supersede: cannot read $container:$path" >&2; exit 1
    elif cmp -s -- "$stage/live" "$built"; then
      printf 'IDENTICAL\t%s\t%s\n' "$container" "$path"
      line="$container"$'\t'"$path"$'\t'"carried_by=$sha"$'\t'"$copy"
      changed=1
    else
      printf 'DIFFERENT\t%s\t%s\n' "$container" "$path"; remaining=1
    fi
  fi
  if (( newline )); then printf '%s\n' "$line" >> "$stage/result"; else printf '%s' "$line" >> "$stage/result"; fi
done < "$stage/original"
(( matched )) || { echo 'hf-supersede: no matching PR rows' >&2; exit 1; }
if (( ! dry && changed )); then
  cmp -s -- "$registry" "$stage/original" || { echo 'hf-supersede: registry changed during comparison' >&2; exit 1; }
  backup=$(mktemp "${registry}.backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
  cp -p -- "$stage/original" "$backup"
  tmp=$(mktemp "${registry}.tmp.XXXXXX")
  cp -p -- "$registry" "$tmp"
  cat "$stage/result" > "$tmp"
  cmp -s -- "$registry" "$stage/original" || { rm -f -- "$tmp"; echo 'hf-supersede: registry changed during comparison' >&2; exit 1; }
  mv -f -- "$tmp" "$registry"
fi
(( remaining == 0 )) || exit 3
REMOTE
