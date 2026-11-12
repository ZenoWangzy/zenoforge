#!/usr/bin/env bash
# Runs ts-judge.mjs with the TypeSafe key injected only into this child (scripts/ops/with-credentials.sh);
# units set TYPESAFE_ENV_FILE, never the key itself, so workers that inherit the unit env never see it.
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
creds="${ZF_WITH_CREDENTIALS_SCRIPT:-$here/../ops/with-credentials.sh}"
# shortcut: without the credentials script, ts-judge.mjs reads TYPESAFE_ENV_FILE itself; upgrade when with-credentials ships in this repo
if [[ -z "${TYPESAFE_API_KEY:-}" && -n "${TYPESAFE_ENV_FILE:-}" && -r "$creds" ]]; then
  exec bash "$creds" --env "$TYPESAFE_ENV_FILE" -- node "$here/ts-judge.mjs" "$@"
fi
exec node "$here/ts-judge.mjs" "$@"
