#!/usr/bin/env bash
# Author gate (#114): only admitted authors start implementation; others are held at triage until an admitted author releases them.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/intake-author"
export MAC_AUTOPI_FIXTURE="$fixture"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts" "$fixture/bin" "$fixture/state"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
fail() { echo "intake-author.test.sh: $*" >&2; exit 1; }

gh_log="$fixture/gh.log"; log="$fixture/say.log"; trans="$fixture/transitions.log"
export GH_LOG="$gh_log" FIXTURE="$fixture"
cat > "$fixture/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100")
    n="${2##*/issues/}"; n="${n%%/*}"; cat "$FIXTURE/comments-$n.json" ;;
  "api repos/{owner}/{repo}/issues/"*)
    n="${2##*/issues/}"; [[ -f "$FIXTURE/author-$n.json" ]] || exit 1; cat "$FIXTURE/author-$n.json" ;;
  "issue comment") exit "${FAIL_COMMENT:-0}" ;;
esac
exit 0
GH
chmod +x "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH"
export TICK_INTAKE_GH_INVOKE="$fixture/bin/gh"
say() { printf '%s\n' "$*" >> "$log"; }
intake_skip() { :; }
scheduler_issue_transition() { printf '%s:%s:%s\n' "$1" "$2" "$3" >> "$trans"; return "${FAIL_TRANSITION:-0}"; }
CFG='{"issue_intake":{"trusted_authors":["friend"]}}'

author() { printf '{"author_association":"%s","user":{"login":"%s"}}\n' "$2" "$3" > "$fixture/author-$1.json"; }
comments() { printf '%s\n' "$2" > "$fixture/comments-$1.json"; }
hold_marker='{"author_association":"NONE","user":{"login":"bot"},"body":"<!-- zf-intake-author-hold -->\nheld"}'
release_by() { printf '[{"author_association":"%s","user":{"login":"%s"},"body":"ok\\n/release-intake"}]\n' "$2" "$3" > "$fixture/comments-$1.json"; }
# run N: prints the gate rc (0 admit, 1 held or retry) and resets the per-case logs
run() { : > "$gh_log"; : > "$trans"; : > "$log"; local rc=0; intake_author_gate "$1" '{"number":'"$1"'}' || rc=$?; printf '%s' "$rc"; }
commented() { grep -Fq 'issue comment' "$gh_log"; }

# Admitted classes go through unchanged: no comment, no transition.
for pair in "1 OWNER owner" "2 MEMBER member" "3 COLLABORATOR collab" "4 NONE friend"; do
  set -- $pair
  author "$1" "$2" "$3"; comments "$1" '[]'
  [[ "$(run "$1")" == 0 ]] || fail "$2 #$1 should be admitted"
  ! commented || fail "$2 #$1 admitted but commented"
  [[ ! -s "$trans" ]] || fail "$2 #$1 admitted but transitioned: $(cat "$trans")"
done

# An outsider is held once: one comment with the marker, moved to needs-triage.
author 5 NONE stranger; comments 5 '[]'
[[ "$(run 5)" == 1 ]] || fail 'outsider admitted without release'
grep -Fq 'issue comment 5 --body <!-- zf-intake-author-hold -->' "$gh_log" || fail "outsider hold comment missing: $(cat "$gh_log")"
[[ "$(cat "$trans")" == '5:needs-triage:intake-author-hold:NONE' ]] || fail "outsider not moved to triage: $(cat "$trans")"

# A later tick does not repeat the comment once the marker is on the issue.
comments 5 "[$hold_marker]"
[[ "$(run 5)" == 1 ]] || fail 'held outsider admitted'
! commented || fail 'hold comment repeated after the marker was posted'

# A failed comment or transition leaves the issue for the next tick.
author 6 NONE stranger; comments 6 '[]'
[[ "$(FAIL_COMMENT=1 run 6)" == 1 ]] || fail 'failed hold comment still reported held'
[[ ! -s "$trans" ]] || fail "failed hold comment still transitioned: $(cat "$trans")"
[[ "$(FAIL_TRANSITION=1 run 6)" == 1 ]] || fail 'failed hold transition not retried'

# Only an admitted author's /release-intake releases; an outsider's does not.
author 7 NONE stranger; release_by 7 NONE stranger
[[ "$(run 7)" == 1 ]] || fail 'outsider release comment released the issue'
author 8 NONE stranger; release_by 8 OWNER owner
[[ "$(run 8)" == 0 ]] || fail 'owner release comment did not release the issue'
[[ "$(cat "$trans")" == '8:ready-for-agent:intake-author-release' ]] || fail "release not recorded in stage history: $(cat "$trans")"
! commented || fail 'a release commented on the issue'

# Unknown association and allow-listed logins follow the route table, and a read failure never holds.
author 9 CONTRIBUTOR stranger; comments 9 '[]'
[[ "$(run 9)" == 1 ]] || fail 'unknown association admitted'
author 10 NONE friend; comments 10 '[]'
[[ "$(run 10)" == 0 ]] || fail 'allow-listed login held'
rm -f "$fixture/author-11.json"
[[ "$(run 11)" == 1 ]] || fail 'unreadable author did not return retry'
[[ ! -s "$trans" ]] && ! commented || fail 'unreadable author changed the issue'
grep -Fq 'author read failed; retry next tick' "$log" || fail "read failure not logged: $(cat "$log")"
echo 'intake-author.test.sh: ok'
