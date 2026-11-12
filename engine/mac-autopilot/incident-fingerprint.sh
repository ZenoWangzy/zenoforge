#!/usr/bin/env bash
# Incident key = fingerprint of the alert signature (Alertmanager group_by, Sentry fingerprinting,
# PagerDuty dedup_key): values that change between occurrences go; unit and issue ids stay.
incident_fingerprint() {
  printf '%s' "$1" | sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z//g' \
    -e 's/[0-9a-f]{40}//g' \
    -e 's/(^| )(count|secs|elapsed|duration|took|age|sha)=[^ ]*/\1/g' \
    | tr -s ' ' | sed -E 's/^ //; s/ $//'
}

incident_class() {
  local raw="$1" slug hash
  slug="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-|-$//g')"
  [[ -n "$slug" ]] || slug=incident
  if ((${#slug} > 64)); then
    hash="$(printf '%s' "$raw" | shasum -a 256 | awk '{print substr($1,1,8)}')"
    slug="${slug:0:55}-$hash"
  fi
  printf '%s\n' "$slug"
}
