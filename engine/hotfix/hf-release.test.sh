#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd)
rc=0; "$p/hf-release.sh" 1 || rc=$?; [[ $rc == 2 ]]
