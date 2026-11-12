#!/usr/bin/env bash
# bin/luna starts codex with -c features.plugins=false (CODEX_PLUGINS_OFF_ARGS; upstream openai/codex#47483).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$test_env_root/luna-plugins-off"
fake_bin="$root/bin"; mkdir -p "$fake_bin" "$root/scratch"
fail() { printf 'luna-plugins-off.test.sh: %s\n' "$*" >&2; exit 1; }

# Fake codex: records its argv on one line and succeeds.
cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
printf ' %s' "$@" > "$CODEX_ARGV_FILE"; printf '\n' >> "$CODEX_ARGV_FILE"
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
export CODEX_ARGV_FILE="$root/codex.argv" LUNA_PROC_MEMINFO="$root/meminfo" WORKER_SCRATCH_ROOT="$root/scratch" PATH="$fake_bin:$PATH"
printf 'Reply with one word.\n' > "$root/prompt.md"

rm -f "$CODEX_ARGV_FILE"
"$engine/bin/luna" k1 "$root" "$root/prompt.md" >/dev/null 2>&1 || true
[[ -s "$CODEX_ARGV_FILE" ]] || fail "fake codex was never started"
grep -Fq ' -c features.plugins=false ' "$CODEX_ARGV_FILE" \
  || fail "luna codex argv lacks -c features.plugins=false: $(cat "$CODEX_ARGV_FILE")"
echo "PASS bin/luna passes -c features.plugins=false"
