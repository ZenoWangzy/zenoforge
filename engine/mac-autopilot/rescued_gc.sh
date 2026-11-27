#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.d/transport.sh"
repo="${1:?repo}" log="$(realpath -m -- "${2:?log file}")"
max_age_days="${RESCUED_MAX_AGE_DAYS:-14}"
pr_age_days="${BRANCH_GC_PR_AGE_DAYS:-7}"
now="${NOW_EPOCH:-$(date +%s)}"
stamp="$(date -u -d "@$now" +%Y%m%dT%H%M%SZ)"
alert_file="$(dirname -- "$log")/alerts/branch-gc.md"
archive_prefix=refs/vecta-rescue/archived
cd -- "$repo"

alert() {
  mkdir -p -- "$(dirname -- "$alert_file")"
  printf '[%s] BRANCH-GC-FAILED %s\n' "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$alert_file"
  echo "rescued_gc: $*" >&2
}
die() { alert "$*"; exit 1; }

git fetch -q --prune origin '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null || die "fetch of origin heads failed"
meta="$(gh repo view --json nameWithOwner,defaultBranchRef --jq '[.nameWithOwner, .defaultBranchRef.name] | @tsv' 2>/dev/null)" || die "repository lookup failed"
IFS=$'\t' read -r owner_repo default_branch <<< "$meta"
[[ -n "$owner_repo" && -n "$default_branch" ]] || die "repository lookup returned no default branch"

if [[ -n "${BRANCH_GC_AUTHOR_EMAILS:-}" ]]; then
  own=" ${BRANCH_GC_AUTHOR_EMAILS,,} "
else
  who="$(gh api user --jq '"\(.id) \(.login)"' 2>/dev/null)" || die "automation account lookup failed"
  read -r uid login <<< "$who"
  [[ -n "$uid" && -n "$login" ]] || die "automation account lookup returned nothing"
  own=" $uid+${login,,}@users.noreply.github.com ${login,,}@users.noreply.github.com "
fi

prs="$(gh pr list --state all --limit 20000 --json headRefName,headRefOid,baseRefName,state,closedAt,isCrossRepository 2>/dev/null)" || die "pull request lookup failed"
rows="$(jq -r '.[] | if .state == "OPEN" then ["open", .headRefName, .baseRefName, 0]
  elif .isCrossRepository then empty
  else ["closed", .headRefName, .headRefOid, ((.closedAt // "1970-01-01T00:00:00Z") | fromdateiso8601)] end | @tsv' <<< "$prs")" || die "pull request data unreadable"
declare -A open_ref=() pr_closed=()
while IFS=$'\t' read -r kind head extra at; do
  if [[ "$kind" == open ]]; then
    open_ref["$head"]=1 open_ref["$extra"]=1
  elif [[ "$kind" == closed ]] && (( at > ${pr_closed["$head $extra"]:-0} )); then
    pr_closed["$head $extra"]="$at"
  fi
done <<< "$rows"
open_ref["$default_branch"]=1

declare -A tip=() when_of=() num_of=() reason_of=()
foreign=0
while read -r b when sha email; do
  [[ "$b" == HEAD || -n "${open_ref["$b"]:-}" ]] && continue
  email="${email#<}"; email="${email%>}"
  [[ "$own" == *" ${email,,} "* ]] || { foreign=$((foreign + 1)); continue; }
  tip["$b"]="$sha" when_of["$b"]="$when"
  [[ "$b" =~ (issue-|hand-)([0-9]+) ]] && num_of["$b"]="${BASH_REMATCH[2]}"
done < <(git for-each-ref --format='%(refname:lstrip=3) %(committerdate:unix) %(objectname) %(authoremail)' refs/remotes/origin/)

(( ${#tip[@]} )) || { echo "rescued_gc: no authored heads"; exit 0; }
is_family() { [[ "$1" == rescued/* || "$1" == backup/* || "$1" == salvage/* || "$1" == train/* ]]; }
pr_aged() { local key="$1 ${tip[$1]}" at; at="${pr_closed[$key]:-}"; [[ -n "$at" ]] && (( now - at > pr_age_days * 86400 )); }

declare -A closed=()
problems=0
mapfile -t nums < <(for b in "${!tip[@]}"; do
  if [[ -n "${num_of["$b"]:-}" ]] && { is_family "$b" || pr_aged "$b"; }; then echo "${num_of["$b"]}"; fi
done | sort -un)
for ((i = 0; i < ${#nums[@]}; i += 100)); do
  q="query { repository(owner: \"${owner_repo%/*}\", name: \"${owner_repo#*/}\") {"
  for n in "${nums[@]:i:100}"; do q+=" i$n: issueOrPullRequest(number: $n) { ... on Issue { state } ... on PullRequest { state } }"; done
  q+=" } }"
  out="$(gh api graphql -f query="$q" 2>/dev/null || :)"
  if jq -e '.data.repository != null and ([.errors[]? | select(.type != "NOT_FOUND")] | length == 0)' > /dev/null 2>&1 <<< "$out"; then
    while read -r k; do [[ -n "$k" ]] && closed["${k#i}"]=1; done < <(jq -r '.data.repository | to_entries[] | select(.value.state == "CLOSED" or .value.state == "MERGED") | .key' <<< "$out")
  else
    alert "issue state lookup failed for one batch of up to 100 numbers, its branches were kept"; problems=1
  fi
done

mapfile -t sorted < <(printf '%s\n' "${!tip[@]}" | sort)
for b in "${sorted[@]}"; do
  n="${num_of["$b"]:-}"
  if is_family "$b"; then
    if [[ -n "$n" && -z "${closed["$n"]:-}" ]]; then continue
    elif [[ "$b" == rescued/* && -n "$n" ]]; then reason_of["$b"]="closed-issue-$n"
    elif (( now - when_of["$b"] > max_age_days * 86400 )); then reason_of["$b"]="${b%%/*}-older-${max_age_days}d"
    fi
  elif pr_aged "$b" && { [[ -z "$n" ]] || [[ -n "${closed["$n"]:-}" ]]; }; then
    reason_of["$b"]="pr-closed-older-${pr_age_days}d"
  fi
done
victims=(); for b in "${sorted[@]}"; do [[ -n "${reason_of["$b"]:-}" ]] && victims+=("$b"); done
echo "rescued_gc: ${#victims[@]} of ${#tip[@]} authored heads are due for collection, $foreign skipped for another author"

deleted=0 failed=()
declare -A archived=() remaining=()
for ((i = 0; i < ${#victims[@]}; i += 50)); do
  batch=("${victims[@]:i:50}") specs=() refs=() ok=() leases=()
  for b in "${batch[@]}"; do
    ref="$archive_prefix/$b-${tip["$b"]:0:12}"; refs+=("$ref"); specs+=("+${tip["$b"]}:$ref")
  done
  git push -q origin "${specs[@]}" 2>/dev/null || :
  archived=()
  if rows="$(git ls-remote origin "${refs[@]}" 2>/dev/null)"; then
    while read -r sha ref; do [[ -n "$ref" ]] && archived["$ref"]="$sha"; done <<< "$rows"
  fi
  for ((j = 0; j < ${#batch[@]}; j++)); do
    b="${batch[j]}"
    if [[ "${archived["${refs[j]}"]:-}" == "${tip["$b"]}" ]]; then ok+=("$b"); leases+=("--force-with-lease=refs/heads/$b:${tip["$b"]}")
    else failed+=("$b"); fi
  done
  (( ${#ok[@]} )) || continue
  git push -q origin --delete "${leases[@]}" "${ok[@]}" 2>/dev/null || :
  remaining=()
  if rows="$(git ls-remote --heads origin "${ok[@]/#/refs/heads/}" 2>/dev/null)"; then
    while read -r sha ref; do [[ -n "$ref" ]] && remaining["$ref"]=1; done <<< "$rows"
  else
    for b in "${ok[@]}"; do remaining["refs/heads/$b"]=1; done
  fi
  for b in "${ok[@]}"; do
    if [[ -n "${remaining["refs/heads/$b"]:-}" ]]; then failed+=("$b"); continue; fi
    printf '%s deleted %s %s reason=%s archive=%s\n' "$stamp" "$b" "${tip["$b"]}" "${reason_of["$b"]}" "$archive_prefix/$b-${tip["$b"]:0:12}" >> "$log"
    deleted=$((deleted + 1))
  done
done
echo "rescued_gc: deleted $deleted of ${#victims[@]} candidate branches (archived under $archive_prefix/)"
(( ${#failed[@]} == 0 )) || { alert "archive or delete failed for ${#failed[@]} of ${#victims[@]} branches, kept: ${failed[*]:0:5}"; problems=1; }
exit "$problems"
