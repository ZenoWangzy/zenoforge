#!/usr/bin/env bash
# Run scheduler gate partition 2 with the shared fixture setup.
set -euo pipefail
SCHEDULER_GATES_PART=2 bash "$(dirname -- "${BASH_SOURCE[0]}")/scheduler-gates.test.sh"
