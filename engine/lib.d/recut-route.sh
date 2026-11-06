# Recut proposes children and writes no code, so it may leave an exhausted Codex route for GLM. Implement and triage may not.

# recut_glm_identity -> the GLM identity, only while Codex is exhausted and GLM has quota. Callers stay on Codex when it fails.
recut_glm_identity() {
  local identity
  codex_quota_exhausted "$(model_policy identity work)" || return 1
  identity="$(model_policy identity hand-zcode)" || return 1
  [ "$(zcode_quota_status)" = available ] && printf '%s\n' "$identity"
}

# policy_route_held <unit> <route> <reason>: a held route logs every tick and reaches the supervisor once a day. A loop that
# breaks on a hold looks like an idle queue otherwise (2026-11-05: recut stopped for hours with status=0 on every tick).
policy_route_held() {
  local unit="$1" route="$2" reason="$3"
  echo "issue-pipeline: $unit route held: $route reason=$reason" >&2
  supervisor_inbox_append_once "policy-route-held:$unit:$reason:$(date -u +%F)" \
    "policy-route-held unit=$unit route=$route reason=$reason zcode=$(zcode_quota_status): the $unit queue is not moving" || true
}
