#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

# A per-ticket failure in the advisor or triage for-n loop must skip that ticket; a `|| return` there drops the batch.
# dispatch_policy_unit returns 80 for a per-ticket spend skip or route failure, so its recut caller must handle 80.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# The first `for n in` loop of one function, from that line through the matching `done`.
batch_loop_body() {
  awk -v fn="$2" '
    index($0, fn "() {") == 1 { inside = 1; next }
    inside && /^}/ { exit }
    inside && !loop && /^[ \t]*for n in / {
      loop = 1; match($0, /^[ \t]*/); indent = substr($0, 1, RLENGTH); print; next
    }
    loop { print; if ($0 == indent "done") exit }
  ' "$1"
}

# The recut caller's case on dispatch_policy_unit's status, from its `if` line through `esac`.
recut_case_body() {
  awk '
    /if dispatch_policy_unit recut / { inside = 1 }
    inside { print; if ($0 ~ /^[ \t]*esac$/) exit }
  ' "$1"
}

batch_ticket_return_ratchet() {
  local file="$1" fn body case_body fail=0
  for fn in dispatch_advisor_batch dispatch_triage_batch; do
    body="$(batch_loop_body "$file" "$fn")"
    if [[ -z "$body" ]]; then
      printf 'FAIL %s: for-n loop not found\n' "$fn"; fail=1; continue
    fi
    if grep -q -F '|| return' <<< "$body"; then
      printf 'FAIL %s: for-n loop returns on a per-ticket failure; skip the ticket with continue:\n' "$fn"
      grep -F '|| return' <<< "$body" | sed 's/^/  /'
      fail=1
    fi
  done
  case_body="$(recut_case_body "$file")"
  if ! grep -qE '^[[:space:]]*80\)' <<< "$case_body"; then
    printf 'FAIL recut caller case on dispatch_policy_unit has no 80) arm; a spend skip would hit *)\n'
    fail=1
  fi
  (( fail == 0 )) || return 1
  printf 'batch ticket return ratchet ok\n'
}

pipeline="$script_dir/issue-pipeline.sh"
if ! batch_ticket_return_ratchet "$pipeline" > "$test_env_root/clean.txt" 2>&1; then
  printf 'batch-ticket-return-ratchet.test.sh: the real issue-pipeline.sh fails: %s\n' "$(cat "$test_env_root/clean.txt")" >&2
  exit 1
fi

fixture_dir="$(mktemp -d "$test_env_root/batch-ticket-return.XXXXXX")"
# Injected: a route/status failure returns from the advisor and triage loops again.
sed 's/\(budget_result="$(issue_spend_budget_status "$n")"\) || {[^}]*}/\1 || return 1/' "$pipeline" > "$fixture_dir/return.sh"
if batch_ticket_return_ratchet "$fixture_dir/return.sh" > "$fixture_dir/out.txt" 2>&1; then
  printf 'batch-ticket-return-ratchet.test.sh: a for-n loop return passed\n' >&2
  exit 1
fi
if ! grep -Fq 'FAIL dispatch_advisor_batch' "$fixture_dir/out.txt" || ! grep -Fq 'FAIL dispatch_triage_batch' "$fixture_dir/out.txt"; then
  printf 'batch-ticket-return-ratchet.test.sh: for-n failure was unexpected: %s\n' "$(cat "$fixture_dir/out.txt")" >&2
  exit 1
fi

# Injected: the recut caller loses its 80) arm.
sed '/^[[:space:]]*80) continue ;;$/d' "$pipeline" > "$fixture_dir/no-80.sh"
if batch_ticket_return_ratchet "$fixture_dir/no-80.sh" > "$fixture_dir/out.txt" 2>&1; then
  printf 'batch-ticket-return-ratchet.test.sh: a recut case without 80) passed\n' >&2
  exit 1
fi
if ! grep -Fq 'has no 80) arm' "$fixture_dir/out.txt"; then
  printf 'batch-ticket-return-ratchet.test.sh: missing-80 failure was unexpected: %s\n' "$(cat "$fixture_dir/out.txt")" >&2
  exit 1
fi

echo 'batch-ticket-return-ratchet.test.sh: all assertions passed'
