#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

A="$test_env_root/codex-week/autopi"
mkdir -p "$A"
LOG="$A/scheduler.log"; UNITS="$A/units.json"; COOLDOWN="$A/cooldown.json"; STAMP=2026-11-05T00:00:00Z
NOW_EPOCH=1793836800
: > "$LOG"; echo '{"units":[]}' > "$UNITS"; echo '{}' > "$COOLDOWN"
export CODEX_QUOTA_SNAPSHOT_FILE="$A/codex-quota.json" CODEX_EXHAUSTED_MARKER_FILE="$A/codex-exhausted-until" CODEX_PROVIDER_PROBE_REQUIRED_FILE="$A/probe-required"
export CODEX_WEEK_STOP_PCT=100 CODEX_IMPLEMENT_STOP_PCT=95
source "$script_dir/scheduler.d/core.sh"
source "$script_dir/../lib.d/codex-budget.sh" && source "$script_dir/../lib.d/model-policy.sh"
source "$script_dir/scheduler.d/models.sh"

fail() { echo "not ok - $*" >&2; cat "$LOG" >&2; exit 1; }
# Claude workers stop at 95 of the week until its reset; sessions keep the rest.
export CLAUDE_QUOTA_SNAPSHOT_FILE="$A/claude-quota.json" CLAUDE_EXHAUSTED_MARKER_FILE="$A/claude-exhausted-until"
cw() { jq -n --argjson p "$1" --argjson r "$2" '{week_pct:$p,week_reset:$r}' > "$CLAUDE_QUOTA_SNAPSHOT_FILE"; }
cw 94 $((NOW_EPOCH + 3600)); if provider_quota_exhausted claude; then fail 'Claude stopped at 94%'; fi
cw 95 $((NOW_EPOCH + 3600)); provider_quota_exhausted claude || fail 'Claude ran at 95%'
cw 95 $((NOW_EPOCH - 1)); if provider_quota_exhausted claude; then fail 'a past Claude week_reset did not end the stop'; fi
provider_quota_exhausted() { [[ "$1" == codex && -f "${CODEX_EXHAUSTED_MARKER_FILE:-}" ]] && (( $(<"$CODEX_EXHAUSTED_MARKER_FILE") > NOW_EPOCH )); }
# ZCode's weekly hold sits at 100: zc-quota spends a weekly reset at 98.
zc_status() { jq -n --argjson w "$1" --argjson now "$NOW_EPOCH" '{five_h_pct:1,week_pct:$w,read_at:$now,freshness:"fresh"}' > "$A/zc.json"; ZCODE_QUOTA_SNAPSHOT_FILE="$A/zc.json" zcode_quota_status; }
[[ "$(zc_status 99)" == available && "$(zc_status 100)" == exhausted ]] || fail "ZCode week hold: 99=$(zc_status 99) 100=$(zc_status 100)"
provider_of() { case "$1" in gpt-*) echo codex ;; claude-*) echo claude ;; *) echo unknown ;; esac; }
model_forbidden_by_policy() { return 1; }
model_policy_model_allowed_for_role() { [[ "$2" == review || "$2" == review_fallback ]]; }
zcode_quota_status() { echo unknown; }
pick_zcode_implementer() { return 1; }
pick_claude_implementer() { PICK_PROVIDER=claude; PICK_MODEL=claude-sonnet-5-5; PICK_EFFORT=high; PICK_HARD=false; }
codex() { :; }
claude() { :; }
codex_probe_ok() { return 0; }
CFG='{"models":{"review":["gpt-6-luna","max"],"review_fallback":["claude-sonnet-5-5","high"],"implement":["gpt-6-luna","max"],"implement_share":{"claude":50,"codex":50,"zcode":0},"hard":{"provider":"codex","model":"gpt-6.1-terra","effort":"high"}}}'
export SCHED_MODEL_POLICY_JSON='{}' MODEL_POLICY_DEFAULT="$script_dir/../model-policy.default.json"
week() { jq -n --argjson p "$1" --argjson r "$2" '{week_pct:$p,week_reset:$r}' > "$CODEX_QUOTA_SNAPSHOT_FILE"; }
sticky='{"id":"u","implement_provider":"codex","implement_route_provider":"codex"}'

week 100 $((NOW_EPOCH + 3600))
pick_configured_model review '{}' || fail 'review had no model at the wall'
[[ "$PICK_PROVIDER" == claude ]] || fail "review stayed on $PICK_PROVIDER at the wall"
pick_implementer "$sticky" || fail 'sticky Codex repair stopped at the wall'
[[ "$PICK_PROVIDER" == claude && "$PICK_REASON" == quota-fallback-to-claude ]] || fail "repair went to $PICK_PROVIDER/$PICK_REASON"
pick_implementer '{"id":"h","hard_escalated":true}' || fail 'hard unit stopped at the wall'
[[ "$PICK_PROVIDER" == claude && "$PICK_REASON" == hard-fallback-claude && "$PICK_HARD" == true ]] || fail "hard went to $PICK_PROVIDER/$PICK_REASON"

CFG="$(jq '.models.implement_share.claude=0' <<<"$CFG")"
if pick_implementer "$sticky"; then fail 'claude share 0 still routed to Claude'; fi
CFG="$(jq '.models.implement_share.claude=50' <<<"$CFG")"

CFG="$(jq '.models.implement_share={claude:100,codex:0,zcode:0}' <<<"$CFG")"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
if pick_implementer '{"id":"unreviewable-claude"}'; then fail 'Claude implement dispatched without an other-family reviewer'; fi
if pick_implementer '{"id":"unreviewable-claude-again"}'; then fail 'second unreviewable Claude implement dispatched'; fi
[[ "$(grep -Fc 'implement-route unreviewable family=claude reason=codex-hold' "$LOG")" == 2 \
  && "$(grep -Fc 'IMPLEMENT-ROUTE-UNREVIEWABLE family=claude' "$AGENT_HOME/logs/head-watch.alerts")" == 1 ]] \
  || fail 'skip logging or the per-hour head-watch alert was not correct'
rm -f "$CODEX_EXHAUSTED_MARKER_FILE"
pick_implementer '{"id":"reviewable-claude"}' || fail 'Claude route changed when the Codex hold was absent'
[[ "$PICK_PROVIDER" == claude ]] || fail "available Claude share routed to $PICK_PROVIDER"
CFG="$(jq '.models.implement_share={claude:50,codex:50,zcode:0}' <<<"$CFG")"

week 100 $((NOW_EPOCH - 1))
pick_configured_model review '{}' && [[ "$PICK_PROVIDER" == codex ]] || fail 'a past week_reset did not end the stop'
week 80 $((NOW_EPOCH + 3600))
pick_configured_model review '{}' && [[ "$PICK_PROVIDER" == codex ]] || fail 'review left Codex at 80%'

# Implementation stops at 95 and moves to ZCode; reviews stay on Codex up to the wall. With Claude off, every path that used it reaches ZCode.
pick_zcode_implementer() { PICK_PROVIDER=zcode; PICK_MODEL=GLM-5.3; PICK_EFFORT=max; PICK_HARD=false; }
CFG="$(jq '.models.implement_share.claude=0 | del(.models.review_fallback)' <<<"$CFG")"
week 98 $((NOW_EPOCH + 3600))
pick_configured_model review '{}' && [[ "$PICK_PROVIDER" == codex ]] || fail 'review left Codex below the wall'
if pick_implementer "$sticky"; then fail 'Codex route had no independent reviewer'; else grep -Fq 'implement-route unreviewable family=codex reason=review-config' "$LOG" || fail 'unreviewable Codex route was not logged'; fi
pick_implementer '{"id":"c","implement_provider":"claude"}' || fail 'sticky Claude unit had no route at share 0'
[[ "$PICK_PROVIDER" == zcode && "$PICK_REASON" == claude-share-off-zcode ]] || fail "sticky Claude went to $PICK_PROVIDER/$PICK_REASON"
week 100 $((NOW_EPOCH + 3600))
pick_implementer '{"id":"h","hard_escalated":true}' || fail 'hard unit had no route at the wall'
[[ "$PICK_PROVIDER" == zcode && "$PICK_REASON" == hard-fallback-zcode && "$PICK_HARD" == true ]] || fail "hard went to $PICK_PROVIDER/$PICK_REASON"
if pick_configured_model review '{}'; then fail 'review had a model at the wall with no fallback'; fi
