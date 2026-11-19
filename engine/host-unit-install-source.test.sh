#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
# Host unit templates (tools/*.service) install scripts from committed code only, never from a clone's working tree.
# 2026-11-18 (row 608): zf-auto-pin.service ran `install ... ~/.zenoforge/clones/<clone>/tools/auto-pin.sh`, so an
# uncommitted edit in that clone went live on the next restart and a merged fix reached the host only by hand.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
fail() { echo "host-unit-install-source.test.sh: $*" >&2; exit 1; }

n=0
for unit in "$repo"/tools/*.service; do
  [[ -e $unit ]] || continue
  n=$((n + 1))
  while IFS= read -r line; do
    [[ $line =~ ^Exec ]] || continue
    # A working-tree read: a clones/ path followed by a file path (tools/..., engine/...) outside `git show <ref>:`.
    if [[ $line =~ \.zenoforge/clones/[^[:space:]\"\']+/(tools|engine)/ ]]; then
      fail "${unit##*/}: $line reads a clone working tree; copy from git show origin/main:<path> instead"
    fi
  done < "$unit"
done
(( n > 0 )) || fail "no tools/*.service found"

grep -Eq '^ExecStartPre=.*git -C "\$\{ZF_AUTO_PIN_CLONE\}" show origin/main:tools/auto-pin\.sh > %h/\.zenoforge/bin/zf-auto-pin\.new' \
  "$repo/tools/zf-auto-pin.service" || fail "zf-auto-pin.service must install tools/auto-pin.sh from origin/main into a new file"
grep -Eq 'mv %h/\.zenoforge/bin/zf-auto-pin\.new %h/\.zenoforge/bin/zf-auto-pin' "$repo/tools/zf-auto-pin.service" \
  || fail "zf-auto-pin.service must move the new copy over the running one, not write it in place"
echo "PASS $n host unit template(s) install from committed code only"
