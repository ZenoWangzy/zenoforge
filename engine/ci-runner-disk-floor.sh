#!/usr/bin/env bash
# Zenoforge-owned. Free-disk floor for a CI runner: ten percent of the disk, capped at 40 GiB.
# lib.sh sources this for the env:ci-runner-capacity / env:build-capacity probes; sourcing must run nothing else.
ci_runner_disk_capped_kb() {
  local total_kb=$1 required_kb
  required_kb=$(( total_kb / 10 ))
  (( required_kb > 41943040 )) && required_kb=41943040
  printf '%s\n' "$required_kb"
}
