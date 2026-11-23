#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_dir="$(cd -- "$engine_dir/.." && pwd -P)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root" "$test_env_root"' EXIT
cat > "$test_root/real-gh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$test_root/real-gh"
export ZF_ENGINE_DIR="$engine_dir" ZF_REPO_DIR="$repo_dir"
export ZF_GH_REAL="$test_root/real-gh" ZF_GH_MEASURE_FILE="$test_root/calls.tsv"
export PATH="$engine_dir/gh-measure/bin:$PATH"
source "$engine_dir/lib.d/transport.sh"

call_line=$((LINENO + 1))
main_gh api repos/example/repo/issues
[[ "$(wc -l < "$ZF_GH_MEASURE_FILE" | tr -d ' ')" == 1 ]]
[[ "$(cut -f3 "$ZF_GH_MEASURE_FILE")" == "engine/gh-measure/gh-attribution.test.sh:$call_line" ]]
echo 'gh-attribution.test.sh: PASS'
