#!/usr/bin/env bash
set -euo pipefail

list_mode=0
if [[ $# -gt 1 ]] || { [[ $# -eq 1 ]] && [[ "$1" != "--list" ]]; }; then
  echo 'usage: production-tenant-marker-readonly.sh [--list]' >&2
  exit 64
fi
if [[ $# -eq 1 ]]; then list_mode=1; fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../config.sh"
night_config="$(zf_config_file night.json || true)"
if [[ -z "$night_config" ]]; then
  echo 'skip: tenant marker monitor has no night.json configuration'
  exit 0
fi
if ! jq -e 'type == "object"' "$night_config" >/dev/null 2>&1; then
  echo 'FAIL: night.json must contain a JSON object' >&2
  exit 2
fi
required_config_valid=''
if jq -e '
  (.production.ssh_hosts.tenant_marker | type == "string" and length > 0)
  and (.production.container_names.database | type == "string" and length > 0)
  and (.production.tenant_ids.marker_probe | type == "string" and length > 0)
  and (.production.database_user_env | type == "string" and length > 0)
  and (.production.database_name_env | type == "string" and length > 0)
  and ([.production.log_sources.tenants_table, .production.log_sources.memberships_table,
        .production.log_sources.accounts_table, .production.log_sources.employees_table,
        .production.log_sources.approvals_table, .production.log_sources.files_table,
        .production.log_sources.events_table, .production.log_sources.roll_targets_table,
        .production.log_sources.instances_table, .production.log_sources.bindings_table]
       | all(.[]; type == "string" and length > 0))
  and (.anomaly_rules.tenant_markers.pattern | type == "string" and length > 0)
  and (.anomaly_rules.tenant_markers.capture_pattern | type == "string" and length > 0)
  and (.anomaly_rules.tenant_markers.invalid_email_pattern | type == "string" and length > 0)
  and (.customer.name | type == "string" and length > 0)
  and (.customer.service_ids.production | type == "string" and length > 0)
  and (.customer.service_ids.demo | type == "string" and length > 0)
  and (.customer.allowed_members | type == "array" and length > 0
    and all(.[]; (.id | type == "string" and length > 0)
      and (.service == "production" or .service == "demo")))
  and (.credentials.wrapper_env_name | type == "string" and length > 0)
  and (.credentials.environment_home_env_name | type == "string" and length > 0)
  and (.credentials.environment_file_name | type == "string" and length > 0)
' "$night_config" >/dev/null 2>&1; then
  required_config_valid=1
fi
if [[ -z "$required_config_valid" ]]; then
  echo 'skip: tenant marker monitor needs topology, tenant, customer and anomaly-rule values in night.json'
  exit 0
fi

ssh_host="$(jq -r '.production.ssh_hosts.tenant_marker' "$night_config")"
database_container="$(jq -r '.production.container_names.database' "$night_config")"
tenant_id="$(jq -r '.production.tenant_ids.marker_probe' "$night_config")"
database_user_env="$(jq -r '.production.database_user_env' "$night_config")"
database_name_env="$(jq -r '.production.database_name_env' "$night_config")"
customer_name="$(jq -r '.customer.name' "$night_config")"
production_service_id="$(jq -r '.customer.service_ids.production' "$night_config")"
demo_service_id="$(jq -r '.customer.service_ids.demo' "$night_config")"
marker_pattern="$(jq -r '.anomaly_rules.tenant_markers.pattern' "$night_config")"
capture_pattern="$(jq -r '.anomaly_rules.tenant_markers.capture_pattern' "$night_config")"
invalid_email_pattern="$(jq -r '.anomaly_rules.tenant_markers.invalid_email_pattern' "$night_config")"
if [[ ! "$ssh_host" =~ ^[A-Za-z0-9_.-]+$ || ! "$database_container" =~ ^[A-Za-z0-9_.-]+$ \
  || ! "$tenant_id" =~ ^[A-Za-z0-9_-]+$ || ! "$database_user_env" =~ ^[A-Z_][A-Z0-9_]*$ \
  || ! "$database_name_env" =~ ^[A-Z_][A-Z0-9_]*$ || ! "$production_service_id" =~ ^[A-Fa-f0-9-]{36}$ \
  || ! "$demo_service_id" =~ ^[A-Fa-f0-9-]{36}$ || "$marker_pattern$capture_pattern$invalid_email_pattern" == *"'"* ]]; then
  echo 'FAIL: invalid tenant marker configuration values' >&2
  exit 2
fi
tables=()
for field in tenants_table memberships_table accounts_table employees_table approvals_table files_table events_table roll_targets_table instances_table bindings_table; do
  table="$(jq -r ".production.log_sources.$field" "$night_config")"
  [[ "$table" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]] || { echo 'FAIL: invalid configured log-source table' >&2; exit 2; }
  tables+=("$table")
done
tenants_table="${tables[0]}"; memberships_table="${tables[1]}"; accounts_table="${tables[2]}"
employees_table="${tables[3]}"; approvals_table="${tables[4]}"; files_table="${tables[5]}"
events_table="${tables[6]}"; roll_targets_table="${tables[7]}"; instances_table="${tables[8]}"
bindings_table="${tables[9]}"

wrapper_env_name="$(jq -r '.credentials.wrapper_env_name' "$night_config")"
environment_home_env_name="$(jq -r '.credentials.environment_home_env_name' "$night_config")"
environment_file_name="$(jq -r '.credentials.environment_file_name' "$night_config")"
[[ "$wrapper_env_name" =~ ^[A-Z_][A-Z0-9_]*$ && "$environment_home_env_name" =~ ^[A-Z_][A-Z0-9_]*$ \
  && "$environment_file_name" =~ ^[A-Za-z0-9_.-]+$ ]] || {
  echo 'FAIL: invalid credential environment variable name' >&2
  exit 2
}
with_credentials="$(printenv "$wrapper_env_name" || true)"
environment_home="$(printenv "$environment_home_env_name" || true)"
environment_file="${environment_home%/}/$environment_file_name"
missing_env=()
[[ -x "$with_credentials" ]] || missing_env+=("$wrapper_env_name")
[[ -n "$environment_home" && -r "$environment_file" ]] || missing_env+=("$environment_home_env_name")
if ((${#missing_env[@]})); then
  printf 'skip: tenant marker monitor host environment is missing %s\n' "${missing_env[*]}"
  exit 0
fi

exceptions_json="$(jq -ce '
  def epoch: if type == "string" then try fromdateiso8601 catch null else null end;
  def valid_exception:
    type == "object"
    and ((keys - ["basis", "memberKey", "excludeFromMemberParity", "expiresAt"]) | length == 0)
    and (.memberKey | type == "string" and test("^member:[^:]+:[^:]+$"))
    and (.basis | type == "string" and test("\\S"))
    and (if has("excludeFromMemberParity") then (.excludeFromMemberParity | type == "boolean") else true end)
    and (if has("expiresAt") then (.expiresAt | epoch) != null else true end)
    and (.excludeFromMemberParity != true or has("expiresAt"));
  (.anomaly_rules.tenant_markers.exceptions // []) as $exceptions
  | if ($exceptions | type == "array") and all($exceptions[]; valid_exception)
      and ([$exceptions[].memberKey] | length == (unique | length))
    then now as $now
      | [$exceptions[] | select((has("expiresAt") | not) or ((.expiresAt | epoch) > $now)) | .memberKey]
    else error("invalid member exception list")
    end
' "$night_config")" || {
  echo 'FAIL: tenant marker member-key exceptions are invalid' >&2
  exit 2
}

marker_pattern_sql="$marker_pattern"
capture_pattern_sql="$capture_pattern"
invalid_email_pattern_sql="$invalid_email_pattern"
sql="$(cat <<SQL
WITH marker_pattern AS (
  SELECT
    '$marker_pattern_sql'::text AS pattern,
    '$capture_pattern_sql'::text AS capture_pattern,
    '$invalid_email_pattern_sql'::text AS invalid_email_pattern
), account_markers AS (
  SELECT wm.tenant_id,
         wm.employee_id,
         string_agg(DISTINCT lower(split_part(pa.primary_email, '@', 2)), ', '
           ORDER BY lower(split_part(pa.primary_email, '@', 2)))
           FILTER (WHERE position('@' IN pa.primary_email) > 0) AS email_domain,
         string_agg(DISTINCT COALESCE(substring(pa.primary_email FROM p.capture_pattern),
           substring(pa.primary_email FROM p.invalid_email_pattern)), ', ')
           FILTER (WHERE pa.primary_email ~* p.pattern) AS email_markers,
         string_agg(DISTINCT substring(lower(pa.primary_email) FROM p.invalid_email_pattern), ', ')
           FILTER (WHERE pa.primary_email ~* p.invalid_email_pattern) AS email_domain_markers
    FROM $memberships_table wm
    JOIN $accounts_table pa ON pa.id = wm.personal_account_id
    CROSS JOIN marker_pattern p
   GROUP BY wm.tenant_id, wm.employee_id
), marker_rows AS (
  SELECT 'tenant'::text AS kind, '$tenants_table'::text AS table_name, t.id AS tenant_id,
         NULL::text AS member_id, t.name AS tenant_name, t.name AS member_name,
         NULL::text AS email_domain,
         ARRAY['tenant_name:' || substring(t.name FROM p.capture_pattern)] AS matched_markers,
         NULL::jsonb AS history, false AS running_process
    FROM $tenants_table t CROSS JOIN marker_pattern p
   WHERE t.name ~* p.pattern
  UNION ALL
  SELECT 'member'::text AS kind, '$employees_table'::text AS table_name, e.tenant_id,
         e.employee_id AS member_id, COALESCE(t.name, '[missing tenant]') AS tenant_name,
         e.name AS member_name, am.email_domain,
         array_remove(ARRAY[
           CASE WHEN COALESCE(e.name, '') ~* p.pattern THEN 'name:' || substring(e.name FROM p.capture_pattern) END,
           CASE WHEN COALESCE(e.employee_id, '') ~* p.pattern THEN 'member_key:' || substring(e.employee_id FROM p.capture_pattern) END,
           CASE WHEN COALESCE(e.department, '') ~* p.pattern THEN 'department:' || substring(e.department FROM p.capture_pattern) END,
           CASE WHEN am.email_markers IS NOT NULL THEN 'email:' || am.email_markers END,
           CASE WHEN am.email_domain_markers IS NOT NULL THEN 'email_domain:' || am.email_domain_markers END
         ], NULL) AS matched_markers,
         jsonb_build_object(
           'approvals', EXISTS (SELECT 1 FROM $approvals_table ar WHERE ar.applicant_id = e.employee_id OR ar.approved_by = e.employee_id),
           'files', EXISTS (SELECT 1 FROM $files_table f WHERE f.tenant_id = e.tenant_id AND f.owner_id = e.employee_id),
           'ledgerEvents', EXISTS (SELECT 1 FROM $events_table le WHERE le.tenant_id = e.tenant_id
             AND (le.submitted_by_employee_id = e.employee_id OR le.confirmed_by_employee_id = e.employee_id)),
           'rollTargets', EXISTS (SELECT 1 FROM $roll_targets_table rt WHERE rt.tenant_id = e.tenant_id AND rt.employee_id = e.employee_id)
         ) AS history,
         EXISTS (SELECT 1 FROM $instances_table fi WHERE fi.employee_id = e.employee_id
           AND fi.status IN ('running', 'starting') AND fi.container_id IS NOT NULL) AS running_process
    FROM $employees_table e LEFT JOIN $tenants_table t ON t.id = e.tenant_id
    LEFT JOIN account_markers am ON am.tenant_id = e.tenant_id AND am.employee_id = e.employee_id
    CROSS JOIN marker_pattern p
   WHERE COALESCE(e.name, '') ~* p.pattern OR COALESCE(e.employee_id, '') ~* p.pattern
      OR COALESCE(e.department, '') ~* p.pattern OR am.email_markers IS NOT NULL OR am.email_domain_markers IS NOT NULL
      OR EXISTS (SELECT 1 FROM $memberships_table wm JOIN $accounts_table pa ON pa.id = wm.personal_account_id
        WHERE wm.tenant_id = e.tenant_id AND wm.employee_id = e.employee_id
          AND (pa.primary_email ~* p.pattern OR pa.primary_email ~* p.invalid_email_pattern))
)
SELECT jsonb_build_object('markers', COALESCE(jsonb_agg(jsonb_build_object(
  'kind', kind, 'table', table_name, 'tenantId', tenant_id, 'memberId', member_id,
  'tenantName', tenant_name, 'memberName', member_name, 'emailDomain', email_domain,
  'matchedMarkers', matched_markers, 'history', history, 'runningProcess', running_process
) ORDER BY kind, tenant_id, member_id), '[]'::jsonb), 'ledgerMembers', (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tenantId', wm.tenant_id, 'memberId', wm.employee_id, 'ledgerSubjectId', binding.ledger_subject_id
  )), '[]'::jsonb)
  FROM $memberships_table wm LEFT JOIN $bindings_table binding
    ON binding.tenant_id = wm.tenant_id AND binding.employee_id = wm.employee_id
  WHERE wm.tenant_id = '$tenant_id' AND wm.membership_status = 'active' AND wm.employee_id IS NOT NULL
    AND (binding.ledger_subject_id IS NULL OR binding.ledger_subject_id IN ('$production_service_id', '$demo_service_id'))
)) FROM marker_rows;
SQL
)"

if ! markers="$(printf '%s\n' "$sql" | bash "$with_credentials" --env "$environment_file" -- \
  bash -c '
    set -euo pipefail
    user_name="${!1-}"; database_name="${!2-}"; shift 2
    if [[ -z "$user_name" || -z "$database_name" ]]; then
      echo __NIGHT_ENV_MISSING__
      exit 0
    fi
    exec "$@" -U "$user_name" -d "$database_name"
  ' _ "$database_user_env" "$database_name_env" \
  timeout 15s ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_host" \
  docker exec -i "$database_container" psql -v ON_ERROR_STOP=1 -A -t)"; then
  echo 'FAIL: tenant marker read failed' >&2
  exit 2
fi
if [[ "$markers" == '__NIGHT_ENV_MISSING__' ]]; then
  printf 'skip: tenant marker monitor host environment is missing %s or %s\n' "$database_user_env" "$database_name_env"
  exit 0
fi

customer_json="$(jq -c --arg tenant_id "$tenant_id" '{tenant_id:$tenant_id, customer:.customer}' "$night_config")"
if ! summary="$(printf '%s' "$markers" | MARKER_CONFIG_JSON="$customer_json" \
  MARKER_MEMBER_EXCEPTIONS_JSON="$exceptions_json" MARKER_LIST_MODE="$list_mode" node -e '
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
try {
  const config = JSON.parse(process.env.MARKER_CONFIG_JSON);
  const { customer, tenant_id: targetTenantId } = config;
  const { markers: rows, ledgerMembers } = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  const serviceIds = customer.service_ids;
  const allowed = new Map(customer.allowed_members.map(({ id, service }) => [id, serviceIds[service]]));
  if (!Array.isArray(ledgerMembers) || ledgerMembers.some(row =>
    !row || row.tenantId !== targetTenantId || typeof row.memberId !== "string"
      || !(row.ledgerSubjectId === null || Object.values(serviceIds).includes(row.ledgerSubjectId)))
      || new Set(ledgerMembers.map(row => row.memberId)).size !== ledgerMembers.length) {
    throw new Error("invalid ledger members");
  }
  const ledgerViolations = ledgerMembers.filter(row => allowed.get(row.memberId) !== row.ledgerSubjectId);
  const missingMembers = [...allowed.keys()].filter(id => !ledgerMembers.some(row => row.memberId === id));
  const demoMembers = new Set(ledgerMembers.filter(row => row.ledgerSubjectId === serviceIds.demo
    && allowed.get(row.memberId) === serviceIds.demo).map(row => row.memberId));
  const exceptions = new Set(JSON.parse(process.env.MARKER_MEMBER_EXCEPTIONS_JSON));
  if (!Array.isArray(rows) || rows.some(row =>
    !row || !["member", "tenant"].includes(row.kind) || !row.tenantId || !row.table
      || (row.kind === "member" && (!row.memberId || !row.history || !Array.isArray(row.matchedMarkers))))) {
    throw new Error("invalid marker rows");
  }
  const findings = rows.filter(row => row.kind !== "member"
    || (!exceptions.has(`member:${row.tenantId}:${row.memberId}`)
      && !(row.tenantId === targetTenantId && demoMembers.has(row.memberId))));
  if (process.env.MARKER_LIST_MODE === "1") {
    const cell = value => String(value ?? "").replace(/[|\t\r\n]/g, " ");
    const key = row => {
      if (row.kind !== "member") return "—";
      const memberId = String(row.memberId);
      const at = memberId.lastIndexOf("@");
      return `member:${row.tenantId}:${at < 0 ? memberId : `${memberId.slice(0, at)}@[redacted]`}`;
    };
    const history = (row, name) => row.history?.[name] === true ? "yes" : row.history?.[name] === false ? "no" : "n/a";
    const columns = ["Tenant", "Table", "Member key", "Display name", "Email domain only", "Marker matched", "Approvals", "Files", "Ledger events", "Roll targets", "Running process"];
    const lines = [`Customer: ${cell(customer.name)}`, `UNMATCHED=${findings.length}`, `LEDGER_VIOLATIONS=${ledgerViolations.length + missingMembers.length}`,
      `| ${columns.join(" | ")} |`, `| ${columns.map(() => "---").join(" | ")} |`];
    for (const row of findings) lines.push(`| ${[
      cell(row.tenantName), cell(row.table), cell(key(row)), cell(row.memberName), cell(row.emailDomain),
      cell((row.matchedMarkers ?? []).join(", ")), history(row, "approvals"), history(row, "files"),
      history(row, "ledgerEvents"), history(row, "rollTargets"),
      row.runningProcess === true ? "yes" : row.runningProcess === false ? "no" : "unknown",
    ].join(" | ")} |`);
    const redact = id => String(id).replace(/@.*/, "@[redacted]");
    for (const row of ledgerViolations) lines.push(`member binding violation: ${redact(row.memberId)} service=${row.ledgerSubjectId ?? "unbound"}`);
    for (const id of missingMembers) lines.push(`configured member missing: ${redact(id)}`);
    process.stdout.write(`${lines.join("\n")}\n`);
    process.exit(0);
  }
  process.stdout.write(JSON.stringify({
    count: findings.length,
    ledgerViolations: ledgerViolations.length + missingMembers.length,
    tenantIds: [...new Set(findings.map(row => row.tenantId))].sort(),
  }));
} catch {
  process.exit(2);
}
')"; then
  echo 'FAIL: tenant marker result could not be parsed' >&2
  exit 2
fi

if ((list_mode)); then
  printf '%s\n' "$summary"
  exit 0
fi

count="$(jq -r '.count' <<< "$summary")"
tenant_ids="$(jq -r '.tenantIds | join(",")' <<< "$summary")"
ledger_violations="$(jq -r '.ledgerViolations' <<< "$summary")"
if ((ledger_violations > 0)); then
  printf 'FAIL: %s configured member binding violation(s)\n' "$ledger_violations" >&2
  exit 1
fi
if ((count > 0)); then
  printf 'FAIL: %s tenant marker row(s) for %s; tenant ids: %s\n' "$count" "$customer_name" "$tenant_ids" >&2
  exit 1
fi

printf 'PASS: no tenant or member marker findings for %s\n' "$customer_name"
