#!/usr/bin/env bash
# rescued_gc.sh：已关闭 issue 的、无 issue 号且超龄的 rescued/* 先存档为 GitHub ref 再删并记日志；在途 issue 的、新的保留；查不到 issue 状态整轮不删。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "rescued_gc.test.sh: $*" >&2; exit 1; }
f="$test_env_root/rescued"; mkdir -p "$f/bin"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git init -q --bare "$f/origin.git"
git clone -q "$f/origin.git" "$f/repo" 2>/dev/null
old=1700000000 now=1800000000
for b in rescued/issue-10-x rescued/issue-20-y rescued/advisor-old rescued/advisor-new; do
  git -C "$f/repo" checkout -q --orphan "$b"
  echo "$b" > "$f/repo/f"; git -C "$f/repo" add f
  when=$old; [[ "$b" == rescued/advisor-new ]] && when=$((now - 3600))
  GIT_COMMITTER_DATE="@$when" GIT_AUTHOR_DATE="@$when" git -C "$f/repo" commit -q -m "$b"
  git -C "$f/repo" push -q origin "$b"
done
# 假 gh：#10 已关闭，#20 仍开；GH_FAIL=1 模拟 GitHub 查询失败
cat > "$f/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "${GH_FAIL:-0}" == 1 ]] && exit 1
case "$1 $2" in
  "repo view") echo owner/repo ;;
  "api graphql") echo i10 ;;
esac
EOF
chmod +x "$f/bin/gh"
heads() { git -C "$f/origin.git" for-each-ref --format='%(refname:short)' refs/heads/rescued/ | sort | tr '\n' ' '; }

GH_FAIL=1 PATH="$f/bin:$PATH" NOW_EPOCH=$now bash "$script_dir/rescued_gc.sh" "$f/repo" "$f/gc.log"
[[ "$(heads)" == 'rescued/advisor-new rescued/advisor-old rescued/issue-10-x rescued/issue-20-y ' ]] || fail "deleted without issue state: $(heads)"

out="$(PATH="$f/bin:$PATH" NOW_EPOCH=$now bash "$script_dir/rescued_gc.sh" "$f/repo" "$f/gc.log")"
[[ "$(heads)" == 'rescued/advisor-new rescued/issue-20-y ' ]] || fail "wrong survivors: $(heads)"
grep -q 'deleted rescued/issue-10-x .* reason=closed-issue-10' "$f/gc.log" || fail 'closed-issue deletion not logged'
grep -q 'deleted rescued/advisor-old .* reason=no-issue-older-14d' "$f/gc.log" || fail 'aged deletion not logged'
[[ "$out" == *'deleted 2 of 4'* ]] || fail "summary wrong: $out"
git -C "$f/origin.git" rev-parse -q --verify refs/vecta-rescue/archived/issue-10-x >/dev/null || fail 'deleted branch missing from the archive ref'
echo 'rescued_gc.test.sh: PASS'
