#!/usr/bin/env bash
# Run the engine test suites, optionally one shard of them: run-engine-tests.sh [shard] [shards]
# ZF_SUITES_FILE=<path> uses that newline-delimited suite list instead of discovering every suite.
set -uo pipefail
cd "$(dirname "$0")/.."
shard=${1:-0} shards=${2:-1} timeout_s=${SUITE_TIMEOUT:-600}
# *.test.py files are driven by their *.test.sh wrapper (it sources test-env.sh: isolated HOME and AGENT_HOME, test mode); run alone
# they lack that environment and execution-admission-metrics.test.py drops its metric rows. Upstream discovers only .test.sh and .test.mjs.
# PORTABLE_ONLY=1 keeps only the suites listed in tools/portable-suites.txt (the platform-layer suites that run on every OS leg).
portable_filter() { if [[ ${PORTABLE_ONLY:-} == 1 ]]; then grep -Fxf <(awk 'NF && $1 !~ /^#/ {print $1}' tools/portable-suites.txt); else cat; fi; }
if [[ -n "${ZF_SUITES_FILE:-}" && ! -f "$ZF_SUITES_FILE" ]]; then
  echo "ERROR run-engine-tests: ZF_SUITES_FILE does not exist: $ZF_SUITES_FILE" >&2
  exit 2
fi
mapfile -t suites < <(
  if [[ -n "${ZF_SUITES_FILE:-}" ]]; then
    cat -- "$ZF_SUITES_FILE"
  else
    find engine \( -name '*.test.sh' -o -name '*.test.mjs' \) | sort
  fi | portable_filter | awk -v s="$shard" -v n="$shards" 'NR % n == s'
)
# CI runs this once per run (shard 0): check-rulings.sh static mode enforces the bootstrap but CI never ran it, so 13 suites drifted.
if [[ $shard == 0 ]]; then
  mapfile -t bootstrap_files < <(find engine -type f -name '*.test.sh')
  bash engine/test-bootstrap-check.sh "${bootstrap_files[@]}" || { echo 'ERROR run-engine-tests: test bootstrap check failed' >&2; exit 1; }
fi
# tools/quarantine.txt: "<suite>\t<reason>" per line, suites known to fail for a reason outside the exported files; skipped and counted, never silently.
# ZF_QUARANTINE_SETS="darwin wsl" (space or comma separated) also loads tools/quarantine-darwin.txt and tools/quarantine-wsl.txt, same format.
declare -A quarantine=() quarantine_set_suites=() quarantine_counts=()
qsets=${ZF_QUARANTINE_SETS:-}
while IFS=$'\t' read -r qsuite qreason; do
  [[ -n $qsuite && $qsuite != \#* ]] && quarantine[$qsuite]=$qreason
done < <(cat tools/quarantine.txt 2>/dev/null; echo)
for qset in ${qsets//,/ }; do
  quarantine_counts[$qset]=0
  while IFS=$'\t' read -r qsuite qreason; do
    if [[ -n $qsuite && $qsuite != \#* ]]; then
      quarantine[$qsuite]=$qreason
      quarantine_set_suites["$qset"$'\034'"$qsuite"]=1
    fi
  done < <(cat "tools/quarantine-$qset.txt" 2>/dev/null; echo)
done
pass=0 fail=0 skipped=0 failed=()
for t in "${suites[@]}"; do
  if [[ -n ${quarantine[$t]+x} ]]; then
    for qset in ${qsets//,/ }; do
      key="$qset"$'\034'"$t"
      [[ -n ${quarantine_set_suites[$key]+x} ]] && quarantine_counts[$qset]=$((quarantine_counts[$qset] + 1))
    done
    skipped=$((skipped + 1)); echo "QUARANTINED $t - ${quarantine[$t]}"; continue
  fi
  case $t in
    *.test.mjs) cmd=(node --test --test-concurrency=1 "$t") ;;
    *.test.py) cmd=(python3 "$t") ;;
    *) cmd=(bash "$t") ;;
  esac
  log="test-logs/${t//\//__}.log"; mkdir -p test-logs
  # Scheduler partitions run real ticks and retain the existing scheduler limit.
  limit=$timeout_s; [[ $t == engine/mac-autopilot/scheduler.test.sh || $t == engine/mac-autopilot/scheduler-part-*.test.sh ]] && limit=${SCHEDULER_SUITE_TIMEOUT:-3000}
  if timeout -s KILL "$limit" "${cmd[@]}" > "$log" 2>&1; then
    pass=$((pass + 1)); echo "PASS $t"; rm -f "$log"
  else
    rc=$?; fail=$((fail + 1)); failed+=("$t rc=$rc"); echo "FAIL $t rc=$rc"; tail -15 "$log" | sed 's/^/    /'
  fi
done
for qset in ${qsets//,/ }; do echo "QUARANTINE $qset: ${quarantine_counts[$qset]}"; done
echo "shard $shard/$shards: $pass passed, $fail failed, $skipped quarantined"
printf '%s\n' "${failed[@]}" > "engine-test-failures-$shard.txt"
exit $(( fail > 0 ))
