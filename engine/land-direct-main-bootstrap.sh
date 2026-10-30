#!/usr/bin/env bash
set -euo pipefail

land_entry="$(realpath -- "${1:-}")"
shift
land_args=("$@")
repo_root="$(git rev-parse --show-toplevel)"

# Engine layout (Line B A2): the entry sits in the engine directory ZF_ENGINE_DIR outside the target repository, a
# published immutable version, so there is no entry commit to compare and no snapshot to take. An entry at
# <toplevel>/engine keeps the checks below, even when ZF_ENGINE_DIR names that directory. With ZF_ENGINE_DIR
# unset (env -i) the entry's own directory stands in for it when it holds config.sh.
land_engine_dir="${ZF_ENGINE_DIR:-}"
[[ -n "$land_engine_dir" || ! -f "${land_entry%/*}/config.sh" ]] || land_engine_dir="${land_entry%/*}"
land_engine_entry=0
if [[ -n "$land_engine_dir" && "${land_entry%/*}" == "$(realpath -- "$land_engine_dir" 2>/dev/null || true)" ]]; then
  land_code_root="$(git -C "${land_entry%/*}" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ "$land_entry" == "$land_code_root/engine/land-direct-main.sh" ]] || land_engine_entry=1
fi
if [[ "$land_engine_entry" == 1 ]]; then
  # The target repository supplies the branch-delivery policy; the engine directory supplies every script.
  land_code_root="$repo_root"
  land_driver_dir="${land_entry%/*}" land_lint_dir="${land_entry%/*}"
else
  land_code_root="$(git -C "${land_entry%/*}" rev-parse --show-toplevel)"
  land_driver_dir="$land_code_root/engine" land_lint_dir="$repo_root/engine"
  land_entry_rel="${land_entry#"$land_code_root"/}"
  [[ "$land_entry_rel" == engine/land-direct-main.sh ]] || {
    echo 'land-direct-main: startup entry is outside the canonical agent path' >&2
    exit 2
  }

  # Validate the invoking checkout before it changes the owner tree.
  land_entry_head="$(git -C "$land_code_root" rev-parse HEAD)"
  land_entry_ref='refs/remotes/origin/main'
  if ! git -C "$land_code_root" show-ref --verify --quiet "$land_entry_ref"; then
    echo "land-direct-main: canonical code source ref $land_entry_ref unavailable; refusing startup sync" >&2
    exit 2
  fi
  land_entry_source="$(git -C "$land_code_root" rev-parse --verify "${land_entry_ref}^{commit}")"
  if ! git -C "$land_code_root" show "$land_entry_head:engine/land-direct-main.sh" 2>/dev/null | cmp -s -- "$land_entry" - \
      && ! git -C "$land_code_root" show "$land_entry_source:engine/land-direct-main.sh" 2>/dev/null | cmp -s -- "$land_entry" -; then
    echo 'land-direct-main: entry differs from both its HEAD commit and origin/main; refusing startup sync' >&2
    exit 2
  fi
fi

branch="$(git -C "$repo_root" branch --show-current)"
[[ -n "$branch" ]] || { echo 'land-direct-main: run from a named branch' >&2; exit 2; }
[[ "$branch" != main ]] || { echo 'land-direct-main: run landings from a topic branch, never main' >&2; exit 2; }
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]]; then
  echo 'land-direct-main: tracked worktree changes must be committed before startup sync' >&2
  exit 1
fi

# Refuse obviously out-of-lane candidates before syncing. The same classification runs again after the sync, against the
# latest policy and rebased tree.
land_policy_source="$land_code_root/scripts/branch-delivery-policy.mjs"
if [[ -f "$land_policy_source" ]] \
    && git -C "$repo_root" show-ref --verify --quiet refs/remotes/origin/main; then
  land_early_paths="$(git -C "$repo_root" diff --name-only origin/main...HEAD)"
  if [[ -n "$land_early_paths" ]]; then
    land_early_paths_json="$(printf '%s\n' "$land_early_paths" | node -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => input += chunk);
      process.stdin.on("end", () => process.stdout.write(JSON.stringify(input.split(/\r?\n/).filter(Boolean))));
    ')"
    if ! land_early_classification="$(node "$land_policy_source" --classify-path-set - <<< "$land_early_paths_json")"; then
      echo 'land-direct-main: could not classify candidate before the startup sync' >&2
      exit 2
    fi
    if [[ "$land_early_classification" != eligible ]]; then
      echo 'Error: Landing fast path refuses product paths; use the product PR checks.' >&2
      printf 'Direct-main lane refusal: open a PR for out-of-lane paths:\n%s\n' \
        "$(sed 's/^/  /' <<< "$land_early_paths")" >&2
      exit 2
    fi
  fi
fi

agent_home="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
export AGENT_HOME="$agent_home"

land_snapshot=""
land_bootstrap_cleanup() {
  local status=$?
  trap - EXIT
  [[ -z "$land_snapshot" ]] || rm -rf -- "$land_snapshot"
  exit "$status"
}
trap land_bootstrap_cleanup EXIT

land_git_network() {
  local timeout_seconds="${ZF_LAND_GIT_TIMEOUT_SECONDS:-240}" status started_ms
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo 'land-direct-main: Git network timeout must be a positive integer' >&2
    return 2
  }
  started_ms="$(date +%s%3N)"
  if command timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" git -C "$repo_root" "$@"; then
    status=0
  else
    status=$?
  fi
  printf 'land-direct-main: bootstrap-git operation=%s duration_ms=%s status=%s deadline_seconds=%s\n' \
    "$1" "$(( $(date +%s%3N) - started_ms ))" "$status" "$timeout_seconds" >&2
  if [[ "$status" == 124 || "$status" == 137 ]]; then
    echo "land-direct-main: Operation timed out during $1 (deadline=${timeout_seconds}s)" >&2
    return 124
  fi
  return "$status"
}

land_transport_is_transient() {
  grep -qiE 'Authentication failed|Permission denied|response (401|403|407)|returned error: (401|403|407)' <<< "$1" \
    && return 1
  grep -qiE 'Proxy CONNECT aborted|CONNECT tunnel failed|failed to refresh available models.{0,160}(timed out|timeout)|GnuTLS.*(handshake failed|non-properly terminated)|TLS connection.*terminated|response 50[0-9]|HTTP[ /][0-9.]* 50[0-9]|returned error: 50[0-9]|TLS handshake timeout|connection (reset|timed out|refused)|Could not resolve (host|proxy)|Failed to connect|unexpected EOF|Operation timed out|GnuTLS recv error|No route to host|Network is unreachable' <<< "$1"
}

land_configure_git_identity() {
  local name="${ZF_AGENT_GIT_USER_NAME:-}" email="${ZF_AGENT_GIT_USER_EMAIL:-}" scope=--local
  [[ -n "$name" ]] || name="$(git -C "$repo_root" config --get user.name 2>/dev/null || true)"
  [[ -n "$email" ]] || email="$(git -C "$repo_root" config --get user.email 2>/dev/null || true)"
  if [[ -z "$name" || -z "$email" ]]; then
    echo 'land-direct-main: Git committer identity is missing; set ZF_AGENT_GIT_USER_NAME and ZF_AGENT_GIT_USER_EMAIL or repository Git config' >&2
    return 1
  fi
  if [[ "$(git -C "$repo_root" config --bool --get extensions.worktreeConfig 2>/dev/null || true)" == true ]]; then
    scope=--worktree
  fi
  if ! git -C "$repo_root" config "$scope" user.name "$name" \
      || ! git -C "$repo_root" config "$scope" user.email "$email" \
      || ! git -C "$repo_root" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    echo 'land-direct-main: could not persist a valid Git committer identity for this worktree' >&2
    return 1
  fi
}

land_git_rebase() {
  local source_driver="$land_driver_dir/git-merge-state-json.sh" driver attributes quoted_driver status
  [[ -x "$source_driver" ]] || { echo "land-direct-main: missing state JSON merge driver: $source_driver" >&2; return 1; }
  driver="$(mktemp "${TMPDIR:-/tmp}/zf-state-json-merge.XXXXXX")" || return 1
  attributes="$(mktemp "${TMPDIR:-/tmp}/zf-state-json-attributes.XXXXXX")" || { rm -f -- "$driver"; return 1; }
  if ! cp -- "$source_driver" "$driver"; then
    rm -f -- "$driver" "$attributes"
    return 1
  fi
  printf '%s\n' 'engine/state/*.json merge=statejson' > "$attributes"
  printf -v quoted_driver '%q' "$driver"
  if git -C "$repo_root" -c "core.attributesFile=$attributes" \
      -c "merge.statejson.driver=bash $quoted_driver %O %A %B" rebase "$@"; then
    status=0
  else
    status=$?
  fi
  rm -f -- "$driver" "$attributes"
  return "$status"
}

# Preserve the owner's recorded base before startup sync can replace it.
land_recorded_main_base="$(git -C "$repo_root" rev-parse --verify 'origin/main^{commit}' 2>/dev/null || true)"
if land_fetch_output="$(land_git_network fetch --no-tags -q origin main 2>&1)"; then
  printf '%s\n' "$land_fetch_output"
else
  printf '%s\n' "$land_fetch_output" >&2
  if land_transport_is_transient "$land_fetch_output"; then
    echo 'land-direct-main: transient transport failure; rerun the landing' >&2
  fi
  echo 'land-direct-main: could not fetch origin/main during startup sync' >&2
  exit 1
fi
land_main_base="$(git -C "$repo_root" rev-parse --verify 'origin/main^{commit}')"
if [[ -n "$land_recorded_main_base" ]] && ! git -C "$repo_root" merge-base --is-ancestor "$land_recorded_main_base" "$land_main_base"; then
  echo "land-direct-main: recorded origin/main base $land_recorded_main_base was rewritten off main (current=$land_main_base)" >&2
  exit 1
fi
if ! land_configure_git_identity || ! land_git_rebase "$land_main_base"; then
  echo 'land-direct-main: could not rebase onto origin/main during startup sync' >&2
  exit 1
fi
printf 'land-direct-main: bootstrap-synced base=%s head=%s\n' \
  "$land_main_base" "$(git -C "$repo_root" rev-parse HEAD)" >&2

# A candidate can predate this script. Synchronize it first so the current
# policy is present, then classify the rebased changes before any preflight or push.
if [[ ! -f "$repo_root/scripts/branch-delivery-policy.mjs" ]]; then
  echo 'land-direct-main: synchronized candidate lacks scripts/branch-delivery-policy.mjs; refusing direct-main landing' >&2
  exit 2
fi
pending_lesson_fragments="$(git -C "$repo_root" ls-tree -r --name-only HEAD -- lessons/pending \
  | awk '$0 ~ /^lessons\/pending\/[^/]+\.json$/')"
if git -C "$repo_root" merge-base --is-ancestor HEAD origin/main \
    && [[ -n "$pending_lesson_fragments" ]]; then
  # The child lander can fold fragments left on an already-landed head. Keep
  # this retry path in sync with its lane check below the bootstrap boundary.
  echo 'land-direct-main: allowing already-landed head to retry pending lesson fold' >&2
elif ! (cd -- "$repo_root" && node scripts/branch-delivery-policy.mjs --check-direct-main-lane); then
  echo 'land-direct-main: synchronized candidate does not qualify for direct-main delivery' >&2
  exit 2
fi

# Lesson recurrence lint runs against the rebased candidate before the canonical
# main snapshot starts landing it, so its verdict is retained in this landing log.
node "$land_lint_dir/supervisor-hold-lesson-lint.mjs" \
  --repo "$repo_root" --base "$land_main_base" --head HEAD

# The remaining recurrence >= 2 lesson lints (#4503) share the same contract.
node "$land_lint_dir/lesson-lints.mjs" \
  --repo "$repo_root" --base "$land_main_base" --head HEAD

land_agent_home="$agent_home"
land_guard_source_root="$land_code_root"
if [[ -e "$land_agent_home/checkout" ]]; then
  land_guard_source_root="$land_agent_home/checkout"
fi
if [[ "$land_engine_entry" == 1 ]]; then
  # land_snapshot stays empty: the exit trap removes it, and the engine directory is not ours to remove.
  land_child_marker="${land_entry%/*}" land_child_dir="${land_entry%/*}"
else
  land_snapshot="$(mktemp -d "${TMPDIR:-/tmp}/zf-land-code.XXXXXX")"
  if [[ "$(git -C "$repo_root" cat-file -t "$land_main_base:engine/land-direct-main.sh" 2>/dev/null || true)" != blob ]]; then
    echo "land-direct-main: synchronized main $land_main_base lacks the lander entry" >&2
    exit 2
  fi
  if ! git -C "$repo_root" archive "$land_main_base" engine | tar -x -C "$land_snapshot"; then
    echo 'land-direct-main: could not snapshot synchronized main' >&2
    exit 1
  fi
  land_child_marker="$land_snapshot" land_child_dir="$land_snapshot/engine"
fi

# The snapshot child is the lander; it fetches, rebases and pushes with the main ref as its only
# serialisation point.
env \
  "_AGENT_WRITE_GUARD_SOURCE_ROOT=$land_guard_source_root" \
  "ZF_LAND_STATE_JSON_MERGE_DRIVER=$land_driver_dir/git-merge-state-json.sh" \
  "ZF_LAND_CODE_SNAPSHOT=$land_child_marker" \
  "ZF_LAND_CODE_SOURCE_ROOT=$repo_root" \
  "ZF_LAND_CODE_SOURCE_OID=$land_main_base" \
  "ZF_REPO_DIR=${ZF_REPO_DIR:-$repo_root}" \
  "ZF_EXECUTION_MODULE_DIR=$land_child_dir" \
  "ZF_SYSTEMD_RUN_REAL=" \
  bash "$land_child_dir/land-direct-main.sh" "${land_args[@]}"
