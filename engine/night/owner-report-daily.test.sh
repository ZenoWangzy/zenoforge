#!/usr/bin/env bash
# Daily daytime owner report: the send window (one mail a day, no evening catch-up), the durable daily
# snapshot, the day and week comparison (a missing base drops that comparison), material changes with a
# traced cause or 未查明, the station section, and the output contract for the longer report.
# Covers owner-report-compare.sh, owner-report-compare.py and owner-report-render.sh (named here so a change to any of them selects this suite).
# The sender is a stub function here: nothing in this suite reaches the real mail path.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/maintainer-health-mail.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"

fail() { printf 'not ok - %s\n' "$1"; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
epoch() { date -u -d "$1" +%s; }

# --- Send window ---------------------------------------------------------------
now="$(epoch 2026-11-08T01:10:00Z)"
owner_report_in_send_window "$now" || fail 'the 09:00 Beijing slot is inside the window'
owner_report_in_send_window "$(epoch 2026-11-08T03:30:00Z)" || fail 'a late timer a few hours on is still inside the window'
for late in 2026-11-08T00:30:00Z 2026-11-08T12:18:00Z 2026-11-08T20:00:00Z; do
  if owner_report_in_send_window "$(epoch "$late")"; then fail "no mail outside daytime: $late"; fi
done
ok 'the send window is the Beijing daytime'

# --- Tick: one mail a day, none in the evening, no catch-up after a missed day ----
sends=0
notify_maintainer_health() { sends=$((sends + 1)); }
notify_maintainer_incident() { :; }
# A deployed host has no engine/lib.sh under MAC_AUTOPILOT_ROOT: the snapshot path must not need it.
export MAC_AUTOPILOT_ROOT="$tmp/host-root"
mkdir -p "$MAC_AUTOPILOT_ROOT"
home="$tmp/home"
mkdir -p "$home/night" "$home/state"
export ZF_ANOMALY_OWNERS_FILE="$tmp/none.json"
maintainer_health_mail_tick "$home" "$(epoch 2026-11-07T12:18:00Z)" >/dev/null
[[ "$sends" == 0 ]] || fail 'an evening tick must not send'
[[ "$(jq -r '.last_digest_slot' "$home/night/founder-health-mail.json")" == "" ]] || fail 'a skipped tick must not claim the slot'
[[ ! -e "$home/night/owner-report-snapshots" ]] || fail 'a skipped tick stores no snapshot'
maintainer_health_mail_tick "$home" "$(epoch 2026-11-08T01:20:00Z)" >/dev/null
[[ "$sends" == 1 ]] || fail 'the daytime tick sends once'
snap="$home/night/owner-report-snapshots/2026-11-08.json"
[[ "$(jq -r '[.schema, .day, (.figures | type)] | join(",")' "$snap")" == '1,2026-11-08,object' ]] || fail 'the tick stores the day snapshot beside the ledger'
before="$(cat "$snap")"
maintainer_health_mail_tick "$home" "$(epoch 2026-11-08T02:20:00Z)" >/dev/null
maintainer_health_mail_tick "$home" "$(epoch 2026-11-08T05:00:00Z)" >/dev/null
[[ "$sends" == 1 ]] || fail 'a second daytime tick the same day sends nothing'
[[ "$(cat "$snap")" == "$before" ]] || fail 'a stored snapshot is never replaced'
maintainer_health_mail_tick "$home" "$(epoch 2026-11-10T12:00:00Z)" >/dev/null
[[ "$sends" == 1 ]] || fail 'a missed day is skipped, not mailed late'
maintainer_health_mail_tick "$home" "$(epoch 2026-11-11T01:30:00Z)" >/dev/null
[[ "$sends" == 2 ]] || fail 'the next daytime slot sends once'
ok 'one mail a day, no evening mail, no catch-up'

# The render path reads snapshots and never creates the store.
fresh="$tmp/fresh"
mkdir -p "$fresh/night"
maintainer_health_mail_daily_facts "$fresh" "$fresh/night/founder-health-mail.json" "$now" "$SCRIPT_DIR/../.." >/dev/null
[[ ! -e "$fresh/night/owner-report-snapshots" ]] || fail 'render must not write the snapshot store'
ok 'render writes nothing'

# --- Stations -----------------------------------------------------------------------
runtime="$tmp/runtime"
mkdir -p "$runtime"
export MAC_AUTOPILOT_RUNTIME_DIR="$runtime"
jq -n --arg at "$(iso $((now - 3600)))" '{generated:$at, metrics:[
  {id:"implement.out_per_day",value:60,healthy:51,unhealthy:12,higher_is_better:true,status:"OK"},
  {id:"flow.merge_rate_per_hour",value:null,healthy:6.5,unhealthy:3.5,higher_is_better:true,status:"NO-DATA"},
  {id:"release.hours_waiting",value:30.04,healthy:4,unhealthy:12,higher_is_better:false,status:"UNHEALTHY"}]}' > "$runtime/node-health.json"
jq -n --arg at "$(iso $((now - 300)))" '{at:$at, stations:{release:{status:"STALLED",stall_min:600}}}' > "$runtime/station-health.json"
rows="$(owner_report_station_facts "$home" "$now")"
[[ "$(jq -r '[.[].key] | join(",")' <<< "$rows")" == 'implement,release' ]] || fail 'a station without a figure is dropped, not shown as zero'
[[ "$(jq -r '.[] | select(.key == "release") | .stall_hours == 10' <<< "$rows")" == true ]] || fail 'a stalled station carries its stall hours'
jq -n --arg at "$(iso $((now - 30 * 3600)))" '{generated:$at, metrics:[{id:"implement.out_per_day",value:60,healthy:51,status:"OK"}]}' > "$runtime/node-health.json"
[[ "$(owner_report_station_facts "$home" "$now")" == null ]] || fail 'a stale scorecard gives no station rows'
ok 'station rows come from fresh scorecards only'

# --- Comparison ---------------------------------------------------------------------
snaps="$tmp/snaps"
mkdir -p "$snaps"
export ZF_OWNER_REPORT_SNAPSHOT_DIR="$snaps"
yesterday_at=$((now - 86400))
jq -n --argjson at "$yesterday_at" '{schema:1,day:"2026-11-07",at:$at,figures:{finished:10,incidents:0,tokens:100000,"station:implement":100,"station:review":100}}' > "$snaps/2026-11-07.json"
jq -n --argjson at "$((now - 7 * 86400))" '{schema:1,day:"2026-11-01",at:$at,figures:{finished:8,tokens:90000}}' > "$snaps/2026-11-01.json"
stations_json='[{"key":"implement","name":"写代码","metric":"implement.out_per_day","unit":"次","phrase":"过去一天完成 ","value":60,"healthy":51,"higher":true,"status":"OK","stall_hours":null},
 {"key":"review","name":"评审","metric":"review.out_per_day","unit":"次","phrase":"过去一天给出结论 ","value":101,"healthy":48,"higher":true,"status":"OK","stall_hours":null}]'
facts="$(jq -cn --argjson now "$now" --argjson stations "$stations_json" '{report_day:"11-08",conclusion:{reason:"做完 14 个"},window:{end:$now},
  output:{finished:{day:14,prev_day:10,week:50,prev_week:40},shipped:{day:0,prev_day:0,week:0,prev_week:0},stock:{now:3,day_ago:2,week_ago:1}},
  last_deploy_at:null,spend:{day:{tokens:100000,money_usd:0},prev_day:{tokens:100000,money_usd:0}},
  quality:{incidents_period:0,alert_classes:null,rollbacks:0,open_subjects:[]},decisions:{items:[],total:0,incomplete:0},stations:$stations}')"
compare="$(owner_report_compare "$facts" "$home" "$now" "")"
lines="$(jq -r '.lines[]' <<< "$compare")"
station_lines="$(jq -r '.station_lines[]' <<< "$compare")"
[[ "$lines" == *'- 做完：比昨天多 4 个，比上周同日多 6 个。'* ]] || fail 'finished shows direction against both bases'
[[ "$lines" == *'- 令牌用量：比昨天没有变化，比上周同日多 1 万。'* ]] || fail 'tokens show the unchanged day and the week'
[[ "$lines" == *'- 线上告警：比昨天没有变化。'* ]] || fail 'a missing week base drops only that comparison'
[[ "$lines" != *撤回上线* ]] || fail 'a figure with no base in either snapshot gets no comparison line'
[[ "$lines" == *'没有去年的数据'* ]] || fail 'the report says plainly there is no year-on-year base'
[[ "$station_lines" == *'- 写代码：过去一天完成 60 次（标准至少 51 次），达标；比昨天少 40 次。'* ]] || fail 'a station line carries its standard and the day change'
[[ "$station_lines" != *'写代码'*'上周同日'* ]] || fail 'a station with no week base shows no week change'
ok 'every figure shows direction against the day and the same weekday, and drops an absent base'

# --- Causes -------------------------------------------------------------------------
causes="$(jq -r '.causes[]' <<< "$compare")"
[[ "$causes" == *'- 做完比昨天多 4 个：未查明。'* ]] || fail 'an untraced material change reads 未查明'
[[ "$causes" == *'- 写代码比昨天少 40 次：未查明。'* ]] || fail 'an untraced station change reads 未查明'
[[ "$causes" != *评审* ]] || fail 'a change under the material bound gets no cause line'
printf '%s\n' '{"implement.out_per_day":"模型额度用完，等明早恢复","release.hours_waiting":"head: roll fix, #1147"}' > "$tmp/owners.json"
export ZF_ANOMALY_OWNERS_FILE="$tmp/owners.json"
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$facts" "$home" "$now" "")")"
[[ "$causes" == *'- 写代码比昨天少 40 次：已有人跟进，登记的说明是：模型额度用完，等明早恢复。'* ]] || fail 'a plain-Chinese owner note is the cause'
jq -n --argjson at "$yesterday_at" '{schema:1,day:"2026-11-07",at:$at,figures:{"station:release":10}}' > "$snaps/2026-11-07.json"
release_facts="$(jq -c '.stations=[{"key":"release","name":"发布","metric":"release.hours_waiting","unit":"小时","phrase":"当前这批已等 ","value":30,"healthy":4,"higher":false,"status":"UNHEALTHY","stall_hours":null}]' <<< "$facts")"
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$release_facts" "$home" "$now" "")")"
[[ "$causes" == *'登记的原因没有写成平白中文'* && "$causes" != *1147* && "$causes" != *head* ]] || fail 'an owner note with Latin text or a tracker id is not repeated'
# What landed between the two days is context beside an untraced station change, never the cause.
repo="$tmp/repo"
git init -q "$repo"
mkdir -p "$repo/engine"
printf 'x\n' > "$repo/engine/dispatch.sh"
git -C "$repo" add -A
GIT_AUTHOR_DATE="@$((now - 43200))" GIT_COMMITTER_DATE="@$((now - 43200))" \
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m 'change dispatch'
git -C "$repo" update-ref refs/remotes/origin/main HEAD
jq -n --argjson at "$yesterday_at" '{schema:1,day:"2026-11-07",at:$at,figures:{"station:implement":100}}' > "$snaps/2026-11-07.json"
export ZF_ANOMALY_OWNERS_FILE="$tmp/none.json"
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$facts" "$home" "$now" "$repo")")"
[[ "$causes" == *'未查明（同期有 1 项改动合入了该环节的代码，尚未核实是否相关）'* ]] || fail 'landed changes are named as context, not as the cause'
ok 'causes come from a traced note or read 未查明'

# --- Report body and contract -------------------------------------------------------
snaps_full="$tmp/snaps-full"
mkdir -p "$snaps_full"
export ZF_OWNER_REPORT_SNAPSHOT_DIR="$snaps_full"
station_names=(取件 分诊 顾问裁定 写代码 评审 返工 合入 自动检查 发布)
station_keys=(intake triage advisor implement review repair merge ci release)
stations_all='[]'
yesterday_figures='{"finished":2,"shipped":1,"incidents":1,"rollbacks":1,"tokens":50000,"money":1}'
for i in "${!station_keys[@]}"; do
  stations_all="$(jq -c --arg k "${station_keys[$i]}" --arg n "${station_names[$i]}" '. + [{key:$k,name:$n,metric:($k + ".metric"),unit:"次",phrase:"过去一天完成 ",value:50,healthy:10,higher:true,status:"UNHEALTHY",stall_hours:3}]' <<< "$stations_all")"
  yesterday_figures="$(jq -c --arg k "station:${station_keys[$i]}" '. + {($k): 5}' <<< "$yesterday_figures")"
done
for day in 2026-11-07 2026-11-01; do
  jq -n --argjson at "$yesterday_at" --arg day "$day" --argjson f "$yesterday_figures" '{schema:1,day:$day,at:$at,figures:$f}' > "$snaps_full/$day.json"
done
big="$(jq -cn --argjson now "$now" --argjson stations "$stations_all" '{report_day:"11-08",conclusion:{reason:"做完 20 个"},window:{end:$now},
  output:{finished:{day:20,prev_day:2,week:50,prev_week:40},shipped:{day:9,prev_day:1,week:9,prev_week:1},stock:{now:30,day_ago:2,week_ago:1}},
  last_deploy_at:null,spend:{day:{tokens:900000,money_usd:7},prev_day:{tokens:50000,money_usd:1}},
  quality:{incidents_period:8,alert_classes:2,rollbacks:6,open_subjects:["订单页打不开"]},
  decisions:{items:[{question:"问题一？",recommendation:"建议：甲。"},{question:"问题二？",recommendation:"建议：乙。"},{question:"问题三？",recommendation:"建议：丙。"}],total:3,incomplete:0},
  stations:$stations}')"
big="$(jq -c --argjson compare "$(owner_report_compare "$big" "$home" "$now" "")" '.compare=$compare' <<< "$big")"
body="$(maintainer_health_mail_build_body "$big")"
printf '%s\n' "$body"
maintainer_health_mail_output_contract "$body" "$now" || fail 'the longest report the renderer can build meets the contract'
[[ "$(wc -l <<< "$body")" -le 40 ]] || fail 'the longest report stays within the line limit'
mapfile -t order < <(grep -n -x -E '产出|变化|质量|资源|各环节效率|变化原因|需要你决定' <<< "$body" | cut -d: -f2)
[[ "${order[*]}" == '产出 变化 质量 资源 各环节效率 变化原因 需要你决定' ]] || fail 'sections come in the contract order'
[[ "$(grep -c '^- .*未查明' <<< "$body")" -le 4 ]] || fail 'cause lines are capped'
bad="${body/变化原因/变化原因$'\n'- 事项 #4821 有变化}"
if maintainer_health_mail_output_contract "$bad" "$now" >/dev/null; then fail 'a tracker id in the new section is refused'; fi
ok 'the longer report meets the output contract'

# --- Backfill: only what can be re-derived -------------------------------------------
export MAC_AUTOPILOT_RUNTIME_DIR="$tmp/bf-runtime"
mkdir -p "$MAC_AUTOPILOT_RUNTIME_DIR" "$tmp/bf-home/night"
anchor="$(epoch 2026-11-08T01:00:00Z)"
python3 - "$MAC_AUTOPILOT_RUNTIME_DIR" "$anchor" <<'PY'
import json, sys
from datetime import datetime, timezone
runtime, anchor = sys.argv[1], int(sys.argv[2])
iso = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
# first event 2.5 days back, one review verdict 1.5 days back
unit = {"id": "issue-1", "stage": "merged", "history": [{"stage": "pr-opened", "at": iso(anchor - 216000)},
                                                        {"stage": "review-approve", "at": iso(anchor - 129600)}]}
json.dump({"units": [unit]}, open(f"{runtime}/units.json", "w"))
PY
bf_snaps="$tmp/bf-snaps"
export ZF_OWNER_REPORT_SNAPSHOT_DIR="$bf_snaps"
maintainer_health_mail_ensure_ledger "$tmp/bf-home/night/founder-health-mail.json" "$anchor"
owner_report_backfill "$tmp/bf-home" "$tmp/bf-home/night/founder-health-mail.json" "$anchor" 3 "$tmp/repo" >/dev/null
[[ "$(jq -r '.figures["station:review"]' "$bf_snaps/2026-11-07.json")" == 1 ]] || fail 'a day inside the ledger is re-derived from it'
[[ "$(jq -r '.figures | has("station:review")' "$bf_snaps/2026-11-06.json")" == false ]] || fail 'a day before the ledger starts gets no station rows, not zeros'
[[ "$(jq -r '.figures | has("station:implement")' "$bf_snaps/2026-11-05.json" 2>/dev/null || printf false)" == false ]] || fail 'the earliest day is not guessed either'
owner_report_backfill "$tmp/bf-home" "$tmp/bf-home/night/founder-health-mail.json" "$anchor" 1 "$tmp/repo" >/dev/null
[[ "$(jq -r '.figures["station:review"]' "$bf_snaps/2026-11-07.json")" == 1 ]] || fail 'a stored day is kept on a second backfill'
ok 'backfill stores only re-derivable rows and keeps stored days'
