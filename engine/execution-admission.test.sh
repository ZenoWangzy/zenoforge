#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/execution-admission.test.py"
