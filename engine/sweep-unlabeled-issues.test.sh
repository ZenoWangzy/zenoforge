#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf -- "$TEST_HOME"' EXIT
export AGENT_HOME="$TEST_HOME/agent" REPO=test/repo
export FAKE_ISSUES_FILE="$TEST_HOME/issues.json" FAKE_GH_LOG="$TEST_HOME/gh.log"
export FAIL_STATE_MERGE_FILE="$TEST_HOME/fail-state-merge"
export FAIL_STATE_MERGE_NUMBER=""
export FAIL_ISSUE_EDIT_NUMBER=""
export REAL_FLOCK="$(command -v flock)"
mkdir -p "$AGENT_HOME/state" "$TEST_HOME/bin"
# Stage-routing fixture; roadmap admission is covered by roadmap-order.test.sh.
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
: >"$AGENT_HOME/supervisor-inbox"
printf '%s\n' '{"maintainer_login":"maintainer"}' >"$AGENT_HOME/recipients.json"
printf '%s\n' bug enhancement >"$TEST_HOME/labels.txt"
export FAKE_LABELS_FILE="$TEST_HOME/labels.txt"
cat >"$FAKE_ISSUES_FILE" <<'JSON'
[
  {"number":7101,"state":"OPEN","labels":[{"name":"bug"}]},
  {"number":7102,"state":"OPEN","labels":[{"name":"on-hold"}]},
  {"number":7103,"state":"OPEN","labels":[{"name":"enhancement"}]},
  {"number":7104,"state":"CLOSED","labels":[{"name":"bug"}]},
  {"number":7105,"state":"OPEN","labels":[{"name":"future-state-fixture"}]},
  {"number":7107,"state":"OPEN","labels":[{"name":"bug"}]},
  {"number":7109,"state":"OPEN","labels":[{"name":"bug"}]},
  {"number":7112,"state":"OPEN","labels":[{"name":"bug"}],"pull_request":{"url":"https://example.test/pull/7112"}}
]
JSON
printf '%s\n' '{"recut_children":[8001]}' >"$AGENT_HOME/state/7103.json"
printf '%s\n' '{invalid state' >"$AGENT_HOME/state/7107.json"

cat >"$TEST_HOME/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1" == api ]]; then
  [[ " $* " == *" --paginate "* ]] || { echo "gh api missing --paginate" >&2; exit 2; }
  jq -c '[.[] | select(.state == "OPEN") | {number, state:"open", labels, user:{login:(.author.login // "other")}, title:(.title // ""), body:(.body // ""), created_at:(.createdAt // "")} + (if has("pull_request") then {pull_request} else {} end)] | [range(0; length; 100) as $start | .[$start:($start + 100)]]' "$FAKE_ISSUES_FILE"
  exit 0
fi
if [[ "$1 $2" == 'issue list' ]]; then
  label="" search="" state="open" limit=1000
  while (($#)); do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --search) search="$2"; shift 2 ;;
      --state) state="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$label" ]]; then
    jq -r --arg want_label "$label" --arg state "$state" --argjson limit "$limit" '
      [.[] | select(has("pull_request") | not)
      | select(($state == "all") or ($state == "open" and .state == "OPEN") or ($state == "closed" and .state == "CLOSED"))
      | select(any(.labels[]?; .name == $want_label)) | .number] | .[:$limit] | .[]
    ' "$FAKE_ISSUES_FILE"
  else
    jq -r --arg state "$state" --arg search "$search" --argjson limit "$limit" '
      [($search | split(" ")[] | select(startswith("-label:")) | ltrimstr("-label:"))] as $excluded
      | [.[] as $issue
        | select($issue | has("pull_request") | not)
        | select(($state == "all") or ($state == "open" and $issue.state == "OPEN") or ($state == "closed" and $issue.state == "CLOSED"))
        | select(all($excluded[]; . as $name | ([$issue.labels[]?.name] | index($name)) == null))
        | $issue.number] | .[:$limit] | .[]
    ' "$FAKE_ISSUES_FILE"
  fi
  exit 0
fi
if [[ "$1 $2" == 'issue view' ]]; then
  number="$3" query=""
  args=("$@")
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "-q" ]]; then query="${args[$((i+1))]}"; fi
  done
  if ((number >= 7200 && number < 8200)); then
    if [[ "$query" == ".labels[].name" ]]; then
      echo on-hold
    elif [[ "$query" == ".state" ]]; then
      echo CLOSED
    else
      echo '{"state":"CLOSED","labels":[{"name":"on-hold"}]}'
    fi
    exit 0
  fi
  if [[ "$query" == ".labels[].name" ]]; then
    jq -r --argjson n "$number" '.[] | select(.number == $n) | .labels[]?.name' "$FAKE_ISSUES_FILE"
  elif [[ "$query" == ".state" ]]; then
    jq -r --argjson n "$number" '.[] | select(.number == $n) | .state' "$FAKE_ISSUES_FILE"
  else
    jq -c --argjson n "$number" '.[] | select(.number == $n) | {number,state,labels,title:(.title // ""),body:(.body // ""),author:(.author // {login:"other"}),comments:(.comments // [])}' "$FAKE_ISSUES_FILE"
  fi
  exit 0
fi
if [[ "$1 $2" == 'label list' ]]; then
  cat "$FAKE_LABELS_FILE"
  exit 0
fi
if [[ "$1 $2" == 'label create' ]]; then
  printf '%s\n' "$3" >>"$FAKE_LABELS_FILE"
  exit 0
fi
if [[ "$1 $2" == 'issue edit' ]]; then
  number="$3" adds=() removes=()
  shift 3
  while (($#)); do
    case "$1" in
      --add-label) adds+=("$2"); shift 2 ;;
      --remove-label) removes+=("$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$number" = "$FAIL_ISSUE_EDIT_NUMBER" ]; then exit 73; fi
  if [ "$number" = 7109 ]; then
    jq 'map(if .number == 7109 then .labels += [{"name":"needs-recut"}] else . end)' \
      "$FAKE_ISSUES_FILE" >"$FAKE_ISSUES_FILE.tmp"
    mv "$FAKE_ISSUES_FILE.tmp" "$FAKE_ISSUES_FILE"
  fi
  remove_json="$(printf '%s\n' "${removes[@]}" | jq -R . | jq -s .)"
  add_json="$(printf '%s\n' "${adds[@]}" | jq -R . | jq -s .)"
  jq --argjson n "$number" --argjson removes "$remove_json" --argjson adds "$add_json" '
    map(if .number == $n then
      .labels = ([.labels[]? | select(.name as $name | ($removes | index($name)) == null)]
        + [$adds[] | {name:.}])
    else . end)
  ' "$FAKE_ISSUES_FILE" >"$FAKE_ISSUES_FILE.tmp"
  mv "$FAKE_ISSUES_FILE.tmp" "$FAKE_ISSUES_FILE"
  if [ "$number" = "$FAIL_STATE_MERGE_NUMBER" ]; then touch "$FAIL_STATE_MERGE_FILE"; fi
  exit 0
fi
echo "unexpected fake gh invocation: $*" >&2
exit 1
FAKE_GH
chmod +x "$TEST_HOME/bin/gh"
cat >"$TEST_HOME/bin/flock" <<'FAKE_FLOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ -e "$FAIL_STATE_MERGE_FILE" ]]; then
  rm -f "$FAIL_STATE_MERGE_FILE"
  exit 1
fi
exec "$REAL_FLOCK" "$@"
FAKE_FLOCK
chmod +x "$TEST_HOME/bin/flock"
export PATH="$TEST_HOME/bin:$PATH"

# Dynamic label proves the query follows the shared array.
source "$SCRIPT_DIR/lib.sh"
ALL_STATE_LABELS+=(future-state-fixture)
FAKE_STATE_LABELS_JSON="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | jq -R . | jq -s .)"
export FAKE_STATE_LABELS_JSON

FAILED=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "ok - $desc"; else echo "not ok - $desc (expected [$expected], got [$actual])"; FAILED=1; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "ok - $desc"; else echo "not ok - $desc (missing [$needle])"; FAILED=1; fi
}

run_sweep() { sweep_unlabeled_issues 2>&1; }

fake_open_ids="$(gh issue list --repo "$REPO" --state open --json number -q '.[].number' | jq -R -s -r 'split("\n") | map(select(length > 0)) | join(",")')"
fake_all_ids="$(gh issue list --repo "$REPO" --state all --json number -q '.[].number' | jq -R -s -r 'split("\n") | map(select(length > 0)) | join(",")')"
fake_closed_ids="$(gh issue list --repo "$REPO" --state closed --json number -q '.[].number' | jq -R -s -r 'split("\n") | map(select(length > 0)) | join(",")')"
fake_without_dynamic_state="$(gh issue list --repo "$REPO" --state all --search '-label:future-state-fixture' --json number -q '.[].number' | jq -R -s -r 'split("\n") | map(select(length > 0)) | join(",")')"
assert_eq "fake gh honors open state filter" "7101,7102,7103,7105,7107,7109" "$fake_open_ids"
assert_eq "fake gh includes closed issues for all state" "7101,7102,7103,7104,7105,7107,7109" "$fake_all_ids"
assert_eq "fake gh honors closed state filter" 7104 "$fake_closed_ids"
assert_eq "fake gh applies candidate label exclusions" "7101,7102,7103,7104,7107,7109" "$fake_without_dynamic_state"

expect_hotfix_predicate() {
  local expected="$1" title="$2" labels="${3:-[]}" issue_json actual
  issue_json="$(jq -cn --arg title "$title" --argjson labels "$labels" '{title:$title,labels:$labels}')"
  if is_hotfix_lane_issue "$issue_json"; then actual=true; else actual=false; fi
  assert_eq "hotfix predicate: $title" "$expected" "$actual"
}
expect_hotfix_predicate true '[热修] repair'
expect_hotfix_predicate true '【热修】repair'
expect_hotfix_predicate true '[hotfix] repair'
expect_hotfix_predicate true '[HOT-FIX] repair'
expect_hotfix_predicate true '（紧急热修） repair'
expect_hotfix_predicate true 'ordinary title' '[{"name":"hotfix"}]'
expect_hotfix_predicate false 'First release after the 9/30 hot-fix chain: retire the stage'
expect_hotfix_predicate false '对齐生产热修插件与主干回归契约'
expect_hotfix_predicate false '员工安全重载期间自动重建容器并覆盖热修…'
expect_hotfix_predicate false 'This title mentions hotfix without a tag'

printf '%s\n' '[]' >"$FAKE_ISSUES_FILE"
run_sweep >/dev/null
assert_eq "empty tick emits no notice" 0 "$(wc -l <"$AGENT_HOME/supervisor-inbox")"

# The hot-fix mechanism closed on 2026-10-04: a marked needs-triage ticket stays in the pipeline.
cat >"$FAKE_ISSUES_FILE" <<'JSON'
[{"number":7119,"state":"OPEN","labels":[{"name":"bug"},{"name":"needs-triage"}],"title":"[hotfix] intake fixture"}]
JSON
printf '%s\n' '{}' >"$AGENT_HOME/state/7119.json"
: >"$FAKE_GH_LOG"
run_sweep >/dev/null
assert_eq "marked needs-triage issue keeps its pipeline stage" "bug,needs-triage" "$(jq -r '.[] | select(.number == 7119) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "marked intake issue is not held" "" "$(state_read 7119 | jq -r '.hold.holder // empty')"
assert_eq "marked intake writes no hotfix inbox line" 0 "$(grep -c hotfix-intake "$AGENT_HOME/supervisor-inbox" || true)"

# An existing hold belongs to its recorded owner and must not be overwritten.
cat >"$FAKE_ISSUES_FILE" <<'JSON'
[{"number":7120,"state":"OPEN","labels":[{"name":"on-hold"},{"name":"needs-triage"}],"title":"[热修] already held"}]
JSON
printf '%s\n' '{"state":"on-hold","hold":{"holder":"another owner","release_condition":"review","expires_at":"2099-01-01T00:00:00Z"}}' >"$AGENT_HOME/state/7120.json"
: >"$FAKE_GH_LOG"
run_sweep >/dev/null
assert_eq "marked issue keeps existing holder" 'another owner' "$(state_read 7120 | jq -r '.hold.holder')"
assert_eq "marked issue already held by someone else gets no rewrite" "" "$(grep '^issue edit 7120 ' "$FAKE_GH_LOG" || true)"

cat >"$FAKE_ISSUES_FILE" <<'JSON'
[
  {"number":7101,"state":"OPEN","labels":[{"name":"bug"}]},
  {"number":7102,"state":"OPEN","labels":[{"name":"on-hold"}]},
  {"number":7103,"state":"OPEN","labels":[{"name":"enhancement"}]},
  {"number":7104,"state":"CLOSED","labels":[{"name":"bug"}]},
  {"number":7105,"state":"OPEN","labels":[{"name":"future-state-fixture"}]},
  {"number":7107,"state":"OPEN","labels":[{"name":"bug"}]},
  {"number":7109,"state":"OPEN","labels":[{"name":"bug"}]},
  {"number":7113,"state":"OPEN","labels":[{"name":"bug"}],"author":{"login":"maintainer"},"title":"Mac demo repro","body":"Maintainer repro fixture"},
  {"number":7114,"state":"OPEN","labels":[{"name":"bug"}],"author":{"login":"maintainer"},"title":"Recut child","body":"Generated child","comments":[{"body":"<!-- zenoforge-agent-comment -->"}]},
  {"number":7115,"state":"OPEN","labels":[{"name":"bug"}],"author":{"login":"maintainer"},"title":"前置能力 [concluded-root-prerequisite-7101]: generated prerequisite","body":"Generated prerequisite"},
  {"number":7116,"state":"OPEN","labels":[{"name":"bug"}],"author":{"login":"maintainer"},"title":"Recut child before bot comment","body":"由 #7101 拆分而来的可独立交付子任务之一，会走正常的分诊流程判定风险等级和处理方式。"},
  {"number":7117,"state":"OPEN","labels":[{"name":"bug"}],"author":{"login":"maintainer"},"title":"[supervisor] HEALTH node owner brief","body":"Generated supervisor work"},
  {"number":7118,"state":"OPEN","labels":[{"name":"pipeline-system"},{"name":"needs-triage"}],"author":{"login":"maintainer"},"title":"Pipeline system task","body":"System lane work"}
]
JSON

printf '%s\n' '{"attempts":0}' >"$AGENT_HOME/state/7101.json"
run_sweep >/dev/null
labels_7101="$(jq -r '.[] | select(.number == 7101) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
labels_7109="$(jq -r '.[] | select(.number == 7109) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "ordinary open issue gets only needs-triage state" bug,needs-triage "$labels_7101"
assert_eq "second ordinary issue gets only needs-triage after stale-label race" bug,needs-triage "$labels_7109"
assert_eq "maintainer-filed issue gets maintainer-test during rescue" bug,maintainer-test,needs-triage "$(jq -r '.[] | select(.number == 7113) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_contains "maintainer rescue fetches issue number for the shared label helper" "$(grep -F 'issue view 7113 ' "$FAKE_GH_LOG")" '--json number,state,labels,title,body,author,comments'
assert_eq "pipeline bot marker excludes generated issue from maintainer-test" bug,needs-triage "$(jq -r '.[] | select(.number == 7114) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "prerequisite title marker excludes generated issue from maintainer-test" bug,needs-triage "$(jq -r '.[] | select(.number == 7115) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "recut body marker excludes generated issue before bot comment" bug,needs-triage "$(jq -r '.[] | select(.number == 7116) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "supervisor brief title excludes generated issue from maintainer-test" bug,needs-triage "$(jq -r '.[] | select(.number == 7117) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "pipeline-system issue keeps its lane without maintainer-test" needs-triage,pipeline-system "$(jq -r '.[] | select(.number == 7118) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
state_count="$(jq --argjson n 7101 --argjson states "$FAKE_STATE_LABELS_JSON" '[.[] | select(.number == $n) | .labels[].name | select(. as $name | $states | index($name) != null)] | length' "$FAKE_ISSUES_FILE")"
assert_eq "rescued issue has exactly one active state label" 1 "$state_count"
assert_contains "normalization removes terminal state added during write" "$(grep -F 'issue edit 7109 ' "$FAKE_GH_LOG")" '--remove-label needs-recut'
assert_contains "normalization removes dynamic shared state labels" "$(grep -F 'issue edit 7109 ' "$FAKE_GH_LOG")" '--remove-label future-state-fixture'
assert_eq "needs-triage is not paired with stale terminal label" false "$(jq -e '.[] | select(.number == 7109) | any(.labels[]; .name == "needs-recut")' "$FAKE_ISSUES_FILE" >/dev/null && echo true || echo false)"
assert_eq "on-hold issue labels unchanged" on-hold "$(jq -r '.[] | select(.number == 7102) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "recut umbrella labels unchanged" enhancement "$(jq -r '.[] | select(.number == 7103) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "closed issue labels unchanged" bug "$(jq -r '.[] | select(.number == 7104) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "dynamic state issue labels unchanged" future-state-fixture "$(jq -r '.[] | select(.number == 7105) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "unreadable local state labels unchanged" bug "$(jq -r '.[] | select(.number == 7107) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "on-hold issue received no edit" "" "$(grep -E '^issue edit 7102 ' "$FAKE_GH_LOG" || true)"
assert_eq "recut umbrella received no edit" "" "$(grep -E '^issue edit 7103 ' "$FAKE_GH_LOG" || true)"
assert_eq "closed issue received no edit" "" "$(grep -E '^issue edit 7104 ' "$FAKE_GH_LOG" || true)"
assert_eq "dynamic state issue received no edit" "" "$(grep -E '^issue edit 7105 ' "$FAKE_GH_LOG" || true)"
assert_eq "unreadable local state received no edit" "" "$(grep -E '^issue edit 7107 ' "$FAKE_GH_LOG" || true)"
assert_eq "open pull request is not treated as an issue" "" "$(grep -E '^issue edit 7112 ' "$FAKE_GH_LOG" || true)"
assert_eq "seven rescues yield one appearance notice" 1 "$(grep -c 'unlabeled-issue-sweep appear rescued=7' "$AGENT_HOME/supervisor-inbox")"

# A new issue during same episode is rescued, but does not repeat appearance.
jq '. + [{"number":7108,"state":"OPEN","labels":[{"name":"bug"}]}]' "$FAKE_ISSUES_FILE" >"$FAKE_ISSUES_FILE.tmp"
mv "$FAKE_ISSUES_FILE.tmp" "$FAKE_ISSUES_FILE"
printf '%s\n' '{}' >"$AGENT_HOME/state/7108.json"
run_sweep >/dev/null
assert_eq "persistent wave does not repeat appearance notice" 1 "$(grep -c 'unlabeled-issue-sweep appear' "$AGENT_HOME/supervisor-inbox")"

# Remove unreadable fixture from the candidate population; zero rescues clears once.
run_sweep >/dev/null
assert_eq "unreadable candidate does not clear alert episode" 0 "$(grep -c 'unlabeled-issue-sweep clear' "$AGENT_HOME/supervisor-inbox" || true)"
jq 'map(select(.number != 7107))' "$FAKE_ISSUES_FILE" >"$FAKE_ISSUES_FILE.tmp"
mv "$FAKE_ISSUES_FILE.tmp" "$FAKE_ISSUES_FILE"
run_sweep >/dev/null
assert_eq "resolved wave yields one clear notice" 1 "$(grep -c 'unlabeled-issue-sweep clear' "$AGENT_HOME/supervisor-inbox")"
run_sweep >/dev/null
assert_eq "quiet ticks do not repeat clear notice" 1 "$(grep -c 'unlabeled-issue-sweep clear' "$AGENT_HOME/supervisor-inbox")"

# The old `gh issue list --limit 1000` silently missed an eligible issue after
# the first thousand. Keep those first results on hold so the eligible
# sentinel beyond the boundary is the only issue the sweep should write.
jq -n '[range(7200; 8201) as $n | {number:$n,state:"OPEN",labels:(if $n < 8200 then [{name:"on-hold"}] else [{name:"bug"}] end)}]' >"$FAKE_ISSUES_FILE"
printf '%s\n' '{}' >"$AGENT_HOME/state/8200.json"
: >"$FAKE_GH_LOG"
: >"$AGENT_HOME/supervisor-inbox"; rm -f "$AGENT_HOME"/logs/supervisor-alert-seen-*.tsv
rm -f "$AGENT_HOME/unlabeled-issue-sweep-alerted"
run_sweep >/dev/null
assert_contains "sweep uses complete API pagination" "$(cat "$FAKE_GH_LOG")" 'api --paginate --slurp'
assert_contains "sweep reaches unlabeled issue after 1000 results" "$(cat "$FAKE_GH_LOG")" 'issue edit 8200'

# A successful GitHub label write must be reported even when the following
# local state merge fails and stops this sweep.
cat >"$FAKE_ISSUES_FILE" <<'JSON'
[{"number":7110,"state":"OPEN","labels":[{"name":"bug"}]}]
JSON
printf '%s\n' '{"attempts":0}' >"$AGENT_HOME/state/7110.json"
FAIL_STATE_MERGE_NUMBER=7110
: >"$FAKE_GH_LOG"
: >"$AGENT_HOME/supervisor-inbox"; rm -f "$AGENT_HOME"/logs/supervisor-alert-seen-*.tsv
rm -f "$AGENT_HOME/unlabeled-issue-sweep-alerted"
if bash -e -u -o pipefail -c 'source "$1/lib.sh"; sweep_unlabeled_issues' _ "$SCRIPT_DIR" >"$TEST_HOME/partial-write.log" 2>&1; then
  partial_write_rc=0
else
  partial_write_rc=$?
fi
FAIL_STATE_MERGE_NUMBER=""
assert_eq "state merge failure still returns failure" 1 "$partial_write_rc"
assert_eq "successful label write remains applied" "bug,needs-triage" "$(jq -r '.[] | select(.number == 7110) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "successful label write emits appearance notice before failure" 1 "$(grep -c 'unlabeled-issue-sweep appear rescued=1' "$AGENT_HOME/supervisor-inbox" || true)"

# A later GitHub edit failure must still report earlier successful rescues.
cat >"$FAKE_ISSUES_FILE" <<'JSON'
[
  {"number":7110,"state":"OPEN","labels":[{"name":"bug"}]},
  {"number":7111,"state":"OPEN","labels":[{"name":"bug"}]}
]
JSON
printf '%s\n' '{}' >"$AGENT_HOME/state/7110.json"
printf '%s\n' '{}' >"$AGENT_HOME/state/7111.json"
: >"$FAKE_GH_LOG"
: >"$AGENT_HOME/supervisor-inbox"; rm -f "$AGENT_HOME"/logs/supervisor-alert-seen-*.tsv
rm -f "$AGENT_HOME/unlabeled-issue-sweep-alerted"
FAIL_ISSUE_EDIT_NUMBER=7111
set +e
bash -e -u -o pipefail -c 'source "$1/lib.sh"; sweep_unlabeled_issues' _ "$SCRIPT_DIR" >"$TEST_HOME/partial-edit.log" 2>&1
partial_edit_rc=$?
set -e
FAIL_ISSUE_EDIT_NUMBER=""
assert_eq "later issue edit failure returns failure" 1 "$partial_edit_rc"
assert_eq "earlier successful rescue remains applied" "bug,needs-triage" "$(jq -r '.[] | select(.number == 7110) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "failed issue edit leaves later issue unchanged" bug "$(jq -r '.[] | select(.number == 7111) | [.labels[].name] | sort | join(",")' "$FAKE_ISSUES_FILE")"
assert_eq "earlier rescue reported before later issue edit failure" 1 "$(grep -c 'unlabeled-issue-sweep appear rescued=1' "$AGENT_HOME/supervisor-inbox" || true)"

maintenance_fn="$(sed -n '/^run_post_dispatch_maintenance() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
reopen_line="$(grep -nF 'sweep_reopened_issues' <<< "$maintenance_fn" | head -1 | cut -d: -f1)"
unlabeled_line="$(grep -nF 'sweep_unlabeled_issues' <<< "$maintenance_fn" | head -1 | cut -d: -f1)"
assert_eq "post-dispatch maintenance recovers reopened issues before unlabeled sweep" true \
  "$([[ -n "$reopen_line" && -n "$unlabeled_line" && "$reopen_line" -lt "$unlabeled_line" ]] && echo true || echo false)"

# 2026-09-27: one failed maintainer-test re-read (gateway 504) aborted the whole
# scheduler tick. A read failure must skip that issue, not fail the list.
candidates='[{"number":7201,"state":"OPEN","labels":[{"name":"ready-for-agent"}],"author":{"login":"maintainer"},"title":"Maintainer repro","body":"repro"},{"number":7202,"state":"OPEN","labels":[{"name":"ready-for-agent"}],"author":{"login":"other"},"title":"Other","body":"x"}]'
mkdir -p "$TEST_HOME/failing-gh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "Gateway Timeout" >&2; exit 1' >"$TEST_HOME/failing-gh/gh"
chmod +x "$TEST_HOME/failing-gh/gh"
labelled="$(PATH="$TEST_HOME/failing-gh:$PATH" label_maintainer_test_candidates "$candidates")" && read_rc=0 || read_rc=$?
assert_eq "maintainer-test re-read failure does not fail the candidate list" 0 "$read_rc"
assert_eq "unreadable maintainer candidate is kept unlabelled for the next tick" 2 "$(jq 'length' <<< "$labelled")"

# 2026-09-27: every maintainer-authored open issue was re-read with comments on every
# tick (203 issues, 17+ min per tick). Only issues inside the intake window are
# candidates, and an issue already judged is not re-read.
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg now "$now_iso" '. + [
  {"number":7120,"state":"OPEN","labels":[{"name":"ready-for-agent"}],"author":{"login":"maintainer"},"title":"Old pipeline ticket","body":"old","createdAt":"2026-01-01T00:00:00Z"},
  {"number":7121,"state":"OPEN","labels":[{"name":"ready-for-agent"}],"author":{"login":"maintainer"},"title":"New generated ticket","body":"generated <!-- zenoforge-agent-comment -->","createdAt":$now}
]' "$FAKE_ISSUES_FILE" > "$FAKE_ISSUES_FILE.tmp" && mv "$FAKE_ISSUES_FILE.tmp" "$FAKE_ISSUES_FILE"
: > "$FAKE_GH_LOG"
run_sweep >/dev/null
assert_eq "old maintainer-authored issue outside the intake window is not re-read" 0 "$(grep -c 'issue view 7120 ' "$FAKE_GH_LOG" || true)"
assert_eq "new maintainer-authored issue inside the window is judged once" 1 "$(grep -c 'issue view 7121 ' "$FAKE_GH_LOG" || true)"
: > "$FAKE_GH_LOG"
run_sweep >/dev/null
assert_eq "an already judged maintainer-authored issue is not re-read" 0 "$(grep -c 'issue view 7121 ' "$FAKE_GH_LOG" || true)"

# 2026-09-28: the same re-read ran in triage, measure and implement through
# label_maintainer_test_candidates, for every maintainer-account issue the pipeline
# had already commented on. A negative judgment is recorded and not repeated.
mkdir -p "$TEST_HOME/bot-comment-gh"
cat > "$TEST_HOME/bot-comment-gh/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$BOT_COMMENT_GH_LOG"
jq -nc --arg m "$BOT_COMMENT_MARKER" '{number:7301,state:"OPEN",labels:[{name:"ready-for-agent"}],author:{login:"maintainer"},title:"Pipeline-filed",body:"x",comments:[{body:($m + " pipeline note")}]}'
GHEOF
chmod +x "$TEST_HOME/bot-comment-gh/gh"
printf '%s\n' '{}' >"$AGENT_HOME/state/7301.json"
export BOT_COMMENT_GH_LOG="$TEST_HOME/bot-comment-gh.log" BOT_COMMENT_MARKER
: > "$BOT_COMMENT_GH_LOG"
candidates='[{"number":7301,"state":"OPEN","labels":[{"name":"ready-for-agent"}],"author":{"login":"maintainer"},"title":"Pipeline-filed","body":"x"}]'
PATH="$TEST_HOME/bot-comment-gh:$PATH" label_maintainer_test_candidates "$candidates" >/dev/null
PATH="$TEST_HOME/bot-comment-gh:$PATH" label_maintainer_test_candidates "$candidates" >/dev/null
assert_eq "maintainer-account issue with pipeline comments is re-read once, not every tick" 1 "$(grep -c 'issue view 7301 ' "$BOT_COMMENT_GH_LOG" || true)"

if [ "$FAILED" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILURES"; exit 1; fi
