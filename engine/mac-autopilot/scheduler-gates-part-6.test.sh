#!/usr/bin/env bash
# Run scheduler gate partition 6 with the shared fixture setup.
set -euo pipefail
SCHEDULER_GATES_PART=6 bash "$(dirname -- "${BASH_SOURCE[0]}")/scheduler-gates.test.sh"
