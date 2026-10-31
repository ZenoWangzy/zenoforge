#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
echo "fix it" > "$t/bad"; ! "$p/hf-brief-lint.sh" "$t/bad" 2>/dev/null
{ for i in $(seq 1 12); do echo "context line $i"; done; echo "Change packages/fruit-industry-pack/src/v4/x.ts"; echo "Run: bash scripts/agent/hotfix/hf-accept.test.sh"; echo "Done when the case passes"; } > "$t/good"
"$p/hf-brief-lint.sh" "$t/good"
