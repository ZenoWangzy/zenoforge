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

gh() {
  case "${1:-}:${2:-}" in
    label:list) cat "$AUTOPILOT_LABELS" ;;
    label:create)
      printf '%s\n' "label:$3" >> "$AUTOPILOT_CREATES"
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
[[ "$(grep -c '^label:auto-filed$' "$AUTOPILOT_CREATES")" == 1 ]] || {
  echo 'scheduler-auto-filed.test.sh: auto-filed label was not created once' >&2
  exit 1
}
[[ "$(grep -c '^issue create .*--label auto-filed$' "$AUTOPILOT_CREATES")" == 2 ]] || {
  echo 'scheduler-auto-filed.test.sh: created issue is missing the auto-filed label' >&2
  exit 1
}
echo 'scheduler-auto-filed.test.sh: PASS'
