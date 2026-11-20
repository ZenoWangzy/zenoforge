#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixtures="$test_env_root/doctor"
base="$fixtures/base"
host_path="$PATH"
mkdir -p "$base"

fail() { echo "doctor.test.sh: $*" >&2; exit 1; }
"$BASH" -n "$engine/doctor.sh" || fail 'doctor.sh has invalid Bash syntax'
if grep -nE '(^|[[:space:]])(declare[[:space:]]+-A|mapfile)([[:space:]]|$)' "$engine/doctor.sh"; then
  fail 'doctor.sh uses Bash features newer than 3.2'
fi

write_script() {
  local path="$1" body="$2"
  printf '#!/bin/sh\n%s\n' "$body" > "$path"
  chmod +x "$path"
}

write_script "$base/uname" 'case "$1" in -s) printf "Linux\\n" ;; -r) printf "6.1.0\\n" ;; esac'
write_script "$base/timeout" '[ "$1" = "--foreground" ] && [ "$2" = "-k" ] && [ "$3" = "1" ] && [ "$4" = "5" ] && [ "$5" = "/bin/true" ]'
write_script "$base/date" '[ "$1" = "-d" ] && [ "$2" = "@0" ] && [ "$3" = "+%s" ] && printf "0\\n"'
write_script "$base/flock" 'case "$1:$2" in -n:9|-u:9) exit 0 ;; *) exit 1 ;; esac'
write_script "$base/setsid" '[ "$1" = "--wait" ] && [ "$2" = "/bin/true" ]'
write_script "$base/systemctl" '[ "$1" = "--user" ] && [ "$2" = "show-environment" ]'

assert_row_count() {
  local output="$1" count=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] || count=$((count + 1))
  done <<< "$output"
  [[ "$count" == 6 ]] || fail "expected six check rows, got $count: $output"
}

assert_fail_rows_have_fixes() {
  local output="$1" line
  while IFS= read -r line; do
    case "$line" in
      FAIL\ *) [[ "$line" == *'[fix: '* ]] || fail "FAIL row has no fix: $line" ;;
    esac
  done <<< "$output"
}

assert_only_failure() {
  local output="$1" check="$2" count=0 line
  while IFS= read -r line; do
    case "$line" in
      FAIL\ *)
        count=$((count + 1))
        [[ "$line" == "FAIL  $check  "* ]] || fail "unexpected FAIL row: $line"
        ;;
    esac
  done <<< "$output"
  [[ "$count" == 1 ]] || fail "expected one FAIL row for $check, got $count: $output"
}

run_case() {
  local name="$1" path="$2" expected_rc="$3" failed_check="${4:-}" output rc=0
  if output="$(PATH="$path" "$BASH" "$engine/doctor.sh" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  [[ "$rc" == "$expected_rc" ]] || fail "$name: expected rc $expected_rc, got $rc: $output"
  assert_row_count "$output"
  assert_fail_rows_have_fixes "$output"
  if [[ -n "$failed_check" ]]; then
    assert_only_failure "$output" "$failed_check"
  fi
  printf '%s\n' "$output"
}

output="$(run_case baseline "$base:$host_path" 0)"
for check in 'GNU timeout' 'GNU date' flock setsid systemd 'WSL idle'; do
  [[ "$output" == *"PASS  $check  "* ]] || fail "baseline did not pass $check: $output"
done

for pair in 'timeout|GNU timeout' 'date|GNU date' 'flock|flock' 'setsid|setsid' 'systemctl|systemd'; do
  tool="${pair%%|*}"
  check="${pair#*|}"
  overlay="$fixtures/fail-$tool"
  mkdir -p "$overlay"
  write_script "$overlay/$tool" 'exit 1'
  run_case "$check failure" "$overlay:$base:$host_path" 1 "$check" >/dev/null
done

wsl="$fixtures/wsl"
mkdir -p "$wsl"
write_script "$wsl/uname" 'case "$1" in -s) printf "Linux\\n" ;; -r) printf "5.15.0-microsoft-standard-WSL2\\n" ;; esac'
output="$(run_case 'WSL-idle reminder' "$wsl:$base:$host_path" 0)"
[[ "$output" == *'WARN  WSL idle  '* && "$output" == *'instanceIdleTimeout=-1'* ]] || fail "WSL idle reminder missing: $output"

printf 'doctor.test.sh: PASS\n'
