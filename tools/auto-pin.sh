#!/usr/bin/env bash
# Pins the newest zenoforge main commit as soon as main moves (rulings zenoforge-instant-effect-2026-11-05, zenoforge-batch-land-2026-11-08:
# "Pin follows the batch at once"). Commits merged together are pinned once, at main's head: walking them one by one cost ~500 s each.
# A failed pin waits for the next main commit, then moves on; dirty-checkout and changed-VectA-head refusals retry once per fix; rate limits retry the same commit up to 3 times. Stop by hand: touch "$ZF_AUTO_PIN_HOME/auto-pin.stop"
# Run a copy, not the clone's file: the loop checks out new commits in its clone (see tools/zf-auto-pin.service).
# State and stop file live in ZF_AUTO_PIN_HOME; engine/mac-autopilot/pin-lag.sh (bell) reads auto-pin.last to alert on a stall.
set -u
ZF_AUTO_PIN_HOME=${ZF_AUTO_PIN_HOME:-$HOME/.zenoforge}
AGENT_HOME=${AGENT_HOME:-$HOME/.vecta-agent}
C=${ZF_AUTO_PIN_CLONE:-$ZF_AUTO_PIN_HOME/clones/pz-zf-review-verdict-clobber}
cache_helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../engine/lib.d" 2>/dev/null && pwd -P)/gh-key-cache.sh"
[[ -f "$cache_helper" ]] || cache_helper="$C/engine/lib.d/gh-key-cache.sh"
source "$cache_helper"
idle=${ZF_AUTO_PIN_IDLE_SECS:-30} retry=${ZF_AUTO_PIN_RETRY_SECS:-60}
state=$ZF_AUTO_PIN_HOME/auto-pin.last; stop=$ZF_AUTO_PIN_HOME/auto-pin.stop
logdir=$ZF_AUTO_PIN_HOME/auto-pin-logs
product_fetch_time=$ZF_AUTO_PIN_HOME/auto-pin-product-fetch.last
# Head 2026-11-05: an override pin must take the PR lane; merge that PR here so it does not wait for head.
# Only a PR holding build.json, overrides.tsv and, optionally, the pack copies merged by this pin, with no failed check.
# A clean three-way merge that leaves a pack copy byte-identical adds no pack file, so the PR is base-only.
merge_override_pin() { # log [intended-row expected-head] -> 0 merged, 1 leave for head
  local log=$1 kind=${2:-override} expected_head=${3:-} url pr repo allowed files raw bad head_sha checks i
  url=$(sed -n 's/.*result=pr-open route=PR landed=no pr=\([^ ]*\).*/\1/p' "$log" | tail -1)
  pr=${url##*/}; [[ $pr =~ ^[1-9][0-9]*$ ]] || { echo 'override-pin: no PR number in the pin log'; return 1; }
  repo=$(sed -E 's#^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+$#\1#' <<<"$url")
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  head_sha=$(gh api "repos/$repo/pulls/$pr" --jq .head.sha) || return 1
  [[ -z $expected_head || $head_sha == "$expected_head" ]] || { echo "override-pin: #$pr head changed before merge"; return 1; }
  raw=$(gh_pr_files_cached_for_repo "$repo" "$pr" "$head_sha") || return 1
  files=$(jq -rs 'add // [] | .[].filename' <<<"$raw") || return 1
  if [[ $kind == intended-row ]]; then
    [[ $files == .zenoforge/build/intended-changes.tsv ]] \
      || { echo "override-pin: #$pr files are not only the intended-changes row"; return 1; }
  else
    allowed=$(printf '%s\n' .zenoforge/build.json .zenoforge/build/overrides.tsv; sed -n 's#^pin-vecta: merged override \([^ ]*\) base=.*#.zenoforge/build/pack/scripts/agent/\1#p' "$log")
    [[ $(wc -l <<<"$allowed") -ge 3 ]] || { echo "override-pin: #$pr merged no override"; return 1; }
    if [[ -n $(comm -23 <(sort <<<"$files") <(sort <<<"$allowed")) \
       || -n $(comm -13 <(sort <<<"$files") <(sort <<<".zenoforge/build.json"$'\n'".zenoforge/build/overrides.tsv")) ]]; then
      echo "override-pin: #$pr files are not the pin, its overrides and their pack copies"; return 1
    fi
  fi
  # Failed = a completed check run or a legacy commit status in failure/error. Pending runs are not failed.
  checks=$(gh_commit_check_runs_persisted "$head_sha" "$repo") || return 1
  bad=$(jq '[.check_runs[]? | select(.status == "completed") | select((.conclusion // "") | test("^(failure|cancelled|timed_out|action_required|startup_failure)$"))] | length' <<<"$checks") || return 1
  statuses=$(gh api "repos/$repo/commits/$head_sha/status" --jq '[.statuses[] | select(.state == "failure" or .state == "error")] | length') || return 1
  bad=$((bad + statuses))
  [[ $bad == 0 ]] || { echo "override-pin: #$pr has $bad failed check(s)"; return 1; }
  gh pr merge "$pr" -R ZenoWangzy/vecta --squash >>"$log" 2>&1 || { echo "override-pin: gh pr merge #$pr failed"; return 1; }
  for ((i = 0; i < 20; i++)); do
    [[ $(gh api "repos/ZenoWangzy/vecta/pulls/$pr" --jq .merged 2>/dev/null) == true ]] && return 0
    sleep 6
  done
  echo "override-pin: #$pr not MERGED after the wait"; return 1
}

# pin-vecta prints path<TAB>reason<TAB>hash after this line.
row_named_fields() { awk -F'\t' 'f { if (NF >= 3) { print $1 "\t" $NF; exit } } /add this row/ { f = 1 }' "$1" 2>/dev/null; }

# An engine-SHA row from anywhere in the pending pin range still names this change; content rows must match the refusal.
row_named_declared() { # log tsv last next -> 0 when tsv declares the refused path
  local log=$1 tsv=$2 last=$3 next=$4 path='' hash='' row_path row_hash commit range
  IFS=$'\t' read -r path hash < <(row_named_fields "$log")
  [[ -n $path && -n $hash ]] || return 1
  if [[ $hash == sha256:* ]]; then
    awk -F'\t' -v p="$path" -v h="$hash" '$1 == p && $NF == h { ok = 1 } END { exit !ok }' "$tsv" 2>/dev/null
    return
  fi
  [[ $hash =~ ^[0-9a-f]{7,40}$ ]] || return 1
  range=$(git -C "$C" rev-list --first-parent "$last..$next" 2>/dev/null) || return 1
  while IFS=$'\t' read -r row_path _ row_hash; do
    [[ $row_path == "$path" && $row_hash =~ ^[0-9a-f]{7,40}$ ]] || continue
    commit=$(git -C "$C" rev-parse --verify -q "$row_hash^{commit}" 2>/dev/null) || continue
    grep -Fxq "$commit" <<<"$range" && return 0
  done < "$tsv"
  return 1
}

row_named_exact_declared() { # log tsv -> 0 when the refused scope is already present
  local log=$1 tsv=$2 path='' hash='' row_path row_hash expected actual
  IFS=$'\t' read -r path hash < <(row_named_fields "$log")
  [[ -n $path && -n $hash ]] || return 1
  if [[ $hash == sha256:* ]]; then
    awk -F'\t' -v p="$path" -v h="$hash" '$1 == p && $NF == h { ok = 1 } END { exit !ok }' "$tsv" 2>/dev/null
    return
  fi
  expected=$(git -C "$C" rev-parse --verify -q "$hash^{commit}" 2>/dev/null) || return 1
  while IFS=$'\t' read -r row_path _ row_hash; do
    [[ $row_path == "$path" && $row_hash =~ ^[0-9a-f]{7,40}$ ]] || continue
    actual=$(git -C "$C" rev-parse --verify -q "$row_hash^{commit}" 2>/dev/null) || continue
    [[ $actual == "$expected" ]] && return 0
  done < "$tsv"
  return 1
}

reviewed_merge() { # engine sha -> 0 when a merge-pr receipt or lane pin records it
  local sha=$1 hold="$ZF_AUTO_PIN_HOME/state/work/merge-lane-hold.txt" receipt_dir receipt
  if [[ -f $hold ]] && awk -v sha="$sha" '$1 == "pin" && $3 == sha { found = 1 } END { exit !found }' "$hold"; then
    return 0
  fi
  receipt_dir=$(git -C "$C" rev-parse --git-path zenoforge-merge-pr 2>/dev/null) || return 1
  [[ $receipt_dir == /* ]] || receipt_dir="$C/$receipt_dir"
  receipt="$receipt_dir/$sha.json"
  jq -e --arg sha "$sha" '
    .sha == $sha and .green == true and .cli_exit_code == 0
    and (.engine_shards | type == "array" and length == 8
      and ([.[].shard] | sort == [0,1,2,3,4,5,6,7])
      and all(.[]; .exit_code == 0))
  ' "$receipt" >/dev/null 2>&1
}

auto_pin_land_row() { # log last next -> path on success
  local log=$1 last=$2 next=$3
  (
    local target="$AGENT_HOME/checkout" row_rel=.zenoforge/build/intended-changes.tsv path='' hash='' reason='' branch='' worktree='' start_head='' row_file='' row_head='' pr_url='' title='' body=''
    cleanup() {
      [[ -z $worktree ]] || git -C "$target" worktree remove --force "$worktree" >>"$log" 2>&1 || :
      [[ -z $branch ]] || git -C "$target" branch -D "$branch" >>"$log" 2>&1 || :
      git -C "$target" worktree prune >>"$log" 2>&1 || :
    }
    trap cleanup EXIT
    IFS=$'\t' read -r path hash < <(row_named_fields "$log")
    [[ -n $path && $path != /* && $path != *$'\t'* && $path != *$'\n'* ]] || return 1
    case "/$path/" in */../*) return 1 ;; esac
    [[ $hash =~ ^[0-9a-f]{7,40}$ || $hash =~ ^sha256:[0-9a-f]{12,64}$ ]] || return 1
    reviewed_merge "$next" || return 1
    [[ -z $(git -C "$target" status --porcelain 2>/dev/null) ]] || return 1
    git -C "$target" fetch -q origin main >>"$log" 2>&1 || return 1
    start_head=$(git -C "$target" rev-parse origin/main 2>/dev/null) || return 1
    row_file=$(git -C "$target" show "$start_head:$row_rel" 2>/dev/null || :)
    if awk -F'\t' -v p="$path" -v h="$hash" '$1 == p && $NF == h { found = 1 } END { exit !found }' <<<"$row_file"; then
      git -C "$target" merge --ff-only "$start_head" >>"$log" 2>&1 || return 1
      printf '%s\n' "$path"
      return 0
    fi
    branch="chore/auto-pin-row-${next:0:12}-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    worktree="$target/.worktrees/auto-pin-row-${next:0:12}-$$-$RANDOM"
    mkdir -p "$target/.worktrees" || return 1
    git -C "$target" worktree add -b "$branch" "$worktree" "$start_head" >>"$log" 2>&1 || return 1
    mkdir -p "$(dirname -- "$worktree/$row_rel")" || return 1
    [[ -f "$worktree/$row_rel" ]] || : > "$worktree/$row_rel"
    reason="auto: reviewed merge ${next:0:12}"
    printf '%s\t%s\t%s\n' "$path" "$reason" "$hash" >>"$worktree/$row_rel"
    git -C "$worktree" add -- "$row_rel" >>"$log" 2>&1 || return 1
    git -C "$worktree" -c user.name='Zeno Wang' -c user.email='163096107+ZenoWangzy@users.noreply.github.com' \
      commit -m "chore: approve intended change for ${next:0:12}" >>"$log" 2>&1 || return 1
    row_head=$(git -C "$worktree" rev-parse HEAD) || return 1
    git -C "$worktree" push -u origin "$branch" >>"$log" 2>&1 || return 1
    title="chore: approve intended change for ${next:0:12}"
    body="Auto-pin intended-changes row for reviewed engine merge ${next:0:12}: $path"
    pr_url=$(cd "$worktree" && gh pr create --base main --head "$branch" --title "$title" --body "$body" 2>>"$log") \
      || { echo 'override-pin: gh pr create failed for the intended-changes row' >>"$log"; return 1; }
    printf 'pin-vecta: result=pr-open route=PR landed=no pr=%s\n' "$pr_url" >>"$log"
    merge_override_pin "$log" intended-row "$row_head" >>"$log" 2>&1 || return 1
    systemctl --user start --no-block vecta-agent.service >>"$log" 2>&1 || :
    git -C "$target" fetch -q origin main >>"$log" 2>&1 || return 1
    git -C "$target" merge --ff-only origin/main >>"$log" 2>&1 || return 1
    printf '%s\n' "$path"
  ) 2>>"$log"
}

# A pin refused by "expected one patch anchor, found N" needs a VectA pack re-anchor, not a retry: file one issue per (patch script, engine file)
# and name its URL in head-watch.alerts. Never blocks or changes the pin; output goes to $log.anchor, not $log (pin-fail-triage and rate-limit checks read $log).
pin_anchor_finding() { # log last next -> 0 always
  local log=$1 last=$2 next=$3 line engine patch live culprits title open url alerts
  line=$(grep -E -m1 'expected one patch anchor, found [0-9]+$' "$log" 2>/dev/null) || return 0
  engine=$(sed -n 's#^.*/\(engine/[^:]*\): expected one patch anchor, found [0-9]*$#\1#p' <<<"$line")
  [[ -n $engine ]] || return 0
  # The runner does not print the patch name, so take the pack patch that names this engine file on product main.
  patch=$(git -C "$AGENT_HOME/checkout" grep -l -F -e "$(basename -- "$engine")" origin/main -- .zenoforge/build/pack 2>/dev/null \
    | sed -n 's#^.*/\(patch-[^/]*\.py\)$#\1#p' | sort -u | paste -sd, -)
  patch=${patch:-unknown}
  live=$(git -C "$AGENT_HOME/checkout" show HEAD:.zenoforge/build.json 2>/dev/null | jq -er '.engine' 2>/dev/null) || live=$last
  culprits=$(git -C "$C" log --format='%h %s' "$live..$next" -- "$engine" 2>/dev/null | head -5)
  culprits=${culprits:-none in $live..$next}
  title="pin anchor: re-anchor $patch for $engine"
  open=$(gh issue list -R ZenoWangzy/vecta --state open --limit 500 --json title,url 2>>"$log.anchor") \
    || { echo "pin-anchor: issue list failed" >>"$log.anchor"; return 0; }
  url=$(jq -r --arg t "$title" '.[] | select(.title == $t) | .url' <<<"$open" | head -1)
  if [[ -z $url ]]; then
    url=$(bash "$AGENT_HOME/engine-live/roadmap-issue-create.sh" gh issue create --repo ZenoWangzy/vecta --title "$title" --label supervisor-created \
      --body "Pin of zenoforge ${next:0:12} refused on a broken VectA pack patch anchor.
Patch script: $patch (VectA .zenoforge/build/pack). Engine file: $engine.
Log line: $line
Culprit engine commits ($live..${next:0:12}, this file):
$culprits

The re-anchored patch must apply on BOTH the live pin (land-direct-main checks the live pin) and the new engine (auto-pin checks main),
and must be idempotent on both: row 869 needed three landing rounds for exactly this." 2>>"$log.anchor" | grep -E '^https://' | tail -1) || url=''
  fi
  [[ -n $url ]] || { echo "pin-anchor: no issue URL for $title" >>"$log.anchor"; return 0; }
  alerts=${ZF_ALERTS_FILE:-$AGENT_HOME/logs/head-watch.alerts}
  mkdir -p "$(dirname -- "$alerts")" 2>/dev/null || return 0
  printf '%s PIN-ANCHOR-FIX %s patch=%s engine=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$url" "$patch" "$engine" >> "$alerts"
  return 0
}

# The pin is when main's tools become the live ones, so the same moment moves the shared tool clone that sessions run tools
# from (quick-land, test-receipt: row 887). Bounded, and log-only on error: the sync never fails, delays or undoes the pin.
# A clone someone made dirty or committed in is left untouched and named in the alerts file, once per clone HEAD and reason.
sync_tool_clone() { # next -> 0 always
  local next=$1 clone head reason marker alerts
  clone=${ZF_AUTO_PIN_TOOL_CLONE:-$HOME/.zenoforge/clones/zf-perf-rules}
  [[ -d $clone ]] || { echo "tool-clone: $clone missing, not synced"; return 0; }
  timeout 60 git -C "$clone" fetch -q origin main >/dev/null 2>&1 || { echo "tool-clone: fetch failed in $clone, not synced"; return 0; }
  head=$(timeout 30 git -C "$clone" rev-parse HEAD 2>/dev/null) || { echo "tool-clone: no HEAD in $clone, not synced"; return 0; }
  if [[ -n $(timeout 30 git -C "$clone" status --porcelain 2>/dev/null) ]]; then
    reason=dirty
  elif ! timeout 30 git -C "$clone" merge-base --is-ancestor "$head" "$next" >/dev/null 2>&1; then
    reason=local-commit
  elif timeout 60 git -C "$clone" checkout -q --detach "$next" >/dev/null 2>&1; then
    echo "$(date -u +%H:%M:%S) TOOL-CLONE-SYNCED ${head:0:12} -> ${next:0:12} in $clone"
    return 0
  else
    echo "tool-clone: checkout ${next:0:12} failed in $clone, not synced"
    return 0
  fi
  echo "tool-clone: $clone stays at ${head:0:12}, $reason"
  marker=$ZF_AUTO_PIN_HOME/auto-pin-tool-clone.alerted
  grep -qxF "$head $reason" "$marker" 2>/dev/null && return 0
  printf '%s %s\n' "$head" "$reason" >>"$marker" 2>/dev/null || return 0
  alerts=${ZF_ALERTS_FILE:-$AGENT_HOME/logs/head-watch.alerts}
  mkdir -p "$(dirname -- "$alerts")" 2>/dev/null || return 0
  printf '%s TOOL-CLONE-STALE %s head=%s reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$clone" "$head" "$reason" >>"$alerts"
  return 0
}

# One pass: fetch, pin the oldest unpinned main commit. Returns 1 only when the checkout fails (the unit restarts the daemon).
auto_pin_pass() {
  local last next merged log rc vecta_failed_head vecta_head product_failed_head product_head product_fetch_secs product_fetch_now product_fetch_last product_fetch_rc product_tries
  local psi_file psi_avg60 psi_max psi_wait_secs psi_waited psi_wait_for
  git -C "$C" fetch -q origin main || { sleep "$idle"; return 0; }
  last=$(cat "$state")
  next=$(git -C "$C" rev-list -1 --first-parent "$last..origin/main")
  if [[ -z $next ]]; then sleep "$idle"; return 0; fi
  git -C "$C" checkout -q --detach "$next" || return 1
  merged=$(git -C "$C" log -1 --format=%cI "$next"); log="$logdir/${next:0:12}.log"
  psi_file=${ZF_AUTO_PIN_PSI_FILE:-/proc/pressure/cpu}
  psi_max=${ZF_AUTO_PIN_PSI_MAX:-60}
  [[ $psi_max =~ ^[0-9]+([.][0-9]+)?$ ]] || psi_max=60
  psi_wait_secs=${ZF_AUTO_PIN_LOAD_WAIT_SECS:-900}
  [[ $psi_wait_secs =~ ^[0-9]+$ ]] || psi_wait_secs=900
  psi_wait_secs=$((10#$psi_wait_secs))
  psi_avg60=$(sed -n 's/^some avg10=[0-9.]* avg60=\([0-9.]*\).*/\1/p' "$psi_file" 2>/dev/null || :)
  if [[ ${LUNA_PRIORITY:-} != hotfix && $psi_avg60 =~ ^[0-9]+([.][0-9]+)?$ ]] \
    && awk -v psi="$psi_avg60" -v max="$psi_max" 'BEGIN { exit !(psi > max) }'; then
    echo "auto-pin: waiting, cpu psi avg60 $psi_avg60 > $psi_max"
    psi_waited=0
    while ((psi_waited < psi_wait_secs)) && [[ ! -e $stop ]]; do
      psi_wait_for=30
      if ((psi_wait_secs - psi_waited < psi_wait_for)); then
        psi_wait_for=$((psi_wait_secs - psi_waited))
      fi
      sleep "$psi_wait_for"
      psi_waited=$((psi_waited + psi_wait_for))
      psi_avg60=$(sed -n 's/^some avg10=[0-9.]* avg60=\([0-9.]*\).*/\1/p' "$psi_file" 2>/dev/null || :)
      if ! [[ $psi_avg60 =~ ^[0-9]+([.][0-9]+)?$ ]] \
        || ! awk -v psi="$psi_avg60" -v max="$psi_max" 'BEGIN { exit !(psi > max) }'; then
        break
      fi
    done
    [[ ! -e $stop ]] || return 0
    if [[ $psi_avg60 =~ ^[0-9]+([.][0-9]+)?$ ]] \
      && awk -v psi="$psi_avg60" -v max="$psi_max" 'BEGIN { exit !(psi > max) }'; then
      echo 'auto-pin: load wait expired'
    fi
  fi
  [[ ! -e $stop ]] || return 0
  # shortcut: timeout bounds one pin at 500s, same as the manual flow; a slower land needs a manual rerun.
  rc=0; (cd "$C" && timeout 500 bash tools/pin-vecta.sh "$next" "$AGENT_HOME/checkout" --land) >"$log" 2>&1 || rc=$?
  if ((rc == 75)) && merge_override_pin "$log"; then
    # The PR route does not fast-forward the live checkout; the agent tick does, then converges.
    systemctl --user start --no-block vecta-agent.service 2>/dev/null || :
    echo "$next" > "$state"; echo "$(date -u +%H:%M:%S) PINNED ${next:0:12} via-pr committed=$merged $(git -C "$C" log -1 --format=%s "$next" | cut -c1-70)"
    sync_tool_clone "$next" || :
  elif ((rc == 0)); then
    # The live wrapper, not the VectA hook: only the wrapper records the swap that the engine canary watches.
    AGENT_HOME=$AGENT_HOME timeout 280 "$AGENT_HOME/engine-live/engine-sync.sh" --converge "$AGENT_HOME/checkout" "$AGENT_HOME" >>"$log" 2>&1 || echo "$(date -u +%H:%M:%S) CONVERGE-FAILED ${next:0:12}"  # live now, not at the next timer run
    echo "$next" > "$state"; echo "$(date -u +%H:%M:%S) PINNED ${next:0:12} committed=$merged $(git -C "$C" log -1 --format=%s "$next" | cut -c1-70)"
    sync_tool_clone "$next" || :
  else
    vecta_failed_head=$(git -C "$AGENT_HOME/checkout" rev-parse HEAD 2>/dev/null || :)
    product_failed_head=$(git -C "$AGENT_HOME/checkout" rev-parse origin/main 2>/dev/null || :)
    echo "$(date -u +%H:%M:%S) PIN-FAILED ${next:0:12} log=$log"; grep -E 'pin-vecta:|refus|add this row' "$log" | tail -4 | cut -c1-200
    pin_anchor_finding "$log" "$last" "$next" || :
    # A reviewed merge can land its own missing row through the checked VectA PR path; keep the pending engine SHA for the next pass.
    if grep -q 'add this row' "$log" && [[ ! -e $log.row-retried ]] \
      && reviewed_merge "$next" && ! row_named_exact_declared "$log" "$AGENT_HOME/checkout/.zenoforge/build/intended-changes.tsv"; then
      if row_path=$(auto_pin_land_row "$log" "$last" "$next"); then
        : > "$log.row-retried"
        echo "$(date -u +%H:%M:%S) PIN-ROW-AUTO ${next:0:12} $row_path"
        return 0
      fi
    fi
    # A rate limit (GraphQL or REST, primary or secondary) clears with time, not with a new main commit: pin this commit again after a backoff, at most 3 times.
    if grep -qi 'rate limit' "$log"; then
      tries=$(ls "$log".rate-retry-* 2>/dev/null | wc -l)
      if ((tries < 3)); then
        : > "$log.rate-retry-$((tries + 1))"
        echo "$(date -u +%H:%M:%S) RATE-LIMIT-RETRY ${next:0:12} attempt=$((tries + 1))"
        sleep "${ZF_AUTO_PIN_RATE_SECS:-300}"; return 0
      fi
    fi
    [[ -e $log.pin-fail-triaged ]] || AGENT_HOME=$AGENT_HOME bash "$C/tools/pin-fail-triage.sh" "$C" "$AGENT_HOME/checkout" "$next" "$log" "$rc" || :
    # Fix forward: a failed pin must not stop the daemon, the next main commit carries the repair.
    while [[ ! -e $stop ]]; do
      sleep "$retry"; git -C "$C" fetch -q origin main || continue
      [[ "$(git -C "$C" rev-parse origin/main)" == "$next" ]] || break
      # A dirty checkout clears with no new main commit, so try the same commit again.
      grep -q 'source checkout has changes' "$log" && [[ -z "$(git -C "$AGENT_HOME/checkout" status --porcelain 2>/dev/null)" ]] && return 0
      # A row declared after the refusal, the one it named: try it again, since a new main commit would make the row stale. Once only.
      if grep -q 'add this row' "$log" && [[ ! -e $log.row-retried ]] \
        && row_named_declared "$log" "$AGENT_HOME/checkout/.zenoforge/build/intended-changes.tsv" "$last" "$next"; then
        : > "$log.row-retried"; return 0
      fi
      # A product origin/main move may fix a fork refusal; refresh at most once per interval.
      product_fetch_secs=${ZF_AUTO_PIN_PRODUCT_FETCH_SECS:-600}
      [[ $product_fetch_secs =~ ^[0-9]+$ ]] || product_fetch_secs=600
      product_fetch_now=$(date +%s 2>/dev/null || :)
      product_fetch_last=$(cat "$product_fetch_time" 2>/dev/null || :)
      product_head=''
      if [[ $product_fetch_now =~ ^[0-9]+$ ]] \
        && { [[ ! $product_fetch_last =~ ^[0-9]+$ ]] || ((product_fetch_now - product_fetch_last >= product_fetch_secs)); }; then
        if printf '%s\n' "$product_fetch_now" > "$product_fetch_time"; then
          product_fetch_rc=0
          timeout 60 git -C "$AGENT_HOME/checkout" fetch -q origin main >/dev/null 2>&1 || product_fetch_rc=$?
        else
          product_fetch_rc=1
        fi
        if ((product_fetch_rc == 0)); then
          product_head=$(git -C "$AGENT_HOME/checkout" rev-parse origin/main 2>/dev/null || :)
        else
          echo "$(date -u +%H:%M:%S) PRODUCT-FETCH-FAILED commit=${next:0:12} rc=$product_fetch_rc"
        fi
      fi
      product_tries=$(ls "$log".product-main-*-retried 2>/dev/null | wc -l)
      if [[ -n $product_failed_head && -n $product_head && $product_head != "$product_failed_head" ]] \
        && ((product_tries < 3)) && [[ ! -e $log.product-main-$product_head-retried ]]; then
        : > "$log.product-main-$product_head-retried"
        echo "$(date -u +%H:%M:%S) RETRY-PRODUCT-MAIN from=$product_failed_head to=$product_head commit=$next"
        return 0
      fi
      # A moved VectA checkout may fix a refusal; retry this commit once for each new checkout head.
      vecta_head=$(git -C "$AGENT_HOME/checkout" rev-parse HEAD 2>/dev/null || :)
      if [[ -n $vecta_failed_head && -n $vecta_head && $vecta_head != "$vecta_failed_head" \
        && ! -e $log.vecta-head-$vecta_head-retried ]]; then
        : > "$log.vecta-head-$vecta_head-retried"
        echo "$(date -u +%H:%M:%S) RETRY-VECTA-HEAD from=$vecta_failed_head to=$vecta_head commit=$next"
        return 0
      fi
    done
    echo "$next" > "$state"
  fi
}

auto_pin_main() {
  mkdir -p "$logdir" "$ZF_AUTO_PIN_HOME/locks"
  exec 8>"$ZF_AUTO_PIN_HOME/locks/auto-pin"; flock -n 8 || { echo 'zf-auto-pin: already running'; exit 1; }
  while [[ ! -e $stop ]]; do
    auto_pin_pass || exit 1
    # A running daemon keeps the script it started with: #656 sat unused for 13 hours. On exit systemd reinstalls the copy from the clone.
    if [[ -f $C/tools/auto-pin.sh ]] && ! cmp -s "$C/tools/auto-pin.sh" "${BASH_SOURCE[0]}"; then
      echo 'zf-auto-pin: the clone has a newer script, exiting for systemd to reinstall it'; exit 0
    fi
  done
  echo 'zf-auto-pin: stopped by stop file'
}
[[ ${BASH_SOURCE[0]} != "$0" ]] || auto_pin_main
