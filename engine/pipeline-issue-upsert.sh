#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo="${ZF_GH_REPO:-${ZF_REPO:?ZF_REPO is not set}}"
class=""
title=""
body_file=""
lane="pipeline-system"
labels=()

usage() {
  echo "usage: $0 --class stable-slug --title title --body-file path [--lane pipeline-system|product] [--label name] [--repo owner/name]" >&2
}

while (($#)); do
  case "$1" in
    --class) class="${2:-}"; shift 2 ;;
    --title) title="${2:-}"; shift 2 ;;
    --body-file) body_file="${2:-}"; shift 2 ;;
    --lane) lane="${2:-}"; shift 2 ;;
    --label) labels+=("${2:-}"); shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ "$class" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { usage; exit 64; }
[[ "$lane" == pipeline-system || "$lane" == product ]] || { usage; exit 64; }
[[ -n "$title" && -n "$repo" && -r "$body_file" ]] || { usage; exit 64; }
if ((${#labels[@]} == 0)); then
  if [[ "$lane" == pipeline-system ]]; then
    labels=(pipeline-system ready-for-agent)
  else
    labels=(bug priority:top needs-triage)
  fi
fi
for label in "${labels[@]}"; do
  [[ "$label" =~ ^[[:alnum:]][[:alnum:]_:-]{0,49}$ ]] || { usage; exit 64; }
done

marker="<!-- zf-incident-class:$class -->"
if grep -Eq '<!--[[:space:]]*zf-incident-class:' "$body_file"; then
  echo "pipeline-issue-upsert: body must not supply its own class marker" >&2
  exit 64
fi

lock_dir="${ZF_ISSUE_LOCK_DIR:-${HOME:?HOME is required}/.zenoforge/issue-create-locks}"
mkdir -p -- "$lock_dir"
exec 9>"$lock_dir/pipeline-system-$class.lock"
# ponytail: a local per-class lock prevents same-host create races; multi-host writers need a shared claim.
flock -x 9

issue_args=(--method GET --paginate --slurp "repos/$repo/issues" --raw-field state=open --field per_page=100)
if [[ "$lane" == pipeline-system ]]; then issue_args+=(--raw-field labels=pipeline-system); fi
issue_pages="$(gh api "${issue_args[@]}")" || {
  echo "pipeline-issue-upsert: could not read open issues; no issue created" >&2
  exit 1
}
issues="$(jq -ce '
  if type != "array" or any(.[]; type != "array") then error("expected paginated issue arrays")
  else [.[][] | select(has("pull_request") | not) | {number,title,body}]
  end
' <<< "$issue_pages")" || {
  echo "pipeline-issue-upsert: invalid open issue list; no issue created" >&2
  exit 1
}
jq -e 'type == "array" and all(.[]; (.number | type) == "number")' <<< "$issues" >/dev/null || {
  echo "pipeline-issue-upsert: invalid open issue list; no issue created" >&2
  exit 1
}

matches="$(jq -c --arg marker "$marker" \
  '[.[] | select((.body // "") | contains($marker))] | sort_by(.number)' <<< "$issues")"
existing="$(jq -r '.[0].number // empty' <<< "$matches")"
if [[ -n "$existing" ]]; then
  repeated_body="$(mktemp)"
  trap 'rm -f -- "${repeated_body:-}" "${new_body:-}"' EXIT
  {
    printf 'Repeated occurrence for %s class `%s`.\n\n' "$lane" "$class"
    cat -- "$body_file"
  } > "$repeated_body"
  gh issue comment "$existing" --repo "$repo" --body-file "$repeated_body"
  printf 'commented issue #%s for class %s (open matches=%s)\n' \
    "$existing" "$class" "$(jq 'length' <<< "$matches")"
  exit 0
fi

new_body="$(mktemp)"
trap 'rm -f -- "${new_body:-}"' EXIT
{
  cat -- "$body_file"
  printf '\n\n%s\n' "$marker"
  if ! grep -Fq '<!-- zenoforge-agent-comment -->' "$body_file"; then
    printf '%s\n' '<!-- zenoforge-agent-comment -->'
  fi
} > "$new_body"
create_args=(gh issue create --repo "$repo")
for label in "${labels[@]}"; do create_args+=(--label "$label"); done
create_args+=(--title "$title" --body-file "$new_body")
url="$(REPO="$repo" ZF_PIPELINE_ISSUE_UPSERT_HELPER=1 \
  bash "$SCRIPT_DIR/roadmap-issue-create.sh" "${create_args[@]}")" || exit 1
[[ "$url" =~ /issues/([1-9][0-9]*)$ ]] || {
  echo "pipeline-issue-upsert: issue create returned no issue URL" >&2
  exit 1
}
printf 'created %s for class %s\n' "$url" "$class"
