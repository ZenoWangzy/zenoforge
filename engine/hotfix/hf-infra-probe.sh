#!/usr/bin/env bash
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh"
config=$(zf_config_file hotfix.json) || {
  legacy=$(pack_file hotfix/hf-infra-probe.sh) && exec bash "$legacy" "$@"
  echo 'hf-infra-probe: configure infrastructure probe in hotfix.json' >&2; exit 1
}
if ! jq -e '.infra_probe | (.host | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_.@-]*$")) and (.container | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$")) and (.cpu_limit | type == "number" and . > 0 and floor == .) and (.memory_limit | type == "number" and . > 0 and floor == .)' "$config" >/dev/null; then
  echo 'hf-infra-probe: configure host, container and limits in hotfix.json' >&2; exit 1
fi
host=$(jq -r '.infra_probe.host' "$config")
container=$(jq -r '.infra_probe.container' "$config")
host_env=$(jq -r '.infra_probe.host_env // ""' "$config")
container_env=$(jq -r '.infra_probe.container_env // ""' "$config")
for name in "$host_env" "$container_env"; do
  [[ -z $name || $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo 'hf-infra-probe: invalid environment variable name' >&2; exit 1; }
done
[[ -z $host_env ]] || host=${!host_env:-$host}
[[ -z $container_env ]] || container=${!container_env:-$container}
[[ $host =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ && $container =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { echo 'hf-infra-probe: invalid host or container' >&2; exit 1; }
cpu=$(jq -r '.infra_probe.cpu_limit' "$config")
mem=$(jq -r '.infra_probe.memory_limit' "$config")
# Identifiers and numeric limits are validated before inclusion in the remote command.
ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "C=$container CPU_LIMIT=$cpu MEM_LIMIT=$mem bash -s" <<'REMOTE'
id=$(docker inspect -f '{{.Id}}' "$C") || exit 2
g=/sys/fs/cgroup/system.slice/docker-$id.scope
lim=$(docker inspect -f 'cpus={{.HostConfig.NanoCpus}} mem={{.HostConfig.Memory}}' "$C")
per=$(awk '/nr_periods/{print $2}' "$g/cpu.stat"); thr=$(awk '/nr_throttled/{print $2}' "$g/cpu.stat")
oom=$(awk '/^oom_kill /{print $2}' "$g/memory.events"); mx=$(awk '/^max /{print $2}' "$g/memory.events")
rec=$(docker logs --since 24h "$C" 2>&1 | grep -c 'not properly shut down')
echo "limits: $lim | throttled ${thr}/${per} periods | oom_kill_total=$oom mem_max_hits=$mx | crash_recoveries_24h=$rec"
bad=0
[[ $lim == *cpus=$CPU_LIMIT* || $lim == *mem=$MEM_LIMIT* ]] && { echo "FINDING: container capped at configured CPU or memory limit, raise before touching queries"; bad=1; }
p2=$(awk '/nr_periods/{print $2}' "$g/cpu.stat"); t2=$(awk '/nr_throttled/{print $2}' "$g/cpu.stat"); sleep 10
p3=$(awk '/nr_periods/{print $2}' "$g/cpu.stat"); t3=$(awk '/nr_throttled/{print $2}' "$g/cpu.stat")
((t3 - t2 > 0 && (t3 - t2) * 10 > p3 - p2)) && { echo "FINDING: pg CPU-throttled over 10% of the last 10s"; bad=1; }
((rec > 0)) && { echo "FINDING: $rec crash recoveries in 24h"; bad=1; }
exit $bad
REMOTE
