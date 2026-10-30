#!/usr/bin/env bash
# Rewrites HEAD's message so a Plan-Package line separated from the following
# Co-Authored-By trailer by blank lines joins that trailer block; git parses only
# the last paragraph as trailers, so the former acceptance checker missed it.
# Used by land-direct-main.sh through `git rebase --exec` (no-op when already joined).
set -euo pipefail
message="$(git show -s --format=%B HEAD)"
fixed="$(awk '
  /^Plan-Package: / { print; held = 1; blanks = 0; next }
  held && /^[[:space:]]*$/ { blanks++; next }
  held { if ($0 !~ /^Co-Authored-By: /) for (i = 0; i < blanks; i++) print ""; held = 0; blanks = 0 }
  { print }
' <<< "$message")"
[[ "$fixed" == "$message" ]] || git commit -q --amend --allow-empty --no-verify -F - <<< "$fixed"
