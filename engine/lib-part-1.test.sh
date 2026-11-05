#!/usr/bin/env bash
# Run partition 1 of lib.test.sh with the shared library fixture.
set -euo pipefail
LIB_TEST_PART=1 bash "$(dirname -- "${BASH_SOURCE[0]}")/lib.test.sh"
