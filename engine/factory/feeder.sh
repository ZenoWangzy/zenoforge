#!/usr/bin/env bash
# Launch the next queued ticket only when no opt worker is still waiting at the capacity gate, so queue order = start order.
# 10-30 #4724 (maintainer: pipeline-system tickets are the supervisor's, never the scheduler's): every 10 min, open
# pipeline-system issues enter queue.txt and get opt-lane (scheduler intake skips opt-lane), or are excluded with a
# reason in intake.log: on-hold, ops alerts (needs-triage / "pipeline health:", zf-ab), a live opt worker, an open PR.
S=${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}; F=$S/factory; L=$S/luna
unset GH_TOKEN
intake() {
  local n labels title why key; touch "$F/.intake-seen" "$F/.intake-excluded"
  gh issue list -R example-maintainer/example-repo --label pipeline-system --state open --limit 200 --json number,title,labels \
    -q '.[] | "\(.number)\t\([.labels[].name] | join(","))\t\(.title)"' 2>/dev/null |
  while IFS=$'\t' read -r n labels title; do
    grep -qx "$n" "$F/.intake-seen" && continue
    why=
    [[ ,$labels, == *,on-hold,* ]] && why=on-hold
    for l in needs-advisor needs-info awaiting-release; do [[ ,$labels, == *,$l,* ]] && why=$l; done  # waits on a ruling or a release
    [[ $title == "pipeline health:"* || ,$labels, == *,needs-triage,* ]] && why="ops alert (zf-ab)"
    if [[ -z $why ]]; then
      for b in $(grep -l "issue #$n（" "$F"/opt-*.brief.md 2>/dev/null); do key=$(basename "$b" .brief.md)
        [[ -f $L/$key/rc ]] || ! kill -0 "$(cat "$L/$key/wrapper.pid" 2>/dev/null)" 2>/dev/null || why="live worker $key"; done
    fi
    [[ -z $why && -n $(gh pr list -R example-maintainer/example-repo --state open --search "\"Refs #$n\" in:body" --json number -q '.[].number' 2>/dev/null) ]] && why="open PR"
    if [[ -n $why ]]; then
      grep -qx "$n $why" "$F/.intake-excluded" || { echo "$n $why" >> "$F/.intake-excluded"; echo "$(date -u +%FT%TZ) exclude #$n: $why" >> "$F/intake.log"; }
      continue
    fi
    gh issue edit "$n" -R example-maintainer/example-repo --add-label opt-lane >/dev/null 2>&1
    echo "opt-i$n $n -" >> "$F/queue.txt"; echo "$n" >> "$F/.intake-seen"; echo "$(date -u +%FT%TZ) enqueue #$n: $title" >> "$F/intake.log"
  done
}
tick=0
while true; do
  (( tick++ % 10 == 0 )) && intake
  waiting=0
  for d in "$L"/opt-*; do [[ -f $d/rc || ! -f $d/wrapper.pid ]] && continue; kill -0 "$(cat "$d/wrapper.pid")" 2>/dev/null || continue
    [[ -f $d/codex.pid ]] && kill -0 "$(cat "$d/codex.pid")" 2>/dev/null || waiting=$((waiting+1)); done
  # Hotfixes come first (maintainer 10-29): the hotfix supervisor pauses intake by touching FEEDER-PAUSE.
  if (( waiting == 0 )) && [[ -s $F/queue.txt && ! -e $F/FEEDER-PAUSE ]]; then
    read -r key issue note < "$F/queue.txt"; sed -i 1d "$F/queue.txt"
    [[ -z $note || $note == - ]] && note= || { [[ $note == /* ]] || note=$F/$note; }  # 10-29: absolute notes were prefixed with $F and launched empty
    (cd "$F" && ./launch.sh "$key" "$issue" $note); sed -i "/^$key\$/d" "$F/.opt-seen"
  fi
  sleep 60
done
