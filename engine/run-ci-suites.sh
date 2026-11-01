#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/config.sh"
cd "$ZF_REPO_DIR"

ci_config="$(zf_config_file ci.json 2>/dev/null || true)"
extra_suite_roots=()
if [[ -n "$ci_config" ]]; then
  mapfile -t extra_suite_roots < <(jq -r '.pipeline_suite_roots[]? | strings' "$ci_config")
fi
export ZF_ENGINE_DIR ZF_REPO_DIR
suite_roots=(engine "${extra_suite_roots[@]}")

shard_index=0
shard_count=1
suite_tier=all
if (($#)); then
  if (($# == 1)) && [[ "$1" == --nightly ]]; then
    suite_tier=nightly
  elif (($# == 2)) && [[ "$1" == --shard ]] && [[ "$2" =~ ^([0-9]+)/([1-9][0-9]*)$ ]]; then
    shard_index="${BASH_REMATCH[1]}"
    shard_count="${BASH_REMATCH[2]}"
    if ((shard_index >= shard_count)); then
      echo 'ERROR run-ci-suites: shard index must be less than shard count' >&2
      exit 2
    fi
  else
    echo 'ERROR run-ci-suites: usage: run-ci-suites.sh [--shard INDEX/COUNT | --nightly]' >&2
    exit 2
  fi
fi

# Long full-script suites run in the scheduled tier and are omitted by default.
nightly_suite_paths=(
  engine/land-direct-main.test.sh
  engine/run-advisor.test.sh
)

suite_jobs="${RUN_CI_SUITES_JOBS:-1}"
if [[ ! "$suite_jobs" =~ ^[1-4]$ ]]; then
  echo 'ERROR run-ci-suites: RUN_CI_SUITES_JOBS must be 1-4' >&2
  exit 2
fi

if ((shard_index == 0)); then
  AGENT_RULINGS_MODE=static bash engine/check-rulings.sh
fi

mapfile -t shell_suites < <(
  for suite_root in "${suite_roots[@]}"; do
    [[ -d "$suite_root" ]] || continue
    find "$suite_root" -type f \( -name '*.test.sh' -o \( -name 'test-*.sh' ! -name 'test-env.sh' \) \) ! -path 'scripts/release/run-release.test.sh' -print
  done | LC_ALL=C sort -u
)
mapfile -t node_suites < <(
  for suite_root in "${suite_roots[@]}"; do
    [[ -d "$suite_root" ]] || continue
    find "$suite_root" -type f -name '*.test.mjs' -print
  done | LC_ALL=C sort -u
)
product_timers_policy="$(zf_config_file systemd/pipeline-timers.list || true)"
if [[ -n "$product_timers_policy" ]]; then
  product_systemd_dir="$(dirname -- "$product_timers_policy")"
  mapfile -t product_systemd_shell_suites < <(find "$product_systemd_dir" -maxdepth 1 -type f -name '*.test.sh' -print | LC_ALL=C sort)
  mapfile -t product_systemd_node_suites < <(find "$product_systemd_dir" -maxdepth 1 -type f -name '*.test.mjs' -print | LC_ALL=C sort)
  if ((${#product_systemd_shell_suites[@]})); then shell_suites+=("${product_systemd_shell_suites[@]}"); fi
  if ((${#product_systemd_node_suites[@]})); then node_suites+=("${product_systemd_node_suites[@]}"); fi
fi
# A configured product root may own a suite that used to live under engine/.
# Keep named scheduled suites in the same tier after that move, preferring the
# engine path whenever it still exists.
mapfile -t nightly_suite_paths < <(
  for requested in "${nightly_suite_paths[@]}"; do
    found=0
    for suite in "${shell_suites[@]}" "${node_suites[@]}"; do
      if [[ "$suite" == "$requested" ]]; then
        printf '%s\n' "$suite"
        found=1
        break
      fi
    done
    if ((found == 0)); then
      basename="${requested##*/}"
      for suite in "${shell_suites[@]}" "${node_suites[@]}"; do
        if [[ "${suite##*/}" == "$basename" ]]; then
          printf '%s\n' "$suite"
          found=1
          break
        fi
      done
    fi
    ((found == 1)) || printf '%s\n' "$requested"
  done
)
suite_count=${#node_suites[@]}
for suite in "${shell_suites[@]}"; do
  [[ "$suite" == engine/sweep-brief-banners.test.sh ]] || suite_count=$((suite_count + 1))
done
if ((suite_count == 0)); then
  echo 'ERROR run-ci-suites: No pipeline test suites found' >&2
  exit 1
fi
if ((shard_count > suite_count)); then
  echo 'ERROR run-ci-suites: shard count exceeds discovered suite count' >&2
  exit 2
fi

scheduled_suite() {
  local suite="$1" candidate
  shift
  for candidate in "$@"; do
    [[ "$candidate" == "$suite" ]] && return 0
  done
  return 1
}

is_nightly_suite() {
  local suite="$1" nightly_suite
  for nightly_suite in "${nightly_suite_paths[@]}"; do
    [[ "$suite" == "$nightly_suite" ]] && return 0
  done
  return 1
}
select_nightly_suites() {
  local requested suite
  for requested in "${nightly_suite_paths[@]}"; do
    for suite in "$@"; do
      [[ "$suite" == "$requested" ]] && printf '%s\0' "$suite"
    done
  done
}
select_pr_shard_suites() {
  local suite
  for suite in "$@"; do
    is_nightly_suite "$suite" || printf '%s\0' "$suite"
  done
}

if [[ "$suite_tier" == nightly ]]; then
  for suite in "${nightly_suite_paths[@]}"; do
    scheduled_suite "$suite" "${shell_suites[@]}" "${node_suites[@]}" \
      || { echo "ERROR run-ci-suites: nightly suite is missing or not scheduled: $suite" >&2; exit 1; }
  done
  mapfile -d '' -t shell_suites < <(select_nightly_suites "${shell_suites[@]}" "${node_suites[@]}")
  node_suites=()
elif [[ "${RUN_CI_SUITES_INCLUDE_NIGHTLY:-0}" != "1" ]]; then
  mapfile -d '' -t shell_suites < <(select_pr_shard_suites "${shell_suites[@]}")
  mapfile -d '' -t node_suites < <(select_pr_shard_suites "${node_suites[@]}")
fi

selected_suite_count=$((${#shell_suites[@]} + ${#node_suites[@]}))
if ((selected_suite_count == 0)); then
  echo "ERROR run-ci-suites: No suites selected for tier=${suite_tier}" >&2
  exit 1
fi
if ((shard_count > selected_suite_count)); then
  echo "ERROR run-ci-suites: shard count exceeds selected suite count (${selected_suite_count})" >&2
  exit 2
fi

# shortcut: use max observed full-run timings; unmeasured suites get 10s until successful per-suite timings are logged.
suite_weight_seconds() {
  case "$1" in
    engine/check-rulings.test.sh) echo 211 ;;
    engine/concluded-root-unblock.test.sh) echo 106 ;;
    engine/dispatch-codex.test.sh) echo 37 ;;
    engine/hand-blocked-on-dependency.test.sh) echo 60 ;;
    engine/issue-pipeline.test.sh) echo 47 ;;
    */land-direct-main.test.sh) echo 157 ;;
    engine/land-queue.test.sh) echo 101 ;;
    engine/lib.test.sh) echo 399 ;;
    engine/night/night.test.sh) echo 1092 ;;
    engine/night/outcomes-audit.test.sh) echo 68 ;;
    */reclaim-disk.test.sh) echo 145 ;;
    engine/run-advisor.test.sh) echo 533 ;;
    engine/run-recut.test.sh) echo 94 ;;
    scripts/release/run-release-suite-release-entry.test.sh) echo 420 ;;
    scripts/release/run-release-suite-rollback.test.sh) echo 410 ;;
    scripts/release/run-release-suite-postdeploy.test.sh) echo 500 ;;
    scripts/release/run-release-suite-reconcile.test.sh) echo 400 ;;
    engine/run-triage-batch.test.sh) echo 76 ;;
    engine/run-triage.test.sh) echo 116 ;;
    engine/supervise-pipeline.test.sh) echo 35 ;;
    engine/worktree-lifecycle.test.sh) echo 228 ;;
    *) echo 10 ;;
  esac
}

# One policy for shell and Node suites, using the same measured weights as sharding.
suite_timeout_floor=300
suite_timeout_multiplier=3
suite_timeout_seconds() {
  local budget=$(($(suite_weight_seconds "$1") * suite_timeout_multiplier))
  ((budget >= suite_timeout_floor)) || budget="$suite_timeout_floor"
  printf '%s\n' "$budget"
}
export suite_timeout_floor suite_timeout_multiplier
export -f suite_weight_seconds suite_timeout_seconds

declare -A suite_shards=()
declare -a shard_loads=()
for ((shard = 0; shard < shard_count; shard++)); do shard_loads[shard]=0; done
mapfile -t weighted_suites < <(
  for suite in "${shell_suites[@]}" "${node_suites[@]}"; do
    [[ "$suite" == engine/sweep-brief-banners.test.sh ]] && continue
    printf '%s\t%s\n' "$(suite_weight_seconds "$suite")" "$suite"
  done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2
)
for weighted_suite in "${weighted_suites[@]}"; do
  weight="${weighted_suite%%$'\t'*}"
  suite="${weighted_suite#*$'\t'}"
  target_shard=0
  for ((shard = 1; shard < shard_count; shard++)); do
    if ((shard_loads[shard] < shard_loads[target_shard])); then target_shard="$shard"; fi
  done
  suite_shards["$suite"]="$target_shard"
  shard_loads[target_shard]=$((shard_loads[target_shard] + weight))
done
select_shard_suites() {
  local suite
  for suite in "$@"; do
    if [[ "${suite_shards[$suite]:-}" == "$shard_index" ]]; then printf '%s\0' "$suite"; fi
  done
}
mapfile -d '' -t shell_suites < <(select_shard_suites "${shell_suites[@]}")
mapfile -d '' -t node_suites < <(select_shard_suites "${node_suites[@]}")
printf '[pipeline suites] shard=%s/%s shell=%s node=%s\n' \
  "$((shard_index + 1))" "$shard_count" "${#shell_suites[@]}" "${#node_suites[@]}"
printf '[pipeline suites] tier=%s\n' "$suite_tier"

# ponytail: default to 2; cap at 4 until main-run timings show headroom.
shell_started=$SECONDS
shell_result_dir="$(mktemp -d /tmp/zenoforge-agent-suite-results-XXXXXX)"
trap 'rm -rf -- "$shell_result_dir"' EXIT
if printf '%s\0' "${shell_suites[@]}" "${node_suites[@]}" | xargs -0 -r -n1 -P "$suite_jobs" bash -c '
  set -euo pipefail
  shell_result_dir="$1"
  suite="$2"
  case "$suite" in
    engine/sweep-brief-banners.test.sh) exit 0 ;; # Calls real systemctl --user.
  esac
  started=$SECONDS
  suite_timeout="$(suite_timeout_seconds "$suite")"
  printf "[pipeline suites] %s timeout=%ss\n" "$suite" "$suite_timeout"
  suite_tmp="$(mktemp -d /tmp/zenoforge-agent-suite-XXXXXX)"
  trap "rm -rf -- \"$suite_tmp\"" EXIT
  suite_log="$suite_tmp/output.log"
  set +e
  # timeout leads its own process group but signals it only on expiry. A suite that exits while a descendant
  # still holds this pipe would leave tee, and the CI job, waiting until the job limit, so kill that group too.
  {
    case "$suite" in
      *.test.mjs) LC_ALL=C TMPDIR="$suite_tmp" timeout --verbose -s KILL "$suite_timeout" node --test --test-concurrency=1 "$suite" & ;;
      *) LC_ALL=C TMPDIR="$suite_tmp" timeout --verbose -s KILL "$suite_timeout" bash "$suite" & ;;
    esac
    timeout_pid=$!
    wait "$timeout_pid"
    suite_status=$?
    if kill -KILL -- "-$timeout_pid" 2>/dev/null; then
      printf "[pipeline suites] %s left running descendants; killed their process group\n" "$suite"
    fi
    exit "$suite_status"
  } 2>&1 | tee "$suite_log"
  child_statuses=("${PIPESTATUS[@]}")
  set -e
  status="${child_statuses[0]}"
  if ((status != 0)); then
    if ((status == 137)) && grep -Fq "timeout: sending signal KILL" "$suite_log"; then
      first_error="suite $suite timed out after ${suite_timeout}s"
      printf "[pipeline suites] %s\n" "$first_error"
    else
      first_error="$(grep -m1 -E "^(not ok|FAIL|ERROR|Error:)" "$suite_log" || true)"
    fi
    if [[ -z "$first_error" ]]; then first_error="no matching failure evidence"; fi
    first_error="${first_error:0:240}"
    result_file="$(mktemp "$shell_result_dir/result.XXXXXXXXXX")"
    printf "%s\t%s\t%s\n" "$status" "$suite" "$first_error" > "$result_file"
  fi
  printf "[pipeline suites] done suite=%s duration=%ss status=%s\n" "$suite" "$((SECONDS - started))" "$status"
  # xargs stops scheduling at 255; preserve raw exit in summary, continue shard.
  ((status != 255)) || status=1
  exit "$status"
' pipeline-suite "$shell_result_dir"; then
  shell_status=0
else
  shell_status=$?
fi
printf '[pipeline suites] shell suites duration=%ss status=%s\n' "$((SECONDS - shell_started))" "$shell_status"
if ((shell_status != 0)); then
  mapfile -t shell_failures < <(
    find "$shell_result_dir" -type f -name 'result.*' -exec cat {} + \
      | LC_ALL=C sort -t $'\t' -k2,2
  )
  if ((${#shell_failures[@]})); then
    for failure in "${shell_failures[@]}"; do
      IFS=$'\t' read -r failure_status failure_suite first_error <<< "$failure"
      printf '[pipeline suites] FAILED suite=%s exit_code=%s first_error=%s\n' \
        "$failure_suite" "$failure_status" "$first_error"
    done
  else
    echo '[pipeline suites] failure summary unavailable: no child status records captured' >&2
  fi
  exit "$shell_status"
fi
