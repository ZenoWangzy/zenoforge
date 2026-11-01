#!/usr/bin/env bash
# Shared by lib.sh's build-capacity recovery probe and the build-capacity reclaim timer.
BUILD_CAPACITY_GATE_GIB=100
# Match the two-day capacity warning at 13 GiB/day before the 100 GiB build gate.
BUILD_CAPACITY_RECLAIM_MARGIN_GIB=26
