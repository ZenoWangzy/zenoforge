#!/usr/bin/env bash
set -euo pipefail
unset ZF_INTENDED_WARNINGS_SUPPRESSED
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ $# -lt 5 || $# -gt 6 || ( $# -eq 6 && -z "$6" ) ]]; then
  echo "usage: run.sh <live version dir> <new version dir> <target repo> <live ref> <new ref> [intended-change list]" >&2
  exit 2
fi
live_version=$1
new_version=$2
target_repo=$3
live_ref=$4
new_ref=$5
intended=()
[[ $# -eq 5 ]] || intended=("$6")

run_gate() {
  local gate="$1"
  case "$gate" in
    unit-paths)
      echo "publish-preflight: checking unit paths"
      if ! bash "$here/unit-paths-check.sh" "$live_version" "$new_version"; then
        echo "publish-preflight: unit-paths check failed" >&2; return 1
      fi
      ;;
    resolved-config)
      echo "publish-preflight: checking resolved config"
      if [[ "${ZF_PREFLIGHT_PREVIOUSLY_LIVE:-0}" == 1 ]]; then
        echo "publish-preflight: skipping resolved-config comparison for previously live version"
      elif ! python3 -I "$here/resolved-config-check.py" \
        "$live_version" "$target_repo" "$live_ref" "$new_version" "$target_repo" "$new_ref" "${intended[@]}"; then
        echo "publish-preflight: resolved-config check failed" >&2; return 1
      fi
      # Both config and dropped-file checks consume the same row format. Emit each stale-row
      # warning once per preflight, from the first comparison that reads the list.
      export ZF_INTENDED_WARNINGS_SUPPRESSED=1
      ;;
    suite-set)
      echo "publish-preflight: checking suite set"
      if ! python3 -I "$here/suite-set-check.py" "$live_version" "$new_version" "$target_repo" "$new_ref"; then
        echo "publish-preflight: suite-set check failed" >&2; return 1
      fi
      ;;
    dropped-file-refs)
      echo "publish-preflight: checking dropped file references"
      if [[ "${ZF_PREFLIGHT_PREVIOUSLY_LIVE:-0}" == 1 ]]; then
        echo "publish-preflight: skipping dropped-file-refs comparison for previously live version"
      elif ! python3 -I "$here/dropped-file-refs-check.py" "$live_version" "$new_version" "${intended[@]}"; then
        echo "publish-preflight: dropped-file-refs check failed" >&2; return 1
      fi
      export ZF_INTENDED_WARNINGS_SUPPRESSED=1
      ;;
    advisor-runner)
      echo "publish-preflight: checking advisor runner"
      if [[ "${ZF_PREFLIGHT_PREVIOUSLY_LIVE:-0}" == 1 ]]; then
        echo "publish-preflight: skipping advisor-runner check for previously live version"
      elif git -C "$target_repo" show "$new_ref:.zenoforge/advisor.json" 2>/dev/null | jq -e 'has("batchRunner")' >/dev/null 2>&1; then
        echo "publish-preflight: advisor.json sets batchRunner, which replaces the engine runner with a product fork; remove the key" >&2
        return 1
      fi
      ;;
    *) echo "publish-preflight: unknown gate in gates.tsv: $gate" >&2; return 2 ;;
  esac
}

while IFS= read -r gate; do
  [[ -n "$gate" && "$gate" != \#* ]] || continue
  run_gate "$gate" || exit $?
done < "$here/gates.tsv"

echo "publish-preflight: OK"
