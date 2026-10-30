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
chmod +x "$t/git" "$t/lw"; export PATH="$t:$PATH" WORKER_BIN="$t" HF_ROOT="$t/root" LOG="$t/gitlog" LAUNCH="$t/launch" GH_TOKEN=secret
echo brief > "$t/brief"
"$p/hf-start.sh" nope slug "$t/brief" && exit 1
"$p/hf-start.sh" 123 slug "$t/brief"
grep -q 'worktree add --lock -b hotfix/123-slug' "$LOG"
grep -qx LUNA_PRIORITY=hotfix "$LAUNCH"
grep -q 'Do not merge or deploy' "$HF_ROOT/hf-123-slug-brief.md"
