#!/usr/bin/env bash
# Shared mac-autopilot test environment (CI contract): locates the repository root for scheduler and bell suites.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
MAC_AUTOPILOT_ENV_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
unset MAC_AUTOPILOT_ROOT MAC_AUTOPILOT_SUPERVISOR_DIR MAC_AUTOPILOT_RUNTIME_DIR
unset MAC_AUTOPILOT_DASHBOARD_OUTPUT MAC_AUTOPILOT_COST_CACHE
export MAC_AUTOPILOT_ENV_ROOT
# No scheduler suite may reach the real rule-ticket upsert: a repeated review class goes to a no-op stub unless a test sets its own.
export REVIEW_CLASS_UPSERT="$test_env_root/no-class-upsert.sh" REVIEW_CLASS_STATE="$test_env_root/review-class-state.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$REVIEW_CLASS_UPSERT"
