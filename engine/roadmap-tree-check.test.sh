#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$test_env_root/roadmap-tree-check"
rm -rf -- "$tmp"
mkdir -p "$tmp/repo" "$tmp/bin"
git -C "$tmp/repo" init -q
git -C "$tmp/repo" config user.name fixture
git -C "$tmp/repo" config user.email fixture@example.invalid
git -C "$tmp/repo" commit --allow-empty -qm base
branch_before="$(git -C "$tmp/repo" branch --show-current)"
base_sha="$(git -C "$tmp/repo" rev-parse HEAD)"
git -C "$tmp/repo" commit --allow-empty -qm live
live_sha="$(git -C "$tmp/repo" rev-parse HEAD)"
git -C "$tmp/repo" switch --orphan outside >/dev/null 2>&1
git -C "$tmp/repo" commit --allow-empty -qm outside
outside_sha="$(git -C "$tmp/repo" rev-parse HEAD)"
git -C "$tmp/repo" switch "$branch_before" >/dev/null 2>&1
printf '#!/bin/sh\nexit 90\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"
export PATH

fail() { printf 'roadmap-tree-check.test.sh: %s\n' "$*" >&2; exit 1; }
fixture() { mkdir -p "$tmp/$1/comments"; }
run_check() {
  local name="$1"
  check_out="$tmp/$name.out"
  check_err="$tmp/$name.err"
  check_rc=0
  python3 "$here/roadmap-tree-check.py" --repo fixture/repo --git-dir "$tmp/repo" \
    --live-sha "$live_sha" --fixture "$tmp/$name" >"$check_out" 2>"$check_err" || check_rc=$?
}
has_line() { grep -Fxq -- "$1" "$check_out" || fail "missing output line [$1]: $(cat "$check_out")"; }
has_no_line() { ! grep -Fq -- "$1" "$check_out" || fail "unexpected output line [$1]: $(cat "$check_out")"; }
has_rc() { [[ "$check_rc" == "$1" ]] || fail "expected rc=$1, got rc=$check_rc; stdout=$(cat "$check_out"); stderr=$(cat "$check_err")"; }

fixture no-parent
jq -n '[
  {number:1,title:"Roadmap",body:"## Why\nProject intent.",state:"CLOSED",labels:["roadmap"],parent:null},
  {number:2,title:"Orphan",body:"",state:"CLOSED",labels:[],parent:null}
]' > "$tmp/no-parent/issues.json"
printf '[]\n' > "$tmp/no-parent/pull-requests.json"
run_check no-parent
has_rc 1
has_line 'NO-PARENT #2: Orphan'
has_line 'roadmap-tree-check: findings=1'

fixture no-why
jq -n '[
  {number:1,title:"Roadmap",body:"",state:"CLOSED",labels:["roadmap"],parent:null},
  {number:2,title:"Needs context",body:"No heading here.",state:"OPEN",labels:[],parent:{number:1}}
]' > "$tmp/no-why/issues.json"
printf '[]\n' > "$tmp/no-why/pull-requests.json"
run_check no-why
has_rc 1
has_line 'NO-WHY #2: Needs context'
has_line 'roadmap-tree-check: findings=1'

fixture near-limit
jq -n '[
  {number:1,title:"Roadmap",body:"## Why\nProject intent.",state:"CLOSED",labels:["roadmap"],parent:null},
  {number:2,title:"Large parent",body:"",state:"CLOSED",labels:["roadmap-epic"],parent:{number:1}},
  (range(1000;1097) as $n | {number:$n,title:("Child " + ($n|tostring)),body:"",state:"CLOSED",labels:[],parent:{number:2}})
]' > "$tmp/near-limit/issues.json"
printf '[]\n' > "$tmp/near-limit/pull-requests.json"
run_check near-limit
has_rc 1
has_line 'NEAR-LIMIT #2: 97 direct sub-issues'
has_line 'roadmap-tree-check: findings=1'

fixture clean
jq -n '[
  {number:1,title:"Roadmap",body:"Why\n---\nProject intent.",state:"OPEN",labels:["roadmap"],parent:null},
  {number:2,title:"Theme",body:"## Problem\nA problem.",state:"OPEN",labels:["roadmap-theme"],parent:{number:1}},
  {number:3,title:"Leaf",body:"No local why.",state:"OPEN",labels:[],parent:{number:2}}
]' > "$tmp/clean/issues.json"
printf '[]\n' > "$tmp/clean/pull-requests.json"
run_check clean
has_rc 0
has_line 'roadmap-tree-check: findings=0'
[[ ! -s "$check_out" || "$(cat "$check_out")" == 'roadmap-tree-check: findings=0' ]] \
  || fail "clean tree printed a finding: $(cat "$check_out")"

fixture state
jq -n --arg base "$base_sha" --arg live "$live_sha" --arg outside "$outside_sha" '[
  {number:1,title:"Roadmap",body:"## Why\nProject intent.",state:"CLOSED",labels:["roadmap"],parent:null},
  {number:10,title:"Reverted delivery",body:"",state:"OPEN",labels:[],parent:{number:1}},
  {number:11,title:"Re-landed delivery",body:"",state:"OPEN",labels:[],parent:{number:1}},
  {number:12,title:"Open work",body:"",state:"OPEN",labels:[],parent:{number:1}},
  {number:13,title:"Commented work",body:"",state:"OPEN",labels:[],parent:{number:1}},
  {number:14,title:"Not live",body:"",state:"OPEN",labels:[],parent:{number:1}},
  {number:15,title:"Roadmap container",body:"",state:"OPEN",labels:["roadmap-theme"],parent:{number:1}},
  {number:17,title:"Parent with open child",body:"",state:"OPEN",labels:[],parent:{number:1}},
  {number:18,title:"Open child",body:"",state:"OPEN",labels:[],parent:{number:17}}
]' > "$tmp/state/issues.json"
jq -n --arg base "$base_sha" --arg live "$live_sha" --arg outside "$outside_sha" '[
  {number:100,title:"Change thing (#10)",body:"",state:"MERGED",mergedAt:"2026-11-01T00:00:00Z",mergeCommit:{oid:$base}},
  {number:101,title:"Revert \"Change thing (#100)\"",body:"",state:"MERGED",mergedAt:"2026-11-02T00:00:00Z",mergeCommit:{oid:$live}},
  {number:102,title:"Reland delivery",body:"Refs #11",state:"MERGED",mergedAt:"2026-11-03T00:00:00Z",mergeCommit:{oid:$live}},
  {number:103,title:"Delivered open work",body:"Fixes #12",state:"MERGED",mergedAt:"2026-11-04T00:00:00Z",mergeCommit:{oid:$base}},
  {number:104,title:"In progress",body:"Refs #12",state:"OPEN",mergedAt:null,mergeCommit:null},
  {number:105,title:"Delivered then discussed",body:"Closes #13",state:"MERGED",mergedAt:"2026-11-05T00:00:00Z",mergeCommit:{oid:$base}},
  {number:106,title:"Not live yet",body:"Refs #14",state:"MERGED",mergedAt:"2026-11-05T00:00:00Z",mergeCommit:{oid:$outside}},
  {number:107,title:"Roadmap container PR",body:"Refs #15",state:"MERGED",mergedAt:"2026-11-05T00:00:00Z",mergeCommit:{oid:$base}},
  {number:108,title:"Parent with open child PR",body:"Refs #17",state:"MERGED",mergedAt:"2026-11-05T00:00:00Z",mergeCommit:{oid:$base}}
]' > "$tmp/state/pull-requests.json"
printf '[]\n' > "$tmp/state/comments/10.json"
printf '[]\n' > "$tmp/state/comments/11.json"
printf '[{"created_at":"2026-11-06T00:00:00Z"}]\n' > "$tmp/state/comments/13.json"
run_check state
has_rc 1
has_line 'STATE-BEHIND #11: Re-landed delivery'
has_no_line 'STATE-BEHIND #10:'
has_no_line 'STATE-BEHIND #12:'
has_no_line 'STATE-BEHIND #13:'
has_no_line 'STATE-BEHIND #14:'
has_no_line 'STATE-BEHIND #15:'
has_no_line 'STATE-BEHIND #17:'
has_line 'roadmap-tree-check: findings=1'

fixture failed-read
printf '{"broken":\n' > "$tmp/failed-read/issues.json"
run_check failed-read
has_rc 2
[[ ! -s "$check_out" ]] || fail "failed read printed findings: $(cat "$check_out")"
grep -Fq 'roadmap-tree-check: read failed' "$check_err" || fail "failed read was not reported: $(cat "$check_err")"

printf 'roadmap-tree-check.test.sh: PASS\n'
