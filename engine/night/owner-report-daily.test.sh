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
# The tick's only figure here is the rollback count from origin/main, a ref CI's checkout does not have.
export ZF_REPO_DIR="$tmp/tick-repo"
git init -q "$ZF_REPO_DIR"
git -C "$ZF_REPO_DIR" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m seed
git -C "$ZF_REPO_DIR" update-ref refs/remotes/origin/main HEAD
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
station_lines="$(jq -r '.station_lines[]' <<< "$compare")"
inl() { jq -r --arg k "$1" '.inline[$k] // "none"' <<< "$compare"; }
[[ "$(inl finished)" == '比昨天多 4 个，比上周同日多 6 个' ]] || fail 'finished shows direction against both bases'
[[ "$(inl tokens)" == '比昨天没有变化，比上周同日多 1 万' ]] || fail 'tokens show the unchanged day and the week'
[[ "$(inl incidents)" == '比昨天没有变化' ]] || fail 'a missing week base drops only that comparison'
[[ "$(inl shipped)" == '比昨天没有变化' ]] || fail 'a day with no snapshot falls back to the report previous-day figure'
[[ "$(inl stock)" == '比昨天多 1 个，比上周同日多 2 个' ]] || fail 'the waiting stock is compared once, with both bases'
[[ "$(inl rollbacks)" == none ]] || fail 'a figure with no base anywhere gets no comparison'
[[ "$(jq -r '.note' <<< "$compare")" == *'没有去年的数据'* ]] || fail 'the report says plainly there is no year-on-year base'
[[ "$station_lines" == *'- 写代码：过去一天完成 60 次（标准至少 51 次），达标；比昨天少 40 次。'* ]] || fail 'a station line carries its standard and the day change'
[[ "$station_lines" != *'写代码'*'上周同日'* ]] || fail 'a station with no week base shows no week change'
ok 'every figure shows direction against the day and the same weekday, and drops an absent base'

# --- Causes -------------------------------------------------------------------------
causes="$(jq -r '.causes[]' <<< "$compare")"
[[ "$causes" == *'- 做完比昨天多 4 个：未查明。'* ]] || fail 'a line with no mapped row reads 未查明'
[[ "$causes" == *'- 写代码比昨天少 40 次：未查明。'* ]] || fail 'an untraced station change reads 未查明'
[[ "$causes" != *评审* ]] || fail 'a change under the material bound gets no cause line'
printf '%s\n' '{"dispatch.collisions_per_day":"提前预测会改同一文件就互相等待，正在换成成熟做法","release.hours_waiting":"head: roll fix, #1147"}' > "$tmp/owners.json"
export ZF_ANOMALY_OWNERS_FILE="$tmp/owners.json"
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$facts" "$home" "$now" "")")"
[[ "$causes" == *'- 写代码比昨天少 40 次：提前预测会改同一文件就互相等待，正在换成成熟做法。'* ]] || fail 'the mapped owner note is the cause, verbatim'
jq -n --argjson at "$yesterday_at" '{schema:1,day:"2026-11-07",at:$at,figures:{"station:release":10}}' > "$snaps/2026-11-07.json"
release_facts="$(jq -c '.stations=[{"key":"release","name":"发布","metric":"release.hours_waiting","unit":"小时","phrase":"当前这批已等 ","value":30,"healthy":4,"higher":false,"status":"UNHEALTHY","stall_hours":null}]' <<< "$facts")"
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$release_facts" "$home" "$now" "")")"
[[ "$causes" == *'- 发布比昨天多 20 小时：已登记原因，但内容含不能直接发送的字符，没有转述。'* && "$causes" != *1147* && "$causes" != *head* ]] || fail 'a note with Latin text or a tracker id is not printed'
# Every mapped line prints its note and never 未查明; every line with no row reads 未查明 (the table is OWNER_ROWS).
python3 - "$SCRIPT_DIR/owner-report-compare.py" "$tmp" "$now" <<'PY' || fail 'every mapped line prints its owner note, every unmapped line reads 未查明'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("orc", sys.argv[1]); orc = importlib.util.module_from_spec(spec); spec.loader.exec_module(orc)
tmp, now = sys.argv[2], int(sys.argv[3])
snap = os.path.join(tmp, "map-snaps"); os.makedirs(snap, exist_ok=True)
keys = list(orc.FIGURES) + ["station:" + s[0] for s in orc.STATIONS]
json.dump({"schema": 1, "day": orc.beijing_day(now - 86400), "at": now - 86400, "figures": {k: 10 for k in keys}}, open(os.path.join(snap, orc.beijing_day(now - 86400) + ".json"), "w"))
every_row = {row: "测试原因" + str(i) for i, row in enumerate(sorted({r for rows in orc.OWNER_ROWS.values() for r in rows}))}
owners = os.path.join(tmp, "map-owners.json"); json.dump(every_row, open(owners, "w"))
def facts_for(key):
    f = {"output": {}, "quality": {}, "spend": {"day": {}}, "stations": []}
    if key == "finished": f["output"]["finished"] = {"day": 30}
    elif key == "shipped": f["output"]["shipped"] = {"day": 30}
    elif key == "stock": f["output"]["stock"] = {"now": 30}
    elif key == "incidents": f["quality"]["incidents_period"] = 30
    elif key == "rollbacks": f["quality"]["rollbacks"] = 30
    elif key == "tokens": f["spend"]["day"]["tokens"] = 30
    elif key == "money": f["spend"]["day"]["money_usd"] = 30
    else:
        name = [s for s in orc.STATIONS if "station:" + s[0] == key][0]
        f["stations"] = [{"key": name[0], "name": name[1], "metric": name[2], "unit": name[3], "phrase": name[4], "value": 30, "healthy": 5, "higher": True, "status": "OK", "stall_hours": None}]
    return f
problems = []
for key in keys:
    causes = orc.compare(facts_for(key), snap, now, "", owners)["causes"]
    mapped = orc.OWNER_ROWS.get(key)
    if len(causes) != 1: problems.append(f"{key}: {len(causes)} cause lines"); continue
    if mapped and ("未查明" in causes[0] or every_row[mapped[0]] not in causes[0]): problems.append(f"{key}: mapped line did not print its note: {causes[0]}")
    if not mapped and "未查明" not in causes[0]: problems.append(f"{key}: unmapped line did not read 未查明: {causes[0]}")
print("\n".join(problems)); sys.exit(1 if problems else 0)
PY
# What landed between the two days is a hint beside 未查明, never the cause.
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
[[ "$causes" == *'- 写代码比昨天少 40 次：未查明。线索，未核实：同期有 1 项改动合入了该环节的代码。'* ]] || fail 'landed changes read as a separate hint after 未查明'
[[ "$causes" != *'次：线索'* && "$causes" != *'次：同期'* && "$causes" != *'个：线索'* && "$causes" != *'个：同期'* ]] || fail 'the hint never stands where the cause goes'
export ZF_ANOMALY_OWNERS_FILE="$tmp/owners.json"
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$facts" "$home" "$now" "$repo")")"
[[ "$causes" == *'- 写代码比昨天少 40 次：提前预测会改同一文件就互相等待，正在换成成熟做法。'* && "$causes" != *线索* ]] || fail 'a mapped owner note is the cause and no hint rides beside it'
export ZF_ANOMALY_OWNERS_FILE="$tmp/none.json"
ok 'causes are the mapped owner note or 未查明; timing is only a separate hint'

# --- Worker causes: behind one switch, off by default, and only rows with evidence ----------
export ZF_OWNER_REPORT_CAUSES_DIR="$tmp/causes"
mkdir -p "$tmp/causes"
jq -n '{day:"2026-11-08",generated_at:1,rows:[
  {line:"finished",cause:"合并队列停了九个小时，所以做完的需求变多后又补回",evidence:"~/scheduler.log: 41 merged lines the day before, 12 today",basis:"read"},
  {line:"station:implement",cause:"额度用完，写代码的任务停了",basis:"read"},
  {line:"stock",cause:"同期有发版，所以等上线的需求变多",evidence:"~/scheduler.log: 3 lines",basis:"read"}]}' > "$tmp/causes/owner-report-causes-2026-11-08.json"
unset ZF_OWNER_REPORT_CAUSES
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$facts" "$home" "$now" "")")"
[[ "$causes" != *合并队列* && "$causes" == *'- 做完比昨天多 4 个：未查明。'* ]] || fail 'with the switch off nothing from the causes file is printed'
export ZF_OWNER_REPORT_CAUSES=1
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$facts" "$home" "$now" "")")"
[[ "$causes" != *合并队列* ]] || fail 'the switch is exactly on, not any value'
export ZF_OWNER_REPORT_CAUSES=on
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$facts" "$home" "$now" "")")"
[[ "$causes" == *'- 做完比昨天多 4 个：合并队列停了九个小时，所以做完的需求变多后又补回。'* ]] || fail 'a row with a source and numbers is printed as the cause'
[[ "$causes" == *'- 写代码比昨天少 40 次：未查明。'* ]] || fail 'a row without an evidence field stays 未查明'
[[ "$causes" == *'- 做完等上线的需求比昨天多 1 个：未查明。'* ]] || fail 'a cause worded as timing stays 未查明'
python3 - "$SCRIPT_DIR/owner-report-compare.py" <<'PY' || fail 'the evidence rule is a code check'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("orc", sys.argv[1]); orc = importlib.util.module_from_spec(spec); spec.loader.exec_module(orc)
good = {"line": "finished", "cause": "合并队列停了九个小时", "evidence": "~/scheduler.log: 41 merged lines, 12 today", "basis": "read"}
assert orc.valid_cause_row(good) == "合并队列停了九个小时"
assert orc.valid_cause_row({**good, "evidence": "metric flow.merge_rate_per_hour 2.1 against 1.2"}) == "合并队列停了九个小时"
bad = {
    "no evidence field": {k: v for k, v in good.items() if k != "evidence"},
    "empty evidence": {**good, "evidence": ""},
    "evidence without a number": {**good, "evidence": "~/scheduler.log shows the queue stopped"},
    "evidence with only times": {**good, "evidence": "~/scheduler.log at 12:03 and 2026-11-07T01:00:00Z"},
    "evidence without a source": {**good, "evidence": "it was 41 merged then 12"},
    "basis timing": {**good, "basis": "timing"},
    "no basis": {k: v for k, v in good.items() if k != "basis"},
    "latin in cause": {**good, "cause": "merge 队列停了"},
    "tracker id in cause": {**good, "cause": "合并队列停了，见 #4821"},
    "address in evidence": {**good, "evidence": "~/scheduler.log: 3 lines for a@b.c"},
    "tracker id in evidence": {**good, "evidence": "~/scheduler.log: 3 lines of #4821"},
    "timing wording": {**good, "cause": "同一时间有发版"},
    "too long": {**good, "cause": "合" * 81},
    "not a row": "text",
}
for name, row in bad.items():
    assert orc.valid_cause_row(row) is None, name
PY
export ZF_OWNER_REPORT_CAUSES=on ZF_ANOMALY_OWNERS_FILE="$tmp/owners.json"
causes="$(jq -r '.causes[]' <<< "$(owner_report_compare "$facts" "$home" "$now" "")")"
[[ "$causes" == *'- 写代码比昨天少 40 次：提前预测会改同一文件'* ]] || fail 'a head note outranks a worker row'
unset ZF_OWNER_REPORT_CAUSES ZF_OWNER_REPORT_CAUSES_DIR
export ZF_ANOMALY_OWNERS_FILE="$tmp/none.json"
[[ "$(jq -c '[.material[].line] | sort' <<< "$compare")" == '["finished","station:implement","stock"]' ]] || fail 'the compare step lists the material changes for the worker'
ok 'worker causes are printed only behind the switch and only with evidence'

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
[[ "$(wc -l <<< "$body")" -eq 32 ]] || fail 'the longest report is 32 lines, which is the contract limit'
[[ "$(sed -n 2p <<< "$body")" == 需要你决定 ]] || fail 'the decisions come right after the conclusion'
mapfile -t order < <(grep -n -x -E '产出|变化|质量|资源|各环节效率|变化原因|需要你决定' <<< "$body" | cut -d: -f2)
[[ "${order[*]}" == '需要你决定 产出 变化 质量 资源 各环节效率 变化原因' ]] || fail 'sections come in the contract order'
[[ "$(grep -c '^- .*未查明' <<< "$body")" -le 4 ]] || fail 'cause lines are capped'
if maintainer_health_mail_output_contract "$body"$'\n- 多出一行' "$now" >/dev/null; then fail 'a 33rd line is refused'; fi
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
