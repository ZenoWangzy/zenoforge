#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
export ZF_REPO=test/repo # test-env.sh unsets ZF_*; the revert issue needs a repo

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script="$script_dir/prompt-observer-compare.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
git init -q -b main "$repo"
git_commit() {
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$repo" -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m "$2"
}
git_commit 1970-01-01T00:08:20Z base # epoch 500
git_commit 1970-01-01T00:16:40Z 'prompt change' # epoch 1000
landing="$(git -C "$repo" rev-parse HEAD)"

# The upsert stub records each call instead of touching GitHub.
upsert_calls="$tmp/upsert-calls"
cat > "$tmp/upsert" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_UPSERT_CALLS"
cat "$6" >> "$TEST_UPSERT_CALLS"
STUB
chmod +x "$tmp/upsert"
export TEST_UPSERT_CALLS="$upsert_calls"

samples_of() {
  local file="$tmp/samples-$1.jsonl" before="$2" after="$3" i
  : > "$file"
  for i in 1 2 3 4 5; do printf '{"unit":"b%s","ts":%s,"score":%s}\n' "$i" "$((900 + i))" "$before" >> "$file"; done
  for i in 1 2 3 4 5; do printf '{"unit":"a%s","ts":%s,"score":%s}\n' "$i" "$((1000 + i * 10))" "$after" >> "$file"; done
  printf '%s\n' "$file"
}

run_compare() {
  PROMPT_OBSERVER_REPORT="$tmp/report.jsonl" PROMPT_OBSERVER_UPSERT="$tmp/upsert" \
    ZF_REPO_DIR="$repo" bash "$script" --prompt triage --landing "$landing" --samples "$1"
}

# improvement: recorded, no issue
improve="$(samples_of improve 0.4 0.8)"
out="$(run_compare "$improve")"
[[ "$out" == *'verdict=improvement'* ]]
[[ "$(jq -r .verdict "$tmp/report.jsonl")" == improvement ]]
[[ ! -e "$upsert_calls" ]]

# regression: one revert issue naming the commit and both scores
regress="$(samples_of regress 0.8 0.4)"
rm -f "$tmp/report.jsonl"
out="$(run_compare "$regress")"
[[ "$out" == *'verdict=regression'* ]]
grep -Fq -- "--class revert-triage-${landing:0:12}" "$upsert_calls"
grep -Fq 'before: n=5 mean=0.8' "$upsert_calls"
grep -Fq 'after: n=5 mean=0.4' "$upsert_calls"
grep -Fq "$landing" "$upsert_calls"
[[ "$(grep -c -- '--class' "$upsert_calls")" == 1 ]]
grep -Fq -- '--repo test/repo' "$upsert_calls"

# regression without ZF_REPO: refused before the upsert call, so no revert issue is filed
rm -f "$upsert_calls" "$tmp/report.jsonl"
set +e
env -u ZF_REPO PROMPT_OBSERVER_REPORT="$tmp/report.jsonl" PROMPT_OBSERVER_UPSERT="$tmp/upsert" \
  ZF_REPO_DIR="$repo" bash "$script" --prompt triage --landing "$landing" --samples "$regress" >/dev/null 2>&1
status=$?
set -e
[[ "$status" != 0 ]]
[[ ! -e "$upsert_calls" ]]

# insufficient data: too few known samples after landing, never a regression
thin="$tmp/thin.jsonl"
printf '{"unit":"b1","ts":950,"score":0.9}\n{"unit":"b2","ts":960,"score":0.9}\n{"unit":"b3","ts":970,"score":0.9}\n{"unit":"b4","ts":980,"score":0.9}\n{"unit":"b5","ts":990,"score":0.9}\n' > "$thin"
printf '{"unit":"a1","ts":1010,"score":0.1}\n{"unit":"a2","ts":1020,"score":0.1}\n' >> "$thin"
rm -f "$tmp/report.jsonl" "$upsert_calls"
out="$(run_compare "$thin")"
[[ "$out" == *'verdict=insufficient-data'* ]]
[[ ! -e "$upsert_calls" ]]

# unknown scores are not counted as failures: 3 nulls after landing leave only 2 known samples
unknown="$tmp/unknown.jsonl"
cp "$thin" "$unknown"
printf '{"unit":"a3","ts":1030,"score":null}\n{"unit":"a4","ts":1040,"score":null}\n{"unit":"a5","ts":1050,"score":null}\n' >> "$unknown"
out="$(run_compare "$unknown")"
[[ "$out" == *'verdict=insufficient-data'* ]]
[[ "$(tail -1 "$tmp/report.jsonl" | jq -r .after_n)" == 2 ]]

# a sample stamped exactly at the landing time is neither before nor after
exact="$tmp/exact.jsonl"
cp "$regress" "$exact"
printf '{"unit":"x","ts":1000,"score":0}\n' >> "$exact"
rm -f "$tmp/report.jsonl"
run_compare "$exact" >/dev/null
[[ "$(jq -r .before_n "$tmp/report.jsonl")" == 5 ]]
[[ "$(jq -r .after_n "$tmp/report.jsonl")" == 5 ]]

# unknown landing commit is refused before any record or issue
set +e
PROMPT_OBSERVER_REPORT="$tmp/report.jsonl" PROMPT_OBSERVER_UPSERT="$tmp/upsert" \
  ZF_REPO_DIR="$repo" bash "$script" --prompt triage --landing deadbeef --samples "$regress" >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 64 ]]
