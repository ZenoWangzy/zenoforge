#!/usr/bin/env bash
# Takes out the commit that turned <workflow> red on <branch>, so main passes its tests again; the fix comes afterwards.
# Engine changes land on main without waiting for CI, so this acts after the fact: no merge queue. Run it in a clone of the repo.
# Stop: touch "${ZF_MAIN_RED_REVERT_HOME:-$HOME/.zenoforge}/main-red-revert.stop".
# Hold: a line "<sha-prefix> <who> <epoch-seconds>" in "${ZF_MAIN_RED_REVERT_HOME:-$HOME/.zenoforge}/main-red-revert.hold" makes it only alert for ZF_MAIN_RED_REVERT_HOLD_SECS (default 7200); malformed or expired lines are ignored.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../engine/lib.d/transport.sh"
export ZF_GH_NO_CACHE=1

home=${ZF_MAIN_RED_REVERT_HOME:-$HOME/.zenoforge}
[[ -e $home/main-red-revert.stop ]] && { echo "main-red-revert: stop file present, nothing done"; exit 0; }
state=$home/main-red-revert.last
alerts=${ZF_ALERTS_FILE:-${AGENT_HOME:-$HOME/.vecta-agent}/logs/head-watch.alerts}
dry=0 repo='' workflow=engine-tests branch=main pin_culprit='' reason='' pinned='' failed_head=''
while (($#)); do
  case $1 in
    --dry-run) dry=1; shift ;;
    --repo) repo=$2; shift 2 ;;
    --workflow) workflow=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --culprit) pin_culprit=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --last-pinned) pinned=$2; shift 2 ;;
    --failed-head) failed_head=$2; shift 2 ;;
    *) echo "usage: main-red-revert.sh [--dry-run] [--repo <owner/name>] [--workflow engine-tests] [--branch main]" >&2; exit 2 ;;
  esac
done
# Default repo comes from the clone's origin, so no repository name is written in the script.
repo=${repo:-$(git remote get-url origin | sed -E 's#^(https?://[^/]+/|[^@]+@[^:]+:)##; s#\.git$##')}

alert() { # <NAME> <details>: echoed always, appended to the alerts file unless dry run
  local name=$1 details=$2
  if [[ -n $pin_culprit ]]; then
    case $name in
      MAIN-RED-NO-CULPRIT) name=PIN-FAIL-NO-CULPRIT ;;
      MAIN-RED-FIX-IN-PROGRESS) name=PIN-FAIL-FIX-IN-PROGRESS ;;
      MAIN-RED-REVERT-CONFLICT) name=PIN-FAIL-REVERT-CONFLICT ;;
      MAIN-CI-AUTO-REVERT) name=PIN-FAIL-AUTO-REVERT ;;
    esac
    details="head=$failed_head pinned=$pinned $details"
  fi
  echo "$name $repo $branch $details"
  ((dry)) && return 0
  mkdir -p "$(dirname -- "$alerts")"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $name $repo $branch $details" >>"$alerts"
}
decided() {
  ((dry)) || { mkdir -p "$home"; if [[ -n $pin_culprit ]]; then echo "$culprit" >>"$state"; else echo "$head" >"$state"; fi; }
}

git fetch -q --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
head=$(git rev-parse "origin/$branch")
if [[ -n $pin_culprit ]]; then
  state=$home/pin-fail-revert.decided
  culprit=$(git rev-parse --verify -q "$pin_culprit^{commit}") || { alert MAIN-RED-NO-CULPRIT "culprit $pin_culprit is unavailable"; exit 0; }
  [[ -n $reason && $pinned =~ ^[0-9a-f]{40}$ && $failed_head =~ ^[0-9a-f]{40}$ ]] \
    && git merge-base --is-ancestor "$failed_head" "$head" \
    && git merge-base --is-ancestor "$culprit" "$failed_head" \
    || { alert MAIN-RED-NO-CULPRIT "culprit $culprit is not in the failed main history"; exit 0; }
  [[ ! -f $state ]] || ! grep -Fxq "$culprit" "$state" || { echo "already decided for ${culprit:0:7}"; exit 0; }
  good=$pinned
else
runs=$(gh run list -R "$repo" --branch "$branch" --workflow "$workflow" --limit 30 --json headSha,status,conclusion,databaseId,createdAt)
# Newest run on a commit: sets st, cc (conclusion) and id; st=none when the commit has no run.
read_run() {
  IFS='|' read -r st cc id <<<"$(jq -r --arg s "$1" '[.[] | select(.headSha == $s)] | sort_by(.createdAt) | last // empty | "\(.status)|\(.conclusion // "")|\(.databaseId)"' <<<"$runs")" || true
  [[ -n ${st:-} ]] || st=none
}

read_run "$head"
echo "HEAD ${head:0:7} run: $st${cc:+ $cc}"
[[ $st == completed && $cc == failure ]] || { echo "main is not red, nothing to do"; exit 0; }
[[ -f $state && $(cat "$state") == "$head" ]] && { echo "already decided for ${head:0:7}"; exit 0; }

mapfile -t hist < <(git rev-list --first-parent -n 31 "$head")
good=
for ((i = 1; i < ${#hist[@]}; i++)); do
  read_run "${hist[i]}"
  [[ $st == completed && $cc == success ]] && { good=${hist[i]}; break; }
done
if [[ -z $good ]]; then
  alert MAIN-RED-NO-CULPRIT "no green run in the 30 commits before ${head:0:7}"; decided; exit 0
fi

culprit=
mapfile -t cands < <(git rev-list --first-parent --reverse "$good..$head")
for c in "${cands[@]}"; do
  read_run "$c"
  if [[ $st == completed && $cc == success ]]; then good=$c; continue; fi
  if [[ $st == completed && $cc == failure ]]; then culprit=$c; break; fi
  if [[ $st != none && $st != completed ]]; then echo "waiting for the run of ${c:0:7} ($st)"; exit 0; fi # not decided: the next run decides
  alert MAIN-RED-NO-CULPRIT "commit ${c:0:7} has no completed run ($st${cc:+ $cc}) between green ${good:0:7} and red ${head:0:7}; candidates: $(printf '%.7s ' "${cands[@]}")"
  decided; exit 0
done
fi
subject=$(git log -1 --format=%s "$culprit")
later=$(git log --format='%s%n%b' "$culprit..$head")
if [[ $subject == Revert* ]]; then
  alert MAIN-RED-NO-CULPRIT "culprit ${culprit:0:7} is a revert: $subject"; decided; exit 0
fi
if grep -Fq -e "Revert \"$subject\"" -e "$culprit" <<<"$later"; then
  alert MAIN-RED-NO-CULPRIT "culprit ${culprit:0:7} is already reverted on $branch"; decided; exit 0
fi
# Someone is fixing the culprit: a fresh claim line in the hold file, or an open PR that names it.
hold_file=$home/main-red-revert.hold hold_secs=${ZF_MAIN_RED_REVERT_HOLD_SECS:-7200}
hold_shown=$hold_file; [[ $hold_shown == "$HOME"/* ]] && hold_shown="~${hold_shown#"$HOME"}"
claimhint="; to fix a commit yourself next time claim it first: echo \"${culprit:0:7} <you> \$(date +%s)\" >> $hold_shown"
holder=
if [[ -f $hold_file ]]; then
  while read -r csha cwho cepoch cextra || [[ -n $csha ]]; do
    [[ $csha =~ ^[0-9a-f]{7,}$ && $cepoch =~ ^[0-9]+$ && -n $cwho && -z $cextra ]] || continue
    if [[ $culprit == "$csha"* ]] && (($(date +%s) - cepoch < hold_secs)); then holder=$cwho; break; fi
  done <"$hold_file"
fi
if [[ -z $holder ]]; then
  if ! pr=$(gh pr list -R "$repo" --state open --search "${culprit:0:7}" --json number --jq '.[0].number // empty' 2>/dev/null); then
    if [[ -n $pin_culprit ]]; then
      alert MAIN-RED-NO-CULPRIT "could not check open PRs for culprit ${culprit:0:7}"
      decided; exit 0
    fi
    pr=
  fi
  if [[ -n $pr ]]; then holder="PR #$pr"; fi
fi
if [[ -n $holder ]]; then
  if ((dry)); then echo "WOULD-HOLD $culprit $holder"; exit 0; fi
  if [[ -n $pin_culprit ]]; then
    alert MAIN-RED-FIX-IN-PROGRESS "culprit ${culprit:0:7} $subject is being fixed by $holder; not reverted"
  else
    alert MAIN-RED-FIX-IN-PROGRESS "culprit ${culprit:0:7} $subject is being fixed by $holder; not reverted. If the fix does not land, remove the claim and the next red head is decided again"
  fi
  decided; exit 0
fi
if ((dry)); then echo "WOULD-REVERT $culprit $subject"; exit 0; fi

wt=$(mktemp -d "${TMPDIR:-/tmp}/main-red-revert.XXXXXX")/wt
trap 'git worktree remove --force "$wt" 2>/dev/null || true; rm -rf -- "$(dirname -- "$wt")"' EXIT
git worktree add -q --detach "$wt" "origin/$branch"
mflag=
if (($(git rev-list --parents -n 1 "$culprit" | wc -w) > 2)); then mflag=1; fi # merge commit: revert against its first parent
if ! git -C "$wt" revert --no-commit ${mflag:+-m 1} "$culprit" >/dev/null 2>&1; then
  git -C "$wt" revert --abort >/dev/null 2>&1 || true
  if [[ -n $pin_culprit ]]; then
    alert MAIN-RED-REVERT-CONFLICT "revert of ${culprit:0:7} ($subject) conflicts with later commits"
  else
    alert MAIN-RED-REVERT-CONFLICT "revert of ${culprit:0:7} ($subject) conflicts with later commits; a human decides$claimhint"
  fi
  decided; exit 0
fi
if [[ -n $pin_culprit ]]; then
printf 'Revert "%s"\n\nAutomatic revert: %s; last pinned %s; failed head %s.\n' \
  "$subject" "$reason" "$pinned" "$failed_head" | git -C "$wt" commit -q -F -
else
printf 'Revert "%s"\n\nAutomatic revert: %s on %s failed at %s (run %s); last green %s.\nRe-land with a fix.\n' \
  "$subject" "$workflow" "$branch" "${culprit:0:7}" "$id" "${good:0:7}" | git -C "$wt" commit -q -F -
fi
if ! git -C "$wt" push -q origin "HEAD:$branch"; then # no force: a moved main is decided by the next run
  alert MAIN-RED-REVERT-CONFLICT "push of the revert of ${culprit:0:7} was rejected, main moved"; [[ -z $pin_culprit ]] || decided; exit 0
fi
if [[ -n $pin_culprit ]]; then
  alert MAIN-CI-AUTO-REVERT "culprit $culprit $subject; reverted as $(git -C "$wt" rev-parse --short HEAD)"
else
  alert MAIN-CI-AUTO-REVERT "culprit ${culprit:0:7} $subject run $id; reverted as $(git -C "$wt" rev-parse --short HEAD)$claimhint"
fi
decided
