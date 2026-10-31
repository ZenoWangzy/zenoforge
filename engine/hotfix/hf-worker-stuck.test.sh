#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export WORKER_SCRATCH_ROOT=$t HF_WORKER_BUDGET_MIN=45
git init -q "$t/wt" && git -C "$t/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base && git -C "$t/wt" update-ref refs/remotes/origin/main HEAD
mkdir -p "$t/luna/k1"; echo b > "$t/luna/k1/backend"; touch -d '-90 minutes' "$t/luna/k1/backend"
# a live "wrapper": a sleeping process whose argv is: bash worker <key> <cwd>
printf 'sleep 30\n' > "$t/worker"; bash "$t/worker" k1 "$t/wt" & echo $! > "$t/luna/k1/wrapper.pid"; trap 'kill $(cat "$t/luna/k1/wrapper.pid") 2>/dev/null; rm -rf "$t"' EXIT
out=$("$p/hf-worker-stuck.sh" || true); grep -q 'k1 running 9[0-9] min, 0 commits' <<< "$out"
git -C "$t/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work     # a commit = progress
[[ -z $("$p/hf-worker-stuck.sh" || true) ]]
