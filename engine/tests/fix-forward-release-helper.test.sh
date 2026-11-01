#!/usr/bin/env bash
set -euo pipefail

engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
repo="$test_root/repo"
bin="$test_root/bin"
mkdir -p "$repo/scripts/release" "$bin"

cat > "$repo/scripts/release/run-release.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$repo/scripts/release/release-drift-carried.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --contains-pr && "$2" == 123 ]]
printf '%s\n' "$0 $*" > "$FIX_FORWARD_HELPER_MARKER"
printf '{"unknown":false,"approved":true}\n'
SH
cat > "$bin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'fixture registry rows\n'
SH
chmod +x "$repo/scripts/release/run-release.sh" "$repo/scripts/release/release-drift-carried.sh" "$bin/ssh"

_AGENT_LIB_DIR="$engine_dir"
source "$engine_dir/lib.d/fix-forward.sh"
ZF_REPO_DIR="$repo"
DEPLOY_HOST=fixture
DEPLOY_DIR="$test_root/deploy"
ZF_DEPLOY_DIR="$test_root/deploy"
FIX_FORWARD_HELPER_MARKER="$test_root/helper-called"
PATH="$bin:$PATH"
export ZF_REPO_DIR DEPLOY_HOST DEPLOY_DIR ZF_DEPLOY_DIR FIX_FORWARD_HELPER_MARKER PATH

zf_release_runner() {
  printf '%s\n' "$ZF_REPO_DIR/scripts/release/run-release.sh"
}

main_fix_forward_carried_pr_registered 123
[[ -f "$FIX_FORWARD_HELPER_MARKER" ]]
grep -Fq "$repo/scripts/release/release-drift-carried.sh --contains-pr 123" "$FIX_FORWARD_HELPER_MARKER"
printf '%s\n' 'fix-forward release helper dispatch passed'
