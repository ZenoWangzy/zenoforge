#!/usr/bin/env bash
# Run the engine test suites, optionally one shard of them: run-engine-tests.sh [shard] [shards]
set -uo pipefail
cd "$(dirname "$0")/.."
shard=${1:-0} shards=${2:-1} timeout_s=${SUITE_TIMEOUT:-600}
# *.test.py files are driven by their *.test.sh wrapper (it sources test-env.sh: isolated HOME and AGENT_HOME, test mode); run alone
# they lack that environment and execution-admission-metrics.test.py drops its metric rows. Upstream discovers only .test.sh and .test.mjs.
mapfile -t suites < <(find engine \( -name '*.test.sh' -o -name '*.test.mjs' \) | sort | awk -v s="$shard" -v n="$shards" 'NR % n == s')
# tools/quarantine.txt: "<suite>\t<reason>" per line, suites known to fail for a reason outside the exported files; skipped and counted, never silently.
declare -A quarantine=()
while IFS=$'\t' read -r qsuite qreason; do
  [[ -n $qsuite && $qsuite != \#* ]] && quarantine[$qsuite]=$qreason
done < <(cat tools/quarantine.txt 2>/dev/null)
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
  if timeout -s KILL "$timeout_s" "${cmd[@]}" > "$log" 2>&1; then
    pass=$((pass + 1)); echo "PASS $t"; rm -f "$log"
  else
    rc=$?; fail=$((fail + 1)); failed+=("$t rc=$rc"); echo "FAIL $t rc=$rc"; tail -15 "$log" | sed 's/^/    /'
  fi
done
echo "shard $shard/$shards: $pass passed, $fail failed, $skipped quarantined"
printf '%s\n' "${failed[@]}" > "engine-test-failures-$shard.txt"
exit $(( fail > 0 ))
