#!/usr/bin/env bash
# Takes out the commit that turned <workflow> red on <branch>, so main passes its tests again; the fix comes afterwards.
# Engine changes land on main without waiting for CI, so this acts after the fact: no merge queue. Run it in a clone of the repo.
# Stop: touch "${ZF_MAIN_RED_REVERT_HOME:-$HOME/.zenoforge}/main-red-revert.stop".
set -euo pipefail

home=${ZF_MAIN_RED_REVERT_HOME:-$HOME/.zenoforge}
[[ -e $home/main-red-revert.stop ]] && { echo "main-red-revert: stop file present, nothing done"; exit 0; }
state=$home/main-red-revert.last
alerts=${ZF_ALERTS_FILE:-${AGENT_HOME:-$HOME/.vecta-agent}/logs/head-watch.alerts}
dry=0 repo='' workflow=engine-tests branch=main
while (($#)); do
  case $1 in
    --dry-run) dry=1; shift ;;
    --repo) repo=$2; shift 2 ;;
    --workflow) workflow=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    *) echo "usage: main-red-revert.sh [--dry-run] [--repo <owner/name>] [--workflow engine-tests] [--branch main]" >&2; exit 2 ;;
  esac
done
# Default repo comes from the clone's origin, so no repository name is written in the script.
repo=${repo:-$(git remote get-url origin | sed -E 's#^(https?://[^/]+/|[^@]+@[^:]+:)##; s#\.git$##')}

alert() { # <NAME> <details>: echoed always, appended to the alerts file unless dry run
  echo "$1 $repo $branch $2"
  ((dry)) && return 0
  mkdir -p "$(dirname -- "$alerts")"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1 $repo $branch $2" >>"$alerts"
}
decided() { ((dry)) || { mkdir -p "$home"; echo "$head" >"$state"; }; } # one decision per red head: a rerun on the same head does nothing

git fetch -q --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
head=$(git rev-parse "origin/$branch")
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
subject=$(git log -1 --format=%s "$culprit")
later=$(git log --format='%s%n%b' "$culprit..$head")
if [[ $subject == Revert* ]]; then
  alert MAIN-RED-NO-CULPRIT "culprit ${culprit:0:7} is a revert: $subject"; decided; exit 0
fi
if grep -Fq -e "Revert \"$subject\"" -e "$culprit" <<<"$later"; then
  alert MAIN-RED-NO-CULPRIT "culprit ${culprit:0:7} is already reverted on $branch"; decided; exit 0
fi
if ((dry)); then echo "WOULD-REVERT $culprit $subject"; exit 0; fi

wt=$(mktemp -d "${TMPDIR:-/tmp}/main-red-revert.XXXXXX")/wt
trap 'git worktree remove --force "$wt" 2>/dev/null || true; rm -rf -- "$(dirname -- "$wt")"' EXIT
git worktree add -q --detach "$wt" "origin/$branch"
mflag=
if (($(git rev-list --parents -n 1 "$culprit" | wc -w) > 2)); then mflag=1; fi # merge commit: revert against its first parent
if ! git -C "$wt" revert --no-commit ${mflag:+-m 1} "$culprit" >/dev/null 2>&1; then
  git -C "$wt" revert --abort >/dev/null 2>&1 || true
  alert MAIN-RED-REVERT-CONFLICT "revert of ${culprit:0:7} ($subject) conflicts with later commits; a human decides"
  decided; exit 0
fi
printf 'Revert "%s"\n\nAutomatic revert: %s on %s failed at %s (run %s); last green %s.\nRe-land with a fix.\n' \
  "$subject" "$workflow" "$branch" "${culprit:0:7}" "$id" "${good:0:7}" | git -C "$wt" commit -q -F -
if ! git -C "$wt" push -q origin "HEAD:$branch"; then # no force: a moved main is decided by the next run
  alert MAIN-RED-REVERT-CONFLICT "push of the revert of ${culprit:0:7} was rejected, main moved"; exit 0
fi
alert MAIN-CI-AUTO-REVERT "culprit ${culprit:0:7} $subject run $id; reverted as $(git -C "$wt" rev-parse --short HEAD)"
decided
