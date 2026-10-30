#!/usr/bin/env bash
# Sourced by lib.sh and the autopilot scheduler.
#
# A closing keyword in an issue title or model-written PR brief has previously
# closed an unrelated issue at merge. Neutralize those references while
# keeping the surrounding text readable.
scrub_closing_keywords() {
  perl -CSD -pe '
    s{
      \b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b (:?\s*)
      (?:
        https?://github\.com/[\w.-]+/[\w.-]+/(?:issues|pull)/(\d+)
        | [\w.-]+/[\w.-]+ \# (\d+)
        | \# (\d+)
      )
    }{
      my $num = $3 // $4 // $5;
      "$1 issue $num"
    }gxie
  '
}
