#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
repo=$t/repo; unrelated=$t/unrelated; origin=$t/origin.git
mkdir "$repo" "$unrelated" "$t/bin"
git init --bare -q "$origin"
git init -q "$repo"
git -C "$repo" checkout -q -b main
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf mainblob > "$repo/a.py"
git -C "$repo" add a.py
git -C "$repo" commit -q -m main
git -C "$repo" remote add origin "$origin"
git -C "$repo" push -q -u origin main
git -C "$repo" checkout -q -b pr-7
printf prblob > "$repo/p.py"
git -C "$repo" add p.py
git -C "$repo" commit -q -m pr
pr_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q origin HEAD:refs/pull/7/head
git -C "$repo" checkout -q main
git -C "$repo" show "$pr_sha:p.py" > "$repo/p.py"
printf liveonly > "$repo/x.py"
export FIXTURE_REPO=$repo FIXTURE_PR_SHA=$pr_sha
cat > "$t/bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ -z ${GH_TOKEN+x} && $PWD == "$FIXTURE_REPO" ]] || exit 1
echo "7 $FIXTURE_PR_SHA"
STUB
chmod +x "$t/bin/gh"; export PATH="$t/bin:$PATH" GH_TOKEN=secret
main_blob=$(git -C "$repo" hash-object "$repo/a.py")
pr_blob=$(git -C "$repo" hash-object "$repo/p.py")
(
  cd "$unrelated"
  "$p/hf-source-check.sh" "$repo/a.py" "$repo/p.py"
) > "$t/ok"
grep -Fq "hf-source-check: ok $repo/a.py ($main_blob)" "$t/ok"
grep -Fq "hf-source-check: ok $repo/p.py ($pr_blob)" "$t/ok"
rc=0
(
  cd "$unrelated"
  "$p/hf-source-check.sh" "$repo/x.py"
) > "$t/refused.out" 2> "$t/refused.err" || rc=$?
[[ $rc == 1 ]]
grep -Fq "hf-source-check: REFUSED $repo/x.py (" "$t/refused.err"
