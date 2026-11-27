#!/usr/bin/env bash
# Every long flag a pipeline script passes to gh must exist in the gh this host runs.
# A missing flag fails the call, and callers that `|| return 0` turn that into silence:
# `gh issue list --sort` stopped every needs-info email reply from being read (2026-10-03).
# Only flags on the same line as the gh subcommand are checked, up to the first pipe or command break.
set -euo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
declare -A known=()
bad=0
while IFS=: read -r file line text; do
  [[ "$text" =~ ^[[:space:]]*# ]] && continue
  [[ "$text" =~ (^|[^[:alnum:]_./-])gh[[:space:]]+(issue|pr|run|label|release|repo|workflow|search|secret|variable|cache)[[:space:]]+([a-z][a-z-]*)(.*)$ ]] || continue
  cmd="${BASH_REMATCH[2]} ${BASH_REMATCH[3]}" rest="${BASH_REMATCH[4]}"
  rest="${rest%%|*}"; rest="${rest%%;*}"; rest="${rest%%&&*}"; rest="${rest%%)*}"
  if [[ -z "${known[$cmd]+set}" ]]; then
    # shellcheck disable=SC2086
    known[$cmd]=" $(gh $cmd --help 2>&1 | grep -oE -- '--[a-z][a-z-]*' | sort -u | tr '\n' ' ') --help "
  fi
  for flag in $(grep -oE -- '(^|[[:space:]])--[a-z][a-z-]*' <<< "$rest" | tr -d ' \t'); do
    [[ "${known[$cmd]}" == *" $flag "* ]] && continue
    echo "check-gh-flags: $file:$line: gh $cmd has no $flag (gh $(gh --version | awk 'NR==1{print $3}'))" >&2
    bad=1
  done
done < <(cd "$root" && grep -rnE --include='*.sh' --exclude='*.test.sh' '(^|[^[:alnum:]_./-])gh[[:space:]]+[a-z]+[[:space:]]+[a-z]' engine)
exit "$bad"
