#!/usr/bin/env bash
# batch-state.test.sh -- 批次 STATE（#4363）：父票正文里的 zf-batch-state 块
# 解析成延迟成本带宽，sweep 把它同步成 critical-path / legacy 标签；队列排序按
# 生产事故 > 关键路径 > 功能 > 遗留消费这些标签（排序契约在 queue-order.test.sh）。
set -euo pipefail
source "$(cd -- "$(dirname "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ZF_REPO=test/repo
export ZF_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
export AGENT_DRY_RUN=0
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
source "$SCRIPT_DIR/lib.sh"

FAILED=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected to find [$needle])" >&2
    FAILED=1
  fi
}

# --- 纯解析：batch_state_band_map ---------------------------------------------
# critical_path 成员与 delay_cost=critical 进关键路径；feature/legacy 按值；
# 标记存在但解析不出 JSON 的父票以 invalid-parent 行上报，不产出带宽。
bands="$(batch_state_band_map '[
  {"number":500,"body":"spec\n<!-- zf-batch-state\n{\"completion\":\"all merged\",\"critical_path\":[501,502],\"delay_cost\":{\"503\":\"feature\",\"504\":\"legacy\"}}\n-->","labels":[]},
  {"number":501,"body":"child","labels":[]},
  {"number":505,"body":"<!-- zf-batch-state\n{no closing brace\n-->","labels":[]},
  {"number":9099,"body":"PR row","pull_request":{"url":"x"},"labels":[]}
]')"
assert_eq "band map derives delay-cost bands from the parent STATE" \
  $'invalid-parent:505\n501\tcritical\n502\tcritical\n503\tfeature\n504\tlegacy' "$bands"

# --- sweep：STATE → 标签同步 ---------------------------------------------------
FAKE_GH_ROOT="$test_env_root/gh"
FAKE_GH_LOG="$test_env_root/gh.log"
export FAKE_GH_ROOT FAKE_GH_LOG
: > "$FAKE_GH_LOG"
mkdir -p "$FAKE_GH_ROOT/issues" "$AGENT_HOME/state"
issue_file() { printf '%s\n' "$1" > "$FAKE_GH_ROOT/issues/$2.json"; }
issue_file '{"number":500,"state":"open","body":"spec\n<!-- zf-batch-state\n{\"completion\":\"all merged\",\"critical_path\":[501,502],\"delay_cost\":{\"503\":\"feature\",\"506\":\"legacy\"}}\n-->","labels":[]}' 500
issue_file '{"number":501,"state":"open","body":"needs both labels fixed","labels":[]}' 501
issue_file '{"number":502,"state":"open","body":"stale legacy band","labels":[{"name":"legacy"}]}' 502
issue_file '{"number":503,"state":"open","body":"downgraded to feature","labels":[{"name":"critical-path"}]}' 503
issue_file '{"number":504,"state":"open","body":"not in any STATE","labels":[{"name":"legacy"}]}' 504
issue_file '{"number":505,"state":"open","body":"<!-- zf-batch-state\n{no closing brace\n-->","labels":[]}' 505
# 506 is graded legacy by the STATE but closed; the sweep only reads open issues.
issue_file '{"number":506,"state":"closed","body":"done long ago","labels":[]}' 506

cat > "$test_env_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"; subcommand="${2:-}"; shift 2 || true
case "$command:$subcommand" in
  api:*)
    # lib.sh 的 gh() 重试包装把 flag 放在 endpoint 前面：api --paginate --slurp <path>。
    endpoint=""
    for arg in "$@"; do
      case "$arg" in --*) ;; *) endpoint="$arg"; break ;; esac
    done
    case "$endpoint" in
      repos/*issues*)
        if [ "${FAKE_PAGES_FAILURE:-0}" = 1 ]; then
          echo "fixture issue snapshot failure" >&2; exit 1
        fi
        printf 'api\n' >> "$FAKE_GH_LOG"
        jq -s '[ [.[] | select(.state == "open")] ]' "$FAKE_GH_ROOT"/issues/*.json
        ;;
      *) echo "unexpected fake gh API call: $endpoint $*" >&2; exit 64 ;;
    esac
    ;;
  label:list) printf 'legacy\n' ;;
  label:create)
    printf 'label create %s\n' "$1" >> "$FAKE_GH_LOG"
    [ "${FAKE_LABEL_CREATE_FAILURE:-0}" != 1 ]
    ;;
  issue:edit)
    number="${1:-}"; shift
    printf 'issue edit %s %s\n' "$number" "$*" >> "$FAKE_GH_LOG"
    file="$FAKE_GH_ROOT/issues/$number.json"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --add-label)
          jq --arg l "$2" '.labels = ((.labels // []) + [{"name":$l}] | unique_by(.name))' "$file" > "$file.tmp" && mv "$file.tmp" "$file"; shift 2 ;;
        --remove-label)
          jq --arg l "$2" '.labels = ((.labels // []) | map(select(.name != $l)))' "$file" > "$file.tmp" && mv "$file.tmp" "$file"; shift 2 ;;
        *) shift ;;
      esac
    done
    ;;
  *) echo "unexpected fake gh call: $command $subcommand $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$test_env_bin/gh"

# 列表失败：rc 1，不写节流纪元，下个 tick 重试。
export FAKE_PAGES_FAILURE=1
if sweep_batch_state 2>/dev/null; then
  assert_eq "failed listing fails the sweep" "rc1" "rc0"
else
  echo "ok - failed listing fails the sweep"
fi
[ -f "$AGENT_HOME/state/batch-state.epoch" ] \
  && { echo "not ok - epoch must not be written on failure"; FAILED=1; } \
  || echo "ok - epoch must not be written on failure"
export FAKE_PAGES_FAILURE=0

sweep_batch_state 2>"$test_env_root/sweep.err"
edits="$(grep -c '^issue edit' "$FAKE_GH_LOG" || true)"
assert_eq "one edit per open STATE child whose band changed" "3" "$edits"
assert_contains "child on the critical path gains the label" "$(cat "$FAKE_GH_LOG")" "issue edit 501 --repo test/repo --add-label critical-path"
assert_contains "stale legacy band is swapped for critical-path" "$(cat "$FAKE_GH_LOG")" "issue edit 502 --repo test/repo --add-label critical-path --remove-label legacy"
assert_contains "downgraded child loses critical-path" "$(cat "$FAKE_GH_LOG")" "issue edit 503 --repo test/repo --remove-label critical-path"
[ "$(grep -c 'issue edit 504' "$FAKE_GH_LOG")" = 0 ] \
  && echo "ok - tickets outside every STATE keep their labels" \
  || { echo "not ok - tickets outside every STATE keep their labels"; FAILED=1; }
[ "$(grep -c 'issue edit 506' "$FAKE_GH_LOG")" = 0 ] \
  && echo "ok - closed children are never edited" \
  || { echo "not ok - closed children are never edited"; FAILED=1; }
assert_contains "missing band labels are created once" "$(cat "$FAKE_GH_LOG")" "label create critical-path"
assert_contains "invalid parent is reported and skipped" "$(cat "$test_env_root/sweep.err")" "505 carries an unparseable batch STATE"

# 幂等：标签已同步后重跑（去掉节流）不再编辑。
: > "$FAKE_GH_LOG"
rm -f "$AGENT_HOME/state/batch-state.epoch"
sweep_batch_state 2>/dev/null
[ "$(grep -c '^issue edit' "$FAKE_GH_LOG")" = 0 ] \
  && echo "ok - an in-sync STATE produces no edits" \
  || { echo "not ok - an in-sync STATE produces no edits ($(grep '^issue edit' "$FAKE_GH_LOG"))"; FAILED=1; }

# 节流：成功后一小时内不再发列表请求。
api_calls="$(grep -c '^api' "$FAKE_GH_LOG" || true)"
sweep_batch_state 2>/dev/null
assert_eq "throttle suppresses the hourly re-list" "$api_calls" "$(grep -c '^api' "$FAKE_GH_LOG" || true)"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASSED"
else
  echo "FAILURES"
  exit 1
fi
