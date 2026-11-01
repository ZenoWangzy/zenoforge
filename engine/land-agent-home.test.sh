#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture_root="$ZF_AGENT_TEST_ROOT/land-agent-home"
fixture_repo="$fixture_root/repo"
fixture_engine="$fixture_root/published/engine"
fixture_home="$fixture_root/deployed-home"
explicit_home="$fixture_root/explicit-home"
explicit_zf_home="$fixture_root/explicit-zf-home"
fake_live="$fixture_root/fake-live"
deploy_repo="$fixture_root/deploy-repo"
deploy_engine="$fixture_root/deploy-engine"
trap 'rm -rf -- "$fixture_root"' EXIT

fail() {
  printf 'land-agent-home.test.sh: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$fixture_repo" "$fixture_engine" "$fixture_home" "$explicit_home" "$explicit_zf_home" "$fake_live" \
  "$deploy_repo" "$deploy_engine"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" checkout -q -b land-agent-home-test
git -C "$fixture_repo" config user.name 'land-agent-home fixture'
git -C "$fixture_repo" config user.email 'land-agent-home@example.invalid'
printf 'fixture repository\n' > "$fixture_repo/README.md"
git -C "$fixture_repo" add README.md
git -C "$fixture_repo" commit -q -m 'fixture: seed repo'

cp "$script_dir/land-direct-main.sh" "$fixture_engine/land-direct-main.sh"
{
  printf 'export ZF_HOME=%q\n' "$fixture_home"
  printf 'export ZF_REPO_DIR=%q\n' "$deploy_repo"
  printf 'export ZF_ENGINE_DIR=%q\n' "$deploy_engine"
} > "$fixture_engine/deploy.env"
cat > "$fake_live/land-queue.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'resolved_agent_home=%s\n' "${AGENT_HOME:-}"
printf 'repo_dir=%s\n' "${ZF_REPO_DIR:-}"
printf 'engine_dir=%s\n' "${ZF_ENGINE_DIR:-}"
SH
chmod +x "$fake_live/land-queue.sh"

# Keep the entrypoint location check out of this handoff test so poisoned deploy.env paths reach --enqueue.
run_lander() (
  local requested_home="${1:-}"
  local requested_zf_home="${2:-}"
  cd "$fixture_repo"
  if [[ -n "$requested_home" ]]; then
    env -u ZF_HOME -u AGENT_HOME HOME="$HOME" AGENT_HOME="$requested_home" \
      ZF_ENGINE_DIR="$fixture_engine" ZF_LAND_CODE_SNAPSHOT="$fixture_root/published" \
      ZF_ENGINE_LIVE="$fake_live" \
      bash "$fixture_engine/land-direct-main.sh" --enqueue
  elif [[ -n "$requested_zf_home" ]]; then
    env -u ZF_HOME -u AGENT_HOME HOME="$HOME" ZF_HOME="$requested_zf_home" \
      ZF_ENGINE_DIR="$fixture_engine" ZF_LAND_CODE_SNAPSHOT="$fixture_root/published" \
      ZF_ENGINE_LIVE="$fake_live" \
      bash "$fixture_engine/land-direct-main.sh" --enqueue
  else
    env -u ZF_HOME -u AGENT_HOME HOME="$HOME" \
      ZF_ENGINE_DIR="$fixture_engine" ZF_LAND_CODE_SNAPSHOT="$fixture_root/published" \
      ZF_ENGINE_LIVE="$fake_live" \
      bash "$fixture_engine/land-direct-main.sh" --enqueue
  fi
)

deployment_output="$(run_lander)"
printf '%s\n' "$deployment_output"
grep -Fqx "resolved_agent_home=$fixture_home" <<< "$deployment_output" \
  || fail "expected deploy.env ZF_HOME=$fixture_home; got ${deployment_output#resolved_agent_home=}"
printf 'PASS: deploy.env ZF_HOME resolved without AGENT_HOME\n'
# The queue handoff gets no repo dir from deploy.env; the live queue resolves its own.
grep -Fqx "repo_dir=" <<< "$deployment_output" \
  || fail "deploy.env ZF_REPO_DIR leaked into the queue handoff: $(grep '^repo_dir=' <<< "$deployment_output" || true)"
printf 'PASS: deployment ZF_REPO_DIR did not leak into the queue handoff\n'
grep -Fqx "engine_dir=$fixture_engine" <<< "$deployment_output" \
  || fail "expected entrypoint engine $fixture_engine; got $(grep '^engine_dir=' <<< "$deployment_output" || true)"
printf 'PASS: deployment ZF_ENGINE_DIR did not replace the entrypoint engine\n'

explicit_output="$(run_lander "$explicit_home")"
printf '%s\n' "$explicit_output"
grep -Fqx "resolved_agent_home=$explicit_home" <<< "$explicit_output" \
  || fail "explicit AGENT_HOME should win; got ${explicit_output#resolved_agent_home=}"
printf 'PASS: explicit AGENT_HOME still wins\n'

explicit_zf_output="$(run_lander '' "$explicit_zf_home")"
printf '%s\n' "$explicit_zf_output"
grep -Fqx "resolved_agent_home=$explicit_zf_home" <<< "$explicit_zf_output" \
  || fail "explicit ZF_HOME should win; got $(grep '^resolved_agent_home=' <<< "$explicit_zf_output" || true)"
printf 'PASS: explicit ZF_HOME still wins\n'

printf 'return 1\n' > "$fixture_engine/deploy.env"
failed_source_output="$(run_lander)"
printf '%s\n' "$failed_source_output"
grep -Fqx "resolved_agent_home=$HOME/.zenoforge" <<< "$failed_source_output" \
  || fail "failing deploy.env source should fall back to HOME; got $(grep '^resolved_agent_home=' <<< "$failed_source_output" || true)"
printf 'PASS: failing deploy.env source falls back without aborting\n'
