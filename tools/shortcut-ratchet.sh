#!/usr/bin/env bash
# Marker ratchet for deliberate limits in engine and tools code: the count per file may shrink, not grow.
# Baseline tools/shortcut-baseline.txt: "<count><TAB><path>" per file with a mark. Raising a line there is the visible, deliberate exception.
# bash tools/shortcut-ratchet.sh [--tighten]: --tighten rewrites the baseline from the tree; it never raises a count or adds a file.
set -uo pipefail
cd "$(dirname "$0")/.."
baseline=tools/shortcut-baseline.txt mark='shortcut[:]'
declare -A base=() now=()
if [[ -f $baseline ]]; then while IFS=$'\t' read -r n path; do [[ -n ${path:-} && $n != \#* ]] && base[$path]=$n; done < "$baseline"; fi
while read -r f; do
  [[ -f $f ]] || continue
  n=$(grep -Isc -- "$mark" "$f") || true
  (( ${n:-0} > 0 )) && now[$f]=$n
done < <(git ls-files --cached --others --exclude-standard engine tools | grep -vE '\.test\.|/vendor/')
fail=0
for f in "${!now[@]}"; do
  n=${now[$f]} b=${base[$f]:-0}
  if (( n > b )); then fail=1; echo "REFUSAL found=\"$f has $n shortcut comments, baseline in $baseline is $b\" alternative=\"remove the new limit, or if it is justified raise that baseline line to '$n$(printf '\t')$f' in this PR\" documented_in=docs/enforced-rules.md"
  elif (( n < b )); then echo "NOTE $f shrank to $n shortcut comments (baseline $b): run bash tools/shortcut-ratchet.sh --tighten."; fi
done
for f in "${!base[@]}"; do [[ -n ${now[$f]:-} ]] || echo "NOTE $f has no shortcut comments left (baseline ${base[$f]}): run bash tools/shortcut-ratchet.sh --tighten."; done
if [[ ${1:-} == --tighten ]]; then
  if (( fail )) && [[ -f $baseline ]]; then echo 'REFUSAL found="a count above baseline" alternative="remove the new limit before tightening" documented_in=docs/enforced-rules.md. Nothing tightened.' >&2; exit 1; fi
  { echo '# shortcut-ratchet baseline: <count><TAB><path>; lower a count when a limit is paid down.'
    for f in "${!now[@]}"; do printf '%s\t%s\n' "${now[$f]}" "$f"; done | LC_ALL=C sort -t$'\t' -k2; } > "$baseline"
  echo 'shortcut-ratchet: baseline tightened'; exit 0
fi
(( fail )) || echo 'shortcut-ratchet ok'
exit $fail
