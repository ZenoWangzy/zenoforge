
recover_orphan_landing() { # landing 无活 land worker（被杀/重启）→ 回 ready-to-merge 重试
  local id wp has_live
  for id in $(jqf -r '.units[] | select(.stage=="landing") | .id' "$UNITS"); do
    has_live=false
    for wp in $(jqf -r --arg u "$id" '.workers[] | select(.unit==$u and .harvested != true) | .pid' "$WORKERS"); do
      alive "$wp" && has_live=true && break
    done
    [[ "$has_live" == true ]] || { set_unit "$id" "$(hist orphan-recover 'landing worker missing; retry merge') | .stage=\"ready-to-merge\""; say "orphan-recover unit=$id landing -> ready-to-merge"; }
  done
}

# 失败回合数：只数返工/阻断/回退/无产出，不数正常推进（批准、合并不算）。
loop_rounds() { # 只数最近一次 supervisor 裁决（requeue/approve）或仲裁之后的失败回合（裁决后重新给满额度）
  # supervisor-approve 以前不算：issue-3560 获批后 CI 测试红转 repair，旧的 5 轮被重算，没修就直接转人工（05:13）。
  jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage | IN("supervisor-requeue","supervisor-approve","supervisor-cap-budget-refill","arbiter-review")) | .key] | max // -1) as $i | [$h[($i + 1):][] | select(.stage=="review-request-changes" or .stage=="review-block" or .stage=="merge-reverted" or .stage=="worker-no-output")] | length' <<<"$1"
}

# 止损预算（#4363）：自最近一次裁决（supervisor requeue/approve 或顾问裁决）起，
# 已花费的 implement/repair 轮数（每个有效 write-start 一轮）与第一轮至今的墙钟。经记录确认的空发现、同 head 无推送修复不计轮；
# 裁决重置预算，让既有顾问收敛通道完整跑完；没有任何裁决拦得住的单元才止损转 supervisor。
# 预算内输出空；超轮数输出 "rounds N of B"，超墙钟输出 "wall Xmin of Ymin after N rounds"。
effective_write_starts_since_ruling() { # unit-json ruling-stages-json → write-start records excluding verified empty repair no-ops
  jqf -c --argjson ruling_stages "$2" '
    def empty_findings_noop($index; $history; $records):
      ([$history | to_entries[]
        | select(.key < $index and (.value.stage | startswith("review-")))] | last // null) as $review
      | if $review == null or $review.value.stage != "review-request-changes" then false
        else
          ([$history | to_entries[]
            | select(.key <= $review.key and .value.stage == "review-request-changes")] | length) as $round
          | ([$records[] | select(.round == $round)] | last // null) as $findings
          | ([$history | to_entries[] | select(.key > $index and .value.stage == "repair-no-push")] | first // null) as $no_push
          | ([$history | to_entries[] | select(.key > $index and .value.stage == "write-start")] | first // null) as $next_write
          | (if $no_push == null then ""
             else try ($no_push.value.result | capture("^head (?<sha>[0-9a-f]{40}) unchanged after repair$").sha) catch ""
             end) as $same_head
          | $findings != null and $findings.block == "ok"
            and ($findings.findings | type) == "array" and ($findings.findings | length) == 0
            and ($findings.all_findings | type) == "array" and ($findings.all_findings | length) == 0
            and $same_head != "" and $review.value.result == $same_head
            and ($next_write == null or $no_push.key < $next_write.key)
        end;
    (.history // []) as $history
    | (.review_findings // []) as $records
    | ([$history | to_entries[]
        | select(.value.stage as $stage | ($ruling_stages | index($stage)) != null)
        | .key] | max // -1) as $ruling
    | [$history | to_entries[]
      | select(.key > $ruling and .value.stage == "write-start")
      | select(.value.work_type != "repair" or (empty_findings_noop(.key; $history; $records) | not))
      | .value]
  ' <<<"$1"
}

ticket_budget_reason() { # unit-json
  # An approval or ci-ready also starts the round count over (repair after approval gets its own rounds); the wall still resets on rulings only.
  local rounds ruling_stages='["supervisor-requeue","supervisor-approve","supervisor-cap-budget-refill","advisor-ruling"]'
  local round_stages='["supervisor-requeue","supervisor-approve","supervisor-cap-budget-refill","advisor-ruling","review-approve","ci-ready"]'
  rounds="$(effective_write_starts_since_ruling "$1" "$round_stages")" || return 1
  # The wall counts time a worker held the unit: 2295 read 1688min after 1 round, nearly all of it queue.
  jqf -r --argjson rounds "$rounds" --argjson ruling_stages "$ruling_stages" --argjson round_budget "$TICKET_ROUND_BUDGET" --argjson wall_budget "$TICKET_WALL_BUDGET_SECONDS" --argjson now "$NOW_EPOCH" '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN($ruling_stages[])) | .key] | max // -1) as $ruling
    | (reduce ($h[($ruling + 1):][] | select(.at != null)) as $e ({open: null, next_row: null, secs: 0};
        ($e.at | epoch) as $t
        | if $e.stage == "write-start" or $e.stage == "write-end" then
            # A write with no end stopped at the first row after it: the worker expired and the gap to the next start is queue.
            (if .open != null then .secs += ([(if $e.stage == "write-end" then $t else .next_row // $t end) - .open, 0] | max) else . end)
            | .open = (if $e.stage == "write-start" then $t else null end) | .next_row = null
          elif .open != null then .next_row //= $t
          else . end)) as $work
    | ($work.secs + (if $work.open == null then 0
        elif (.stage // "" | IN("implement", "repair")) then [$now - $work.open, 0] | max
        elif $work.next_row != null then [$work.next_row - $work.open, 0] | max
        else 0 end)) as $worker_secs
    | if ($rounds | length) >= $round_budget
      then "rounds \($rounds | length) of \($round_budget)"
      else select($worker_secs > $wall_budget)
        | "wall \(($worker_secs / 60) | floor)min of \(($wall_budget / 60) | floor)min after \($rounds | length) rounds"
      end' <<<"$1" 2>/dev/null
}

# 同一失败重复（行 90：24h 内 37 次 stop-loss 转 arbiter，前面是同一个 self-check-red/ci-test-red 的，requeue 交付 0 of 4）：
# 自最近一次裁决（与 ticket_budget_reason 同一组 ruling 阶段）起，单元最前面的事件是红（ci-test-red/ci-red/self-check-red），
# 且它的 (阶段, 规整后的 result) 与更早一轮的红相同。规整同 ~/.zenoforge/state/work/90/v2.py：长十六进制串和数字都换成 N。
# The scheduler's own fresh-signal requeue (stop_loss_fresh_requeue) is not a ruling here: the window runs on across it, so the same signal
# coming back after that requeue is a repeat. A merge conflict or a review request-changes repeats when the requeue named it.
STOP_LOSS_FRESH_PREFIX='scheduler fresh-signal requeue: '
STOP_LOSS_FRESH_METRIC=supervisor.fresh_requeue_delivery_24h
STOP_LOSS_WINDOW_JQ='
    def sched: .stage == "supervisor-requeue" and ((.result // "") | startswith($prefix));
    def norm: tostring | gsub("\\b(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}\\b"; "N") | gsub("[0-9]+"; "N") | gsub("\\s+"; " ");
    def red: .stage | IN("ci-test-red", "ci-red", "self-check-red");
    (.history // []) as $h
    | ([$h | to_entries[] | select((.value.stage | IN("supervisor-requeue", "supervisor-approve", "supervisor-cap-budget-refill", "advisor-ruling")) and (.value | sched | not)) | .key] | max // -1) as $ruling
    | $h[($ruling + 1):] as $w
    | ([$w[] | select(.stage | IN("ci-test-red", "ci-red", "self-check-red", "merge-conflict", "review-request-changes", "review-block", "review-approve", "ci-ready",
        "repair-no-push", "worker-no-output", "implement-no-push", "implement-no-changes", "size-recut"))] | last // null) as $front
    | ([$w[] | select(red) | [.stage, (.result | norm), (.result // "" | tostring | gsub("\\s+"; " "))]]) as $reds'
stop_loss_same_failure() { # unit-json → prints the failure's check label (the red event's result) when it repeats an earlier round's; rc 1 otherwise
  jqf -er --arg prefix "$STOP_LOSS_FRESH_PREFIX" "$STOP_LOSS_WINDOW_JQ"'
    | select($front != null and (if $front | red then ($reds[-1]) as $c | $reds[:-1] | any(.[0] == $c[0] and .[1] == $c[1])
        else ($front.stage | IN("merge-conflict", "review-request-changes")) and any($w[] | select(sched); (.result | ltrimstr($prefix)) == $front.stage) end))
    | if $front | red then $reds[-1][2] else $front.stage end' <<<"$1" 2>/dev/null
}

# A fresh signal (a first-time red check, a merge conflict, a review request-changes) at the round budget: row 90 saw the arbiter requeue 30 of 31
# of them and 16 of 22 delivered, so the scheduler requeues without a model run, at most twice since the last real ruling (a repeat of the first
# signal is stop_loss_same_failure, the other route). While the fresh requeues' own delivery rate sits under 50% on at least 6 outcomes
# (the scorecard value is null below 6), they go back to the arbiter. rc 0 when it requeued.
stop_loss_fresh_requeue() { # id unit-json budget-reason
  local id="$1" signal count rate
  [[ "$3" == rounds* ]] && ! stop_loss_same_failure "$2" >/dev/null || return 1
  IFS=$'\t' read -r signal count < <(jqf -er --arg prefix "$STOP_LOSS_FRESH_PREFIX" "$STOP_LOSS_WINDOW_JQ"'
    | select($front != null and (($front.stage | IN("ci-test-red", "ci-red", "self-check-red", "merge-conflict"))
        or ($front.stage == "review-request-changes" and ([$w[] | select(.stage == "review-request-changes")] | length) == 1)))
    | [(if $front | red then $reds[-1][0] + " " + $reds[-1][2][0:100] else $front.stage end), ([$w[] | select(sched)] | length)] | @tsv' <<<"$2" 2>/dev/null) || return 1
  (( count < 2 )) || return 1
  rate="$(jqf -r --arg id "$STOP_LOSS_FRESH_METRIC" '.metrics[]? | select(.id == $id) | .value // empty' "$A/node-health.json" 2>/dev/null || true)"
  [[ -z "$rate" ]] || jqf -en --argjson rate "$rate" '$rate >= 50' >/dev/null 2>&1 || return 1
  set_unit "$id" "$(hist supervisor-requeue "$STOP_LOSS_FRESH_PREFIX$signal")" && say "stop-loss fresh signal unit=$id requeued once in the scheduler: $signal"
}

# A repeated failure whose check is red on main belongs to main, not to the unit (main-red units come from health-release; their SHAs'
# failed checks are fetched once per SHA per tick by main_red_failed_checks). label → the active main-red SHA, rc 1 when none.
stop_loss_main_red_sha() { # check-label (ci-* result: names joined by ", ")
  local sha checks
  while read -r sha; do
    [[ "$sha" =~ $SHA_RE ]] || continue
    checks="$(main_red_failed_checks "$sha")" || continue
    jqf -en --arg label "$1" --argjson main "$checks" '($label | split(", ")) as $names | any($names[]; . as $n | $main | index($n) != null)' >/dev/null 2>&1 \
      && { printf '%s\n' "$sha"; return 0; }
  done < <(jqf -r '.units[] | select(.main_red == true and ((.ci_sha // "") | test("^[0-9a-f]{40}$")) and ((.stage // "") | IN("closed","landed","merged","done") | not)) | .ci_sha' "$UNITS" | sort -u)
  return 1
}

# Both exits of a same-failure stop-loss land here. The wait (check red on main) reuses the main-red park fields; the park (unit's own failure)
# reads exactly "stop-loss same failure: <check>". Each records the PR head so stop_loss_unpark_sweep can requeue when it changes.
stop_loss_same_failure_hold() { # id from-stage label [main-red-sha]
  local id="$1" from="$2" label="$3" red_sha="${4:-}" pr head="" set
  pr="$(unit_field "$id" '.pr // empty')"
  [[ ! "$pr" =~ ^[0-9]+$ ]] || head="$(tick_pr_head "$pr" 2>/dev/null || true)"
  if [[ -n "$red_sha" ]]; then
    set="$(hist ci-main-red-park "stop-loss same failure: ${label:0:80} also failed on main $red_sha") | .stage=\"parked\" | .parked_reason=\"main-red\" | .unpark_condition=\"the same checks pass on main\" | .parked_main_red_sha=$(js "$red_sha") | .stop_loss_wait=true"
  else
    [[ "$(unit_field "$id" '.stage // empty')" == parked ]] || return 0
    set=".parked_reason=$(js "stop-loss same failure: ${label:0:80}") | .unpark_condition=$(js "$([[ -n "$pr" ]] && echo 'the PR head changes' || echo 'a supervisor decision')")"
  fi
  # One timed retry per unit: a unit already requeued by it parks again with the PR-head exit only.
  if [[ -z "$red_sha" && -n "$head" && "$(unit_field "$id" '.stop_loss_timed_requeue // empty')" != true && "$MAIN_HEAD" =~ $SHA_RE ]]; then
    set="$set | .stop_loss_park_epoch=${NOW_EPOCH:-$(date +%s)} | .stop_loss_park_main=$(js "$MAIN_HEAD")"
  fi
  set_unit "$id" "$set | .parked_from_stage=$(js "$from") | .stop_loss_park_head=$(js "$head")" && say "stop-loss same failure unit=$id: $([[ -n "$red_sha" ]] && echo "waits for main green ($red_sha)" || echo parked)"
}

stop_loss_unpark_sweep() { # requeue (refilled budget) when the PR head changed or the main red the unit waited on turned green
  local id from head red_sha pr park_epoch park_main cur resolved why timed
  while IFS=$'\t' read -r id from head red_sha pr park_epoch park_main; do
    [[ -n "$id" ]] || continue
    why=""
    if [[ "$pr" =~ ^[0-9]+$ && "$head" =~ $SHA_RE ]]; then
      cur="$(tick_pr_head "$pr" 2>/dev/null || true)"
      [[ ! "$cur" =~ $SHA_RE || "$cur" == "$head" ]] || why="PR head changed to ${cur:0:9}"
    fi
    if [[ -z "$why" && "$red_sha" =~ $SHA_RE ]]; then
      resolved="$(jqf -r --arg red "$red_sha" 'first(.units[] | select(.main_red==true and .ci_sha==$red and .stage=="closed" and ((.resolved_main_sha // "") | test("^[0-9a-f]{40}$"))) | .resolved_main_sha) // empty' <(units_history_doc))"
      [[ ! "$resolved" =~ $SHA_RE ]] || why="main green at ${resolved:0:9}"
    fi
    # Backoff retry, once: parked past STOP_LOSS_PARK_RETRY_SECONDS (24 h) and main has advanced since the park. The branch is brought up to the new main
    # through ci_update_branch (the one server-side rebase path); a refused update still requeues, and the redispatched worker starts from the latest main.
    timed=""
    if [[ -z "$why" && "$park_epoch" =~ ^[0-9]+$ && "$park_main" =~ $SHA_RE && "$MAIN_HEAD" =~ $SHA_RE && "$MAIN_HEAD" != "$park_main" ]] \
      && (( ${NOW_EPOCH:-$(date +%s)} - park_epoch >= ${STOP_LOSS_PARK_RETRY_SECONDS:-86400} )); then
      cur="$(tick_pr_head "$pr" 2>/dev/null || true)"
      if [[ "$cur" =~ $SHA_RE ]] && ci_update_branch "$pr" "$cur"; then why="parked over 24 h and main advanced to ${MAIN_HEAD:0:9}: branch updated onto it"
      else why="parked over 24 h and main advanced to ${MAIN_HEAD:0:9}: branch update not applied, the worker starts from the latest main"; fi
      timed=" | .stop_loss_timed_requeue=true"
    fi
    [[ -n "$why" ]] || continue
    [[ "$from" != - ]] || from=repair-pending
    set_unit "$id" "$(hist supervisor-requeue "stop-loss same failure: unparked, $why; budget refilled") | .stage=$(js "$from") | .note=null$timed | del(.stop_loss_park_epoch,.stop_loss_park_main,.parked_reason,.unpark_condition,.parked_main_red_sha,.parked_from_stage,.stop_loss_park_head,.stop_loss_wait)" \
      && say "stop-loss same failure unit=$id requeued at $from: $why"
  done < <(jqf -r '.units[] | select(.stage == "parked" and .stop_loss_park_head != null)
    | [.id, (.parked_from_stage // "-"), (.stop_loss_park_head | if . == "" then "-" else . end), (.parked_main_red_sha // "-"), (.pr // "-"), (.stop_loss_park_epoch // "-"), (.stop_loss_park_main // "-")] | @tsv' "$UNITS")
}

# Token spend gate. Every finished worker log is one `spend_runs` record on its unit (spend_ledger.py; fresh tokens come from the
# dashboard's own unit_spend, so this gate and `workorders` agree). Lifetime fresh tokens past the soft line park the unit once and
# send it to one arbiter decision whose prompt carries the per-run table and a class; the first return to dispatch after that is the
# single refill (a `token-refill` event). Past the hard line the unit parks for good: the check reads only spend, so no ruling kind
# (supervisor-requeue, cap-budget-refill, advisor-ruling, arbiter) can refill it, and the head hears of it once through the inbox.
record_run_spend() { # → one spend_runs record on the unit of each finished worker log not yet recorded; one ledger write for the lot
  local out rc=0 err
  err="$(mktemp "$A/.spend-sweep.XXXXXX")" || return 0
  out="$(timeout 120 python3 "$HERE/spend_ledger.py" sweep "$SUP" "$UNITS" 500 2>"$err")" || rc=$?
  # A failed sweep used to vanish (2>/dev/null) and left the gate summing zero: say it, the liveness metric then names the gap.
  (( rc == 0 )) || { say "spend ledger sweep failed rc=$rc: $(tail -n 1 "$err" | cut -c1-200)"; rm -f -- "$err"; return 0; }
  rm -f -- "$err"
  [[ -n "$out" ]] || return 0
  units_update --slurpfile runs <(printf '%s\n' "$out") 'reduce $runs[] as $r (.;
    (.units[] | select(.id == $r.unit)) |= (.spend_runs = (if any((.spend_runs // [])[]; .log == $r.run.log) then .spend_runs else (.spend_runs // []) + [$r.run] end)
      | .history = [(.history // [])[] | if .stage == "write-start" and .attempt == $r.run.log then . + {fresh_tokens: $r.run.fresh_tokens, raw_tokens: $r.run.raw_tokens} else . end]))' \
    && say "spend ledger recorded $(grep -c . <<<"$out") run(s)" || say "spend ledger write failed"
}

unit_fresh_tokens() { jqf -r '[(.spend_runs // [])[] | .fresh_tokens // 0] | add // 0' <<<"$1"; }

token_spend_verdict() { # unit-json → hard | soft | refill | ok
  local total
  total="$(unit_fresh_tokens "$1")"
  [[ "$total" =~ ^[0-9]+$ ]] || { echo ok; return 0; }
  if (( total >= TOKEN_PARK_HARD_TOKENS )); then echo hard
  elif (( total >= TOKEN_PARK_SOFT_TOKENS )); then
    jqf -r '(.history // []) as $h
      | if any($h[]; .stage == "token-refill") then "ok"
        elif any($h[]; .stage == "token-park" and ((.result // "") | startswith("soft"))) then "refill"
        else "soft" end' <<<"$1"
  else echo ok; fi
}

token_park_class() { # unit-json → report-gate-loop | hot-file-churn | undersized | unclassified
  jqf -r '
    (.history // []) as $h
    | ([(.review_findings // [])[] | select((.report // "") | test("^(incident|engine-override)-gate-"))] | length) as $gates
    | ([$h[] | if .stage == "merge-conflict" then ((.conflict_files // "") | sub(" count=[0-9]+$"; "") | split(",") | unique[])
               elif .stage == "ci-test-red" then ((.tests // []) | unique[])
               else empty end
        | select(type == "string" and length > 0 and (startswith("unavailable") | not) and (startswith("none") | not))]
       | group_by(.) | map(length) | max // 0) as $same_file
    | if $gates >= 2 then "report-gate-loop"
      elif $same_file >= 2 then "hot-file-churn"
      elif any($h[]; .stage == "size-recut" or .stage == "size-split-admitted"
                     or (.stage == "supervisor-escalated" and ((.result // "") | startswith("size admission:")))) then "undersized"
      else "unclassified" end' <<<"$1"
}

token_park_context() { # unit-json → the arbiter prompt block for a unit parked at the soft line; empty otherwise
  jqf -r 'select((.token_park.level // "") == "soft") | .token_park as $t
    | "## Token-spend park (scheduler)\nThis unit passed \($t.fresh_tokens) lifetime fresh tokens (uncached input + output) and was parked for this one decision. Class: \($t.class) (report-gate-loop = repeated incident/report gate overrides; hot-file-churn = repeated merge-conflict or ci-test-red on the same shared file; undersized = size recheck escalation after implement; unclassified = none of these). A ruling that sends the unit back to work refills it once; past the hard line no ruling refills it, so prefer recut, close or park when the class says the loop will repeat.\nPer-run spend (start, phase, backend, minutes, fresh tokens):\n"
      + ([$t.runs[] | "\(.start)\t\(.phase)\t\(.backend)\t\(.minutes)\t\(.fresh_tokens)"] | join("\n"))' <<<"$1"
}

token_spend_park() { # id unit-json soft|hard
  local id="$1" u="$2" level="$3" total class rec note ev=""
  total="$(unit_fresh_tokens "$u")"; class="$(token_park_class "$u")"
  note="$level token line: $total lifetime fresh tokens (class $class)"
  # The table is built inside the filter from the unit's own records: a unit with many runs must not ride on a command line.
  rec="(.spend_runs // []) as \$r | {level:$(js "$level"), class:$(js "$class"), fresh_tokens:$total, at:$(js "$STAMP"), runs:[\$r | sort_by(.start)[] | {start, phase, backend, minutes, fresh_tokens}]}"
  if [[ "$level" == soft ]]; then
    set_unit "$id" "$(hist token-park "soft: $note") | .token_park=($rec)" || return 1
    to_supervisor "$id" "token park: $note" 'Park at the soft token line for one arbiter decision' \
      'lifetime fresh tokens passed the soft line' "$total fresh tokens against the $TOKEN_PARK_SOFT_TOKENS line, class $class" \
      '["Dispatch another worker round at the same scope"]'
    return 0
  fi
  cancel_unit_runs "$id" "parked at the hard token line"
  # The park event is recorded once per unit: a later requeue that the gate parks again only repeats the state, not the count.
  jqf -e 'any((.history // [])[]; .stage == "token-park" and ((.result // "") | startswith("hard")))' <<<"$u" >/dev/null 2>&1 || ev="$(hist token-park "hard: $note") | "
  set_unit "$id" "${ev}.token_park=($rec) | .stage=\"parked\" | .note=$(js "token hard park: $note") | $(park_fields token-hard-park 'never: no ruling refills a unit past the hard token line')" || return 1
  say "token hard park unit=$id fresh=$total line=$TOKEN_PARK_HARD_TOKENS class=$class"
  (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "token-hard-park:$id" "token-hard-park unit=$id: $total lifetime fresh tokens passed the hard line $TOKEN_PARK_HARD_TOKENS (class $class); no ruling refills it") \
    || say "token hard park unit=$id: inbox entry not delivered"
}

token_spend_gate() { # id unit-json [check-only] → 0 when the unit may dispatch, 1 when it is held (parked, or the full tick decides)
  local id="$1" u="$2" verdict ruling
  verdict="$(token_spend_verdict "$u")"
  [[ "$verdict" != ok ]] || return 0
  [[ "${3:-}" != check-only ]] || return 1
  case "$verdict" in
    refill)
      ruling="$(jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage == "token-park") | .key] | max // -1) as $p
        | [$h[($p + 1):][] | select((.stage | test("^(supervisor|advisor|arbiter)-")) and (.stage | IN("supervisor-escalated", "supervisor-arbiter") | not)) | .stage] | last // "released"' <<<"$u")"
      set_unit "$id" "$(hist token-refill "once, after $ruling; the hard line stays $TOKEN_PARK_HARD_TOKENS") | del(.token_park)" || return 1
      say "token refill unit=$id after $ruling"
      return 0 ;;
    soft) token_spend_park "$id" "$u" soft || :; return 1 ;;
    *) token_spend_park "$id" "$u" hard || :; return 1 ;;
  esac
}

repair_rounds_since_ruling() { # unit-json → repair starts since the last successful review or supervisor/advisor decision
  local starts
  starts="$(effective_write_starts_since_ruling "$1" '["supervisor-arbiter","supervisor-arbiter-round","supervisor-requeue","supervisor-approve","advisor-ruling","review-approve"]')" || return 1
  jqf -r --argjson starts "$starts" '
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("supervisor-arbiter","supervisor-arbiter-round","supervisor-requeue","supervisor-approve","advisor-ruling","review-approve")) | .key] | max // -1) as $ruling
    | $h[$ruling + 1:] as $recent
    | ($recent | [to_entries[] | select(.value.stage == "write-start" and .value.work_type == "repair") | .key] | min // ($recent | length)) as $first_tagged
    | ([$recent[0:$first_tagged][] | select(.stage == "repair-delivered" or .stage == "self-fix-delivered" or (.stage == "worker-no-output" and .result == "repair"))] | length) as $legacy
    | ([$starts[] | select(.work_type == "repair")] | length) as $tagged
    | $legacy + $tagged' <<<"$1"
}
repair_cap_admission() { # unit-id unit-json → two failed repair rounds escalate before another worker is prepared
  local rounds hard_attempts starts
  rounds="$(repair_rounds_since_ruling "$2")"
  [[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 2 )) || return 0
  starts="$(effective_write_starts_since_ruling "$2" '["supervisor-arbiter","supervisor-arbiter-round","supervisor-requeue","supervisor-approve","advisor-ruling","review-approve"]')" || return 1
  hard_attempts="$(jqf -r --argjson starts "$starts" '[ $starts[] | select(.work_type == "repair" and .hard_escalation == true) ] | length')"
  if [[ "$(jqf -r '.hard_escalated // false' <<<"$2")" != true || "$hard_attempts" == 0 ]]; then
    if ! hard_implementer_fields || ! provider_runtime_ready "$PICK_PROVIDER" "$PICK_MODEL" production "$2"; then
      to_supervisor "$1" "repair cap: two failed repair rounds and no configured hard implementation identity is available" \
        'Escalate to supervisor arbitration because the hard implementation identity is unavailable' \
        'two repair write-starts have failed and the configured production identity cannot run' \
        "$rounds failed repair rounds; hard identity unavailable under the current provider quota/runtime state" \
        '["Dispatch another repair on the failed work identity"]'
      say "repair cap unit=$1 rounds=$rounds hard identity unavailable -> supervisor-review"
      return 1
    fi
    set_unit "$1" "$(hist hard-escalation "two failed repair rounds; next implementation uses the production identity") | .hard_escalated=true"
    say "repair cap unit=$1 rounds=$rounds limit=2 -> hard implementation identity"
    return 0
  fi
  to_supervisor "$1" "repair cap: the hard-tier repair failed; escalate to the configured supervisor arbiter" \
    'Escalate to supervisor arbitration after the hard-tier repair fails' \
    'a repair write-start on the hard identity failed after the two-round escalation' \
    "$rounds failed repair rounds; configured supervisor arbitration profile=$SUPERVISOR_ARBITER_PROFILE" \
    '["Dispatch another repair on the same hard identity"]'
  say "repair cap unit=$1 rounds=$rounds hard-tier repair failed -> supervisor-review"
  return 1
}
# ---------- 2. 派发（焦点与并发；预算只告警） ----------
# 新 worker slot 按 main-red、热修回迁、critical 的现有紧急度排序；其后离完成最近的环节优先，再按配置 tier。
# 2026-10-20 三个热修回迁在 review-pending 等了 56 分钟，名额被新收的孤儿 PR 先拿走（L62）。
dispatch_order() {
  local started=$SECONDS rc=0 elapsed
  jqf -c --argjson priority_order "$DISPATCH_PRIORITY_ORDER" --argjson first_issues "${DISPATCH_FIRST_ISSUES:-[]}" '
    .units
    | map(select(.stage | test("-pending$")))
    | sort_by([
        (.issue as $issue | if any($first_issues[] | numbers; . == $issue) then 0 else 1 end),
        (if .main_red == true then 0 else 1 end),
        (if .hotpatch == true then 0 else 1 end),
        (if .critical == true then 0 else 1 end),
        (if .stage == "rereview-pending" then 0 elif .stage == "repair-pending" then 1 elif .stage == "review-pending" then 2 elif .stage == "implement-pending" then 3 else 4 end),
        ((if .hotpatch == true then "hotfix" elif (.lane // "") == "direct-main" then "opt" else "normal" end) as $tier
          | ($priority_order | index($tier) // ($priority_order | length))),
        (.id // "")
      ])[]
  ' "$UNITS" || rc=$?
  elapsed=$((SECONDS - started))
  [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || (( elapsed < 2 )) || say "dispatch detail candidate_order secs=${elapsed}s"
  return "$rc"
}
# 合并后验证失败被 revert 的单元回到 repair，但原 PR 已是 MERGED：GitHub 不再把分支新提交挂到它上面，repair 推了也
# 显示"head 未变"，单元在 repair-no-push / 仲裁评审里空转到升级（2026-10-21 issue-3451 / #4009 空转 4 小时）。
# repair 交付后用同一分支开新 PR（已有 open PR 就沿用），评审与 CI 在新 PR 上进行。
reopen_reverted_pr() { # unit old-pr
  local branch issue title out pr
  branch="$(unit_field "$1" .branch)"; issue="$(unit_field "$1" '.issue // empty')"
  [[ -n "$branch" ]] || { to_supervisor "$1" "merge of #$2 was reverted but the unit has no branch to re-deliver"; return 0; }
  title="$(unit_field "$1" .title)"
  scheduler_pr_open "$branch" "${title:-$1}${issue:+ (#$issue)}" "${issue:+Refs #$issue

}Re-delivery of #$2: its squash merge was reverted on main after post-merge verification failed. This PR carries the same branch with the repair on top."
  pr="$SCHED_PR_NUM"
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then say "unit=$1 re-delivery PR for reverted #$2 not created yet (branch $branch)"; return 0; fi
  set_unit "$1" "$(hist pr-reopened "#$2 -> #$pr after merge revert") | .pr=$pr | del(.reopen_pr) | .reviewed_sha=null | .reviewed_pr_head=null$([[ "$branch" =~ $GATED_BRANCH_RE ]] && printf ' | .gated=true')"
  say "unit=$1 merge of #$2 was reverted -> re-delivered as PR #$pr"
}
approved_ci_repair_unchanged() { # unit-json head pr-head
  jqf -e --arg sha "$2" --arg pr_head "$3" '
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("review-approve", "review-request-changes", "review-block")) | .key] | max // -1) as $last_review
    | .reviewed_sha == $sha and .reviewed_pr_head == $pr_head
      and $last_review >= 0 and $h[$last_review].stage == "review-approve" and $h[$last_review].result == $sha
      and $h[-1].stage == "repair-delivered"
      and any($h[($last_review + 1):][]; .stage == "ci-test-red" or .stage == "ci-red")
  ' <<<"$1" >/dev/null
}
# A repair run whose PR head did not move is no delivered repair (2026-11-07, PR 5690: a run that stopped before its push was
# written repair-delivered, counted as a repair, and conflict triage re-flagged the same head before the no-push check ran).
# Unchanged heads that are expected stay delivered: an approved head whose CI went red after the approval (the repair concludes
# an infrastructure red and the scheduler reruns it, approved_ci_repair_unchanged), a round whose findings record is verified empty,
# and a report-only round: every blocking finding names the PR body or the delivery report in its `file` field (live values
# "(PR #5618 body)", "PR #4888 implementer report"), so the repair edits GitHub text and no commit can move the head (4741, 5544).
repair_unchanged_expected() { # unit-json head
  jqf -e --arg b "$2" '
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("review-approve", "review-request-changes", "review-block")) | .key] | max // -1) as $i
    | def report_only: type == "string" and (contains("/") | not) and test("^[(]?(PR|pull request)[^/]*(body|description|report)[)]?$|delivery[ -]report"; "i");
      if $i < 0 or $h[$i].result != $b then false
      elif $h[$i].stage == "review-approve" then any($h[($i + 1):][]; .stage == "ci-test-red" or .stage == "ci-red")
      elif $h[$i].stage == "review-request-changes" then
        ([$h[0:($i + 1)][] | select(.stage == "review-request-changes")] | length) as $round
        | ([(.review_findings // [])[] | select(.round == $round)] | last // null) as $f
        | $f != null and $f.block == "ok" and ($f.findings | type) == "array"
          and ((($f.findings | length) == 0 and ($f.all_findings | type) == "array" and ($f.all_findings | length) == 0)
            or (($f.findings | length) > 0 and all($f.findings[]; .file | report_only)))
          and (any($h[($i + 1):][]; .stage == "merge-conflict") | not)
      else false end' <<<"$1" >/dev/null
}
repair_head_class() { # unit workdir -> "<class> <head before the run>": changed | unchanged | unchanged-expected | unknown
  local u base pr branch now
  u="$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  base="$(jqf -r '[(.history // [])[] | select(.stage == "write-start" and .work_type == "repair")] | (last // {}) | .pr_head // empty' <<<"$u")"
  pr="$(jqf -r '.pr // empty' <<<"$u")"; branch="$(jqf -r '.branch // empty' <<<"$u")"
  if [[ ! "$base" =~ $SHA_RE || ! "$pr" =~ ^[0-9]+$ || "$(jqf -r '.lane // "pr"' <<<"$u")" == direct-main ]]; then echo "unknown -"; return 0; fi
  now=""; [[ -z "$2" || -z "$branch" ]] || now="$(timeout 30 git -C "$2" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)"
  [[ "$now" =~ $SHA_RE ]] || now="$(pr_view "$pr" headRefOid)"
  [[ "$now" =~ $SHA_RE ]] || { echo "unknown $base"; return 0; }
  if [[ "$now" != "$base" ]]; then echo "changed $base"
  elif repair_unchanged_expected "$u" "$base"; then echo "unchanged-expected $base"
  else echo "unchanged $base"; fi
}
# A no-push round whose worker log or report shows the backend died (auth, quota, model_not_found, a failed turn): not the work's fault.
repair_backend_failure() { # worker-log report → the first matching line, empty when none
  # The worker's own classifier (bin/worker fatal_reason) prints "worker: fatal stderr pattern: ..."; prose about auth or quota in agent output does not match.
  { grep -hE -m1 '^(worker: )?(fatal stderr pattern|both backends failed)|model_not_found|AI_APICallError' "$1" 2>/dev/null
    grep -hE -m1 '^(worker: )?(fatal stderr pattern|both backends failed)|model_not_found' "$2" 2>/dev/null; } | head -1 | cut -c1-200
}
repair_run_filter() { # unit class head fresh-tokens [worker-log report] -> jq filter: record the run; an unchanged head is repair-no-push, retried twice per head, then to the arbiter route
  local stage=rereview-pending n bf=""
  if [[ "$2" == unchanged ]]; then
    n="$(jqf -r --arg id "$1" --arg h "head $3 " '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage=="repair-no-push" and ((.result // "") | startswith($h)))] | length' "$UNITS")"
    (( n < 2 )) && stage=repair-pending
    bf="$(repair_backend_failure "${5:-/dev/null}" "${6:-/dev/null}")"
    echo "$(hist repair-no-push "head $3 unchanged after repair") | .history[-1].head_class=\"unchanged\" | .history[-1].fresh_tokens=${4:-null}${bf:+ | .history[-1].backend_failure=$(js "$bf")} | .stage=\"$stage\""
  else
    echo "$(hist repair-delivered) | .history[-1].head_class=$(js "$2") | .history[-1].fresh_tokens=${4:-null} | .repair_hint=null | .stage=\"$stage\""
  fi
}
# Circuit breaker on repeated identical outcomes (Nygard, Release It!): REPAIR_BREAKER_RUNS repair runs in a row that end on one
# head leave a further run nothing new to try (issue-5573: four terra repairs on e145d3f0, none pushed), so the unit parks for
# the next automatic arbiter pass, with the head, run count and final report evidence in its ledger note.
REPAIR_BREAKER_RUNS="${REPAIR_BREAKER_RUNS:-2}"
repair_breaker() { # unit report-file → parks the unit when its last repair runs all ended repair-no-push on the same head
  local u head n evidence result
  u="$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  head="$(jqf -r '(.history // [])[-1] // {} | select(.stage == "repair-no-push") | (.result // "") | capture("^head (?<sha>[0-9a-f]{40}) unchanged").sha? // empty' <<<"$u" 2>/dev/null)"
  [[ "$head" =~ $SHA_RE ]] || return 0
  n="$(jqf -r --arg r "head $head unchanged after repair" '[(.history // [])[] | select(.stage == "repair-no-push" or .stage == "repair-delivered")] | reverse
    | reduce .[] as $e ({n: 0, stop: false}; if .stop then . elif $e.stage == "repair-no-push" and $e.result == $r then .n += 1 else .stop = true end) | .n' <<<"$u")"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= REPAIR_BREAKER_RUNS )) || return 0
  evidence="$(awk '/^```/ { fence = !fence; next } !fence && NF { last = $0 } END { print last }' "$2" 2>/dev/null | cut -c1-300)"
  result="head $head: $n consecutive repair runs ended on it without a push; last evidence: ${evidence:-none recorded}"
  cap_set_unit "$1" park "$result" "" "$(hist repair-breaker "$result") | .stage=\"parked\" | .parked_reason=\"repair-breaker\" | .unpark_condition=\"a supervisor decision\" | .note=$(js "$result")" || return 1
  say "repair breaker unit=$1 head=${head:0:12} runs=$n -> parked"
}
# Admission: a repair on package code runs the Dagger gate, which needs the host's container runtime. The probe is the
# env-fault ledger's own (env:test-gate:docker); rc 1 or 127 means missing, anything else (unknown, timeout) admits. The
# refusal is counted once per hold on the unit and in the ledger counter admission_refusals, and logged; the unit stays
# repair-pending and each later tick only skips it (dispatch_skip), so nothing retries in a loop.
# shortcut: a path regex stands in for "gate needs Dagger" and can drift from the target CI map; upgrade to reading .zenoforge/ci.json (or the focused-test map) and treating a path routed to a Dagger-run suite as needing Dagger, when a second target or a new Dagger suite appears.
REPAIR_DAGGER_PATH_RE="${REPAIR_DAGGER_PATH_RE:-^(packages|apps)/}"
container_runtime_missing() { # → 0 when the host probe says the runtime is missing; one probe per tick
  local rc=0
  if [[ -z "${TICK_CONTAINER_RUNTIME:-}" ]]; then
    timeout 30 bash -c 'source "$1" >/dev/null 2>&1 || exit 2; env_fault_probe env:test-gate:docker' _ "$SCHEDULER_AGENT_LIB" >/dev/null 2>&1 || rc=$?
    case "$rc" in 1|127) TICK_CONTAINER_RUNTIME=missing ;; *) TICK_CONTAINER_RUNTIME=ready ;; esac
  fi
  [[ "$TICK_CONTAINER_RUNTIME" == missing ]]
}
repair_runtime_admission() { # id unit-json → logs once when a container repair runs on a host with no runtime; always admits
  jqf -e --arg re "$REPAIR_DAGGER_PATH_RE" 'any((.footprint // [])[]?; type == "string" and test($re))' <<<"$2" >/dev/null || return 0
  if ! container_runtime_missing; then
    [[ "$(jqf -r '.repair_runtime_refused // false' <<<"$2")" != true ]] || set_unit "$1" 'del(.repair_runtime_refused)'
    return 0
  fi
  if [[ "$(jqf -r '.repair_runtime_refused // false' <<<"$2")" != true ]]; then
    set_unit "$1" '.repair_runtime_refused=true' \
      && units_update '.admission_refusals["repair-no-container-runtime"] = ((.admission_refusals["repair-no-container-runtime"] // 0) + 1)'
    say "repair-runtime-missing unit=$1: admitted without a local container runtime; PR CI runs the Dagger gate"
  fi
  return 0 # 2026-11-08: refusing here never cleared on a host with no runtime (13 repairs held 3.5 h); the same-head breaker still stops a repair that cannot push
}
repair_failure_prompt() { # unit-json review-report -> only this repair's failure evidence
  local u="$1" report="$2" hint pr checks name link job tmp i pid step_file log_file started=$SECONDS elapsed index=0
  local -a names=() links=() step_files=() log_files=() pids=()
  hint="$(jqf -r '.repair_hint // empty' <<<"$u")"
  [[ -z "$hint" ]] || printf '%s\n' "$hint"
  case "$(jqf -r '.history[-1].stage // empty' <<<"$u")" in
    ci-red|ci-test-red)
      pr="$(jqf -r '.pr // empty' <<<"$u")"
      checks="$(repair_check_rows "$pr")" || checks='[]'
      tmp="$(mktemp -d)" || return 1
      # 失败 job 的元数据与日志有界并行取（GH_PARALLEL）。
      while IFS=$'\t' read -r name link; do
        job="${link##*/job/}"; [[ "$job" =~ ^[0-9]+$ ]] || continue
        step_file="$tmp/$index.steps"; log_file="$tmp/$index.log"
        names+=("$name"); links+=("$link"); step_files+=("$step_file"); log_files+=("$log_file")
        (unset GH_TOKEN; gh api "repos/{owner}/{repo}/actions/jobs/$job" \
          --jq '.steps[]? | select(.conclusion=="failure") | "Failing CI step: " + .name' \
          >"$step_file") 2>/dev/null &
        pids+=("$!"); gh_par_throttle pids
        (unset GH_TOKEN
          # 只取报告用的末尾 80 行，不再整份下载 job 日志（05:10:42Z 拍 2 个检查 17s）。日志端点
          # 302 到 Azure blob：后缀区间（bytes=-N）Azure 不认，先 bytes=0-0 探出总长
          # （Content-Range 尾段就是总字节数），再按显式区间只取末 64KB；探不出总长回落整份。
          total="$(gh api -i -H "Range: bytes=0-0" "repos/{owner}/{repo}/actions/jobs/$job/logs" 2>/dev/null \
            | tr -d '\r' | grep -i '^content-range:' | grep -oE '[0-9]+$' || true)"
          if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
            start=$(( total > 65536 ? total - 65536 : 0 ))
            exec gh api --allow-escape-sequences -H "Range: bytes=$start-$((total - 1))" \
              "repos/{owner}/{repo}/actions/jobs/$job/logs"
          else
            exec gh api --allow-escape-sequences "repos/{owner}/{repo}/actions/jobs/$job/logs"
          fi
        ) >"$log_file" 2>/dev/null &
        pids+=("$!"); gh_par_throttle pids
        index=$((index + 1))
      done < <(jqf -r '.[] | select(.bucket=="fail") | [.name,.link] | @tsv' <<<"$checks")
      for pid in "${pids[@]}"; do wait "$pid" || :; done
      for i in "${!names[@]}"; do
        printf '\nFailing CI check: %s\n%s\n' "${names[$i]}" "${links[$i]}"
        cat "${step_files[$i]}" 2>/dev/null || true
        tail -80 "${log_files[$i]}" 2>/dev/null || true
      done
      rm -rf -- "$tmp"
      elapsed=$((SECONDS - started))
      (( elapsed >= 2 )) && say "dispatch detail repair_failure_evidence PR#$pr checks=${#names[@]} secs=${elapsed}s"
      ;;
    *)
      # Review findings come with the hint too (a hotpatch unit carries a hint and then gets REQUEST-CHANGES).
      if [[ -n "$report" && -r "$SUP/$report" ]]; then
        [[ -z "$hint" ]] || printf '\n评审报告 %s：\n' "$report"
        cat -- "$SUP/$report"
      elif [[ -z "$hint" ]]; then
        return 1
      fi
      ;;
  esac
  return 0
}
