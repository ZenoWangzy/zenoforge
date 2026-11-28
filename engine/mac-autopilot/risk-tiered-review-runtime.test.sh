#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "$BASH_SOURCE")/.." && pwd -P)/test-env.sh"
REPO_DIR="$TMPDIR/risk-tiered-review-repo"
ROOT="$REPO_DIR"
SUP="$TMPDIR/risk-tiered-review-supervisor"
UNITS="$SUP/units.json"
UNITS_ARCHIVE="$SUP/units-archive.json"
SELF_CHECK_LOG="$TMPDIR/risk-tiered-review-self-check.log"
mkdir -p "$REPO_DIR/.zenoforge/state" "$REPO_DIR/engine/state" "$REPO_DIR/packages/tests" "$REPO_DIR/packages/fruit/tests" "$SUP"
git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.name fixture
git -C "$REPO_DIR" config user.email fixture@example.invalid
cat > "$REPO_DIR/.zenoforge/state/escape-suites.json" <<'JSON'
{"version":1,"packages":{"packages":[{"test":"packages/tests/core.test.sh","command":["bash","packages/tests/core.test.sh"]}],"packages/fruit":[{"test":"packages/fruit/tests/escape.test.sh","command":["bash","packages/fruit/tests/escape.test.sh"]}]}}
JSON
printf '%s\n' '{"schema":"fixture","files":{}}' > "$REPO_DIR/engine/state/rule-files.json"
printf 'printf "green core\\n"\n' > "$REPO_DIR/packages/tests/core.test.sh"
printf 'printf "green\\n"\n' > "$REPO_DIR/packages/fruit/tests/escape.test.sh"
git -C "$REPO_DIR" add .
git -C "$REPO_DIR" commit -qm base
BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" update-ref refs/remotes/origin/main "$BASE_SHA"
printf 'printf "green v2\\n"\n' > "$REPO_DIR/packages/fruit/tests/escape.test.sh"
git -C "$REPO_DIR" add .
git -C "$REPO_DIR" commit -qm candidate
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
printf 'escape-suite: package=packages test=packages/tests/core.test.sh rc=0 output=green\nescape-suite: package=packages/fruit test=packages/fruit/tests/escape.test.sh rc=0 output=green\nrisk-review-check: lesson-lints rc=0\n' > "$SELF_CHECK_LOG"
STAMP='2026-11-26T00:00:00Z'
NOW_EPOCH=1795651200
SHA_RE='^[0-9a-f]{40}$'
ZF_PACK_REL=engine
export ZF_PACK_REL
jqf() { command jq "$@"; }
js() { jq -cn --arg value "$1" '$value'; }
unit_field() { jqf -r --arg id "$1" "(.units[] | select(.id==\$id)) | ($2)" "$UNITS"; }
hist() {
  local entry
  entry="$(jq -cn --arg stage "$1" --arg result "$2" --arg at "$STAMP" '{stage:$stage,result:$result,at:$at}')"
  printf '.history += [%s]' "$entry"
}
set_unit() {
  local temporary="$UNITS.next"
  jq --arg id "$1" "(.units[] | select(.id==\$id)) |= ($2)" "$UNITS" > "$temporary"
  mv "$temporary" "$UNITS"
}
say() { :; }
post_approved_status() { :; }
scheduler_lock_yield_between_units() { return 0; }
source "$(dirname -- "$BASH_SOURCE")/scheduler.d/risk-tiered-review.sh"
printf '{"units":[{"id":"skip-unit","issue":1121,"stage":"review-pending","self_check_status":"pass","self_check_sha":"%s","self_check_output":"%s","history":[]}]}' \
  "$HEAD_SHA" "$SELF_CHECK_LOG" > "$UNITS"
unit="$(jq -c '.units[0]' "$UNITS")"
history_sha="$(printf '%040d' 7)"
history_skip_at="$(date -u -d '21 days ago' +%Y-%m-%dT%H:%M:%SZ)"
history_merge_at="$(date -u -d '20 days ago' +%Y-%m-%dT%H:%M:%SZ)"
history_escape_at="$(date -u -d '19 days ago' +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg sha "$history_sha" --arg skip "$history_skip_at" --arg merged "$history_merge_at" \
  --arg escape "$history_escape_at" --arg path packages/fruit/tests/escape.test.sh \
  '{units:[range(0;5) as $i | {id:("matured-\($i)"),stage:"merged",approved_sha:$sha,history:( [
    {stage:"review-skip",result:$sha,at:$skip,paths:[$path]},
    {stage:"merged",at:$merged}
  ] + (if $i < 2 then [{stage:"review-skip-escape",at:$escape,paths:[$path]}] else [] end))}]}' > "$UNITS_ARCHIVE"
if risk_tiered_review_try_skip skip-unit "$unit" "$REPO_DIR" "$HEAD_SHA" "$HEAD_SHA"; then
  echo 'an escape-rate brake must leave the candidate for normal review'
  exit 1
fi
jq -e '.units[0] | .stage == "review-pending" and .history == []' "$UNITS" >/dev/null
cp "$UNITS_ARCHIVE" "$SUP/matured-units.json"
printf '{"units":[]}' > "$UNITS_ARCHIVE"
risk_tiered_review_try_skip skip-unit "$unit" "$REPO_DIR" "$HEAD_SHA" "$HEAD_SHA"
jq -e --arg sha "$HEAD_SHA" '.units[0] | .stage == "ready-to-merge" and .approved_sha == $sha and .history[-1].stage == "review-skip" and (.history[-1].paths | index("packages/fruit/tests/escape.test.sh") != null) and ([.history[-1].checks[] | select(.kind == "escape-suite")] | length == 2) and any(.history[-1].checks[]; .kind == "lesson-lint")' "$UNITS" >/dev/null
source "$(dirname -- "$BASH_SOURCE")/scheduler.d/pr-body.sh"
self_check_verification_body() { :; }
printf 'Implemented the fixture.\n' > "$SUP/report.md"
unit="$(jq -c '.units[0]' "$UNITS")"
body="$(pr_body_source 1121 "$SUP/report.md" "$unit")"
[[ "$body" == *'## review'* && "$body" == *'escape-suite:packages/fruit:packages/fruit/tests/escape.test.sh'* && "$body" == *'lesson-lint:exact-second-elapsed-grep'* ]]
jq --arg at "$STAMP" '.units[0].stage = "merged" | .units[0].history += [{stage:"merged",at:$at}] | .units += [{id:"escape-unit",issue:1122,stage:"merged",hotpatch:true,approved_sha:null,history:[{stage:"merged",at:$at}]}]' "$UNITS" > "$UNITS.next"
mv "$UNITS.next" "$UNITS"
incident="$(jq -c '.units[1]' "$UNITS")"
risk_tiered_review_record_escape "$incident" "$BASE_SHA" "$HEAD_SHA"
jq -e --arg path packages/fruit/tests/escape.test.sh '.units[0] | any(.history[]; .stage == "review-skip-escape" and ((.paths // []) | index($path) != null))' "$UNITS" >/dev/null
jq -e --arg path packages/fruit/tests/escape.test.sh 'length == 2 and all(.[]; .path == $path) and ([.[].packagePath] | sort == ["packages","packages/fruit"])' "$SUP/risk-tiered-review-invalidations.json" >/dev/null
[[ "$(jq -r '.units[1].risk_tiered_escape_recorded_sha' "$UNITS")" == "$HEAD_SHA" ]]
review_block="$(sed -n '/^      review-pending)/,/^      implement-pending)/p' "$(dirname -- "$BASH_SOURCE")/scheduler.d/dispatch-queue.sh")"
skip_line="$(grep -n 'risk_tiered_review_try_skip' <<<"$review_block" | cut -d: -f1)"
pick_line="$(grep -n 'pick_review_for_unit' <<<"$review_block" | cut -d: -f1)"
[[ "$skip_line" =~ ^[0-9]+$ && "$pick_line" =~ ^[0-9]+$ ]] && (( skip_line < pick_line ))
grep -q 'risk_tiered_review_record_escape "$ready" "$pre_merge_sha" "$approved"' "$(dirname -- "$BASH_SOURCE")/scheduler.d/merge-lane.sh"
decision_units="$SUP/decision-units.json"
jq -n --argjson unit "$unit" --slurpfile history "$SUP/matured-units.json" \
  '{units:([$unit] + $history[0].units)}' > "$decision_units"
missing_archive_decision="$(node "$(risk_tiered_review_script)" --decision --repo "$REPO_DIR" --base "$BASE_SHA" --head "$HEAD_SHA" \
  --check-output "$SELF_CHECK_LOG" --status pass --self-check-sha "$HEAD_SHA" \
  --invalidations "$SUP/missing-invalidations.json" --units "$decision_units" --archive "$SUP/missing-archive.json")"
jq -e '.eligible == true' <<<"$missing_archive_decision" >/dev/null
echo 'ok - eligible review skips are recorded, named in the PR body, and invalidated by a covered escape'
