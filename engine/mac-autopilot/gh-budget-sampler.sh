#!/usr/bin/env bash
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"
source "$HERE/../lib.d/transport.sh"
gh_budget_sample || :
