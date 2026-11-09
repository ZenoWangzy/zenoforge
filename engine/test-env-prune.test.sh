#!/usr/bin/env bash
# Roots of runs killed before their exit trap are pruned; fresh roots, other names and an unsafe parent survive.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture" "$test_env_root"' EXIT
home="$fixture/home"
parent="$home/.cache/zenoforge-agent-test"
mkdir -p "$parent/zenoforge-agent-test-OLD001" "$parent/zenoforge-agent-test-NEW001" "$parent/keep-old" "$home/zenoforge-agent-test-HOMEOLD"
touch -d '2 days ago' "$parent/zenoforge-agent-test-OLD001" "$parent/keep-old" "$home/zenoforge-agent-test-HOMEOLD"

# A child run sources test-env.sh under the fixture home: its prune runs, then it removes its own root on exit.
HOME="$home" bash -c 'source "$1"' _ "$engine/test-env.sh"
[[ ! -e "$parent/zenoforge-agent-test-OLD001" ]] || { echo 'test-env-prune.test.sh: old root survived the prune' >&2; exit 1; }
[[ -d "$parent/zenoforge-agent-test-NEW001" ]] || { echo 'test-env-prune.test.sh: fresh root was pruned' >&2; exit 1; }
[[ -d "$parent/keep-old" ]] || { echo 'test-env-prune.test.sh: non-matching dir was pruned' >&2; exit 1; }

# An empty parent and the host home itself are refused, so a matching old dir under home survives.
HOME="$home" bash -c 'source "$1"; test_env_prune_old_roots ""; test_env_prune_old_roots "$test_host_home"' _ "$engine/test-env.sh"
[[ -d "$home/zenoforge-agent-test-HOMEOLD" ]] || { echo 'test-env-prune.test.sh: prune ran on the host home' >&2; exit 1; }
echo 'PASS test-env prunes roots older than a day and refuses an empty parent or the host home'
