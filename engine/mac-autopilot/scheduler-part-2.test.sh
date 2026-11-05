#!/usr/bin/env bash
# Run partition 2 of the scheduler cases with the shared fixtures.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCHED_TEST_PART=2 bash "$(dirname -- "${BASH_SOURCE[0]}")/scheduler.test.sh"
