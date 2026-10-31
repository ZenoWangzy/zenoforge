#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d)
mkdir -p "$t/cg" "$t/config" "$t/pack"
printf 'nr_periods 100\nnr_throttled 20\n' > "$t/cg/cpu.stat"
printf 'oom_kill 5\nmax 9\n' > "$t/cg/memory.events"
cat > "$t/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in inspect) [[ "$3" == *Id* ]] && echo abc || echo 'cpus=100 mem=200';; logs) echo 'database system was not properly shut down';; esac
STUB
cat > "$t/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SSH_ARGS"
sed "s#/sys/fs/cgroup/system.slice/docker-\$id.scope#$CG_DIR#" | env C=x CPU_LIMIT=100 MEM_LIMIT=200 bash -s
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/sleep"
chmod +x "$t/docker" "$t/ssh" "$t/sleep"
export PATH="$t:$PATH" ZF_CONFIG_ROOT=$t/config ZF_PACK_DIR=$t/pack SSH_ARGS=$t/args CG_DIR=$t/cg
printf '%s\n' '{"infra_probe":{"host":"pack","container":"pack","cpu_limit":100,"memory_limit":200}}' > "$t/pack/hotfix.json"
printf '%s\n' '{"infra_probe":{"host":"override","container":"service","cpu_limit":100,"memory_limit":200}}' > "$t/config/hotfix.json"
out=$("$p/hf-infra-probe.sh" 2>&1) && { echo 'expected finding'; exit 1; }
grep -q 'FINDING: container capped' <<< "$out"
grep -q 'FINDING: 1 crash recoveries' <<< "$out"
grep -Fxq override "$SSH_ARGS"
mv "$t/config/hotfix.json" "$t/override.json"
"$p/hf-infra-probe.sh" >/dev/null 2>&1 || true
grep -Fxq pack "$SSH_ARGS"
mv "$t/pack/hotfix.json" "$t/pack.json"
! "$p/hf-infra-probe.sh" >/dev/null 2>&1
mkdir -p "$t/pack/hotfix"
printf '#!/usr/bin/env bash\nprintf legacy > "$LEGACY_LOG"\n' > "$t/pack/hotfix/hf-infra-probe.sh"
export LEGACY_LOG=$t/legacy
"$p/hf-infra-probe.sh"
[[ $(cat "$LEGACY_LOG") == legacy ]]
