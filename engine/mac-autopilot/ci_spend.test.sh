#!/usr/bin/env bash
# ci_spend.py：CI runner 时间里改变不了结论的部分——被取消的 job、未获批即被取代的 PR head、[skip ci] 提交上的产品 Postsubmit（L64/L65）。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "ci_spend.test.sh: $*" >&2; exit 1; }
a="$test_env_root/ci-spend"; mkdir -p "$a"
A1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; A2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
B1=cccccccccccccccccccccccccccccccccccccccc; B2=dddddddddddddddddddddddddddddddddddddddd
echo "{\"units\":[{\"id\":\"pr-2\",\"history\":[{\"stage\":\"review-approve\",\"result\":\"$B1\"}]}]}" > "$a/units.json"
job() { printf '{"conclusion":"%s","started_at":"2026-10-21T10:00:00Z","completed_at":"2026-10-21T10:%s:00Z","runner_name":"%s"}' "$1" "$2" "${3-r1}"; }
run() { printf '{"id":%s,"name":"%s","event":"%s","head_branch":"%s","head_sha":"%s","status":"completed","created_at":"2026-10-21T%s:00Z","head_commit":{"message":"%s"}}' "$@"; }
cat > "$a/fixture.json" <<JSON
{"runs":[
 $(run 1 CI pull_request agent/a "$A1" 10:00 "feat: a"),
 $(run 2 CI pull_request agent/a "$A2" 11:00 "fix: a"),
 $(run 3 CI pull_request agent/b "$B1" 10:00 "feat: b"),
 $(run 4 CI pull_request agent/b "$B2" 11:00 "fix: b"),
 $(run 5 CI workflow_dispatch main "$A2" 11:30 "[skip ci] fix(agent): x"),
 $(run 6 CI push main "$B2" 11:40 "feat: merged")],
 "prs":[{"number":2,"additions":700,"deletions":200},{"number":3,"additions":10,"deletions":5}],
 "jobs":{
  "1":[$(job success 10)],
  "2":[$(job success 20),$(job cancelled 05),$(job cancelled 30 "")],
  "3":[$(job failure 08)],
  "4":[$(job success 12)],
  "5":[$(job success 32)],
  "6":[$(job success 40)]}}
JSON
out="$(python3 "$script_dir/ci_spend.py" --runtime "$a" --hours 5 --now 2026-10-21T12:00:00Z --fixture "$a/fixture.json")"
# 总计 10+25+8+12+32+40=127（无 runner 的排队取消不计）；浪费：run1 被取代且未获批 10、run2 取消 5、run5 非产品 Postsubmit 32；
# run3 被取代但获批过（B1），不算浪费。
got="$(jq -c '[.total_min, .waste_min, .by_reason.superseded_unapproved, .by_reason.cancelled, .by_reason.nonproduct_postsubmit]' "$a/ci-spend.json")"
[[ "$got" == '[127,47,10,5,32]' ]] || fail "classification wrong: $got ($out)"
[[ "$(jq -r .waste_pct "$a/ci-spend.json")" == 37.0 ]] || fail "waste share wrong: $(jq -r .waste_pct "$a/ci-spend.json")"
# 已完成 run 的 job 分钟进缓存，下一次采样不再取
jq -e 'has("1") and has("6")' "$a/ci-spend-cache.json" >/dev/null || fail 'completed runs not cached'
jq '.jobs = {}' "$a/fixture.json" > "$a/fixture2.json"
python3 "$script_dir/ci_spend.py" --runtime "$a" --hours 5 --now 2026-10-21T12:00:00Z --fixture "$a/fixture2.json" >/dev/null
[[ "$(jq -r .total_min "$a/ci-spend.json")" == 127 ]] || fail 'cached job minutes not reused'
jq -e '.lines == {"2":900,"3":15}' "$a/pr-sizes.json" >/dev/null || fail "PR sizes not written: $(cat "$a/pr-sizes.json" 2>/dev/null)"

# The previous 500-PR census omitted 41 active-window ledger PRs in #4482.
# A real sampling run queries ledger PRs, refreshes open heads, and reuses
# immutable merged sizes; a failed query leaves the missing size visible.
cat > "$a/units.json" <<'JSON'
{"units":[
 {"id":"pr-201","pr":201,"stage":"merged","history":[{"stage":"merged","at":"2026-10-20T12:00:00Z"}]},
 {"id":"pr-202","pr":202,"stage":"review-pending","history":[]},
 {"id":"pr-203","pr":203,"stage":"merged","history":[{"stage":"merged","at":"2026-10-20T12:00:00Z"}]},
 {"id":"pr-204","pr":204,"stage":"merged","history":[{"stage":"merged","at":"2026-08-01T12:00:00Z"}]}
]}
JSON
echo '{"lines":{"201":400},"states":{"201":"MERGED"}}' > "$a/pr-sizes.json"
echo '{"202":{"additions":400,"deletions":401,"state":"OPEN"},"203":{"additions":200,"deletions":300,"state":"MERGED"}}' > "$a/pr-data.json"
cat > "$a/gh-real" <<'PY'
#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
root = Path(os.environ["SIZE_TEST_ROOT"])
args = sys.argv[1:]
if args[:3] == ["api", "--paginate", "--slurp"]:
    print(json.dumps([{"workflow_runs": []}]))
elif args[:2] == ["api", "graphql"]:
    numbers = re.findall(r"p(\d+):pullRequest\(number:\d+\)", " ".join(args))
    with (root / "queries.log").open("a") as out:
        out.write(",".join(numbers) + "\n")
    if (root / "query-failed").exists():
        sys.exit(1)
    data = json.loads((root / "pr-data.json").read_text())
    print(json.dumps({"data": {"repository": {"p" + n: data.get(n) for n in numbers}}}))
else:
    print("[]")
PY
chmod +x "$a/gh-real"
export SIZE_TEST_ROOT="$a" ZF_GH_REAL_CLI="$a/gh-real"
export PATH="$script_dir/../gh-shim:$PATH"
python3 "$script_dir/ci_spend.py" --runtime "$a" --hours 5 --now 2026-10-21T12:00:00Z >/dev/null
jq -e '.lines == {"201":400,"202":801,"203":500} and .states == {"201":"MERGED","202":"OPEN","203":"MERGED"}' "$a/pr-sizes.json" >/dev/null \
  || fail 'ledger PR batch omitted sizes, deletions, or the undated active PR'
[[ "$(cat "$a/queries.log")" == '202,203' ]] || fail 'merged PR cache was not reused or stale PR was fetched'
echo '{"202":{"additions":50,"deletions":50,"state":"OPEN"},"203":{"additions":999,"deletions":999,"state":"MERGED"}}' > "$a/pr-data.json"
python3 "$script_dir/ci_spend.py" --runtime "$a" --hours 5 --now 2026-10-21T12:30:00Z >/dev/null
jq -e '.lines == {"201":400,"202":100,"203":500}' "$a/pr-sizes.json" >/dev/null \
  || fail 'open PR size was not refreshed or merged size was not reused'
[[ "$(tail -1 "$a/queries.log")" == '202' ]] || fail 'the second sample fetched immutable PR sizes again'
touch "$a/query-failed"
python3 "$script_dir/ci_spend.py" --runtime "$a" --hours 5 --now 2026-10-21T13:00:00Z >/dev/null
jq -e '(.lines | has("202") | not) and .lines["201"] == 400 and .lines["203"] == 500' "$a/pr-sizes.json" >/dev/null \
  || fail 'a failed size query reused an unverified open PR size'
echo 'ci_spend.test.sh: PASS'
