# Quota routing from models.routing_file (a host file such as ~/.vecta-agent/model-routing.json).
# Same rule as ~/.vecta-agent/bin/model-primary.mjs: a family is out when it is reserved (reserve set and
# until null or still ahead) or its quota file is stale or unreadable; the rest are ordered by week quota left.
# Founder 2026-11-14: 「哪个额度多就用哪个当主力」. Unset routing_file keeps the configured shares.

routing_file_path() { # → the routing file from $CFG, ~ expanded; empty when unset
  local file
  file="$(jq -r '.models.routing_file // empty' <<<"${CFG:-null}" 2>/dev/null)"
  printf '%s' "${file/#\~/$HOME}"
}

routing_configured() { [[ -n "$(routing_file_path)" ]]; }

routing_family_order() { # → usable families (claude|codex|glm), most week quota left first
  local file now stale name reserve_json reserve_until qfile left
  file="$(routing_file_path)"
  [[ -n "$file" ]] || return 0
  now="${NOW_EPOCH:-$(date +%s)}"
  stale="$(jq -r '.stale_after_seconds // 3600' "$file" 2>/dev/null || echo 3600)"
  while IFS= read -r name; do
    reserve_json="$(jq -c --arg n "$name" '.families[$n].reserve // null' "$file" 2>/dev/null)"
    if [[ "$reserve_json" != null ]]; then
      reserve_until="$(jq -r '.until // empty' <<<"$reserve_json")"
      if [[ -z "$reserve_until" ]] || (( now < $(date -d "$reserve_until" +%s 2>/dev/null || echo 0) )); then continue; fi
    fi
    qfile="$(jq -r --arg n "$name" '.families[$n].quota_file // empty' "$file")"; qfile="${qfile/#\~/$HOME}"
    left="$(jq -r --argjson now "$now" --argjson stale "$stale" '
      select((.week_pct | type) == "number" and (.read_at | type) == "number" and ($now - .read_at) <= $stale)
      | [100 - .week_pct, 0] | max' "$qfile" 2>/dev/null)"
    [[ -n "$left" ]] && printf '%s %s\n' "$left" "$name"
  done < <(jq -r '.families | keys_unsorted[]' "$file" 2>/dev/null) | sort -s -k1,1gr | awk '{print $2}'
}

routing_review_candidates() { # author-family codex-identity glm-identity sonnet-identity → reviewer identities: other routed families by quota, then Sonnet
  local author="$1" fam
  while IFS= read -r fam; do
    [[ "$fam" != "$author" ]] || continue
    case "$fam" in
      codex) printf '%s\n' "$2" ;;
      glm) printf '%s\n' "$3" ;;
      claude) printf '%s\n' "$4" ;;
    esac
  done < <(routing_family_order)
  [[ "$author" == claude ]] || printf '%s\n' "$4"
}
