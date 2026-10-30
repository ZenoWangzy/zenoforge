#!/usr/bin/env bash
# Line B G11: the model policy default is the pack's model-policy.default.json, or the engine's generic one when there is no pack.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
engine="$MODEL_POLICY_TEST_REPO/engine"
pack_policy="$engine/model-policy.default.json"
generic_policy="$engine/model-policy.default.json"

fail() { echo "FAIL $*" >&2; exit 1; }

# The generic file is the pack's policy minus the the product-specific values: the advisor is disabled and no CI flakes are seeded.
[[ "$(jq -S '.roles.advisor.disabled = true | del(.hand_loop_breaker.known_flakes)' "$pack_policy")" == "$(jq -S . "$generic_policy")" ]] \
  || fail 'generic policy drifted from the pack policy (only advisor.disabled and known_flakes may differ)'

# Default pack dir (the engine dir): the default is the pack's policy, exactly where it was before the pack seam.
resolved="$(bash -c 'source "$1/lib.sh" && printf %s "$MODEL_POLICY_DEFAULT"' _ "$engine")"
[[ "$resolved" == "$pack_policy" ]] || fail "default pack resolves $resolved, expected $pack_policy"

# No pack (ZF_PACK_DIR set empty): the default is the generic policy; it validates, and its advisor role is disabled.
output="$(ZF_PACK_DIR= AGENT_HOME="$test_env_root/no-pack-agent" bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  [[ "$MODEL_POLICY_DEFAULT" == "$1/model-policy.default.json" ]] || { echo "resolves $MODEL_POLICY_DEFAULT"; exit 1; }
  model_policy_validate_file "$MODEL_POLICY_DEFAULT"
  mkdir -p "$AGENT_HOME" && cp "$MODEL_POLICY_DEFAULT" "$MODEL_POLICY_FILE"
  advisor_role_disabled
  printf ok
' _ "$engine" 2>&1)" || fail "no-pack default: $output"
[[ "$output" == ok ]] || fail "no-pack default printed: $output"

echo 'PASS model-policy default: pack policy with the default pack dir, generic policy without a pack'
