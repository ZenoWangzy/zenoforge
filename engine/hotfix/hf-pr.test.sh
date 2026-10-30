#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/git" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  symbolic-ref) printf '%s\n' "$BRANCH" ;;
  diff) printf '%s\n' a.py b.ts ;;
esac
STUB
cat > "$t/gh" <<'STUB'
#!/usr/bin/env bash
[[ -z ${GH_TOKEN+x} ]]
case "$1 $2" in
  'pr list') printf '7 hotfix/other\n' ;;
  'pr view') printf '%s\n' $THEIRS ;;
  'pr create') printf '%s\n' "$@" > "$LOG" ;;
esac
STUB
chmod +x "$t/git" "$t/gh"; export PATH="$t:$PATH" LOG="$t/log" GH_TOKEN=secret
BRANCH=topic THEIRS=z.md "$p/hf-pr.sh" && exit 1
BRANCH=hotfix/test THEIRS=b.ts "$p/hf-pr.sh" --title hello && exit 1
[[ ! -e $LOG ]]
BRANCH=hotfix/test THEIRS=b.ts HF_OVERLAP_ACK=7 "$p/hf-pr.sh" --title hello
grep -qx hotfix "$LOG"; rm "$LOG"
BRANCH=hotfix/test THEIRS=z.md "$p/hf-pr.sh" --title hello
grep -qx hotfix "$LOG"
