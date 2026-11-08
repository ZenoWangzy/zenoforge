#!/usr/bin/env bash
# The full tick has one dispatch pass. The dirty-gated second pass duplicated refill and ran ticks into their limit (#604).
# This file stays: suite-set-check refuses a pin that drops a baseline suite.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "dispatch-dirty-gate.test.sh: $*" >&2; exit 1; }
! grep -qE 'dispatch_pending_if_dirty|dispatch_inputs_fingerprint|TICK_DISPATCH_FP' "$here/scheduler.sh" "$here"/scheduler.d/*.sh \
  || fail 'the dirty-gated second pass came back'
[[ "$(grep -c 'phase_yield_lock dispatch_pending' "$here/scheduler.sh")" == 1 ]] || fail 'the full tick does not have exactly one dispatch pass'
echo 'dispatch-dirty-gate.test.sh: pass'
