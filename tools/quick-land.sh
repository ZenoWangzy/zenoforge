#!/usr/bin/env bash
# Ruling zenoforge_direct_live_2026_11_12: an ordinary engine change goes from edit to main in one command, no PR.
# Run it in a clone sitting on origin/main with the edit uncommitted:
#   bash tools/quick-land.sh [--test '<cmd>']... [--prior-art '<URL or: no external prior art: reason>'] '<commit subject>' ['<commit trailer>']
# Code needs --prior-art (written into the commit message as a `## prior-art` section; ruling
# zenoforge-limited-allow-research-first-2026-11-05) and at least one --test; each runs through tools/test-receipt.sh at the committed HEAD, and one red stops the
# landing with the branch kept. Gate files, rule files and overridden files still go through a PR.
# shortcut: a --test is one plain command split on spaces (no shell operators); wrap pipes in a script.
# shortcut: merge-pr.sh's static scans, scheduler prelude, review-family and revert checks do not run here; pass them as --test.
# CI runs on the push to main (a red main opens an incident) and zf-auto-pin publishes the merged SHA.
set -euo pipefail

QUICK_LAND_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$QUICK_LAND_DIR/merge-pr.sh" # MERGE_PR_GATE_RE

# The pin merges these engine files into the target's pack copy (tools/pin-vecta.sh); prints the first one the staged paths touch.
quick_land_override_hit() { # <staged engine paths>
  local home target hook table
  home="${AGENT_HOME:-${ZF_HOME:-$HOME/.vecta-agent}}"
  target="$home/checkout"
  git -C "$target" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main 2>/dev/null || true
  hook="$(git -C "$target" show origin/main:.zenoforge/build.json 2>/dev/null | jq -er '.hook | select(type == "string" and length > 0)')" \
    || { echo "cannot read the override table from $target"; return 0; }
  table="$(git -C "$target" show "origin/main:$(dirname -- "$hook")/overrides.tsv" 2>/dev/null)" || return 0 # no table: nothing is overridden
  grep -xFf <(awk -F'\t' '$1 != "" && $1 !~ /^#/ { print "engine/" $1 }' <<<"$table") <<<"$1" | head -1 || true
}

quick_land_refusal() { # <number of --test> <prior-art text> → staged diff; prints why it is not quick-landable; prints nothing when it is
  local tests="$1" prior="${2:-}" paths path code=0 hit
  paths="$(git diff --cached --name-only)"
  [[ -n "$paths" ]] || { echo 'nothing to land'; return 0; }
  while IFS= read -r path; do
    [[ "$path" =~ $MERGE_PR_GATE_RE ]] && { echo "gate file: $path"; return 0; }
    case "$path" in
      engine/vendor/*) echo "vendored file: $path"; return 0 ;;
      *.md) ;;
      *) code=1 ;;
    esac
  done <<<"$paths"
  hit="$(git diff --cached --name-only --diff-filter=DR --no-renames | grep -E '^engine/.*\.test\.(sh|py|mjs)$' | head -1 || true)"
  [[ -z "$hit" ]] || { echo "deletes or renames away test suite: $hit"; return 0; }
  if grep -q '^engine/' <<<"$paths"; then
    hit="$(quick_land_override_hit "$(grep '^engine/' <<<"$paths")")"
    [[ -z "$hit" ]] || { echo "VectA override table file: $hit"; return 0; }
  fi
  if ((code && !tests)); then echo 'code change needs at least one --test'; return 0; fi
  # Same acceptance as merge_pr_prior_art_ok: a source URL or a "no external prior art: <reason>" line.
  if ((code)) && ! grep -Eiq 'https?://[^[:space:])>]+|^no external prior art:[[:space:]]*[^[:space:]]' <<<"$prior"; then
    echo 'code change needs --prior-art "<source URL>" or "no external prior art: <reason>"'
  fi
}

# Checks that need the new commit: the rule lane and the size ratchet, on this change's own files only.
quick_land_commit_refusal() {
  local out
  [[ -f engine/rule-lane.sh ]] || { echo 'engine/rule-lane.sh is missing'; return 0; }
  bash engine/rule-lane.sh origin/main HEAD >/dev/null 2>&1 || { echo 'rule-lane refused the change'; return 0; }
  out="$({ bash tools/size-ratchet.sh 2>&1 || true; } | awk 'NR == FNR { own[$0] = 1; next } $1 == "FAIL" && $2 in own' <(git diff --name-only origin/main HEAD) -)"
  [[ -z "$out" ]] || echo "size-ratchet: $out"
}

quick_land_run_tests() { # test commands...; stops at the first red, the receipt keeps every rc
  local cmd words rc=0
  for cmd in "$@"; do
    read -r -a words <<<"$cmd"
    bash "$QUICK_LAND_DIR/test-receipt.sh" "${words[@]}" || rc=$?
    ((rc == 0)) || { echo "quick-land: test failed rc=$rc: $cmd" >&2; return 1; }
  done
}

quick_land_main() {
  local subject trailer reason branch prior=''
  local -a tests=() rest=()
  while (($#)); do
    case "$1" in
      --test) [[ -n "${2:-}" ]] || { echo 'quick-land: --test needs a command' >&2; return 2; }; tests+=("$2"); shift 2 ;;
      --prior-art) [[ -n "${2:-}" ]] || { echo 'quick-land: --prior-art needs a text' >&2; return 2; }; prior="$2"; shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  subject="${rest[0]:-}" trailer="${rest[1]:-}"
  [[ -n "$subject" ]] || { echo "usage: quick-land.sh [--test '<cmd>']... [--prior-art '<text>'] '<commit subject>' ['<commit trailer>']" >&2; return 2; }
  git fetch -q origin main
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    echo 'quick-land: HEAD is not origin/main; other commits would land too' >&2
    return 1
  fi
  git add -A
  reason="$(quick_land_refusal "${#tests[@]}" "$prior")"
  if [[ -n "$reason" ]]; then
    echo "quick-land: use the normal PR path: $reason" >&2
    return 1
  fi
  branch="quick/$(git rev-parse --short HEAD)-$(date +%s)"
  git switch -q -c "$branch"
  git commit -qm "$subject" ${prior:+-m $'## prior-art\n'"$prior"} ${trailer:+-m "$trailer"}
  # From here a refusal keeps the committed branch for inspection or a PR; only a landed change returns to origin/main.
  reason="$(quick_land_commit_refusal)"
  if [[ -n "$reason" ]]; then
    echo "quick-land: use the normal PR path: $reason (branch $branch kept)" >&2
    return 1
  fi
  quick_land_run_tests ${tests[@]+"${tests[@]}"} || { echo "quick-land: not landed, branch $branch kept at $(git rev-parse --short HEAD)" >&2; return 1; }
  git push -q origin HEAD:main || { echo "quick-land: push to main failed (main moved?); branch $branch kept" >&2; return 1; }
  git fetch -q origin main
  git switch -q --detach origin/main
  git branch -q -D "$branch"
  echo "quick-land: landed on main at $(git rev-parse --short HEAD)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  quick_land_main "$@"
fi
