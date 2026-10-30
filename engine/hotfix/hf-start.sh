#!/usr/bin/env bash
set -euo pipefail
unset GH_TOKEN
[[ $# == 3 && $1 =~ ^[0-9]+$ && $2 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && -f $3 ]] || { echo 'usage: hf-start.sh <issue-number> <slug> <brief-file>' >&2; exit 2; }
issue=$1; slug=$2; brief=$3
root=${HF_ROOT:-${HOME:-/tmp}/.zenoforge/scratch/hotfix}
bin=${WORKER_BIN:-${HOME:-/tmp}/.zenoforge/scratch/bin}
mkdir -p "$root"
git fetch origin main
worktree="$root/wt-$issue-$slug"
git worktree add --lock -b "hotfix/$issue-$slug" "$worktree" origin/main
worker_brief="$root/hf-$issue-$slug-brief.md"
cat "$brief" > "$worker_brief"
cat >> "$worker_brief" <<'FOOTER'

Run engine/hotfix/prepush-gates.sh before pushing. Open the PR with engine/hotfix/hf-pr.sh. Do not merge or deploy.

Hotfix lane: PR → merge (hf-merge.sh, after the acceptance record passes) → engine/hotfix/hf-release.sh (landed b04717a90) rebuilds only the affected service image under its immutable merge-SHA tag and deploys that one service → real-user acceptance (验收用户 WebUI or 维护者 WeChat). Never fix production by editing files inside a container or docker cp; engine/hotfix/README.md documents the only remaining exception, for hotfixes that cannot ship as an image.

Done checklist (all must be checked before you report done): deployed SHA, acceptance result, issue closed, worktree cleaned, founder notified.
Theoretical lower bound: <e.g. CI 25 min + release 30 min>. Report ETA as a range, never a single time.
FOOTER
"$bin/lw" start "hf-$issue" env LUNA_PRIORITY=hotfix "$bin/terra-until-done" "hf-$issue" "$worktree" "$worker_brief"
