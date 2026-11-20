image_inputs_changed_in_release() {
  [[ $'\n'$DIFF_CHANGED_IMAGES$'\n' == *$'\n'$1$'\n'* ]]
}

expected_image_id() {
  if [[ -n "${RELEASE_DESIRED_IDS[$1]:-}" ]]; then
    printf '%s\n' "${RELEASE_DESIRED_IDS[$1]}"
  else
    remote "docker image inspect -f '{{.Id}}' '$REGISTRY/$1:${RELEASE_IMAGE_TAGS[$1]:-$DEPLOYED_SHA}'"
  fi
}
