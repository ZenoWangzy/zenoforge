# One wording of the advisor plan contract for the batch first prompt and its plan re-ask, so they cannot drift.
# The target overlay can replace prompts/advisor-batch.md, so the engine states the contract itself.
advisor_plan_contract() {
  printf 'a complete plan with changes (file, symbol, change), tests_fail_first, and non_goals'
}

advisor_batch_manifest_text() {
  printf '\n## Frozen issue manifest\nReply with this exact `requested_issues` array: %s\nEvery ruling except `tracker` and `duplicate` must include %s.\n' \
    "$1" "$(advisor_plan_contract)"
}
