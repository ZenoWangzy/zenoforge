#!/usr/bin/env bash
# hf-brief-lint.sh <brief-file>: refuse a worker brief that cannot be finished unaided.
# 10-29/30: the #4620 worker ran 8 rounds and wrote no code from a vague brief; the supervisor found out hours later.
set -euo pipefail
b=${1:?usage: hf-brief-lint.sh <brief-file>}
miss=()
(( $(wc -l < "$b") >= 12 )) || miss+=('at least 12 lines (symptom, evidence, expected behavior)')
grep -qiE 'done when|definition of done|acceptance' "$b" || miss+=('a "Done when" line')
grep -qE '(scripts|packages|src|engine)/[A-Za-z0-9_./-]+' "$b" || miss+=('the file or directory paths to change')
grep -qiE '(bash|node|pnpm|npm|pytest)[^`]*(test|spec)|\.test\.' "$b" || miss+=('the test command to run')
((${#miss[@]} == 0)) || { printf 'hf-brief-lint: %s is missing:\n' "$b" >&2; printf ' - %s\n' "${miss[@]}" >&2; exit 2; }
