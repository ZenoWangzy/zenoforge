#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

source_extract_line_count() {
  local root="$1" path="$2" count rc
  if count=$(grep -cE "sed -n ['\"]/\\^?[a-zA-Z_]" "$root/$path"); then
    printf '%s\n' "$count"
  else
    rc=$?
    if (( rc == 1 )) && [[ "$count" == 0 ]]; then
      printf '0\n'
    else
      return "$rc"
    fi
  fi
}

source_extract_ratchet() {
  local root="$1" baseline="$2" path count old fail=0 total=0 files=0
  local -A baseline_counts=() seen=()
  while IFS=$'\t' read -r count path; do
    [[ -n "${path:-}" ]] || continue
    baseline_counts["$path"]="$count"
  done < "$baseline"

  while IFS= read -r path; do
    [[ -n "$path" && "${path##*/}" == *'.test.sh'* ]] || continue
    [[ -f "$root/$path" ]] || continue
    count=$(source_extract_line_count "$root" "$path") || return $?
    seen["$path"]=1
    total=$((total + count))
    (( count == 0 )) || files=$((files + 1))
    old="${baseline_counts[$path]:-0}"
    if (( count > old )); then
      fail=1
      printf 'FAIL %s has %s source-extract lines, baseline %s\n' "$path" "$count" "$old"
    elif (( count < old )); then
      printf 'NOTE %s is at %s, lower its baseline from %s\n' "$path" "$count" "$old"
    fi
  done < <(git -C "$root" ls-files -- engine)

  for path in "${!baseline_counts[@]}"; do
    [[ "${seen[$path]:-0}" == 1 ]] || printf 'NOTE %s is in %s but no longer tracked\n' "$path" "$baseline"
  done

  (( fail == 0 )) || return 1
  printf 'source-extract ratchet ok: %s lines in %s files\n' "$total" "$files"
}

repo_root="$MODEL_POLICY_TEST_REPO"
source_extract_ratchet "$repo_root" "$repo_root/engine/source-extract-baseline.txt"

mkdir -p "$repo_root/.tmp"
fixture_root="$(mktemp -d "$repo_root/.tmp/source-extract-ratchet.XXXXXX")"
trap 'rm -rf -- "$fixture_root" "$test_env_root"' EXIT
mkdir -p "$fixture_root/engine"
git -C "$fixture_root" init -q -b main
{
  printf '%s%s%s%s\n' 'sed -n ' "'" '/^first() {/,/^}/p' "' engine/source.sh"
  printf '%s%s%s%s\n' 'sed -n ' '"' '/^second() {/,/^}/p' '" engine/source.sh'
} > "$fixture_root/engine/fake.test.sh"
git -C "$fixture_root" add engine/fake.test.sh
fixture_baseline="$fixture_root/source-extract-baseline.txt"
fixture_output="$fixture_root/output.txt"

printf '2\tengine/fake.test.sh\n' > "$fixture_baseline"
if ! source_extract_ratchet "$fixture_root" "$fixture_baseline" > "$fixture_output" 2>&1; then
  printf 'source-extract-ratchet.test.sh: an equal baseline failed: %s\n' "$(cat "$fixture_output")" >&2
  exit 1
fi
if ! grep -Fq 'source-extract ratchet ok: 2 lines in 1 files' "$fixture_output"; then
  printf 'source-extract-ratchet.test.sh: equal baseline lacks success summary: %s\n' "$(cat "$fixture_output")" >&2
  exit 1
fi

printf '1\tengine/fake.test.sh\n' > "$fixture_baseline"
if source_extract_ratchet "$fixture_root" "$fixture_baseline" > "$fixture_output" 2>&1; then
  printf 'source-extract-ratchet.test.sh: a count above baseline passed\n' >&2
  exit 1
else
  rc=$?
fi
if (( rc != 1 )) || ! grep -Fq 'FAIL engine/fake.test.sh has 2 source-extract lines, baseline 1' "$fixture_output"; then
  printf 'source-extract-ratchet.test.sh: over-baseline failure was unexpected: %s\n' "$(cat "$fixture_output")" >&2
  exit 1
fi

printf '3\tengine/fake.test.sh\n' > "$fixture_baseline"
if ! source_extract_ratchet "$fixture_root" "$fixture_baseline" > "$fixture_output" 2>&1; then
  printf 'source-extract-ratchet.test.sh: a count below baseline failed: %s\n' "$(cat "$fixture_output")" >&2
  exit 1
fi
if ! grep -Fq 'NOTE engine/fake.test.sh is at 2, lower its baseline from 3' "$fixture_output"; then
  printf 'source-extract-ratchet.test.sh: lower baseline note is missing: %s\n' "$(cat "$fixture_output")" >&2
  exit 1
fi

echo 'source-extract-ratchet.test.sh: all assertions passed'
