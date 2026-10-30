#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/root"
cat > "$t/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
 'rev-parse --show-toplevel') echo "$ROOT" ;;
 'rev-parse '*) echo candidate ;;
 'merge-base '*) echo base ;;
 'rev-list --count '*) echo "${COUNT:-1}" ;;
 'worktree add '*) d="${@: -2:1}"; mkdir -p "$d/.zenoforge"
   printf '%s\n' '# example gates' '' 'echo gate-one' 'exit "${FAIL:-0}"' > "$d/.zenoforge/prepush-gates" ;;
esac
STUB
chmod +x "$t/bin/"*; export PATH="$t/bin:$PATH" ROOT="$t/root" GH_TOKEN=secret
FAIL=0 "$p/prepush-gates.sh" | grep -q 'rc=0'
FAIL=0 "$p/prepush-gates.sh" > "$t/out"; grep -q 'bash -c .*gate-one' "$t/out"
rc=0; FAIL=1 "$p/prepush-gates.sh" > "$t/out" || rc=$?; [[ $rc == 1 ]]; grep -q 'rc=1' "$t/out"
rc=0; COUNT=0 "$p/prepush-gates.sh" > "$t/out" 2>&1 || rc=$?; [[ $rc == 2 ]]; grep -q 'commit first' "$t/out"
