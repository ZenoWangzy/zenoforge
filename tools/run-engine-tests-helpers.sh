#!/usr/bin/env bash

# Emit a stable signal when one suite consumes more than half its timeout.
engine_test_log_if_slow() {
  local file="$1" elapsed_seconds="$2" limit_seconds="$3"
  [[ "$elapsed_seconds" =~ ^[0-9]+$ && "$limit_seconds" =~ ^[0-9]+$ ]] || return 0
  (( elapsed_seconds * 2 > limit_seconds )) || return 0
  printf 'SLOW-TEST %s %s\n' "$file" "$elapsed_seconds"
}
