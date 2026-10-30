#!/usr/bin/env bash
# 批准后、占 CI 名额前，复用 CI 的 touched-package selector：改动包跑全套，依赖它的包跑 Vitest related。
# 本地只跑默认测试，不启用 RUN_INTEGRATION 或 PGTEST_URL；无法本地验证时 SKIP，继续交给 CI。
# 用法：precheck.sh <clone> <pr> <head> → 第一行 "PRECHECK: PASS|FAIL|SKIP <说明>"，FAIL 后附失败摘要。
# SKIP = 本机跑不了或 dependent 没有可选的 related 测试，照常交给 CI，绝不卡交付。
# 内存守卫 2 GiB：限制 worker 数，并对整个预检共用 PRECHECK_TIMEOUT_SECONDS。
set -uo pipefail
dir="$1" pr="$2" head="$3"
budget="${PRECHECK_TIMEOUT_SECONDS:-900}"
skip() { echo "PRECHECK: SKIP $*"; exit 0; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The scheduler runs this from the autopi-live copy, where ../.. is not the repo (10-28: every precheck SKIPped).
repo_root="${MAC_AUTOPILOT_ROOT:-$(cd "$script_dir/../.." && pwd)}"
evidence_script="$script_dir/test-evidence.py"
evidence_ledger="${ZF_TEST_EVIDENCE_LEDGER:-${MAC_AUTOPILOT_SUPERVISOR_DIR:-${HOME:-}/.zenoforge/supervisor}/test-evidence.jsonl}"

avail="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
[[ "$avail" =~ ^[0-9]+$ ]] && (( avail >= ${PRECHECK_MIN_MEM_KIB:-2097152} )) || skip "MemAvailable ${avail:-unknown} KiB below the 2 GiB guard"
command git -C "$dir" fetch -q origin main 2>/dev/null || skip "fetch of main failed"
command git -C "$dir" fetch -q origin "refs/pull/$pr/head" 2>/dev/null || skip "fetch of PR #$pr failed"
command git -C "$dir" checkout -q -f --detach "$head" 2>/dev/null && command git -C "$dir" clean -fdq 2>/dev/null || skip "checkout of $head failed"
tree="$(command git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null)" || skip "tree id for $head unavailable"
has_test_evidence() { python3 "$evidence_script" has "$evidence_ledger" "$tree" "$1"; }
record_test_evidence() {
  python3 "$evidence_script" record "$evidence_ledger" "$tree" "$1" precheck \
    || echo "PRECHECK: test evidence not persisted for $1" >&2
}
base="$(command git -C "$dir" merge-base origin/main "$head" 2>/dev/null)" || skip "no merge-base with main"

selection="$(node --experimental-strip-types "$repo_root/scripts/ci/touched-package-selection.mjs" \
  --repo "$dir" --base "$base" --head "$head" 2>/dev/null)" || skip "workspace package selection failed"
mapfile -t roots < <(jq -r '.rootPaths[]' <<< "$selection")
mapfile -t targets < <(jq -r '.affectedPaths[]' <<< "$selection")
(( ${#roots[@]} )) || skip "no affected workspace packages"

declare -A is_root=()
for p in "${roots[@]}"; do is_root["$p"]=1; done
source_files=()
while IFS= read -r f; do
  [[ "$f" =~ \.(ts|tsx|js|mjs)$ && -f "$dir/$f" ]] || continue
  source_files+=("$dir/$f")
done < <(command git -C "$dir" diff --name-only --diff-filter=ACMRT "$base" "$head" -- "${roots[@]}")

started_at=$SECONDS
remaining_seconds() {
  local remaining=$((budget - (SECONDS - started_at)))
  (( remaining > 0 )) || return 1
  printf '%s' "$remaining"
}
left="$(remaining_seconds)" || skip "precheck timed out after ${budget}s"
install_budget=600
(( left < install_budget )) && install_budget="$left"
install_filters=()
for p in "${targets[@]}"; do
  name="$(jq -r '.name' "$dir/$p/package.json")"
  install_filters+=("--filter=${name}...")
done
(cd "$dir" && timeout "$install_budget" pnpm install --frozen-lockfile --prefer-offline "${install_filters[@]}" >/dev/null 2>&1) \
  || skip "pnpm install failed or timed out"

out="$(mktemp)"; trap 'rm -f "$out"' EXIT
rc=0; ran=""
for p in "${roots[@]}"; do
  name="$(jq -r .name "$dir/$p/package.json")"
  left="$(remaining_seconds)" || skip "precheck timed out after ${budget}s"
  (cd "$dir" && timeout "$left" pnpm --filter "$name^..." run --if-present build >/dev/null 2>&1) \
    || skip "building dependencies of $name failed or timed out"
done

for p in "${targets[@]}"; do
  [[ -f "$dir/$p/package.json" ]] || continue
  test_script="$(jq -r '.scripts.test // ""' "$dir/$p/package.json")"
  [[ -n "$test_script" ]] || continue
  name="$(jq -r .name "$dir/$p/package.json")"
  test_target="test:$name"
  left="$(remaining_seconds)" || skip "precheck timed out after ${budget}s"
  if [[ -n "${is_root[$p]:-}" || "$test_script" != 'vitest run' ]]; then
    if has_test_evidence "$test_target"; then
      ran+="$p(reused) "
      continue
    fi
    (cd "$dir" && env -u RUN_INTEGRATION -u PGTEST_URL \
      VITEST_MAX_WORKERS=1 VITEST_MAX_FORKS=1 VITEST_MAX_THREADS=1 \
      timeout "$left" pnpm --filter "./$p" run test >> "$out" 2>&1)
    r=$?
    (( r == 124 )) && skip "package tests timed out after ${budget}s in $p"
    if (( r == 0 )); then record_test_evidence "$test_target"; else rc=$r; fi
    ran+="$p "
  else
    (( ${#source_files[@]} )) || skip "no changed source modules for dependent package $p"
    if has_test_evidence "$test_target"; then
      ran+="$p(reused) "
      continue
    fi
    related_paths="$(printf '%s\n' "${source_files[@]}" | sed "s|^$dir/||" | LC_ALL=C sort | paste -sd, -)"
    related_target="related-test:$name:$related_paths"
    if has_test_evidence "$related_target"; then
      ran+="$p(related-reused) "
      continue
    fi
    (cd "$dir" && env -u RUN_INTEGRATION -u PGTEST_URL \
      VITEST_MAX_WORKERS=1 VITEST_MAX_FORKS=1 VITEST_MAX_THREADS=1 \
      timeout "$left" pnpm --filter "./$p" exec vitest related --run "${source_files[@]}" \
        --no-file-parallelism --maxWorkers=1 >> "$out" 2>&1)
    r=$?
    (( r == 124 )) && skip "related tests timed out after ${budget}s in $p"
    if (( r != 0 )); then
      if grep -q 'No test files found' "$out"; then
        skip "Vitest found no related tests in $p"
      fi
      rc=$r
    else
      record_test_evidence "$related_target"
    fi
    ran+="$p(related) "
  fi
done
fails="$(sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -E ' FAIL |AssertionError|Error: ' | sort -u | head -20)"
if (( rc != 0 )); then
  [[ -n "$fails" ]] || skip "vitest exited $rc without a test failure (environment)"
  echo "PRECHECK: FAIL selected tests fail locally in ${ran% }"
  printf '%s\n' "$fails"
  exit 0
fi
echo "PRECHECK: PASS selected package and related tests pass in ${ran% }"
