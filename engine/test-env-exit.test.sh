#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/home"
cat > "$fixture/probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PRIOR:-0}" == 1 ]]; then trap 'printf ran > "$MARK"' EXIT; fi
source "$PROBE_ENGINE/test-env.sh"
printf '%s\n' "$test_env_root" > "$ROOT_FILE"
EOF
for prior in 0 1; do
  rm -f "$fixture/root" "$fixture/mark"
  HOME="$fixture/home" PRIOR="$prior" MARK="$fixture/mark" ROOT_FILE="$fixture/root" PROBE_ENGINE="$engine" bash "$fixture/probe.sh"
  root="$(cat "$fixture/root")"
  [[ "$root" == "$fixture/home/.cache/zenoforge-agent-test/zenoforge-agent-test-"* ]] || { echo "test-env-exit.test.sh: unexpected root $root" >&2; exit 1; }
  [[ ! -e "$root" ]] || { echo "test-env-exit.test.sh: root survived exit (prior=$prior): $root" >&2; exit 1; }
  if [[ "$prior" == 1 ]]; then
    [[ "$(cat "$fixture/mark" 2>/dev/null)" == ran ]] || { echo 'test-env-exit.test.sh: caller EXIT trap did not run' >&2; exit 1; }
  fi
done
echo 'PASS test-env removes its root on exit and still runs a caller EXIT trap set before it'
