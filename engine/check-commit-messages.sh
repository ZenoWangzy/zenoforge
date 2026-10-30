#!/usr/bin/env bash
set -euo pipefail

# The commit-message refusals land-direct-main.sh applies to every commit it lands.
# branch-delivery-preflight.mjs --mode commit runs this same checker, so a hand agent
# hears each refusal at commit time instead of one landing cycle later (2026-10-07,
# landing 251: a [skip ci] token in the body passed commit preflight and failed the landing).
# The messages keep the land-direct-main prefix verbatim; that is what the landing prints.

usage() {
  echo "Usage: $0 <git-range>" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage
range="$1"

refuse() {
  printf 'land-direct-main: %s\n' "$1" >&2
  exit 1
}

closing_pattern='(^|[^a-z0-9_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)([[:space:]]+|:[[:space:]]*)([a-z0-9_.-]+/[a-z0-9_.-]+)?#[0-9]+([^0-9]|$)'

commits="$(git rev-list --reverse "$range")" || exit 1
[[ -n "$commits" ]] || exit 0
while IFS= read -r commit; do
  message="$(git show -s --format=%B "$commit")"
  subject="${message%%$'\n'*}"
  body=""
  [[ "$message" == *$'\n'* ]] && body="${message#*$'\n'}"
  lower_subject="${subject,,}"
  lower_body="${body,,}"
  if [[ "$lower_body" =~ $closing_pattern ]]; then
    refuse "commit $commit body contains a GitHub closing keyword and issue reference"
  fi
  if [[ "$lower_body" == *'[skip ci]'* ]]; then
    refuse "commit $commit body contains [skip ci]; keep it only at the start of the subject"
  fi
  if [[ "$lower_subject" == *'[skip ci]'* ]] && \
    { [[ "${lower_subject:0:9}" != '[skip ci]' ]] || [[ "${lower_subject:9}" == *'[skip ci]'* ]]; }; then
    refuse "commit $commit has [skip ci] outside the subject prefix"
  fi
  # Hand-agent commits carry the package trailer directly followed by the attribution
  # trailer; git appends an amend-added Plan-Package after existing trailers, so this is
  # enforced only when both trailers are present.
  if ! awk '
    { lines[NR] = $0 }
    /^Plan-Package: / { if (!plan_line) plan_line = NR }
    /^Co-Authored-By: / { has_co = 1 }
    END {
      if (plan_line && has_co && !(plan_line < NR && lines[plan_line + 1] ~ /^Co-Authored-By: /)) exit 1
    }
  ' <<<"$message"; then
    refuse "commit $commit has a Plan-Package trailer not directly followed by Co-Authored-By"
  fi
done <<<"$commits"
