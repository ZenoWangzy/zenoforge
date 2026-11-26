#!/usr/bin/env bash
# Factory batch units (stage dispatch for recut/triage/implement, advisor and triage batches, gitnexus refresh, web advisor jobs)
# start in ZF_BATCH_SLICE (zf-batch.slice). Deploy units (release batch, hf-release, hf-merge, release train) start in
# ZF_RELEASE_SLICE (zf-release.slice) and never set MemoryHigh, so a deploy is not reclaim-throttled.
# Both slices nest under zf.slice by the dash and stay outside zf-workers.slice, where the worker MemoryHigh throttle applies.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { printf 'batch-units-slice.test.sh: %s\n' "$*" >&2; exit 1; }

BATCH_SLICE='--slice="${ZF_BATCH_SLICE:-zf-batch.slice}"'
RELEASE_SLICE='--slice="${ZF_RELEASE_SLICE:-zf-release.slice}"'

# The systemd-run call that starts at the line matching $2 in $1: that line and the 12 after it, where its options and command sit.
call() { grep -F -A12 -- "$2" "$engine/$1" || true; }

# batch_site FILE UNIT-PATTERN LABEL: the call carries the batch slice.
batch_site() {
  local block; block="$(call "$1" "$2")"
  [[ -n "$block" ]] || fail "$3: no systemd-run call matches $2"
  grep -Fq -- "$BATCH_SLICE" <<< "$block" || fail "$3: its systemd-run call lacks $BATCH_SLICE"
  printf 'PASS %s: %s\n' "$3" "$BATCH_SLICE"
}

# release_site FILE UNIT-PATTERN LABEL: the call carries the release slice and no MemoryHigh.
release_site() {
  local block; block="$(call "$1" "$2")"
  [[ -n "$block" ]] || fail "$3: no systemd-run call matches $2"
  grep -Fq -- "$RELEASE_SLICE" <<< "$block" || fail "$3: its systemd-run call lacks $RELEASE_SLICE"
  if grep -q 'MemoryHigh' <<< "$block"; then fail "$3: a release call must not set MemoryHigh"; fi
  printf 'PASS %s: %s, no MemoryHigh\n' "$3" "$RELEASE_SLICE"
}

# --- batch units ---
batch_site issue-pipeline.sh '--unit "${UNIT_PREFIX_TRANSIENT}-$stage-$n" --collect' 'issue-pipeline stage dispatch (implement, triage, recut)'
batch_site issue-pipeline.sh '--unit ${UNIT_PREFIX_TRANSIENT}-advisor-batch --collect' 'issue-pipeline advisor-batch'
batch_site issue-pipeline.sh '--unit "$claim_unit" --collect' 'issue-pipeline triage-batch'
batch_site issue-pipeline.sh '--unit ${UNIT_PREFIX_TRANSIENT}-gitnexus-refresh --collect' 'issue-pipeline gitnexus-refresh'
batch_site web-advisor-provider-job.sh '--unit "$prefix-advisor-batch" --collect' 'web-advisor-provider-job advisor-batch'
batch_site providers/web-advisor-provider.sh '--unit "${ZF_WEB_ADVISOR_PROVIDER_UNIT_PREFIX}-web-advisor-provider-$job_id" --collect' 'web-advisor-provider job'

# --- release units ---
release_site issue-pipeline.sh '--unit ${UNIT_PREFIX_TRANSIENT}-release-batch --collect' 'issue-pipeline release-batch'
release_site hotfix/hf-release.sh '--unit ${UNIT_PREFIX_TRANSIENT}-release-batch --collect' 'hf-release release-batch'
release_site hotfix/hf-merge.sh '--unit "${UNIT_PREFIX_TRANSIENT}-hf-release-$pr" --collect' 'hf-merge hf-release'
release_site mac-autopilot/scheduler.d/health-release.sh '--unit ${UNIT_PREFIX_TRANSIENT}-release-train --collect' 'release-train'

printf 'PASS every batch and release systemd-run site names its slice; no release site sets MemoryHigh\n'
