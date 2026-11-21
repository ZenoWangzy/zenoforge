#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
retro="$dir/retro.py"
root="$test_env_root/scratch"

# Fixture: twelve finished luna workers (rc written, older for smaller numbers), one unfinished, one retro run.
mk() {
  local d="$root/luna/$1"
  mkdir -p "$d"
  seq 1 "$2" | sed 's/.*/{"type":"item.completed","n":&}/' > "$d/events.jsonl"
}
for i in $(seq -w 1 12); do
  mk "w$i" 5
  echo 0 > "$root/luna/w$i/rc"
  touch -d "@$((1000 + 10#$i))" "$root/luna/w$i/rc"
done
mk w13 5                                  # no rc: still running, must be skipped
mk retro-20261111T0300Z 5                 # earlier retro run: must be skipped
echo 0 > "$root/luna/retro-20261111T0300Z/rc"
touch -d "@2000" "$root/luna/retro-20261111T0300Z/rc"

python3 -B "$retro" select "$root" 10 > "$test_env_root/keys.txt"
expected="$(seq -f 'w%02g' 3 12)"
[[ "$(cat "$test_env_root/keys.txt")" == "$expected" ]] || { echo "retro.test.sh: select picked wrong sessions:" >&2; cat "$test_env_root/keys.txt" >&2; exit 1; }
echo "select rc=0"

# Raw model output: one kept candidate, four dropped for four different reasons.
cat > "$test_env_root/raw.json" <<'JSON'
{"candidates":[
 {"category":"navigation","severity":"high","session_key":"w12","event_line":3,"evidence":"read 4 files to find the schema","proposal":"add a pointer"},
 {"category":"navigation","severity":"high","session_key":"w11","evidence":"no line cited","proposal":"add a pointer"},
 {"category":"navigation","severity":"low","session_key":"w10","event_line":99,"evidence":"line past end","proposal":"add a pointer"},
 {"category":"vibes","severity":"low","session_key":"w09","event_line":2,"evidence":"x","proposal":"y"},
 {"category":"tool-economy","severity":"low","session_key":"w01","event_line":2,"evidence":"not selected","proposal":"y"}
]}
JSON
python3 -B "$retro" filter "$root" "$test_env_root/keys.txt" "$test_env_root/raw.json" "$test_env_root/out.json"
jq -e '.candidates | length == 1 and .[0].session_key == "w12" and .[0].event_line == 3' "$test_env_root/out.json" >/dev/null \
  || { echo "retro.test.sh: kept candidate wrong:" >&2; cat "$test_env_root/out.json" >&2; exit 1; }
echo "keep rc=0"
jq -e '.dropped == {"no_event_position":1,"event_line_out_of_range":1,"bad_category":1,"unknown_session":1} and .total == 5' "$test_env_root/out.json" >/dev/null \
  || { echo "retro.test.sh: drop counts wrong:" >&2; cat "$test_env_root/out.json" >&2; exit 1; }
echo "drop-count rc=0"
# Slice 2 publishes the filtered candidate file.
publish_root="$test_env_root/publish-scratch"
publish_repo="$test_env_root/publish-repo"
fake_bin="$test_env_root/publish-bin"
engine="$(cd -- "$dir/.." && pwd -P)"
mkdir -p "$publish_root/luna/p1" "$publish_root/luna/p2" "$publish_repo/.zenoforge/state" "$fake_bin"
printf '%s\n' '{"type":"failure","message":"same event","at":"2026-11-18T10:00:00Z"}' > "$publish_root/luna/p1/events.jsonl"
printf '%s\n' '{"type":"failure","message":"same event","at":"2026-11-18T11:00:00Z"}' > "$publish_root/luna/p2/events.jsonl"
cat > "$test_env_root/candidates.json" <<'JSON'
{"candidates":[
  {"category":"navigation","severity":"medium","session_key":"p1","event_line":1,"evidence":"first event evidence","proposal":"Add a pointer to the schema"},
  {"category":"navigation","severity":"high","session_key":"p2","event_line":1,"evidence":"second event evidence","proposal":"Add a pointer to the schema"},
  {"category":"automated-checks","severity":"high","session_key":"p1","event_line":1,"evidence":"lint evidence","proposal":"Add a lint check for this case"}
]}
JSON
cat > "$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1:$2" in
  api:--method)
    if [[ "$*" == *"/sub_issues"* ]]; then
      echo '{}'
    elif [[ "$*" == *"/issues/"* ]]; then
      echo 501000
    else
      jq -c 'if length == 0 then [[]] else [.] end' "$FAKE_ISSUES"
    fi
    ;;
  label:list) cat "$FAKE_LABELS" ;;
  label:create)
    grep -qx -- "$3" "$FAKE_LABELS" || printf '%s\n' "$3" >> "$FAKE_LABELS"
    ;;
  issue:view)
    [[ "${FAKE_ISSUE_VIEW_FAILURE:-0}" == 1 ]] && exit 1
    cat "$FAKE_ISSUE_VIEW"
    ;;
  pr:list) cat "$FAKE_MERGED_PRS" ;;
  issue:create)
    title=""; body_file=""; labels='[]'
    while (($#)); do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        --label) labels="$(jq --arg name "$2" '. + [{name:$name}]' <<< "$labels")"; shift 2 ;;
        *) shift ;;
      esac
    done
    number="$(cat "$FAKE_NEXT_NUMBER")"
    printf '%s\n' "$((number + 1))" > "$FAKE_NEXT_NUMBER"
    jq --argjson number "$number" --arg title "$title" --argjson labels "$labels" --rawfile body "$body_file" \
      '. + [{number:$number,title:$title,body:$body,state:"OPEN",labels:$labels}]' "$FAKE_ISSUES" > "$FAKE_ISSUES.tmp"
    mv "$FAKE_ISSUES.tmp" "$FAKE_ISSUES"
    printf 'https://github.com/test/repo/issues/%s\n' "$number"
    ;;
  issue:comment)
    number="$3"
    body_file=""
    while (($#)); do
      case "$1" in --body-file) body_file="$2"; shift 2 ;; *) shift ;; esac
    done
    jq -cn --argjson number "$number" --rawfile body "$body_file" '{number:$number,body:$body}' >> "$FAKE_COMMENTS"
    ;;
  *) echo "unexpected fake gh call: $*" >&2; exit 90 ;;
esac
SH
chmod +x "$fake_bin/gh"
printf '%s\n' bug priority:top needs-triage auto-filed > "$test_env_root/labels"
printf '[]\n' > "$test_env_root/issues.json"
: > "$test_env_root/comments.jsonl"
printf '7001\n' > "$test_env_root/next-number"
printf '[]\n' > "$test_env_root/merged-prs.json"
ZF_GH_REPO=test/repo ZF_REPO=example-maintainer/example-repo ZF_REPO_DIR="$publish_repo" ZF_ENGINE_DIR="$engine" \
  ZF_ISSUE_LOCK_DIR="$test_env_root/locks" RETRO_OUT_DIR="$test_env_root/publish-out" \
  PATH="$fake_bin:$PATH" FAKE_ISSUES="$test_env_root/issues.json" FAKE_COMMENTS="$test_env_root/comments.jsonl" \
  FAKE_LABELS="$test_env_root/labels" FAKE_NEXT_NUMBER="$test_env_root/next-number" \
  python3 -B "$retro" publish "$publish_root" "$publish_repo" "$test_env_root/candidates.json"
jq -e 'length == 1 and (.[0].body | contains("first event evidence"))
  and (([.[0].labels[].name] | index("needs-triage")) != null)' "$test_env_root/issues.json" >/dev/null \
  || { echo "retro.test.sh: duplicate candidates did not create exactly one issue:" >&2; cat "$test_env_root/issues.json" >&2; exit 1; }
[[ "$(wc -l < "$test_env_root/comments.jsonl" | tr -d ' ')" == 1 ]] \
  || { echo 'retro.test.sh: duplicate candidate did not append exactly one comment' >&2; cat "$test_env_root/comments.jsonl" >&2; exit 1; }
jq -e '.body | contains("second event evidence")' "$test_env_root/comments.jsonl" >/dev/null \
  || { echo 'retro.test.sh: duplicate candidate comment omitted its evidence' >&2; cat "$test_env_root/comments.jsonl" >&2; exit 1; }
echo "publish dedupe rc=0"
# (a) Every merged retro change is recorded: the intake issue and the lesson fragment alike.
jq -e '.changes | length == 2
  and any(.[]; .issue == 7001 and .category == "navigation" and (.filed_at | type == "string"))
  and any(.[]; .category == "automated-checks" and .verifiable == false and (.lesson | type == "string")
    and (.reason | contains("lesson fragment")))' \
  "$test_env_root/publish-out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: candidate issue was not recorded for verification:" >&2; cat "$test_env_root/publish-out/retro-verify.json" >&2; exit 1; }
fragment="$(printf '%s\n' "$publish_repo"/lessons/pending/*.json)"
[[ -f "$fragment" ]] || { echo 'retro.test.sh: mechanical candidate created no lesson fragment' >&2; exit 1; }
printf '%s\n' '{"incidents":[]}' > "$publish_repo/registry.json"
ZF_REPO_DIR="$publish_repo" ZF_ENGINE_DIR="$engine" ZF_CONFIG_ROOT="$publish_repo/.zenoforge" \
  bash "$engine/lesson-fragments.sh" --check "$publish_repo" "$publish_repo/registry.json" --files "$fragment"
echo "publish fragment accepted rc=0"

# The verifier uses filtered retro candidates from equal ten-session windows.
verify_root="$test_env_root/verify-scratch"
verify_out="$test_env_root/verify-out"
mkdir -p "$verify_root/luna" "$verify_out"
merge_epoch="$(date -u -d '2026-01-01 00:00:00 UTC' +%s)"
merge_at="$(date -u -d "@$merge_epoch" +%Y-%m-%dT%H:%M:%SZ)"
for i in $(seq 0 9); do
  id="$(printf '%02d' "$i")"
  d="$verify_root/luna/b$id"
  mkdir -p "$d"
  printf '0\n' > "$d/rc"
  seq 1 4 | sed 's/.*/{"type":"item.completed"}/' > "$d/events.jsonl"
  touch -d "@$((merge_epoch - 10 + i))" "$d/rc"
done
for i in $(seq 0 9); do
  id="$(printf '%02d' "$i")"
  d="$verify_root/luna/a$id"
  mkdir -p "$d"
  printf '0\n' > "$d/rc"
  seq 1 4 | sed 's/.*/{"type":"item.completed"}/' > "$d/events.jsonl"
  touch -d "@$((merge_epoch + 1 + i))" "$d/rc"
done
for i in $(seq 0 9); do printf 'b%02d\n' "$i"; done > "$verify_out/before.keys"
for i in $(seq 0 9); do printf 'a%02d\n' "$i"; done > "$verify_out/after.keys"
cat > "$verify_out/before.candidates.json" <<'JSON'
{"candidates":[
 {"category":"navigation","severity":"high","session_key":"b00","event_line":1,"evidence":"e","proposal":"p"},
 {"category":"navigation","severity":"high","session_key":"b01","event_line":1,"evidence":"e","proposal":"p"},
 {"category":"navigation","severity":"high","session_key":"b02","event_line":1,"evidence":"e","proposal":"p"}
]}
JSON
cat > "$verify_out/after.candidates.json" <<'JSON'
{"candidates":[
 {"category":"navigation","severity":"high","session_key":"a00","event_line":1,"evidence":"e","proposal":"p"},
 {"category":"navigation","severity":"high","session_key":"a01","event_line":1,"evidence":"e","proposal":"p"},
 {"category":"navigation","severity":"high","session_key":"a02","event_line":1,"evidence":"e","proposal":"p"},
 {"category":"navigation","severity":"high","session_key":"a03","event_line":1,"evidence":"e","proposal":"p"}
]}
JSON
touch -d "@$((merge_epoch - 20))" "$verify_out/before.keys"
touch -d "@$((merge_epoch + 20))" "$verify_out/after.keys"
jq -n --arg merged "$merge_at" '{closedByPullRequestsReferences:[{mergedAt:$merged}]}' > "$test_env_root/closed-issue.json"
cat > "$verify_out/retro-verify.json" <<'JSON'
{"changes":[{"issue":9001,"category":"navigation","class":"navigation-retract-fixture"}]}
JSON
ZF_GH_REPO=test/repo ZF_REPO=example-maintainer/example-repo ZF_REPO_DIR="$publish_repo" ZF_ENGINE_DIR="$engine" \
  ZF_ISSUE_LOCK_DIR="$test_env_root/locks" PATH="$fake_bin:$PATH" \
  FAKE_ISSUES="$test_env_root/issues.json" FAKE_COMMENTS="$test_env_root/comments.jsonl" \
  FAKE_LABELS="$test_env_root/labels" FAKE_NEXT_NUMBER="$test_env_root/next-number" \
  FAKE_ISSUE_VIEW="$test_env_root/closed-issue.json" FAKE_MERGED_PRS="$test_env_root/merged-prs.json" \
  python3 -B "$dir/retro-verify.py" "$verify_root" "$verify_out"
jq -e --arg merged "$merge_at" '.changes[0] | .merged_at == $merged and .before_count == 3 and .after_count == 4
  and (.reported_at | type == "string") and (.retraction_filed_at | type == "string")' \
  "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: verifier did not record the before/after counts:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
jq -es 'any(.[]; .number == 9001 and (.body | contains("Before: 3 candidate events in 10 sessions.")
  and contains("After: 4 candidate events in 10 sessions.")))' "$test_env_root/comments.jsonl" >/dev/null \
  || { echo "retro.test.sh: merged issue comment omitted the equal-window counts:" >&2; cat "$test_env_root/comments.jsonl" >&2; exit 1; }
jq -e 'any(.[]; .title == "Retro: retract or rewrite navigation change"
  and (.body | contains("3 events in 10 sessions") and contains("4 events in 10 sessions")))' \
  "$test_env_root/issues.json" >/dev/null \
  || { echo "retro.test.sh: no retract-or-rewrite issue included both counts:" >&2; cat "$test_env_root/issues.json" >&2; exit 1; }
echo "verification before/after rc=0"

# Every later verify invocation reuses the fake gh; per-scenario overrides win.
run_verify() {
  ZF_GH_REPO=test/repo ZF_REPO=example-maintainer/example-repo ZF_REPO_DIR="$publish_repo" ZF_ENGINE_DIR="$engine" \
    ZF_ISSUE_LOCK_DIR="$test_env_root/locks" PATH="$fake_bin:$PATH" \
    FAKE_ISSUES="$test_env_root/issues.json" FAKE_COMMENTS="$test_env_root/comments.jsonl" \
    FAKE_LABELS="$test_env_root/labels" FAKE_NEXT_NUMBER="$test_env_root/next-number" \
    FAKE_ISSUE_VIEW="${FAKE_ISSUE_VIEW:-$test_env_root/closed-issue.json}" \
    FAKE_MERGED_PRS="${FAKE_MERGED_PRS:-$test_env_root/merged-prs.json}" \
    python3 -B "$dir/retro-verify.py" "$1" "$2"
}

# (b) A "Refs #N" PR never closes the issue, so the merged time comes from the merged-PR body search.
jq -n '{closedByPullRequestsReferences:[]}' > "$test_env_root/open-issue.json"
printf '%s\n' "[{\"mergedAt\":\"$merge_at\"}]" > "$test_env_root/merged-prs.json"
jq -n --arg filed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{changes:[{issue:9101,category:"navigation",class:"navigation-refs-fixture",filed_at:$filed}]}' \
  > "$verify_out/retro-verify.json"
FAKE_ISSUE_VIEW="$test_env_root/open-issue.json" run_verify "$verify_root" "$verify_out"
jq -e --arg merged "$merge_at" '.changes[0].merged_at == $merged and .before_count == 3 and .after_count == 4' \
  "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: a Refs-PR change never got its merged time:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
echo "verification refs-merge-time rc=0"
# A change whose PR can never be found is named every run once past the bound.
jq -n --arg filed "$(date -u -d '20 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{changes:[{issue:9102,category:"navigation",class:"navigation-stale-fixture",filed_at:$filed}]}' \
  > "$verify_out/retro-verify.json"
printf '[]\n' > "$test_env_root/merged-prs.json"
stale_out="$(FAKE_ISSUE_VIEW="$test_env_root/open-issue.json" run_verify "$verify_root" "$verify_out")"
[[ "$stale_out" == *"issue #9102"*"still has no merged PR after 14 days"* ]] \
  || { echo "retro.test.sh: an unfindable PR waited silently:" >&2; printf '%s\n' "$stale_out" >&2; exit 1; }
jq -e '.changes[0] | has("merged_at") | not' "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: an unfindable PR still changed the state file:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
echo "verification stale-bound rc=0"

# (c) A gh failure ends the follow-up with one line and rc 0; the state file is untouched.
jq -n '{changes:[{issue:9103,category:"navigation",class:"navigation-gh-failure-fixture"}]}' \
  > "$verify_out/retro-verify.json"
cp "$verify_out/retro-verify.json" "$test_env_root/retro-verify.before.json"
gh_fail_rc=0
gh_fail_out="$(FAKE_ISSUE_VIEW_FAILURE=1 FAKE_ISSUE_VIEW="$test_env_root/closed-issue.json" \
  run_verify "$verify_root" "$verify_out" 2>/dev/null)" || gh_fail_rc=$?
[[ "$gh_fail_rc" == 0 ]] || { echo "retro.test.sh: a gh failure stopped the retro run (rc=$gh_fail_rc)" >&2; exit 1; }
[[ "$gh_fail_out" == *"9103"*"retrying next run"* ]] \
  || { echo "retro.test.sh: a gh failure did not print its one-line reason:" >&2; printf '%s\n' "$gh_fail_out" >&2; exit 1; }
cmp "$test_env_root/retro-verify.before.json" "$verify_out/retro-verify.json" \
  || { echo "retro.test.sh: a gh failure still rewrote the state file:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
echo "verification gh-failure rc=0"

# (d) The count went down: the change is reported but no retract-or-rewrite issue is opened.
cat > "$verify_out/after.candidates.json" <<'JSON'
{"candidates":[
 {"category":"navigation","severity":"high","session_key":"a00","event_line":1,"evidence":"e","proposal":"p"},
 {"category":"navigation","severity":"high","session_key":"a01","event_line":1,"evidence":"e","proposal":"p"}
]}
JSON
jq -n '{changes:[{issue:9104,category:"navigation",class:"navigation-drop-fixture",merged_at:"2026-01-01T00:00:00Z"}]}' \
  > "$verify_out/retro-verify.json"
run_verify "$verify_root" "$verify_out"
jq -e '.changes[0] | .before_count == 3 and .after_count == 2 and (.reported_at | type == "string")
  and (has("retraction_filed_at") | not)' "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: a dropped count was misrecorded:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
jq -e '[.[] | select(.body | contains("navigation-drop-fixture"))] | length == 0' \
  "$test_env_root/issues.json" >/dev/null \
  || { echo "retro.test.sh: a dropped count still opened a retract issue:" >&2; cat "$test_env_root/issues.json" >&2; exit 1; }
jq -es 'any(.[]; .number == 9104 and (.body | contains("After: 2 candidate events")))' "$test_env_root/comments.jsonl" >/dev/null \
  || { echo "retro.test.sh: a dropped count was not reported:" >&2; cat "$test_env_root/comments.jsonl" >&2; exit 1; }
echo "verification count-dropped rc=0"
# The window is incomplete: verify waits for ten retained sessions on both sides.
wait_root="$test_env_root/verify-wait-scratch"
mkdir -p "$wait_root/luna"
for i in $(seq 0 9); do
  d="$wait_root/luna/b$(printf '%02d' "$i")"
  mkdir -p "$d"; printf '0\n' > "$d/rc"; : > "$d/events.jsonl"
  touch -d "@$((merge_epoch - 10 + i))" "$d/rc"
done
for i in $(seq 0 2); do
  d="$wait_root/luna/a$(printf '%02d' "$i")"
  mkdir -p "$d"; printf '0\n' > "$d/rc"; : > "$d/events.jsonl"
  touch -d "@$((merge_epoch + 1 + i))" "$d/rc"
done
jq -n '{changes:[{issue:9105,category:"navigation",class:"navigation-wait-fixture",merged_at:"2026-01-01T00:00:00Z"}]}' \
  > "$verify_out/retro-verify.json"
wait_out="$(run_verify "$wait_root" "$verify_out")"
[[ "$wait_out" == *"waiting for 10 retained sessions around issue #9105"* ]] \
  || { echo "retro.test.sh: an incomplete window did not wait:" >&2; printf '%s\n' "$wait_out" >&2; exit 1; }
jq -e '.changes[0] | has("before_count") | not' "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: an incomplete window still counted:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
echo "verification window-incomplete rc=0"
# An unreadable state file is the loud exception: the run still fails.
printf 'not json\n' > "$verify_out/retro-verify.json"
rc=0; run_verify "$verify_root" "$verify_out" >/dev/null 2>&1 || rc=$?
[[ "$rc" != 0 ]] || { echo 'retro.test.sh: an unreadable state file exited 0' >&2; exit 1; }
echo "verification bad-state rc!=0"
echo 'retro.test.sh: all assertions passed'
