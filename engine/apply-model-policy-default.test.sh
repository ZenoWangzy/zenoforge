#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
test_root="$(mktemp -d "$TMPDIR/apply-model-policy-test.XXXXXX")"
trap 'rm -rf -- "$test_root" "$test_env_root"' EXIT
repo="$test_root/repo"
remote="$test_root/origin.git"
agent_home="$test_root/agent"
mkdir -p "$repo/engine" "$agent_home"
git init -q --bare --initial-branch=main "$remote"
git -C "$repo" init -q --initial-branch=main
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
copy_agent_library "$repo/engine"
git -C "$repo" add engine
git -C "$repo" commit -qm 'fixture policy default'
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q --set-upstream origin main
git -C "$repo" fetch -q origin main

live_file="$agent_home/model-policy.json"
work_model="$(jq -r '.roles.work.model' "$repo/engine/model-policy.default.json")"
local_work_model="local-work"
work_effort="$(jq -r '.roles.work.effort' "$repo/engine/model-policy.default.json")"
work_tier="$(jq -r '.roles.work.service_tier // empty' "$repo/engine/model-policy.default.json")"
production_model="$(jq -r '.roles.production.model' "$repo/engine/model-policy.default.json")"
production_effort="$(jq -r '.roles.production.effort' "$repo/engine/model-policy.default.json")"
printf -v work_identity 'codex:%s:%s' "$work_model" "$work_effort"
printf -v production_identity 'codex:%s:%s' "$production_model" "$production_effort"
# Model a legacy persistent policy: no schema marker, review role, fallback
# fields, current escalation, or switch fields, plus valid local choices.
jq --arg model "$local_work_model" 'del(.schema_version, .roles.review, .roles.work.service_tier,
    .roles.work.fallback_model, .roles.production.fallback_model, .roles.review.fallback_model,
    .escalation, .switches)
  | .roles.work.model = $model
  | .switches = {"roadmap-order": false}' \
  "$repo/engine/model-policy.default.json" > "$live_file"
chmod 640 "$live_file"
cp -- "$live_file" "$test_root/old-policy.json"
output="$(AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh")"
grep -Fxq "$(printf 'work\t%s\t%s' "$work_identity" "$work_tier")" <<< "$output"
grep -Fxq "$(printf 'production\t%s\t' "$production_identity")" <<< "$output"
resolved_work="$(
  cd "$repo"
  AGENT_HOME="$agent_home" bash -c '
    source "$1/engine/lib.sh"
    model_policy identity work
  ' _ "$repo"
)"
[[ "$resolved_work" == "$work_identity" ]]
[[ "$(jq -r '.roles.work.model' "$test_root/old-policy.json")" == "$local_work_model" ]]
[[ "$(jq -r '.roles.work.model' "$live_file")" == "$work_model" ]]
jq -e --arg tier "$work_tier" '.roles.work.service_tier == $tier and (.roles.production | has("service_tier") | not)' "$live_file" >/dev/null
for role in work production review; do
  jq -e --arg role "$role" '.roles[$role] | (has("fallback_model") | not) and (has("fallback_identity") | not)' "$live_file" >/dev/null
done
jq -e --slurpfile default "$repo/engine/model-policy.default.json" \
  '. == $default[0]' "$live_file" >/dev/null
[[ "$(stat -c '%a' "$live_file")" == 600 ]]
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == 1 ]]
cmp -s "$test_root/old-policy.json" "${backups[0]}"
[[ "$(stat -c '%a' "${backups[0]}")" == 640 ]]
[[ "$(jq -r '.schema_version' "$live_file")" == 3 ]]

# Schema v2's redundant same-model fallback must migrate cleanly to the no-fallback v3 contract.
jq '.schema_version = 2
  | .roles.work.fallback_model = .roles.work.model
  | .roles.review.fallback_model = .roles.review.model
  | .roles.production.fallback_model = .roles.production.model' \
  "$repo/engine/model-policy.default.json" > "$live_file"
chmod 640 "$live_file"
cp -- "$live_file" "$test_root/old-v2-policy.json"
resolved_after_v2_migration="$(
  cd "$repo"
  AGENT_HOME="$agent_home" bash -c 'source "$1/engine/lib.sh"; model_policy identity work' _ "$repo"
)"
[[ "$resolved_after_v2_migration" == "$work_identity" ]]
jq -e '.schema_version == 3 and ([.roles.work, .roles.review, .roles.production] | all((has("fallback_model") | not) and (has("fallback_identity") | not)))' "$live_file" >/dev/null
v2_backup=("$agent_home"/model-policy.json.bak.schema-v2.*)
[[ "${#v2_backup[@]}" == 1 ]]
cmp -s "$test_root/old-v2-policy.json" "${v2_backup[0]}"
backups=("$agent_home"/model-policy.json.bak.*)

# A schema-v2 operator override can have a different primary model and the
# approved Luna fallback. Migration replaces the full policy, so this valid
# legacy fallback must be backed up and removed along with the other v2 fields.
candidate_model="gpt-6-candidate"
jq --arg candidate "$candidate_model" '.schema_version = 2
  | .roles.work.model = $candidate
  | .roles.work.fallback_model = "gpt-6-luna"
  | .roles.review.fallback_model = .roles.review.model
  | .roles.production.fallback_model = .roles.production.model' \
  "$repo/engine/model-policy.default.json" > "$live_file"
chmod 640 "$live_file"
cp -- "$live_file" "$test_root/old-v2-candidate-policy.json"
candidate_backup_count="${#v2_backup[@]}"
resolved_after_candidate_migration="$(
  cd "$repo"
  AGENT_HOME="$agent_home" bash -c 'source "$1/engine/lib.sh"; model_policy identity work' _ "$repo"
)"
[[ "$resolved_after_candidate_migration" == "$work_identity" ]]
jq -e --slurpfile default "$repo/engine/model-policy.default.json" \
  '. == $default[0]' "$live_file" >/dev/null
v2_backup=("$agent_home"/model-policy.json.bak.schema-v2.*)
[[ "${#v2_backup[@]}" == "$((candidate_backup_count + 1))" ]]
candidate_backup_found=0
for backup in "${v2_backup[@]}"; do
  if cmp -s "$test_root/old-v2-candidate-policy.json" "$backup"; then
    candidate_backup_found=1
    break
  fi
done
[[ "$candidate_backup_found" == 1 ]]
backups=("$agent_home"/model-policy.json.bak.*)

# A valid v1 fallback may be a different active Codex model. Validate it with
# the v1 rules, preserve its original bytes, then install the strict v3 default.
legacy_fallback_model="gpt-6-legacy"
jq --arg model "$legacy_fallback_model" '
  .schema_version = 1
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model) else . end)
  | .roles.work.fallback_model = $model
  | .roles["legacy-fallback"] = {provider:"codex", model:$model, effort:"max", disabled:true}
' "$repo/engine/model-policy.default.json" > "$live_file"
chmod 640 "$live_file"
cp -- "$live_file" "$test_root/legacy-v1-custom-fallback.json"
backup_count="${#backups[@]}"
AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh" > "$test_root/legacy-v1.log"
jq -e --slurpfile default "$repo/engine/model-policy.default.json" '. == $default[0]' "$live_file" >/dev/null
[[ "$(stat -c '%a' "$live_file")" == 600 ]]
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$((backup_count + 1))" ]]
legacy_backup_found=0
for backup in "${backups[@]}"; do
  if cmp -s "$test_root/legacy-v1-custom-fallback.json" "$backup"; then
    legacy_backup_found=1
    [[ "$(stat -c '%a' "$backup")" == 640 ]]
  fi
done
[[ "$legacy_backup_found" == 1 ]]

# A v1 fallback model may point at a custom role whose model is now forbidden.
# Migration discards the active fallback and its otherwise-unreferenced target,
# while preserving the complete original policy in the backup.
legacy_forbidden_fallback_model="gpt-6.1-sol"
jq --arg model "$legacy_forbidden_fallback_model" '
  .schema_version = 1
  | .forbidden |= map(select(. != "sol"))
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model, .value.fallback_identity) else . end)
  | .roles.work.fallback_model = $model
  | .roles["legacy-fallback"] = {provider:"codex", model:$model, effort:"max", disabled:true}
' "$repo/engine/model-policy.default.json" > "$live_file"
chmod 640 "$live_file"
cp -- "$live_file" "$test_root/legacy-v1-forbidden-fallback-model.json"
forbidden_model_backup_count="${#backups[@]}"
resolved_after_forbidden_model_migration="$(
  cd "$repo"
  AGENT_HOME="$agent_home" bash -c 'source "$1/engine/lib.sh"; model_policy identity work' _ "$repo"
)"
[[ "$resolved_after_forbidden_model_migration" == "$work_identity" ]]
jq -e --slurpfile default "$repo/engine/model-policy.default.json" '. == $default[0]' "$live_file" >/dev/null
[[ "$(stat -c '%a' "$live_file")" == 600 ]]
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$((forbidden_model_backup_count + 1))" ]]
forbidden_model_backup_found=0
for backup in "${backups[@]}"; do
  if cmp -s "$test_root/legacy-v1-forbidden-fallback-model.json" "$backup"; then
    forbidden_model_backup_found=1
    [[ "$(stat -c '%a' "$backup")" == 640 ]]
  fi
done
[[ "$forbidden_model_backup_found" == 1 ]]

# An escalation reference independently retains the custom fallback-model
# target; its current-forbidden model must still block migration without a backup.
jq --arg model "$legacy_forbidden_fallback_model" '
  .schema_version = 1
  | .forbidden |= map(select(. != "sol"))
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model, .value.fallback_identity) else . end)
  | .roles.work.fallback_model = $model
  | .roles["legacy-fallback"] = {provider:"codex", model:$model, effort:"max"}
  | .escalation.steps += [{name:"legacy-fallback", role:"legacy-fallback"}]
' "$repo/engine/model-policy.default.json" > "$live_file"
cp -- "$live_file" "$test_root/legacy-v1-retained-forbidden-fallback-model.json"
retained_model_backup_count="${#backups[@]}"
if AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh" > "$test_root/legacy-retained-model.log" 2>&1; then
  echo 'expected an independently referenced current-forbidden fallback-model role to block migration' >&2
  exit 1
fi
grep -Fq 'persistent policy cannot be migrated without changing its valid settings' "$test_root/legacy-retained-model.log"
cmp -s "$test_root/legacy-v1-retained-forbidden-fallback-model.json" "$live_file"
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$retained_model_backup_count" ]]

# A valid v1 fallback identity can target a different active Codex role that
# is absent from the current default. Migration installs the current default
# and keeps the complete legacy policy as a backup.
legacy_fallback_identity="codex:gpt-6-legacy:max"
jq --arg identity "$legacy_fallback_identity" '
  .schema_version = 1
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model, .value.fallback_identity) else . end)
  | .roles.work.model = "gpt-6-candidate"
  | .roles.work.fallback_identity = $identity
  | .roles["legacy-fallback"] = {provider:"codex", model:"gpt-6-legacy", effort:"max"}
' "$repo/engine/model-policy.default.json" > "$live_file"
chmod 640 "$live_file"
cp -- "$live_file" "$test_root/legacy-v1-custom-fallback-identity.json"
identity_backup_count="${#backups[@]}"
AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh" > "$test_root/legacy-v1-identity.log"
jq -e --slurpfile default "$repo/engine/model-policy.default.json" '. == $default[0]' "$live_file" >/dev/null
[[ "$(stat -c '%a' "$live_file")" == 600 ]]
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$((identity_backup_count + 1))" ]]
identity_backup_found=0
for backup in "${backups[@]}"; do
  if cmp -s "$test_root/legacy-v1-custom-fallback-identity.json" "$backup"; then
    identity_backup_found=1
    [[ "$(stat -c '%a' "$backup")" == 640 ]]
  fi
done
[[ "$identity_backup_found" == 1 ]]

# A v1 fallback identity may target a custom role whose model is now forbidden.
# The active fallback identity and its target role are both discarded by the
# upgrade, while the original bytes remain available in the backup.
legacy_forbidden_fallback_identity="codex:gpt-6.1-sol:max"
jq --arg identity "$legacy_forbidden_fallback_identity" '
  .schema_version = 1
  | .forbidden |= map(select(. != "sol"))
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model, .value.fallback_identity) else . end)
  | .roles.work.model = "gpt-6-candidate"
  | .roles.work.fallback_identity = $identity
  | .roles["legacy-fallback"] = {provider:"codex", model:"gpt-6.1-sol", effort:"max"}
' "$repo/engine/model-policy.default.json" > "$live_file"
chmod 640 "$live_file"
cp -- "$live_file" "$test_root/legacy-v1-forbidden-fallback-identity.json"
forbidden_identity_backup_count="${#backups[@]}"
resolved_after_forbidden_identity_migration="$(
  cd "$repo"
  AGENT_HOME="$agent_home" bash -c 'source "$1/engine/lib.sh"; model_policy identity work' _ "$repo"
)"
[[ "$resolved_after_forbidden_identity_migration" == "$work_identity" ]]
jq -e --slurpfile default "$repo/engine/model-policy.default.json" '. == $default[0]' "$live_file" >/dev/null
[[ "$(stat -c '%a' "$live_file")" == 600 ]]
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$((forbidden_identity_backup_count + 1))" ]]
forbidden_identity_backup_found=0
for backup in "${backups[@]}"; do
  if cmp -s "$test_root/legacy-v1-forbidden-fallback-identity.json" "$backup"; then
    forbidden_identity_backup_found=1
    [[ "$(stat -c '%a' "$backup")" == 640 ]]
  fi
done
[[ "$forbidden_identity_backup_found" == 1 ]]

# Keep a legacy fallback target in the candidate when the escalation policy
# also references it. That independently retained role must still fail the
# current forbidden-model check, without backing up or rewriting the file.
jq --arg identity "$legacy_forbidden_fallback_identity" '
  .schema_version = 1
  | .forbidden |= map(select(. != "sol"))
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model, .value.fallback_identity) else . end)
  | .roles.work.model = "gpt-6-candidate"
  | .roles.work.fallback_identity = $identity
  | .roles["legacy-fallback"] = {provider:"codex", model:"gpt-6.1-sol", effort:"max"}
  | .escalation.steps += [{name:"legacy-fallback", role:"legacy-fallback"}]
' "$repo/engine/model-policy.default.json" > "$live_file"
cp -- "$live_file" "$test_root/legacy-v1-retained-forbidden-fallback-identity.json"
retained_identity_backup_count="${#backups[@]}"
if AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh" > "$test_root/legacy-retained-identity.log" 2>&1; then
  echo 'expected an independently referenced current-forbidden fallback role to block migration' >&2
  exit 1
fi
grep -Fq 'persistent policy cannot be migrated without changing its valid settings' "$test_root/legacy-retained-identity.log"
cmp -s "$test_root/legacy-v1-retained-forbidden-fallback-identity.json" "$live_file"
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$retained_identity_backup_count" ]]

# A v1 fallback identity must still refuse a disabled Codex role before backup.
jq --arg model "$legacy_fallback_model" '
  .schema_version = 1
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model) else . end)
  | .roles.work.fallback_model = $model
  | .roles.work.fallback_identity = "codex:gpt-6-disabled:max"
  | .roles["disabled-codex"] = {provider:"codex", model:"gpt-6-disabled", effort:"max", disabled:true}
' "$repo/engine/model-policy.default.json" > "$live_file"
cp -- "$live_file" "$test_root/legacy-v1-disabled-fallback.json"
backup_count="${#backups[@]}"
if AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh" > "$test_root/legacy-disabled.log" 2>&1; then
  echo 'expected a v1 fallback identity targeting a disabled role to fail' >&2
  exit 1
fi
grep -Fq 'persistent policy cannot be migrated without changing its valid settings' "$test_root/legacy-disabled.log"
cmp -s "$test_root/legacy-v1-disabled-fallback.json" "$live_file"
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$backup_count" ]]

# A policy from a newer installation must never be silently downgraded.
cp -- "$live_file" "$test_root/current-policy.json"
jq '.schema_version = 99' "$live_file" > "$test_root/future-policy.json"
mv -- "$test_root/future-policy.json" "$live_file"
cp -- "$live_file" "$test_root/future-policy-before-apply.json"
backup_count="${#backups[@]}"
if AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh" > "$test_root/future.log" 2>&1; then
  echo 'expected a newer persistent policy to fail closed' >&2
  exit 1
fi
grep -Fq 'persistent schema version 99 is newer than supported version 3' "$test_root/future.log"
cmp -s "$test_root/future-policy-before-apply.json" "$live_file"
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$backup_count" ]]
cp -- "$test_root/current-policy.json" "$live_file"

before="$(sha256sum "$live_file" | cut -d' ' -f1)"
backup_count="${#backups[@]}"
jq --arg tier "$work_tier" '.roles.work.service_tier = ($tier + "-mismatch")' \
  "$repo/engine/model-policy.default.json" > "$test_root/mismatched-policy.json"
mv -- "$test_root/mismatched-policy.json" "$repo/engine/model-policy.default.json"
if AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh" > "$test_root/mismatch.log" 2>&1; then
  echo 'expected mismatched checkout policy to fail' >&2
  exit 1
fi
grep -Fq 'checkout default is not the landed origin/main default' "$test_root/mismatch.log"
[[ "$(sha256sum "$live_file" | cut -d' ' -f1)" == "$before" ]]
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$backup_count" ]]

# A malformed landed default must fail validation before replacing the live file.
cp -- "$test_root/old-policy.json" "$live_file"
git -C "$repo" checkout -q -- engine/model-policy.default.json
printf '{broken json\n' > "$repo/engine/model-policy.default.json"
git -C "$repo" add engine/model-policy.default.json
git -C "$repo" commit -qm 'invalid model policy default fixture'
git -C "$repo" push -q origin main
cp -- "$live_file" "$test_root/before-invalid-apply.json"
backup_count="${#backups[@]}"
if AGENT_HOME="$agent_home" bash "$repo/engine/apply-model-policy-default.sh" > "$test_root/invalid.log" 2>&1; then
  echo 'expected invalid landed policy to fail validation' >&2
  exit 1
fi
grep -Eq 'model_policy: versioned policy is invalid|model policy cannot resolve the work role' "$test_root/invalid.log"
cmp -s "$test_root/before-invalid-apply.json" "$live_file"
backups=("$agent_home"/model-policy.json.bak.*)
[[ "${#backups[@]}" == "$backup_count" ]]

echo 'apply-model-policy-default: sync, role resolution, backup, permissions, and pre-land guard passed'
