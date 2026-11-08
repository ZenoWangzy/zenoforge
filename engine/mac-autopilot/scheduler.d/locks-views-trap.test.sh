#!/usr/bin/env bash
# acquire_scheduler_lock keeps the EXIT trap set before it (the engine canary) and runs it once, even after a re-acquire.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/locks-views-trap"
mkdir -p "$fixture"
probe="$fixture/probe.sh"
cat > "$probe" <<'EOF'
set -euo pipefail
source "$SCHED_DIR/core.sh"
source "$SCHED_DIR/locks-views.sh"
trap 'printf x >> "$PROBE_COUNT"' EXIT
acquire_scheduler_lock
release_scheduler_lock
acquire_scheduler_lock
EOF
SCHED_DIR="$script_dir" SCHED_LOCK="$fixture/sched.lock" PROBE_COUNT="$fixture/prior.count" bash "$probe"

[[ "$(cat "$fixture/prior.count" 2>/dev/null)" == x ]] || { echo 'locks-views-trap.test.sh: prior EXIT trap did not run after acquire_scheduler_lock' >&2; exit 1; }
[[ ! -e "$fixture/sched.lock" ]] || { echo 'locks-views-trap.test.sh: lock dir survived exit' >&2; exit 1; }
[[ "$(wc -c < "$fixture/prior.count")" == 1 ]] || { echo 'locks-views-trap.test.sh: prior EXIT trap ran more than once after a re-acquire' >&2; exit 1; }
echo 'locks-views-trap.test.sh: all assertions passed'
