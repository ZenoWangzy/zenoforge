#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t="$test_env_root/hotfix-brief-lint"; mkdir -p "$t"
echo "fix it" > "$t/bad"; ! "$p/hf-brief-lint.sh" "$t/bad" 2>/dev/null
{ for i in $(seq 1 12); do echo "context line $i"; done; echo "Change packages/fruit-industry-pack/src/v4/x.ts"; echo "Add regression-test coverage; PR CI runs it"; echo "Done when the case passes"; } > "$t/good"
"$p/hf-brief-lint.sh" "$t/good"
{ cat "$t/good"; echo "Run the test locally first"; } > "$t/local"
! "$p/hf-brief-lint.sh" "$t/local" 2>/dev/null
{ cat "$t/good"; echo "Run local test suites before push"; } > "$t/local-first"
! "$p/hf-brief-lint.sh" "$t/local-first" 2>/dev/null
{ cat "$t/good"; echo "Record local test receipts"; } > "$t/local-receipts"
! "$p/hf-brief-lint.sh" "$t/local-receipts" 2>/dev/null
{ cat "$t/good"; echo "Record the test receipt locally"; } > "$t/local-receipts-reordered"
! "$p/hf-brief-lint.sh" "$t/local-receipts-reordered" 2>/dev/null
{ cat "$t/good"; echo "A local test receipt is required before pushing"; } > "$t/local-receipt-required"
! "$p/hf-brief-lint.sh" "$t/local-receipt-required" 2>/dev/null
