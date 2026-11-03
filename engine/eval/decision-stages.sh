#!/usr/bin/env bash
# Diff paths (stdin, one per line) → the eval stages whose decisions they can change,
# space-separated in the canonical stage order. One mapping for both callers: the
# scheduler's prompt-eval dispatch (evals-arbiter.sh) and the engine-pin eval gate
# (engine-sync.sh), so the two never disagree about a touched file's decision surface.
#   default: stage prompts, Matt skills and the model policy — the inputs a stage's
#     decision is read from.
#   --pin: also the stage execution code the pin gate runs from the built version
#     directory (stage-call.sh, the lib it sources, the provider CLIs). Such a diff
#     can change any product-stage decision, so it gates the whole product set.
#     supervisor stays out unless its own prompt or arbiter code changed: the gate
#     spends its terra arbitrations only on a diff that touches that stage.
# No output means no eval stage is affected (a pure test, doc or lesson diff).
set -euo pipefail
pin=0
[[ "${1:-}" != --pin ]] || { pin=1; shift; }
(($# == 0)) || { echo 'usage: decision-stages.sh [--pin] < paths' >&2; exit 2; }
review_skill="${ZF_REVIEW_SKILL:-code-review}"
declare -A affected=()
path=''
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    engine/prompts/triage.*|.zenoforge/prompts/triage.*) affected[triage]=1; affected[end-to-end]=1 ;;
    engine/prompts/advisor*|.zenoforge/prompts/advisor*) affected[advisor]=1; affected[end-to-end]=1 ;;
    engine/prompts/implement-contract.md|.zenoforge/prompts/implement-contract.md) affected[implement]=1; affected[end-to-end]=1 ;;
    engine/prompts/review-contract.md|.zenoforge/prompts/review-contract.md|".agents/skills/$review_skill"/*|engine/mac-autopilot/review-contract.sh)
      affected[review]=1; affected[end-to-end]=1 ;;
    .agents/skills/triage/*|.agents/skills/ask-matt/*) affected[triage]=1; affected[end-to-end]=1 ;;
    .agents/skills/implement/*|.agents/skills/tdd/*|.agents/skills/diagnosing-bugs/*) affected[implement]=1; affected[end-to-end]=1 ;;
    .agents/skills/to-tickets/*|.agents/skills/to-spec/*) affected[end-to-end]=1 ;;
    engine/prompts/recut.*|engine/prompts/guarded-recut-hand.md|.zenoforge/prompts/recut.*|.zenoforge/prompts/guarded-recut-hand.md)
      affected[end-to-end]=1 ;;
    engine/prompts/supervisor-arbiter.md|.zenoforge/prompts/supervisor-arbiter.md|engine/prompts/supervisor-cap-triage.md|.zenoforge/prompts/supervisor-cap-triage.md)
      affected[supervisor]=1 ;;
    engine/prompts/*|engine/model-policy.default.json|.zenoforge/prompts/*|.zenoforge/model-policy.default.json)
      affected[triage]=1; affected[advisor]=1; affected[implement]=1; affected[review]=1; affected[end-to-end]=1 ;;
  esac
  if (( pin )); then
    case "$path" in
      engine/lib.sh|engine/config.sh|engine/lib.d/*|engine/eval/stage-call.sh|engine/bin/*|engine/providers/*)
        affected[triage]=1; affected[advisor]=1; affected[implement]=1; affected[review]=1; affected[end-to-end]=1 ;;
      engine/mac-autopilot/scheduler.d/evals-arbiter.sh)
        affected[supervisor]=1 ;;
    esac
  fi
done
for stage in triage advisor implement review supervisor end-to-end; do
  [[ -n "${affected[$stage]:-}" ]] && printf '%s ' "$stage"
done
printf '\n'
