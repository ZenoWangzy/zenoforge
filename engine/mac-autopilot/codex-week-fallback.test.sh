#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

A="$test_env_root/codex-week/autopi"
mkdir -p "$A"
LOG="$A/scheduler.log"; UNITS="$A/units.json"; COOLDOWN="$A/cooldown.json"; STAMP=2026-11-05T00:00:00Z
NOW_EPOCH=1793836800
: > "$LOG"; echo '{"units":[]}' > "$UNITS"; echo '{}' > "$COOLDOWN"
export CODEX_QUOTA_SNAPSHOT_FILE="$A/codex-quota.json"
export CODEX_WEEK_STOP_PCT=100 CODEX_IMPLEMENT_STOP_PCT=95
source "$script_dir/scheduler.d/core.sh"
source "$script_dir/../lib.d/codex-budget.sh"
source "$script_dir/scheduler.d/models.sh"

fail() { echo "not ok - $*" >&2; cat "$LOG" >&2; exit 1; }
# Claude workers stop at 95 of the week until its reset; sessions keep the rest.
export CLAUDE_QUOTA_SNAPSHOT_FILE="$A/claude-quota.json"
cw() { jq -n --argjson p "$1" --argjson r "$2" '{week_pct:$p,week_reset:$r}' > "$CLAUDE_QUOTA_SNAPSHOT_FILE"; }
cw 94 $((NOW_EPOCH + 3600)); if provider_quota_exhausted claude; then fail 'Claude stopped at 94%'; fi
cw 95 $((NOW_EPOCH + 3600)); provider_quota_exhausted claude || fail 'Claude ran at 95%'
cw 95 $((NOW_EPOCH - 1)); if provider_quota_exhausted claude; then fail 'a past Claude week_reset did not end the stop'; fi
provider_quota_exhausted() { return 1; }
# ZCode's weekly hold sits at 100: zc-quota spends a weekly reset at 98.
zc_status() { jq -n --argjson w "$1" --argjson now "$NOW_EPOCH" '{five_h_pct:1,week_pct:$w,read_at:$now,freshness:"fresh"}' > "$A/zc.json"; ZCODE_QUOTA_SNAPSHOT_FILE="$A/zc.json" zcode_quota_status; }
[[ "$(zc_status 99)" == available && "$(zc_status 100)" == exhausted ]] || fail "ZCode week hold: 99=$(zc_status 99) 100=$(zc_status 100)"
provider_of() { case "$1" in gpt-*) echo codex ;; claude-*) echo claude ;; *) echo unknown ;; esac; }
model_forbidden_by_policy() { return 1; }
zcode_quota_status() { echo unknown; }
pick_zcode_implementer() { return 1; }
pick_claude_implementer() { PICK_PROVIDER=claude; PICK_MODEL=claude-sonnet-5-5; PICK_EFFORT=high; PICK_HARD=false; }
codex() { :; }
CFG='{"models":{"review":["gpt-6-luna","max"],"review_fallback":["claude-sonnet-5-5","high"],"implement":["gpt-6-luna","max"],"implement_share":{"claude":50,"codex":50,"zcode":0},"hard":{"provider":"codex","model":"gpt-6.1-terra","effort":"high"}}}'
SCHED_MODEL_POLICY_JSON='{}'
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

week 100 $((NOW_EPOCH - 1))
pick_configured_model review '{}' && [[ "$PICK_PROVIDER" == codex ]] || fail 'a past week_reset did not end the stop'
week 80 $((NOW_EPOCH + 3600))
pick_configured_model review '{}' && [[ "$PICK_PROVIDER" == codex ]] || fail 'review left Codex at 80%'

# Implementation stops at 95 and moves to ZCode; reviews stay on Codex up to the wall. With Claude off, every path that used it reaches ZCode.
pick_zcode_implementer() { PICK_PROVIDER=zcode; PICK_MODEL=GLM-5.3; PICK_EFFORT=max; PICK_HARD=false; }
CFG="$(jq '.models.implement_share.claude=0 | del(.models.review_fallback)' <<<"$CFG")"
week 98 $((NOW_EPOCH + 3600))
pick_configured_model review '{}' && [[ "$PICK_PROVIDER" == codex ]] || fail 'review left Codex below the wall'
pick_implementer "$sticky" && [[ "$PICK_PROVIDER" == zcode ]] || fail "implementation stayed on $PICK_PROVIDER at 98%"
pick_implementer '{"id":"c","implement_provider":"claude"}' || fail 'sticky Claude unit had no route at share 0'
[[ "$PICK_PROVIDER" == zcode && "$PICK_REASON" == claude-share-off-zcode ]] || fail "sticky Claude went to $PICK_PROVIDER/$PICK_REASON"
week 100 $((NOW_EPOCH + 3600))
pick_implementer '{"id":"h","hard_escalated":true}' || fail 'hard unit had no route at the wall'
[[ "$PICK_PROVIDER" == zcode && "$PICK_REASON" == hard-fallback-zcode && "$PICK_HARD" == true ]] || fail "hard went to $PICK_PROVIDER/$PICK_REASON"
if pick_configured_model review '{}'; then fail 'review had a model at the wall with no fallback'; fi
echo 'ok - over the weekly stop, reviews, repairs and hard units move to Claude; share 0 and a reset are honoured'
