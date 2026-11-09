#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
bin=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(mktemp -d); trap 'rm -rf "$root" "$test_env_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# gate <file> <avail_mb> <psi_full> <priority> <age_seconds> <cpu_busy>: prints admitted or refused.
# Loads the real box_has_room from the file. PSI some is fixed at 32 (the live value that used to block hotfix).
# LUNA_MIN=0 keeps the first tier out, and age and cpu are set so only the tier under test can admit.
gate() {
  local file=$1 d src; d=$(mktemp -d -p "$root")
  printf 'MemAvailable: %s kB\n' "$(( $2 * 1024 ))" >"$d/meminfo"
  printf 'some avg10=32 avg60=35 avg300=36 total=1\nfull avg10=%s avg60=4 avg300=4.6 total=1\n' "$3" >"$d/psi"
  src=$(awk '/^box_has_room\(\)/,/^}$/' "$file"); [[ -n $src ]] || fail "no box_has_room in $file"
  (
    export LUNA_PROC_MEMINFO="$d/meminfo" LUNA_PROC_PSI_MEMORY="$d/psi" LUNA_PRIORITY="$4" LUNA_MIN=0 LUNA_MAX=10
    export LUNA_AGE_ADMIT_SECONDS="$5" CPU_BUSY="$6"
    codex_runs() { echo 0; }
    cpu_busy() { echo "$CPU_BUSY"; }
    eval "$src"
    if box_has_room; then echo admitted; else echo refused; fi
  )
}
# expect <file> <avail_mb> <full> <priority> <age> <cpu> <want>
expect() {
  local got; got=$(gate "$1" "$2" "$3" "$4" "$5" "$6")
  [[ $got == "$7" ]] || fail "$(basename "$1") avail=$2 full=$3 prio=$4 age=$5 cpu=$6: got $got, want $7"
}

for f in "$bin/luna" "$bin/zc"; do
  #            file avail full prio   age  cpu want
  expect "$f"  4600   2   hotfix   999999 0   admitted # hotfix tier: 3 GB floor, full < 10
  expect "$f"  4600  12   hotfix   999999 0   refused  # full 12: refused for every tier
  expect "$f"  2500   2   hotfix   999999 0   refused  # hotfix below 3 GB
  expect "$f"  4600   2   normal   999999 0   refused  # normal needs 5 GB: 4600 is under
  expect "$f"  6000   2   normal   999999 0   admitted # normal tier: cpu under target, full < 10, 5 GB free
  expect "$f"  6000  12   normal   999999 0   refused  # normal, full 12
  expect "$f"  6000   2   normal        0 100  admitted # aging tier alone: cpu busy, aged, 5 GB free
  expect "$f"  6000  12   normal        0 100  refused  # aging, full 12
done
echo "ok - hotfix admits at 3 GB with full < 10; normal and aging admit at 5 GB with full < 10; full 12 refused; in luna and zc"
