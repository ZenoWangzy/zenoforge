#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
retro="$dir/retro.py"
root="$test_env_root/scratch"

bash -n "$dir/run-retro.sh"
jq -e '
  .properties.candidates.items as $candidate
  | ($candidate.required | index("derived_from") != null)
    and $candidate.properties.check.type == "object"
    and $candidate.properties.check.minProperties == 1
    and $candidate.properties.derived_from.type == "array"
    and $candidate.properties.derived_from.items.type == "string"
    and $candidate.properties.derived_from.uniqueItems == true
    and ($candidate.properties | has("paired_eval") | not)
' "$dir/../prompts/retro.schema.json" >/dev/null \
  || { echo 'retro.test.sh: retro schema omits matcher or lineage fields' >&2; exit 1; }
grep -Fq 'none of the latest ten successful recorded sessions' "$dir/../prompts/retro.md"
grep -Fq 'For automated-checks, include a non-empty matcher object' "$dir/../prompts/retro.md"
grep -Fq 'Use an empty derived_from array when none apply' "$dir/../prompts/retro.md"
grep -Fq 'A prompt or skill change remains a proposal until the existing paired evaluation' "$dir/../prompts/retro.md"

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
eval_home="$test_env_root/eval-home"
engine="$(cd -- "$dir/.." && pwd -P)"
mkdir -p "$publish_root/luna/p1" "$publish_root/luna/p2" "$publish_root/luna/p3" "$publish_root/luna/p4" "$publish_root/luna/p5" "$publish_root/luna/p6" "$publish_root/luna/p7" "$publish_repo/.zenoforge/state" "$fake_bin" "$eval_home/eval"
printf '%s\n' '{"type":"failure","message":"same event","at":"2026-11-18T10:00:00Z"}' > "$publish_root/luna/p1/events.jsonl"
printf 'engine-a\n' > "$publish_root/luna/p1/engine-version"
printf '%s\n' '{"type":"failure","message":"same event","at":"2026-11-18T11:00:00Z"}' > "$publish_root/luna/p2/events.jsonl"
printf '%s\n' '{"type":"failure","message":"unmeasurable"}' > "$publish_root/luna/p3/events.jsonl"
printf 'engine-a\n' > "$publish_root/luna/p3/engine-version"
printf '%s\n' '{"type":"failure","message":"false positive"}' > "$publish_root/luna/p4/events.jsonl"
printf 'engine-a\n' > "$publish_root/luna/p4/engine-version"
printf '%s\n' '{"type":"failure","message":"eval regression"}' > "$publish_root/luna/p5/events.jsonl"
printf '%s\n' '{"type":"failure","message":"unrelated comparison"}' > "$publish_root/luna/p6/events.jsonl"
printf '%s\n' '{"type":"failure","message":"unpaired case"}' > "$publish_root/luna/p7/events.jsonl"
printf 'engine-a\n' > "$publish_root/luna/p5/engine-version"
printf 'engine-a\n' > "$publish_root/luna/p6/engine-version"
printf 'engine-a\n' > "$publish_root/luna/p7/engine-version"
for i in $(seq -w 1 10); do
  mkdir -p "$publish_root/luna/normal-$i"
  printf '0\n' > "$publish_root/luna/normal-$i/rc"
  printf '%s\n' '{"type":"item.completed"}' > "$publish_root/luna/normal-$i/events.jsonl"
done
printf '%s\n' '{"type":"failure","message":"ordinary recovered failure"}' > "$publish_root/luna/normal-10/events.jsonl"
mkdir -p "$publish_repo/lessons/full"
printf '%s\n' '**V1272** Existing lesson.' > "$publish_repo/lessons/RULES.md"
cat > "$test_env_root/candidates.json" <<'JSON'
{"candidates":[
  {"category":"navigation","severity":"medium","session_key":"p1","event_line":1,"evidence":"first event evidence","proposal":"Add a pointer to the schema","derived_from":["V1272"]},
  {"category":"navigation","severity":"high","session_key":"p2","event_line":1,"evidence":"second event evidence","proposal":"Add a pointer to the schema","derived_from":["V1272"]},
  {"category":"automated-checks","severity":"high","session_key":"p1","event_line":1,"evidence":"lint evidence","proposal":"Add a lint check for this case","check":{"type":"failure","message":"same event"},"derived_from":["V1272"]},
  {"category":"automated-checks","severity":"medium","session_key":"p3","event_line":1,"evidence":"missing executable matcher","proposal":"Add a lint check without a matcher","derived_from":["V1272"]},
  {"category":"automated-checks","severity":"medium","session_key":"p4","event_line":1,"evidence":"matcher hits ordinary recovered events","proposal":"Add a broad lint check","check":{"type":"failure"},"derived_from":["V1272"]},
  {"category":"automated-checks","severity":"high","session_key":"p5","event_line":1,"evidence":"paired evaluation regressed a frozen case","proposal":"Add an eval regression lint check","check":{"type":"failure","message":"eval regression"},"derived_from":["V1272"]},
  {"category":"automated-checks","severity":"high","session_key":"p6","event_line":1,"evidence":"comparison labels must identify this candidate","proposal":"unrelated comparison labels","check":{"type":"failure","message":"unrelated comparison"},"derived_from":["V1272"]},
  {"category":"automated-checks","severity":"high","session_key":"p7","event_line":1,"evidence":"all cases must be paired","proposal":"unpaired case","check":{"type":"failure","message":"unpaired case"},"derived_from":["V1272"]}
]}
JSON
cat > "$fake_bin/node" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
runner="$1"
shift
[[ "$runner" == */engine/eval/run-eval.mjs ]] || { echo "unexpected fake node script: $runner" >&2; exit 90; }
case "$1" in
  --label)
    label="$2"
    shift 2
    fragment=""
    route_issues=0
    while (($#)); do
      case "$1" in
        --no-route-fresh-agent-issues) route_issues=1; shift ;;
        --lesson-fragment) fragment="$2"; shift 2 ;;
        --case|--cases) echo "retro eval unexpectedly filtered frozen cases" >&2; exit 91 ;;
        *) echo "unexpected fake eval option: $1" >&2; exit 92 ;;
      esac
    done
    [[ "$route_issues" == 1 ]] || { echo "eval issue routing was not suppressed" >&2; exit 99; }
    if [[ "$label" == retro-base-* ]]; then
      [[ -z "$fragment" ]] || { echo "baseline included a lesson fragment" >&2; exit 93; }
    elif [[ "$label" == retro-cand-* ]]; then
      [[ -n "$fragment" && -f "$fragment" ]] || { echo "candidate label omitted its lesson fragment" >&2; exit 94; }
    else
      echo "retro eval label omitted its candidate id: $label" >&2
      exit 95
    fi
    results='[{"stage":"triage","caseId":"sample-retry-delay","run":1,"pass":true}]'
    result_label="$label"
    if [[ -n "$fragment" ]] && grep -Fq 'eval regression' "$fragment"; then
      results='[{"stage":"triage","caseId":"sample-retry-delay","run":1,"pass":false}]'
    elif [[ -n "$fragment" ]] && grep -Fq 'unrelated comparison' "$fragment"; then
      result_label="retro-cand-unrelated"
    elif [[ -n "$fragment" ]] && grep -Fq 'unpaired case' "$fragment"; then
      results='[{"stage":"triage","caseId":"sample-retry-delay","run":1,"pass":true},{"stage":"triage","caseId":"unpaired","run":1,"pass":true}]'
    fi
    fragment_text=""
    fragment_sha=""
    suite_sha="$(git -C "$ZF_ENGINE_DIR" rev-parse HEAD)"
    if [[ -n "$fragment" ]]; then
      fragment_text="$(cat "$fragment")"
      fragment_sha="$(printf '%s' "$fragment_text" | sha256sum | awk '{print $1}')"
    fi
    mkdir -p "$AGENT_HOME/eval/$label"
    jq -n --arg label "$result_label" --arg sha "$fragment_sha" --arg suite "$suite_sha" --argjson results "$results" \
      '{label:$label,suiteSha:$suite,caseSetSha:"fixture-cases",lessonFragmentSha:(if $sha == "" then null else $sha end),policy:{roles:{}},overrides:[],results:$results}' > "$AGENT_HOME/eval/$label/results.json"
    jq -cn --arg kind run --arg label "$label" --arg fragment "$fragment" \
      '{kind:$kind,label:$label,fragment:$fragment}' >> "$FAKE_EVAL_CALLS"
    ;;
  --compare)
    baseline="$2"
    candidate="$3"
    shift 3
    [[ "$baseline" == retro-base-* && "$candidate" == retro-cand-* ]] || { echo "comparison labels omitted candidate ids" >&2; exit 96; }
    baseline_id="$(sed 's/^retro-base-//' <<< "$baseline")"
    candidate_id="$(sed 's/^retro-cand-//' <<< "$candidate")"
    [[ "$baseline_id" == "$candidate_id" ]] || { echo "comparison labels named different candidates" >&2; exit 97; }
    baseline_file="$AGENT_HOME/eval/$baseline/results.json"
    candidate_file="$AGENT_HOME/eval/$candidate/results.json"
    baseline_name="$(jq -r '.label' "$baseline_file")"
    candidate_name="$(jq -r '.label' "$candidate_file")"
    jq -cn --arg kind compare --arg baseline "$baseline" --arg candidate "$candidate" \
      '{kind:$kind,baseline:$baseline,candidate:$candidate}' >> "$FAKE_EVAL_CALLS"
    echo "$baseline_name: 1/1; $candidate_name: 1/1"
    if jq -e '.results[0].pass == true' "$baseline_file" >/dev/null && jq -e '.results[0].pass == false' "$candidate_file" >/dev/null; then
      echo 'REGRESSION pass→fail triage/sample-retry-delay run 1'
    else
      echo 'pass→fail: none'
    fi
    if [[ "$(jq '.results | length' "$candidate_file")" -gt "$(jq '.results | length' "$baseline_file")" ]]; then
      echo "UNPAIRED triage/unpaired/1 only in $candidate_name"
    fi
    echo 'compared in both labels: triage/sample-retry-delay/1'
    ;;
  *)
    echo "unexpected fake eval command: $*" >&2
    exit 98
    ;;
esac
SH
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
    [[ "${FAKE_ISSUE_VIEW_FAILURE:-0}" == 1 || "${FAKE_ISSUE_VIEW_FAILURE_ISSUE:-}" == "$3" ]] && exit 1
    cat "$FAKE_ISSUE_VIEW"
    ;;
  pr:list|api:search/issues) cat "$FAKE_MERGED_PRS" ;;
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
chmod +x "$fake_bin/node"
gh() { command gh "$@"; }
export -f gh
printf '%s\n' bug priority:top needs-triage auto-filed > "$test_env_root/labels"
: > "$test_env_root/eval-calls.jsonl"
printf '[]\n' > "$test_env_root/issues.json"
: > "$test_env_root/comments.jsonl"
printf '7001\n' > "$test_env_root/next-number"
printf '[]\n' > "$test_env_root/merged-prs.json"
ZF_GH_REPO=test/repo ZF_REPO=example-maintainer/example-repo ZF_REPO_DIR="$publish_repo" ZF_ENGINE_DIR="$engine" \
  ZF_ISSUE_LOCK_DIR="$test_env_root/locks" RETRO_OUT_DIR="$test_env_root/publish-out" \
  AGENT_HOME="$eval_home" FAKE_EVAL_CALLS="$test_env_root/eval-calls.jsonl" \
  PATH="$fake_bin:$PATH" FAKE_ISSUES="$test_env_root/issues.json" FAKE_COMMENTS="$test_env_root/comments.jsonl" \
  FAKE_LABELS="$test_env_root/labels" FAKE_NEXT_NUMBER="$test_env_root/next-number" \
  python3 -B "$retro" publish "$publish_root" "$publish_repo" "$test_env_root/candidates.json"
jq -e 'length == 1 and (.[0].body | contains("first event evidence"))
  and (.[0].body | contains("Source: p1 events.jsonl line 1") and contains("Derived from: V1272"))
  and (([.[0].labels[].name] | index("needs-triage")) != null)' "$test_env_root/issues.json" >/dev/null \
  || { echo "retro.test.sh: duplicate candidates did not create exactly one issue:" >&2; cat "$test_env_root/issues.json" >&2; exit 1; }
[[ "$(wc -l < "$test_env_root/comments.jsonl" | tr -d ' ')" == 1 ]] \
  || { echo 'retro.test.sh: duplicate candidate did not append exactly one comment' >&2; cat "$test_env_root/comments.jsonl" >&2; exit 1; }
jq -e '.body | contains("second event evidence")' "$test_env_root/comments.jsonl" >/dev/null \
  || { echo 'retro.test.sh: duplicate candidate comment omitted its evidence' >&2; cat "$test_env_root/comments.jsonl" >&2; exit 1; }
echo "publish dedupe rc=0"
jq -s -e '
  ([.[] | select(.kind == "run")] | length == 8) and
  ([.[] | select(.kind == "compare")] | length == 4) and
  all(.[] | select(.kind == "run");
    if (.label | startswith("retro-base-")) then .fragment == ""
    else (.label | startswith("retro-cand-")) and (.fragment | length > 0) end) and
  all(.[] | select(.kind == "compare");
    (.baseline | startswith("retro-base-")) and
    (.candidate | startswith("retro-cand-")) and
    (.baseline | ltrimstr("retro-base-")) == (.candidate | ltrimstr("retro-cand-")))
' "$test_env_root/eval-calls.jsonl" >/dev/null \
  || { echo 'retro.test.sh: candidate evals did not use exact paired labels and one default case set' >&2; cat "$test_env_root/eval-calls.jsonl" >&2; exit 1; }
# (a) Every merged retro change is recorded: the intake issue and the lesson fragment alike.
jq -e '.changes | length == 2
  and any(.[]; .issue == 7001 and .category == "navigation" and (.filed_at | type == "string")
    and .lineage_id != null and .derived_from == ["V1272"]
    and .sources == [{session_key:"p1",event_line:1},{session_key:"p2",event_line:1}])
  and any(.[]; .category == "automated-checks" and .verifiable == true and (.lesson | type == "string")
    and .sources == [{session_key:"p1",event_line:1}] and .derived_from == ["V1272"]
    and .engine_version == "engine-a" and .check == {type:"failure",message:"same event"}
    and (.admission.normal_sessions | length == 10) and .admission.paired_eval.status == "passed")' \
  "$test_env_root/publish-out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: candidate issue was not recorded for verification:" >&2; cat "$test_env_root/publish-out/retro-verify.json" >&2; exit 1; }
fragment="$(printf '%s\n' "$publish_repo"/lessons/pending/*.json)"
[[ -f "$fragment" ]] || { echo 'retro.test.sh: mechanical candidate created no lesson fragment' >&2; exit 1; }
jq -e '.check == {type:"failure",message:"same event"} and .engine_version == "engine-a" and .derived_from == ["V1272"]
  and .source_event == {session_key:"p1",event_line:1} and .admission.matched_normal_events == 0
  and .admission.paired_eval.regressions == 0' "$fragment" >/dev/null \
  || { echo 'retro.test.sh: admitted fragment omitted its matcher, lineage or measurement' >&2; cat "$fragment" >&2; exit 1; }
jq -e '.observations | length == 5
  and any(.[]; .source_event.session_key == "p3" and (.reason | contains("no check matcher")))
  and any(.[]; .source_event.session_key == "p4" and (.reason | contains("normal session")))
  and any(.[]; .source_event.session_key == "p5" and (.reason | contains("pass-to-fail regression")))
  and any(.[]; .source_event.session_key == "p6" and (.reason | contains("labels do not match candidate id")))
  and any(.[]; .source_event.session_key == "p7" and (.reason | contains("unpaired case")))' \
  "$test_env_root/publish-out/retro-verify.json" >/dev/null \
  || { echo 'retro.test.sh: an unmeasurable candidate was not retained as an observation' >&2; cat "$test_env_root/publish-out/retro-verify.json" >&2; exit 1; }
lesson_id="$(jq -r '.changes[] | select(.category == "automated-checks") | .lesson' "$test_env_root/publish-out/retro-verify.json")"
filed_at="$(jq -r --arg lesson "$lesson_id" '.changes[] | select(.lesson == $lesson) | .filed_at' "$test_env_root/publish-out/retro-verify.json")"
printf 'engine-b\n' > "$publish_root/luna/p1/engine-version"
jq '{candidates:[.candidates[] | select(.category == "automated-checks") | .check={message:"same event"}]}' \
  "$test_env_root/candidates.json" > "$test_env_root/changed-lesson-candidate.json"
ZF_GH_REPO=test/repo ZF_REPO=example-maintainer/example-repo ZF_REPO_DIR="$publish_repo" ZF_ENGINE_DIR="$engine" \
  ZF_ISSUE_LOCK_DIR="$test_env_root/locks" RETRO_OUT_DIR="$test_env_root/publish-out" \
  PATH="$fake_bin:$PATH" FAKE_ISSUES="$test_env_root/issues.json" FAKE_COMMENTS="$test_env_root/comments.jsonl" \
  FAKE_LABELS="$test_env_root/labels" FAKE_NEXT_NUMBER="$test_env_root/next-number" \
  python3 -B "$retro" publish "$publish_root" "$publish_repo" "$test_env_root/changed-lesson-candidate.json"
jq -e --arg lesson "$lesson_id" --arg filed "$filed_at" \
  '.changes[] | select(.lesson == $lesson) | .engine_version == "engine-a"
    and .check == {type:"failure",message:"same event"} and .filed_at == $filed' \
  "$test_env_root/publish-out/retro-verify.json" >/dev/null \
  || { echo 'retro.test.sh: an existing lesson admission was rewritten' >&2; cat "$test_env_root/publish-out/retro-verify.json" >&2; exit 1; }
printf 'engine-a\n' > "$publish_root/luna/p1/engine-version"
python3 -B "$retro" lineage "$publish_repo" "$test_env_root/publish-out" > "$test_env_root/lineage.txt"
grep -Fq 'V1272' "$test_env_root/lineage.txt" || { echo 'retro.test.sh: lineage context omitted the existing lesson id' >&2; cat "$test_env_root/lineage.txt" >&2; exit 1; }
grep -Fq "$lesson_id" "$test_env_root/lineage.txt" || { echo 'retro.test.sh: lineage context omitted the admitted candidate id' >&2; cat "$test_env_root/lineage.txt" >&2; exit 1; }
printf '%s\n' '{"incidents":[]}' > "$publish_repo/registry.json"
ZF_REPO_DIR="$publish_repo" ZF_ENGINE_DIR="$engine" ZF_CONFIG_ROOT="$publish_repo/.zenoforge" \
  bash "$engine/lesson-fragments.sh" --check "$publish_repo" "$publish_repo/registry.json" --files "$fragment"
echo "publish fragment accepted rc=0"
jq --arg lesson "$lesson_id" '(.changes[] | select(.lesson == $lesson)).verdict = "withdrawn"' \
  "$test_env_root/publish-out/retro-verify.json" > "$test_env_root/publish-out/retro-verify.next.json"
mv "$test_env_root/publish-out/retro-verify.next.json" "$test_env_root/publish-out/retro-verify.json"
jq '{candidates:[.candidates[] | select(.category == "automated-checks")]}' \
  "$test_env_root/candidates.json" > "$test_env_root/withdrawn-candidate.json"
rm -f -- "$publish_repo/lessons/pending/$lesson_id.json" "$publish_repo/lessons/full/$lesson_id.md"
ZF_GH_REPO=test/repo ZF_REPO=example-maintainer/example-repo ZF_REPO_DIR="$publish_repo" ZF_ENGINE_DIR="$engine" \
  ZF_ISSUE_LOCK_DIR="$test_env_root/locks" RETRO_OUT_DIR="$test_env_root/publish-out" \
  PATH="$fake_bin:$PATH" FAKE_ISSUES="$test_env_root/issues.json" FAKE_COMMENTS="$test_env_root/comments.jsonl" \
  FAKE_LABELS="$test_env_root/labels" FAKE_NEXT_NUMBER="$test_env_root/next-number" \
  python3 -B "$retro" publish "$publish_root" "$publish_repo" "$test_env_root/withdrawn-candidate.json"
test ! -e "$publish_repo/lessons/pending/$lesson_id.json"
test ! -e "$publish_repo/lessons/full/$lesson_id.md"
echo "publish withdrawn lesson stays removed rc=0"

short_root="$test_env_root/short-scratch"
short_repo="$test_env_root/short-repo"
mkdir -p "$short_root/luna/source" "$short_root/luna/normal" "$short_repo/lessons"
printf '%s\n' '{"type":"failure","message":"short sample"}' > "$short_root/luna/source/events.jsonl"
printf 'engine-a\n' > "$short_root/luna/source/engine-version"
printf '0\n' > "$short_root/luna/normal/rc"
printf '%s\n' '{"type":"item.completed"}' > "$short_root/luna/normal/events.jsonl"
printf '%s\n' '**V1272** Existing lesson.' > "$short_repo/lessons/RULES.md"
cat > "$test_env_root/short-candidate.json" <<'JSON'
{"candidates":[{"category":"automated-checks","severity":"high","session_key":"source","event_line":1,
  "evidence":"only one normal session is available","proposal":"Add a measured check","check":{"type":"failure","message":"short sample"},"derived_from":["V1272"]}]}
JSON
RETRO_OUT_DIR="$test_env_root/short-out" python3 -B "$retro" publish "$short_root" "$short_repo" "$test_env_root/short-candidate.json"
test ! -d "$short_repo/lessons/pending" || { echo 'retro.test.sh: a candidate with too few normal sessions was loaded' >&2; exit 1; }
jq -e '.observations | length == 1 and .[0].reason == "only 1 of 10 normal sessions is available"' \
  "$test_env_root/short-out/retro-verify.json" >/dev/null \
  || { echo 'retro.test.sh: insufficient samples were not retained as an observation' >&2; cat "$test_env_root/short-out/retro-verify.json" >&2; exit 1; }

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
  printf 'engine-a\n' > "$d/engine-version"
  printf '0\n' > "$d/rc"
  printf '%s\n' '{"type":"item.completed"}' '{"type":"tool.event"}' '{"type":"unrelated"}' '{"type":"item.completed"}' > "$d/events.jsonl"
  touch -d "@$((merge_epoch - 10 + i))" "$d/rc"
done
for i in $(seq 0 9); do
  id="$(printf '%02d' "$i")"
  d="$verify_root/luna/a$id"
  mkdir -p "$d"
  printf 'engine-a\n' > "$d/engine-version"
  printf '0\n' > "$d/rc"
  printf '%s\n' '{"type":"item.completed"}' '{"type":"tool.event"}' '{"type":"unrelated"}' '{"type":"item.completed"}' > "$d/events.jsonl"
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
{"changes":[
 {"issue":9001,"category":"navigation","class":"navigation-retract-fixture","lineage_id":"navigation-retract-fixture"},
 {"issue":9002,"category":"navigation","class":"candidate-9002","lineage_id":"candidate-9002","derived_from":["navigation-retract-fixture"],"verifiable":false},
 {"issue":9003,"category":"navigation","class":"candidate-9003","lineage_id":"candidate-9003","derived_from":["candidate-9002"],"verifiable":false}
]}
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
  and (.body | contains("3 events in 10 sessions") and contains("4 events in 10 sessions")
    and contains("#9002") and contains("#9003")))' \
  "$test_env_root/issues.json" >/dev/null \
  || { echo "retro.test.sh: no retract-or-rewrite issue included both counts:" >&2; cat "$test_env_root/issues.json" >&2; exit 1; }
echo "verification before/after rc=0"

# Every later verify invocation reuses the fake gh; per-scenario overrides win.
run_verify() {
  ZF_GH_REPO=test/repo ZF_REPO=example-maintainer/example-repo ZF_REPO_DIR="${VERIFY_REPO:-$publish_repo}" ZF_ENGINE_DIR="$engine" \
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
jq -e --arg merged "$merge_at" '.changes[0] | .merged_at == $merged and .before_count == 3 and .after_count == 4' \
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

jq -n '{changes:[
  {issue:9105,category:"navigation",class:"navigation-gh-failure-first"},
  {issue:9106,category:"navigation",class:"navigation-after-gh-failure"}
]}' > "$verify_out/retro-verify.json"
jq -c '.changes[0]' "$verify_out/retro-verify.json" > "$test_env_root/first-change.before.json"
later_out="$(FAKE_ISSUE_VIEW_FAILURE_ISSUE=9105 run_verify "$verify_root" "$verify_out")"
[[ "$later_out" == *"issue #9105"*"retrying next run"* ]] \
  || { echo "retro.test.sh: a failing first issue did not print its retry line:" >&2; printf '%s\n' "$later_out" >&2; exit 1; }
jq -c '.changes[0]' "$verify_out/retro-verify.json" > "$test_env_root/first-change.after.json"
cmp "$test_env_root/first-change.before.json" "$test_env_root/first-change.after.json" \
  || { echo "retro.test.sh: a failing first change was rewritten:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
jq -e --arg merged "$merge_at" '.changes[1] | .merged_at == $merged and .before_count == 3 and .after_count == 4
  and (.reported_at | type == "string")' "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: a later change was not verified after the first failed:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
echo "verification continues after gh-failure rc=0"

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
printf '{"candidates":[]}\n' > "$verify_out/before.candidates.json"
printf '{"candidates":[]}\n' > "$verify_out/after.candidates.json"
issues_before="$(jq 'length' "$test_env_root/issues.json")"
jq -n '{changes:[{issue:9106,category:"navigation",class:"navigation-empty-fixture",merged_at:"2026-01-01T00:00:00Z"}]}' \
  > "$verify_out/retro-verify.json"
run_verify "$verify_root" "$verify_out"
jq -e '.changes[0] | .before_count == 0 and .after_count == 0
  and (.reported_at | type == "string") and (.inconclusive_at | type == "string")
  and (has("retraction_filed_at") | not)' "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: a zero count was not recorded as inconclusive:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
jq -s 'any(.[]; .number == 9106 and ((.body | split("\\n") | map(select(length > 0)) | last) == "Verdict: inconclusive (no events in either window)"))' \
  "$test_env_root/comments.jsonl" >/dev/null \
  || { echo "retro.test.sh: the zero-count verdict was missing from the issue comment:" >&2; cat "$test_env_root/comments.jsonl" >&2; exit 1; }
inconclusive_at="$(jq -r '.changes[0].inconclusive_at' "$verify_out/retro-verify.json")"
run_verify "$verify_root" "$verify_out"
jq -e --arg timestamp "$inconclusive_at" '.changes[0] | .inconclusive_at == $timestamp' \
  "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: the inconclusive timestamp was rewritten:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
jq -e --argjson expected "$issues_before" 'length == $expected' "$test_env_root/issues.json" >/dev/null \
  || { echo "retro.test.sh: an inconclusive change opened a retraction issue:" >&2; cat "$test_env_root/issues.json" >&2; exit 1; }
jq -s 'map(select(.number == 9106)) | length == 1' "$test_env_root/comments.jsonl" >/dev/null \
  || { echo "retro.test.sh: the inconclusive issue comment was duplicated:" >&2; cat "$test_env_root/comments.jsonl" >&2; exit 1; }
echo "verification zero-count-inconclusive rc=0"
cat > "$verify_out/after.candidates.json" <<'JSON'
{"candidates":[
 {"category":"navigation","severity":"high","session_key":"a00","event_line":1,"evidence":"e","proposal":"p"},
 {"category":"navigation","severity":"high","session_key":"a01","event_line":1,"evidence":"e","proposal":"p"}
]}
JSON
jq -n '{changes:[{issue:9107,category:"navigation",class:"navigation-rise-fixture",merged_at:"2026-01-01T00:00:00Z"}]}' \
  > "$verify_out/retro-verify.json"
run_verify "$verify_root" "$verify_out"
jq -e '.changes[0] | .before_count == 0 and .after_count == 2
  and (.reported_at | type == "string") and (.retraction_filed_at | type == "string")
  and (has("inconclusive_at") | not)' "$verify_out/retro-verify.json" >/dev/null \
  || { echo "retro.test.sh: a count rising from zero was not retracted:" >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
jq -e --argjson expected "$((issues_before + 1))" 'length == $expected' "$test_env_root/issues.json" >/dev/null \
  || { echo "retro.test.sh: a zero-to-two change did not open a retraction issue:" >&2; cat "$test_env_root/issues.json" >&2; exit 1; }
echo "verification zero-to-two-retracted rc=0"
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
lesson_repo="$test_env_root/lesson-repo"
mkdir -p "$lesson_repo/lessons/pending" "$lesson_repo/lessons/full"
cat > "$lesson_repo/lessons/RULES.md" <<'DOC'
# Rules

<a id="v-next-automated-regress"></a>
**V-NEXT-automated-regress** Withdraw this lesson.

<a id="v-next-tool-keep"></a>
**V-NEXT-tool-keep** Keep this lesson.
DOC
cat > "$lesson_repo/lessons/CATALOG.md" <<'DOC'
# Catalog

Applies: [V-NEXT-automated-regress](RULES.md#v-next-automated-regress)
Applies: [V-NEXT-tool-keep](RULES.md#v-next-tool-keep)
DOC
printf 'regressing lesson\n' > "$lesson_repo/lessons/full/automated-regress.md"
printf 'non-regressing lesson\n' > "$lesson_repo/lessons/full/tool-keep.md"
printf '{"id":"automated-regress"}\n' > "$lesson_repo/lessons/pending/automated-regress.json"
printf '{"id":"tool-keep"}\n' > "$lesson_repo/lessons/pending/tool-keep.json"
cat > "$verify_out/before.candidates.json" <<'JSON'
{"candidates":[
 {"category":"automated-checks","severity":"high","session_key":"b00","event_line":1,"evidence":"e","proposal":"p","check":{"type":"item.completed"}},
 {"category":"automated-checks","severity":"high","session_key":"b00","event_line":3,"evidence":"e","proposal":"p","check":{"type":"unrelated"}},
 {"category":"automated-checks","severity":"high","session_key":"b01","event_line":1,"evidence":"e","proposal":"p","check":{"type":"item.completed"}},
 {"category":"automated-checks","severity":"high","session_key":"b01","event_line":3,"evidence":"e","proposal":"p","check":{"type":"unrelated"}},
 {"category":"automated-checks","severity":"high","session_key":"b02","event_line":1,"evidence":"e","proposal":"p","check":{"type":"item.completed"}},
 {"category":"automated-checks","severity":"high","session_key":"b02","event_line":3,"evidence":"e","proposal":"p","check":{"type":"unrelated"}},
 {"category":"tool-economy","severity":"high","session_key":"b00","event_line":2,"evidence":"e","proposal":"p","check":{"type":"tool.event"}},
 {"category":"tool-economy","severity":"high","session_key":"b01","event_line":2,"evidence":"e","proposal":"p","check":{"type":"tool.event"}},
 {"category":"tool-economy","severity":"high","session_key":"b02","event_line":2,"evidence":"e","proposal":"p","check":{"type":"tool.event"}}
]}
JSON
cat > "$verify_out/after.candidates.json" <<'JSON'
{"candidates":[
 {"category":"automated-checks","severity":"high","session_key":"a00","event_line":1,"evidence":"e","proposal":"p","check":{"type":"item.completed"}},
 {"category":"automated-checks","severity":"high","session_key":"a01","event_line":1,"evidence":"e","proposal":"p","check":{"type":"item.completed"}},
 {"category":"automated-checks","severity":"high","session_key":"a02","event_line":1,"evidence":"e","proposal":"p","check":{"type":"item.completed"}},
 {"category":"automated-checks","severity":"high","session_key":"a03","event_line":1,"evidence":"e","proposal":"p","check":{"type":"item.completed"}},
 {"category":"tool-economy","severity":"high","session_key":"a00","event_line":2,"evidence":"e","proposal":"p","check":{"type":"tool.event"}}
]}
JSON
touch -d "@$((merge_epoch - 20))" "$verify_out/before.keys" "$verify_out/before.candidates.json"
touch -d "@$((merge_epoch + 20))" "$verify_out/after.keys" "$verify_out/after.candidates.json"
jq -n --arg filed "$merge_at" '{changes:[
  {lesson:"automated-regress",category:"automated-checks",class:"automated-regress",filed_at:$filed,
    engine_version:"engine-a",check:{type:"item.completed"},verifiable:false,admission:{status:"passed"}},
  {lesson:"tool-keep",category:"tool-economy",class:"tool-keep",filed_at:$filed,
    engine_version:"engine-a",check:{type:"tool.event"},verifiable:false,admission:{status:"passed"}}
]}' > "$verify_out/retro-verify.json"
VERIFY_REPO="$lesson_repo" run_verify "$verify_root" "$verify_out"
printf 'regressing lesson restored by checkout\n' > "$lesson_repo/lessons/full/automated-regress.md"
printf '{"id":"automated-regress"}\n' > "$lesson_repo/lessons/pending/automated-regress.json"
cat >> "$lesson_repo/lessons/RULES.md" <<'DOC'

<a id="v-next-automated-regress"></a>
**V-NEXT-automated-regress** Withdraw this lesson.
DOC
cat >> "$lesson_repo/lessons/CATALOG.md" <<'DOC'
Applies: [V-NEXT-automated-regress](RULES.md#v-next-automated-regress)
DOC
VERIFY_REPO="$lesson_repo" run_verify "$verify_root" "$verify_out"
jq -e '.changes | any(.[]; .lesson == "automated-regress" and .before_count == 3 and .after_count == 4
    and .verdict == "withdrawn" and (.withdrawn_at | type == "string"))
  and any(.[]; .lesson == "tool-keep" and .before_count == 3 and .after_count == 1
    and .verdict == "retained" and (has("withdrawn_at") | not))' \
  "$verify_out/retro-verify.json" >/dev/null \
  || { echo 'retro.test.sh: engine-version lesson verification recorded the wrong verdicts' >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
jq -e '.events | length == 1 and .[0].type == "lesson-withdrawn"
  and .[0].lesson == "automated-regress" and .[0].engine_version == "engine-a"
  and .[0].before_count == 3 and .[0].after_count == 4' \
  "$verify_out/retro-verify.json" >/dev/null \
  || { echo 'retro.test.sh: lesson withdrawal event was not recorded' >&2; cat "$verify_out/retro-verify.json" >&2; exit 1; }
test ! -e "$lesson_repo/lessons/pending/automated-regress.json"
test ! -e "$lesson_repo/lessons/full/automated-regress.md"
! grep -Fq 'V-NEXT-automated-regress' "$lesson_repo/lessons/RULES.md"
! grep -Fq 'V-NEXT-automated-regress' "$lesson_repo/lessons/CATALOG.md"
test -e "$lesson_repo/lessons/pending/tool-keep.json"
test -e "$lesson_repo/lessons/full/tool-keep.md"
grep -Fq 'V-NEXT-tool-keep' "$lesson_repo/lessons/RULES.md"
grep -Fq 'V-NEXT-tool-keep' "$lesson_repo/lessons/CATALOG.md"
echo "verification engine-version lesson-withdrawal rc=0"
echo 'retro.test.sh: all assertions passed'
