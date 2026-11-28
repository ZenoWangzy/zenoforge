#!/usr/bin/env bash
# run_merge_lane_pass re-renders the PR body before it merges: a unit whose report changed since its PR opened gets
# the body edit (--body-file) ahead of the merge call (order read from the stub gh log); an unchanged report gets no edit.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "pr-body-merge-lane.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
H1=1111111111111111111111111111111111111111
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
alive() { return 1; }
ensure_clone() { printf '%s' "$fixture/wt-$1"; }
checkout_pr_head() { :; }
MAIN_HEAD="$M1"
gate_eval_sha() { printf '%s\n' "$M1"; }
git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && ( "${!#}" == refs/pull/*/head || "${!#}" == +refs/pull/*/head:refs/autopi/merge-candidates/* ) ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && ( "${5:-}" == FETCH_HEAD* || "${5:-}" == refs/autopi/merge-candidates/* ) ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
# A repo without pipeline-suites.yml: no main-suites gate (as scheduler-gates-suites-retired.test.sh).
repo="$fixture/body-lane-repo"; rm -rf "$repo"
command git init -q -b main "$repo"
command git -C "$repo" config user.email t@example.invalid; command git -C "$repo" config user.name t
mkdir -p "$repo/engine" "$ROOT/engine"
printf '#!/usr/bin/env bash\nprintf "rule-lane: decision=pass actor=%%s touched=0\\n" "${ZF_AGENT_NAME:-unit}"\n' > "$ROOT/engine/rule-lane.sh"
cp -- "$ROOT/engine/rule-lane.sh" "$repo/engine/rule-lane.sh"
echo base > "$repo/base.txt"; command git -C "$repo" add -A; command git -C "$repo" commit -qm base
command git -C "$repo" update-ref refs/remotes/origin/main "$(command git -C "$repo" rev-parse HEAD)"
ROOT="$repo"
GH_RUNS='[]'; GH_HEAD="$H1"; GH_MERGE_SHA="$M2"
GH_CHECKS='[{"name":"Pipeline suites","bucket":"pass"}]'
: > "$A/alerts/gate.md"

GH_LOG="$fixture/body-lane-gh.log"
lane_gh_saved="$(declare -f gh)"
gh() {
  case "$1 $2" in
    'pr edit'|'pr merge') printf '%s %s\n' "$1 $2" "$3" >> "$GH_LOG" ;;
  esac
  [[ "$1 $2" == 'pr edit' ]] && { cp "$5" "$fixture/body-lane-edited"; return 0; }
  eval "${lane_gh_saved/gh ()/gh_lane ()}"; gh_lane "$@"
}
printf '%s\n' '## root-cause' 'a' '## prior-art' 'https://example.com/x' > "$sup/impl-lane.md"
old_hash="$(pr_body_hash 'a body rendered from the report as it was when the PR opened')"
mk() { jq -cn --arg sha "$H1" --arg h "$1" '{units:[{id:"issue-7001",issue:7001,pr:87,stage:"ready-to-merge",lane:"pr",approved_sha:$sha,implementation_report:"impl-lane.md",pr_body_hash:$h,history:[]}]}'; }

units "$(mk "$old_hash")"
: > "$GH_LOG"; GH_MERGES=(); run_merge_lane || :
[[ "$(cat "$GH_LOG")" == $'pr edit 87\npr merge 87' ]] || fail "a changed report must edit the PR body before the merge, in that order ($(tr '\n' '|' < "$GH_LOG"))"
grep -qx '## prior-art' "$fixture/body-lane-edited" || fail 'the body edited before the merge lacks ## prior-art'

units "$(mk "$(pr_body_hash "$(pr_body_source 7001 "$sup/impl-lane.md")")")"
: > "$GH_LOG"; GH_MERGES=(); run_merge_lane || :
[[ "$(cat "$GH_LOG")" == 'pr merge 87' ]] || fail "an unchanged report must merge without an edit ($(tr '\n' '|' < "$GH_LOG"))"
echo 'pr-body-merge-lane.test.sh: ok'
