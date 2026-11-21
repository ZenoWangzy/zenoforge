#!/usr/bin/env bash
# Ruling zenoforge_direct_live_2026_11_12: an ordinary engine change goes from edit to main in one command, no PR.
# Run it in a clone sitting on origin/main with the edit uncommitted:
#   bash tools/quick-land.sh [--test '<cmd>']... [--prior-art '<URL or: no external prior art: reason>'] '<commit subject>' ['<commit trailer>']
# Code needs --prior-art (written into the commit message as a `## prior-art` section; ruling
# zenoforge-limited-allow-research-first-2026-11-05) and at least one --test; each runs through tools/test-receipt.sh at the committed HEAD, and one red stops the
# landing with the branch kept. Founder 2026-11-19 ("改动都直接上线，立刻生效"): a gate file lands here with its own suite
# (--test 'bash engine/merge-pr-helper.test.sh'); a VectA-overridden file lands after a pin-vecta dry run passes. Rule files still go through a PR.
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
  table="$(git -C "$target" show "origin/main:$(dirname -- "$hook")/overrides.tsv" 2>/dev/null)" || table="" # no table: nothing is overridden
  # 11-19: 00fabfb changed a file a pack patch-*.py rewrites and stalled every pin for 25 min; those files get the dry run too.
  grep -xFf <({ awk -F'\t' '$1 != "" && $1 !~ /^#/ { print "engine/" $1 }' <<<"$table"; git -C "$target" grep -hoE '"[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+"' origin/main -- '.zenoforge/build/pack/scripts/zenoforge-pack/patch-*.py' 2>/dev/null | tr -d '"' | sed 's#^#engine/#'; }) <<<"$1" | head -1 || true
}

# Main moves while the suites run (2026-11-20: four runs of about 20 min each were lost to commits on other files).
# Commits that arrived meanwhile and share no file with this change or with the suites it ran are replayed under it,
# as a merge queue does; a shared file or a conflict keeps the refusal. The suites ran on the earlier base: main CI
# covers a semantic clash.
quick_land_push() { # <the --test commands>; a rejected push replays onto the moved main (at most 3 times)
  # Main moved while the suites ran (2026-11-20: four 20-minute lands lost). A main commit on a file of this change refuses;
  # one on a suite this land ran replays and runs only those suites again (985 and the paused-tick fix lost 20-40 min runs
  # to suite-only overlap); the rest of the green result stands, as in a merge queue.
  local base left=3 theirs cmd word rerun
  until git push -q origin HEAD:main 2>/dev/null; do
    (( left-- > 0 )) || return 1
    base="$(git rev-parse HEAD~1)"
    git fetch -q origin main || return 1
    theirs="$(git diff --name-only "$base" origin/main | sort -u)"
    [[ -z "$(comm -12 <(git diff --name-only "$base" HEAD | sort -u) <(printf '%s\n' "$theirs"))" ]] || return 1
    git rebase -q origin/main 2>/dev/null || { git rebase --abort 2>/dev/null; return 1; }
    rerun=()
    for cmd in "$@"; do
      for word in $cmd; do [[ $word == *.test.* ]] && grep -qxF -- "$word" <<<"$theirs" && { rerun+=("$cmd"); break; }; done
    done
    if (( ${#rerun[@]} )); then
      quick_land_run_tests "${rerun[@]}" || { echo "quick-land: a suite main changed is red on the replayed tree" >&2; return 1; }
    fi
    echo "quick-land: main advanced; replayed onto $(git rev-parse --short origin/main), ${#rerun[@]} changed suite(s) rerun" >&2
  done
}

quick_land_refusal() { # <number of --test> <prior-art text> [test commands] → staged diff; prints why it is not quick-landable; prints nothing when it is
  local tests="$1" prior="${2:-}" paths path code=0 hit
  paths="$(git diff --cached --name-only)"
  [[ -n "$paths" ]] || { echo 'nothing to land'; return 0; }
  while IFS= read -r path; do
    [[ "$path" =~ $MERGE_PR_GATE_RE && " ${3:-} " != *engine/merge-pr-helper.test.sh* ]] && { echo "gate file $path needs --test 'bash engine/merge-pr-helper.test.sh'"; return 0; }
    case "$path" in
      engine/vendor/*) echo "vendored file: $path"; return 0 ;;
      *.md) ;;
      *) code=1 ;;
    esac
  done <<<"$paths"
  hit="$(git diff --cached --name-only --diff-filter=DR --no-renames | grep -E '^engine/.*\.test\.(sh|py|mjs)$' | head -1 || true)"
  [[ -z "$hit" ]] || { echo "deletes or renames away test suite: $hit"; return 0; }
  if ((code && !tests)); then echo 'code change needs at least one --test'; return 0; fi
  # Same acceptance as merge_pr_prior_art_ok: a source URL or a "no external prior art: <reason>" line.
  if ((code)) && ! grep -Eiq 'https?://[^[:space:])>]+|^no external prior art:[[:space:]]*[^[:space:]]' <<<"$prior"; then
    echo 'code change needs --prior-art "<source URL>" or "no external prior art: <reason>"'
  fi
}

# Checks that need the new commit: the rule lane, size ratchet and shortcut ratchet.
# 11-19: 47bc387 landed with only intake-refill-flush.test.sh while the focused selection also named intake-existing-walk and
# intake-missing-state; both went red on main. Every focused test must be a --test, except the whole scheduler suites that take
# about 25 min each (scheduler.test.sh, scheduler-gates.test.sh, scheduler-part-N.test.sh): main CI runs those.
quick_land_missing_focused() { # <test commands> -> prints each focused test path of origin/main..HEAD the commands do not name
  local path
  while IFS= read -r path; do
    [[ "$path" == engine/* || "$path" == tools/* ]] || continue
    case "${path##*/}" in scheduler.test.sh|scheduler-gates.test.sh|scheduler-part-*.test.sh) continue ;; esac
    [[ " ${1:-} " == *" $path "* ]] || printf '%s\n' "$path"
  done < <(${QUICK_LAND_FOCUSED:-node engine/focused-test-paths.mjs} --range origin/main HEAD 2>/dev/null)
}

quick_land_commit_refusal() { # [test commands]
  local out missing
  # A selection error (a changed script with no mapped test) is a refusal, not an empty selection.
  ${QUICK_LAND_FOCUSED:-node engine/focused-test-paths.mjs} --range origin/main HEAD >/dev/null 2>&1 \
    || { echo "focused-test-paths failed for origin/main..HEAD (run it to see why; a new script needs a RELATED_TESTS row)"; return 0; }
  missing="$(quick_land_missing_focused "${1:-}")"
  [[ -z "$missing" ]] || { echo "focused tests missing from --test: $(paste -sd' ' <<<"$missing")"; return 0; }
  [[ -f engine/rule-lane.sh ]] || { echo 'engine/rule-lane.sh is missing'; return 0; }
  bash engine/rule-lane.sh origin/main HEAD >/dev/null 2>&1 || { echo 'rule-lane refused the change'; return 0; }
  local hit log="${TMPDIR:-/tmp}/quick-land-pin-$(git rev-parse --short HEAD).log"
  hit="$(quick_land_override_hit "$(git diff --name-only origin/main HEAD | grep '^engine/' || true)")"
  if [[ -n "$hit" ]]; then # the pin merges this file into the VectA pack copy: prove the pin still builds and passes before main moves
    ZF_LOCAL_CLONE="$PWD" bash tools/pin-vecta.sh "$(git rev-parse HEAD)" "${AGENT_HOME:-${ZF_HOME:-$HOME/.vecta-agent}}/checkout" >"$log" 2>&1 \
      || { echo "pin dry run failed for VectA override file $hit (log $log)"; return 0; }
  fi
  # Main CI checks every engine *.test.sh for the bootstrap before any suite runs; the focused suites do not
  # (2026-11-20: a new test file without it turned main red for 46 minutes).
  local -a suites; mapfile -t suites < <(git diff --name-only --diff-filter=AM origin/main HEAD -- ':(glob)engine/**/*.test.sh')
  (( ${#suites[@]} == 0 )) || bash "$QUICK_LAND_DIR/../engine/test-bootstrap-check.sh" "${suites[@]}" >/dev/null 2>&1 \
    || { echo "a changed test file lacks the bootstrap (set -euo pipefail, then source test-env.sh): ${suites[*]}"; return 0; }
  out="$({ bash tools/size-ratchet.sh 2>&1 || true; } | awk 'NR == FNR { own[$0] = 1; next } $1 == "FAIL" && $2 in own' <(git diff --name-only origin/main HEAD) -)"
  [[ -z "$out" ]] || echo "size-ratchet: $out"
  out="$({ bash tools/shortcut-ratchet.sh 2>&1 || true; } | awk '
    NR == FNR { own[$0] = 1; next }
    /^FAIL / { print; next }
    /^NOTE / {
      note = substr($0, 6)
      marker = " has no shortcut comments left "
      at = index(note, marker)
      if (at) {
        path = substr(note, 1, at - 1)
        if (path in own) print
      }
    }
  ' <(git diff --name-only origin/main HEAD) -)"
  [[ -z "$out" ]] || echo "shortcut-ratchet: $out"
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
  reason="$(quick_land_refusal "${#tests[@]}" "$prior" "${tests[*]-}")"
  if [[ -n "$reason" ]]; then
    echo "quick-land: use the normal PR path: $reason" >&2
    return 1
  fi
  branch="quick/$(git rev-parse --short HEAD)-$(date +%s)"
  git switch -q -c "$branch"
  git commit -qm "$subject" ${prior:+-m $'## prior-art\n'"$prior"} ${trailer:+-m "$trailer"}
  # From here a refusal keeps the committed branch for inspection or a PR; only a landed change returns to origin/main.
  reason="$(quick_land_commit_refusal "${tests[*]-}")"
  if [[ -n "$reason" ]]; then
    echo "quick-land: use the normal PR path: $reason (branch $branch kept)" >&2
    return 1
  fi
  quick_land_run_tests ${tests[@]+"${tests[@]}"} || { echo "quick-land: not landed, branch $branch kept at $(git rev-parse --short HEAD)" >&2; return 1; }
  # shellcheck disable=SC2048,SC2086 # words on purpose: each test path becomes one argument
  quick_land_push ${tests[@]+"${tests[@]}"} || { echo "quick-land: push to main failed (main moved on a file this change or its suites touch, or kept moving); branch $branch kept" >&2; return 1; }
  git fetch -q origin main
  git switch -q --detach origin/main
  git branch -q -D "$branch"
  echo "quick-land: landed on main at $(git rev-parse --short HEAD)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  quick_land_main "$@"
fi
