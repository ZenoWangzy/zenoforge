#!/usr/bin/env bash
# Run scheduler gate partition 5 with the shared fixture setup.
set -euo pipefail
SCHEDULER_GATES_PART=5 bash "$(dirname -- "${BASH_SOURCE[0]}")/scheduler-gates.test.sh"
