#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
config_root="$tmp/.zenoforge"
pack_dir="$tmp/pack"
bin_dir="$tmp/bin"
mkdir -p "$config_root" "$pack_dir" "$bin_dir" "$tmp/agent-home"
touch "$tmp/agent-home/env"

cat > "$tmp/target-night.json" <<'JSON'
{
  "credentials": {
    "wrapper_env_name": "TEST_CREDENTIAL_WRAPPER",
    "environment_home_env_name": "TEST_ENV_HOME",
    "environment_file_name": "env"
  },
  "production": {
    "container_names": {"database": "target-database"},
    "database_user_env": "TEST_DATABASE_USER",
    "database_name_env": "TEST_DATABASE_NAME"
  },
  "authorization": {
    "ssh_host": "target-host",
    "service_container": "target-service",
    "pack_key": "target-pack",
    "target_tenant_id": "target-tenant",
    "api": {
      "host": "127.0.0.1",
      "port": 8080,
      "path": "/probe",
      "service_token_header": "x-test-token",
      "employee_header": "x-test-employee"
    },
    "service_token_env_name": "TEST_SERVICE_TOKEN",
    "expected_denial_status": 403,
    "required_role_level": 10,
    "manifest_id_field": "fixturePackId",
    "statuses": {
      "install_scope": "target-scope",
      "installation": "target-installed",
      "pack": "target-active",
      "version": "target-published",
      "membership": "target-member"
    },
    "tenant_statuses": ["active", "trial"],
    "tables": {
      "installations": "fixture.pack_installs",
      "packs": "fixture.packs",
      "versions": "fixture.versions",
      "tenants": "fixture.tenants",
      "employees": "fixture.employees",
      "memberships": "fixture.memberships",
      "employee_roles": "fixture.employee_roles",
      "roles": "fixture.roles",
      "bindings": "fixture.bindings"
    }
  }
}
JSON
cp "$tmp/target-night.json" "$config_root/night.json"
jq '.authorization.ssh_host = "pack-host"
  | .authorization.service_container = "pack-service"
  | .authorization.target_tenant_id = "pack-tenant"
  | .authorization.tables.employees = "pack.employees"' \
  "$tmp/target-night.json" > "$pack_dir/night.json"

cat > "$bin_dir/with-credentials" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CALL_LOG"
if [[ " $* " == *' psql '* ]]; then
  cat > "$TEST_SQL_LOG"
  printf '%s\n' "$TEST_CONTEXT"
else
  TEST_SERVICE_TOKEN=fixture node --import "$TEST_FETCH_STUB" -
fi
WRAPPER
cat > "$tmp/fetch.mjs" <<'JS'
globalThis.fetch = async (_url, options) => ({
  status: Number(process.env[options.headers['x-test-employee'] === 'privileged-id'
    ? 'TEST_PRIVILEGED_STATUS' : 'TEST_CROSS_STATUS']),
  body: { cancel: async () => {} },
});
JS
chmod +x "$bin_dir/with-credentials"

export TEST_CREDENTIAL_WRAPPER="$bin_dir/with-credentials"
export TEST_ENV_HOME="$tmp/agent-home"
export TEST_DATABASE_USER=fixture TEST_DATABASE_NAME=fixture
export TEST_CALL_LOG="$tmp/calls" TEST_SQL_LOG="$tmp/sql" TEST_FETCH_STUB="$tmp/fetch.mjs"
export TEST_CONTEXT='{"installedTenantIds":["target-tenant"],"privilegedEmployeeId":"privileged-id","crossTenantEmployeeId":"cross-id"}'
export TEST_PRIVILEGED_STATUS=403 TEST_CROSS_STATUS=403

ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" bash "$script_dir/authorization-readonly.sh" > "$tmp/result"
grep -Fxq 'OK authorization tenants=1 target=installed unexpected=0 cross-tenant=403 privileged=403' "$tmp/result"
grep -Fq "target-host" "$TEST_CALL_LOG"
grep -Fq "target-service" "$TEST_CALL_LOG"
grep -Fq "fixture.pack_installs" "$TEST_SQL_LOG"
grep -Fq "target-tenant" "$TEST_SQL_LOG"
if grep -Fq "pack-host\|pack-service\|pack-tenant\|pack.employees" "$TEST_CALL_LOG" "$TEST_SQL_LOG"; then
  echo 'FAIL: pack config won over the target .zenoforge override' >&2
  exit 1
fi

echo 'ok - authorization monitor uses the target configuration override'
