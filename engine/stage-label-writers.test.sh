#!/usr/bin/env bash
# Stage labels change only through lib.sh issue_transition: a raw gh label edit leaves state and label
# apart (#2951, 2026-10-08). No pipeline script may write stage labels directly.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
labels='needs-triage|needs-info|ready-for-agent|ready-for-human|needs-owner|checks-blocked|duplicate|finish-first|wontfix|needs-advisor|needs-recut|awaiting-release|awaiting-pipeline-sync|awaiting-pipeline-health|released|concluded|on-hold'
# Literal-only scans missed the three variable-backed triage/advisor writers.
# Metadata edits are safe only while their configured lane labels stay outside the stage vocabulary.
audit_raw_edits() {
  awk '
    /^[[:space:]]*#/ { next }
    /gh issue edit/ && $0 !~ /edit_args=\(gh issue edit/ && $0 !~ /guarded_write gh issue edit "\$N" --repo "\$REPO" "\$\{CATEGORY_EDIT_ARGS\[@\]\}"/ && $0 !~ /--milestone/ && $0 !~ /--add-blocked-by|--remove-blocked-by/ && $0 !~ /--add-label opt-lane([[:space:]]|$)/ && $0 !~ /--add-label "\$pipeline_label"/ && $0 !~ /--add-label pipeline-system([[:space:];]|$)/ && $0 !~ /--add-label founder-test([[:space:]]|$)/ && !(FILENAME == "engine/lib.d/sweeps.sh" && /\$\{edit_args\[@\]\}/) { print FILENAME ":" FNR ":" $0; bad=1 }
    END { exit bad }
  ' "$@"
}
fixture="$(mktemp)"
trap 'rm -f -- "$fixture"; rm -rf -- "$test_env_root"' EXIT
for edit in 'gh issue edit "$n" --add-label ready-for-agent' 'gh issue edit "$n" "${edit_args[@]}"' 'gh issue edit "$n" --add-label on-hold'; do
  printf '%s\n' "$edit" > "$fixture"
  if audit_raw_edits "$fixture" >/dev/null; then
    echo "not ok - raw stage writer escapes audit: $edit"
    exit 1
  fi
done
for edit in 'guarded_write gh issue edit "$number" --repo "$REPO" --milestone "$milestone"' 'guarded_write gh issue edit "$N" --repo "$REPO" --add-label "$pipeline_label"' 'guarded_write gh issue edit "$n" --repo "$REPO" --add-label pipeline-system'; do
  printf '%s\n' "$edit" > "$fixture"
  if ! audit_raw_edits "$fixture"; then
    echo "not ok - non-stage metadata edit rejected by audit: $edit"
    exit 1
  fi
done
jq -e --argjson state_labels "$(printf '%s' "$labels" | jq -R 'split("|")')" '
  [.rulings[] | select(.id == "nonproduct-lane-routing") | .membership.labels[]?]
  | all(.[]; . as $label | ($state_labels | index($label)) == null)
' engine/state/rulings.json >/dev/null || {
  echo "not ok - pipeline lane labels overlap lifecycle labels"
  exit 1
}
case "|$labels|" in *'|pipeline-system|'*)
  echo "not ok - pipeline-system must remain outside the stage vocabulary"
  exit 1
  ;;
esac

status=0
while IFS= read -r file; do
  if ! audit_raw_edits "$file"; then status=1; fi
  count="$(grep -cE -- "--(add|remove)-label[ =]\"?($labels)\b" "$file" || true)"
  if ((count > 0)); then
    echo "not ok - $file writes stage labels outside issue_transition ($count, allowed 0)"
    status=1
  fi
done < <(git ls-files 'engine/*.sh' | grep -v -e '\.test\.sh$' -e '^engine/lib\.sh$' -e '^engine/lib\.d/issue-state\.sh$')
((status == 0)) && echo "ok - stage labels change only through issue_transition"
exit "$status"
