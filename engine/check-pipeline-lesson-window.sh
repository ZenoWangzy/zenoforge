#!/usr/bin/env bash
set -euo pipefail

repo="${1:?repo root required}"
code_commit="$(git -C "$repo" log -1 --format=%H -- engine)"
rules_commit="$(git -C "$repo" log -1 --format=%H -- lessons/RULES.md)"
catalog_commit="$(git -C "$repo" log -1 --format=%H -- lessons/CATALOG.md)"

if git -C "$repo" merge-base --is-ancestor "$code_commit" "$rules_commit" &&
   git -C "$repo" merge-base --is-ancestor "$code_commit" "$catalog_commit"; then
  exit 0
fi

# Lessons use a separate docs push; give the latest pipeline change 24 hours to acquire both entries.
code_epoch="$(git -C "$repo" show -s --format=%ct "$code_commit")"
age=$(( $(date +%s) - code_epoch ))
(( age >= 0 && age < 86400 ))
