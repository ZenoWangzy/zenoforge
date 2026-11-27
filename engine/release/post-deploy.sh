release_migration_command() {
  local mode="$1" phase="$2" repo="$3" sha="$4"
  local -a args=()
  [[ "$mode" == backups ]] && args+=(--backups)
  node "$ZF_ENGINE_DIR/post-deploy-migrations.mjs" "${args[@]}" --phase "$phase" "$repo" "$sha"
}

release_post_deploy_sql() {
  release_migration_command sql post-deploy "${2:-$ZF_REPO_DIR}" "${1:?release SHA required}"
}

release_pre_deploy_sql() {
  release_migration_command sql pre-deploy "${2:-$ZF_REPO_DIR}" "${1:?release SHA required}"
}

release_post_deploy_backup_entries() {
  release_migration_command backups post-deploy "${2:-$ZF_REPO_DIR}" "${1:?release SHA required}"
}

release_pre_deploy_backup_entries() {
  release_migration_command backups pre-deploy "${2:-$ZF_REPO_DIR}" "${1:?release SHA required}"
}
