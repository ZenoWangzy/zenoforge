#!/usr/bin/env bash
# Run the engine test suites, optionally one shard of them: run-engine-tests.sh [shard] [shards]
set -uo pipefail
cd "$(dirname "$0")/.."
shard=${1:-0} shards=${2:-1} timeout_s=${SUITE_TIMEOUT:-600}
# *.test.py files are driven by their *.test.sh wrapper (it sources test-env.sh: isolated HOME and AGENT_HOME, test mode); run alone
# they lack that environment and execution-admission-metrics.test.py drops its metric rows. Upstream discovers only .test.sh and .test.mjs.
# PORTABLE_ONLY=1 keeps only the suites listed in tools/portable-suites.txt (the platform-layer suites that run on every OS leg).
portable_filter() { if [[ ${PORTABLE_ONLY:-} == 1 ]]; then grep -Fxf <(awk 'NF && $1 !~ /^#/ {print $1}' tools/portable-suites.txt); else cat; fi; }
mapfile -t suites < <(find engine \( -name '*.test.sh' -o -name '*.test.mjs' \) | sort | portable_filter | awk -v s="$shard" -v n="$shards" 'NR % n == s')
# tools/quarantine.txt: "<suite>\t<reason>" per line, suites known to fail for a reason outside the exported files; skipped and counted, never silently.
# ZF_QUARANTINE_SETS="darwin wsl" (space or comma separated) also loads tools/quarantine-darwin.txt and tools/quarantine-wsl.txt, same format.
declare -A quarantine=()
qfiles=(tools/quarantine.txt)
qsets=${ZF_QUARANTINE_SETS:-}
for qset in ${qsets//,/ }; do qfiles+=("tools/quarantine-$qset.txt"); done
while IFS=$'\t' read -r qsuite qreason; do
  [[ -n $qsuite && $qsuite != \#* ]] && quarantine[$qsuite]=$qreason
done < <(for qf in "${qfiles[@]}"; do cat "$qf" 2>/dev/null; echo; done)
pass=0 fail=0 skipped=0 failed=()
for t in "${suites[@]}"; do
  if [[ -n ${quarantine[$t]+x} ]]; then
    skipped=$((skipped + 1)); echo "QUARANTINED $t - ${quarantine[$t]}"; continue
  fi
  case $t in
    *.test.mjs) cmd=(node --test --test-concurrency=1 "$t") ;;
    *) cmd=(bash "$t") ;;
  esac
  log="test-logs/${t//\//__}.log"; mkdir -p test-logs
  # scheduler.test.sh runs ~55 real scheduler ticks in one process; it needs far more than the default limit.
  limit=$timeout_s; [[ $t == engine/mac-autopilot/scheduler.test.sh ]] && limit=${SCHEDULER_SUITE_TIMEOUT:-3000}
  if timeout -s KILL "$limit" "${cmd[@]}" > "$log" 2>&1; then
    pass=$((pass + 1)); echo "PASS $t"; rm -f "$log"
  else
    rc=$?; fail=$((fail + 1)); failed+=("$t rc=$rc"); echo "FAIL $t rc=$rc"; tail -15 "$log" | sed 's/^/    /'
  fi
done
echo "shard $shard/$shards: $pass passed, $fail failed, $skipped quarantined"
printf '%s\n' "${failed[@]}" > "engine-test-failures-$shard.txt"
exit $(( fail > 0 ))
