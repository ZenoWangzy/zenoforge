#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
v="$(dirname "${BASH_SOURCE[0]}")/validate-acceptance.mjs"; h=0123456789abcdef0123456789abcdef01234567
rec() { printf '<!-- vecta-hotfix-acceptance:start -->{"schema":"example.hotfix-acceptance/v1","status":"%s","reason":"%s","accepted_head_sha":"%s"}<!-- vecta-hotfix-acceptance:end -->' "$1" "$2" "$h"; }
PR_BODY="$(rec deferred-to-release needs-unreleased-migration)" PR_HEAD_SHA=$h PR_NUMBER=4687 node "$v" >/dev/null
PR_BODY="$(rec deferred-to-release needs-unreleased-migration)" PR_HEAD_SHA=$h GITHUB_REF=refs/pull/4687/merge node "$v" >/dev/null
! PR_BODY="$(rec deferred-to-release needs-unreleased-migration)" PR_HEAD_SHA=$h PR_NUMBER=1 node "$v" 2>/dev/null
! PR_BODY="$(rec deferred-to-release other)" PR_HEAD_SHA=$h PR_NUMBER=4687 node "$v" 2>/dev/null
PR_BODY="$(rec not_applicable test-only)" PR_HEAD_SHA=$h PR_CHANGED_FILES=a/tests/x.ts node "$v" >/dev/null
! PR_BODY="$(rec not_applicable test-only)" PR_HEAD_SHA=$h PR_CHANGED_FILES=a/src/x.ts node "$v" 2>/dev/null
