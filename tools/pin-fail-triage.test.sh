#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/engine/test-env.sh"
repo=$MODEL_POLICY_TEST_REPO
script=$repo/tools/pin-fail-triage.sh
tmp=$(mktemp -d "$TMPDIR/pin-fail-triage-test.XXXXXX")
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
[[ "$1 $2" == 'pr list' ]] || exit 1
[[ ${PR_FAIL:-0} != 1 ]] || exit 1
[[ ! -f $PR_FIXTURE ]] || cat "$PR_FIXTURE"
GH
cat > "$tmp/bin/systemd-run" <<'SCOPE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SCOPE_CALLS"
while (($#)) && [[ $1 != -- ]]; do shift; done
shift
exec "$@"
SCOPE
cat > "$tmp/bin/engine-sync" <<'SYNC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CONTROL_CALLS"
case "$1" in
  --build) [[ ${CONTROL_FAIL:-0} != 1 ]] || exit 1; mkdir -p "$5/version" ;;
  --check) [[ -d $2/version || ${2##*/} == version ]] || exit 1 ;;
  *) exit 2 ;;
esac
SYNC
chmod +x "$tmp/bin/gh" "$tmp/bin/systemd-run" "$tmp/bin/engine-sync"
export PATH="$tmp/bin:$PATH" ZF_ENGINE_SYNC="$tmp/bin/engine-sync"
fail() { echo "pin-fail-triage.test.sh: $*" >&2; exit 1; }
case_dir() {
  local d=$tmp/$1
  mkdir -p "$d"
  git init -q --bare "$d/engine-origin.git"
  git clone -q "$d/engine-origin.git" "$d/engine" 2>/dev/null
  git -C "$d/engine" checkout -q -b main
  engine=$d/engine bare=$d/engine-origin.git
  export ZF_AUTO_PIN_HOME=$d/home ZF_MAIN_RED_REVERT_HOME=$d/home ZF_ALERTS_FILE=$d/alerts
  export CONTROL_CALLS=$d/control-calls SCOPE_CALLS=$d/scope-calls CANDIDATE_CALLS=$d/candidate-calls PR_FIXTURE=$d/pr
  export CONTROL_FAIL=0 FAIL_SHA='' FAIL_RC=1 CANDIDATE_MESSAGE='' PR_FAIL=0
  mkdir -p "$ZF_AUTO_PIN_HOME" "$engine/tools"
  : > "$CONTROL_CALLS"; : > "$SCOPE_CALLS"; : > "$CANDIDATE_CALLS"
  g=$(put base base baseline)
  git init -q --bare "$d/product-origin.git"
  git clone -q "$d/product-origin.git" "$d/product" 2>/dev/null
  git -C "$d/product" checkout -q -b main
  product=$d/product
  mkdir -p "$product/.zenoforge"
  printf '{"engine":"%s","hook":"build.sh"}\n' "$g" > "$product/.zenoforge/build.json"
  git -C "$product" add -A; git -C "$product" commit -qm product; git -C "$product" push -q -u origin main
  cp "$repo/tools/main-red-revert.sh" "$engine/tools/main-red-revert.sh"
  {
    cat <<'PIN'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$CANDIDATE_CALLS"
if [[ $1 == "$FAIL_SHA" ]]; then echo "$CANDIDATE_MESSAGE"; exit "$FAIL_RC"; fi
exit 0
PIN
    cat "$repo/tools/pin-vecta.sh"
  } > "$engine/tools/pin-vecta.sh"
  log=$d/pin.log
  printf 'pin-vecta: refusing publication build_status=1 check_status=1 preflight_status=1 vecta_gate_status=0\n' > "$log"
}
put() {
  printf '%s\n' "$2" > "$engine/$1"
  git -C "$engine" add -- "$1"; git -C "$engine" commit -qm "$3"; git -C "$engine" push -q origin HEAD:main
  git -C "$engine" rev-parse HEAD
}
run_triage() { bash "$script" "$engine" "$product" "$h" "$log" "${1:-1}" > "$tmp/out" 2>&1 || :; }
alert_has() { [[ -f $ZF_ALERTS_FILE ]] && grep -q " $1 " "$ZF_ALERTS_FILE"; }
head_is() { [[ $(git -C "$bare" rev-parse main) == "$1" ]]; }

case_dir product
h=$(put base bad 'break pin')
cp "$repo/tools/pin-vecta.sh" "$engine/tools/pin-vecta.sh"
product_head=$(git -C "$product" rev-parse HEAD)
export CONTROL_FAIL=1
run_triage
alert_has PIN-FAIL-PRODUCT || fail 'control failure did not emit PIN-FAIL-PRODUCT'
head_is "$h" || fail 'control failure pushed a revert'
run_triage
[[ $(wc -l < "$ZF_ALERTS_FILE") == 1 ]] || fail 'same head emitted a second alert'
[[ $(grep -c '^--build ' "$CONTROL_CALLS") == 1 ]] || fail 'control did not run exactly once'
grep -Fq "$log" "$ZF_ALERTS_FILE" || fail 'product alert omitted pin log'
grep -Fq -- "--build $g $product_head --out " "$CONTROL_CALLS" || fail 'control did not build the pinned engine against product main'
[[ $(git -C "$product" worktree list --porcelain | grep -c '^worktree ') == 1 ]] || fail 'control left its worktree behind'
out_dir=$(awk '/^--build / {print $5}' "$CONTROL_CALLS")
[[ ! -e $out_dir && $(git -C "$product" rev-parse HEAD) == "$product_head" ]] || fail 'control left output or changed product HEAD'
grep -q -- 'TasksMax=300 -p MemoryMax=2G -- timeout 600' "$SCOPE_CALLS" || fail 'control did not use the pin resource bounds'

case_dir single
h=$(put base bad 'break pin')
cp "$repo/tools/pin-vecta.sh" "$engine/tools/pin-vecta.sh"
run_triage
alert_has PIN-FAIL-AUTO-REVERT || fail 'single candidate was not auto-reverted'
[[ $(git -C "$bare" show main:base) == base ]] || fail 'single candidate remains on main'
git -C "$bare" log -1 --format=%B main | grep -q "${g:0:7}" || fail 'revert message omitted pinned commit'
[[ $(git -C "$product" worktree list --porcelain | grep -c '^worktree ') == 1 ]] || fail 'passing control left its worktree behind'
grep -Fq "head=$h pinned=$g" "$ZF_ALERTS_FILE" || fail 'revert alert omitted failed and pinned heads'

case_dir override
h=$(put base bad 'break override')
printf 'pin-vecta: refusing pin: override test.sh: three-way merge conflicts\n' > "$log"
run_triage
alert_has PIN-FAIL-AUTO-REVERT || fail 'single override conflict did not select its culprit'
[[ $(git -C "$bare" show main:base) == base ]] || fail 'override conflict culprit remains on main'

case_dir gate
h=$(put base bad 'break gate')
printf 'pin-vecta: refusing publication build_status=0 check_status=0 preflight_status=0 vecta_gate_status=1\n' > "$log"
run_triage
alert_has PIN-FAIL-AUTO-REVERT || fail 'single gate failure did not select its culprit'
[[ $(git -C "$bare" show main:base) == base ]] || fail 'gate failure culprit remains on main'

case_dir multiple
first=$(put first one 'first change'); second=$(put second two 'second change'); h=$(put third three 'third change')
export FAIL_SHA=$second
run_triage
alert_has PIN-FAIL-AUTO-REVERT || fail 'multiple candidates did not revert the failed candidate'
[[ $(git -C "$bare" show main:first) == one ]] || fail 'first candidate was reverted'
! git -C "$bare" cat-file -e main:second 2>/dev/null || fail 'second candidate remains'
[[ $(cat "$CANDIDATE_CALLS") == "$first"$'\n'"$second" ]] || fail 'candidates were not tested oldest first'

case_dir claim
h=$(put base bad 'break pin')
printf '%s fixer %s\n' "${h:0:7}" "$(date +%s)" > "$ZF_MAIN_RED_REVERT_HOME/main-red-revert.hold"
run_triage
alert_has PIN-FAIL-FIX-IN-PROGRESS || fail 'claim did not hold revert'
head_is "$h" || fail 'claim still pushed a revert'
(cd "$engine" && bash tools/main-red-revert.sh --culprit "$h" --reason 'pin build failed' --last-pinned "$g" --failed-head "$h") > "$tmp/repeat" 2>&1
[[ $(wc -l < "$ZF_ALERTS_FILE") == 1 ]] || fail 'same culprit got a second decision'

case_dir excluded
h=$(put base bad 'break pin')
for reason in 'rate limit' 'add this row' 'source checkout has changes' 'could not read zenoforge main CI runs' 'result=land-failed'; do
  printf '%s\n' "$reason" > "$log"
  run_triage
  [[ ! -s $CONTROL_CALLS && ! -e $ZF_ALERTS_FILE ]] || fail "$reason was triaged"
done
printf 'pin failed\n' > "$log"
for rc in 2 75 124; do
  run_triage "$rc"
  [[ ! -s $CONTROL_CALLS && ! -e $ZF_ALERTS_FILE ]] || fail "exit $rc was triaged"
done

case_dir preflight
h=$(put base bad 'preflight only')
printf 'pin-vecta: refusing publication build_status=0 check_status=0 preflight_status=1 vecta_gate_status=0\n' > "$log"
run_triage
alert_has PIN-FAIL-NO-CULPRIT || fail 'preflight-only failure selected a culprit'
head_is "$h" || fail 'preflight-only failure pushed a revert'

case_dir cap
for i in 1 2 3 4 5 6; do h=$(put "file$i" "$i" "change $i"); done
run_triage
alert_has PIN-FAIL-NO-CULPRIT || fail 'more than five candidates did not alert'
[[ ! -s $CANDIDATE_CALLS ]] || fail 'more than five candidates ran dry pins'
head_is "$h" || fail 'more than five candidates pushed a revert'

case_dir unavailable
first=$(put first one 'first change'); h=$(put second two 'second change')
export FAIL_SHA=$first FAIL_RC=2
run_triage
alert_has PIN-FAIL-NO-CULPRIT || fail 'candidate setup refusal did not stop attribution'
head_is "$h" || fail 'candidate setup refusal pushed a revert'

case_dir changed_control
h=$(put base bad 'break pin')
printf '#!/usr/bin/env bash\nexit 0\n' > "$engine/tools/pin-vecta.sh"
run_triage
alert_has PIN-FAIL-NO-CULPRIT || fail 'unrecognized control steps did not stop attribution'
[[ ! -s $CONTROL_CALLS ]] || fail 'unrecognized control steps ran a build'
head_is "$h" || fail 'unrecognized control steps pushed a revert'

case_dir changed_block
h=$(put base bad 'break pin')
export CONTROL_MARKER=$tmp/control-marker
sed -i '/^build_status=0$/a touch "$CONTROL_MARKER"' "$engine/tools/pin-vecta.sh"
run_triage
[[ ! -e $CONTROL_MARKER ]] || fail 'changed control code ran without review'
alert_has PIN-FAIL-NO-CULPRIT || fail 'changed control code did not stop attribution'
head_is "$h" || fail 'changed control code pushed a revert'

case_dir all_pass
first=$(put first one 'first change'); h=$(put second two 'second change')
run_triage
alert_has PIN-FAIL-NO-CULPRIT || fail 'passing candidates did not alert'
grep -Fq "${first:0:7}" "$ZF_ALERTS_FILE" && grep -Fq "${h:0:7}" "$ZF_ALERTS_FILE" || fail 'no-culprit alert omitted candidates'
head_is "$h" || fail 'passing candidates pushed a revert'

case_dir moved_product
h=$(put base bad 'break pin')
git clone -q -b main "$(git -C "$product" remote get-url origin)" "$tmp/product-writer"
echo updated > "$tmp/product-writer/updated"
git -C "$tmp/product-writer" add updated; git -C "$tmp/product-writer" commit -qm 'product changed'
git -C "$tmp/product-writer" push -q origin main
new_product_head=$(git -C "$tmp/product-writer" rev-parse HEAD)
run_triage
grep -Fq -- "--build $g $new_product_head --out " "$CONTROL_CALLS" || fail 'control did not use the updated product main'
alert_has PIN-FAIL-NO-CULPRIT || fail 'product move did not stop attribution'
head_is "$h" || fail 'product move pushed a revert'
[[ ! -e $log.pin-fail-triaged ]] || fail 'product move kept the marker, so the re-pin on the new product head would not be triaged'

case_dir detached_product
h=$(put base bad 'break pin')
git -C "$product" checkout -q --detach
run_triage
alert_has PIN-FAIL-AUTO-REVERT || fail 'detached product at origin main prevented attribution'
[[ $(git -C "$bare" show main:base) == base ]] || fail 'detached product culprit remains on main'

case_dir conflict
first=$(put base first 'first change'); h=$(put base later 'later change')
export FAIL_SHA=$first
run_triage
alert_has PIN-FAIL-REVERT-CONFLICT || fail 'conflicting revert did not alert'
head_is "$h" || fail 'conflicting revert was pushed'

case_dir reverted
first=$(put base first 'first change')
git -C "$engine" revert --no-edit "$first" >/dev/null
git -C "$engine" push -q origin HEAD:main
h=$(git -C "$engine" rev-parse HEAD)
export FAIL_SHA=$first
run_triage
alert_has PIN-FAIL-NO-CULPRIT || fail 'already reverted candidate did not alert'
head_is "$h" || fail 'already reverted candidate was reverted again'

case_dir pr
h=$(put base bad 'break pin')
echo 42 > "$PR_FIXTURE"
run_triage
alert_has PIN-FAIL-FIX-IN-PROGRESS || fail 'open PR did not hold revert'
head_is "$h" || fail 'open PR still allowed a revert'

case_dir pr_unavailable
h=$(put base bad 'break pin')
export PR_FAIL=1
run_triage
alert_has PIN-FAIL-NO-CULPRIT || fail 'unavailable PR search did not stop attribution'
head_is "$h" || fail 'unavailable PR search still allowed a revert'

case_dir revert_subject
h=$(put base bad 'Revert "old change"')
run_triage
alert_has PIN-FAIL-NO-CULPRIT || fail 'revert subject was not refused'
head_is "$h" || fail 'a revert commit was reverted'

case_dir rejected
h=$(put base bad 'break pin')
mkdir -p "$bare/hooks"
printf '#!/usr/bin/env bash\nexit 1\n' > "$bare/hooks/pre-receive"
chmod +x "$bare/hooks/pre-receive"
run_triage
alert_has PIN-FAIL-REVERT-CONFLICT || fail 'rejected revert push did not alert'
head_is "$h" || fail 'rejected revert push moved main'

case_dir merge
git -C "$engine" checkout -q -b feature
printf 'change\n' > "$engine/feature"
git -C "$engine" add feature; git -C "$engine" commit -qm feature
git -C "$engine" checkout -q main
git -C "$engine" merge -q --no-ff feature -m 'merge feature'
git -C "$engine" push -q origin HEAD:main
h=$(git -C "$engine" rev-parse HEAD)
run_triage
alert_has PIN-FAIL-AUTO-REVERT || fail 'merge culprit was not reverted'
! git -C "$bare" cat-file -e main:feature 2>/dev/null || fail 'merge was not reverted against first parent'

case_dir stop
h=$(put base bad 'break pin')
touch "$ZF_AUTO_PIN_HOME/pin-fail-triage.stop"
run_triage
[[ ! -s $CONTROL_CALLS && ! -e $ZF_ALERTS_FILE ]] || fail 'stop file did not disable triage'
head_is "$h" || fail 'stop file still allowed a revert'

echo 'pin-fail-triage.test.sh: all passed'
