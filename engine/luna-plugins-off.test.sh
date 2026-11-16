#!/usr/bin/env bash
# bin/luna disables plugins and isolates the worker from host context-mode MCP readiness.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$test_env_root/luna-plugins-off"
fake_bin="$root/bin"; mkdir -p "$fake_bin" "$root/scratch" "$root/host-sentinels"
fail() { printf 'luna-plugins-off.test.sh: %s\n' "$*" >&2; exit 1; }

# Fake codex: records its argv and worker sentinel directory, then checks the directory is empty.
cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
printf ' %s' "$@" > "$CODEX_ARGV_FILE"; printf '\n' >> "$CODEX_ARGV_FILE"
printf '%s\n' "${CONTEXT_MODE_MCP_SENTINEL_DIR:-}" > "$CODEX_CONTEXT_MODE_DIR_FILE"
[[ -n "${CONTEXT_MODE_MCP_SENTINEL_DIR:-}" && -d "$CONTEXT_MODE_MCP_SENTINEL_DIR" ]] || exit 81
[[ -z "$(ls -A "$CONTEXT_MODE_MCP_SENTINEL_DIR")" ]] || exit 82
SH
# Fake systemd-run: skips its own options and runs the command after `--`.
cat > "$fake_bin/systemd-run" <<'SH'
#!/usr/bin/env bash
while (($#)); do [[ "$1" == -- ]] && { shift; exec "$@"; }; shift; done
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/systemctl"
chmod +x "$fake_bin/codex" "$fake_bin/systemd-run" "$fake_bin/systemctl"
printf 'MemAvailable: 8000000 kB\n' > "$root/meminfo"
printf '999999999\n' > "$root/host-sentinels/context-mode-mcp-ready-host"
export CODEX_ARGV_FILE="$root/codex.argv" CODEX_CONTEXT_MODE_DIR_FILE="$root/codex.context-mode-dir"
export CONTEXT_MODE_MCP_SENTINEL_DIR="$root/host-sentinels"
export LUNA_PROC_MEMINFO="$root/meminfo" WORKER_SCRATCH_ROOT="$root/scratch" PATH="$fake_bin:$PATH"
printf 'Reply with one word.\n' > "$root/prompt.md"

rm -f "$CODEX_ARGV_FILE" "$CODEX_CONTEXT_MODE_DIR_FILE"
run_status=0
"$engine/bin/luna" k1 "$root" "$root/prompt.md" >/dev/null 2>&1 || run_status=$?
[[ "$run_status" -eq 0 ]] || fail "luna codex stub exited $run_status"
[[ -s "$CODEX_ARGV_FILE" ]] || fail "fake codex was never started"
grep -Fq ' -c features.plugins=false ' "$CODEX_ARGV_FILE" \
  || fail "luna codex argv lacks -c features.plugins=false: $(cat "$CODEX_ARGV_FILE")"
[[ -s "$CODEX_CONTEXT_MODE_DIR_FILE" ]] || fail "fake codex did not receive CONTEXT_MODE_MCP_SENTINEL_DIR"
worker_sentinel_dir="$(<"$CODEX_CONTEXT_MODE_DIR_FILE")"
[[ "$worker_sentinel_dir" == "$root/scratch/tmp/k1/context-mode-mcp-ready."* ]] \
  || fail "luna sentinel directory is outside its worker tmp: $worker_sentinel_dir"
[[ -d "$worker_sentinel_dir" && -z "$(ls -A "$worker_sentinel_dir")" ]] \
  || fail "luna sentinel directory is missing or not empty: $worker_sentinel_dir"
echo 'PASS bin/luna passes plugin-off args and an empty per-run context-mode sentinel directory'

context_mode_module="$test_host_home/.npm-global/lib/node_modules/context-mode/hooks/core/mcp-ready.mjs"
if command -v node >/dev/null 2>&1 && [[ -r "$context_mode_module" ]]; then
  CONTEXT_MODE_MODULE="$context_mode_module" CONTEXT_MODE_MCP_SENTINEL_DIR="$root/host-sentinels" node --input-type=module - <<'NODE'
import { pathToFileURL } from "node:url";
const { isMCPReady } = await import(pathToFileURL(process.env.CONTEXT_MODE_MODULE));
if (!isMCPReady()) throw new Error("fresh host sentinel was not detected");
NODE
  CONTEXT_MODE_MODULE="$context_mode_module" CONTEXT_MODE_MCP_SENTINEL_DIR="$worker_sentinel_dir" node --input-type=module - <<'NODE'
import { pathToFileURL } from "node:url";
const { isMCPReady } = await import(pathToFileURL(process.env.CONTEXT_MODE_MODULE));
if (isMCPReady()) throw new Error("worker detected a host context-mode sentinel");
NODE
  echo 'PASS context-mode isMCPReady ignores the host sentinel for the worker'
else
  echo 'SKIP context-mode isMCPReady integration: node or package unavailable'
fi
