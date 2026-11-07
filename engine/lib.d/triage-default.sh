# 2026-11-06 founder ruling ("triage decides by default; advisor only for
# irreversible, production-data or security calls"): 38-41% of triage tickets
# went to the advisor -- one web tab with an 18h p50 -- for judgments the
# implementer could take itself. This module owns the advisor_reason contract
# and the two triage routing decisions that ruling changed. The helpers assign
# the caller's script-level STATE, BRIEF, ADVISOR_ROUTE_REASON and
# ADVISOR_DEFAULT_SOURCE variables (run-triage.sh has no locals at that
# level), the same way route_to_advisor() assigns ISSUE_VERDICT_GUARD_SKIPPED.

# triage_advisor_reason <result-json> -- normalize the model's advisor_reason
# output. Only the three advisor-only calls survive; anything else, including
# a field an older target-repository prompt override never produced, is none,
# so an override that predates the field can only ever take the default.
triage_advisor_reason() {
  local reason
  reason="$(jq -r '.advisor_reason // "none"' <<< "$1")"
  case "$reason" in
    irreversible|production-data|security) printf '%s\n' "$reason" ;;
    *) printf '%s\n' none ;;
  esac
}


# triage_route_model_verdict <n> <model-state> <advisor-reason> <risk> <level> <phase>
# Route a model verdict of ready-for-human or needs-owner. The 2026-09-15
# ruling stands (neither may survive as a human terminal); the 2026-11-06
# ruling adds that the advisor sees one only for an advisor-only call. The
# default still passes through ladder_state() -- the 2026-09-12 autonomy gate
# over risk_class/level/phase is untouched, so an out-of-set measurement the
# model parked on ready-for-human is refused exactly like an over-admitted
# ready-for-agent.
triage_route_model_verdict() {
  local n="$1" model_state="$2" advisor_reason="$3" risk_class="$4" level="$5" phase="$6"
  if [ "$advisor_reason" != none ]; then
    echo "run-triage: #$n model verdict $model_state + advisor_reason=$advisor_reason -> needs-advisor (an irreversible, production-data or security call is the advisor's)" >&2
    BRIEF="**Routed to the advisor instead of a human.** This triage run judged issue #$n to carry an advisor-only call (advisor_reason: $advisor_reason); under the 2026-09-15 ruling that call is the advisor's first.

$BRIEF"
    STATE="needs-advisor" ADVISOR_ROUTE_REASON=model_verdict_human
    return 0
  fi
  echo "run-triage: #$n model verdict $model_state -> triage default (advisor_reason=none); the implementer decides the open point" >&2
  if [ "$(ladder_state "$risk_class" "$level" "$phase")" = ready-for-agent ]; then
    BRIEF="**Triage took the default.** This ticket's open point is an implementer's judgment call, not an advisor-only call, so under the default-first routing it enters implementation directly; the implementer decides the open point and records the choice in the PR.

$BRIEF"
    STATE="ready-for-agent" ADVISOR_DEFAULT_SOURCE=model_verdict_human
  else
    BRIEF="**Triage took the default, and the autonomy gate still refused it.** The open point is the implementer's to decide, but the measured risk_class=$risk_class level=$level under AGENT_PHASE=$phase is outside this phase's autonomy set, so the advisor reviews it before implementation.

$BRIEF"
    STATE="needs-advisor" ADVISOR_ROUTE_REASON=autonomy_gate
  fi
}


# triage_route_l2_freshness <n> <advisor-reason> -- route a phase-3 L2
# verdict whose GitNexus index freshness stayed unconfirmed. Unconfirmed
# freshness is an environment condition, not a judgment call: since
# 2026-11-06 it no longer routes to the advisor on its own. The advisor sees
# this gate only when the model also named an advisor-only call; otherwise the
# verdict's state stands and the brief records that the impact was never
# confirmed, so the implementer verifies the blast radius the index could not.
triage_route_l2_freshness() {
  local n="$1" advisor_reason="$2"
  if [ "$advisor_reason" != none ]; then
    echo "run-triage: #$n unconfirmed L2 freshness and advisor_reason=$advisor_reason keep admission closed; routing to advisor" >&2
    STATE=needs-advisor ADVISOR_ROUTE_REASON=l2_freshness
    BRIEF="**L2 impact freshness was not confirmed.** The phase-3 L2 admission gate remains closed; the advisor must resolve the impact gate.

$BRIEF"
  else
    echo "run-triage: #$n unconfirmed L2 freshness alone no longer routes to the advisor; keeping the verdict's state ($STATE) with the impact marked unconfirmed" >&2
    ADVISOR_DEFAULT_SOURCE=l2_freshness
    BRIEF="**L2 impact freshness was not confirmed.** The impact evidence that would normally gate this L2 admission stayed unavailable (an environment condition, not a problem with this ticket), so this ticket proceeds on triage's default: the implementer must treat the L2 impact as unconfirmed and verify the affected symbols directly.

$BRIEF"
  fi
}
