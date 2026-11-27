# Release runner foundation. Source after selecting the target repository; the
# public dispatcher remains responsible for choosing the product runner.
RELEASE_RUNNER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "${ZF_ENGINE_DIR:-}" ]]; then
  ZF_ENGINE_DIR="$(cd -- "$RELEASE_RUNNER_DIR/.." && pwd -P)"
fi
export ZF_ENGINE_DIR
source "$ZF_ENGINE_DIR/config.sh"
source "$RELEASE_RUNNER_DIR/delivery.sh"
source "$RELEASE_RUNNER_DIR/images.sh"
source "$RELEASE_RUNNER_DIR/drift-filter.sh"
source "$RELEASE_RUNNER_DIR/rollback.sh"
source "$RELEASE_RUNNER_DIR/loss-probe.sh"
source "$RELEASE_RUNNER_DIR/post-deploy.sh"
declare -A RELEASE_DESIRED_IDS RELEASE_IMAGE_TAGS

release_config_value() {
  local key="${1:-<unspecified>}" value
  if [[ -z "${RELEASE_CONFIG:-}" ]] \
    || ! value="$(jq -er --arg key "$key" '.release[$key] | select(type == "string" and length > 0)' \
      "$RELEASE_CONFIG" 2>/dev/null)"; then
    printf 'run-release: required release config key .release.%s is missing or invalid\n' "$key" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

release_runner_load_config() {
  RELEASE_CONFIG="$(zf_config_file release.json 2>/dev/null || true)"
  DEPLOY_HOST="${DEPLOY_HOST:-$(release_config_value deployHost)}"
  REGISTRY="$(release_config_value imageRegistry)"
  INFRA_WORKFLOW_REPOSITORY="$(release_config_value infraWorkflowRepository)"
  INFRA_BUILD_WORKFLOW="$(release_config_value infraBuildWorkflow)"
  INFRA_WORKFLOW_RUN_URL="$(release_config_value infraWorkflowRunUrl)"
  PRODUCTION_URL="$(release_config_value productionUrl)"
}
