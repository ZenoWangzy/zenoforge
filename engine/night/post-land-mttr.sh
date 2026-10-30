#!/usr/bin/env bash

# Post-land breakage MTTR for the six-hour maintainer digest: for every culprit
# commit named by a later fix commit, measure culprit landing -> first red
# run whose tested head contains the culprit (CI on main = Postsubmit, or
# Pipeline suites) -> the first fix naming that culprit after the red was
# seen. Sourced by founder-health-mail.sh; the `summary` CLI is the same
# computation for reports and incident accounting.

# Every number has a standard (node_health.py pattern): healthy bound,
# unhealthy bound, between the two is DEGRADED. Calibrated 2026-10-30 on the
# 2026-10-29 opt landings (totals 59.7/52.2/73.6 min; a Pipeline suites or
# Postsubmit run takes ~30 min to report red, a fix-forward lands ~30 min
# after the red is seen):
#   detect  healthy 45 min (one verification run plus dispatch slack),
#           unhealthy 90 min
#   fix     healthy 60 min (diagnosis plus one landing), unhealthy 120 min
#   total   healthy 90 min (one detect cycle plus one fix cycle),
#           unhealthy 180 min
post_land_mttr_standard() {
  jq -cn '{detect_healthy_seconds:2700,detect_unhealthy_seconds:5400,
    fix_healthy_seconds:3600,fix_unhealthy_seconds:7200,
    total_healthy_seconds:5400,total_unhealthy_seconds:10800,
    meaning:"发现不超过45分钟、修复不超过60分钟、总恢复不超过90分钟"}'
}

# Commit-time is the land time: direct-main landings push the worktree commit
# as-is, and land-queue finished_epoch runs at most a minute behind it
# (2026-10-29 samples: 11-46 s). Commit time also covers PR landings, which
# the land-queue never sees.
post_land_mttr_commits() {
  local repo="$1" scan_start_iso="$2"
  git -C "$repo" log origin/main --since="$scan_start_iso" \
    --format='%H%x1f%ct%x1f%B%x1e' 2>/dev/null |
    jq -Rs 'split("\u001e") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "") | select(length > 0))
      | map(split("\u001f") | {sha:.[0], at:(.[1]|tonumber), msg:.[2]})'
}

# The culprit link is the fix commit's own message, no separate storage:
# a `Fix-Forward-Of: <sha>` trailer (preferred, documented in
# docs/agents/issue-pipeline.md) or — the convention the 2026-10-29 fixes
# already used — the culprit SHA named anywhere in the body. A candidate only
# counts when it resolves to an ancestor of the fix on main.
post_land_mttr_culprit_of() {
  local repo="$1" fix_sha="$2" msg="$3" candidate
  candidate="$(jq -Rsr '
    ([scan("Fix-Forward-Of:[[:space:]]*([0-9a-f]{7,40})"; "i")] | map(.[0]) | .[0] // null) as $trailer
    | if $trailer != null then $trailer else ([scan("[0-9a-f]{7,40}")] | .[0] // "") end
  ' <<< "$msg" 2>/dev/null)" || return 1
  [ -n "$candidate" ] || return 1
  git -C "$repo" cat-file -e "$candidate^{commit}" 2>/dev/null || return 1
  [ "$candidate" = "$fix_sha" ] && return 1
  git -C "$repo" merge-base --is-ancestor "$candidate" "$fix_sha" 2>/dev/null || return 1
  printf '%s\n' "$(git -C "$repo" rev-parse --verify "$candidate^{commit}")"
}

# Fix candidates that landed in the digest window (since, until]. A later
# commit may reference a culprit several times (the real fix, then hardening);
# pairing with the red happens later, so keep every candidate.
post_land_mttr_fix_candidates() {
  local repo="$1" commits="$2" since="$3" until="$4" row sha at msg culprit culprit_at
  local -a candidates=()
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    sha="$(jq -r '.sha' <<< "$row")"
    at="$(jq -r '.at' <<< "$row")"
    msg="$(jq -r '.msg' <<< "$row")"
    (( at > since && at <= until )) || continue
    culprit="$(post_land_mttr_culprit_of "$repo" "$sha" "$msg")" || continue
    culprit_at="$(git -C "$repo" show -s --format=%ct "$culprit" 2>/dev/null)" || continue
    [[ "$culprit_at" =~ ^[0-9]+$ ]] || continue
    (( culprit_at < at )) || continue
    candidates+=("$(jq -cn --arg culprit "$culprit" --argjson landed_at "$culprit_at" \
      --arg fix "$sha" --argjson fixed_at "$at" \
      '{culprit:$culprit,landed_at:$landed_at,fix:$fix,fixed_at:$fixed_at}')")
  done < <(jq -c '.[]' <<< "$commits")
  if (( ${#candidates[@]} )); then
    printf '%s\n' "${candidates[@]}" | jq -s 'sort_by(.fixed_at)'
  else
    printf '[]\n'
  fi
}

# Completed main-branch runs of the two post-land verification channels. One
# gh call per digest; bisect train refs are excluded by branch=main.
post_land_mttr_red_runs() {
  local created_since_iso="$1" runs
  runs="$(timeout 30 gh api \
    "repos/${REPO:-${ZF_REPO:?ZF_REPO is not set}}/actions/runs?branch=main&status=completed&per_page=100&page=1&created=%3E%3D${created_since_iso}" \
    2>/dev/null)" || return 1
  jq -c '[.workflow_runs[]?
    | select((.name == "CI" or .name == "Pipeline suites")
      and (.event == "push" or .event == "workflow_dispatch")
      and (.conclusion != "success" and .conclusion != "cancelled"
        and .conclusion != "skipped" and .conclusion != "neutral"))
    | {id, name, head_sha, ended_at:.updated_at}]
    | sort_by(.ended_at)' <<< "$runs" 2>/dev/null
}

# Detection = the first red run that ENDED after the culprit landed AND whose
# tested head actually contains the culprit. Time order alone would credit a
# red that started before the landing and never saw the culprit's change
# (2026-10-29: CI push 40953413965 ended 111 s after 5669222f5 landed, on a
# head that predates it, red from an earlier breakage).
post_land_mttr_detects() {
  local repo="$1" candidates="$2" red_runs="$3" culprit landed row run head ended
  local -A ancestry=() seen_culprits=() detected=()
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    culprit="$(jq -r '.culprit' <<< "$row")"
    [ -n "${seen_culprits[$culprit]:-}" ] && continue
    seen_culprits[$culprit]=1
    landed="$(jq -r '.landed_at' <<< "$row")"
    while IFS= read -r run; do
      [ -n "$run" ] || continue
      ended="$(jq -r '.ended_at | try fromdateiso8601 catch 0' <<< "$run")"
      (( ended > landed )) || continue
      head="$(jq -r '.head_sha' <<< "$run")"
      if [ -z "${ancestry[$culprit $head]:-}" ]; then
        if git -C "$repo" merge-base --is-ancestor "$culprit" "$head" 2>/dev/null; then
          ancestry["$culprit $head"]=1
        else
          ancestry["$culprit $head"]=0
        fi
      fi
      (( ancestry["$culprit $head"] )) || continue
      detected[$culprit]="$(jq -cn --arg culprit "$culprit" --argjson landed_at "$landed" \
        --argjson detected_at "$ended" --argjson detected_by "$(jq -r '.id' <<< "$run")" \
        '{culprit:$culprit,landed_at:$landed_at,detected_at:$detected_at,detected_by:$detected_by}')"
      break
    done < <(jq -c '.[]' <<< "$red_runs")
  done < <(jq -c 'unique_by(.culprit)[]' <<< "$candidates")
  if (( ${#detected[@]} )); then
    printf '%s\n' "${detected[@]}" | jq -s 'sort_by(.detected_at)'
  else
    printf '[]\n'
  fi
}

# Pairing: the fix is the FIRST candidate naming the culprit that landed after
# the red was seen. A fix that landed before any red observed the culprit
# repaired something else that culprit broke (2026-10-29: 42bf6d5ee fixed the
# hf-merge stub 5669222f5 broke, 33 min before Postsubmit saw the job-contract
# red that a9c10d350 then fixed).
post_land_mttr_summary() {
  local repo="$1" since="$2" until="$3" commits candidates red_runs detects scan_start_iso created_since_iso
  [[ "$since" =~ ^[0-9]+$ && "$until" =~ ^[0-9]+$ && "$until" -gt "$since" ]] || return 1
  scan_start_iso="$(date -u -d "@$((since - 7200))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  commits="$(post_land_mttr_commits "$repo" "$scan_start_iso")" || return 1
  candidates="$(post_land_mttr_fix_candidates "$repo" "$commits" "$since" "$until")" || return 1
  red_runs=null
  if [ "$(jq -r 'length' <<< "$candidates")" -gt 0 ]; then
    created_since_iso="$(date -u -d "@$(( $(jq -r '[.[].landed_at] | min' <<< "$candidates") - 7200 ))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
    red_runs="$(post_land_mttr_red_runs "$created_since_iso")" || red_runs=null
  fi
  if [ "$red_runs" = null ]; then
    detects=null
  else
    detects="$(post_land_mttr_detects "$repo" "$candidates" "$red_runs")" || return 1
  fi
  jq -cn --argjson candidates "$candidates" --argjson red_runs "$red_runs" \
    --argjson detects "$detects" --argjson standard "$(post_land_mttr_standard)" \
    --argjson window "{\"from\":$since,\"to\":$until}" '
    def paired($d):
      [$candidates[] | select(.culprit == $d.culprit and .fixed_at > $d.detected_at)]
      | sort_by(.fixed_at) | .[0] // null;
    (if $detects == null then
        # gh could not answer: keep the earliest fix per culprit with an
        # unknown detection time rather than dropping the breakage silently.
        [$candidates | sort_by(.fixed_at) | unique_by(.culprit)[]
          | {culprit, landed_at, detected_at:null, detected_by:null, fix, fixed_at}]
      else
        [$detects[] | . as $d | paired($d) as $fix
          | select($fix != null)
          | {culprit:$d.culprit, landed_at:$d.landed_at, detected_at:$d.detected_at,
             detected_by:$d.detected_by, fix:$fix.fix, fixed_at:$fix.fixed_at}]
      end)
    | [.[] | . + {detect_seconds:(if .detected_at == null then null else .detected_at - .landed_at end),
        fix_seconds:(if .detected_at == null then null else .fixed_at - .detected_at end),
        total_seconds:(.fixed_at - .landed_at)}]
    | . as $events
    | def median($values):
        ($values | map(select(type == "number")) | sort) as $sorted
        | if ($sorted | length) == 0 then null
          else (($sorted | length) as $n
            | (if ($n % 2) == 1 then $sorted[($n / 2 | floor)]
               else ($sorted[($n / 2 | floor) - 1] + $sorted[$n / 2 | floor]) / 2 end)) end;
    {window:$window, runs_error:($red_runs == null), events:$events,
     summary:{count:($events | length),
       detect_median_seconds:median([$events[].detect_seconds]),
       fix_median_seconds:median([$events[].fix_seconds]),
       total_median_seconds:median([$events[].total_seconds]),
       total_max_seconds:([$events[].total_seconds] | max // null),
       over_standard:([$events[] | select(.total_seconds > $standard.total_healthy_seconds)] | length)},
     bounds:$standard}'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  repo='' since='' until="$(date +%s)"
  [ "${1:-}" = summary ] && shift
  while (( $# )); do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --since) since="$2"; shift 2 ;;
      --until) until="$2"; shift 2 ;;
      *) printf 'usage: %s summary --repo REPO --since EPOCH [--until EPOCH]\n' "$0" >&2; exit 2 ;;
    esac
  done
  [[ "$repo" != '' && "$since" =~ ^[0-9]+$ && "$until" =~ ^[0-9]+$ ]] || {
    printf 'usage: %s summary --repo REPO --since EPOCH [--until EPOCH]\n' "$0" >&2
    exit 2
  }
  post_land_mttr_summary "$repo" "$since" "$until"
fi
