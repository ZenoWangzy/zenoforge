#!/usr/bin/env bash
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
values=$(node - "$DIR/lib/config.cjs" <<'NODE'
const {config:c,expand} = require(process.argv[2]);
for (const [k,v] of Object.entries(c.watch)) { const x = Array.isArray(v) ? v.join(' ') : String(v); console.log('W_' + k + "='" + (x.startsWith('~/') ? expand(x) : x).replace(/'/g, "'\\''") + "'"); }
NODE
) || exit 1
eval "$values"
A=$W_autopi
S=$(mktemp -d); prev_unhealthy=""; last_cpu=0
rt_lines=$(wc -l < "$A/release-train.log" 2>/dev/null || echo 0)
IB=$W_inbox; ib_lines=$(wc -l < "$IB" 2>/dev/null || echo 0)
while true; do
  now=$(date +%s)
  n=$(wc -l < "$A/release-train.log" 2>/dev/null || echo 0)
  if [ "$n" -gt "$rt_lines" ]; then
    tail -n +$((rt_lines + 1)) "$A/release-train.log" | grep -E "$W_release_events" | cut -c1-200 | sed 's/^/release-train: /'
    rt_lines=$n
  fi
  n=$(wc -l < "$IB" 2>/dev/null || echo 0)
  if [ "$n" -gt "$ib_lines" ]; then tail -n +$((ib_lines + 1)) "$IB" | grep -E "$W_inbox_events" | cut -c1-300 | sed 's/^/inbox: /'; ib_lines=$n; fi
  failed=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -E "$W_units_pattern" | sort | tr '\n' ' ')
  [ -n "$failed" ] && [ "$failed" != "$(cat "$S/failed" 2>/dev/null)" ] && echo "failed units: $failed"
  echo "$failed" > "$S/failed"
  last_tick=$(stat -c %Y "$A/scheduler.log" 2>/dev/null || echo 0)
  if [ ! -s "$W_pause" ] && [ $((now - last_tick)) -gt "$W_tick_seconds" ] && [ ! -e "$S/tickgap" ]; then echo "scheduler.log silent for $(( (now - last_tick) / 60 ))m"; touch "$S/tickgap"; fi
  [ $((now - last_tick)) -le "$W_tick_seconds" ] && mv "$S/tickgap" "$S/tickgap.old" 2>/dev/null || :
  if [ -s "$A/node-health.txt" ]; then
    u=$(grep UNHEALTHY "$A/node-health.txt" | sed -E 's/ {2,}/|/g' | cut -d'|' -f3 | sort)
    new=$(comm -13 <(echo "$prev_unhealthy") <(echo "$u") | grep .)
    [ -n "$prev_unhealthy" ] && [ -n "$new" ] && echo "new UNHEALTHY: $(echo "$new" | tr '\n' ';')"
    prev_unhealthy=$(printf "%s\n%s\n" "$prev_unhealthy" "$u" | grep . | sort -u)
  fi
  read -r _ u n s i w q sq st _ < /proc/stat; tot=$((u+n+s+i+w+q+sq+st)); idle=$((i+w))
  busy=$(( ${ptot:-0} && tot > ptot ? 100 - 100 * (idle - pidle) / (tot - ptot) : 50 )); ptot=$tot; pidle=$idle
  avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if { [ "$busy" -gt "$W_cpu_high" ] || [ "$busy" -lt "$W_cpu_low" ] || [ "$avail" -lt "$W_memory_min" ]; } && [ $((now - last_cpu)) -ge "$W_alert_seconds" ]; then
    echo "cpu_busy=${busy}% mem_avail=${avail}M"; last_cpu=$now
  fi
  tmp_free=$(df -m --output=avail "$W_temp_root" | tail -1 | tr -d " ")
  if [ "$tmp_free" -lt "$W_temp_min" ] && [ $((now - ${last_tmp:-0})) -ge "$W_alert_seconds" ]; then echo "tmp_free=${tmp_free}M of $W_temp_root"; last_tmp=$now; fi
  if [ -s "$W_pause" ] && systemctl --user -q is-active $W_pause_units 2>/dev/null; then echo "PAUSE violated: scheduler or tick timer active"; fi
  tabs=$(node - "$W_chrome_endpoint" "$W_chrome_patterns" <<'NODE'
const [url, ...patterns] = process.argv.slice(2);
fetch(url).then(r=>r.json()).then(t=>{const p=t.filter(x=>x.type==='page'); const a=patterns.join(' ').split(' '); console.log(p.filter(x=>new RegExp(a[0]).test(x.url)).length+' '+p.filter(x=>new RegExp(a[1]).test(x.url)).length+' '+p.length)}).catch(()=>{});
NODE
  )
  read -r chat vt allp <<<"$tabs"
  if [ -n "$tabs" ] && { [ "${chat:-0}" -gt "${W_chrome_limits%% *}" ] || [ "${vt:-0}" -gt "${W_chrome_limits##* }" ]; } && [ $((now - ${last_tabs:-0})) -ge "$W_alert_seconds" ]; then
    echo "shared Chrome leftovers: chatgpt_chats=$chat $W_chrome_label=$vt pages=$allp"; last_tabs=$now
  fi
  sleep "$W_interval"
done
