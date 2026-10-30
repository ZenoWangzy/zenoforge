#!/usr/bin/env bash
# Runs ts-judge.mjs with the TypeSafe key injected only into this child (scripts/ops/with-credentials.sh);
# units set TYPESAFE_ENV_FILE, never the key itself, so workers that inherit the unit env never see it.
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "${TYPESAFE_API_KEY:-}" && -n "${TYPESAFE_ENV_FILE:-}" ]]; then
  exec bash "$here/../ops/with-credentials.sh" --env "$TYPESAFE_ENV_FILE" -- node "$here/ts-judge.mjs" "$@"
fi
exec node "$here/ts-judge.mjs" "$@"
