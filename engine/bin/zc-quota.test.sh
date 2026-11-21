#!/usr/bin/env bash
# Weekly pacing, expiring caps, and held-under-pace alerts in bin/zc-quota; CDP reads need the signed-in browser.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
node "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/zc-quota" --self-test
