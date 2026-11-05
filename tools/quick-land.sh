#!/usr/bin/env bash
# Ruling simple-tasks-fast-lane-2026-11-05: a small Markdown change lands in one command.
# Run it in a clone sitting on origin/main with the edit uncommitted. CI still runs after
# the merge, and zf-auto-pin publishes the merged SHA.
set -euo pipefail

QUICK_LAND_MAX_LINES=30

quick_land_refusal() { # staged diff → prints why it is not simple; prints nothing when it is
  local paths path lines
  paths="$(git diff --cached --name-only)"
  [[ -n "$paths" ]] || { echo 'nothing to land'; return 0; }
  while IFS= read -r path; do
    case "$path" in
      engine/vendor/*) echo "vendored file: $path"; return 0 ;;
      *.md) ;;
      *) echo "not Markdown: $path"; return 0 ;;
    esac
  done <<<"$paths"
  lines="$(git diff --cached --numstat | awk '{ total += $1 + $2 } END { print total + 0 }')"
  if ((lines > QUICK_LAND_MAX_LINES)); then
    echo "$lines changed lines, limit $QUICK_LAND_MAX_LINES"
  fi
}

quick_land_main() {
  local subject="${1:-}" trailer="${2:-}" reason branch url
  [[ -n "$subject" ]] || { echo 'usage: quick-land.sh <commit subject> [commit trailer]' >&2; return 2; }
  git fetch -q origin main
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    echo 'quick-land: HEAD is not origin/main; other commits would land too' >&2
    return 1
  fi
  git add -A
  reason="$(quick_land_refusal)"
  if [[ -n "$reason" ]]; then
    echo "quick-land: use the normal PR path: $reason" >&2
    return 1
  fi
  branch="quick/$(git rev-parse --short HEAD)-$(date +%s)"
  git switch -q -c "$branch"
  git commit -qm "$subject" ${trailer:+-m "$trailer"}
  git push -q -u origin "$branch"
  url="$(gh pr create --base main --head "$branch" --title "$subject" \
    --body $'Small Markdown change, landed by tools/quick-land.sh.\n\n## prior-art\n\nno external prior art: small text change')"
  bash tools/merge-pr.sh "${url##*/}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  quick_land_main "$@"
fi
