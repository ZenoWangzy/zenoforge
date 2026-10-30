
pr_behind_main() { # pr head → 0 = head 不含当前 origin/main
  git -C "$ROOT" fetch -q origin "refs/pull/$1/head" 2>/dev/null || return 1
  [[ "$(git -C "$ROOT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" == "$2" ]] || return 1
  ! git -C "$ROOT" merge-base --is-ancestor refs/remotes/origin/main "$2" 2>/dev/null
}
# head 是 approved 与 main 某提交的干净两亲合并（GitHub update-branch 的产物）：PR 自身改动没变，批准沿用，不再全量复审。
approval_carries() { # pr approved head
  local p1 p2 extra tree
  git -C "$ROOT" fetch -q origin "refs/pull/$1/head" 2>/dev/null || return 1
  [[ "$(git -C "$ROOT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" == "$3" ]] || return 1
  read -r _ p1 p2 extra <<<"$(git -C "$ROOT" rev-list --parents -n1 "$3" 2>/dev/null)"
  [[ "$p1" == "$2" && "$p2" =~ $SHA_RE && -z "$extra" ]] || return 1
  # update-branch merges GitHub's newest main, which the local origin/main may not have yet (10-28: every carry
  # after a fresh merge went stale, costing a rereview + self-check + CI per main advance).
  git -C "$ROOT" merge-base --is-ancestor "$p2" refs/remotes/origin/main 2>/dev/null \
    || { git -C "$ROOT" fetch -q origin refs/heads/main 2>/dev/null && git -C "$ROOT" merge-base --is-ancestor "$p2" FETCH_HEAD 2>/dev/null; } \
    || return 1
  tree="$(git -C "$ROOT" merge-tree --write-tree "$p1" "$p2" 2>/dev/null)" || return 1
  [[ "$tree" == "$(git -C "$ROOT" rev-parse "$3^{tree}" 2>/dev/null)" ]]
}

# ---------- 3. 串行 merge queue + 合并后 exact-SHA suites 验证 ----------
revert_squash_merge() { # pr merge_sha [branch]; main 写入仅由 supervisor 执行时生效；给 branch 就把回退推到该分支（回退 PR），不碰 main
  local pr="$1" merge_sha="$2" target="${3:-main}" origin_url revert_repo
  origin_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "$origin_url" ]] || return 1
  mkdir -p "$WT_ROOT" || return 1
  revert_repo="$(mktemp -d "$WT_ROOT/merge-revert-${pr}.XXXXXX")" || return 1
  # 从本地 checkout 克隆（硬链接对象）再取最新 main，避免每次全量下载。
  if ! git clone -q --no-checkout "$ROOT" "$revert_repo/r" 2>/dev/null; then rm -rf -- "$revert_repo"; return 1; fi
  revert_repo="$revert_repo/r"
  git -C "$revert_repo" config user.name "the product Autopilot Supervisor"
  git -C "$revert_repo" config user.email "zenoforge-autopilot@users.noreply.github.com"
  if ! git -C "$revert_repo" remote set-url origin "$origin_url" \
    || ! git -C "$revert_repo" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main; then
    say "merge revert fetch failed PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  if ! git -C "$revert_repo" cat-file -e "${merge_sha}^{commit}" 2>/dev/null \
    || ! git -C "$revert_repo" merge-base --is-ancestor "$merge_sha" refs/remotes/origin/main; then
    say "merge revert refused: commit not on origin/main PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  if git -C "$revert_repo" log refs/remotes/origin/main --format=%H \
    --grep="This reverts commit ${merge_sha}\." | grep -q .; then
    say "merge revert already present PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    [[ "$target" == main ]]
    return
  fi
  if ! git -C "$revert_repo" checkout -q -B "autopi-revert-pr-${pr}" refs/remotes/origin/main; then
    say "merge revert checkout failed PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  # Squash merge commits have one parent; plain git revert is the correct inverse.
  if ! git -C "$revert_repo" revert --no-edit "$merge_sha"; then
    say "merge revert conflict PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  # Push runs only when this function is executed by the live supervisor.
  if ! git -C "$revert_repo" push origin "HEAD:refs/heads/$target"; then
    say "merge revert push failed PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  rm -rf -- "${revert_repo%/r}"
  return 0
}
main_red_launch() { # sha run-id attempt → 后台写 $MAIN_RED_DIR/<sha>.report，一行 culprit=… 或 fallback=…
  local sha="$1" run="$2" attempt="$3" report="$MAIN_RED_DIR/$1.report"
  [[ -f "${ZF_ENGINE_DIR:-$ROOT/engine}/night/main-ci-recovery.sh" ]] || { echo "fallback=worker-missing" > "$report"; return 0; }
  (cd "$ROOT" && exec setsid timeout -k 5 330 bash -c '
    out="$(ZF_REPO_DIR="$1" bash "$1/engine/night/main-ci-recovery.sh" attribute-red "$2" "$3" "$4" 2>/dev/null | tail -n 1)"
    printf "%s\n" "${out:-fallback=attribution-failed}" > "$5.tmp" && mv "$5.tmp" "$5"' _ "$ROOT" "$run" "$attempt" "$sha" "$report") > /dev/null 2>&1 < /dev/null &
}
main_red_attribution() { # sha run-id attempt；置 MAIN_RED_REVERTED（已回退）和 MAIN_RED_PENDING（复现还在跑）
  local sha="$1" run="$2" attempt="$3" dir="$MAIN_RED_DIR" report line culprit suite uid
  MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0
  [[ "$sha" =~ $SHA_RE && "$run" =~ ^[0-9]+$ && "$attempt" =~ ^[1-9][0-9]*$ ]] || return 0
  report="$dir/$sha.report"
  mkdir -p "$dir" || return 0
  if [[ -e "$dir/$sha.reverted" ]]; then MAIN_RED_REVERTED=1; return 0; fi
  [[ ! -e "$dir/$sha.revert-failed" ]] || return 0
  if [[ ! -e "$dir/$sha.started" ]]; then
    : > "$dir/$sha.started"
    main_red_launch "$sha" "$run" "$attempt"
    say "main red $sha run=$run attempt=$attempt: reproduction started"
  fi
  if [[ ! -s "$report" ]]; then
    # 超过 7 分钟还没有报告就按超时走原路径
    (( NOW_EPOCH - $(stat -c %Y "$dir/$sha.started" 2>/dev/null || echo 0) < 420 )) && MAIN_RED_PENDING=1
    return 0
  fi
  line="$(head -n 1 "$report")"
  [[ "$line" == culprit=* ]] || return 0
  culprit="${line#culprit=}"; culprit="${culprit%% *}"
  suite="${line#*suite=}"; suite="${suite%% *}"
  [[ "$culprit" =~ $SHA_RE ]] || return 0
  if ! revert_squash_merge "main-red-${sha:0:9}" "$culprit"; then
    : > "$dir/$sha.revert-failed"
    say "main red $sha: revert of $culprit failed (conflict or push race); current rerun path continues"
    return 0
  fi
  : > "$dir/$sha.reverted"; MAIN_RED_REVERTED=1
  gh workflow run pipeline-suites.yml --ref main >/dev/null 2>&1 || say "main red $sha: Pipeline suites dispatch on the revert failed"
  say "main red $sha: reverted $culprit (parent passes, candidate fails $suite)"
  echo "[$STAMP] MAIN-RED-REVERTED main=$sha culprit=$culprit suite=$suite run=$run" >> "$A/alerts/gate.md"
  uid="$(jqf -r --arg c "$culprit" 'first(.units[] | select((.land_sha // "") == $c) | .id) // empty' "$UNITS")"
  [[ -n "$uid" ]] || return 0
  set_unit "$uid" "$(hist main-red-reverted "$culprit reverted after $suite failed on main") | .main_red_reverted=$(js "$culprit") | .approved_sha=null | .repair_hint=$(js "你落地的提交 $culprit 让 main 的 Pipeline suites 失败（run $run attempt ${attempt}，suite ${suite}），已被自动回退：父提交通过、该提交失败。用 gh run view $run --attempt $attempt --log-failed 看失败，在你的分支上基于当前 origin/main 重新应用改动（回退的回退或 cherry-pick ${culprit}），先让 $suite 通过再落地。") | .stage=\"repair-pending\""
}

ci_classify_run() { # exact run metadata + failed-step logs; retry budget is deliberately separate
  local run="$1" expected_sha="$2" run_sha status conclusion failed_log judge_input judge_output judged_class
  CI_CLASS=unknown; CI_RUN_ID="$(jqf -r '.databaseId // empty' <<<"$run")"
  CI_RUN_ATTEMPT="$(jqf -r '.attempt | select(type=="number" and .>0 and floor==.)' <<<"$run")"
  run_sha="$(jqf -r '.headSha // empty' <<<"$run")"
  status="$(jqf -r '.status // empty' <<<"$run")"
  conclusion="$(jqf -r '.conclusion // empty' <<<"$run")"
  CI_REASON="Pipeline suites ${status:-missing}/${conclusion:-no-verdict} on $expected_sha"
  [[ "$run_sha" == "$expected_sha" && "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  [[ "$status" == completed ]] || return 0
  if [[ "$conclusion" == success ]]; then CI_CLASS=pass; return 0; fi
  # Cancelled, timed out, skipped and missing verdicts do not establish a regression.
  [[ "$conclusion" == failure && "$CI_RUN_ID" =~ ^[0-9]+$ ]] || return 0
  if [[ ! "$CI_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
    CI_REASON="$CI_REASON; run attempt unavailable, supervisor reconciliation required"
    return 0
  fi
  if ! failed_log="$(gh run view "$CI_RUN_ID" --attempt "$CI_RUN_ATTEMPT" --log-failed 2>/dev/null)"; then
    CI_REASON="$CI_REASON; failed logs unavailable"
    return 0
  fi
  CI_CLASS="$(printf '%s\n' "$failed_log" | python3 -c '
import re, sys
lines = sys.stdin.read().splitlines()
code = re.compile(r"FAILED suite=|\bnot ok \d+(?:\s|$)|(?:^|\s)(?-i:FAIL|FAILED)\s+\S|\b(?:AssertionError|SyntaxError|ReferenceError)\b|\berror TS\d+:|\b(?:Tests?|Suites?):[^\n]*\b[1-9]\d* failed\b|\b[1-9]\d* (?:tests?|suites?) (?:failed|failing)\b|\btest(?: case)? timed out", re.I)
network = re.compile(r"gnutls|curl: \((?:5|6|7|18|28|35|52|55|56|60)\)|could not resolve (?:host|proxy)|ECONNRESET|ETIMEDOUT|EAI_AGAIN|connection (?:reset|timed out)|failed to connect to|couldn.?t connect to|network is unreachable|TLS connection was non-properly terminated", re.I)
failed = re.compile(r"\b(?:fatal|error|failed|failure|exception)\b|timed out|##\[error\]", re.I)
wrapper = re.compile(r"(?:Error: )?Process completed with exit code \d+\.?$|The process .+ failed with exit code \d+\.?$", re.I)
suite_timeout = re.compile(r"FAILED suite=\S+.* timed out after \d+s\s*$", re.I)
if any(code.search(suite_timeout.sub("", line)) for line in lines):
    print("code")
elif any(network.search(line) or suite_timeout.search(line) for line in lines) and not any(failed.search(line) and not network.search(line) and not suite_timeout.search(line) and not wrapper.search(line) for line in lines):
    print("infra")
else:
    print("unknown")
')"
  [[ "$CI_CLASS" == infra || "$CI_CLASS" == code ]] || CI_CLASS=unknown
  judge_input="$(jqf -cn --arg event_id "ci:$CI_RUN_ID:$CI_RUN_ATTEMPT" \
    --arg current "$CI_CLASS" --arg sha "$expected_sha" \
    --arg failedLog "$(tail -c 12000 <<<"$failed_log")" \
    '{event_id:$event_id,currentDecision:$current,sha:$sha,failedLog:$failedLog}')"
  judge_output=""
  if [[ -n "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
    judge_output="$(printf '%s\n' "$judge_input" | bash "${ZF_ENGINE_DIR:-$ROOT/engine}/ts-judge.sh" ci-failure 2>/dev/null || true)"
  fi
  judged_class="$(jqf -r 'select(.status=="answered" and .adopted==true) | .decision // empty' <<<"$judge_output" 2>/dev/null || true)"
  case "$judged_class" in
    code|infra|flaky) CI_CLASS="$judged_class" ;;
  esac
}

ci_failure_retry_status() { # exact SHA, current run, existing reservation (null if unused)
  local sha="$1" run="$2" reserved="$3"
  CI_RETRY_ACTION=hold; CI_RETRY_RECORD=""
  if [[ ! "$CI_RUN_ID" =~ ^[0-9]+$ || ! "${CI_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] \
    || ! jqf -e --arg sha "$sha" '.headSha==$sha and .status=="completed" and .conclusion=="failure"' <<<"$run" >/dev/null; then
    CI_REASON="$CI_REASON; retry identity unavailable, supervisor reconciliation required"
    return 0
  fi
  if [[ "$reserved" == null ]]; then
    CI_RETRY_RECORD="$(jqf -cn --arg sha "$sha" --arg run "$CI_RUN_ID" --argjson attempt "$CI_RUN_ATTEMPT" --arg at "$STAMP" \
      '{sha:$sha,workflow:"Pipeline suites",run_id:$run,attempt:$attempt,requested_at:$at}')"
    CI_RETRY_ACTION=request
  elif jqf -e --arg sha "$sha" --arg run "$CI_RUN_ID" --argjson attempt "$CI_RUN_ATTEMPT" '
    type=="object" and .sha==$sha and .workflow=="Pipeline suites" and (.run_id|tostring)==$run
    and (.attempt | type=="number" and .>0 and floor==.) and .attempt < $attempt
  ' <<<"$reserved" >/dev/null 2>&1; then
    # Server evidence reconciles even an unconfirmed rerun request; polling the old red does not.
    CI_RETRY_ACTION=observed
    CI_REASON="$CI_REASON; later completed attempt $CI_RUN_ATTEMPT observed after the reserved rerun (1/1)"
  else
    CI_REASON="$CI_REASON; retry already reserved (1/1), no proven later attempt; supervisor reconciliation required"
  fi
}

# 失败只有 per-suite 超时、没有任何 not ok：CI 机负载导致（2026-10-20 land-queue.test.sh 在 492s 上限被杀，
# 把产品 PR #3859 白白回退）。按基础设施处理：重跑一次失败 job，不回退、不当代码裁决。
suites_timeout_only() { # log-failed text
  grep -qE 'FAILED suite=.* timed out after' <<<"$1" || return 1
  ! grep -qE 'not ok [0-9]+ -' <<<"$1" && ! grep -E 'FAILED suite=' <<<"$1" | grep -vq 'timed out after'
}

# 门禁候选：从 origin/main HEAD 往回，直到第一个非 [skip ci] 提交为止（含）。
# [skip ci] 提交通常没有 suites run（L7），但 land-direct-main 会为落地提交手动派发一次，有 run 就用它。
pipeline_path_re() { # pipeline-suites.yml 的 paths → 正则（** 任意，* 不跨目录）
  sed -n "/^  pull_request:/,/^  [a-z_]*:\$/p" "$ROOT/.github/workflows/pipeline-suites.yml" 2>/dev/null \
    | sed -nE "s/^ *- '([^']+)'.*/\\1/p" \
    | sed -E 's/[.]/\\./g; s/[*][*]/@@/g; s/[*]/[^\/]*/g; s/@@/.*/g; s/^/^/; s/$/$/' | paste -sd'|'
}
gate_eval_sha() {
  # 只看最新的「非 [skip ci]」提交会让流水线 PR 饿死：产品合并频繁，最新提交的套件总在排队（2026-10-20 #3857/#3862/#3868 等 4–15 小时）。
  # 产品提交不改流水线路径，旧提交的套件结论对它仍然成立：一直往前走，直到第一个改了流水线路径的非 [skip ci] 提交（含）。
  local sha re
  re="$(pipeline_path_re)"
  for sha in $(git -C "$ROOT" log -n 30 --format=%H refs/remotes/origin/main 2>/dev/null); do
    printf '%s\n' "$sha"
    git -C "$ROOT" log -1 --format=%B "$sha" | grep -qiE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]' && continue
    [[ -n "$re" ]] && ! git -C "$ROOT" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null | grep -qE "$re" && continue
    return 0
  done
}
main_suites_load() {
  [[ "$MAIN_SUITES_RUNS_LOADED" != true ]] || return 0
  MAIN_SUITES_RUNS_LOADED=true
  local query_seconds started=$SECONDS
  MAIN_SUITES_RUNS="$(gh run list --workflow "Pipeline suites" --branch main --limit 100 \
    --json conclusion,status,createdAt,headSha,databaseId,attempt 2>/dev/null)" || MAIN_SUITES_RUNS=""
  jqf -e 'type=="array"' <<<"$MAIN_SUITES_RUNS" >/dev/null || MAIN_SUITES_RUNS=""
  query_seconds=$((SECONDS - started))
  (( query_seconds < 2 )) || say "merge detail main_suites_query=${query_seconds}s"
}
suites_run_for() { # sha → 该提交最新一次 Pipeline suites run（JSON，无则空）
  main_suites_load
  [[ -n "$MAIN_SUITES_RUNS" ]] || return 0
  jqf --arg sha "$1" 'map(select(.headSha==$sha)) | sort_by(.createdAt) | last // empty' <<<"$MAIN_SUITES_RUNS"
}

gate_note() { # 门禁状态只在变化时写 alerts/gate.md，避免每拍刷屏触发 bell
  local last="$A/.gate-last"
  [[ "$(cat "$last" 2>/dev/null)" == "$1" ]] && return 0
  echo "[$STAMP] $1" >> "$A/alerts/gate.md"
  printf '%s\n' "$1" > "$last"
}

retry_blocked_units() { # BLOCK 只在 head 变了，或 main 已推进且该单元尚未因此重评过时重派
  local id pr head reviewed blocked_main retries
  while IFS=$'\t' read -r id pr reviewed blocked_main retries; do
    [[ -n "$id" && -n "$pr" ]] || continue
    head="$(pr_view "$pr" headRefOid)"
    [[ "$head" =~ $SHA_RE ]] || continue
    if [[ "$head" != "$reviewed" ]]; then
      set_unit "$id" "$(hist block-retry "head moved to $head") | .stage=\"rereview-pending\""
      say "blocked unit=$id head moved -> rereview-pending"
    elif [[ "$blocked_main" != "$MAIN_HEAD" ]] && (( retries < 1 )); then
      set_unit "$id" "$(hist block-retry "main moved to $MAIN_HEAD") | .stage=\"review-pending\" | .block_retries=$((retries+1))"
      say "blocked unit=$id main moved -> one fresh review"
    fi
  done < <(jqf -r '.units[] | select(.stage=="blocked-external" and .blocked_on == null and .size_recut_pending != true and ((.note // "") | contains("CONFLICTED") | not)) | [.id, (.pr // "" | tostring), (.reviewed_sha // ""), (.blocked_main_sha // ""), (.block_retries // 0 | tostring)] | @tsv' "$UNITS")
}
