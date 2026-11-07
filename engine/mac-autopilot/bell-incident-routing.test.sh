#!/usr/bin/env bash
# Incident intake routing and the slow-phase threshold (#5147): evidence that the
# engine owns (scheduler.log lines) files its incident on the engine repo, product
# evidence keeps filing on the product repo, and one slow-phase notice files
# nothing until the same phase is slow in N of the last M tick summaries.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
unset AUTOPILOT_LOOP_UNIT

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bell="$script_dir/bell.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bell-incident-route.XXXXXX")"
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
  *) echo "unexpected incident-routing gh call: $*" >&2; exit 91 ;;
esac
SH
chmod +x "$bin/"*
export PATH="$bin:$PATH"

make_runtime() { # $1=name → prints the autopilot runtime dir
  local a="$tmp/$1"
  mkdir -p "$a/alerts"
  printf 'window.DASH={};\n' > "$a/dashboard.data.js"
  printf '%s\n' '{"bell":{"enabled":true,"dedup_minutes":30}}' > "$a/config.json"
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
  printf '7100\n' > "$INCIDENT_NEXT_NUMBER"
}

run_bell() { # $1=autopilot dir, $2=supervisor dir
  mkdir -p "$2"
  BELL_AUTOPI_DIR="$1" BELL_SUPERVISOR_DIR="$2" bash "$bell"
}

tick_stamps() { # $1=count → stamps one minute apart, oldest first
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timezone, timedelta
count = int(sys.argv[1])
now = datetime.now(timezone.utc)
for i in range(count, 0, -1):
    print((now - timedelta(minutes=i)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# 1. A scheduler.log-evidence incident files on the engine repo, never the product repo.
engine_autopi="$(make_runtime engine-route)"
reset_gh_fixture engine-route
printf '[%s] orphan-recover reclaimed unit=unit-route\n' "$(tick_stamps 1)" > "$engine_autopi/scheduler.log"
run_bell "$engine_autopi" "$tmp/engine-route-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]] || { echo 'bell-incident-routing.test.sh: scheduler.log incident did not create exactly one issue' >&2; exit 1; }
[[ "$(grep -c '^issue create --repo ZenoWangzy/zenoforge ' "$INCIDENT_GH_CALLS")" == 1 ]] || {
  echo 'bell-incident-routing.test.sh: scheduler.log evidence must file on the engine repo' >&2
  exit 1
}
if grep -q '^issue create --repo test/product ' "$INCIDENT_GH_CALLS"; then
  echo 'bell-incident-routing.test.sh: engine evidence filed on the product repo' >&2
  exit 1
fi
jq -e '.[0].body | contains("<!-- vecta-incident-class:scheduler-orphan-recover-reclaimed-unit-unit-route -->")
  and contains("Occurrence count: 1")' "$INCIDENT_ISSUES" >/dev/null
jq -e '.[0].labels | any(.name == "auto-filed") and any(.name == "incident")' "$INCIDENT_ISSUES" >/dev/null
grep -Fxq incident "$INCIDENT_LABELS"
grep -Fxq auto-filed "$INCIDENT_LABELS"
echo 'ok - scheduler.log evidence files the incident on the engine repo'

# 2. Product-path evidence keeps filing on the product repo.
product_autopi="$(make_runtime product-route)"
reset_gh_fixture product-route
printf '[%s] tick done units=0 live=0\n' "$(tick_stamps 1)" > "$product_autopi/scheduler.log"
product_sup="$tmp/product-route-sup"
mkdir -p "$product_sup"
jq -n '[{n:1,"priority":"P1","reason":"fixture","verdict":"FIX"}]' > "$product_sup/advisor-verdicts-old.json"
touch -d "@$(( $(date +%s) - 200000 ))" "$product_sup/advisor-verdicts-old.json"
run_bell "$product_autopi" "$product_sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]] || { echo 'bell-incident-routing.test.sh: product incident did not create exactly one issue' >&2; exit 1; }
[[ "$(grep -c '^issue create --repo test/product ' "$INCIDENT_GH_CALLS")" == 1 ]] || {
  echo 'bell-incident-routing.test.sh: product evidence must keep filing on the product repo' >&2
  exit 1
}
if grep -q '^issue create --repo ZenoWangzy/zenoforge ' "$INCIDENT_GH_CALLS"; then
  echo 'bell-incident-routing.test.sh: product evidence was rerouted to the engine repo' >&2
  exit 1
fi
jq -e '.[0].body | contains("<!-- vecta-incident-class:verdicts-backlog-stale -->")' "$INCIDENT_ISSUES" >/dev/null
echo 'ok - product-path evidence keeps filing on the product repo'

# 3. A plain refill summary is routine scheduler output, not an incident.
plain_refill_autopi="$(make_runtime plain-refill)"
reset_gh_fixture plain-refill
printf '[%s] refill done live=5 secs=43 gh_calls=7\n' \
  "$(tick_stamps 1)" > "$plain_refill_autopi/scheduler.log"
run_bell "$plain_refill_autopi" "$tmp/plain-refill-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 0 ]] || { echo 'bell-incident-routing.test.sh: plain refill summary filed an incident' >&2; exit 1; }
if grep -q '^issue create ' "$INCIDENT_GH_CALLS"; then
  echo 'bell-incident-routing.test.sh: plain refill summary created an issue' >&2
  exit 1
fi
[[ ! -s "$plain_refill_autopi/BELL-QUEUE.md" ]] || {
  echo 'bell-incident-routing.test.sh: plain refill summary queued an event' >&2
  exit 1
}
echo 'ok - a plain refill summary is ignored'

# 4. A single slow-phase notice is a metric: no event, no issue.
single_autopi="$(make_runtime single-slow)"
reset_gh_fixture single-slow
printf '[%s] refill done live=1 free_slots=7 pending=0 secs=25 gh_calls=1 slow: dispatch_pending=14s\n' \
  "$(tick_stamps 1)" > "$single_autopi/scheduler.log"
run_bell "$single_autopi" "$tmp/single-slow-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 0 ]] || { echo 'bell-incident-routing.test.sh: one slow notice filed an incident' >&2; exit 1; }
if grep -q '^issue create ' "$INCIDENT_GH_CALLS"; then
  echo 'bell-incident-routing.test.sh: one slow notice created an issue' >&2
  exit 1
fi
[[ ! -s "$single_autopi/BELL-QUEUE.md" ]] || {
  echo 'bell-incident-routing.test.sh: one slow notice queued an event' >&2
  exit 1
}
[[ "$(jq -r '.slow_phase_ticks["dispatch_pending"] // ""' "$single_autopi/bell-state.json")" == 1 ]] || {
  echo 'bell-incident-routing.test.sh: the slow notice was not recorded in the tick window' >&2
  exit 1
}
echo 'ok - a single slow-phase notice files nothing'

# 5. The same phase slow in 5 of the last 10 tick summaries files exactly one engine incident.
repeat_autopi="$(make_runtime repeat-slow)"
reset_gh_fixture repeat-slow
mapfile -t stamps < <(tick_stamps 10)
: > "$repeat_autopi/scheduler.log"
for i in "${!stamps[@]}"; do
  if (( (i + 1) % 2 == 1 )); then
    printf '[%s] refill done live=1 free_slots=7 pending=0 secs=25 gh_calls=1 slow: dispatch_pending=14s\n' \
      "${stamps[$i]}" >> "$repeat_autopi/scheduler.log"
  else
    printf '[%s] refill done live=1 free_slots=7 pending=0 secs=8 gh_calls=1\n' \
      "${stamps[$i]}" >> "$repeat_autopi/scheduler.log"
  fi
done
run_bell "$repeat_autopi" "$tmp/repeat-slow-sup"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]] || { echo 'bell-incident-routing.test.sh: 5-of-10 slow ticks did not create exactly one issue' >&2; exit 1; }
[[ "$(grep -c '^issue create --repo ZenoWangzy/zenoforge ' "$INCIDENT_GH_CALLS")" == 1 ]] || {
  echo 'bell-incident-routing.test.sh: the repeated slow phase must file on the engine repo' >&2
  exit 1
}
jq -e '.[0].body | contains("<!-- vecta-incident-class:slow-phase-dispatch-pending -->")
  and contains("Occurrence count: 1") and contains("dispatch_pending was slow in 5 of the last 10")' \
  "$INCIDENT_ISSUES" >/dev/null
grep -Fq 'dispatch_pending was slow in 5 of the last 10' "$repeat_autopi/BELL-QUEUE.md"
echo 'ok - five slow ticks out of ten file one engine incident'

echo 'bell-incident-routing.test.sh: PASS'
