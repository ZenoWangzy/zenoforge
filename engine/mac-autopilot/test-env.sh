#!/usr/bin/env bash
# Shared mac-autopilot test environment (CI contract): locates the repository root for scheduler and bell suites.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
MAC_AUTOPILOT_ENV_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
unset MAC_AUTOPILOT_ROOT MAC_AUTOPILOT_SUPERVISOR_DIR MAC_AUTOPILOT_RUNTIME_DIR
unset MAC_AUTOPILOT_DASHBOARD_OUTPUT MAC_AUTOPILOT_COST_CACHE
export MAC_AUTOPILOT_ENV_ROOT
