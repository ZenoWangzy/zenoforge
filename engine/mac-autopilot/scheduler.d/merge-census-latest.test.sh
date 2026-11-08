#!/usr/bin/env bash
# The merge lane's census keeps only the newest run per check name, so a newer SUCCESS hides an older
# CANCELLED, a newer FAILURE is never hidden by an older SUCCESS, and a lane skip needs a truly pending row.
# 2026-11-08 PR#5846: "merge skipped (checks pending or unavailable)" at 10:02Z and 10:10Z was real pending
# (Required CI gates ran until 10:18Z), not duplicate-run noise; this pins the duplicate-run cases.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
d=$(cd "$(dirname "$0")" && pwd)
eval "$(sed -n '/^pr_census_by_number() {/,/^}/p' "$d/merge-lane.sh")"
HERE=$(cd "$d/.." && pwd); jqf() { jq "$@"; }
# The lane's own skip test, verbatim from merge-lane.sh.
lane_skips() { ! jq -e 'length > 0 and all(.[]; .bucket != "pending")' <<<"$1" >/dev/null; }
run() { # name status conclusion started run_id
  jq -nc --arg n "$1" --arg s "$2" --arg c "$3" --arg t "$4" --arg r "$5" \
    '{__typename:"CheckRun", name:$n, status:$s, conclusion:(if $c == "" then null else $c end), startedAt:$t, detailsUrl:("https://github.com/o/r/actions/runs/" + $r + "/job/1")}'
}
census() { # rows... → normalized checks array of PR 7
  printf '%s\n' "$@" | jq -sc '[{number:7, headRefOid:"abc", isDraft:false, mergeable:"MERGEABLE", statusCheckRollup:.}]' | pr_census_by_number | jq -c '.["7"].checks | map({name, bucket})'
}
fail() { echo "FAIL: $1: $2"; exit 1; }

# PR#5846 shape: older CANCELLED + SKIPPED copies, newer SUCCESS, listed in GitHub's mixed order.
c=$(census \
  "$(run 'Required CI gates' COMPLETED CANCELLED 2026-11-08T09:57:16Z 100)" \
  "$(run 'Required CI gates' COMPLETED SKIPPED 2026-11-08T09:57:04Z 99)" \
  "$(run 'Required CI gates' COMPLETED SUCCESS 2026-11-08T10:18:14Z 101)" \
  "$(run 'NUL bytes' COMPLETED SUCCESS 2026-11-08T09:57:47Z 101)" \
  "$(run 'NUL bytes' COMPLETED CANCELLED 2026-11-08T09:57:05Z 100)")
[[ "$c" == '[{"name":"Required CI gates","bucket":"pass"},{"name":"NUL bytes","bucket":"pass"}]' ]] || fail "older CANCELLED, newer SUCCESS" "$c"
! lane_skips "$c" || fail "older CANCELLED, newer SUCCESS" "lane skips"

# Reverse: older SUCCESS, newer FAILURE must stay visible as fail.
c=$(census "$(run 'Required CI gates' COMPLETED SUCCESS 2026-11-08T09:57:16Z 100)" "$(run 'Required CI gates' COMPLETED FAILURE 2026-11-08T10:18:14Z 101)")
[[ "$c" == '[{"name":"Required CI gates","bucket":"fail"}]' ]] || fail "older SUCCESS, newer FAILURE" "$c"

# Newest run still running: pending, so the lane waits (the 10:02Z/10:10Z case).
c=$(census "$(run 'Required CI gates' COMPLETED SUCCESS 2026-11-08T09:57:16Z 100)" "$(run 'Required CI gates' IN_PROGRESS '' 2026-11-08T10:01:00Z 101)")
[[ "$c" == '[{"name":"Required CI gates","bucket":"pending"}]' ]] || fail "newest run in progress" "$c"
lane_skips "$c" || fail "newest run in progress" "lane must skip"

# PR#5848 shape: SKIPPED and CANCELLED copies first, then a newer FAILURE on two gates. The lane must see
# fail (its `fails` list is non-empty, so it takes the red/repair path), not pending.
c=$(census \
  "$(run 'Touched packages PR gate' COMPLETED SKIPPED 2026-11-08T09:59:10Z 200)" \
  "$(run 'Touched packages PR gate' COMPLETED CANCELLED 2026-11-08T09:59:20Z 201)" \
  "$(run 'Touched packages PR gate' COMPLETED SKIPPED 2026-11-08T09:59:30Z 203)" \
  "$(run 'Touched packages PR gate' COMPLETED FAILURE 2026-11-08T10:01:00Z 202)" \
  "$(run 'Required CI gates' COMPLETED SKIPPED 2026-11-08T09:59:10Z 200)" \
  "$(run 'Required CI gates' COMPLETED CANCELLED 2026-11-08T09:59:20Z 201)" \
  "$(run 'Required CI gates' COMPLETED FAILURE 2026-11-08T10:20:00Z 202)" \
  "$(run 'contract' COMPLETED SUCCESS 2026-11-08T10:00:00Z 202)")
[[ "$c" == '[{"name":"Touched packages PR gate","bucket":"fail"},{"name":"Required CI gates","bucket":"fail"},{"name":"contract","bucket":"pass"}]' ]] || fail "5848 shape" "$c"
! lane_skips "$c" || fail "5848 shape" "lane skips a real red"
[[ "$(jq -r '[.[] | select(.bucket == "fail") | .name] | sort | join(",")' <<<"$c")" == "Required CI gates,Touched packages PR gate" ]] || fail "5848 shape" "fails list"

# A name whose only rows are SKIPPED drops out and does not block.
c=$(census "$(run 'Postsubmit validate' COMPLETED SKIPPED 2026-11-08T09:57:05Z 100)" "$(run 'contract' COMPLETED SUCCESS 2026-11-08T09:57:18Z 101)")
[[ "$c" == '[{"name":"contract","bucket":"pass"}]' ]] || fail "skipped-only name" "$c"
echo ok
