#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
config_root="$tmp/.zenoforge"
pack_dir="$tmp/pack"
mkdir -p "$config_root" "$pack_dir" "$tmp/bin"

jq -n '{production:{
  container_names:{production:["target-app","target-db"],database:"target-db",shard_pattern:"target-shard-*"},
  database_user_env:"TEST_DB_USER",database_name_env:"TEST_DB_NAME",
  log_sources:{trace_table:"test.trace_events",ux_span:"target-span",ux_channel:"target-channel"}
},anomaly_rules:{production_logs:{window:"10m",base_log_line_cap:100,shard_log_line_cap:50,
  trace_limit:10,ux_limit:5,stuck_after_seconds:60,log_line_error_pattern:"FIXTURE_FAILURE",
  http_error_pattern:"NO_HTTP_ERRORS",stack_trace_pattern:"NO_STACK_TRACES"}}}' > "$config_root/night.json"
jq '.production.container_names.production=["pack-app"]
  | .production.container_names.shard_pattern="pack-shard-*"
  | .production.container_names.database="pack-db"
  | .production.log_sources.ux_span="pack-span"
  | .anomaly_rules.production_logs.log_line_error_pattern="PACK_ONLY"' \
  "$config_root/night.json" > "$pack_dir/night.json"

cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  ps)
    printf '%s\n' \
      'abcdef123456|target-app' 'bcdef1234567|target-db' 'cdef12345678|target-shard-1' \
      'def123456789|pack-app' 'ef123456789a|unconfigured'
    ;;
  inspect)
    shift 3
    for id in "$@"; do
      case "$id" in
        abcdef123456) name=target-app ;;
        bcdef1234567) name=target-db ;;
        cdef12345678) name=target-shard-1 ;;
        *) exit 64 ;;
      esac
      printf '/%s|0|false|0|0001-01-01T00:00:00Z|true\n' "$name"
    done
    ;;
  exec)
    [[ "$*" == *'target-db'* ]]
    if [[ "$*" == *"span = 'target-span'"* ]]; then
      printf '%s\n' '{"trace_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","first_visible_ms":10,"silent_gap_ms":20,"errored":false,"stuck":false}'
    else
      [[ "$*" == *'FROM test.trace_events'* ]]
      printf '%s\n' '{"trace_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","service":"sample","route":"/status"}'
    fi
    ;;
  logs)
    container="${@: -1}"
    printf '%s\n' "$container" >> "$PROD_ERRORS_DOCKER_LOGS"
    if [[ "$container" == target-shard-1 ]]; then
      [[ "$*" == *'--tail 50'* ]]
      printf '%s\n' '2026-01-01T00:00:00Z FIXTURE_FAILURE fixture failure'
    else
      [[ "$*" == *'--tail 100'* ]]
      printf '%s\n' '2026-01-01T00:00:00Z INFO fixture message'
    fi
    ;;
  *) exit 64 ;;
esac
DOCKER
chmod +x "$tmp/bin/docker"

: > "$tmp/docker-logs"
TEST_DB_USER=fixture-user TEST_DB_NAME=fixture-db PROD_ERRORS_DOCKER_LOGS="$tmp/docker-logs" \
  ZF_CONFIG_ROOT="$config_root" ZF_PACK_DIR="$pack_dir" PATH="$tmp/bin:$PATH" \
  bash "$script_dir/prod-errors-readonly.sh" > "$tmp/result"

grep -Fxq '__PROD_ERRORS_OK__' "$tmp/result"
grep -Fq 'target-shard-1' "$tmp/result"
grep -Fq 'FIXTURE_FAILURE fixture failure' "$tmp/result"
grep -Fxq target-app "$tmp/docker-logs"
grep -Fxq target-db "$tmp/docker-logs"
grep -Fxq target-shard-1 "$tmp/docker-logs"
! grep -Fxq pack-app "$tmp/docker-logs"
! grep -Fxq unconfigured "$tmp/docker-logs"

ZF_CONFIG_ROOT="$tmp/empty-config" ZF_PACK_DIR='' bash "$script_dir/prod-errors-readonly.sh" > "$tmp/skipped"
grep -Fq 'skip: night log monitor needs container, log-source and anomaly-rule values' "$tmp/skipped"
echo 'ok - configured log sources and containers use the target night.json override'
