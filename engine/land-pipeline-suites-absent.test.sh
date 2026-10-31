#!/usr/bin/env bash
# A target repo without .github/workflows/pipeline-suites.yml gets no post-land dispatch and no failure.
set -euo pipefail
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
eval "$(sed -n '/^dispatch_pipeline_suites_after_landing() {/,/^}/p' "$p/land-direct-main.sh")"
pipeline_suites_main_focused_run_covers_sha() { return 1; }
gh() { echo "gh must not run" >&2; return 9; }
git init -q "$t/r"; cd "$t/r"; git -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; sha=$(git rev-parse HEAD)
dispatch_pipeline_suites_after_landing "$sha" "$sha"
echo ok
