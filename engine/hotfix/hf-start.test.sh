#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG"
STUB
cat > "$t/lw" <<'STUB'
#!/usr/bin/env bash
[[ -z ${GH_TOKEN+x} ]]; printf '%s\n' "$@" > "$LAUNCH"
STUB
cat > "$t/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'issue view 123 --json labels') echo '{"labels":[{"name":"bug"}]}' ;;
  'issue view 124 --json labels') echo '{"labels":[]}' ;;
  *) exit 97 ;;
esac
STUB
chmod +x "$t/git" "$t/lw" "$t/gh"; export PATH="$t:$PATH" WORKER_BIN="$t" HF_ROOT="$t/root" LOG="$t/gitlog" LAUNCH="$t/launch" GH_TOKEN=secret
{ for i in $(seq 1 12); do echo "context $i"; done; echo "Change engine/hotfix/x.sh"; echo "Run bash engine/hotfix/x.test.sh"; echo "Done when green"; } > "$t/brief"
echo vague > "$t/vague"; ! "$p/hf-start.sh" 123 slug "$t/vague" 2>/dev/null
"$p/hf-start.sh" nope slug "$t/brief" && exit 1
"$p/hf-start.sh" 123 slug "$t/brief"
grep -q 'worktree add --lock -b hotfix/123-slug' "$LOG"
grep -qx LUNA_PRIORITY=hotfix "$LAUNCH"
grep -q 'Do not merge or deploy' "$HF_ROOT/hf-123-slug-brief.md"
grep -q 'Done checklist' "$HF_ROOT/hf-123-slug-brief.md"
grep -q 'INCIDENT_RULE' "$HF_ROOT/hf-123-slug-brief.md"
grep -qF 'This unit IS an incident unit: its label bug is in incident.labels' "$HF_ROOT/hf-123-slug-brief.md"
grep -q '## root-cause' "$HF_ROOT/hf-123-slug-brief.md"
grep -q '## recurrence-guard' "$HF_ROOT/hf-123-slug-brief.md"
grep -q 'engine/lesson-guard-schema.mjs' "$HF_ROOT/hf-123-slug-brief.md"
"$p/hf-start.sh" 124 plain "$t/brief"
! grep -q 'INCIDENT_RULE' "$HF_ROOT/hf-124-plain-brief.md"
! grep -q 'This unit IS an incident unit' "$HF_ROOT/hf-124-plain-brief.md"
