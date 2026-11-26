#!/usr/bin/env bash
# File-size ratchet for engine source: a file over CAP lines may shrink but not grow; a file not in the baseline must stay at or under CAP.
# Baseline: tools/size-baseline.txt, "<lines><TAB><path>" per file over the cap. Raising or adding a line there is the visible, deliberate exception.
# CAP 800: 26 of the 295 files in scope (about 9%) are over it, so most files never meet the ratchet; it targets the few
# large files that collide in merges. A lower cap would put 45+ files in the baseline for no extra protection.
set -uo pipefail
cd "$(dirname "$0")/.."
CAP=800 baseline=tools/size-baseline.txt
declare -A base=()
while IFS=$'\t' read -r n path; do [[ -n ${path:-} && $n != \#* ]] && base[$path]=$n; done < "$baseline"
fail=0 seen=" "
# Source = scripts under engine/ and tools/; tests, vendored code and fixtures are out of scope.
while read -r f; do
  [[ -f $f ]] || continue
  n=$(wc -l < "$f"); seen+="$f "
  b=${base[$f]:-}
  if [[ -z $b ]]; then
    (( n > CAP )) && { fail=1; echo "REFUSAL found=\"$f has $n lines, over the $CAP-line cap and not in $baseline\" alternative=\"split the file, or if the size is deliberate add the line '$n$(printf '\t')$f' to $baseline in this PR\" documented_in=docs/enforced-rules.md,docs/adr/0007-file-size-only-shrinks-above-cap.md"; }
  elif (( n > b )); then
    fail=1; echo "REFUSAL found=\"$f has $n lines, above its $b-line baseline in $baseline\" alternative=\"move code out of it, or if the growth is deliberate change that baseline line to '$n$(printf '\t')$f' in this PR\" documented_in=docs/enforced-rules.md,docs/adr/0007-file-size-only-shrinks-above-cap.md"
  elif (( n <= CAP )); then
    echo "NOTE $f shrank to $n lines, at or under the $CAP-line cap: delete its line from $baseline."
  elif (( n < b )); then
    echo "NOTE $f shrank to $n lines (baseline $b): lower its baseline line in $baseline to \"$n$(printf '\t')$f\"."
  fi
done < <(git ls-files --cached --others --exclude-standard engine tools | grep -E '\.(sh|mjs|py|js|ts|cjs)$' | grep -vE '\.test\.|(^|/)test-[^/]*\.sh$|/vendor/|/fixtures?/')
for p in "${!base[@]}"; do [[ $seen == *" $p "* ]] || echo "NOTE $p is in $baseline but no longer in scope: delete its line."; done
(( fail )) || echo "size-ratchet ok"
exit $fail
