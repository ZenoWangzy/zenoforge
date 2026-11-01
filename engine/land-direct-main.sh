#!/usr/bin/env bash
set -euo pipefail
# The lander's own preflight checks are allowed for non-product units (maintainer 10-29 ruling covers
# worker-run tests); without this the worker test shim refused them and no direct-main unit could land.
unset ZF_NON_PRODUCT_UNIT

self="$(realpath -- "$0")"
land_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "$land_script_dir/config.sh" ]]; then
  source "$land_script_dir/config.sh"
else
  # Published lander entrypoints omit config.sh; resolve their engine directory locally.
  ZF_ENGINE_DIR="${ZF_ENGINE_DIR:-$land_script_dir}"
  export ZF_ENGINE_DIR
fi
land_agent_home="${AGENT_HOME:-${ZF_HOME:-}}"
if [[ -z "$land_agent_home" ]]; then
  land_agent_home="$(
    if [[ -f "$land_script_dir/deploy.env" ]]; then
      source "$land_script_dir/deploy.env" >/dev/null 2>&1 || true
    fi
    printf '%s' "${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
  )"
fi
AGENT_HOME="$land_agent_home"
export AGENT_HOME
orig_args=("$@")
land_snapshot_marker="${ZF_LAND_CODE_SNAPSHOT:-}"
# $self is realpath-normalized while the marker arrives verbatim from mktemp; macOS TMPDIR
# (/tmp → /private/tmp, trailing slash → //) made every reentry comparison fail and the
# snapshot child re-ran bootstrap against a directory without .git (#3869).
land_snapshot_entry=""
if [[ -n "$land_snapshot_marker" ]]; then
  land_snapshot_entry="$(realpath -- "$land_snapshot_marker" 2>/dev/null || printf '%s' "$land_snapshot_marker")/engine/land-direct-main.sh"
fi
if [[ -z "$land_snapshot_marker" ]]; then
  land_bootstrap_needed=1
  for land_arg in "${orig_args[@]}"; do
    case "$land_arg" in
      --enqueue|--revalidate|--reconcile-pr|--reconcile-only) land_bootstrap_needed=0 ;;
    esac
  done
  if [[ "$land_bootstrap_needed" == 1 ]]; then
    exec bash "${self%/*}/land-direct-main-bootstrap.sh" "$self" "${orig_args[@]}"
  fi
fi
# Engine layout (Line B A2): the entry sits in the engine directory ZF_ENGINE_DIR outside the target repository, so
# there is no <toplevel>/engine entry to compare with a commit. That directory is a published, immutable version:
# run it in place, no snapshot. An entry at <toplevel>/engine keeps the commit comparison below, even when
# ZF_ENGINE_DIR names that directory. With ZF_ENGINE_DIR unset (env -i) the entry's own directory stands in for it
# when it holds config.sh.
land_engine_dir="${ZF_ENGINE_DIR:-}"
[[ -n "$land_engine_dir" || ! -f "${self%/*}/config.sh" ]] || land_engine_dir="${self%/*}"
land_engine_entry=0
if [[ "$self" != "$land_snapshot_entry" && -n "$land_engine_dir" \
    && "${self%/*}" == "$(realpath -- "$land_engine_dir" 2>/dev/null || true)" ]]; then
  land_entry_top="$(git -C "${self%/*}" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ "$self" == "$land_entry_top/engine/land-direct-main.sh" ]] || land_engine_entry=1
fi
if [[ "$land_engine_entry" == 1 ]]; then
  land_target_repo="$(git rev-parse --show-toplevel)"
  land_guard_source_root="$land_target_repo"
  if [[ -e "$land_agent_home/checkout" ]]; then
    land_guard_source_root="$land_agent_home/checkout"
  fi
  printf 'land-direct-main: engine=%s (published engine directory, no snapshot)\n' "${self%/*}" >&2
  if [[ "${_AGENT_REPO_DIR_DERIVED-}" == "${ZF_REPO_DIR-}" ]]; then
    ZF_REPO_DIR="$land_target_repo"
    unset _AGENT_REPO_DIR_DERIVED
    if [[ "${_AGENT_CONFIG_ROOT_DERIVED-}" == "${ZF_CONFIG_ROOT-}" ]]; then
      ZF_CONFIG_ROOT="$ZF_REPO_DIR/.zenoforge"
      unset _AGENT_CONFIG_ROOT_DERIVED
      export ZF_CONFIG_ROOT
    fi
  fi
  export _AGENT_WRITE_GUARD_SOURCE_ROOT="$land_guard_source_root" ZF_LAND_CODE_SNAPSHOT="${self%/*}" \
    ZF_REPO_DIR="${ZF_REPO_DIR:-$land_target_repo}" ZF_EXECUTION_MODULE_DIR="${self%/*}" ZF_SYSTEMD_RUN_REAL=""
elif [[ "$self" != "$land_snapshot_entry" ]]; then
  land_source_root="$(git -C "${self%/*}" rev-parse --show-toplevel)"
  land_entry_head="$(git -C "$land_source_root" rev-parse HEAD)"
  land_source_ref='refs/remotes/origin/main'
  if ! git -C "$land_source_root" show-ref --verify --quiet "$land_source_ref"; then
    echo "land-direct-main: canonical code source ref $land_source_ref unavailable; refusing snapshot (no lock taken)" >&2
    exit 2
  fi
  if ! land_source_head="$(git -C "$land_source_root" rev-parse --verify "${land_source_ref}^{commit}" 2>/dev/null)" \
      || [[ ! "$land_source_head" =~ ^[0-9a-f]{40}$ ]]; then
    echo "land-direct-main: canonical code source ref $land_source_ref is not a full commit; refusing snapshot (no lock taken)" >&2
    exit 2
  fi
  if [[ "$(git -C "$land_source_root" cat-file -t "$land_source_head:engine/land-direct-main.sh" 2>/dev/null || true)" != blob ]]; then
    echo "land-direct-main: canonical code source $land_source_head lacks the lander entry; refusing snapshot (no lock taken)" >&2
    exit 2
  fi
  if ! git -C "$land_source_root" show "$land_entry_head:engine/land-direct-main.sh" 2>/dev/null | cmp -s -- "$self" - \
      && ! git -C "$land_source_root" show "$land_source_head:engine/land-direct-main.sh" 2>/dev/null | cmp -s -- "$self" -; then
    echo 'land-direct-main: entry differs from both its HEAD commit and the pinned canonical source commit; refusing snapshot (no lock taken)' >&2
    exit 2
  fi
  land_code_snapshot="$(mktemp -d "${TMPDIR:-/tmp}/zf-land-code.XXXXXX")"
  trap 'rm -rf -- "$land_code_snapshot"' EXIT
  git -C "$land_source_root" archive "$land_source_head" engine | tar -x -C "$land_code_snapshot"
  printf 'land-direct-main: code-version=%s source-ref=%s snapshot=%s\n' "$land_source_head" "$land_source_ref" "$land_code_snapshot" >&2
  # Shared state belongs to the runtime checkout, even when this landing starts
  # from an isolated owner worktree. The code snapshot is not a pipeline install.
  land_guard_source_root="$land_source_root"
  if [[ -e "$land_agent_home/checkout" ]]; then
    land_guard_source_root="$land_agent_home/checkout"
  fi
  if _AGENT_WRITE_GUARD_SOURCE_ROOT="$land_guard_source_root" \
      ZF_LAND_CODE_SNAPSHOT="$land_code_snapshot" ZF_LAND_CODE_SOURCE_ROOT="$land_source_root" \
      ZF_LAND_CODE_SOURCE_OID="$land_source_head" ZF_REPO_DIR="${ZF_REPO_DIR:-$land_source_root}" \
      ZF_EXECUTION_MODULE_DIR="$land_code_snapshot/engine" \
      ZF_SYSTEMD_RUN_REAL="" \
      bash "$land_code_snapshot/engine/land-direct-main.sh" "${orig_args[@]}"; then
    exit 0
  else
    exit "$?"
  fi
fi
# Set only for direct-main pushes whose full checks run post-land.
slot_held="${LAND_PREFLIGHT_SLOT_HELD:-}"
unset LAND_PREFLIGHT_SLOT_HELD

usage() {
  echo "Usage: $0 [--wait-seconds N] [--revalidate [SHA]] [--reconcile-pr N] [--reconcile-only] [--preflight-only] [--enqueue]" >&2
}

revalidate_only=0
revalidate_target=""
reconcile_pr=""
reconcile_only=0
enqueue_only=0
preflight_only=0
while (($#)); do
  case "$1" in
    --wait-seconds)
      # Accepted and ignored: landings no longer queue on a lock, so there is nothing to wait for.
      (($# >= 2)) || { usage; exit 2; }
      shift 2
      ;;
    --wait-seconds=*)
      shift
      ;;
    --revalidate)
      revalidate_only=1
      if (($# >= 2)) && [[ "$2" != --* ]]; then
        revalidate_target="$2"
        shift 2
      else
        shift
      fi
      ;;
    --reconcile-pr)
      (($# >= 2)) || { usage; exit 2; }
      reconcile_pr="$2"
      shift 2
      ;;
    --reconcile-only)
      reconcile_only=1
      shift
      ;;
    --enqueue)
      enqueue_only=1
      shift
      ;;
    --preflight-only)
      preflight_only=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
cd -- "$repo_root"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || { echo "land-direct-main: run from a named branch" >&2; exit 2; }
if [[ "$branch" == main && "$revalidate_only" != 1 && -z "$reconcile_pr" ]]; then
  echo "land-direct-main: run landings from a topic branch, never main" >&2
  exit 2
fi
[[ -z "$reconcile_pr" || "$reconcile_pr" =~ ^[0-9]+$ ]] || { echo "land-direct-main: PR number must be numeric" >&2; exit 2; }
[[ "$reconcile_only" != 1 || -z "$reconcile_pr" ]] || { echo "land-direct-main: --reconcile-only is internal" >&2; exit 2; }
if [[ -n "$reconcile_pr" && ( "$revalidate_only" == 1 || "$enqueue_only" == 1 ) ]] \
  || [[ "$reconcile_only" == 1 && ( "$revalidate_only" == 1 || "$enqueue_only" == 1 || "$preflight_only" == 1 ) ]] \
  || [[ "$preflight_only" == 1 && ( "$revalidate_only" == 1 || "$enqueue_only" == 1 || -n "$reconcile_pr" ) ]]; then
  echo "land-direct-main: incompatible command options" >&2
  exit 2
fi
fast_safety_only_path=0
if [[ "$revalidate_only" != 1 && -z "$reconcile_pr" && "$reconcile_only" != 1 ]]; then
  fast_safety_only_path=1
  echo "land-direct-main: direct-main safety path bypasses preflight slot; focused suites run post-land" >&2
fi

agent_home="$land_agent_home"
export AGENT_HOME="$agent_home"
RELEASE_RECOVERY_DIR="$agent_home/release-recovery"
if [[ "$enqueue_only" == 1 ]]; then
  [[ "$revalidate_only" != 1 ]] || { echo "land-direct-main: --enqueue cannot combine with --revalidate" >&2; exit 2; }
  export AGENT_HOME="$agent_home"
  # This fresh process belongs to the live queue, not our code snapshot.
  unset _AGENT_WRITE_GUARD_SOURCE_ROOT
  exec bash "${ZF_ENGINE_LIVE:-$agent_home/checkout/engine}/land-queue.sh" enqueue "$repo_root" \
    "${ZF_AGENT_NAME:-}" "${ZF_AGENT_REPORT:-}"
fi

lock_dir="$agent_home/locks"
mkdir -p -- "$lock_dir"
# Newest duration and result per focused suite; the preflight orders suites from it (last failed first,
# then fastest first). Kept beside the landing queue, not in the issue-state directory.
export ZF_FOCUSED_DURATIONS_FILE="${ZF_FOCUSED_DURATIONS_FILE:-$agent_home/land-queue/focused-suite-durations.json}"

# Timestamped phase lines make each landing's blocking time readable from its queue log.
land_phase() {
  printf 'land-direct-main: phase=%s at=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
}

land_process_start_ticks() {
  local stat_line rest
  IFS= read -r stat_line < "/proc/$BASHPID/stat" || return 1
  rest="${stat_line##*) }"
  awk '{print $20}' <<< "$rest"
}

land_register_post_push_range() {
  local base="$1" head="$2" tmp start_ticks owner
  if [[ -n "${ZF_LAND_RESULT_DIR:-}" ]]; then
    mkdir -p -- "$ZF_LAND_RESULT_DIR" || return 1
    tmp="$(mktemp "$ZF_LAND_RESULT_DIR/.range.XXXXXX")" || return 1
    printf '%s %s\n' "$base" "$head" > "$tmp" && mv -f -- "$tmp" "$ZF_LAND_RESULT_DIR/range" || {
      rm -f -- "$tmp"
      return 1
    }
    return 0
  fi
  start_ticks="$(land_process_start_ticks)" || return 1
  owner="${ZF_AGENT_NAME:-direct-main}"
  direct_landing_ticket="$(bash "$land_script_dir/land-queue.sh" direct-reserve \
    "$repo_root" "$owner" "$base" "$head" "$BASHPID" "$start_ticks")" || return 1
  echo "land-direct-main: landed range registered ticket=$direct_landing_ticket ${base:0:12}..${head:0:12}"
}

# Source helpers beside this script, not from the landing worktree: the queue runs the checkout's
# land-direct-main.sh against older agent worktrees, whose lib.sh lacked agent_owned_issue_ids on
# 2026-10-11 and refused every landing with "could not resolve owner issues".
source "$land_script_dir/merge-result-check.sh"
export ZF_REPO_DIR="${ZF_REPO_DIR:-$repo_root}"
source "$land_script_dir/lib.sh"
source "$land_script_dir/model-policy-fast-forward.sh"
incident_guards_file="$(zf_config_file state/incident-guards.json 2>/dev/null || true)"
if [[ "$incident_guards_file" == "$ZF_REPO_DIR/"* ]]; then
  INCIDENT_GUARDS_REPO_PATH="${incident_guards_file#"$ZF_REPO_DIR"/}"
else
  INCIDENT_GUARDS_REPO_PATH="${ZF_PACK_REL:-engine}/state/incident-guards.json"
fi
ZF_AGENT_ISSUES="$(agent_owned_issue_ids "${ZF_AGENT_NAME:-direct-main}" "${ZF_AGENT_ISSUES:-${HAND_ISSUES:-}}")" || {
  echo 'land-direct-main: could not resolve owner issues' >&2
  exit 1
}
export ZF_AGENT_ISSUES
# lib.sh cds to $ZF_REPO_DIR, which run-implement sets to the agent checkout
# (on main). Every pipeline-system delivery then re-executed from that checkout
# and failed "never main" (2026-09-26..29: #1828, #1832, #1851, #1857, #1875).
cd -- "$repo_root"

land_configure_git_identity() {
  local name="${ZF_AGENT_GIT_USER_NAME:-}" email="${ZF_AGENT_GIT_USER_EMAIL:-}" scope=--local
  if [[ -z "$name" ]]; then name="$(git config --get user.name 2>/dev/null || true)"; fi
  if [[ -z "$email" ]]; then email="$(git config --get user.email 2>/dev/null || true)"; fi
  if [[ -z "$name" || -z "$email" ]]; then
    echo "land-direct-main: Git committer identity is missing; set ZF_AGENT_GIT_USER_NAME and ZF_AGENT_GIT_USER_EMAIL or repository Git config" >&2
    return 1
  fi
  if [[ "$(git config --bool --get extensions.worktreeConfig 2>/dev/null || true)" == true ]]; then
    scope=--worktree
  fi
  if ! git config "$scope" user.name "$name" || ! git config "$scope" user.email "$email"; then
    echo "land-direct-main: could not persist Git committer identity for this worktree" >&2
    return 1
  fi
  if ! git var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    echo "land-direct-main: configured Git committer identity is invalid" >&2
    return 1
  fi
}

land_git_rebase() {
  local source_driver="${ZF_LAND_STATE_JSON_MERGE_DRIVER:-$land_script_dir/git-merge-state-json.sh}" driver attributes quoted_driver status
  [[ -x "$source_driver" ]] || { echo "land-direct-main: missing state JSON merge driver: $source_driver" >&2; return 1; }
  driver="$(mktemp "${TMPDIR:-/tmp}/zf-state-json-merge.XXXXXX")" || return 1
  attributes="$(mktemp "${TMPDIR:-/tmp}/zf-state-json-attributes.XXXXXX")" || { rm -f -- "$driver"; return 1; }
  if ! cp -- "$source_driver" "$driver"; then
    rm -f -- "$driver" "$attributes"
    return 1
  fi
  printf '%s\n' "$ZF_PACK_REL/state/*.json merge=statejson" > "$attributes"
  printf -v quoted_driver '%q' "$driver"
  if git -c "core.attributesFile=$attributes" \
      -c "merge.statejson.driver=bash $quoted_driver %O %A %B" rebase "$@"; then
    status=0
  else
    status=$?
  fi
  rm -f -- "$driver" "$attributes"
  return "$status"
}

# zf-ab 裁决（10-29）：footprint 互斥对 shared-append 注册表文件放行并行，文本冲突在落地
# rebase 处解决。这里把改动范围带 shared-append 文件的落地 rebase 记进共享日志
# （node_health 的 ci.shared_append_rebase_conflict_pct 读它）；遥测失败不阻断落地。
land_shared_append_range_files() { # base -> 落地范围与 shared-append 名单的交集（JSON 数组；无需记录时输出空）
  local base="$1" range
  git merge-base --is-ancestor "$base" HEAD 2>/dev/null && return 0 # up-to-date 的 rebase 不重放提交
  range="$(git diff --name-only --no-renames "$base...HEAD" 2>/dev/null)" || return 0
  [[ -n "$range" ]] || return 0
  printf '%s' "$range" | jq -Rsc --slurpfile cfg "$land_script_dir/mac-autopilot/config.template.json" '
    (($cfg[0].footprint_mutex.shared_append // []) | map(select(type == "string"))) as $sa
    | split("\n") | [.[] | select(length > 0) | select(. as $x | any($sa[]; . == $x))]' 2>/dev/null || return 0
}
land_record_shared_append_rebase() { # base shared_files_json conflict_bool conflict_files_json
  local when row
  when="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  row="$(jq -cn --arg when "$when" --arg repo "${ZF_REPO:-example-maintainer/example-repo}" \
      --arg actor "${ZF_AGENT_NAME:-direct-main}" --arg base "$1" \
      --argjson files "$2" --argjson conflict "$3" --argjson cfiles "$4" '
    {schema: "zf-shared-append-rebase/v1", when: $when, repo: $repo, actor: $actor, base: $base,
     shared_files: $files, conflict: $conflict, conflict_files: $cfiles}')" || return 0
  mkdir -p -- "$agent_home/logs" 2>/dev/null || return 0
  printf '%s\n' "$row" >> "$agent_home/logs/shared-append-rebases.jsonl" 2>/dev/null || return 0
}
land_rebase_record_shared_append() { # base；rebase 本体失败照旧向上返回，rebase 停在冲突态时可见未合并路径
  local base="$1" files cfiles='[]'
  files="$(land_shared_append_range_files "$base")"
  if land_git_rebase "$base"; then
    [[ -n "$files" && "$files" != '[]' ]] \
      && land_record_shared_append_rebase "$base" "$files" false "$cfiles"
    return 0
  fi
  if [[ -n "$files" && "$files" != '[]' ]]; then
    cfiles="$(git diff --name-only --diff-filter=U 2>/dev/null | jq -Rsc --argjson files "$files" \
      'split("\n") | [.[] | select(length > 0) | select(. as $x | ($files | index($x)) != null)]' 2>/dev/null || true)"
    land_record_shared_append_rebase "$base" "$files" true "${cfiles:-[]}"
  fi
  return 1
}

# 2026-10-13: 29 successful queued push phases give p99=119.908s. 240s is
# approximately twice p99 and covers the historical lock-hold p99 bound of 214.422s.
land_git_network() {
  local timeout_seconds="${ZF_LAND_GIT_TIMEOUT_SECONDS:-240}" status started_ms
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo "land-direct-main: Git network timeout must be a positive integer" >&2
    return 2
  }
  started_ms="$(date +%s%3N)"
  if command timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" git "$@"; then
    status=0
  else
    status=$?
  fi
  printf 'land-direct-main: git-network operation=%s duration_ms=%s status=%s deadline_seconds=%s\n' \
    "$1" "$(( $(date +%s%3N) - started_ms ))" "$status" "$timeout_seconds" >&2
  if [[ "$status" == 124 || "$status" == 137 ]]; then
    echo "land-direct-main: Operation timed out during $1 (deadline=${timeout_seconds}s)" >&2
    return 124
  fi
  return "$status"
}
land_git_transport_retry() {
  local attempt=1 max_attempts=2 base_delay="${ZF_LAND_TRANSPORT_BACKOFF_BASE_SECONDS:-1}" delay output failure_output status
  [[ "$base_delay" =~ ^[0-9]+$ ]] || { echo "land-direct-main: retry backoff must be a non-negative integer" >&2; return 2; }
  ((base_delay <= 4)) || base_delay=4
  output="$(mktemp)" || return 1
  while :; do
    if "$@" > "$output" 2>&1; then
      cat "$output"
      rm -f -- "$output"
      return 0
    else
      status=$?
    fi
    failure_output="$(cat "$output")"
    printf '%s\n' "$failure_output" >&2
    # Linked worktrees share origin/main; concurrent fetches can race its ref update.
    if ((attempt >= max_attempts)) || {
      ! agent_transport_is_transient "$failure_output" && ! agent_ref_update_race_is_transient "$failure_output"
    }; then
      rm -f -- "$output"
      return "$status"
    fi
    delay=$((base_delay << (attempt - 1)))
    ((delay <= 4)) || delay=4
    printf 'land-direct-main: transient transport failure; retry %s/%s in %ss\n' \
      "$((attempt + 1))" "$max_attempts" "$delay" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

land_git_fetch_main() {
  ZF_GIT_FETCH_TRANSIENT_RETRIES=0 land_git_transport_retry git_fetch_bounded "$repo_root" main
}

replace_added_lesson_id() {
  local base="$1" file="$2" candidate="$3" assigned="$4"
  local diff_line next_line=0 changed_lines temp_file
  local -a added_lines=()
  local added

  while IFS= read -r diff_line; do
    if [[ "$diff_line" == @@* ]]; then
      if [[ "$diff_line" =~ \+([0-9]+) ]]; then
        next_line="${BASH_REMATCH[1]}"
      else
        next_line=0
      fi
      continue
    fi
    if [[ "$diff_line" == +++* || "$diff_line" == ---* ]]; then
      continue
    fi
    if [[ "$diff_line" == +* ]]; then
      added_lines+=("$next_line")
      next_line=$((next_line + 1))
    elif [[ "$diff_line" == ' '* ]]; then
      next_line=$((next_line + 1))
    fi
  done < <(git diff --no-ext-diff --unified=0 "$base...HEAD" -- "$file")

  ((${#added_lines[@]} > 0)) || return 0
  printf -v changed_lines '%s ' "${added_lines[@]}"
  temp_file="$(mktemp)"
  if ! awk -v changed_lines="$changed_lines" -v candidate="$candidate" -v assigned="$assigned" '
    function replace_token(input, token, replacement, position, before, after, previous) {
      output = ""
      while ((position = index(input, token)) > 0) {
        before = substr(input, 1, position - 1)
        after = substr(input, position + length(token))
        previous = substr(before, length(before), 1)
        output = output before
        if ((before == "" || previous !~ /[[:alnum:]_]/) && after !~ /^[0-9]/) {
          output = output replacement
        } else {
          output = output token
        }
        input = after
      }
      return output input
    }
    BEGIN {
      count = split(changed_lines, line_numbers, " ")
      for (i = 1; i <= count; i++) if (line_numbers[i] != "") changed[line_numbers[i]] = 1
    }
    {
      if (changed[NR]) {
        if (candidate == "NEXT" || candidate ~ /^NEXT-/) {
          suffix = candidate == "NEXT" ? "" : substr(candidate, 5)
          $0 = replace_token($0, "V-NEXT" suffix, "V" assigned)
          $0 = replace_token($0, "v-next" suffix, "v" assigned)
          $0 = replace_token($0, "v-NEXT" suffix, "v" assigned)
          $0 = replace_token($0, "VNEXT" suffix, "V" assigned)
          $0 = replace_token($0, "vnext" suffix, "v" assigned)
        } else {
          $0 = replace_token($0, "V" candidate, "V" assigned)
          $0 = replace_token($0, "v" candidate, "v" assigned)
        }
      }
      print
    }
  ' "$file" > "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi
  cat "$temp_file" > "$file" || { rm -f -- "$temp_file"; return 1; }
  rm -f -- "$temp_file"
}

# A registry may live outside the target repo during migration; then the resolved config file supplies the used ids.
landed_incident_guards() {
  local p="$INCIDENT_GUARDS_REPO_PATH" f
  if git cat-file -e "$1:$p" 2>/dev/null; then git show "$1:$p"; return; fi
  f="$(zf_config_file state/incident-guards.json)" && cat "$f" || echo '{}'
}

added_guard_id_for_lesson_occurrence() {
  local base="$1" candidate="$2" occurrence="$3" guard_id count=0
  local -A base_guard_ids=()
  while IFS= read -r guard_id; do
    [[ -n "$guard_id" ]] && base_guard_ids["$guard_id"]=1
  done < <(landed_incident_guards "$base" | jq -r '.incidents[]?.id // empty')
  while IFS= read -r guard_id; do
    [[ -n "$guard_id" && -z "${base_guard_ids[$guard_id]:-}" ]] || continue
    count=$((count + 1))
    if ((count == occurrence)); then
      printf '%s\n' "$guard_id"
      return 0
    fi
  done < <(jq -r --arg lesson_id "V$candidate" '.incidents[]? | select(.lesson_id == $lesson_id) | .id' \
    "$INCIDENT_GUARDS_REPO_PATH")
  return 1
}

added_catalog_full_path_for_lesson_occurrence() {
  local base="$1" candidate="$2" occurrence="$3" diff_line count=0 line
  while IFS= read -r diff_line; do
    [[ "$diff_line" == +++* || "$diff_line" == ---* ]] && continue
    [[ "$diff_line" == +* ]] || continue
    line="${diff_line:1}"
    if [[ "$line" == *RULES.md* && ( "$line" == *"V$candidate"* || "$line" == *"v$candidate"* ) ]]; then
      count=$((count + 1))
      if ((count == occurrence)) && [[ "$line" =~ (\./)?(full/[^[:space:]\)]+\.md) ]]; then
        printf 'lessons/%s\n' "${BASH_REMATCH[2]}"
        return 0
      fi
    fi
  done < <(git diff --no-ext-diff --unified=0 "$base...HEAD" -- lessons/CATALOG.md)
  return 1
}

replace_added_lesson_occurrence() {
  local base="$1" file="$2" candidate="$3" assigned="$4" occurrence="$5"
  local diff_line next_line=0 changed_lines target guard_id full_path temp_file
  local -a added_lines=()
  local added

  if [[ "$file" == "$INCIDENT_GUARDS_REPO_PATH" ]]; then
    guard_id="$(added_guard_id_for_lesson_occurrence "$base" "$candidate" "$occurrence")" || return 0
    temp_file="$(mktemp)"
    if ! jq --arg id "$guard_id" --arg lesson_id "V$assigned" \
      '(.incidents[] | select(.id == $id)).lesson_id = $lesson_id' "$file" > "$temp_file"; then
      rm -f -- "$temp_file"
      return 1
    fi
    cat "$temp_file" > "$file" || { rm -f -- "$temp_file"; return 1; }
    rm -f -- "$temp_file"
    return 0
  fi

  if [[ "$file" == lessons/full/* ]]; then
    if full_path="$(added_catalog_full_path_for_lesson_occurrence "$base" "$candidate" "$occurrence")"; then
      [[ "$file" == "$full_path" ]] || return 0
    else
      guard_id="$(added_guard_id_for_lesson_occurrence "$base" "$candidate" "$occurrence" 2>/dev/null || true)"
      if [[ -n "$guard_id" ]]; then
        [[ "$file" == "lessons/full/$guard_id.md" ]] || return 0
      else
        local -a matching_full_files=()
        while IFS= read -r full_path; do
          [[ -n "$full_path" ]] || continue
          grep -Eq "(^|[^[:alnum:]_])[Vv]$candidate([^0-9]|$)" "$full_path" && matching_full_files+=("$full_path")
        done < <(git diff --name-only "$base...HEAD" -- lessons/full | LC_ALL=C sort)
        ((${#matching_full_files[@]} >= occurrence)) || return 0
        [[ "$file" == "${matching_full_files[$((occurrence - 1))]}" ]] || return 0
      fi
    fi
    replace_added_lesson_id "$base" "$file" "$candidate" "$assigned" || return 1
    return $?
  fi

  while IFS= read -r diff_line; do
    if [[ "$diff_line" == @@* ]]; then
      if [[ "$diff_line" =~ \+([0-9]+) ]]; then next_line="${BASH_REMATCH[1]}"; else next_line=0; fi
      continue
    fi
    if [[ "$diff_line" == +++* || "$diff_line" == ---* ]]; then continue; fi
    if [[ "$diff_line" == +* ]]; then
      added_lines+=("$next_line")
      next_line=$((next_line + 1))
    elif [[ "$diff_line" == ' '* ]]; then
      next_line=$((next_line + 1))
    fi
  done < <(git diff --no-ext-diff --unified=0 "$base...HEAD" -- "$file")
  ((${#added_lines[@]} > 0)) || return 0
  printf -v changed_lines '%s ' "${added_lines[@]}"
  temp_file="$(mktemp)"
  if ! awk -v changed_lines="$changed_lines" -v candidate="$candidate" -v assigned="$assigned" \
    -v occurrence="$occurrence" -v file="$file" '
    function replace_token(input, token, replacement, position, before, after, previous) {
      output = ""
      while ((position = index(input, token)) > 0) {
        before = substr(input, 1, position - 1)
        after = substr(input, position + length(token))
        previous = substr(before, length(before), 1)
        output = output before
        if ((before == "" || previous !~ /[[:alnum:]_]/) && after !~ /^[0-9]/) output = output replacement
        else output = output token
        input = after
      }
      return output input
    }
    BEGIN {
      count = split(changed_lines, line_numbers, " ")
      for (i = 1; i <= count; i++) if (line_numbers[i] != "") changed[line_numbers[i]] = 1
    }
    {
      lines[NR] = $0
      if (changed[NR] && file == "lessons/RULES.md" && index($0, "**V" candidate "**")) {
        rule_count++
        if (rule_count == occurrence) target = NR
      } else if (changed[NR] && file == "lessons/CATALOG.md" && index($0, "RULES.md") &&
        (index($0, "V" candidate) || index($0, "v" candidate))) {
        catalog_count++
        if (catalog_count == occurrence) target = NR
      }
    }
    END {
      has_anchor = target > 1 && index(lines[target - 1], "<a id=\"v" candidate "\"></a>")
      for (i = 1; i <= NR; i++) {
        if (file == "lessons/RULES.md" && target && i == target && !has_anchor) print "<a id=\"v" assigned "\"></a>"
        line = lines[i]
        if (file == "lessons/RULES.md" && target && has_anchor && i == target - 1) {
          line = replace_token(line, "v" candidate, "v" assigned)
          line = replace_token(line, "V" candidate, "V" assigned)
        }
        if (target && i == target) {
          line = replace_token(line, "V" candidate, "V" assigned)
          line = replace_token(line, "v" candidate, "v" assigned)
        }
        print line
      }
    }
  ' "$file" > "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi
  cat "$temp_file" > "$file" || { rm -f -- "$temp_file"; return 1; }
  rm -f -- "$temp_file"
}

# A failed attempt leaves its fold commit (and the IDs assigned into it) on
# the branch. Replayed onto a main that has folded the same fragments, the
# union merge on RULES.md keeps both copies under two IDs (2026-09-29).
drop_stale_fold_commits() {
  while [[ "$(git log -1 --format=%s)" == '[skip ci] fold merged lesson fragments' ]]; do
    git reset -q --keep HEAD~1 || return 1
  done
}

assign_lesson_ids() {
  local base occupied_base diff_line added candidate id changed_path max_id=0 next_id assigned did_rewrite=0 direction count removed current_path='' paired_id
  local docs_only=1
  local added_rule_count removed_rule_count added_incident_count removed_incident_count
  local rules_ids incident_ids
  local -a candidates=() candidate_order=() lesson_paths=() assignment_keys=()
  local -A added_counts=() removed_counts=() used_ids=() main_used_ids=() assignments=()
  local -A base_rule_ids=() base_incident_ids=() added_rule_counts=() removed_rule_counts=() added_incident_counts=() removed_incident_counts=()

  base="${LESSON_ID_CHANGE_BASE:-$(git rev-parse origin/main)}"
  occupied_base="${LESSON_ID_OCCUPIED_BASE:-$(git rev-parse origin/main)}"
  while IFS= read -r changed_path; do
    case "$changed_path" in lessons/*) ;; *) docs_only=0; break ;; esac
  done < <(git diff --name-only "$base...HEAD")
  while IFS= read -r diff_line; do
    if [[ "$diff_line" == +++* ]]; then
      current_path=""
      [[ "$diff_line" == "+++ b/"* ]] && current_path="${diff_line#+++ b/}"
      continue
    fi
    [[ "$diff_line" == ---* ]] && continue
    if [[ "$diff_line" == +* ]]; then
      direction=added
    elif [[ "$diff_line" == -* ]]; then
      direction=removed
    else
      continue
    fi
    added="${diff_line:1}"
    if [[ "$added" =~ \*\*V-NEXT-([a-z0-9-]+)\*\* ]]; then
      candidate="NEXT-${BASH_REMATCH[1]}"
    elif [[ "$added" == *'**V-NEXT**'* ]]; then
      candidate=NEXT
    elif [[ "$added" =~ \*\*V([0-9]+)\*\* ]]; then
      candidate="${BASH_REMATCH[1]}"
    else
      candidate=""
    fi
    if [[ -n "$candidate" ]]; then
      if [[ "$direction" == added ]]; then
        [[ -n "${added_counts[$candidate]:-}" ]] || candidate_order+=("$candidate")
        added_counts["$candidate"]=$(( ${added_counts[$candidate]:-0} + 1 ))
        if [[ "$current_path" == lessons/RULES.md ]]; then
          added_rule_counts["$candidate"]=$(( ${added_rule_counts[$candidate]:-0} + 1 ))
        fi
      else
        removed_counts["$candidate"]=$(( ${removed_counts[$candidate]:-0} + 1 ))
        if [[ "$current_path" == lessons/RULES.md ]]; then
          removed_rule_counts["$candidate"]=$(( ${removed_rule_counts[$candidate]:-0} + 1 ))
        fi
      fi
    fi
    if [[ "$added" =~ \"lesson_id\"[[:space:]]*:[[:space:]]*\"V-NEXT-([a-z0-9-]+)\" ]]; then
      candidate="NEXT-${BASH_REMATCH[1]}"
    elif [[ "$added" =~ \"lesson_id\"[[:space:]]*:[[:space:]]*\"V-NEXT\" ]]; then
      candidate=NEXT
    elif [[ "$added" =~ \"lesson_id\"[[:space:]]*:[[:space:]]*\"V([0-9]+)\" ]]; then
      candidate="${BASH_REMATCH[1]}"
    else
      candidate=""
    fi
    if [[ -n "$candidate" ]]; then
      if [[ "$direction" == added ]]; then
        [[ -n "${added_counts[$candidate]:-}" ]] || candidate_order+=("$candidate")
        added_counts["$candidate"]=$(( ${added_counts[$candidate]:-0} + 1 ))
        if [[ "$current_path" == "$INCIDENT_GUARDS_REPO_PATH" ]]; then
          added_incident_counts["$candidate"]=$(( ${added_incident_counts[$candidate]:-0} + 1 ))
        fi
      else
        removed_counts["$candidate"]=$(( ${removed_counts[$candidate]:-0} + 1 ))
        if [[ "$current_path" == "$INCIDENT_GUARDS_REPO_PATH" ]]; then
          removed_incident_counts["$candidate"]=$(( ${removed_incident_counts[$candidate]:-0} + 1 ))
        fi
      fi
    fi
  done < <(git diff --no-ext-diff --unified=0 "$base...HEAD" -- lessons/RULES.md "$INCIDENT_GUARDS_REPO_PATH")
  for candidate in "${candidate_order[@]}"; do
    count="${added_counts[$candidate]}"
    removed="${removed_counts[$candidate]:-0}"
    ((count > removed)) && candidates+=("$candidate")
  done
  ((${#candidates[@]} > 0)) || return 0

  rules_ids="$(git show "$base:lessons/RULES.md" | sed -nE 's/^\*\*V([0-9]+)\*\*.*/\1/p')"
  incident_ids="$(landed_incident_guards "$base" | jq -r '.incidents[]?.lesson_id // empty' | sed -nE 's/^V([0-9]+)$/\1/p')"
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    base_rule_ids["$id"]=1
  done <<< "$rules_ids"
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    base_incident_ids["$id"]=1
  done <<< "$incident_ids"
  rules_ids="$(git show "$occupied_base:lessons/RULES.md" | sed -nE 's/^\*\*V([0-9]+)\*\*.*/\1/p')"
  incident_ids="$(landed_incident_guards "$occupied_base" | jq -r '.incidents[]?.lesson_id // empty' | sed -nE 's/^V([0-9]+)$/\1/p')"
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    used_ids["$id"]=1
    main_used_ids["$id"]=1
    ((id > max_id)) && max_id="$id"
  done <<< "$rules_ids"
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    used_ids["$id"]=1
    main_used_ids["$id"]=1
    ((id > max_id)) && max_id="$id"
  done <<< "$incident_ids"
  next_id=$((max_id + 1))

  # A branch-assigned ID stays provisional until present on origin/main.
  # Reserve every outgoing numeric ID so fresh allocations cannot collide with
  # a different provisional ID from the same branch.
  for candidate in "${candidates[@]}"; do
    [[ "$candidate" =~ ^[0-9]+$ ]] && used_ids["$candidate"]=1
  done

  local preserve_occurrence rule_count incident_count record_count occurrence assignment_key occurrence_index
  for candidate in "${candidates[@]}"; do
    paired_id=0
    preserve_occurrence=0
    rule_count=$(( ${added_rule_counts[$candidate]:-0} - ${removed_rule_counts[$candidate]:-0} ))
    incident_count=$(( ${added_incident_counts[$candidate]:-0} - ${removed_incident_counts[$candidate]:-0} ))
    ((rule_count < 0)) && rule_count=0
    ((incident_count < 0)) && incident_count=0
    record_count="$rule_count"
    ((incident_count > record_count)) && record_count="$incident_count"
    ((record_count > 0)) || record_count=1
    if [[ "$candidate" != NEXT && "$candidate" != NEXT-* \
      && ( -n "${base_rule_ids[$candidate]:-}" || -n "${base_incident_ids[$candidate]:-}" ) ]]; then
      added_rule_count="${added_rule_counts[$candidate]:-0}"
      removed_rule_count="${removed_rule_counts[$candidate]:-0}"
      added_incident_count="${added_incident_counts[$candidate]:-0}"
      removed_incident_count="${removed_incident_counts[$candidate]:-0}"
      if [[ "$docs_only" == 1 && -n "${base_incident_ids[$candidate]:-}" && -z "${base_rule_ids[$candidate]:-}" ]] \
        && ((added_rule_count > removed_rule_count && added_incident_count == removed_incident_count)); then
        paired_id=1
      elif [[ -n "${base_rule_ids[$candidate]:-}" && -z "${base_incident_ids[$candidate]:-}" ]] \
        && ((added_incident_count > removed_incident_count && added_rule_count == removed_rule_count)); then
        paired_id=1
      fi
    fi
    if [[ "$candidate" == NEXT || "$candidate" == NEXT-* ]]; then
      preserve_occurrence=0
    elif ((paired_id == 1)) || [[ -z "${main_used_ids[$candidate]:-}" ]]; then
      preserve_occurrence=1
    fi
    for ((occurrence = 1; occurrence <= record_count; occurrence++)); do
      ((occurrence == preserve_occurrence)) && continue
      while [[ -n "${used_ids[$next_id]:-}" ]]; do next_id=$((next_id + 1)); done
      assignment_key="$candidate:$occurrence"
      assignments["$assignment_key"]="$next_id"
      assignment_keys+=("$assignment_key")
      used_ids["$next_id"]=1
      next_id=$((next_id + 1))
      did_rewrite=1
    done
  done
  ((did_rewrite == 1)) || return 0

  mapfile -t lesson_paths < <(git diff --name-only "$base...HEAD" -- lessons/RULES.md lessons/CATALOG.md lessons/full "$INCIDENT_GUARDS_REPO_PATH")
  for ((occurrence_index = ${#assignment_keys[@]} - 1; occurrence_index >= 0; occurrence_index--)); do
    assignment_key="${assignment_keys[$occurrence_index]}"
    candidate="${assignment_key%:*}"
    occurrence="${assignment_key##*:}"
    assigned="${assignments[$assignment_key]}"
    for file in "${lesson_paths[@]}"; do
      [[ "$file" == lessons/full/* ]] || continue
      if [[ "$candidate" == NEXT || "$candidate" == NEXT-* ]]; then
        replace_added_lesson_id "$base" "$file" "$candidate" "$assigned" || return 1
      else
        replace_added_lesson_occurrence "$base" "$file" "$candidate" "$assigned" "$occurrence" || return 1
      fi
    done
    for file in "${lesson_paths[@]}"; do
      [[ "$file" == lessons/full/* ]] && continue
      if [[ "$candidate" == NEXT || "$candidate" == NEXT-* ]]; then
        replace_added_lesson_id "$base" "$file" "$candidate" "$assigned" || return 1
      else
        replace_added_lesson_occurrence "$base" "$file" "$candidate" "$assigned" "$occurrence" || return 1
      fi
    done
    if [[ "$candidate" == NEXT ]]; then
      echo "land-direct-main: assigned lesson ID V$assigned to V-NEXT"
    elif [[ "$candidate" == NEXT-* ]]; then
      echo "land-direct-main: assigned lesson ID V$assigned to pending fragment ${candidate#NEXT-}"
    else
      echo "land-direct-main: reassigned provisional lesson ID V$candidate occurrence $occurrence to V$assigned"
    fi
  done
  git add -- "${lesson_paths[@]}" || return 1
  if [[ "${LESSON_ID_COMMIT_MODE:-amend}" == new ]]; then
    git commit -m '[skip ci] assign merged lesson IDs'
  else
    git commit --amend --no-edit
  fi
}

assign_plan_package_trailer() {
  local package="${PLAN_PACKAGE:-${branch#hand/}}" existing
  [[ "$branch" == hand/* || -n "${PLAN_PACKAGE:-}" ]] || return 0
  # Keep this trailer independent of the retired acceptance runner's package registry.
  existing="$(git show -s --format=%B HEAD | sed -n 's/^Plan-Package: //p')"
  if [[ -n "$existing" ]]; then
    [[ "$existing" =~ ^[[:alnum:]_.-]+(/[[:alnum:]_.-]+)*$ ]] || {
      echo "land-direct-main: invalid existing Plan-Package value: $existing" >&2
      return 1
    }
    if [[ -n "${PLAN_PACKAGE:-}" && "$existing" != "$PLAN_PACKAGE" ]]; then
      echo "land-direct-main: HEAD already has Plan-Package: $existing, expected $PLAN_PACKAGE" >&2
      return 1
    fi
    return 0
  fi
  [[ "$package" =~ ^[[:alnum:]_.-]+(/[[:alnum:]_.-]+)*$ ]] || {
    echo "land-direct-main: invalid Plan-Package value: $package" >&2
    return 1
  }
  git commit --amend --no-edit --trailer "Plan-Package: $package"
}

land_append_owner_issue_references() {
  local upstream="$1" amend_script exec_command status
  local -a issues=( $ZF_AGENT_ISSUES )
  ((${#issues[@]})) || return 0
  [[ "$(git rev-parse HEAD)" != "$(git rev-parse "$upstream")" ]] || return 0
  mkdir -p -- "$agent_home/tmp" || return 1
  amend_script="$(mktemp "$agent_home/tmp/land-owner-issues.XXXXXX")" || return 1
  cat > "$amend_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
message="$(git show -s --format=%B HEAD)"
for issue in $ZF_AGENT_ISSUES; do
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || exit 2
  if grep -Eiq "(^|[^[:alnum:]_])(#|issue[[:space:]]+)$issue([^[:alnum:]_]|$)" <<< "$message"; then
    exit 0
  fi
done
trailers=()
for issue in $ZF_AGENT_ISSUES; do trailers+=(--trailer "Refs: issue $issue"); done
git commit --amend --no-edit "${trailers[@]}"
EOF
  chmod 700 "$amend_script" || { rm -f -- "$amend_script"; return 1; }
  printf -v exec_command 'bash %q' "$amend_script"
  if GIT_SEQUENCE_EDITOR=: ZF_AGENT_ISSUES="$ZF_AGENT_ISSUES" \
      git rebase --interactive --exec "$exec_command" "$upstream"; then
    status=0
  else
    status=$?
  fi
  rm -f -- "$amend_script"
  return "$status"
}

prepare_lesson_metadata_for_landing() (
  local owner_root="$repo_root" owner_head worktree folded_head
  # The folding worktree shares origin/main with concurrent fetchers. Allocate
  # only against this item's actual rebase base, just like its commit rewrites.
  export LESSON_ID_CHANGE_BASE="$tested_base" LESSON_ID_OCCUPIED_BASE="$tested_base"
  owner_head="$(git rev-parse HEAD)" || return 1
  # A new worktree does not inherit config.worktree identity from its owner.
  export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$(git config user.name)}"
  export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$(git config user.email)}"
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$GIT_COMMITTER_NAME}"
  export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$GIT_COMMITTER_EMAIL}"
  worktree="$(mktemp -d "${TMPDIR:-/tmp}/zf-lesson-fold.XXXXXX")" || return 1
  trap 'if [[ -e "$worktree/.git" ]]; then
    git -C "$owner_root" worktree remove --force "$worktree" || exit 1
  else
    rmdir -- "$worktree" || exit 1
  fi' EXIT
  if ! git worktree add --quiet --detach "$worktree" "$owner_head"; then
    echo "land-direct-main: lesson ID preparation skipped; Pipeline suites on the landed head report it" >&2
    return 0
  fi
  # ID allocation writes before committing. Keep every partial result
  # in a disposable tree; the owner's index.lock belongs to its other Git writer.
  repo_root="$worktree"
  cd -- "$repo_root" || return 1
  if ! assign_lesson_ids; then
    echo "land-direct-main: lesson ID allocation skipped; Pipeline suites on the landed head report it" >&2
    return 0
  fi
  folded_head="$(git rev-parse HEAD)" || return 1
  cd -- "$owner_root" || return 1
  [[ "$folded_head" != "$owner_head" ]] || return 0
  if [[ "$(git rev-parse HEAD)" != "$owner_head" ]]; then
    echo "land-direct-main: owner HEAD changed during lesson preparation; retry landing" >&2
    return 1
  fi
  # reset --keep acquires index.lock before updating files, and preserves owner edits.
  if ! git reset --quiet --keep "$folded_head"; then
    echo "land-direct-main: lesson ID preparation skipped; Pipeline suites on the landed head report it" >&2
  fi
)

reconcile_merged_pr() {
  local pr="$1" merge_commit merge_parent worktree branch_name land_script status
  merge_commit="$(gh pr view "$pr" --repo "${ZF_GH_REPO:-$REPO}" \
    --json mergeCommit -q '.mergeCommit.oid // empty')" || {
    echo "land-direct-main: could not read merge commit for PR #$pr" >&2
    return 1
  }
  [[ "$merge_commit" =~ ^[0-9a-f]{40}$ ]] || {
    echo "land-direct-main: PR #$pr has no valid merge commit" >&2
    return 1
  }
  land_git_fetch_main || { echo "land-direct-main: could not fetch main for PR #$pr lesson reconciliation" >&2; return 1; }
  git merge-base --is-ancestor "$merge_commit" origin/main || {
    echo "land-direct-main: PR #$pr merge commit is not on origin/main" >&2
    return 1
  }
  merge_parent="$(git rev-parse "$merge_commit^1" 2>/dev/null)" || {
    echo "land-direct-main: PR #$pr merge commit has no first parent" >&2
    return 1
  }
  if git diff --quiet "$merge_parent" "$merge_commit" -- \
    lessons/RULES.md "$INCIDENT_GUARDS_REPO_PATH"; then
    echo "land-direct-main: PR #$pr introduced no numbered lesson records; reconciliation is already complete"
    return 0
  fi

  worktree="$(mktemp -d "${TMPDIR:-/tmp}/zf-lesson-reconcile.XXXXXX")" || return 1
  rmdir -- "$worktree"
  branch_name="agent/lesson-reconcile-${pr}-$$"
  if ! git worktree add -q -b "$branch_name" "$worktree" "$merge_commit"; then
    rm -rf -- "$worktree"
    echo "land-direct-main: could not create reconciliation worktree for PR #$pr" >&2
    return 1
  fi
  land_script="${ZF_ENGINE_LIVE:-$agent_home/checkout/engine}/land-direct-main.sh"
  [[ -r "$land_script" ]] || land_script="$worktree/engine/land-direct-main.sh"
  if (cd -- "$worktree" && AGENT_HOME="$agent_home" ZF_REPO_DIR="$worktree" \
    LESSON_ID_CHANGE_BASE="$merge_parent" LESSON_ID_COMMIT_MODE=new \
    bash "$land_script" --reconcile-only); then
    status=0
  else
    status=$?
  fi
  if ! git worktree remove --force "$worktree"; then
    echo "land-direct-main: could not remove reconciliation worktree for PR #$pr" >&2
    return 1
  fi
  if ! git branch -D "$branch_name" >/dev/null; then
    echo "land-direct-main: could not remove reconciliation branch for PR #$pr" >&2
    return 1
  fi
  return "$status"
}

# Every landing waits for MemAvailable >= 3 GB (one focused worker plus reserve), not load.
# The two bounded slots below already stop the issue-1985 pile-up. Hand and implement agents
# keep load near 5x nproc for hours, so a load gate never opened and only its 45-minute cap
# released each FIFO head in turn: on 2026-10-10 five landings waited 30+ minutes behind
# two empty slots, then ran at the same load anyway.
wait_for_preflight_memory() {
  local meminfo_file="${AGENT_DISPATCH_MEMINFO_FILE:-/proc/meminfo}" available_kib mem_mb waited=0
  while :; do
    if ! available_kib="$(awk '$1 == "MemAvailable:" { print $2; found=1; exit } END { if (!found) exit 1 }' "$meminfo_file")" || \
      [[ ! "$available_kib" =~ ^[0-9]+$ ]]; then
      echo "land-direct-main: cannot read MemAvailable from $meminfo_file" >&2
      return 1
    fi
    mem_mb=$((available_kib / 1024))
    if ((mem_mb >= 3072)); then
      if ((waited)); then
        echo "land-direct-main: preflight memory gate passed mem_mb=$mem_mb" >&2
      fi
      return 0
    fi
    if ((!waited)); then
      echo "land-direct-main: preflight memory gate waiting mem_mb=$mem_mb required_mb=3072" >&2
      waited=1
    fi
    sleep 5
  done
}

with_preflight_slot() {
  if [[ -n "$slot_held" ]]; then "$@"; return; fi
  # One bounded slot set for every landing's test-running part, queue landings included. On
  # 2026-10-08 queue landings skipped the slots: 7+ ran focused suites at once (load ~55 on 12
  # cores) and landing 278 failed "host overloaded during preflight". The fast path keeps each
  # slot hold to minutes, so waiters wait here without spawning suites.
  local slots="${ZF_LAND_PREFLIGHT_SLOTS:-2}"
  [[ "$slots" =~ ^[1-9][0-9]*$ ]] || { echo "land-direct-main: ZF_LAND_PREFLIGHT_SLOTS must be a positive integer" >&2; return 2; }
  # FIFO: only the oldest live waiter tries the slots; a random race starved
  # one landing for 155 minutes on 2026-09-28. The command drops its ticket
  # when it starts, so the next waiter can take the other slot.
  local slot status waited=0 admission_checked=0 queue="$lock_dir/preflight-queue" ticket head t
  mkdir -p -- "$queue"
  ticket="${ZF_LAND_RELOAD_QUEUE_TICKET:-$queue/$(date +%s%N).$BASHPID}"
  export ZF_LAND_RELOAD_QUEUE_TICKET="$ticket"
  : > "$ticket"
  while :; do
    head=""
    for t in "$queue"/*; do
      [[ -e "$t" ]] || continue
      if kill -0 "${t##*.}" 2>/dev/null; then head="$t"; break; fi
      rm -f -- "$t"
    done
    if [[ "$head" == "$ticket" ]]; then
      if ((admission_checked == 0)); then
        if wait_for_preflight_memory; then
          admission_checked=1
        else
          status=$?
          rm -f -- "$ticket"
          return "$status"
        fi
      fi
      for ((slot = 1; slot <= slots; slot++)); do
        if flock -n -o -E 200 "$lock_dir/land-preflight-$slot.lock" \
          bash -c 'rm -f -- "$0"; exec "$@"' "$ticket" "$@"; then
          return 0
        else
          status=$?
        fi
        [[ "$status" == 200 ]] || { rm -f -- "$ticket"; return "$status"; }
      done
      # Memory can change while this waiter sits behind occupied slots. Recheck
      # before each later attempt to claim a newly freed slot.
      admission_checked=0
    fi
    [[ "$waited" == 1 ]] || echo "land-direct-main: waiting for a preflight slot" >&2
    waited=1
    sleep 2
  done
}

preflight() {
  # Only local safety checks block an infrastructure push; full verification owns post-land follow-up.
  local -a args=("$repo_root/scripts/branch-delivery-preflight.mjs" --mode push --target main --baseline-sha "$tested_base" --fast-path)
  local timeout_seconds="${ZF_LAND_PREFLIGHT_TIMEOUT_SECONDS:-1800}" ticket="${ZF_LAND_QUEUE_TICKET:-manual}" out started_at elapsed_ms status stage
  # Maintainer 10-29: direct-main accepts only non-product lanes; focused suites run in post-land Pipeline.
  args+=(--skip-focused-tests)
  [[ "$timeout_seconds" =~ ^[1-9][0-9]{0,3}$ ]] || {
    echo 'land-direct-main: preflight timeout must be a positive integer below 10000' >&2
    return 2
  }
  ((timeout_seconds > 1800)) && timeout_seconds=1800
  [[ "$ticket" =~ ^[0-9]{20}$ ]] || ticket=manual
  # Agents often leave a blank line between Plan-Package and Co-Authored-By, which hides the
  # package from git's trailer parser; join it here instead of refusing the landing (three
  # refusals and owner resumes on 2026-10-07/08, landings 265, 302 and 332).
  if grep -q '^Plan-Package: ' <<< "$(git log --format=%B "$tested_base..HEAD")"; then
    git rebase -q --exec "bash $(dirname -- "$self")/join-plan-package-trailer.sh" "$tested_base" || return 1
  fi
  check_commit_message_range "$tested_base..HEAD"
  printf 'land-direct-main: preflight baseline-sha=%s head=%s\n' "$tested_base" "$(git rev-parse HEAD)" >&2
  out="$(mktemp)"
  started_at="$(date +%s%3N)"
  if [[ "$fast_safety_only_path" == 1 ]]; then
    if ZF_LAND_QUEUE_TICKET="$ticket" ZF_PREFLIGHT_STAGE_TIMEOUT_SECONDS="${ZF_PREFLIGHT_STAGE_TIMEOUT_SECONDS:-1200}" \
        timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" node "${args[@]}" 2>&1 | tee "$out"; then
      status=0
    else
      status=$?
    fi
  else
    if ZF_LAND_QUEUE_TICKET="$ticket" ZF_PREFLIGHT_STAGE_TIMEOUT_SECONDS="${ZF_PREFLIGHT_STAGE_TIMEOUT_SECONDS:-1200}" \
        with_preflight_slot timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" node "${args[@]}" 2>&1 | tee "$out"; then
      status=0
    else
      status=$?
    fi
  fi
  elapsed_ms="$(($(date +%s%3N) - started_at))"
  stage="$(sed -n 's/^Preflight stage failed: ticket=[^ ]* stage=\([^ ]*\) duration_ms=.*/\1/p' "$out" | tail -n 1)"
  [[ -n "$stage" ]] || stage="$(sed -n 's/^Preflight stage started: ticket=[^ ]* stage=//p' "$out" | tail -n 1)"
  if [[ "$status" == 124 || "$status" == 137 ]] || grep -q '^Preflight stage failed: .*status=timed-out' "$out"; then
    echo "land-direct-main: preflight failed ticket=$ticket stage=${stage:-unknown} duration_ms=$elapsed_ms status=timed-out timeout_seconds=$timeout_seconds" >&2
    rm -f "$out"
    return 124
  fi
  if ((status != 0)); then
    echo "land-direct-main: preflight failed ticket=$ticket stage=${stage:-unknown} duration_ms=$elapsed_ms status=$status" >&2
    rm -f "$out"
    return "$status"
  fi
  echo "land-direct-main: preflight finished ticket=$ticket stage=${stage:-unknown} duration_ms=$elapsed_ms status=$status" >&2
  # A topic-branch ("trunk") pass runs neither rulings nor focused tests. On
  # 2026-09-25 a3bb6292 touched one path outside the lane, passed as trunk, and
  # landed an incident registry that broke check-rulings.
  if ! grep -qE '^Push preflight passed: .* \((development-system|documentation)-direct-main\)\.$' "$out"; then
    rm -f "$out"
    echo "land-direct-main: preflight did not select a direct-main flow; paths outside the pipeline/docs lane go through a PR" >&2
    return 1
  fi
  rm -f "$out"
}

# Shared with branch-delivery-preflight.mjs commit mode (engine/check-commit-messages.sh):
# hand agents hear the landing's commit-message refusals at commit time (landing 251, 2026-10-07).
check_commit_message_range() {
  bash "$(dirname -- "$self")/check-commit-messages.sh" "$1"
}

# Main push and manual runs share a non-preemptive workflow group. Never
# manufacture a commit to retrigger checks: dispatch the current main ref.
postsubmit_run_contains_sha() {
  local target_sha="$1" repo="${ZF_GH_REPO:-$REPO}" response cache_window_start
  cache_window_start="$(date -u -d '10 years ago' '+%Y-%m-%dT%H:%M:%SZ')" || return 2
  response="$(timeout --signal=TERM --kill-after=2s 45s gh api -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "repos/$repo/actions/workflows/ci.yml/runs?branch=main&per_page=100&created=%3E%3D${cache_window_start}" 2>/dev/null)" || return 2
  jq -e --arg sha "$target_sha" '
    any(.workflow_runs[]; .head_sha == $sha and .head_branch == "main"
      and (.event == "push" or .event == "workflow_dispatch")
      and .path == ".github/workflows/ci.yml"
      and (.status == "queued" or .status == "pending" or .status == "in_progress"
        or (.status == "completed" and .conclusion == "success")))
  ' <<< "$response" >/dev/null
}

revalidate_missing_postsubmit() {
  local requested="$1" target_sha main_sha run_status timeout_seconds claim_rc
  main_sha="$(git rev-parse origin/main)"
  target_sha="$main_sha"
  if [[ -n "$requested" ]]; then
    target_sha="$(git rev-parse --verify "$requested^{commit}")" || return 1
    git merge-base --is-ancestor "$target_sha" "$main_sha" || {
      echo "land-direct-main: main does not contain Postsubmit target $target_sha" >&2
      return 1
    }
  fi
  # Validate today's head, even when recovering an older missing target.
  if postsubmit_run_contains_sha "$main_sha"; then
    echo "land-direct-main: current main already has an active or green Postsubmit run"
    return 0
  else
    run_status=$?
    if [[ "$run_status" -eq 2 ]]; then
      echo "land-direct-main: could not read current main Postsubmit runs; retry next tick" >&2
      return 1
    fi
  fi
  timeout_seconds="${ZF_LAND_POSTSUBMIT_DISPATCH_TIMEOUT_SECONDS:-45}"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 2
  if postsubmit_request_dispatch_claim "$main_sha" 600 3 1; then :; else
    claim_rc=$?
    if [[ "$claim_rc" == 1 ]]; then
      echo "land-direct-main: Postsubmit request for $main_sha is already claimed or waiting for its retry window"
      return 0
    fi
    echo "land-direct-main: Postsubmit request claim for $main_sha is invalid or unreadable" >&2
    return 1
  fi
  if timeout --signal=TERM --kill-after=2s "${timeout_seconds}s" \
    gh workflow run ci.yml --repo "${ZF_GH_REPO:-$REPO}" --ref main -f "source_sha=$main_sha"; then
    postsubmit_request_record_write "$main_sha" requested "" "" || {
      echo "land-direct-main: Postsubmit request for $main_sha was dispatched but its shared result marker could not be saved" >&2
      return 1
    }
    echo "land-direct-main: dispatched Postsubmit revalidation ref=main head=$main_sha target=$target_sha"
  else
    run_status=$?
    postsubmit_request_record_write "$main_sha" dispatch-failed "" "" || \
      echo "land-direct-main: could not persist failed Postsubmit request state for $main_sha" >&2
    echo "land-direct-main: Postsubmit dispatch failed exit=$run_status; retry next tick" >&2
    return "$run_status"
  fi
}

# 2026-10-31 ruling: known non-product config ranges need only a JSON syntax check.
syntax_only_landing() {
  local base="$1" head="$2" pack_rel="${ZF_PACK_REL:-engine}" path found=0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    found=1
    case "$path" in
      packages/*|infra/*|deploy/*|migrations/*) return 1 ;;
    esac
    case "$path" in
      *.md|docs/*|lessons/*|"$pack_rel"/state/*.json|"$pack_rel"/prompts/*|\
        "$pack_rel"/mac-autopilot/config.template.json|.agents/skills/*) ;;
      *) return 1 ;;
    esac
  done < <(git diff --name-only --no-renames "$base...$head")
  (( found == 1 ))
}

# Only the focused post-land verdict is needed here. A green focused run itself
# dispatches the exact-SHA full run into #4719's batched main group.
pipeline_suites_main_focused_run_covers_sha() {
  local target_sha="$1" repo="${ZF_GH_REPO:-$REPO}" cache_window_start response
  cache_window_start="$(date -u -d '10 years ago' '+%Y-%m-%dT%H:%M:%SZ')" || return 2
  response="$(timeout --signal=TERM --kill-after=2s 45s gh api -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "repos/$repo/actions/workflows/pipeline-suites.yml/runs?branch=main&per_page=100&created=%3E%3D${cache_window_start}" 2>/dev/null)" || return 2
  jq -e --arg sha "$target_sha" '
    any(.workflow_runs[]?; .head_branch == "main"
      and (.event == "push" or .event == "workflow_dispatch")
      and .path == ".github/workflows/pipeline-suites.yml"
      and (.status == "queued" or .status == "pending" or .status == "in_progress"
        or (.status == "completed" and (.conclusion == "success" or .conclusion == "failure")))
      and (.display_title | startswith("Pipeline suites post-land " + $sha + " ")))
  ' <<< "$response" >/dev/null
}

dispatch_pipeline_suites_after_landing() {
  local main_sha="$1" base_sha="${2:-}" status=0 census_status=0 ticket="${direct_landing_ticket:-${ZF_LAND_QUEUE_TICKET:-unknown}}"
  local focused_covered=false
  # A target repo without the workflow (VectA since 10-31) has its pipeline suites in the engine's own CI.
  git cat-file -e "$main_sha:.github/workflows/pipeline-suites.yml" 2>/dev/null || return 0
  if pipeline_suites_main_focused_run_covers_sha "$main_sha"; then
    focused_covered=true
  else
    census_status=$?
    # An unreadable census must not drop the focused landing verdict.
    if [[ "$census_status" -eq 2 ]]; then
      echo "land-direct-main: Pipeline suites focused-run census unreadable for landed_sha=$main_sha; dispatching if the base is valid" >&2
    fi
  fi

  # The post-land group is independent of the non-preemptive main full-suite group.
  if [[ "$focused_covered" != true ]]; then
    if [[ ! "$base_sha" =~ ^[0-9a-f]{40}$ ]]; then
      status=2
    else
      if timeout --signal=TERM --kill-after=2s 45s \
        gh workflow run pipeline-suites.yml --repo "${ZF_GH_REPO:-$REPO}" --ref main \
          -f "post_land_base_sha=$base_sha" -f "post_land_head_sha=$main_sha"; then
        echo "land-direct-main: dispatched Pipeline suites post-land range ${base_sha:0:12}..${main_sha:0:12}"
      else
        status=$?
      fi
    fi
  fi

  if [[ "$status" -ne 0 && "$focused_covered" != true ]]; then
    echo "land-direct-main: Pipeline suites post-land focused dispatch failed landed_sha=$main_sha exit=$status recovery_owner=supervisor" >&2
    DRY_RUN=0 supervisor_inbox_append_once \
      "pipeline-suites-dispatch-failed:$main_sha" \
      "pipeline-suites-dispatch-failed landed_sha=$main_sha ticket=$ticket phase=focused ref=main exit=$status recovery_owner=supervisor action=inspect exact-SHA focused Pipeline suites run and redispatch only if absent" \
      || echo "land-direct-main: failed to record Pipeline suites dispatch recovery in supervisor inbox for $main_sha" >&2
    return "$status"
  fi
  return 0
}

landed_range_changes_postsubmit_input() {
  local base_sha="$1" head_sha="$2" changed_path
  while IFS= read -r -d '' changed_path; do
    case "$changed_path" in
      .dagger/*|scripts/ci/*|.github/workflows/ci.yml) return 0 ;;
    esac
  done < <(git diff --name-only --no-renames -z "$base_sha..$head_sha")
  return 1
}

# Paths whose landing runs engine/systemd/sync-cihost-*.sh on cihost after the push.
cihost_sync_path() {
  local -a globs=() # ZF_CIHOST_SYNC_PATHS (config.sh); read -a splits without pathname expansion
  local glob
  read -ra globs <<< "$ZF_CIHOST_SYNC_PATHS"
  for glob in ${globs[@]+"${globs[@]}"}; do
    [[ "$1" == $glob ]] && return 0
  done
  return 1
}

# The tree every sync-cihost-* script runs from: its own directory plus the sources it installs.
cihost_sync_archive() {
  local -a roots sync_roots=()
  read -ra sync_roots <<< "$ZF_CIHOST_SYNC_ROOTS"
  mapfile -t roots < <(git ls-tree --name-only "$1" -- ${sync_roots[@]+"${sync_roots[@]}"})
  git archive "$1" "${roots[@]}"
}

install_landed_host_artifacts() {
  local base="$1" path name dest unit_dest_dir units_changed=0 temp_dir
  local install_wrapper=0 install_units=0 sync_cihost=0 sync_path
  local -a landed_paths=()

  mapfile -t landed_paths < <(git diff --name-only "$base...HEAD")
  for path in "${landed_paths[@]}"; do
    if cihost_sync_path "$path"; then sync_cihost=1; continue; fi
    case "$path" in
      "$ZF_PACK_REL"/install-gitnexus-wrapper.sh|"$ZF_PACK_REL"/gitnexus-wrapper.sh)
        install_wrapper=1
        ;;
      "$ZF_PACK_REL"/systemd/*.service|"$ZF_PACK_REL"/systemd/*.timer)
        install_units=1
        ;;
    esac
  done

  if ((!install_wrapper && !install_units && !sync_cihost)); then return 0; fi
  if ! land_git_fetch_main; then
    echo "land-direct-main: could not fetch origin/main before installing host artifacts" >&2
    return 1
  fi
  if ! git merge-base --is-ancestor HEAD origin/main; then
    echo "land-direct-main: refusing host install because HEAD is not on origin/main" >&2
    return 1
  fi

  if ((install_wrapper)); then
    ZF_REPO_DIR="$repo_root" \
      bash "${ZF_ENGINE_LIVE:-$repo_root/engine}/install-gitnexus-wrapper.sh"
  fi

  if ((install_units)); then
    unit_dest_dir="${SYSTEMD_USER_UNIT_DIR:-${HOME:?HOME is not set}/.config/systemd/user}"
    temp_dir="$(mktemp -d)"
    while IFS= read -r path; do
      case "$path" in */"$ZF_CIHOST_FILE_STEM"-*) continue ;; *.service|*.timer) ;; *) continue ;; esac
      name="${path##*/}"
      git show "origin/main:$path" > "$temp_dir/$name" || { rm -rf -- "$temp_dir"; return 1; }
      dest="$unit_dest_dir/$name"
      if [[ ! -f "$dest" ]] || ! cmp -s "$temp_dir/$name" "$dest"; then
        if ! install -D -m 0644 "$temp_dir/$name" "$dest"; then
          echo "land-direct-main: failed to install origin/main unit $name into $unit_dest_dir" >&2
          rm -rf -- "$temp_dir"
          return 1
        fi
        units_changed=1
        echo "land-direct-main: installed origin/main unit $name -> $unit_dest_dir" >&2
      fi
    done < <(git ls-tree -r --name-only origin/main -- "$ZF_PACK_REL/systemd")
    rm -rf -- "$temp_dir"
    if ((units_changed)) && ! systemctl --user daemon-reload; then
      echo "land-direct-main: systemd --user daemon-reload failed after installing origin/main units" >&2
      return 1
    fi
  fi

  # cihost units run on cihost, which has no checkout (10/07 reclaim fix sat on main
  # uninstalled for a day). Ship origin/main's systemd dir and run each sync there.
  # ops/host rides along: sync-cihost-* scripts install sources from it.
  # One sync failing (2026-10-10: dangling-image-reclaim timed out on a busy build lock) must not skip
  # the others or abort post-land steps; the supervisor hears which ones to rerun.
  if ((sync_cihost)); then
    local -a failed_syncs=()
    local -a sync_script_dirs=()
    local ci_config
    ci_config="$(zf_config_file ci.json 2>/dev/null || true)"
    if [[ -n "$ci_config" ]]; then
      mapfile -t sync_script_dirs < <(jq -r '.post_land_sync_script_dirs[]? | strings' "$ci_config")
    fi
    if ((${#sync_script_dirs[@]} == 0)); then
      sync_script_dirs=("$ZF_PACK_REL/systemd")
    fi
    while IFS= read -r sync_path; do
      if ! cihost_sync_archive origin/main | ssh -o BatchMode=yes -o ConnectTimeout=15 "$ZF_CIHOST_HOST" \
        "t=\$(mktemp -d) && tar -x -C \"\$t\" && bash \"\$t/$sync_path\"; s=\$?; rm -rf -- \"\$t\"; exit \$s"; then
        echo "land-direct-main: failed to run origin/main $sync_path on cihost" >&2
        failed_syncs+=("$sync_path")
        continue
      fi
      echo "land-direct-main: ran origin/main $sync_path on cihost" >&2
    done < <(git ls-tree -r --name-only origin/main -- "${sync_script_dirs[@]}" | LC_ALL=C sort -u | grep "/sync-$ZF_CIHOST_FILE_STEM-[^/]*\.sh\$" | grep -v '\.test\.sh$')
    if ((${#failed_syncs[@]})); then
      local sync_archive_cmd="git archive origin/main $ZF_CIHOST_SYNC_ROOTS"
      supervisor_inbox_append_once "cihost-sync-failed:$(git rev-parse --short origin/main)" \
        "cihost-sync-failed main=$(git rev-parse --short origin/main) landed but not installed on cihost: ${failed_syncs[*]}; rerun each with $sync_archive_cmd piped to ssh $ZF_CIHOST_HOST" || true
      return 1
    fi
  fi
}

if [[ "$revalidate_only" == 1 ]]; then
  if ! land_git_fetch_main; then
    echo "land-direct-main: could not fetch main before Postsubmit revalidation" >&2
    exit 1
  fi
  if revalidate_missing_postsubmit "$revalidate_target"; then
    exit 0
  else
    result=$?
    [[ "$result" -eq 2 ]] && exit 0
    exit "$result"
  fi
fi

if [[ -n "$reconcile_pr" ]]; then
  if reconcile_merged_pr "$reconcile_pr"; then
    exit 0
  else
    exit $?
  fi
fi

# Direct-main landings serialise on the main ref itself: the push of HEAD:main is the compare-and-swap.
# Git rejects a non-fast-forward, so a landing that lost the race fetches, rebases onto the winner,
# recomputes the metadata that depended on the main it saw and pushes again.
# No host-wide lock is taken; a killed landing leaves nothing for the next one to wait on.
tested_base=""
land_retry_count=0
land_main_rebase_after_advance() {
  local new_main="$1"
  land_configure_git_identity || return 1
  if ! drop_stale_fold_commits || ! land_rebase_record_shared_append "$new_main"; then
    echo "land-direct-main: rebase conflict after external main advance; resolve it, then rerun this script" >&2
    return 1
  fi
  tested_base="$new_main"
  land_retry_count=$((land_retry_count + 1))
  prepare_lesson_metadata_for_landing
  assign_plan_package_trailer || return 1
  land_append_owner_issue_references "$new_main" || return 1
  printf 'land-direct-main: rebased onto main=%s retry=%s; focused verification runs post-land\n' \
    "${new_main:0:12}" "$land_retry_count" >&2
}

# A lesson-only PR with no pending or colliding ID needs no preflight slot.
# Resolve IDs first in its disposable worktree; queue only an actual repair.
if [[ "$reconcile_only" == 1 && -z "$slot_held" ]]; then
  if ! land_git_fetch_main || ! land_configure_git_identity || ! drop_stale_fold_commits; then
    echo "land-direct-main: could not prepare merged-PR lesson reconciliation" >&2
    exit 1
  fi
  if [[ "${LESSON_ID_COMMIT_MODE:-amend}" != new ]] && ! land_git_rebase origin/main; then
    echo "land-direct-main: could not prepare merged-PR lesson reconciliation" >&2
    exit 1
  fi
  bash "$land_script_dir/lesson-fragments.sh" --fold "$repo_root"
  assign_lesson_ids
  assign_plan_package_trailer
  if [[ "${LESSON_ID_COMMIT_MODE:-amend}" == new ]] && ! land_git_rebase origin/main; then
    echo "land-direct-main: could not rebase merged-PR lesson reconciliation onto main" >&2
    exit 1
  fi
  if [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]]; then
    echo "land-direct-main: no lesson ID repair needed for merged PR"
    exit 0
  fi
  with_preflight_slot env LAND_PREFLIGHT_SLOT_HELD=1 bash "$self" "${orig_args[@]}"
  exit
fi

# Full verification/reconciliation paths take a slot before fetching, so a
# queued main advance cannot force them to repeat expensive checks. Direct-main
# safety-only landings skip this admission gate and run suites after push.
if [[ -z "$slot_held" && "$fast_safety_only_path" != 1 ]]; then
  with_preflight_slot env LAND_PREFLIGHT_SLOT_HELD=1 bash "$self" "${orig_args[@]}"
  exit
fi
land_phase start
recorded_main_base="$(git rev-parse --verify 'origin/main^{commit}' 2>/dev/null || true)"
if ! land_git_fetch_main; then
  echo "land-direct-main: could not fetch origin/main before preflight" >&2
  exit 1
fi
if ! land_configure_git_identity; then
  exit 1
fi
# Other worktrees can fetch during lesson folding; preflight must use the SHA we rebased onto.
tested_base="$(git rev-parse origin/main)"
if [[ -n "$recorded_main_base" ]] && ! git merge-base --is-ancestor "$recorded_main_base" "$tested_base"; then
  echo "land-direct-main: recorded origin/main base $recorded_main_base was rewritten off main (current=$tested_base)" >&2
  exit 1
fi
if ! drop_stale_fold_commits || ! land_rebase_record_shared_append "$tested_base"; then
  echo "land-direct-main: rebase conflict; resolve it, then rerun this script" >&2
  exit 1
fi
# M3 传感器/执行器分离（#4499）：规则文件清单内的 diff 只放行 supervisor 语法检查通道；
# unit 一律拒绝。每次落地输出一条 rule-lane 判定行。
bash "$land_script_dir/rule-lane.sh" "$tested_base" "$(git rev-parse HEAD)"
# 非产品配置落地只做 JSON 语法检查，在推送前做（2026-10-31 裁决）。
if syntax_only_landing "$tested_base" HEAD; then
  while IFS= read -r landed_path; do
    [[ "$landed_path" == *.json ]] && git cat-file -e "HEAD:$landed_path" 2>/dev/null || continue
    git show "HEAD:$landed_path" | jq empty >/dev/null 2>&1 \
      || { printf 'land-direct-main: non-product config syntax check failed path=%s\n' "$landed_path" >&2; exit 1; }
  done < <(git diff --name-only --no-renames "$tested_base...HEAD")
fi
prepare_lesson_metadata_for_landing
assign_plan_package_trailer
if ! land_append_owner_issue_references "$tested_base"; then
  echo 'land-direct-main: could not append owner issue references' >&2
  exit 1
fi
if [[ "$reconcile_only" == 1 && "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]]; then
  echo "land-direct-main: no lesson ID repair needed for merged PR"
  exit 0
fi
if ! merge_result_node_check "$repo_root" "$tested_base" "$(git rev-parse HEAD)"; then
  echo 'land-direct-main: refusing push because merge result Node syntax check failed' >&2
  exit 1
fi
land_phase preflight-start
preflight
land_phase preflight-passed
if [[ "$preflight_only" == 1 ]]; then
  echo "land-direct-main: preflight-only passed for $tested_base; not pushing"
  exit 0
fi

while :; do
  if ! land_git_fetch_main; then
    echo "land-direct-main: could not fetch origin/main before push" >&2
    exit 1
  fi
  main_after_fetch="$(git rev-parse origin/main)"
  if [[ "$main_after_fetch" != "$tested_base" ]]; then
    if land_main_rebase_after_advance "$main_after_fetch"; then :; else
      result=$?
      exit "$result"
    fi
    if ! merge_result_node_check "$repo_root" "$tested_base" "$(git rev-parse HEAD)"; then
      echo 'land-direct-main: refusing push because merge result Node syntax check failed after rebasing onto newer main' >&2
      exit 1
    fi
  else
    printf 'land-direct-main: verified-base fast path base=%s head=%s\n' "$tested_base" "$(git rev-parse HEAD)" >&2
  fi

  base_before_push="$tested_base"
  candidate_head="$(git rev-parse HEAD)"
  land_register_post_push_range "$base_before_push" "$candidate_head"
  if land_git_transport_retry land_git_network push origin HEAD:main; then
    echo "land-direct-main: pushed $branch to main"
    land_phase pushed
    printf 'land-direct-main: verification-summary retry_count=%s\n' "$land_retry_count" >&2
    if [[ -z "${ZF_LAND_RESULT_DIR:-}" ]]; then
      if ! bash "$land_script_dir/land-queue.sh" direct-landed \
          "$direct_landing_ticket" "$base_before_push" "$candidate_head"; then
        echo "land-direct-main: direct landed range remains pending recovery ticket=$direct_landing_ticket" >&2
        exit 1
      fi
    fi
    break
  else
    push_status=$?
  fi
  if [[ "$push_status" == 124 || "$push_status" == 137 ]]; then
    exit 1
  fi

  if ! land_git_fetch_main; then
    echo "land-direct-main: could not fetch origin/main after push failed" >&2
    exit 1
  fi
  main_after_fetch="$(git rev-parse origin/main)"
  if git merge-base --is-ancestor HEAD "$main_after_fetch"; then
    echo "land-direct-main: origin/main contains HEAD; push acknowledgment was lost"
    if [[ -z "${ZF_LAND_RESULT_DIR:-}" ]]; then
      candidate_head="$(git rev-parse HEAD)"
      bash "$land_script_dir/land-queue.sh" direct-landed \
        "$direct_landing_ticket" "$base_before_push" "$candidate_head"
    fi
    break
  fi
  if [[ "$main_after_fetch" == "$tested_base" ]]; then
    echo "land-direct-main: push failed and origin/main did not advance" >&2
    exit 1
  fi

  # Another landing won the race: rebase onto it and push again.
  if land_main_rebase_after_advance "$main_after_fetch"; then :; else
    result=$?
    exit "$result"
  fi
done

# 2026-10-30 (#4728): one supervisor-inbox event per landing replaces the
# head supervisor polling git fetch to discover them. Reached on both
# push-success and lost-acknowledgment exits from the loop above; every other
# exit left origin/main without this commit. run-tick.sh reports the main
# advances it observes, but this landing fast-forwards the live checkout
# below, so this event is the landing's only inbox record.
DRY_RUN=0 supervisor_inbox_append landing \
  "ticket=${direct_landing_ticket:-unknown} branch=$branch lane=direct-main subject=\"$(git log -1 --format=%s)\"" \
  || echo "land-direct-main: failed to record landing event in supervisor inbox" >&2

# Pipeline suites on the landed head verify the push; the lander only records the range.
echo "land-direct-main: landed range recorded ${base_before_push:0:12}..${candidate_head:0:12}"
install_landed_host_artifacts "$base_before_push" \
  || echo "land-direct-main: host artifact install incomplete; the landing stands and the supervisor inbox names what to rerun" >&2
# Non-product changes take effect at push, not at the next tick's fast-forward (up to ~20 min;
# 2026-10-08 landing 333 ran the pre-fix lander 3 minutes after the fix landed).
live_checkout="${AGENT_HOME:-$HOME/.zenoforge}/checkout"
if [[ -d "$live_checkout/.git" || -f "$live_checkout/.git" ]] \
  && [[ -z "$(git -C "$live_checkout" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  live_old_head="$(git -C "$live_checkout" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$live_old_head" ]] && (cd -- "$live_checkout" && land_git_network fetch -q origin main) \
    && git -C "$live_checkout" merge -q --ff-only origin/main; then
    live_new_head="$(git -C "$live_checkout" rev-parse HEAD)"
    echo "land-direct-main: live checkout fast-forwarded to origin/main" >&2
    host_daemon_check="$(zf_host_ops_file scripts/agent/check-host-daemons.py "${ZF_ENGINE_LIVE:-$live_checkout/engine}/check-host-daemons.py")"
    if [[ -f "$host_daemon_check" ]] && ! python3 -B \
      "$host_daemon_check" "$live_checkout" --sync "$live_old_head" "$live_new_head"; then
      supervisor_inbox_append_once "host-daemon-sync-failed:$live_new_head" \
        "host-daemon-sync-failed main=$live_new_head; run check-host-daemons.py against live checkout and restart affected units" || true
    fi
    if ! sync_model_policy_default_after_fast_forward \
      "$live_checkout" "${AGENT_HOME:-$HOME/.zenoforge}" "$live_old_head" "$live_new_head"; then
      echo "land-direct-main: live policy sync failed; supervisor inbox has the reason" >&2
    fi
  else
    echo "land-direct-main: live checkout not fast-forwarded (dirty or diverged); the next tick retries" >&2
  fi
else
  echo "land-direct-main: live checkout not fast-forwarded (dirty or diverged); the next tick retries" >&2
fi
# Ordinary development-system/documentation landings leave Postsubmit untouched; only landed ranges that
# change its inputs request an exact-main-SHA validation. The helper skips an active or green run and
# keeps dispatch failures recoverable without changing the successful landing result.
main_sha="$(git rev-parse HEAD)"
dispatch_status=0
if syntax_only_landing "$base_before_push" "$candidate_head"; then
  echo 'land-direct-main: non-product config landing; post-land Pipeline suites skipped (2026-10-31 ruling)'
elif dispatch_pipeline_suites_after_landing "$main_sha" "$base_before_push"; then :; else dispatch_status=$?; fi
if landed_range_changes_postsubmit_input "$base_before_push" "$candidate_head"; then
  if revalidate_missing_postsubmit "$main_sha"; then :; else
    postsubmit_status=$?
    echo "land-direct-main: Postsubmit revalidation request failed for landed range ${base_before_push:0:12}..${candidate_head:0:12} exit=$postsubmit_status; landing remains successful" >&2
  fi
fi
if ((dispatch_status != 0)); then exit "$dispatch_status"; fi
