#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/dispatch-steps-report"
mkdir -p "$fixture"
cat > "$fixture/scheduler.log" <<'LOG'
[2026-11-28T00:00:00Z] dispatch detail steps refill=true scan=2.000s/2 load=1.000s/1
[2026-11-27T23:00:00Z] dispatch detail steps refill=true scan=20.000s/1 old=1.000s/1
[2026-11-28T00:02:00Z] dispatch detail steps refill=false scan=8.000s/2 check=4.000s/2
LOG
cat > "$fixture/scheduler.log.1" <<'LOG'
[2026-11-28T00:01:00Z] dispatch detail steps refill=true scan=4.000s/1 write=2.000s/1
[2026-11-28T00:03:00Z] dispatch detail steps refill=false scan=6.000s/1 write=2.000s/1
[2026-11-28T00:04:00Z] dispatch detail steps refill=true broken=not-a-duration/1
LOG

expect_report() {
  local expected=$1
  shift
  local actual
  actual="$(python3 "$script_dir/dispatch_steps_report.py" "$fixture/scheduler.log" "$fixture/scheduler.log.1" "$@")"
  [[ "$actual" == "$expected" ]] || {
    printf 'dispatch-steps-report.test.sh: output mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  }
}

expected_all="$(printf '%b' "$(cat <<'EXPECTED'
passes	5
pass_total_p50	8.000s
pass_total_p90	21.000s
step	passes	total	share	p50	p90
scan	5	40.000s	80.0%	6.000s	20.000s
check	1	4.000s	8.0%	4.000s	4.000s
write	2	4.000s	8.0%	2.000s	2.000s
load	1	1.000s	2.0%	1.000s	1.000s
old	1	1.000s	2.0%	1.000s	1.000s
unparsed_lines	1
EXPECTED
)")"
expected_since="$(printf '%b' "$(cat <<'EXPECTED'
passes	4
pass_total_p50	6.000s
pass_total_p90	12.000s
step	passes	total	share	p50	p90
scan	4	20.000s	69.0%	4.000s	8.000s
check	1	4.000s	13.8%	4.000s	4.000s
write	2	4.000s	13.8%	2.000s	2.000s
load	1	1.000s	3.4%	1.000s	1.000s
unparsed_lines	1
EXPECTED
)")"
expected_refill="$(printf '%b' "$(cat <<'EXPECTED'
passes	2
pass_total_p50	8.000s
pass_total_p90	12.000s
step	passes	total	share	p50	p90
scan	2	14.000s	70.0%	6.000s	8.000s
check	1	4.000s	20.0%	4.000s	4.000s
write	1	2.000s	10.0%	2.000s	2.000s
unparsed_lines	0
EXPECTED
)")"

expect_report "$expected_all"
expect_report "$expected_since" --since 2026-11-28T00:00:00Z
expect_report "$expected_refill" --refill false
