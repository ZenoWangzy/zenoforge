#!/usr/bin/env bash
# hf-brief-lint.sh <brief-file>: refuse a worker brief that cannot be finished unaided.
# 10-29/30: the #4620 worker ran 8 rounds and wrote no code from a vague brief; the supervisor found out hours later.
set -euo pipefail
b=${1:?usage: hf-brief-lint.sh <brief-file>}
miss=()
(( $(wc -l < "$b") >= 12 )) || miss+=('at least 12 lines (symptom, evidence, expected behavior)')
grep -qiE 'done when|definition of done|acceptance' "$b" || miss+=('a "Done when" line')
grep -qE '(scripts|packages|src|engine)/[A-Za-z0-9_./-]+' "$b" || miss+=('the file or directory paths to change')
grep -qiE 'test|spec' "$b" || miss+=('regression-test coverage for PR CI')
grep -qiE 'PR CI|CI checks|CI runs' "$b" || miss+=('PR CI as the test verification path')
grep -qiE '^[[:space:]]*(run|execute|must run|should run|please run).*((test|spec|suite).*(locally|local|on this host)|(locally|local).*(test|spec|suite))' "$b" && miss+=('no instruction to run test suites locally')
awk '
function inspect(text, value) {
  value = tolower(text)
  if (value ~ /(do not|never|must not|should not|avoid|don.t|not required|not needed|not necessary|manual only|no longer)/) return
  if (value ~ /(local|locally)/ && value ~ /receipt/ && value ~ /(record|write|save|create|produce|leave|provide|attach|submit|require|needed|must|should|shall|need|before push|before pushing|pre-push|gate)/) found = 1
}
{
  sentence_count = split($0, sentences, /[;.!?]/)
  for (i = 1; i <= sentence_count; i++) {
    clause_count = split(sentences[i], clauses, /[[:space:]]+(and|but|however)[[:space:]]+/)
    for (j = 1; j <= clause_count; j++) inspect(clauses[j])
  }
}
END { exit !found }
' "$b" && miss+=('no instruction to record local test receipts')
((${#miss[@]} == 0)) || { printf 'hf-brief-lint: %s is missing:\n' "$b" >&2; printf ' - %s\n' "${miss[@]}" >&2; exit 2; }
