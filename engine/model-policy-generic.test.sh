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

# A template the running engine refuses (a tick outlives the checkout fast-forward that publishes a newer one) must not stop
# lib.sh: the engine's own default stands in, one greppable line says so, the live policy is never written, and the strict
# publishing path still refuses.
t="$test_env_root/template-fallback"
mkdir -p "$t/cfg" "$t/agent"
engine_default="$engine/model-policy.default.json"
refused="$t/cfg/model-policy.default.json"
jq '.roles.work.provider = "bogus"' "$engine_default" > "$refused"
refused_line="model-policy-template-refused file=$refused using=engine-default"
load() { # load <agent home> <engine dir>: print the resolved default, then the work identity
  AGENT_HOME="$1" ZF_CONFIG_ROOT="$t/cfg" bash -c 'source "$1/lib.sh" && printf "%s\n%s\n" "$MODEL_POLICY_DEFAULT" "$(model_policy identity work)"' _ "$2"
}
live="$t/agent/model-policy.json"
jq -S . "$engine_default" > "$live"
live_sum="$(cksum < "$live")"
out="$(load "$t/agent" "$engine" 2>"$t/err")" || fail "refused template: lib.sh did not load: $(cat "$t/err")"
[[ "$(sed -n 1p <<< "$out")" == "$engine_default" ]] || fail "refused template: default is $(sed -n 1p <<< "$out")"
[[ "$(sed -n 2p <<< "$out")" == "$MODEL_POLICY_TEST_WORK_IDENTITY" ]] || fail "refused template: work identity $(sed -n 2p <<< "$out")"
[[ "$(grep -c '^model-policy-template-refused ' "$t/err")" == 1 ]] && grep -qxF "$refused_line" "$t/err" || fail "refused template: stderr line: $(cat "$t/err")"
[[ "$(cksum < "$live")" == "$live_sum" ]] || fail 'refused template: live policy bytes changed'
# One inbox alert per template content, not one per load.
load "$t/agent" "$engine" >/dev/null 2>&1 || fail 'refused template: second load failed'
[[ "$(grep -c ' model-policy-template-refused file=' "$t/agent/supervisor-inbox")" == 1 ]] || fail 'refused template: alert was not once per content'

# A missing live policy is not seeded from the engine default while a template is refused.
rm -rf "$t/empty"; mkdir -p "$t/empty"
if load "$t/empty" "$engine" >/dev/null 2>&1; then fail 'refused template: load seeded or accepted a missing live policy'; fi
[[ ! -e "$t/empty/model-policy.json" ]] || fail 'refused template: a missing live policy was seeded from the engine default'

# A valid template is used unchanged, with no line.
valid="$t/cfg-valid"; mkdir -p "$valid"
jq '.switches["roadmap-order"] = (.switches["roadmap-order"] | not)' "$engine_default" > "$valid/model-policy.default.json"
out="$(AGENT_HOME="$t/agent" ZF_CONFIG_ROOT="$valid" bash -c 'source "$1/lib.sh" && printf "%s" "$MODEL_POLICY_DEFAULT"' _ "$engine" 2>"$t/err")" || fail "valid template: $(cat "$t/err")"
[[ "$out" == "$valid/model-policy.default.json" ]] && ! grep -q 'model-policy-template-refused' "$t/err" || fail 'valid template was replaced or announced'

# Engine default also broken: the hard failure stays.
copy_agent_library "$t/broken-engine"
printf '{}\n' > "$t/broken-engine/model-policy.default.json"
if load "$t/agent" "$t/broken-engine" >"$t/out" 2>"$t/err"; then fail 'broken engine default: lib.sh loaded'; fi
grep -q 'cannot resolve the work role' "$t/err" && ! grep -q 'model-policy-template-refused' "$t/err" || fail "broken engine default: $(cat "$t/err")"

# The strict publishing path refuses the same template and leaves the live file alone.
repo="$t/repo"; mkdir -p "$repo/engine" "$repo/.zenoforge"; git init -q -b main "$repo"
git -C "$repo" config user.name t; git -C "$repo" config user.email t@example.invalid
cp "$refused" "$repo/.zenoforge/model-policy.default.json"; cp "$refused" "$repo/engine/model-policy.default.json"
git -C "$repo" add -A; git -C "$repo" commit -qm refused
git init -q --bare -b main "$t/origin.git"; git -C "$repo" remote add origin "$t/origin.git"; git -C "$repo" push -q origin main
if AGENT_HOME="$t/agent" ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_PACK_DIR="$repo/engine" ZF_PACK_REL=engine ZF_CONFIG_ROOT="$repo/.zenoforge" \
  bash "$engine/apply-model-policy-default.sh" >"$t/out" 2>"$t/err"; then fail 'apply published a refused template'; fi
[[ "$(cksum < "$live")" == "$live_sum" ]] || fail 'apply with a refused template changed the live policy'
! grep -q 'model-policy-template-refused' "$t/err" || fail 'apply used the fallback'

# The scheduler sources only lib.d/model-policy.sh (no supervisor-inbox.sh): the same fallback and alert work there.
rm -rf "$t/sched-agent"; mkdir -p "$t/sched-agent"
sched_out="$(AGENT_HOME="$t/sched-agent" MODEL_POLICY_DEFAULT="$refused" bash -c 'source "$1/lib.d/model-policy.sh"; source "$1/lib.d/model-policy-fallback.sh"; model_policy_default_fallback "$1/model-policy.default.json"; printf "%s" "$MODEL_POLICY_DEFAULT"' _ "$engine" 2>"$t/err")" || fail "scheduler fallback: $(cat "$t/err")"
[[ "$sched_out" == "$engine_default" ]] && grep -qxF "$refused_line" "$t/err" && grep -q ' model-policy-template-refused file=' "$t/sched-agent/supervisor-inbox" || fail "scheduler fallback: $sched_out $(cat "$t/err")"

echo 'PASS model-policy default: pack policy with the default pack dir, generic policy without a pack'
