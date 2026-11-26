#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

A="$test_env_root/implement-route-deferred-review"
export AGENT_HOME="$A" test_env_bin
mkdir -p "$A/logs" "$test_env_bin"
LOG="$A/scheduler.log"; UNITS="$A/units.json"; COOLDOWN="$A/cooldown.json"; STAMP=2026-11-21T23:30:00Z
NOW_EPOCH="$(date +%s)"; MAX=8; TICK_REVIEW_WAITS=""
: > "$LOG"; echo '{}' > "$COOLDOWN"
test_cli_path=""
while IFS= read -r path_entry; do
  [[ -n "$path_entry" && "$path_entry" != "$test_host_home"/* ]] && test_cli_path="${test_cli_path:+$test_cli_path:}$path_entry"
done < <(tr ':' '\n' <<<"${PATH#"$test_env_bin":}")
export PATH="$test_env_bin:$test_cli_path" MODEL_POLICY_DEFAULT="$script_dir/../../model-policy.default.json"
export MODEL_POLICY_FILE="$A/model-policy.json" ZCODE_PROVIDER_CONFIG_FILE="$A/zcode-config.json"
export CODEX_EXHAUSTED_MARKER_FILE="$A/codex-exhausted-until" CODEX_UNAVAILABLE_MARKER_FILE="$A/codex-unavailable-until"
export CODEX_PROVIDER_PROBE_REQUIRED_FILE="$A/probe-required"
export ZCODE_EXHAUSTED_MARKER_FILE="$A/zcode-exhausted-until" ZCODE_QUOTA_SNAPSHOT_FILE="$A/zc-quota.json"
export CLAUDE_EXHAUSTED_MARKER_FILE="$A/claude-exhausted-until" CLAUDE_QUOTA_SNAPSHOT_FILE="$A/claude-quota.json"

source "$script_dir/core.sh"
source "$script_dir/units.sh"
source "$script_dir/../../lib.d/codex-budget.sh"
source "$script_dir/../../lib.d/model-policy.sh"
source "$script_dir/../../lib.d/locks.sh"
source "$script_dir/models.sh"
source "$script_dir/review-rules.sh"

fail() { echo "not ok - $*" >&2; cat "$LOG" >&2; exit 1; }

# Stubs: the ledger write, the model table and the CLI/probe checks. The hold, cap and verdict logic is real.
set_unit() { local tmp="$A/units.tmp"; jq --arg id "$1" "(.units[] | select(.id==\$id)) |= ($2)" "$UNITS" > "$tmp" && mv "$tmp" "$UNITS"; }
model_policy_model_allowed_for_role() { return 0; }
routing_configured() { return 1; }
codex_probe_ok() { return 0; }
model_tuple_field() { case "$1:$2" in review:0) [[ "${REVIEW_POOL:-all}" == claude-only ]] || echo gpt-5.5 ;; review:1) echo high ;; review_cross:0) echo GLM-5.3 ;; review_cross:1) echo max ;; review_fallback:0) echo claude-sonnet-4-6 ;; review_fallback:1) echo high ;; esac; }
review_identity_for_model() { case "$1" in gpt-*) echo "codex:$1:$2" ;; GLM-*) echo "zcode:$1:$2" ;; claude-*) echo "claude:$1:$2" ;; *) return 1 ;; esac; }
toggle_cli() { if [[ "$2" == on ]]; then printf '#!/usr/bin/env bash\nexit 0\n' > "$test_env_bin/$1"; chmod +x "$test_env_bin/$1"; else rm -f "$test_env_bin/$1"; fi; }
command() { if [[ "${1:-}" == -v && ( "${2:-}" == claude || "${2:-}" == codex ) ]]; then [[ -x "$test_env_bin/$2" ]]; return; fi; builtin command "$@"; }
glm_quota_stale() { jq -n '{freshness:"fresh",read_at:0,max_age_seconds:900,five_h_pct:0,week_pct:1,cap_5h:60,cap_week:100}' > "$ZCODE_QUOTA_SNAPSHOT_FILE"; }
future() { echo $(( $(date +%s) + 3600 )); }
write_units() { # N review-pending Claude-authored units
  jq -cn --argjson n "$1" '{units:[range(0;$n) as $i | {id:("u\($i)"),stage:"review-pending",implement_identity:"claude:claude-opus-4-7:high",history:[]}]}' > "$UNITS"
}
reset_route() {
  IMPLEMENT_ROUTE_REVIEWABILITY_CACHE=(); IMPLEMENT_ROUTE_SKIPS=""; : > "$LOG"
  rm -f "$AGENT_HOME/logs/head-watch.alerts" "$CODEX_EXHAUSTED_MARKER_FILE" "$CODEX_UNAVAILABLE_MARKER_FILE" "$ZCODE_EXHAUSTED_MARKER_FILE" "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" "$CLAUDE_EXHAUSTED_MARKER_FILE"
}

# (a) GLM held by a future marker, Codex without its CLI, 3 Claude units waiting: reviewable, deferred line, no alert.
write_units 3; reset_route; toggle_cli codex off; toggle_cli claude off; glm_quota_stale
glm_until="$(future)"; printf '%s\n' "$glm_until" > "$ZCODE_EXHAUSTED_MARKER_FILE"
implement_route_family_reviewable claude || fail "(a) claude not reviewable: $IMPLEMENT_REVIEWER_REASON"
grep -Fq "implement-route deferred-review family=claude reviewer=glm until=$glm_until waiting=3/16" "$LOG" || fail "(a) deferred line missing"
! grep -Fq 'IMPLEMENT-ROUTE-UNREVIEWABLE' "$AGENT_HOME/logs/head-watch.alerts" 2>/dev/null || fail "(a) alert written"

# (b) same, but the GLM marker is absent and the quota read is stale: no end epoch, so unreviewable and alerted.
write_units 3; reset_route; toggle_cli codex off; glm_quota_stale
if implement_route_family_reviewable claude; then fail "(b) claude reviewable with GLM quota stale"; fi
grep -Fq 'implement-route unreviewable family=claude reason=glm-hold' "$LOG" || fail "(b) unreviewable line missing"
grep -Fq 'IMPLEMENT-ROUTE-UNREVIEWABLE family=claude reason=glm-hold' "$AGENT_HOME/logs/head-watch.alerts" || fail "(b) alert missing"

# (c) 16 counted units with MAX=8 and a timed Codex hold: unreviewable with reason deferred-review-cap.
write_units 16; reset_route; toggle_cli codex off; glm_quota_stale; future > "$CODEX_EXHAUSTED_MARKER_FILE"
if implement_route_family_reviewable claude; then fail "(c) claude reviewable at the cap"; fi
[[ "$IMPLEMENT_REVIEWER_REASON" == deferred-review-cap ]] || fail "(c) reason was $IMPLEMENT_REVIEWER_REASON"
grep -Fq 'IMPLEMENT-ROUTE-UNREVIEWABLE family=claude reason=deferred-review-cap' "$AGENT_HOME/logs/head-watch.alerts" || fail "(c) alert missing"

# (d) codex and glm families with the same holds (GLM, Codex and the Claude fallback all on a marker): unreviewable as before, nothing deferred.
write_units 3; reset_route; toggle_cli codex off; toggle_cli claude off; glm_quota_stale
future > "$ZCODE_EXHAUSTED_MARKER_FILE"; future > "$CODEX_EXHAUSTED_MARKER_FILE"; future > "$CLAUDE_EXHAUSTED_MARKER_FILE"
if implement_route_family_reviewable codex; then fail "(d) codex reviewable"; fi
if implement_route_family_reviewable glm; then fail "(d) glm reviewable"; fi
! grep -Fq 'deferred-review' "$LOG" || fail "(d) codex or glm deferred"
grep -Fq 'IMPLEMENT-ROUTE-UNREVIEWABLE family=codex' "$AGENT_HOME/logs/head-watch.alerts" || fail "(d) codex alert missing"
grep -Fq 'IMPLEMENT-ROUTE-UNREVIEWABLE family=glm' "$AGENT_HOME/logs/head-watch.alerts" || fail "(d) glm alert missing"

write_units 0; reset_route; future > "$CLAUDE_EXHAUSTED_MARKER_FILE"
(
  model_tuple_field() { case "$1:$2" in review_fallback:0) echo claude-sonnet-4-6 ;; review_fallback:1) echo high ;; esac; }
  routing_configured() { return 0; }
  routing_implement_family_order() { printf 'glm\n'; }
  routing_review_candidates() { printf 'claude:claude-sonnet-4-6:high\n'; }
  PICK_PROVIDER=""
  if pick_routed_implementer '{}' ''; then fail "(d2) glm implement picked without a reviewer"; fi
  [[ -z "$PICK_PROVIDER" ]] || fail "(d2) glm implement picked $PICK_PROVIDER"
  [[ "$IMPLEMENT_REVIEWER_REASON" == reviewer-held:claude ]] || fail "(d2) glm wait reason was $IMPLEMENT_REVIEWER_REASON"
  IMPLEMENT_ROUTE_REVIEWABILITY_CACHE=(); IMPLEMENT_ROUTE_SKIPS=""
  if pick_routed_implementer '{}' ''; then fail "(d2) glm implement picked on a repeated check"; fi
  [[ "$IMPLEMENT_REVIEWER_REASON" == reviewer-held:claude ]] || fail "(d2) repeated glm wait reason was $IMPLEMENT_REVIEWER_REASON"
)
grep -Fq 'implement-route unreviewable family=glm reason=reviewer-held:claude' "$LOG" || fail "(d2) glm wait log missing"
grep -Fq 'IMPLEMENT-ROUTE-UNREVIEWABLE family=glm reason=reviewer-held:claude' "$AGENT_HOME/logs/head-watch.alerts" || fail "(d2) Claude hold alert missing"
glm_alerts="$(grep -F "${STAMP:0:13}" "$AGENT_HOME/logs/head-watch.alerts" | grep -Fc 'IMPLEMENT-ROUTE-UNREVIEWABLE family=glm ' || true)"
[[ "$glm_alerts" == 1 ]] || fail "(d2) glm alert count for the hour was $glm_alerts"

# (e) Claude-authored unit, GLM held, Codex without CLI, Claude fallback free: review pick selects nothing.
write_units 0; reset_route; toggle_cli codex off; toggle_cli claude on; glm_quota_stale; future > "$ZCODE_EXHAUSTED_MARKER_FILE"
unit='{"id":"u-e","issue":"1","stage":"review-pending","implement_identity":"claude:claude-opus-4-7:high","history":[]}'
PICK_MODEL=""; PICK_PROVIDER=""
if pick_review_for_unit "$unit"; then fail "(e) same-family review picked: ${PICK_PROVIDER:-none} ${PICK_MODEL:-none}"; fi
[[ -z "$PICK_MODEL" ]] || fail "(e) PICK_MODEL set to $PICK_MODEL"

# (f) review_family_verdict: a same-family READY is discarded; other-family READY and NOT_READY pass.
printf '%s\n' "$(jq -cn '{units:[{id:"u-f",stage:"review-pending",implement_identity:"claude:claude-opus-4-7:high",reviewed_sha:"abc",history:[]}]}')" > "$UNITS"
unit_f="$(jq -c '.units[0]' "$UNITS")"
if review_family_verdict "$unit_f" "claude:claude-opus-4-7:high" READY; then fail "(f) claude READY from claude not discarded"; fi
[[ "$(jq -r '.units[0].stage' "$UNITS")" == review-pending ]] || fail "(f) stage not review-pending"
[[ "$(jq -r '.units[0].reviewed_sha' "$UNITS")" == null ]] || fail "(f) reviewed_sha not cleared"
[[ "$(jq -r '.units[0].history[-1].stage' "$UNITS")" == review-same-family ]] || fail "(f) no review-same-family event"
[[ "$(jq -r '.units[0].history[-1].result' "$UNITS")" == 'author=claude reviewer=claude' ]] || fail "(f) event result wrong"
[[ "$(unit_retries u-f verdict-missing)" == 0 ]] || fail "(f) counted as verdict-missing"
grep -Fq 'review-family verdict discarded unit=u-f author=claude reviewer=claude' "$LOG" || fail "(f) discard log missing"
review_family_verdict "$unit_f" "zcode:GLM-5.3:max" READY || fail "(f) other-family READY discarded"
review_family_verdict "$unit_f" "claude:claude-opus-4-7:high" NOT_READY || fail "(f) NOT_READY changed"

# (g) Claude-authored unit, GLM held, Codex quota used up, credits under the cap: reviewable on credits, no deferred line.
# (h) the same with credits at the cap: back to the deferred route, which waits for the GLM hold.
export CODEX_SESSIONS_DIR="$A/sessions"; mkdir -p "$CODEX_SESSIONS_DIR"
balance() { printf '{"payload":{"rate_limits":{"credits":{"has_credits":true,"balance":"%s"}}}}\n' "$1" > "$CODEX_SESSIONS_DIR/rollout-a.jsonl"; }
CODEX_CREDITS_ROLES="review arbiter"; CODEX_CREDITS_CAP=5000; CODEX_CREDITS_START_BALANCE=29582
write_units 3; reset_route; toggle_cli codex on; toggle_cli claude off; glm_quota_stale
glm_until="$(future)"; printf '%s\n' "$glm_until" > "$ZCODE_EXHAUSTED_MARKER_FILE"; future > "$CODEX_EXHAUSTED_MARKER_FILE"
balance 29000.5
implement_route_family_reviewable claude || fail "(g) claude not reviewable on credits: $IMPLEMENT_REVIEWER_REASON"
! grep -Fq 'deferred-review' "$LOG" || fail "(g) deferred line written while credits are open"
! grep -Fq 'IMPLEMENT-ROUTE-UNREVIEWABLE' "$AGENT_HOME/logs/head-watch.alerts" 2>/dev/null || fail "(g) alert written"
write_units 3; reset_route; toggle_cli codex on; toggle_cli claude off; glm_quota_stale
glm_until="$(future)"; printf '%s\n' "$glm_until" > "$ZCODE_EXHAUSTED_MARKER_FILE"; printf '%s\n' "$(( $(date +%s) + 7200 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
balance 24582
implement_route_family_reviewable claude || fail "(h) claude not deferred at the credits cap: $IMPLEMENT_REVIEWER_REASON"
grep -Fq "implement-route deferred-review family=claude reviewer=glm until=$glm_until waiting=3/16" "$LOG" || fail "(h) deferred line missing at the credits cap"
CODEX_CREDITS_ROLES=""; CODEX_CREDITS_CAP=""; CODEX_CREDITS_START_BALANCE=""

REVIEW_POOL=claude-only; CFG='{"models":{"implement_share":{"claude":0,"zcode":100,"codex":0}}}'
write_units 0; reset_route; toggle_cli claude on; future > "$CLAUDE_EXHAUSTED_MARKER_FILE"
unit='{"id":"u-i","issue":"1457","implement_provider":"zcode"}'
PICK_ROUTE_PROVIDER=""
if pick_implementer "$unit"; then fail "(i) glm implement picked with its only reviewer held by Claude"; fi
[[ "$IMPLEMENT_REVIEWER_REASON" == reviewer-held:claude ]] || fail "(i) reviewer hold reason was $IMPLEMENT_REVIEWER_REASON"
grep -Fq 'implement-route deferred-review family=glm reviewer=claude reason=reviewer-held:claude' "$LOG" || fail "(i) glm route did not wait"
! grep -Fq 'implement-route unreviewable family=glm' "$LOG" || fail "(i) glm route was logged as unreviewable"
alerts="$(grep -Fc 'IMPLEMENT-ROUTE-UNREVIEWABLE family=glm reason=reviewer-held:claude' "$AGENT_HOME/logs/head-watch.alerts" 2>/dev/null || true)"
[[ "$alerts" == 1 ]] || fail "(i) expected one hourly alert, got $alerts"
if pick_implementer "$unit"; then fail "(i) second glm implement picked with its only reviewer held by Claude"; fi
alerts="$(grep -Fc 'IMPLEMENT-ROUTE-UNREVIEWABLE family=glm reason=reviewer-held:claude' "$AGENT_HOME/logs/head-watch.alerts" 2>/dev/null || true)"
[[ "$alerts" == 1 ]] || fail "(i) repeated hourly alert, got $alerts"

echo 'ok - implement-route deferred review'
