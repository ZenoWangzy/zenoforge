release_filter_drift() {
  local repo_dir="${1:?repo dir required}"
  local old_sha="${2:-}" new_sha="${3:-}" approved_sha="${4:-${3:-}}"
  local hook skill image_hooks="" approved_hook="" approved_skill="" containers="" container_hooks="" revisions container sha output
  hook="$(release_config_value driftHookPath)" || return 1
  skill="$(release_config_value driftSkillPath)" || return 1
  output="$(cat)" || return 1
  if ! awk '
    $2 !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*(\/[a-z0-9][a-z0-9_-]{0,63})?$/ { next }
    ($1 == "OK" && NF == 4 && $3 ~ /^hook=/ && $4 ~ /^skill=/) ||
    ($1 == "DRIFT" && NF == 5 && $3 ~ /^hook=/ && $4 ~ /^skill=/ && $5 ~ /^chain=/) { found = 1; exit }
    END { exit !found }' <<< "$output"; then
    printf '%s\n' "$output"
    printf 'DRIFT CHECK=1 returned no container results\n'
    return 0
  fi
  for sha in "$old_sha" "$new_sha"; do
    [[ "$sha" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || continue
    git -C "$repo_dir" cat-file -e "$sha:$hook" 2>/dev/null || continue
    image_hooks+=" $(git -C "$repo_dir" show "$sha:$hook" | md5sum | cut -c1-32)"
  done
  if [[ "$approved_sha" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] \
    && git -C "$repo_dir" cat-file -e "$approved_sha:$hook" 2>/dev/null \
    && git -C "$repo_dir" cat-file -e "$approved_sha:$skill" 2>/dev/null; then
    approved_hook="$(git -C "$repo_dir" show "$approved_sha:$hook" | md5sum | cut -c1-32)"
    approved_skill="$(git -C "$repo_dir" show "$approved_sha:$skill" | md5sum | cut -c1-32)"
  fi
  while IFS= read -r container; do
    [[ "$container" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*(/[a-z0-9][a-z0-9_-]{0,63})?$ ]] || return 1
    containers+=" '$container'"
  done < <(awk -v image_hooks="$image_hooks" -v approved_hook="$approved_hook" -v approved_skill="$approved_skill" '
BEGIN { n = split(image_hooks, h, " "); for (i = 1; i <= n; i++) known["hook", h[i]] = 1 }
$1 == "KNOWN" { known[$2, $3] = 1; next }
$1 == "BASELINE" { baseline[$2, $3, $4] = 1; next }
$1 == "DRIFT" && NF == 5 && $3 ~ /^hook=/ && $4 ~ /^skill=/ && $5 ~ /^chain=/ &&
  !(approved_hook != "" && approved_skill != "" &&
    substr($3, 6) == approved_hook && substr($4, 7) == approved_skill) &&
  !(("hook", substr($3, 6)) in known) && (("skill", substr($4, 7)) in known) &&
  !(($2, substr($3, 6), substr($4, 7)) in baseline) { print $2 }' <<< "$output" | sort -u)
  if [[ -n "$containers" ]]; then
    revisions="$(ssh "${SSH_OPTS[@]}" "$DEPLOY_HOST" "set -eu
for unit in $containers; do
c=\${unit%%/*}
image=\$(docker inspect -f '{{.Image}}' \"\$c\")
revision=\$(docker image inspect -f '{{index .Config.Labels \"org.opencontainers.image.revision\"}}' \"\$image\")
printf 'IMAGE_REVISION %s %s\\n' \"\$unit\" \"\$revision\"
    done")" || { echo 'DRIFT running image revision probe failed'; return 1; }
    while read -r tag container new_image_sha; do
      [[ "$tag" == IMAGE_REVISION && "$new_image_sha" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || continue
      git -C "$repo_dir" merge-base --is-ancestor "$new_image_sha" "$new_sha" 2>/dev/null || continue
      git -C "$repo_dir" cat-file -e "$new_image_sha:$hook" 2>/dev/null || continue
      container_hooks+=" $container/$(git -C "$repo_dir" show "$new_image_sha:$hook" | md5sum | cut -c1-32)"
    done <<< "$revisions"
  fi
  awk -v image_hooks="$image_hooks" -v container_hooks="$container_hooks" -v approved_hook="$approved_hook" -v approved_skill="$approved_skill" '
BEGIN {
  n = split(image_hooks, h, " "); for (i = 1; i <= n; i++) known["hook", h[i]] = 1
  n = split(container_hooks, h, " "); for (i = 1; i <= n; i++) container_known[h[i]] = 1
}
$1 == "KNOWN" { known[$2, $3] = 1; next }
$1 == "BASELINE" { baseline[$2, $3, $4] = 1; next }
$1 == "DRIFT" && NF == 5 && $3 ~ /^hook=/ && $4 ~ /^skill=/ && $5 ~ /^chain=/ &&
  ((approved_hook != "" && approved_skill != "" &&
      substr($3, 6) == approved_hook && substr($4, 7) == approved_skill) ||
    (($2, substr($3, 6), substr($4, 7)) in baseline) ||
    ((((("hook", substr($3, 6)) in known) || (($2 "/" substr($3, 6)) in container_known)) &&
      (("skill", substr($4, 7)) in known)))) { next }
{ print }' <<< "$output"
}
