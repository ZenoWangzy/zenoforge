#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

# Functions that exist only in lib.sh / lib.d: scheduler context reaches them through
# (source "$SCHEDULER_AGENT_LIB"; fn ...), so a bare call elsewhere in scheduler.d is a bug.
agent_lib_only_names() {
  local root="$1" path
  local -a lib=() mac=()
  mapfile -t lib < <(git -C "$root" ls-files -- engine/lib.sh 'engine/lib.d/*.sh')
  mapfile -t mac < <(git -C "$root" ls-files -- 'engine/mac-autopilot/*.sh' | grep -Ev '\.test\.sh$|/test-[^/]*\.sh$' || true)
  comm -23 \
    <(for path in "${lib[@]}"; do sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)\(\) *\{.*/\1/p' "$root/$path"; done | sort -u) \
    <(for path in "${mac[@]:-}"; do [[ -n "$path" ]] && sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)\(\) *\{.*/\1/p' "$root/$path"; done | sort -u)
}

# One ERE: a name in command position (start of line, space, ; & | ( { or backquote), as a whole word.
agent_lib_call_pattern() {
  local IFS='|'
  printf '(^[[:space:]]*|[;&|({`][[:space:]]*)(%s)([^[:alnum:]_]|$)\n' "$*"
}

# Flagged lines of one file as "N:text": no comment lines, and no line that already names SCHEDULER_AGENT_LIB.
agent_lib_call_lines() {
  local root="$1" path="$2" pattern="$3" line text name lib_path module
  local -a lib_paths=()
  mapfile -t lib_paths < <(git -C "$root" ls-files -- engine/lib.sh 'engine/lib.d/*.sh')
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    text="${line#*:}"
    [[ "$text" != *SCHEDULER_AGENT_LIB* ]] || continue
    name="$(grep -oE -- "$pattern" <<< "$text" | sed -n '1p' | sed -E 's/^[^A-Za-z_]+//; s/[^A-Za-z0-9_].*//')"
    [[ -n "$name" ]] || continue
    module=lib
    for lib_path in "${lib_paths[@]}"; do
      if grep -qE "^[[:space:]]*${name}\\(\\)[[:space:]]*\\{" "$root/$lib_path"; then
        module="${lib_path##*/}"
        module="${module%.sh}"
        break
      fi
    done
    [[ "$module" != transport && "$module" != issue-rest && "$module" != gh-tick-cache ]] || continue
    if awk -v target="${line%%:*}" -v module="$module" '
      /^[[:alnum:]_]+\(\)[[:space:]]*[({]/ { scoped=0 }
      $0 ~ "scheduler_scope_lib[[:space:]]+" module "([[:space:]]|$)" { scoped=1 }
      NR == target { exit !scoped }
    ' "$root/$path"; then continue; fi
    printf '%s\n' "$line"
  done < <(sed -E 's/[[:space:]]+#.*$//' "$root/$path" | grep -nE -- "$pattern" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
}

# "<file> <count>" per non-test scheduler.d file.
agent_lib_call_counts() {
  local root="$1" path count pattern lines
  local -a names=()
  mapfile -t names < <(agent_lib_only_names "$root")
  (( ${#names[@]} > 0 )) || { printf 'REFUSAL found="no agent-lib-only functions found under %s" alternative="check the library and scheduler function definitions" documented_in=docs/enforced-rules.md\n' "$root" >&2; return 1; }
  pattern=$(agent_lib_call_pattern "${names[@]}")
  while IFS= read -r path; do
    [[ -n "$path" && "${path##*/}" != *.test.sh && "${path##*/}" != test-*.sh ]] || continue
    lines=$(agent_lib_call_lines "$root" "$path" "$pattern")
    count=$(printf '%s' "$lines" | grep -c . || true)
    printf '%s %s\n' "$path" "$count"
  done < <(git -C "$root" ls-files -- 'engine/mac-autopilot/scheduler.d/*.sh')
}

agent_lib_call_ratchet() {
  local root="$1" baseline="$2" path count old line num text name fail=0 total=0 files=0
  local -A baseline_counts=() seen=()
  local -a names=()
  local pattern
  while read -r path count; do
    [[ -n "${path:-}" ]] || continue
    baseline_counts["$path"]="$count"
  done < "$baseline"

  mapfile -t names < <(agent_lib_only_names "$root")
  (( ${#names[@]} > 0 )) || { printf 'REFUSAL found="no agent-lib-only functions found under %s" alternative="check the library and scheduler function definitions" documented_in=docs/enforced-rules.md\n' "$root" >&2; return 1; }
  pattern=$(agent_lib_call_pattern "${names[@]}")
  while read -r path count; do
    seen["$path"]=1
    total=$((total + count))
    (( count == 0 )) || files=$((files + 1))
    if [[ -z "${baseline_counts[$path]:-}" ]]; then
      fail=1
      printf 'REFUSAL found="%s is missing from %s" alternative="add the path with its measured count when it enters the ratchet scope" documented_in=docs/enforced-rules.md\n' "$path" "$baseline"
    elif (( count > baseline_counts[$path] )); then
      fail=1
      printf 'REFUSAL found="%s has %s agent-lib-only calls, baseline %s" alternative="call it as (source SCHEDULER_AGENT_LIB; fn ...), or define it in scheduler context" documented_in=docs/enforced-rules.md; lines naming an agent-lib-only function (the new one is among them):\n' \
        "$path" "$count" "${baseline_counts[$path]}"
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        num=${line%%:*}; text=${line#*:}
        name=$(printf '%s\n' "$text" | grep -oE "$pattern" | sed -n '1p' | sed -E 's/^[^A-Za-z_]+//; s/[^A-Za-z0-9_].*//') || name='?'
        printf '  %s:%s calls %s\n' "$path" "$num" "$name"
      done < <(agent_lib_call_lines "$root" "$path" "$pattern")
    elif (( count < baseline_counts[$path] )); then
      printf 'NOTE %s is at %s, lower its baseline from %s\n' "$path" "$count" "${baseline_counts[$path]}"
    fi
  done < <(agent_lib_call_counts "$root")

  for path in "${!baseline_counts[@]}"; do
    [[ "${seen[$path]:-0}" == 1 ]] || printf 'NOTE %s is in %s but no longer tracked\n' "$path" "$baseline"
  done

  (( fail == 0 )) || return 1
  printf 'agent-lib call ratchet ok: %s calls in %s files\n' "$total" "$files"
}

repo_root="$MODEL_POLICY_TEST_REPO"
agent_lib_call_ratchet "$repo_root" "$repo_root/engine/agent-lib-call-baseline.txt"

mkdir -p "$repo_root/.tmp"
fixture_root="$(mktemp -d "$repo_root/.tmp/agent-lib-call-ratchet.XXXXXX")"
trap 'rm -rf -- "$fixture_root" "$test_env_root"' EXIT
# The fixture is a copy of every tracked file the scan reads, so the clean copy must pass the real baseline.
git -C "$repo_root" ls-files -z -- engine/lib.sh engine/lib.d engine/mac-autopilot |
  while IFS= read -r -d '' path; do
    mkdir -p "$fixture_root/${path%/*}"
    cp "$repo_root/$path" "$fixture_root/$path"
  done
git -C "$fixture_root" init -q -b main
git -C "$fixture_root" add -A -- engine
fixture_output="$fixture_root/output.txt"
baseline="$repo_root/engine/agent-lib-call-baseline.txt"
injected='engine/mac-autopilot/scheduler.d/recut-reopen.sh'

if ! agent_lib_call_ratchet "$fixture_root" "$baseline" > "$fixture_output" 2>&1; then
  printf 'agent-lib-call-ratchet.test.sh: the clean fixture failed the real baseline: %s\n' "$(cat "$fixture_output")" >&2
  exit 1
fi
if ! grep -Fq 'agent-lib call ratchet ok:' "$fixture_output"; then
  printf 'agent-lib-call-ratchet.test.sh: clean fixture lacks success summary: %s\n' "$(cat "$fixture_output")" >&2
  exit 1
fi

injected_count=$(( $(awk -v path="$injected" '$1 == path { print $2 }' "$baseline") + 1 ))
for ((i = 0; i < injected_count; i += 1)); do
  printf 'supervisor_inbox_append x y\n' >> "$fixture_root/$injected"
done
injected_line=$(wc -l < "$fixture_root/$injected")
if agent_lib_call_ratchet "$fixture_root" "$baseline" > "$fixture_output" 2>&1; then
  printf 'agent-lib-call-ratchet.test.sh: a bare agent-lib call passed\n' >&2
  exit 1
else
  rc=$?
fi
if (( rc != 1 )) || ! grep -Fq "REFUSAL found=\"$injected has " "$fixture_output" \
  || ! grep -Fq 'alternative="call it as (source SCHEDULER_AGENT_LIB; fn ...), or define it in scheduler context" documented_in=docs/enforced-rules.md' "$fixture_output" \
  || ! grep -Fq "$injected:$injected_line calls supervisor_inbox_append" "$fixture_output"; then
  printf 'agent-lib-call-ratchet.test.sh: bare call failure was unexpected (rc %s): %s\n' "$rc" "$(cat "$fixture_output")" >&2
  exit 1
fi

echo 'agent-lib-call-ratchet.test.sh: all assertions passed'
