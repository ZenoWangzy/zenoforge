release_loss_probe_deployments() {
  bash "$ZF_ENGINE_DIR/production-deployment-read.sh" "$1" 2>/dev/null || true
}

release_run_loss_probe() {
  local repo_dir="${REPO_DIR:-$ZF_REPO_DIR}" image hook service container_filter label rollback_label deployment_repo records deployed_sha approved_sha
  local keeper_state image_revision_command live_image_sha check_output check_status raw_check_output live_count
  image="$(release_config_value lossProbeImageName)" || return 1
  hook="$(release_config_value lossProbeHookPath)" || return 1
  service="$(release_config_value lossProbeService)" || return 1
  container_filter="$(release_config_value lossProbeContainerFilter)" || return 1
  label="$(release_config_value lossProbeLabel)" || return 1
  rollback_label="$(release_config_value rollbackLabel)" || return 1
  deployment_repo="$(release_config_value deploymentRepository)" || return 1
  records="$(release_loss_probe_deployments "$deployment_repo")"
  deployed_sha="$(jq -r --arg image "$image" 'first(.[] | select((.payload.images // {} | has($image))) | (.payload.image_shas[$image] // .payload.sha // .sha)) // .[0].sha // empty' <<<"$records" 2>/dev/null || true)"
  approved_sha="$(git -C "$repo_dir" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ ! "$deployed_sha" =~ ^[0-9a-f]{40}$ ]] || ! git -C "$repo_dir" cat-file -e "$deployed_sha:$hook" 2>/dev/null; then
    printf 'DRIFT deployed %s hook baseline unavailable\n' "$label"
    return 1
  fi
  keeper_state="$(systemctl --user show --property=ActiveState --value "$service")" || {
    printf 'DRIFT cannot read %s state\n' "$service"
    return 1
  }
  case "$keeper_state" in
    active|inactive|failed) ;;
    *) printf 'DRIFT unknown %s state: %s\n' "$service" "$keeper_state"; return 1 ;;
  esac
  local filter_quoted
  printf -v filter_quoted '%q' "$container_filter"
  image_revision_command="set -eu
containers=\$(docker ps --filter $filter_quoted --format '{{.ID}}')
[ -n \"\$containers\" ]
container_count=\$(printf '%s\\n' \"\$containers\" | wc -l | tr -d '[:space:]')
[ \"\$container_count\" = 1 ]
container_image=\$(docker inspect -f '{{.Image}}' \"\$containers\")
docker image inspect -f '{{index .Config.Labels \"org.opencontainers.image.revision\"}}' \"\$container_image\""
  live_image_sha="$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=10 "$DEPLOY_HOST" "$image_revision_command" 2>/dev/null)" || live_image_sha=""
  if [[ ! "$live_image_sha" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || ! git -C "$repo_dir" cat-file -e "$live_image_sha:$hook" 2>/dev/null || ! git -C "$repo_dir" merge-base --is-ancestor "$live_image_sha" HEAD 2>/dev/null; then
    printf 'DRIFT current deployed %s image revision unavailable\n' "$label"
    return 1
  fi
  if check_output="$(release_run_rollback "$live_image_sha" check "$deployed_sha" "$live_image_sha" 2>&1)"; then check_status=0; else check_status=$?; fi
  raw_check_output="$check_output"
  if [[ "$check_status" -ne 0 ]] && ! grep -q '^DRIFT ' <<< "$raw_check_output"; then
    printf '%s\n' "$raw_check_output"
    printf 'DRIFT %s CHECK=1 exit=%s\n' "$rollback_label" "$check_status"
    return 1
  fi
  if ! check_output="$(release_filter_drift "$repo_dir" "$deployed_sha" "$live_image_sha" "$approved_sha" <<< "$raw_check_output")"; then
    printf '%s\n' "$check_output"
    return 1
  fi
  printf '%s\n' "$check_output"
  if grep -Eqi '(^|[[:space:]])DRIFT([[:space:]]|$)|uncovered (container|profile)' <<< "$check_output"; then
    printf 'DRIFT %s CHECK=1 exit=%s\n' "$rollback_label" "$check_status"
    return 1
  fi
  live_count="$(grep -Ec '^(OK|DRIFT) ' <<< "$raw_check_output" || true)"
  if [[ "$keeper_state" == failed && "$live_count" -gt 0 ]]; then
    printf 'DRIFT %s failed while %s matching containers are live\n' "$service" "$live_count"
    return 1
  fi
}
