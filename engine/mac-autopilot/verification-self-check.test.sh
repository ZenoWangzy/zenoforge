#!/usr/bin/env bash
# A target verification command runs before review; red results use self-fix, and the passing evidence reaches the existing PR body refresh.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-scheduler-gates-fixture.sh"

fail() { echo "verification-self-check.test.sh: $*" >&2; exit 1; }
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/scheduler.d/self-check.sh"

sha=""
session_id=11111111-2222-3333-4444-555555555555
TAG=20261110T000000Z
fixture="$test_env_root/verification"
repo="$fixture/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
git -C "$repo" commit --allow-empty -qm base
runs_file="$sup/verification-runs"; : > "$runs_file"
self_check_run() { echo run >> "$runs_file"; echo 'stub self-check'; return 0; }
self_check_runs() { wc -l < "$runs_file" | tr -d ' '; }
pid_start() { echo stub; }
tick_pr_base() { echo main; }

write_unit() { # id issue report
  jqf -cn --arg id "$1" --argjson issue "$2" --arg report "$3" --arg sid "$session_id" \
    '{units:[{id:$id,issue:$issue,lane:"pr",pr:$issue,branch:("agent/"+$id),stage:"review-pending",labels:[],implement_model:"gpt-6-luna",session_ids:{repair:$sid},implementation_report:$report,self_check_fixes:0,history:[]}]}' > "$UNITS"
  printf '## root-cause\nverification case\n\n## recurrence-guard\nkind: test\n\n## prior-art\nno external prior art: test fixture\n' > "$sup/$3"
}
commit_config_as_base() {
  git -C "$repo" add -A -- .zenoforge/state/verification.json
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm 'verification config base'
  sha="$(git -C "$repo" rev-parse HEAD)"
}
run_gate() { # id issue report → harvest the real pre-review gate
  local id="$1" issue="$2" report="$3"
  self_check_before_review "$id" "$sha" "$repo" "$(jqf -c '.units[0]' "$UNITS")" || true
  wait
  self_check_harvest
}
field() { jqf -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }

gh_calls="$fixture/gh-calls"
edited_body="$fixture/edited-body"
GH_BODY=''
FOCUS_MODE=all
unit_dispatch_priority() { echo 1; }
dispatch_capacity_free() { return 0; }
gh() {
  case "$1 $2" in
    'pr view') printf '%s' "$GH_BODY" ;;
    'pr edit')
      [[ "$4" == --body-file ]] || fail "unexpected PR edit form: $*"
      printf 'pr edit %s\n' "$3" >> "$gh_calls"
      cp "$5" "$edited_body"
      ;;
    *) fail "unexpected gh call: $*" ;;
  esac
}

# Green verification records the argv and its evidence, edits the existing PR body once, and allows review dispatch.
green="$repo/verify-green"
cat > "$green" <<'SH'
#!/bin/sh
[ "$1" = '--green' ] || exit 91
mkdir -p evidence
printf 'visited /welcome\n' > evidence/user-path.log
printf 'verification passed\n'
SH
chmod +x "$green"
mkdir -p "$repo/.zenoforge/state"
jqf -cn --arg exe "$green" '{argv:[$exe,"--green"],timeout_s:5,evidence_dir:"evidence"}' > "$repo/.zenoforge/state/verification.json"
commit_config_as_base
write_unit issue-87001 87001 impl-87001.md
set_unit issue-87001 '.implementation_report="impl-87001.md"'
run_gate issue-87001 87001 impl-87001.md
[[ "$(field issue-87001 .self_check_status)" == pass ]] || fail 'green verification did not reach pass'
jqf -e '.units[0].verification.exit_code == 0 and .units[0].verification.argv[1] == "--green" and .units[0].verification.evidence_files == ["evidence/user-path.log"]' "$UNITS" >/dev/null \
  || fail "green verification did not retain command and evidence: $(jqf -c '.units[0]' "$UNITS")"
: > "$gh_calls"
refill_stopped() { return 1; }
dispatches=()
dispatch() { dispatches+=("$1"); return 0; }
dispatch_why_clear() { :; }
dispatch_if_room issue-87001 review-pending review review.log impl-87001.md gpt-6-luna high prompt "$sha" "$repo" "" "" "$(jqf -c '.units[0]' "$UNITS")" false codex false configured codex || fail 'green verification did not dispatch review'
[[ "${dispatches[*]}" == review ]] || fail 'green verification did not reach review dispatch'
[[ "$(grep -c '^pr edit 87001$' "$gh_calls")" == 1 ]] || fail 'verification did not use one guarded PR body edit'
grep -qx '## verification' "$edited_body" || fail 'PR body lacks ## verification'
grep -Fq "Command argv (JSON): [\"$green\",\"--green\"]" "$edited_body" || fail 'PR body does not name the verification command'
grep -qx 'Exit code: 0' "$edited_body" || fail 'PR body does not name the verification exit code'
grep -Fq 'Evidence files (relative to clone): ["evidence/user-path.log"]' "$edited_body" || fail 'PR body does not name the evidence file'

# A nonzero verification exits before self_check_run and room_for keeps review from dispatching while self-fix is pending.
red="$repo/verify-red"
cat > "$red" <<'SH'
#!/bin/sh
printf 'verification failed on /welcome\nsecond output line\n'
exit 17
SH
chmod +x "$red"
jqf -cn --arg exe "$red" '{argv:[$exe],timeout_s:5,evidence_dir:"evidence"}' > "$repo/.zenoforge/state/verification.json"
commit_config_as_base
write_unit issue-87002 87002 impl-87002.md
run_gate issue-87002 87002 impl-87002.md
[[ "$(field issue-87002 .self_check_status)" == red ]] || fail 'nonzero verification was not red'
jqf -e '.units[0].self_fix_pending == true' "$UNITS" >/dev/null || fail 'nonzero verification did not queue self-fix'
out="$(field issue-87002 .self_check_output)"
grep -Fq 'verification failed on /welcome' "$out" && grep -Fq 'evidence=evidence' "$out" || fail 'red verification log lacks command output or evidence path'
: > "$runs_file"
dispatches=()
dispatch_if_room issue-87002 review-pending review review.log impl-87002.md gpt-6-luna high prompt "$sha" "$repo" "" "" "$(jqf -c '.units[0]' "$UNITS")" false codex false configured codex && fail 'red verification dispatched review'
[[ "${dispatches[*]}" != review && "$(self_check_runs)" == 0 ]] || fail 'red verification ran the normal self-check or review'

# No config keeps today's self-check behavior and logs one skip per unit across two ticks.
rm -f "$repo/.zenoforge/state/verification.json"
commit_config_as_base
write_unit issue-87003 87003 impl-87003.md
run_gate issue-87003 87003 impl-87003.md
self_check_before_review issue-87003 "$sha" "$repo" "$(jqf -c '.units[0]' "$UNITS")" || fail 'no-config second tick did not reuse the pass'
self_check_harvest
[[ "$(self_check_runs)" == 1 ]] || fail 'no-config path changed normal self-check behavior'
[[ "$(grep -Fc 'verification: skipped unit=issue-87003 (no state/verification.json)' "$LOG")" == 1 ]] || fail 'no-config skip was not logged exactly once'
jqf -e '.units[0].verification_skip_logged == true' "$UNITS" >/dev/null || fail 'no-config skip guard was not stored on the unit'

# Malformed JSON and a string argv are refused before the marker command can run.
marker="$repo/verification-command-ran"
cat > "$repo/mark-ran" <<'SH'
#!/bin/sh
touch "$1"
SH
chmod +x "$repo/mark-ran"
for invalid in malformed string-argv; do
  write_unit "issue-87004-$invalid" 87004 "impl-87004-$invalid.md"
  if [[ "$invalid" == malformed ]]; then
    printf '{"argv":["%s"],\n' "$repo/mark-ran" > "$repo/.zenoforge/state/verification.json"
  else
    jqf -cn --arg command "$repo/mark-ran $marker" '{argv:$command,timeout_s:5,evidence_dir:"evidence"}' > "$repo/.zenoforge/state/verification.json"
  fi
  commit_config_as_base
  run_gate "issue-87004-$invalid" 87004 "impl-87004-$invalid.md"
  [[ "$(field "issue-87004-$invalid" .self_check_status)" == red ]] || fail "$invalid config was not red"
  out="$(field "issue-87004-$invalid" .self_check_output)"
  grep -Fq 'verification refused' "$out" || fail "$invalid config was not refused with a reason"
  [[ ! -e "$marker" ]] || fail "$invalid config ran the marker command"
done

# A worker deletion cannot hide the failing config committed at the PR base.
git -C "$repo" switch -q main
jqf -cn --arg exe "$red" '{argv:[$exe],timeout_s:5,evidence_dir:"evidence"}' > "$repo/.zenoforge/state/verification.json"
commit_config_as_base
git -C "$repo" switch -q -c head-delete-verification
rm -f "$repo/.zenoforge/state/verification.json"
git -C "$repo" add -A -- .zenoforge/state/verification.json
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm 'worker deletes verification config'
sha="$(git -C "$repo" rev-parse HEAD)"
write_unit issue-87005 87005 impl-87005.md
run_gate issue-87005 87005 impl-87005.md
[[ "$(field issue-87005 .self_check_status)" == red ]] || fail 'worker deletion hid the failing base verification config'
out="$(field issue-87005 .self_check_output)"
grep -Fq 'verification failed unit=issue-87005 exit_code=17' "$out" || fail 'failing base verification command did not run'
! grep -Fq 'verification: skipped unit=issue-87005 (no state/verification.json)' "$LOG" || fail 'worker deletion was treated as a verification skip'
[[ "$(grep -Fc 'verification: ignored head copy for this run unit=issue-87005 path=.zenoforge/state/verification.json' "$LOG")" == 1 ]] || fail 'deleted head config was not logged as ignored'

# A worker addition cannot introduce a config when the base has none.
git -C "$repo" switch -q main
rm -f "$repo/.zenoforge/state/verification.json"
commit_config_as_base
git -C "$repo" switch -q -c head-add-verification
jqf -cn --arg exe "$repo/mark-ran" --arg marker "$marker" '{argv:[$exe,$marker],timeout_s:5,evidence_dir:"evidence"}' > "$repo/.zenoforge/state/verification.json"
git -C "$repo" add -- .zenoforge/state/verification.json
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm 'worker adds verification config'
sha="$(git -C "$repo" rev-parse HEAD)"
write_unit issue-87006 87006 impl-87006.md
run_gate issue-87006 87006 impl-87006.md
[[ "$(grep -Fc 'verification: skipped unit=issue-87006 (no state/verification.json)' "$LOG")" == 1 ]] || fail 'base without config did not skip verification'
[[ "$(grep -Fc 'verification: ignored head copy for this run unit=issue-87006 path=.zenoforge/state/verification.json' "$LOG")" == 1 ]] || fail 'added head config was not logged as ignored'
[[ ! -e "$marker" ]] || fail 'head-only verification config ran its marker command'

echo 'verification-self-check.test.sh: ok'
