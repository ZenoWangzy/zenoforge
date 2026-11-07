#!/usr/bin/env bash
# The scheduler.log scan files only real failure signatures with stable class ids
# (2026-11-03: 165 open "Incident: scheduler..." issues came from routine progress
# lines matched by substrings and whole-line class keys). Routine progress files
# nothing at the default medium severity; repeats of one failure class bump the
# existing issue's occurrence count instead of opening a new one.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
unset AUTOPILOT_LOOP_UNIT

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bell="$script_dir/bell.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bell-sched-sig.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin" "$tmp/agent-home/logs"
export BELL_TEST_NETWORK=green BELL_STALE_CI_DISABLE=1
export MAC_AUTOPILOT_ROOT="$MAC_AUTOPILOT_ENV_ROOT" ZF_ENGINE_DIR="$MAC_AUTOPILOT_ENV_ROOT/engine"
export ZF_REPO_DIR="$MAC_AUTOPILOT_ENV_ROOT" ZF_REPO=test/product ZF_GH_REPO=test/product
export ZF_ISSUE_LOCK_DIR="$tmp/issue-locks" AGENT_HOME="$tmp/agent-home"
cat > "$tmp/roadmap-tree.json" <<'JSON'
{"roots":[{"number":900,"title":"the product roadmap","state":"open","labels":["roadmap"],"children":[{"number":910,"title":"开发流水线与运行稳定","state":"open","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":912,"title":"Incident intake","state":"open","labels":["roadmap-epic"],"children":[]}]}]}]}
JSON
export ZF_ROADMAP_TREE_CACHE_FILE="$tmp/roadmap-tree.json"

cat > "$bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ls-remote) printf 'deadbeef\trefs/heads/main\n'; exit 0 ;;
  *) exit 2 ;;
esac
SH
cat > "$bin/timeout" <<'SH'
#!/usr/bin/env bash
while [[ "${1:-}" == --foreground || "${1:-}" == --kill-after=* ]]; do shift; done
[[ "${1:-}" =~ ^[0-9]+s?$ ]] && shift
exec "$@"
SH
for stub in ps pkill systemctl; do
  cat > "$bin/$stub" <<'SH'
#!/usr/bin/env bash
exit 0
SH
done
cat > "$bin/journalctl" <<'SH'
#!/usr/bin/env bash
printf 'oom-kill fixture trace 1\n'
SH
cat > "$bin/notify-send" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$INCIDENT_GH_CALLS"
case "${1:-}:${2:-}" in
  label:list)
    while IFS= read -r label; do printf '%s\n' "$label"; done < "$INCIDENT_LABELS"
    ;;
  label:create)
    label="${3:?}"
    grep -qx -- "$label" "$INCIDENT_LABELS" || printf '%s\n' "$label" >> "$INCIDENT_LABELS"
    ;;
  api:--method)
    jq -c '[.]' "$INCIDENT_ISSUES"
    ;;
  api:repos/*/issues/*/sub_issues)
    echo '{}'
    ;;
  api:repos/*/issues/*)
    echo 501000
    ;;
  issue:create)
    title=""; body_file=""; repo=""; previous=""; labels=()
    for arg in "$@"; do
      case "$previous" in
        --title) title="$arg" ;;
        --body-file) body_file="$arg" ;;
        --repo) repo="$arg" ;;
        --label) labels+=("$arg") ;;
      esac
      previous="$arg"
    done
    number="$(cat "$INCIDENT_NEXT_NUMBER")"
    printf '%s\n' "$((number + 1))" > "$INCIDENT_NEXT_NUMBER"
    labels_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s 'map({name:.})')"
    jq --argjson number "$number" --arg title "$title" --arg repo "$repo" --argjson labels "$labels_json" --rawfile body "$body_file" \
      '. + [{number:$number,title:$title,body:$body,state:"OPEN",labels:$labels,repo:$repo}]' \
      "$INCIDENT_ISSUES" > "$INCIDENT_ISSUES.tmp"
    mv "$INCIDENT_ISSUES.tmp" "$INCIDENT_ISSUES"
    printf 'https://github.com/test/product/issues/%s\n' "$number"
    ;;
  issue:view)
    jq -ce --argjson number "${3:?}" '[.[] | select(.number==$number)][0]' "$INCIDENT_ISSUES"
    ;;
  issue:edit)
    echo '{}'
    ;;
  issue:comment)
    number="${3:?}"; body_file=""; previous=""
    for arg in "$@"; do
      [[ "$previous" != --body-file ]] || body_file="$arg"
      previous="$arg"
    done
    jq -cn --argjson number "$number" --rawfile body "$body_file" '{number:$number,body:$body}' >> "$INCIDENT_COMMENTS"
    ;;
  *) echo "unexpected scheduler-signature gh call: $*" >&2; exit 91 ;;
esac
SH
chmod +x "$bin/"*
export PATH="$bin:$PATH"

make_runtime() { # $1=name → prints the autopilot runtime dir; severity gate left at the default (medium)
  local a="$tmp/$1"
  mkdir -p "$a/alerts"
  printf 'window.DASH={};\n' > "$a/dashboard.data.js"
  printf '%s\n' '{"bell":{"enabled":true,"notify":false,"auto_supervisor":false,"dedup_minutes":30}}' > "$a/config.json"
  printf '%s\n' '{"units":[]}' > "$a/units.json"
  printf '%s\n' '{"workers":[]}' > "$a/workers.json"
  jq -n '{monitor_initialized:true,scheduler_lines:0,alert_mtimes:{},merge_events:{},signatures:{},pending:[]}' > "$a/bell-state.json"
  printf '%s\n' "$a"
}

reset_gh_fixture() { # $1=name → per-scenario gh state
  export INCIDENT_LABELS="$tmp/$1-labels" INCIDENT_ISSUES="$tmp/$1-issues.json"
  export INCIDENT_COMMENTS="$tmp/$1-comments.jsonl" INCIDENT_GH_CALLS="$tmp/$1-gh-calls.log"
  export INCIDENT_NEXT_NUMBER="$tmp/$1-next-number"
  printf 'pipeline-system\nready-for-agent\n' > "$INCIDENT_LABELS"
  printf '[]\n' > "$INCIDENT_ISSUES"
  : > "$INCIDENT_COMMENTS"
  : > "$INCIDENT_GH_CALLS"
  printf '7300\n' > "$INCIDENT_NEXT_NUMBER"
}

run_bell() { # $1=autopilot dir, $2=supervisor dir
  mkdir -p "$2"
  BELL_AUTOPI_DIR="$1" BELL_SUPERVISOR_DIR="$2" bash "$bell"
}

now_stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# 1. Today's real routine lines, replayed verbatim at the default medium severity,
#    file nothing: no issue, no gh write, no queued event.
routine_autopi="$(make_runtime routine-replay)"
reset_gh_fixture routine-replay
{
  printf '[%s] refill done live=6 secs=33 gh_calls=1 slow: dispatch_pending=24s\n' "$(now_stamp)"
  printf '[%s] unit issue-3129 unblocked: #3128 delivered\n' "$(now_stamp)"
  printf '[%s] unit issue-5245 blocked on predecessor #3201\n' "$(now_stamp)"
  printf '[%s] supervisor budget-park unit=pr-3521: cap triage: token spent 180000 > 120000\n' "$(now_stamp)"
  printf '[%s] merge detail blocked_pr_recheck=12s\n' "$(now_stamp)"
} > "$routine_autopi/scheduler.log"
run_bell "$routine_autopi" "$tmp/routine-replay-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 0 ]] || { echo 'bell-scheduler-signatures.test.sh: a routine progress line filed an incident' >&2; exit 1; }
if grep -q '^issue create ' "$INCIDENT_GH_CALLS"; then
  echo 'bell-scheduler-signatures.test.sh: a routine progress line created an issue' >&2; exit 1
fi
jq -e '.incident_stats == {} and .incident_filing == {}' "$routine_autopi/bell-state.json" >/dev/null \
  || { echo 'bell-scheduler-signatures.test.sh: a routine line was queued as an incident' >&2; jq -c '.incident_stats,.incident_filing' "$routine_autopi/bell-state.json" >&2; exit 1; }
[[ ! -s "$routine_autopi/BELL-QUEUE.md" ]] || {
  echo 'bell-scheduler-signatures.test.sh: a routine line queued an event' >&2; exit 1
}
echo 'ok - routine progress lines file nothing at medium severity'

# 2. A jqf failure files once; a repeat with different numbers bumps the same class.
jqf_autopi="$(make_runtime jqf-dedupe)"
reset_gh_fixture jqf-dedupe
printf '[%s] census: jqf error (rc=5) in set_unit at stage=registry\n' "$(now_stamp)" > "$jqf_autopi/scheduler.log"
run_bell "$jqf_autopi" "$tmp/jqf-dedupe-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]] || { echo 'bell-scheduler-signatures.test.sh: jqf error did not file exactly one issue' >&2; exit 1; }
jq -e '.[0].body | contains("<!-- vecta-incident-class:sched-jqf-error-set-unit -->")
  and contains("Occurrence count: 1")' "$INCIDENT_ISSUES" >/dev/null
printf '[%s] census: jqf error (rc=7) in set_unit at stage=registry\n' "$(now_stamp)" >> "$jqf_autopi/scheduler.log"
run_bell "$jqf_autopi" "$tmp/jqf-dedupe-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]] || { echo 'bell-scheduler-signatures.test.sh: the rc=7 repeat opened a second issue' >&2; exit 1; }
[[ "$(grep -c '^issue create ' "$INCIDENT_GH_CALLS")" == 1 ]] || {
  echo 'bell-scheduler-signatures.test.sh: the repeat must not create another issue' >&2; exit 1
}
jq -se 'length == 1 and .[0].number == 7300
  and (.[0].body | contains("Occurrence count: 2") and contains("sched-jqf-error-set-unit"))' "$INCIDENT_COMMENTS" >/dev/null \
  || { echo 'bell-scheduler-signatures.test.sh: the repeat did not bump the existing issue occurrence count' >&2; cat "$INCIDENT_COMMENTS" >&2; exit 1; }
jq -e '.incident_stats["sched-jqf-error-set-unit"].count == 2' "$jqf_autopi/bell-state.json" >/dev/null \
  || { echo 'bell-scheduler-signatures.test.sh: the repeat did not bump the tracked occurrence count' >&2; exit 1; }
echo 'ok - a jqf repeat with different numbers bumps the same class'

# 3. A refused tick files one high-severity incident; the routine line next to it files nothing.
refuse_autopi="$(make_runtime tick-refusal)"
reset_gh_fixture tick-refusal
{
  printf '[%s] unit issue-5245 blocked on predecessor #3201\n' "$(now_stamp)"
  printf '[%s] run-tick: refusing to run this tick — cause=scheduler-failed observed=issue-pipeline.sh exited with status 1\n' "$(now_stamp)"
} > "$refuse_autopi/scheduler.log"
run_bell "$refuse_autopi" "$tmp/tick-refusal-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]] || { echo 'bell-scheduler-signatures.test.sh: the refusal scan did not file exactly one issue' >&2; exit 1; }
jq -e '.[0].body | contains("<!-- vecta-incident-class:sched-run-tick-refused -->")
  and contains("- Severity: high")' "$INCIDENT_ISSUES" >/dev/null \
  || { echo 'bell-scheduler-signatures.test.sh: the refusal incident is not high severity' >&2; jq -r '.[0].body' "$INCIDENT_ISSUES" >&2; exit 1; }
echo 'ok - a refused tick files one high-severity incident'

# 4. A real budget stop-loss line keeps filing, under a stable class id.
budget_autopi="$(make_runtime budget-stop)"
reset_gh_fixture budget-stop
printf '[%s] BUDGET-STOP token spent>100, unit=unit-budget not dispatched\n' "$(now_stamp)" > "$budget_autopi/scheduler.log"
run_bell "$budget_autopi" "$tmp/budget-stop-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]] || { echo 'bell-scheduler-signatures.test.sh: the budget stop-loss line did not file exactly one issue' >&2; exit 1; }
jq -e '.[0].body | contains("<!-- vecta-incident-class:sched-budget-stop -->")' "$INCIDENT_ISSUES" >/dev/null
jq -e '[.pending[].raw_signature] == ["sched-budget-stop"]' "$budget_autopi/bell-state.json" >/dev/null \
  || { echo 'bell-scheduler-signatures.test.sh: the budget stop-loss event lost its stable id' >&2; jq -c '.pending' "$budget_autopi/bell-state.json" >&2; exit 1; }
echo 'ok - a budget stop-loss line files under one stable class id'

echo 'bell-scheduler-signatures.test.sh: PASS'
