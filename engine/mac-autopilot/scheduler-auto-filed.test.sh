#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/scheduler-auto-filed"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
printf '%s\n' needs-triage > "$fixture/labels"
: > "$fixture/creates"
export AUTOPILOT_LABELS="$fixture/labels" AUTOPILOT_CREATES="$fixture/creates"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
AUTOPILOT_LABEL_LIST_FAIL=false
AUTOPILOT_LABEL_CREATE_ERROR=""

gh() {
  case "${1:-}:${2:-}" in
    label:list)
      if [[ "$AUTOPILOT_LABEL_LIST_FAIL" == true ]]; then
        return 1
      fi
      cat "$AUTOPILOT_LABELS"
      ;;
    label:create)
      printf '%s\n' "label:$3" >> "$AUTOPILOT_CREATES"
      if [[ -n "$AUTOPILOT_LABEL_CREATE_ERROR" ]]; then
        printf '%s\n' "$AUTOPILOT_LABEL_CREATE_ERROR" >&2
        return 1
      fi
      if grep -qx -- "$3" "$AUTOPILOT_LABELS" && [[ " $* " != *" --force "* ]]; then
        printf '%s\n' 'HTTP 422 already_exists' >&2
        return 1
      fi
      grep -qx -- "$3" "$AUTOPILOT_LABELS" || printf '%s\n' "$3" >> "$AUTOPILOT_LABELS"
      ;;
    issue:create)
      printf '%s\n' "$*" >> "$AUTOPILOT_CREATES"
      printf 'https://github.com/example/repo/issues/%s\n' "$(( $(grep -c '^issue create' "$AUTOPILOT_CREATES") + 40 ))"
      ;;
    *) echo "unexpected scheduler-auto-filed gh call: $*" >&2; return 1 ;;
  esac
}

first="$(scheduler_auto_filed_issue_create --title first --body evidence --label needs-triage)"
second="$(scheduler_auto_filed_issue_create --title second --body evidence --label ready-for-agent)"
[[ "$first" == https://github.com/example/repo/issues/41 && "$second" == https://github.com/example/repo/issues/42 ]] || {
  echo 'scheduler-auto-filed.test.sh: issue creation did not return each URL' >&2
  exit 1
}
[[ "$(grep -c '^label:auto-filed$' "$AUTOPILOT_CREATES")" == 2 ]] || {
  echo 'scheduler-auto-filed.test.sh: auto-filed label was not prepared for each issue' >&2
  exit 1
}
[[ "$(grep -c '^issue create .*--label auto-filed$' "$AUTOPILOT_CREATES")" == 2 ]] || {
  echo 'scheduler-auto-filed.test.sh: created issue is missing the auto-filed label' >&2
  exit 1
}

printf '%s\n' needs-triage auto-filed > "$AUTOPILOT_LABELS"
AUTOPILOT_AUTO_FILED_LABEL_READY=false
AUTOPILOT_LABEL_LIST_FAIL=true
scheduler_auto_filed_issue_create --title list-failed --body evidence --label needs-triage > "$fixture/list-failed-url"
[[ "$AUTOPILOT_AUTO_FILED_LABEL_READY" == true ]] || {
  echo 'scheduler-auto-filed.test.sh: failed label list left the existing auto-filed label not ready' >&2
  exit 1
}
[[ "$(cat "$fixture/list-failed-url")" == https://github.com/example/repo/issues/43 ]] || {
  echo 'scheduler-auto-filed.test.sh: issue creation did not return a URL after a failed label list' >&2
  exit 1
}
grep -Fqx -- 'issue create --title list-failed --body evidence --label needs-triage --label auto-filed' "$AUTOPILOT_CREATES" || {
  echo 'scheduler-auto-filed.test.sh: issue created after a failed label list is missing auto-filed' >&2
  exit 1
}

printf '%s\n' needs-triage > "$AUTOPILOT_LABELS"
AUTOPILOT_AUTO_FILED_LABEL_READY=false
AUTOPILOT_LABEL_LIST_FAIL=false
AUTOPILOT_LABEL_CREATE_ERROR='HTTP 403 Forbidden'
scheduler_auto_filed_issue_create --title create-forbidden --body evidence --label needs-triage > "$fixture/create-forbidden-url"
[[ "$AUTOPILOT_AUTO_FILED_LABEL_READY" == false ]] || {
  echo 'scheduler-auto-filed.test.sh: unrelated label create failure marked auto-filed ready' >&2
  exit 1
}
[[ "$(cat "$fixture/create-forbidden-url")" == https://github.com/example/repo/issues/44 ]] || {
  echo 'scheduler-auto-filed.test.sh: issue creation did not continue after an unrelated label create failure' >&2
  exit 1
}
grep -Fqx -- 'issue create --title create-forbidden --body evidence --label needs-triage' "$AUTOPILOT_CREATES" || {
  echo 'scheduler-auto-filed.test.sh: issue after unrelated label create failure did not use the fallback' >&2
  exit 1
}
echo 'scheduler-auto-filed.test.sh: PASS'
