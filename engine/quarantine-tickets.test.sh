#!/usr/bin/env bash
# Every non-comment line in tools/quarantine*.txt has a reason and a ticket token (PT-n or #n), so no skipped suite is silent or unowned.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { echo "quarantine-tickets.test.sh: $*" >&2; exit 1; }

bad=$(cd "$repo" && awk -F'\t' '/^#/ || NF == 0 { next } NF < 2 || $2 !~ /(PT-[0-9]+|#[0-9]+)/ { print FILENAME ": " $0 }' tools/quarantine*.txt)
[[ -z $bad ]] || fail "quarantine line without a reason and a ticket: $bad"
echo "quarantine-tickets ok"
