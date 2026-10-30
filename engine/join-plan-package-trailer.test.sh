#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
git -C "$tmp" init -q && git -C "$tmp" config user.email t@t && git -C "$tmp" config user.name t
git -C "$tmp" commit -q --allow-empty -m base
git -C "$tmp" commit -q --allow-empty -F - <<'MSG'
[skip ci] fix(agent): sample

Body text.

Plan-Package: hand-2824

Co-Authored-By: Codex <codex@openai.com>
MSG
git -C "$tmp" commit -q --allow-empty -m 'second' -m 'Plan-Package: hand-x
Co-Authored-By: Codex <codex@openai.com>'
(cd "$tmp" && git rebase -q --exec "bash $SCRIPT_DIR/join-plan-package-trailer.sh" HEAD~2)
[[ "$(git -C "$tmp" log -1 --skip=1 --format='%(trailers:key=Plan-Package,valueonly)' | sed '/^$/d')" == hand-2824 ]] \
  || { echo 'not ok - separated Plan-Package joins the trailer block'; exit 1; }
echo 'ok - separated Plan-Package joins the trailer block'
[[ "$(git -C "$tmp" log -1 --format='%(trailers:key=Plan-Package,valueonly)' | sed '/^$/d')" == hand-x ]] \
  || { echo 'not ok - an already-joined message is unchanged'; exit 1; }
echo 'ok - an already-joined message is unchanged'
(cd "$tmp" && bash "$SCRIPT_DIR/check-commit-messages.sh" HEAD~2..HEAD) && echo 'ok - lander commit-message check passes after joining'
