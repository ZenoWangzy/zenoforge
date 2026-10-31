#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../config.sh"
night_config="$(zf_config_file night.json || true)"
if [[ -z "$night_config" ]]; then
  echo 'skip: authorization monitor has no night.json configuration'
  exit 0
fi
if ! jq -e 'type == "object"' "$night_config" >/dev/null 2>&1; then
  echo 'FAIL: night.json must contain a JSON object' >&2
  exit 2
fi
if ! jq -e '
  (.authorization.ssh_host | type == "string" and length > 0)
  and (.authorization.service_container | type == "string" and length > 0)
  and (.authorization.pack_key | type == "string" and length > 0)
  and (.authorization.target_tenant_id | type == "string" and length > 0)
  and (.authorization.api.host | type == "string" and length > 0)
  and (.authorization.api.port | type == "number")
  and (.authorization.api.path | type == "string" and length > 0)
  and (.authorization.api.service_token_header | type == "string" and length > 0)
  and (.authorization.api.employee_header | type == "string" and length > 0)
  and (.authorization.service_token_env_name | type == "string" and length > 0)
  and (.authorization.expected_denial_status | type == "number")
  and (.authorization.required_role_level | type == "number")
  and (.authorization.manifest_id_field | type == "string" and length > 0)
  and (.authorization.statuses.install_scope | type == "string" and length > 0)
  and (.authorization.statuses.installation | type == "string" and length > 0)
  and (.authorization.statuses.pack | type == "string" and length > 0)
  and (.authorization.statuses.version | type == "string" and length > 0)
  and (.authorization.statuses.membership | type == "string" and length > 0)
  and (.authorization.tables | type == "object" and all(.[]; type == "string" and length > 0))
  and (.authorization.tenant_statuses | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  and (.credentials.wrapper_env_name | type == "string" and length > 0)
  and (.credentials.environment_home_env_name | type == "string" and length > 0)
  and (.credentials.environment_file_name | type == "string" and length > 0)
  and (.production.database_user_env | type == "string" and length > 0)
  and (.production.database_name_env | type == "string" and length > 0)
' "$night_config" >/dev/null 2>&1; then
  echo 'skip: authorization monitor needs target, service and schema settings in night.json'
  exit 0
fi

ssh_host="$(jq -r '.authorization.ssh_host' "$night_config")"
service_container="$(jq -r '.authorization.service_container' "$night_config")"
pack_key="$(jq -r '.authorization.pack_key' "$night_config")"
target_tenant_id="$(jq -r '.authorization.target_tenant_id' "$night_config")"
api_host="$(jq -r '.authorization.api.host' "$night_config")"
api_port="$(jq -r '.authorization.api.port' "$night_config")"
api_path="$(jq -r '.authorization.api.path' "$night_config")"
service_token_header="$(jq -r '.authorization.api.service_token_header' "$night_config")"
employee_header="$(jq -r '.authorization.api.employee_header' "$night_config")"
service_token_env_name="$(jq -r '.authorization.service_token_env_name' "$night_config")"
expected_denial_status="$(jq -r '.authorization.expected_denial_status' "$night_config")"
required_role_level="$(jq -r '.authorization.required_role_level' "$night_config")"
manifest_id_field="$(jq -r '.authorization.manifest_id_field' "$night_config")"
install_scope="$(jq -r '.authorization.statuses.install_scope' "$night_config")"
installation_status="$(jq -r '.authorization.statuses.installation' "$night_config")"
pack_status="$(jq -r '.authorization.statuses.pack' "$night_config")"
version_status="$(jq -r '.authorization.statuses.version' "$night_config")"
membership_status="$(jq -r '.authorization.statuses.membership' "$night_config")"
if [[ ! "$ssh_host" =~ ^[A-Za-z0-9_.-]+$ || ! "$service_container" =~ ^[A-Za-z0-9_.-]+$ \
  || ! "$pack_key" =~ ^[A-Za-z0-9_.-]+$ || ! "$target_tenant_id" =~ ^[A-Za-z0-9_-]+$ \
  || ! "$api_host" =~ ^(localhost|127\.0\.0\.1)$ || ! "$api_port" =~ ^[1-9][0-9]{0,4}$ \
  || ! "$api_path" =~ ^/[A-Za-z0-9_./-]+$ || ! "$service_token_header" =~ ^[A-Za-z0-9-]+$ \
  || ! "$employee_header" =~ ^[A-Za-z0-9-]+$ || ! "$service_token_env_name" =~ ^[A-Z_][A-Z0-9_]*$ \
  || ! "$expected_denial_status" =~ ^[1-5][0-9]{2}$ || ! "$required_role_level" =~ ^[0-9]+$ \
  || ! "$manifest_id_field" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ || ! "$install_scope" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ \
  || ! "$installation_status" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ || ! "$pack_status" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ \
  || ! "$version_status" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ || ! "$membership_status" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
  echo 'FAIL: invalid authorization monitor configuration' >&2
  exit 2
fi

declare -A table=()
while IFS=$'\t' read -r key value; do
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$value" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]] || {
    echo 'FAIL: invalid authorization table configuration' >&2
    exit 2
  }
  table["$key"]="$value"
done < <(jq -r '.authorization.tables | to_entries[] | [.key, .value] | @tsv' "$night_config")
for key in installations packs versions tenants employees memberships employee_roles roles bindings; do
  [[ -n "${table[$key]:-}" ]] || { echo 'FAIL: authorization table configuration is incomplete' >&2; exit 2; }
done

tenant_statuses=()
while IFS= read -r status; do
  [[ "$status" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo 'FAIL: invalid authorization tenant status' >&2; exit 2; }
  tenant_statuses+=("'$status'")
done < <(jq -r '.authorization.tenant_statuses[]' "$night_config")
tenant_status_sql="$(IFS=,; printf '%s' "${tenant_statuses[*]}")"

wrapper_env_name="$(jq -r '.credentials.wrapper_env_name' "$night_config")"
environment_home_env_name="$(jq -r '.credentials.environment_home_env_name' "$night_config")"
environment_file_name="$(jq -r '.credentials.environment_file_name' "$night_config")"
database_user_env="$(jq -r '.production.database_user_env' "$night_config")"
database_name_env="$(jq -r '.production.database_name_env' "$night_config")"
[[ "$wrapper_env_name" =~ ^[A-Z_][A-Z0-9_]*$ && "$environment_home_env_name" =~ ^[A-Z_][A-Z0-9_]*$ \
  && "$environment_file_name" =~ ^[A-Za-z0-9_.-]+$ && "$database_user_env" =~ ^[A-Z_][A-Z0-9_]*$ \
  && "$database_name_env" =~ ^[A-Z_][A-Z0-9_]*$ ]] || {
  echo 'FAIL: invalid authorization credential environment configuration' >&2
  exit 2
}
with_credentials="$(printenv "$wrapper_env_name" || true)"
environment_home="$(printenv "$environment_home_env_name" || true)"
environment_file="${environment_home%/}/$environment_file_name"
database_user="$(printenv "$database_user_env" || true)"
database_name="$(printenv "$database_name_env" || true)"
missing_env=()
[[ -x "$with_credentials" ]] || missing_env+=("$wrapper_env_name")
[[ -n "$environment_home" && -r "$environment_file" ]] || missing_env+=("$environment_home_env_name")
[[ -n "$database_user" ]] || missing_env+=("$database_user_env")
[[ -n "$database_name" ]] || missing_env+=("$database_name_env")
if ((${#missing_env[@]})); then
  printf 'skip: authorization monitor host environment is missing %s\n' "${missing_env[*]}"
  exit 0
fi

sql="$(cat <<SQL
BEGIN READ ONLY;
WITH installed_packs AS (
  SELECT DISTINCT install.tenant_id
    FROM ${table[installations]} install
    JOIN ${table[packs]} pack ON pack.id = install.scenario_pack_id
    JOIN ${table[versions]} version
      ON version.id = install.installed_version_id
     AND version.scenario_pack_id = install.scenario_pack_id
   WHERE install.install_scope = '$install_scope'
     AND install.status = '$installation_status'
     AND pack.status = '$pack_status'
     AND pack.pack_key = '$pack_key'
     AND version.status = '$version_status'
     AND version.manifest->>'$manifest_id_field' = pack.pack_key
), probe_identities AS (
  SELECT
    (SELECT employee.employee_id
       FROM installed_packs installed
       JOIN ${table[employees]} employee ON employee.tenant_id = installed.tenant_id
       JOIN ${table[memberships]} membership
         ON membership.tenant_id = employee.tenant_id
        AND membership.employee_id = employee.employee_id
        AND membership.membership_status = '$membership_status'
        AND membership.removed_at IS NULL
      WHERE installed.tenant_id = '$target_tenant_id'
        AND (SELECT max(role.level)
               FROM ${table[employee_roles]} employee_role
               JOIN ${table[roles]} role
                 ON role.id = employee_role.role_id
                AND role.tenant_id = employee_role.tenant_id
              WHERE employee_role.employee_id = employee.employee_id
                AND employee_role.tenant_id = employee.tenant_id) = $required_role_level
        AND EXISTS (
          SELECT 1 FROM ${table[bindings]} binding
           WHERE binding.tenant_id = employee.tenant_id
             AND binding.employee_id = employee.employee_id
        )
      ORDER BY employee.employee_id
      LIMIT 1) AS privileged_employee_id,
    (SELECT employee.employee_id
       FROM ${table[employees]} employee
       JOIN ${table[tenants]} tenant ON tenant.id = employee.tenant_id
       JOIN ${table[memberships]} membership
         ON membership.tenant_id = employee.tenant_id
        AND membership.employee_id = employee.employee_id
        AND membership.membership_status = '$membership_status'
        AND membership.removed_at IS NULL
      WHERE tenant.status::text IN ($tenant_status_sql)
        AND tenant.id <> '$target_tenant_id'
        AND NOT EXISTS (
          SELECT 1 FROM installed_packs installed WHERE installed.tenant_id = employee.tenant_id
        )
      ORDER BY employee.tenant_id, employee.employee_id
      LIMIT 1) AS cross_tenant_employee_id
)
SELECT jsonb_build_object(
  'installedTenantIds', COALESCE((SELECT jsonb_agg(tenant_id ORDER BY tenant_id) FROM installed_packs), '[]'::jsonb),
  'privilegedEmployeeId', privileged_employee_id,
  'crossTenantEmployeeId', cross_tenant_employee_id
)
FROM probe_identities;
COMMIT;
SQL
)"

probe_context="$(printf '%s\n' "$sql" | bash "$with_credentials" --env "$environment_file" -- \
  timeout 15s ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_host" \
  docker exec -i "$(jq -r '.production.container_names.database' "$night_config")" \
  psql -q -v ON_ERROR_STOP=1 -U "$database_user" -d "$database_name" -A -t 2>/dev/null)" || {
  echo 'FAIL: authorization read-only probe failed' >&2
  exit 1
}
if ! jq -e '
  .installedTenantIds | type == "array" and all(.[]; type == "string")
' <<< "$probe_context" >/dev/null 2>&1 \
  || ! jq -e '.privilegedEmployeeId | type == "string" and length > 0' <<< "$probe_context" >/dev/null 2>&1 \
  || ! jq -e '.crossTenantEmployeeId | type == "string" and length > 0' <<< "$probe_context" >/dev/null 2>&1; then
  echo 'FAIL: authorization probe identities unavailable' >&2
  exit 2
fi

probe_context="$(jq -cn --argjson read "$probe_context" \
  --arg tenant "$target_tenant_id" --arg host "$api_host" --argjson port "$api_port" \
  --arg path "$api_path" --arg service_header "$service_token_header" \
  --arg employee_header "$employee_header" --arg env_name "$service_token_env_name" \
  --argjson expected "$expected_denial_status" \
  '$read + {targetTenant:$tenant, api:{host:$host,port:$port,path:$path,serviceTokenHeader:$service_header,employeeHeader:$employee_header,serviceTokenEnvName:$env_name,expectedStatus:$expected}}')"
probe_program="$(printf 'const context = JSON.parse(%s);\n' "$(jq -Rs . <<< "$probe_context")"
cat <<'JS'
const secret = process.env[context.api.serviceTokenEnvName];
if (!secret) throw new Error("service credential unavailable");
const url = `http://${context.api.host}:${context.api.port}${context.api.path}`;
const check = async employeeId => {
  const response = await fetch(url, {
    method: "POST",
    headers: {"content-type": "application/json", [context.api.serviceTokenHeader]: secret,
      [context.api.employeeHeader]: employeeId},
    signal: AbortSignal.timeout(5000),
  });
  await response.body?.cancel().catch(() => {});
  return response.status;
};
const [crossTenantStatus, privilegedStatus] = await Promise.all([
  check(context.crossTenantEmployeeId),
  check(context.privilegedEmployeeId),
]);
const tenants = context.installedTenantIds;
const targetInstalled = tenants.includes(context.targetTenant);
const unexpectedTenantCount = tenants.filter(id => id !== context.targetTenant).length;
const ok = tenants.length === 1 && targetInstalled && unexpectedTenantCount === 0
  && crossTenantStatus === context.api.expectedStatus && privilegedStatus === context.api.expectedStatus;
console.log((ok ? "OK" : "FAIL") + " authorization tenants=" + tenants.length
  + " target=" + (targetInstalled ? "installed" : "missing")
  + " unexpected=" + unexpectedTenantCount
  + " cross-tenant=" + crossTenantStatus + " privileged=" + privilegedStatus);
process.exitCode = ok ? 0 : 1;
JS
)"

if ! printf '%s\n' "$probe_program" | bash "$with_credentials" --env "$environment_file" -- \
  timeout 20s ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_host" \
  docker exec -i "$(jq -r '.authorization.service_container' "$night_config")" node - 2>/dev/null; then
  echo 'FAIL: authorization service probe failed' >&2
  exit 1
fi
