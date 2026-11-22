# Recut proposes children and writes no code, so it may leave an exhausted Codex route for GLM. Implement and triage may not.

# recut_glm_identity [issue] -> while Codex is exhausted: the GLM identity when GLM has quota, else Claude (head 2026-11-22 under
# the founder's 11-21 balance ruling: haiku, sonnet after a failed haiku recut of that issue, never opus) unless the routing
# file reserves Claude. Callers stay on Codex when it fails.
recut_glm_identity() {
  local identity model
  codex_quota_exhausted "$(model_policy identity work)" || return 1
  if [ "$(zcode_quota_status)" = available ]; then model_policy identity hand-zcode; return; fi
  ! declare -F routing_configured >/dev/null || ! routing_configured || { routing_family_order | grep -qx claude && ! routing_implement_off claude; } || return 1
  identity="$(model_policy identity hand-claude)" || return 1
  [ -z "${1:-}" ] || ! state_read "$1" 2>/dev/null | jq -e '.recut_claude_haiku_failed_at' >/dev/null 2>&1 || identity="${identity/claude-haiku-5-5/claude-sonnet-5-5}"
  model="${identity#*:}"; model="${model%:*}"
  model_policy_model_allowed_for_role "$model" hand-claude && command -v claude >/dev/null 2>&1 && ! provider_quota_exhausted claude \
    && printf '%s\n' "$identity"
}

# policy_route_held <unit> <route> <reason>: a held route logs every tick and reaches the supervisor once a day. A loop that
# breaks on a hold looks like an idle queue otherwise (2026-11-05: recut stopped for hours with status=0 on every tick).
policy_route_held() {
  local unit="$1" route="$2" reason="$3"
  echo "issue-pipeline: $unit route held: $route reason=$reason" >&2
  supervisor_inbox_append_once "policy-route-held:$unit:$reason:$(date -u +%F)" \
    "policy-route-held unit=$unit route=$route reason=$reason zcode=$(zcode_quota_status): the $unit queue is not moving" || true
}
