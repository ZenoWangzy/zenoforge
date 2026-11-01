#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
config_root="$tmp/.zenoforge"
pack_dir="$tmp/pack"
mkdir -p "$config_root" "$pack_dir" "$tmp/credentials"
: > "$tmp/credentials/env"

jq -n '{production:{ssh_hosts:{tenant_marker:"target-host"},
  container_names:{database:"target-db"},tenant_ids:{marker_probe:"target-tenant"},
  database_user_env:"TEST_DB_USER",database_name_env:"TEST_DB_NAME",
  log_sources:{tenants_table:"test.tenants",memberships_table:"test.memberships",accounts_table:"test.accounts",
    employees_table:"test.employees",approvals_table:"test.approvals",files_table:"test.files",
    events_table:"test.events",roll_targets_table:"test.roll_targets",instances_table:"test.instances",
    bindings_table:"test.bindings"}},
  anomaly_rules:{tenant_markers:{pattern:"test|demo",capture_pattern:"(test|demo)",
    invalid_email_pattern:"(?i)@[^@]+[.](test|invalid)$",exceptions:[]}},
  credentials:{wrapper_env_name:"NIGHT_CREDENTIALS_WRAPPER",environment_home_env_name:"NIGHT_CREDENTIALS_HOME",
    environment_file_name:"env"},
  customer:{name:"Target Customer",service_ids:{production:"01234567-89ab-cdef-0123-456789abcdef",
    demo:"abcdef01-2345-6789-abcd-ef0123456789"},
    allowed_members:[{id:"member-one",service:"production"},{id:"demo-two",service:"demo"}]}}' > "$config_root/night.json"
jq '.production.ssh_hosts.tenant_marker="pack-host"
  | .production.container_names.database="pack-db"
  | .production.tenant_ids.marker_probe="pack-tenant"
  | .customer.name="Pack Customer"' "$config_root/night.json" > "$pack_dir/night.json"

cat > "$tmp/with-credentials" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$WRAPPER_CALLS"
cat > "$PROBE_SQL_CAPTURE"
jq -n --slurpfile markers "$PROBE_MARKERS" --slurpfile members "$PROBE_MEMBERS" \
  '{markers:$markers[0],ledgerMembers:$members[0]}'
WRAPPER
chmod +x "$tmp/with-credentials"

jq -n '[{kind:"member",table:"test.employees",tenantId:"target-tenant",memberId:"smoke-user@example.invalid",
  tenantName:"Target Tenant",memberName:"Synthetic Member",emailDomain:"example.invalid",matchedMarkers:["name:test"],
  history:{approvals:false,files:false,ledgerEvents:false,rollTargets:false},runningProcess:false}]' > "$tmp/markers.json"
jq -n '[{tenantId:"target-tenant",memberId:"member-one",ledgerSubjectId:"01234567-89ab-cdef-0123-456789abcdef"},
  {tenantId:"target-tenant",memberId:"demo-two",ledgerSubjectId:"abcdef01-2345-6789-abcd-ef0123456789"}]' > "$tmp/members.json"

NIGHT_CREDENTIALS_WRAPPER="$tmp/with-credentials" NIGHT_CREDENTIALS_HOME="$tmp/credentials" \
  TEST_DB_USER=fixture-user TEST_DB_NAME=fixture-db WRAPPER_CALLS="$tmp/wrapper.calls" \
  PROBE_SQL_CAPTURE="$tmp/query.sql" PROBE_MARKERS="$tmp/markers.json" PROBE_MEMBERS="$tmp/members.json" \
  ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" \
  bash "$script_dir/production-tenant-marker-readonly.sh" --list > "$tmp/result"

! grep -Fq 'Customer:' "$tmp/result"
grep -Fq 'target-tenant' "$tmp/result"
grep -Fq 'UNMATCHED=1' "$tmp/result"
grep -Fq "WHERE wm.tenant_id = 'target-tenant'" "$tmp/query.sql"
grep -Fq 'JOIN test.bindings' "$tmp/query.sql"
! grep -Fq 'pack-tenant' "$tmp/query.sql"
grep -Fq 'target-host' "$tmp/wrapper.calls"
grep -Fq 'target-db' "$tmp/wrapper.calls"
! grep -Fq 'pack-host' "$tmp/wrapper.calls"
! grep -Fq 'pack-db' "$tmp/wrapper.calls"

ZF_CONFIG_ROOT="$tmp/empty-config" ZF_PACK_DIR='' \
  bash "$script_dir/production-tenant-marker-readonly.sh" > "$tmp/skipped"
grep -Fq 'skip: tenant marker monitor needs topology, tenant, customer and anomaly-rule values' "$tmp/skipped"

# Without the wrapper environment and the database environment, credentials.wrapper_script
# (relative to ZF_REPO_DIR) and .production.database_user/.database_name carry the probe.
mkdir -p "$tmp/repo/ops" "$tmp/fallback-config/.zenoforge" "$tmp/shim"
cat > "$tmp/repo/ops/with-credentials.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
shift 3
exec "$@"
WRAPPER
cat > "$tmp/shim/timeout" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROBE_PSQL_ARGS"
jq -c -n --slurpfile markers "$PROBE_MARKERS" --slurpfile members "$PROBE_MEMBERS" \
  '{markers:$markers[0],ledgerMembers:$members[0]}'
SH
chmod +x "$tmp/repo/ops/with-credentials.sh" "$tmp/shim/timeout"
jq '.credentials.wrapper_script = "ops/with-credentials.sh"
  | .production.database_user = "configured-user"
  | .production.database_name = "configured-db"' "$config_root/night.json" > "$tmp/fallback-config/.zenoforge/night.json"

env -u NIGHT_CREDENTIALS_WRAPPER -u TEST_DB_USER -u TEST_DB_NAME \
  NIGHT_CREDENTIALS_HOME="$tmp/credentials" PROBE_PSQL_ARGS="$tmp/psql.args" \
  PROBE_MARKERS="$tmp/markers.json" PROBE_MEMBERS="$tmp/members.json" \
  ZF_CONFIG_ROOT="$tmp/fallback-config/.zenoforge" ZF_PACK_DIR='' ZF_REPO_DIR="$tmp/repo" \
  PATH="$tmp/shim:$PATH" \
  bash "$script_dir/production-tenant-marker-readonly.sh" --list > "$tmp/fallback-result"
! grep -Fq 'Customer:' "$tmp/fallback-result"
grep -Fq -- '-U configured-user -d configured-db' "$tmp/psql.args"
echo 'ok - tenant marker topology, identities and rules use the target night.json override'
