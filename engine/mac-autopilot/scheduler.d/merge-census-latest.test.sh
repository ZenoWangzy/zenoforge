#!/usr/bin/env bash
# The merge lane's census keeps only the newest run per check name, so a newer SUCCESS hides an older
# CANCELLED, a newer FAILURE is never hidden by an older SUCCESS, and a lane skip needs a truly pending row.
# 2026-11-08 PR#5846: "merge skipped (checks pending or unavailable)" at 10:02Z and 10:10Z was real pending
# (Required CI gates ran until 10:18Z), not duplicate-run noise; this pins the duplicate-run cases.
# The list call no longer carries statusCheckRollup: rows come per head SHA from the check-runs endpoint
# (tick-census.sh), so these cases drive that path with REST-shaped check_runs rows.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
d=$(cd "$(dirname "$0")" && pwd)
source "$d/tick-census.sh"
HERE=$(cd "$d/.." && pwd); jqf() { jq "$@"; }; SHA_RE='^[0-9a-f]{40}$'
GH_CHECK_RUNS='{check_runs: []}'
gh() {
  case "${1:-} ${2:-}" in
    'api repos/{owner}/{repo}/commits/'*'/check-runs?per_page=100') jq -c '.check_runs // []' <<<"$GH_CHECK_RUNS" ;;
    *) echo "unexpected gh call: $*" >&2; return 1 ;;
  esac
}
# The lane's own skip test, verbatim from merge-lane.sh.
lane_skips() { ! jq -e 'length > 0 and all(.[]; .bucket != "pending")' <<<"$1" >/dev/null; }
run() { # name status conclusion started run_id (REST check-run shape; conclusion "" on an unfinished run)
  jq -nc --arg n "$1" --arg s "$2" --arg c "$3" --arg t "$4" --arg r "$5" \
    '{name:$n, status:$s, conclusion:(if $c == "" then null else $c end), started_at:$t, details_url:("https://github.com/o/r/actions/runs/" + $r + "/job/1")}'
}
census() { # rows... → normalized checks array of PR 7 (light census row + per-head check-runs fetch)
  GH_CHECK_RUNS="$(printf '%s\n' "$@" | jq -sc '{check_runs: .}')"
  jq -cn '{number:7, headRefOid:"abcdefabcdefabcdefabcdefabcdefabcdefabcd", isDraft:false, mergeable:"MERGEABLE"}' \
    | pr_census_by_number | pr_census_checks_fill | jq -c '{checks: (.["7"].checks | map({name, bucket})), ci: .["7"].ci}'
}
fail() { echo "FAIL: $1: $2"; exit 1; }

# PR#5846 shape: older CANCELLED + SKIPPED copies, newer SUCCESS, listed in GitHub's mixed order.
c=$(census \
  "$(run 'Required CI gates' completed cancelled 2026-11-08T09:57:16Z 100)" \
  "$(run 'Required CI gates' completed skipped 2026-11-08T09:57:04Z 99)" \
  "$(run 'Required CI gates' completed success 2026-11-08T10:18:14Z 101)" \
  "$(run 'NUL bytes' completed success 2026-11-08T09:57:47Z 101)" \
  "$(run 'NUL bytes' completed cancelled 2026-11-08T09:57:05Z 100)")
[[ "$c" == '{"checks":[{"name":"Required CI gates","bucket":"pass"},{"name":"NUL bytes","bucket":"pass"}],"ci":0}' ]] || fail "older CANCELLED, newer SUCCESS" "$c"
! lane_skips "$c" || fail "older CANCELLED, newer SUCCESS" "lane skips"

# Reverse: older SUCCESS, newer FAILURE must stay visible as fail.
c=$(census "$(run 'Required CI gates' completed success 2026-11-08T09:57:16Z 100)" "$(run 'Required CI gates' completed failure 2026-11-08T10:18:14Z 101)")
[[ "$c" == '{"checks":[{"name":"Required CI gates","bucket":"fail"}],"ci":1}' ]] || fail "older SUCCESS, newer FAILURE" "$c"

# Newest run still running: pending, so the lane waits (the 10:02Z/10:10Z case); pending is not green.
c=$(census "$(run 'Required CI gates' completed success 2026-11-08T09:57:16Z 100)" "$(run 'Required CI gates' in_progress '' 2026-11-08T10:01:00Z 101)")
[[ "$c" == '{"checks":[{"name":"Required CI gates","bucket":"pending"}],"ci":2}' ]] || fail "newest run in progress" "$c"
lane_skips "$c" || fail "newest run in progress" "lane must skip"

# PR#5848 shape: SKIPPED and CANCELLED copies first, then a newer FAILURE on two gates. The lane must see
# fail (its `fails` list is non-empty, so it takes the red/repair path), not pending.
c=$(census \
  "$(run 'Touched packages PR gate' completed skipped 2026-11-08T09:59:10Z 200)" \
  "$(run 'Touched packages PR gate' completed cancelled 2026-11-08T09:59:20Z 201)" \
  "$(run 'Touched packages PR gate' completed skipped 2026-11-08T09:59:30Z 203)" \
  "$(run 'Touched packages PR gate' completed failure 2026-11-08T10:01:00Z 202)" \
  "$(run 'Required CI gates' completed skipped 2026-11-08T09:59:10Z 200)" \
  "$(run 'Required CI gates' completed cancelled 2026-11-08T09:59:20Z 201)" \
  "$(run 'Required CI gates' completed failure 2026-11-08T10:20:00Z 202)" \
  "$(run 'contract' completed success 2026-11-08T10:00:00Z 202)")
[[ "$c" == '{"checks":[{"name":"Touched packages PR gate","bucket":"fail"},{"name":"Required CI gates","bucket":"fail"},{"name":"contract","bucket":"pass"}],"ci":1}' ]] || fail "5848 shape" "$c"
! lane_skips "$c" || fail "5848 shape" "lane skips a real red"
[[ "$(jq -r '[.checks[] | select(.bucket == "fail") | .name] | sort | join(",")' <<<"$c")" == "Required CI gates,Touched packages PR gate" ]] || fail "5848 shape" "fails list"

# A name whose only rows are SKIPPED drops out and does not block.
c=$(census "$(run 'Postsubmit validate' completed skipped 2026-11-08T09:57:05Z 100)" "$(run 'contract' completed success 2026-11-08T09:57:18Z 101)")
[[ "$c" == '{"checks":[{"name":"contract","bucket":"pass"}],"ci":0}' ]] || fail "skipped-only name" "$c"

# An unreadable check-runs read is checks null (never green): the lane skips the candidate as census-unavailable,
# and a row-less success (empty array) is pending, not green.
GH_CHECK_RUNS='not-json'
c="$(jq -cn '{number:7, headRefOid:"abcdefabcdefabcdefabcdefabcdefabcdefabcd", isDraft:false, mergeable:"MERGEABLE"}' | pr_census_by_number | pr_census_checks_fill)"
[[ "$(jq -r '.["7"].checks' <<<"$c")" == null && "$(jq -r '.["7"].ci' <<<"$c")" == null ]] || fail "unreadable check-runs" "$c"
GH_CHECK_RUNS='{check_runs: []}'
c="$(jq -cn '{number:7, headRefOid:"abcdefabcdefabcdefabcdefabcdefabcdefabcd", isDraft:false, mergeable:"MERGEABLE"}' | pr_census_by_number | pr_census_checks_fill)"
[[ "$(jq -c '.["7"].checks' <<<"$c")" == '[]' && "$(jq -r '.["7"].ci' <<<"$c")" == 0 ]] || fail "row-less success" "$c"
lane_skips "$(jq -c '.["7"].checks' <<<"$c")" || fail "row-less success" "lane must skip"
echo ok
