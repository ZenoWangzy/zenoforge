#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture_root="$ZF_AGENT_TEST_ROOT/land-agent-home"
fixture_repo="$fixture_root/repo"
fixture_engine="$fixture_root/published/engine"
fixture_home="$fixture_root/deployed-home"
explicit_home="$fixture_root/explicit-home"
fake_live="$fixture_root/fake-live"
trap 'rm -rf -- "$fixture_root"' EXIT

fail() {
  printf 'land-agent-home.test.sh: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$fixture_repo" "$fixture_engine" "$fixture_home" "$explicit_home" "$fake_live"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" checkout -q -b land-agent-home-test
git -C "$fixture_repo" config user.name 'land-agent-home fixture'
git -C "$fixture_repo" config user.email 'land-agent-home@example.invalid'
printf 'fixture repository\n' > "$fixture_repo/README.md"
git -C "$fixture_repo" add README.md
git -C "$fixture_repo" commit -q -m 'fixture: seed repo'

cp "$script_dir/land-direct-main.sh" "$fixture_engine/land-direct-main.sh"
printf 'export ZF_HOME=%q\n' "$fixture_home" > "$fixture_engine/deploy.env"
cat > "$fake_live/land-queue.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'resolved_agent_home=%s\n' "${AGENT_HOME:-}"
SH
chmod +x "$fake_live/land-queue.sh"

run_lander() (
  local requested_home="${1:-}"
  cd "$fixture_repo"
  if [[ -n "$requested_home" ]]; then
    env -u ZF_HOME -u AGENT_HOME HOME="$HOME" AGENT_HOME="$requested_home" \
      ZF_ENGINE_DIR="$fixture_engine" ZF_ENGINE_LIVE="$fake_live" \
      bash "$fixture_engine/land-direct-main.sh" --enqueue
  else
    env -u ZF_HOME -u AGENT_HOME HOME="$HOME" \
      ZF_ENGINE_DIR="$fixture_engine" ZF_ENGINE_LIVE="$fake_live" \
      bash "$fixture_engine/land-direct-main.sh" --enqueue
  fi
)

deployment_output="$(run_lander)"
printf '%s\n' "$deployment_output"
[[ "$deployment_output" == "resolved_agent_home=$fixture_home" ]] \
  || fail "expected deploy.env ZF_HOME=$fixture_home; got ${deployment_output#resolved_agent_home=}"
printf 'PASS: deploy.env ZF_HOME resolved without AGENT_HOME\n'

explicit_output="$(run_lander "$explicit_home")"
printf '%s\n' "$explicit_output"
[[ "$explicit_output" == "resolved_agent_home=$explicit_home" ]] \
  || fail "explicit AGENT_HOME should win; got ${explicit_output#resolved_agent_home=}"
printf 'PASS: explicit AGENT_HOME still wins\n'
