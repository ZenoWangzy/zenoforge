#!/usr/bin/env bash
# The weekly pace line of bin/zc-quota (glm_factory_cap_2026_11_08); the CDP read itself needs the signed-in browser.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
node "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/zc-quota" --self-test
