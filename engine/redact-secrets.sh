#!/usr/bin/env bash

# Shared text redaction used by the Codex dispatcher and TypeSafe judge.
redact_secret_text() {
  local value="${1//$'\r'/ }"
  if [[ -n "${TYPESAFE_API_KEY:-}" ]]; then
    value="${value//"$TYPESAFE_API_KEY"/[REDACTED]}"
  fi
  printf '%s' "$value" | sed -E \
    -e 's/(authorization[[:space:]]*:[[:space:]]*bearer[[:space:]]+)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/(bearer[[:space:]]+)[-[:alnum:]_.~+\/:=]{12,}/\1[REDACTED]/Ig' \
    -e 's/gh[pousr]_[[:alnum:]_]{20,}|github_pat_[[:alnum:]_]{20,}|sk-[[:alnum:]_-]{12,}|xox[baprs]-[[:alnum:]-]{20,}/[REDACTED]/g' \
    -e 's/("[[:alnum:]_.-]*(token|api[_-]?key|access[_-]?token|secret|password|credential|authorization)[[:alnum:]_.-]*"[[:space:]]*:[[:space:]]*")[^"]*(")/\1[REDACTED]\3/Ig' \
    -e 's/([[:alnum:]_.-]*(token|key|secret|password|credential)[[:alnum:]_.-]*[[:space:]]*[=:][[:space:]]*)[^,;&[:space:]|]+/\1[REDACTED]/Ig' \
    -e 's/([[:alnum:]_.-]*(token|api[_-]?key|secret|password|credential)[[:alnum:]_.-]*[[:space:]]*[|][[:space:]]*)[^|[:cntrl:]]+/\1[REDACTED]/Ig'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  redact_secret_text "$(cat)"
fi
