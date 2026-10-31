#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh"
config=$(zf_config_file hotfix.json) || {
  legacy=$(pack_file hotfix/hf-apply-dist.sh) && exec bash "$legacy" "$@"
  echo 'hf-apply-dist: configure distribution installation in hotfix.json' >&2; exit 1
}
(($# == 3)) && [[ $1 =~ ^[0-9a-f]{7,40}$ && $2 =~ ^[a-z0-9-]+$ && -f $3 ]] || { echo 'usage: hf-apply-dist.sh <main-sha> <tag> <coord.md>' >&2; exit 2; }
if ! jq -e '.apply_dist | type == "object" and ([.host,.host_env,.repo_env,.release_unit,.backup_root,.coord_root,.registry,.package_dir,.container_path,.repo_home_relative] | all(.[]; type == "string" and test("^[A-Za-z0-9_./@-]+$"))) and ([.host_env,.repo_env] | all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*$"))) and ([.backup_root,.coord_root,.registry,.container_path] | all(.[]; startswith("/"))) and ([.package_dir,.repo_home_relative] | all(.[]; startswith("/") | not)) and (.containers | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$"))) and ([.install,.build,.restart] | all(.[]; type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not))))' "$config" >/dev/null; then
  echo 'hf-apply-dist: invalid distribution installation configuration' >&2; exit 1
fi
mapfile -t fields < <(jq -r '.apply_dist | .host,.host_env,.repo_env,.release_unit,.backup_root,.coord_root,.registry,.package_dir,.container_path,.repo_home_relative' "$config")
read -r host host_env repo_env unit backup coord_root registry package_dir target repo_home_relative < <(printf '%s ' "${fields[@]}"; printf '\n')
host=${!host_env:-$host}; repo=${!repo_env:-$HOME/$repo_home_relative}
[[ $host =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ && $unit =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ && /$package_dir/ != */../* && /$repo_home_relative/ != */../* ]] || { echo 'hf-apply-dist: invalid host or package path' >&2; exit 1; }
mapfile -t containers < <(jq -r '.apply_dist.containers[]' "$config")
mapfile -t install < <(jq -r '.apply_dist.install[]' "$config")
mapfile -t build < <(jq -r '.apply_dist.build[]' "$config")
mapfile -t restart < <(jq -r '.apply_dist.restart[]' "$config")
sha=$1 tag=$2 coord=$3
! systemctl --user is-active --quiet "$unit" || { echo 'hf-apply-dist: release is active; hold' >&2; exit 1; }
git -C "$repo" fetch -q origin main
if git -C "$repo" merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
  main_sha=$(git -C "$repo" rev-parse --verify "$sha^{commit}")
else
  main_sha=$(unset GH_TOKEN; gh pr list --label hotfix --state open --json number,headRefOid -q ".[] | select(.headRefOid | startswith(\"$sha\")) | .number" | head -1)
  [[ $main_sha =~ ^[0-9]+$ ]] || { echo "hf-apply-dist: $sha is neither on origin/main nor an open hotfix PR head" >&2; exit 1; }
  git -C "$repo" fetch -q origin "pull/$main_sha/head"
fi
[[ $main_sha =~ ^[0-9a-f]{40,64}$ || $main_sha =~ ^[0-9]+$ ]] || { echo 'hf-apply-dist: invalid source revision' >&2; exit 1; }
mkdir -p "${PREPUSH_TMP:=$HOME/.cache/zf-prepush}"
work=$(mktemp -d -p "$PREPUSH_TMP")
trap 'git -C "$repo" worktree remove --force "$work/tree" >/dev/null 2>&1 || true; [[ ! -f $work/dist.tgz ]] || unlink "$work/dist.tgz"; rmdir "$work" 2>/dev/null || true' EXIT
git -C "$repo" worktree add -q --detach "$work/tree" "$sha"
(cd "$work/tree" && "${install[@]}" >/dev/null && "${build[@]}" >/dev/null)
tar -C "$work/tree/$package_dir" -czf "$work/dist.tgz" dist
scp -q "$work/dist.tgz" "$host:$backup/$tag-dist.tgz"
scp -q "$here/register-release-drift-carried.sh" "$host:$backup/$tag-register-release-drift-carried.sh"
scp -q "$coord" "$host:$coord_root/COORD-$(date -u +%Y%m%d)-hotfix-$tag.md"
# All remote arguments are validated shell-safe identifiers or paths.
ssh -o ConnectTimeout=8 "$host" "bash -s -- $tag $main_sha $backup $registry $target ${containers[*]}" <<'REMOTE'
set -euo pipefail
tag=$1 revision=$2 backup=$3 registry=$4 target=$5; shift 5
B=$backup/$tag-$(date -u +%Y%m%dT%H%MZ); S=$B/stage
R=$backup/$tag-register-release-drift-carried.sh
mkdir -p "$S"; tar -C "$S" -xzf "$backup/$tag-dist.tgz"
for c in "$@"; do
  mkdir -p "$B/$c"; docker cp "$c:$target" "$B/$c/dist"
  docker cp "$S/dist/." "$c:$target/"
  while IFS= read -r -d '' staged_file; do
    relative=${staged_file#"$S/dist/"}
    container_path=$target/$relative
    old_file=$B/$c/dist/$relative
    [[ -f "$old_file" ]] && cmp -s -- "$old_file" "$staged_file" && continue
    installed_copy=$B/$c/installed-from-main/$relative
    mkdir -p -- "$(dirname -- "$installed_copy")"
    docker cp "$c:$container_path" "$installed_copy"
    bash "$R" "$registry" "$c" "$container_path" "$revision" "$installed_copy"
  done < <(find "$S/dist" -type f -print0)
done
echo "backup=$B"
REMOTE
for c in "${containers[@]}"; do (cd "$repo" && "${restart[@]}" "$c"); done
HF_SHA=$sha bash "$here/hf-accept.sh"
