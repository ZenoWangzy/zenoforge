#!/usr/bin/env bash
# Run scheduler gate partition 4 with the shared fixture setup.
set -euo pipefail
SCHEDULER_GATES_PART=4 bash "$(dirname -- "${BASH_SOURCE[0]}")/scheduler-gates.test.sh"
