#!/usr/bin/env bash
# Prepare a Vecta engine pin in an isolated worktree and run the publish preflight
# before choosing or entering a delivery lane.
set -euo pipefail

usage() {
  echo "usage: $0 <engine-sha> <vecta-checkout> [--land]" >&2
}

land=0
args=()
for arg in "$@"; do
  if [[ "$arg" == --land ]]; then land=1; else args+=("$arg"); fi
done
if ((${#args[@]} != 2)); then usage; exit 2; fi

requested_engine_sha=${args[0]}
target_input=${args[1]}
[[ -d "$target_input" ]] || { echo "pin-vecta: Vecta checkout not found: $target_input" >&2; exit 2; }
target=$(cd -- "$target_input" && pwd -P)
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
engine_repo=${ZF_LOCAL_CLONE:-$repo_root}
engine_repo=$(git -C "$engine_repo" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "pin-vecta: engine checkout is not a git repository: ${ZF_LOCAL_CLONE:-$repo_root}" >&2; exit 2; }

if [[ "$requested_engine_sha" =~ ^[0-9a-f]{40}$ ]]; then
  engine_sha=$requested_engine_sha
elif [[ "$requested_engine_sha" =~ ^[0-9a-f]{7,39}$ ]]; then
  engine_sha=$(git -C "$engine_repo" rev-parse --verify -q "$requested_engine_sha^{commit}") \
    || { echo "pin-vecta: short engine SHA is not available in $engine_repo; pass a full SHA" >&2; exit 2; }
else
  echo 'pin-vecta: engine SHA must be a full SHA or a 7–39 digit prefix' >&2
  exit 2
fi

command -v jq >/dev/null || { echo 'pin-vecta: jq is required' >&2; exit 2; }
gh_bin=${GH:-gh}
command -v -- "$gh_bin" >/dev/null || { echo 'pin-vecta: gh is required to read zenoforge main CI runs' >&2; exit 2; }
command -v systemd-run >/dev/null || { echo 'pin-vecta: systemd-run is required for bounded engine commands' >&2; exit 2; }
command -v timeout >/dev/null || { echo 'pin-vecta: timeout is required for bounded engine commands' >&2; exit 2; }
command -v mktemp >/dev/null || { echo 'pin-vecta: mktemp is required for a fresh output directory' >&2; exit 2; }

pin_override_names=()
if [[ -n "${ZF_PIN_OVERRIDE:-}" ]]; then
  case "$ZF_PIN_OVERRIDE" in
    ,*|*,|*,,*)
      echo 'pin-vecta: ZF_PIN_OVERRIDE must contain comma-separated workflow names' >&2
      exit 2
      ;;
  esac
  IFS=, read -r -a pin_override_names <<<"$ZF_PIN_OVERRIDE"
  for workflow_name in "${pin_override_names[@]}"; do
    case "$workflow_name" in
      engine-tests|cli-tests) ;;
      *)
        echo "pin-vecta: unsupported ZF_PIN_OVERRIDE workflow: $workflow_name (allowed: engine-tests, cli-tests)" >&2
        exit 2
        ;;
    esac
  done
fi

main_ci_runs=$("$gh_bin" api --paginate --slurp \
  "repos/ZenoWangzy/zenoforge/actions/runs?head_sha=$engine_sha&branch=main&per_page=100") \
  || { echo "pin-vecta: refusing pin: could not read zenoforge main CI runs for $engine_sha" >&2; exit 1; }
if ! jq -e 'type == "array" and length > 0 and all(.[];
    type == "object" and (.workflow_runs | type == "array") and all(.workflow_runs[];
      type == "object" and (.name | type == "string") and (.head_sha | type == "string")
      and has("head_branch") and (.head_branch == null or (.head_branch | type == "string"))
      and (.status | type == "string") and has("conclusion")
      and (.conclusion == null or (.conclusion | type == "string"))))' \
    <<<"$main_ci_runs" >/dev/null 2>&1; then
  echo "pin-vecta: refusing pin: could not read zenoforge main CI runs for $engine_sha as valid JSON" >&2
  exit 1
fi

failed_workflows=()
failed_workflow_output=$(jq -r --arg sha "$engine_sha" '[.[] | .workflow_runs[]
  | select(.head_sha == $sha and .head_branch == "main" and .status == "completed" and .conclusion == "failure"
      and (.name == "engine-tests" or .name == "cli-tests"))
  | .name] | unique[]' <<<"$main_ci_runs") \
  || { echo "pin-vecta: refusing pin: could not inspect zenoforge main CI runs for $engine_sha" >&2; exit 1; }
while IFS= read -r workflow_name; do
  [[ -n "$workflow_name" ]] && failed_workflows+=("$workflow_name")
done <<<"$failed_workflow_output"

if ((${#failed_workflows[@]})); then
  blocked_workflows=()
  overridden_workflows=()
  for failed_workflow in "${failed_workflows[@]}"; do
    matched=0
    for override_name in "${pin_override_names[@]}"; do
      if [[ "$failed_workflow" == "$override_name" ]]; then
        matched=1
        break
      fi
    done
    if ((matched)); then overridden_workflows+=("$failed_workflow"); else blocked_workflows+=("$failed_workflow"); fi
  done
  if ((${#blocked_workflows[@]})); then
    blocked_csv=$(IFS=,; printf '%s' "${blocked_workflows[*]}")
    echo "pin-vecta: refusing pin: failed zenoforge main workflows for $engine_sha: $blocked_csv; add only explicitly approved workflows to ZF_PIN_OVERRIDE=<workflow-name>[,<workflow-name>]" >&2
    exit 1
  fi
  if ((${#overridden_workflows[@]})); then
    overridden_csv=$(IFS=,; printf '%s' "${overridden_workflows[*]}")
    echo "pin-vecta: explicit ZF_PIN_OVERRIDE allows failed workflows: $overridden_csv" >&2
  fi
fi

git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1 \
  || { echo "pin-vecta: not a git checkout: $target" >&2; exit 2; }
[[ -z "$(git -C "$target" status --porcelain)" ]] \
  || { echo "pin-vecta: source checkout has changes; commit or clear them before preparing a fresh worktree" >&2; exit 2; }

build_rel=.zenoforge/build.json
git -C "$target" fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
origin_main=$(git -C "$target" rev-parse --verify refs/remotes/origin/main^{commit}) \
  || { echo 'pin-vecta: origin/main is unavailable' >&2; exit 2; }
source_head=$(git -C "$target" rev-parse --verify HEAD^{commit})
source_branch=$(git -C "$target" symbolic-ref --quiet --short HEAD || true)
start_head=$source_head
if [[ "$source_branch" == main ]] && git -C "$target" merge-base --is-ancestor "$source_head" "$origin_main"; then
  start_head=$origin_main
fi
merge_base=$(git -C "$target" merge-base "$origin_main" "$start_head") \
  || { echo 'pin-vecta: source branch and origin/main have no merge base' >&2; exit 2; }

base_config=$(git -C "$target" show "$start_head:$build_rel") \
  || { echo "pin-vecta: $build_rel is absent at $start_head" >&2; exit 2; }
hook=$(jq -er '.hook | select(type == "string" and length > 0)' <<<"$base_config") \
  || { echo "pin-vecta: $build_rel has no build hook" >&2; exit 2; }
old_engine_sha=$(jq -er '.engine | select(type == "string" and test("^[0-9a-f]{40}$"))' <<<"$base_config") \
  || { echo "pin-vecta: $build_rel has no full engine SHA" >&2; exit 2; }
overrides_rel="$(dirname -- "$hook")/overrides.tsv"
if [[ "$(jq -r '.engine' <<<"$base_config")" == "$engine_sha" ]]; then
  echo "pin-vecta: $build_rel already pins $engine_sha" >&2
  exit 1
fi

agent_home=${AGENT_HOME:-${ZF_HOME:-$HOME/.vecta-agent}}
live_engine_sync=${ZF_ENGINE_SYNC:-$agent_home/engine-live/engine-sync.sh}
if [[ "$live_engine_sync" != */* ]]; then
  live_engine_sync=$(command -v -- "$live_engine_sync") \
    || { echo "pin-vecta: engine-sync command not found: ${ZF_ENGINE_SYNC:-engine-sync}" >&2; exit 2; }
fi
[[ -f "$live_engine_sync" ]] || { echo "pin-vecta: live engine-sync is missing: $live_engine_sync" >&2; exit 2; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
short_sha=${engine_sha:0:12}
branch="chore/pin-vecta-$short_sha-$stamp"
worktree="$target/.worktrees/pin-vecta-$short_sha-$stamp"
mkdir -p -- "$target/.worktrees"
git -C "$target" worktree add -b "$branch" "$worktree" "$start_head"
[[ -f "$worktree/$hook" ]] || { echo "pin-vecta: build hook is missing at $start_head: $hook" >&2; exit 2; }

pin_tmp="$worktree/$build_rel.tmp.$$"
jq -c --arg engine "$engine_sha" '.engine = $engine' "$worktree/$build_rel" > "$pin_tmp"
mv -- "$pin_tmp" "$worktree/$build_rel"
git -C "$worktree" add -- "$build_rel"
if git -C "$worktree" diff --cached --quiet; then
  echo 'pin-vecta: pin produced no change' >&2
  exit 1
fi

direct_route=1
while IFS= read -r -d '' path; do
  case "$path" in
    .zenoforge/build.json|.zenoforge/build/intended-changes.tsv) ;;
    *) direct_route=0 ;;
  esac
done < <(git -C "$worktree" diff --cached --name-only -z "$merge_base")

if ((direct_route)); then
  commit_subject="[skip ci] chore(engine): pin zenoforge $short_sha"
  route=land-direct-main
else
  commit_subject="chore(engine): pin zenoforge $short_sha"
  route=PR
fi
git -C "$worktree" commit -m "$commit_subject"
head_sha=$(git -C "$worktree" rev-parse HEAD)

# Use a unique root per invocation: engine-sync output dirs are immutable and a
# repeat build under the same id would otherwise silently reuse the prior tree.
out_root=$(mktemp -d "${TMPDIR:-/tmp}/zf-pin-vecta-out.XXXXXXXX")
printf 'pin-vecta: worktree=%s\npin-vecta: out=%s\npin-vecta: branch=%s head=%s\n' \
  "$worktree" "$out_root" "$branch" "$head_sha"

run_bounded_step() { # <step> <command> [args...]
  local step="$1" status=0
  shift
  if env \
    ZF_REPO_DIR="$worktree" ZF_CONFIG_ROOT="$worktree/.zenoforge" \
    VECTA_REPO_DIR="$worktree" ZF_TARGET_CHECKOUT="$worktree" VECTA_DIR="$worktree" \
    AGENT_HOME="$agent_home" ZF_LOCAL_CLONE="$engine_repo" ZF_PREFLIGHT_LIVE_REF="$head_sha" \
    systemd-run --user --scope -p TasksMax=300 -p MemoryMax=2G -- timeout 600 "$@" \
      >"$out_root/$step.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  cat "$out_root/$step.log"
  return "$status"
}

build_status=0
run_bounded_step build "$live_engine_sync" --build "$engine_sha" "$head_sha" --out "$out_root" || build_status=$?

version_dirs=()
mapfile -t version_dirs < <(find "$out_root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print | LC_ALL=C sort)
version_dir="$out_root"
if ((${#version_dirs[@]} == 1)); then
  version_dir=${version_dirs[0]}
elif ((${#version_dirs[@]} > 1)); then
  echo "pin-vecta: build left ${#version_dirs[@]} version dirs; --check and --preflight will run against the fresh root and the pin will not be published" >&2
fi

check_status=0
run_bounded_step check "$live_engine_sync" --check "$version_dir" || check_status=$?

intended_file="$worktree/.zenoforge/build/intended-changes.tsv"
preflight_args=(--preflight "$version_dir")
[[ ! -f "$intended_file" ]] || preflight_args+=("$intended_file")
candidate_engine_sync="$version_dir/engine/engine-sync.sh"
preflight_runner=("$live_engine_sync" "${preflight_args[@]}")
if [[ -f "$candidate_engine_sync" ]]; then
  preflight_runner=(bash "$candidate_engine_sync" "${preflight_args[@]}")
fi
preflight_status=0
run_bounded_step preflight "${preflight_runner[@]}" || preflight_status=$?

print_override_diagnostics() {
  local table="$worktree/$overrides_rel" live_dir pack_map mismatch_file path expected actual orig pack_path diff_file lines_file pack_file shared_count changed_count
  [[ -f "$table" ]] || return 0
  live_dir=$(readlink -e -- "$agent_home/engine-live" 2>/dev/null || true)
  pack_map=''
  [[ -z "$live_dir" ]] || pack_map="$(dirname -- "$live_dir")/PACK-FILES"
  mismatch_file="$out_root/override-paths.$$.tmp"
  awk '/^override changed: / { sub(/^override changed: /, ""); sub(/;.*/, ""); print }' \
    "$out_root/build.log" | LC_ALL=C sort -u > "$mismatch_file"
  echo 'pin-vecta: override blob mismatch details:' >&2
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    expected=$(awk -F '\t' -v wanted="$path" '$1 == wanted { print $2; exit }' "$table")
    actual=$(git -C "$engine_repo" rev-parse --verify -q "$engine_sha:engine/$path" 2>/dev/null || true)
    [[ -n "$actual" && "$expected" == "$actual" ]] && continue
    printf '  %s expected=%s actual=%s\n' "$path" "${expected:-missing}" "${actual:-missing}" >&2
    orig=''
    if [[ -r "$pack_map" ]]; then
      orig=$(awk -F '\t' -v wanted="$path" '$2 == wanted { print $1; exit }' "$pack_map")
    fi
    pack_path=''
    if [[ -n "$orig" ]]; then pack_path=".zenoforge/build/pack/$orig"; fi
    pack_file="$out_root/pack-copy.$$.tmp"
    if [[ -z "$pack_path" ]] || ! git -C "$worktree" show "$head_sha:$pack_path" > "$pack_file" 2>/dev/null; then
      pack_path=".zenoforge/build/pack/scripts/agent/$path"
      if ! git -C "$worktree" show "$head_sha:$pack_path" > "$pack_file" 2>/dev/null; then
        printf '    pack copy shares changed lines: unknown (no PACK-FILES mapping or pack source)\n' >&2
        continue
      fi
    fi
    diff_file="$out_root/override-diff.$$.tmp"
    lines_file="$out_root/override-lines.$$.tmp"
    if ! git -C "$engine_repo" diff --no-ext-diff --unified=0 "$old_engine_sha" "$engine_sha" -- "engine/$path" > "$diff_file" 2>/dev/null; then
      printf '    pack copy shares changed lines: unknown (engine diff unavailable)\n' >&2
      continue
    fi
    grep -E '^[+-]' "$diff_file" | grep -Ev '^(\+\+\+|---)' > "$lines_file" || true
    shared_count=0
    changed_count=0
    while IFS= read -r line; do
      changed_count=$((changed_count + 1))
      line=${line:1}
      if grep -Fqx -- "$line" "$pack_file"; then shared_count=$((shared_count + 1)); fi
    done < "$lines_file"
    if ((changed_count == 0)); then
      printf '    pack copy shares changed lines: unknown (no textual diff)\n' >&2
    elif ((shared_count > 0)); then
      printf '    pack copy shares changed lines: yes (%s/%s lines; %s)\n' \
        "$shared_count" "$changed_count" "$pack_path" >&2
    else
      printf '    pack copy shares changed lines: no (0/%s lines; %s)\n' \
        "$changed_count" "$pack_path" >&2
    fi
  done < "$mismatch_file"
}

print_intended_rows() {
  local line detail path reason
  while IFS= read -r line; do
    [[ "$line" == 'resolved-config-check: CHANGED '* ]] || continue
    detail=${line#resolved-config-check: CHANGED }
    path=${detail%%: live *}
    [[ "$path" != "$detail" && -n "$path" ]] || continue
    reason="engine pin $short_sha changes resolved config"
    echo "pin-vecta: add this row to $intended_file and rerun:" >&2
    printf '%s\t%s\t%s\n' "$path" "$reason" "$engine_sha" >&2
  done < "$out_root/preflight.log"
}

if ((build_status != 0)) && { grep -q 'override guard failed\|override changed:' "$out_root/build.log"; }; then
  print_override_diagnostics
fi
if ((preflight_status != 0)); then print_intended_rows; fi

if ((build_status != 0 || check_status != 0 || preflight_status != 0)); then
  printf 'pin-vecta: refusing publication build_status=%s check_status=%s preflight_status=%s\n' \
    "$build_status" "$check_status" "$preflight_status" >&2
  exit 1
fi

if [[ "$(git -C "$worktree" rev-parse HEAD)" != "$head_sha" ]] \
  || [[ -n "$(git -C "$worktree" status --porcelain)" ]]; then
  echo 'pin-vecta: prepared worktree changed after publish preflight; refusing publication' >&2
  exit 1
fi

# Reclassify the committed diff. A hook that adds paths must not keep the
# precomputed route or its skip-ci commit subject.
final_route=direct
while IFS= read -r -d '' path; do
  case "$path" in
    .zenoforge/build.json|.zenoforge/build/intended-changes.tsv) ;;
    *) final_route=pr ;;
  esac
done < <(git -C "$worktree" diff --name-only -z "$merge_base" HEAD)
if { [[ "$final_route" == direct && "$route" != land-direct-main ]]; } \
  || { [[ "$final_route" == pr && "$route" != PR ]]; } \
  || { [[ "$final_route" == direct && "$commit_subject" != '[skip ci]'* ]]; } \
  || { [[ "$final_route" == pr && "$commit_subject" == '[skip ci]'* ]]; }; then
  echo 'pin-vecta: committed diff no longer matches the prepared delivery route; refusing publication' >&2
  exit 1
fi

printf 'pin-vecta: prepared route=%s branch=%s head=%s\n' "$route" "$branch" "$head_sha"
if ((land == 0)); then
  echo 'pin-vecta: stopped before pushing (pass --land to publish through the selected route)'
  exit 0
fi

# Both lanes resolve the repo and branch from the working directory.
cd -- "$worktree"
if [[ "$route" == land-direct-main ]]; then
  lander=${ZF_LAND_DIRECT_MAIN:-$agent_home/engine-live/land-direct-main.sh}
  [[ -f "$lander" ]] || { echo "pin-vecta: land-direct-main is missing: $lander" >&2; exit 2; }
  run_bounded_step land bash "$lander"
else
  delivery_preflight="$worktree/scripts/branch-delivery-preflight.mjs"
  [[ -f "$delivery_preflight" ]] \
    || { echo "pin-vecta: branch delivery preflight is missing: $delivery_preflight" >&2; exit 2; }
  run_bounded_step delivery node "$delivery_preflight" --mode push --publish-topic
  gh_bin=${GH:-gh}
  "$gh_bin" pr create --base main --head "$branch" \
    --title "chore(engine): pin zenoforge $short_sha" \
    --body "Pin the engine to $engine_sha. The build, check, and publish preflight passed before selecting the PR route."
fi
