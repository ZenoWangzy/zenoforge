#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { echo "caps.test.sh: $*" >&2; exit 1; }
t="$test_env_root/caps"
mkdir -p "$t/bin" "$t/status"
for tool in codex gh; do printf '#!/bin/sh\nexit 0\n' > "$t/bin/$tool"; chmod +x "$t/bin/$tool"; done
printf 'Linux version 6.6.0-microsoft-standard-WSL2 (gcc)\n' > "$t/wsl-version"
printf 'Linux version 6.6.0 (gcc)\n' > "$t/native-version"
printf 'MemTotal:       32768000 kB\n' > "$t/meminfo"

# run_caps <ZF_OS> <proc version file>: detect with codex and gh stubbed, zf-absent-cli never installed.
run_caps() {
  PATH="$t/bin:$PATH" ZF_OS="$1" ZF_PROC_VERSION_FILE="$2" ZF_MEMINFO_FILE="$t/meminfo" \
    ZF_CAPS_CLI='codex zf-absent-cli gh' bash "$engine/coord/caps.sh"
}

out=$(run_caps linux "$t/wsl-version")
jq -e '.os == "linux" and .wsl == true and .cli.codex == "ok" and .cli.gh == "ok"
  and .cli["zf-absent-cli"] == "missing" and .mem_mb == 32000 and (.cpus | type == "number")' <<<"$out" >/dev/null \
  || fail "linux WSL2 detection wrong: $out"

out=$(run_caps linux "$t/native-version")
jq -e '.wsl == false' <<<"$out" >/dev/null || fail "native Linux reported as WSL: $out"

out=$(run_caps darwin "$t/native-version")
jq -e '.os == "darwin" and .wsl == false' <<<"$out" >/dev/null || fail "darwin detection wrong: $out"

source "$engine/coord/status.sh"
caps_a='{"os":"linux","arch":"x86_64","wsl":true,"cpus":12,"mem_mb":32000,"cli":{"codex":"ok","claude":"missing","gh":"ok"}}'
caps_b='{"os":"darwin","arch":"arm64","wsl":false,"cpus":8,"mem_mb":16384,"cli":{"codex":"missing","claude":"ok","gh":"ok"}}'
status_record host-b 4b7d02 2026-11-12T10:00:30Z "$caps_b" > "$t/status/host-b.json"
status_record host-a 9f2c1e 2026-11-12T10:00:00Z "$caps_a" > "$t/status/host-a.json"
jq -e '.proto == 1 and .draining == false and .caps.os == "linux"' "$t/status/host-a.json" >/dev/null \
  || fail "status record schema wrong"

want=$(cat <<'EOF'
HOST       INSTANCE   OS      ARCH     CPUS   MEM_MB HEARTBEAT            CLI
host-a     9f2c1e     linux   x86_64     12    32000 2026-11-12T10:00:00Z codex,gh
host-b     4b7d02     darwin  arm64       8    16384 2026-11-12T10:00:30Z claude,gh
EOF
)
got=$(status_show "$t/status")
[[ "$got" == "$want" ]] || fail "status show differs from golden output:"$'\n'"$got"

bash "$engine/coord/status.sh" show "$t/status" >/dev/null || fail "status.sh show entry point failed"
echo 'caps.test.sh: ok'
