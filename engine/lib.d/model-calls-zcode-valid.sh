zcode_reply_valid() { # <role> <schema_file> <object>: zcode enforces no schema, so a recut reply needs every required key here
  if [ "$1" = review ]; then
    jq -e 'type == "object" and (.verdict | type) == "string" and (.verdict | IN("READY", "NOT_READY", "INPUT_INCOMPLETE")) and (.report_md | type) == "string"' \
      <<< "$3" >/dev/null 2>&1
  else
    jq -e --slurpfile schema "$2" '. as $reply | type == "object" and all($schema[0].required[]; . as $key | $reply | has($key))' <<< "$3" >/dev/null 2>&1
  fi
}
