LAND_COORD_LANE_OWNER=""
LAND_COORD_LANE_OWNED=0

land_coord_lane_begin() {
  local wait="${1:-0}" status
  LAND_COORD_LANE_OWNER="${ZF_COORD_LANE_OWNER:-}"
  if [[ "${ZF_COORD_LANE:-}" == land && -n "$LAND_COORD_LANE_OWNER" ]]; then
    if coord_assert_owned lane-land "$LAND_COORD_LANE_OWNER"; then return 0; else status=$?; fi
    echo 'land-direct-main: inherited land lane ownership is no longer current' >&2
    return "$status"
  fi
  LAND_COORD_LANE_OWNER="$(coord_new_owner)" || return $?
  if coord_lane_acquire land "$LAND_COORD_LANE_OWNER" "$wait"; then
    LAND_COORD_LANE_OWNED=1
    return 0
  else
    status=$?
  fi
  echo "land-direct-main: could not acquire land lane status=$status" >&2
  return "$status"
}

land_coord_lane_assert() {
  local status
  if coord_assert_owned lane-land "$LAND_COORD_LANE_OWNER"; then return 0; else status=$?; fi
  echo 'land-direct-main: land lane ownership expired before push' >&2
  return "$status"
}

land_coord_lane_release() {
  [[ "$LAND_COORD_LANE_OWNED" == 1 && -n "$LAND_COORD_LANE_OWNER" ]] || return 0
  if coord_lane_release land "$LAND_COORD_LANE_OWNER"; then :; else
    local status=$?
    echo 'land-direct-main: could not release land lane' >&2
    return "$status"
  fi
  LAND_COORD_LANE_OWNED=0
}

land_coord_lane_cleanup() {
  land_coord_lane_release || :
}
