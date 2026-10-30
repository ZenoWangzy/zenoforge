
# Gate 4's predicate (run-implement.sh): is $2 (one changed path) inside the
# JSON array $1 of expected-package prefixes — exact match, or "$item/..."?
# 2026-09-12 bug this replaced: `any(.[]; $p == . or ($p | startswith(. +
# "/")))` looked right but the `$p |` pipe inside the condition rebinds `.`
# to $p for everything downstream, so `startswith(. + "/")` silently became
# `startswith($p + "/")` — always false. Binding the array element to its
# own variable ($item) before ever piping $p avoids the shadowing. See
# lib.test.sh for the regression test (a file under a declared package
# passes; a file outside it fails).
# 2026-09-14 (#1178/PR #1186): triage pinned expected_packages down to
# sub-package paths ("packages/example-pack/src",
# "packages/example-pack/tests") for an issue that legitimately also
# needed a third path in the SAME package
# (.../example-pack/runtime/hooks/) — this
# gate correctly rejected it as "outside expected_packages", parking a
# green, on-scope PR (#1186) on a human. lessons/RULES.md V77: a file set
# handed to an implementer up front is a CONCLUSION of finding the right
# seam, not a constraint issued before anyone has looked at the code —
# triage writes expected_packages before an implementer has chosen which
# files inside a package to touch, so it can only ever know the package,
# not the eventual sub-paths.
#
# Fixed by widening $expected_json to package granularity right here,
# inside the shared predicate, rather than at the one call site
# (run-triage.sh) that writes expected_packages, and rather than telling
# the model in prompts/triage.md to only ever write package-level paths.
# Two reasons this seam, not those:
# 1. The merge gate continues to funnel through this one function. Scheduler
#    collision reads now first choose optional exact expected_paths, but their
#    legacy fallback still calls this normalizer, so old/unknown state keeps
#    this same package-wide protection.
# 2. It is retroactive. #1178 was triaged and its narrow expected_packages
#    already persisted to its state file *before* this fix existed; a
#    write-time fix in run-triage.sh only protects tickets triaged after it
#    ships and does nothing for #1178 itself — it would still need a full
#    re-triage, not just the existing resume path (eef6058b3) picking the
#    already-open, already-green PR #1186 back up. Normalizing on read
#    means the very next gate check (this one) already sees it correctly,
#    with no re-triage and no state-file surgery.
# Prompt-only compliance was rejected outright, independent of the above:
# this codebase's own measured rate for it is under 2%
# (a standing project ruling on this exact pattern
# enforce rules with hooks, not prose).
#
# This repo's package boundary is `packages/<name>` — pnpm-workspace.yaml
# only globs `packages/*`, no other top-level directory is package-shaped —
# so any expected_json entry nested under one is widened to it; a bare
# `packages/<name>` or a path outside `packages/` entirely (e.g.
# `docs/agents`) passes through unchanged. `$path` (the second argument,
# never widened) needs no such treatment: widening only the `expected_json`
# side is sufficient, because a longer `$path` is already captured by the
# `startswith($item + "/")` check once $item is the package root.
#
# Widening also makes expected_packages_collide()'s concurrent-PR collision
# check catch MORE overlap, not less — it was already comparing prefixes
# through this same function, so a coarser prefix only ever matches a
# superset of what a narrower one matched. Two tickets both scoped to the
# same package now serialize via finish-first even if their real diffs
# would never have touched the same file, which is the conservative
# direction to be wrong in, not the dangerous one. A path outside every
# (now package-level) expected package still fails this gate exactly as
# before — this narrows what counts as "outside", it does not remove the
# gate.
# 2026-09-15 (#1215): an advisor-written entry of "templates/levels/" (a
# trailing slash, not a packages/-rooted path so the widening step above
# never touches it) made path_in_expected_packages's own
# startswith($item + "/") check require "templates/levels//" -- a path that
# cannot occur -- so a diff that was genuinely inside the declared scope
# read as outside it. The gate's own rejection message printed the exact
# entry that should have matched ("outside expected_packages
# [\"packages/example-service\",\"templates/levels/\"]"), and nobody read it
# for hours: it correctly re-routed #1215 to a second advisor episode (which
# then hit an unrelated deadlock, since fixed, and froze), stranded its
# already-green PR #1240 open, and open_pr_file_collision() -- same shared
# normalization, comparing at package granularity for legacy state -- then
# blocked #1144 and #1177 from ever being offered as candidates while #1240
# sat there.
#
# Fixed by stripping trailing slash(es) before the existing packages/
# widening runs, in this one shared function every consumer above already
# funnels through for its merge-gate and legacy scheduling fallback -- not in
# the jq
# expression at path_in_expected_packages's call site, and not by asking
# run-triage.sh/advisor.md to never emit a trailing slash, for the same
# "single seam, retroactive, prompt compliance measures <2%" reasons
# already argued above for the packages/ widening.
#
# select(length > 0) after stripping also drops an entry that was only
# slashes (e.g. "/"), so it can't survive as an inert empty-string
# comparison. Everything else considered and deliberately NOT handled,
# because advisor.schema.json's expected_packages_addendum and
# triage.schema.json's expected_packages are free-text arrays but every
# real producer (triage.md's own worked examples, #1215's actual payload)
# only ever writes bare "packages/<name>" or "<dir>/<subdir>" forms:
# - A leading "./" or leading "/" — no prompt example or observed payload
#   has ever emitted one; nothing here would generate it. Adding a strip
#   for it would be a defense against an input that cannot occur, not a
#   fix for one that did.
# - A duplicate entry after normalization — already handled by the
#   trailing `| unique` below, which runs after the slash-strip, so
#   ["templates/levels","templates/levels/"] still collapses to one entry
#   exactly like the pre-existing packages/ widening case does.
# `$path` (the second argument to path_in_expected_packages) still needs no
# equivalent treatment, same as the widening comment above already argues:
# a real diff path from `git diff --name-only` / `gh pr view --json files`
# never carries a trailing slash.
normalize_expected_packages() {
  echo "$1" | jq -c '
    map(sub("/+$"; "") | select(length > 0))
    | [.[] | if test("^packages/[^/]+/") then (split("/")[0:2] | join("/")) else . end]
    | unique
  '
}


# Collision scheduling may use triage's optional exact paths, but merge gate
# 4 remains deliberately package-wide. Unknown/legacy state has no exact
# paths, so it takes the existing normalized package scope rather than gaining
# unprotected concurrency.
selection_scope_json() {
  local state_json
  state_json="$(cat)"
  if echo "$state_json" | jq -e '(.expected_paths? | type) == "array" and (.expected_paths | length) > 0' >/dev/null 2>&1; then
    echo "$state_json" | jq -c '.expected_paths'
  else
    normalize_expected_packages "$(echo "$state_json" | jq -c '.expected_packages // []')"
  fi
}


# declared_write_surface_missing <paths-json> <repo-root> -- true only when
# every explicitly declared path is absent from the checkout.
declared_write_surface_missing() {
  local paths_json="$1" repo_root="${2:-${REPO_DIR:-}}" path
  MISSING_WRITE_SURFACE_PATHS=""
  if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' <<< "$paths_json" >/dev/null 2>&1; then
    MISSING_WRITE_SURFACE_PATHS="声明范围无法解析"
    return 0
  fi
  if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
    MISSING_WRITE_SURFACE_PATHS="仓库范围无法读取"
    return 0
  fi
  while IFS= read -r path; do
    case "$path" in
      /*|..|../*|*/../*|*/..)
        MISSING_WRITE_SURFACE_PATHS="声明范围无法安全检查"
        return 0
        ;;
    esac
    if [ -e "$repo_root/$path" ]; then
      return 1
    fi
    MISSING_WRITE_SURFACE_PATHS="${MISSING_WRITE_SURFACE_PATHS:+$MISSING_WRITE_SURFACE_PATHS, }$path"
  done < <(jq -r '.[]' <<< "$paths_json")
  return 0
}


issue_body_file_paths_json() {
  local include_key_files="${2:-false}" whole_text="${3:-false}"
  local paths
  if [[ "$whole_text" == true ]]; then
    paths="$(printf '%s\n' "${1:-}" | grep -Eo "$ISSUE_BODY_PATH_REGEX" | LC_ALL=C sort -u || true)"
  else
    paths="$(printf '%s\n' "${1:-}" | awk -v include_key_files="$include_key_files" '
      {
        lower = tolower($0)
        key_heading = lower ~ /^[[:space:]]*#{1,6}[[:space:]]*key files( and symbols)?[[:space:]]*$/
        scope_heading = lower ~ /^[[:space:]]*#{1,6}[[:space:]]*(fix|target|affected|implementation)[ -]*(paths|files)[[:space:]]*$/
        if ((include_key_files == "true" && key_heading) || scope_heading) { active = 1; next }
        if (lower ~ /^[[:space:]]*#{1,6}[[:space:]]/) { active = 0; next }
        key_label = lower ~ /^[[:space:]]*key files( and symbols)?[[:space:]]*:/
        scope_label = lower ~ /^[[:space:]]*(fix|target|affected|implementation)[ -]*(paths|files)[[:space:]]*:/
        if ((include_key_files == "true" && key_label) || scope_label) { active = 1; sub(/^[^:]*:[[:space:]]*/, ""); print; next }
        if (active && lower ~ /^[[:space:]]*[[:alpha:]][[:alnum:] _-]*:[[:space:]]*$/) { active = 0; next }
        if (active) print
      }
    ' | grep -Eo "$ISSUE_BODY_PATH_REGEX" | LC_ALL=C sort -u || true)"
  fi
  printf '%s\n' "$paths" | jq -Rsc 'split("\n") | map(select(length > 0))'
}


# brief_lane_verdict <issue-number|0> [note-file] -> worker-facing lane section.
# The hand dispatcher persists this in the brief before starting an opt worker.
brief_lane_verdict() {
  local issue="${1:-}" note="${2:-}" text="" issue_json paths classification verdict="unknown" refs_issue="" recheck_doc
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo 'brief_lane_verdict: issue number must be numeric' >&2; return 64; }
  [[ -z "$note" || -r "$note" ]] || { echo "brief_lane_verdict: note file is unreadable: $note" >&2; return 64; }

  [[ -z "$note" ]] || text="$(cat -- "$note")"$'\n'
  if [[ "$issue" != 0 ]]; then
    issue_json="$(gh issue view "$issue" --repo "$REPO" --json body,comments 2>/dev/null || true)"
    if [[ -n "$issue_json" ]]; then
      text+="$(jq -r '(.body // "") + "\n" + ([.comments[]?.body // ""] | join("\n"))' <<<"$issue_json")"$'\n'
    fi
  fi

  paths="$(issue_body_file_paths_json "$text" true)"
  if [[ "$(jq 'length' <<<"$paths")" -eq 0 ]]; then
    paths="$(issue_body_file_paths_json "$text" true true)"
  fi
  if [[ "$(jq 'length' <<<"$paths")" -gt 0 ]]; then
    classification="$(node "$REPO_DIR/scripts/branch-delivery-policy.mjs" --classify-path-set - <<<"$paths" 2>/dev/null || true)"
    case "$classification" in
      eligible) verdict="direct-main" ;;
      not-eligible) verdict="pr" ;;
    esac
  fi

  [[ "$issue" == 0 ]] || refs_issue="、正文写 Refs #${issue}"
  recheck_doc="$(cat <<'EOF'
第一次写文件时先复核车道（在 worktree 根目录执行，覆盖未提交改动和未跟踪新文件）：

    { git diff --name-only origin/main; git ls-files --others --exclude-standard; } | sort -u \
      | jq -Rsc 'split("\n") | map(select(length > 0))' \
      | node scripts/branch-delivery-policy.mjs --classify-path-set -

输出 eligible 才继续 direct-main；输出 not-eligible 立即停，本票改走 PR 车道交付，不要继续实现等 land-direct-main 以 exit 2 拒绝。
EOF
)"

  case "$verdict" in
    direct-main)
      cat <<EOF
## 车道判定（launch 时已判：direct-main，#4722）

预计改动路径已用 scripts/branch-delivery-policy.mjs --classify-path-set（land-direct-main 落地时同一份判定）判为 eligible：

$(jq -r '.[] | "  - " + .' <<<"$paths")

按 brief 用 engine/land-direct-main.sh 落地。要写上面清单之外的路径时，先按下面的命令重判一次；not-eligible 就改走 PR 车道（开 PR${refs_issue}），不要等 land-direct-main 以 exit 2 拒绝。

${recheck_doc}
EOF
      ;;
    pr)
      cat <<EOF
## 车道判定（launch 时已判：PR 车道，#4722）

预计改动路径用 scripts/branch-delivery-policy.mjs --classify-path-set（land-direct-main 落地时同一份判定）判为 not-eligible，直落会被 land-direct-main 以 exit 2 拒绝：

$(jq -r '.[] | "  - " + .' <<<"$paths")

从一开始就按 PR 交付：开 PR${refs_issue}，走产品门禁，不要走 land-direct-main，也不要先写完再搬家。
EOF
      ;;
    *)
      cat <<EOF
## 车道判定（launch 未能判定，#4722）

brief 里提取不到仓库内路径，无法预判 direct-main 还是 PR 车道。

${recheck_doc}
EOF
      ;;
  esac
}


# issue_change_surface_json <state-json> <body> <labels-json> -> scoped paths.
# Triage paths/packages stay authoritative; key files and package labels fill
# gaps without widening ordinary collision scheduling.
issue_change_surface_json() {
  local state="$1" body="$2" labels="$3" body_paths expected_paths expected_packages label_paths
  if ! jq -e 'type == "object" and ((.expected_paths // []) | type == "array") and ((.expected_packages // []) | type == "array")' <<< "$state" >/dev/null 2>&1 \
    || ! jq -e 'type == "array"' <<< "$labels" >/dev/null 2>&1; then
    echo '[]'
    return 0
  fi
  body_paths="$(issue_body_file_paths_json "$body" true)" || { echo '[]'; return 0; }
  expected_paths="$(jq -c '.expected_paths // []' <<< "$state")"
  expected_packages="$(normalize_expected_packages "$(jq -c '.expected_packages // []' <<< "$state")")" || { echo '[]'; return 0; }
  label_paths="$(jq -c '
    [ .[]? | (.name // .) | select(type == "string")
      | try capture("^(package|pkg):(?<path>[A-Za-z0-9._/-]+)$").path catch empty
      | if startswith("packages/") or startswith("apps/") then . else "packages/" + . end
    ] | unique
  ' <<< "$labels")" || { echo '[]'; return 0; }
  jq -cn --argjson p "$expected_paths" --argjson e "$expected_packages" \
    --argjson b "$body_paths" --argjson l "$label_paths" '($p + $e + $b + $l) | unique'
}


issue_body_mentions_product_scope() {
  local text="${1:-}"
  grep -Eiq '(^|[^[:alnum:]_])(packages|apps)/' <<< "$text" && return 0
  grep -Eiq '(^|[^[:alnum:]_./-])[[:alnum:]_.-]+\.(ts|tsx|sql|mjs)([^[:alnum:]_.-]|$)' <<< "$text"
}


issue_is_parent_tracker() {
  jq -e '
    type == "object" and (
      ((.subIssuesSummary.total // .subIssues.totalCount // ((.subIssues.nodes // []) | length) // 0)
        > (.subIssuesSummary.completed // 0))
      or any(.blockedBy.nodes[]?; ((.state // "") | ascii_downcase) == "open")
    )
  ' <<< "${1:-}" >/dev/null 2>&1
}


issue_intake_parent_reason() { # issue number, fetched issue JSON -> reason; 1=leaf, 2=parent lookup unavailable
  local n="$1" json="$2" title body child state sub_issues
  title="$(jq -r '.title // ""' <<< "$json")"
  body="$(jq -r '.body // ""' <<< "$json")"
  if grep -Eiq '(^|[^[:alnum:]_-])(spec|specification)([^[:alnum:]_-]|$)' <<< "$title" \
      || grep -Eiq '^[[:space:]]*(#{1,6}[[:space:]]*)?(spec|specification)([[:space:]:#_-]|$)' <<< "$body" \
      || grep -Eiq '(^|[^[:alnum:]_])(this issue|this ticket)[[:space:]]+is[[:space:]]+(a[[:space:]]+)?(spec|specification)([^[:alnum:]_-]|$)' <<< "$body" \
      || { grep -Eiq 'ADR[[:space:]_-]*[0-9]+' <<< "$title" \
        && grep -Eiq 'pilot|试点' <<< "$title"; } \
      || grep -Eiq '^[[:space:]]*(#{1,6}[[:space:]]*)?ADR[[:space:]_-]*[0-9]+[[:space:]]+(pilot|试点)([[:space:][:punct:]]|$)' <<< "$body"; then
    printf 'spec/ADR pilot\n'
    return 0
  fi

  while IFS= read -r child; do
    [[ "$child" =~ ^[1-9][0-9]*$ && "$child" != "$n" ]] || continue
    state="$(gh issue view "$child" --json state --jq .state 2>/dev/null)" || return 2
    case "$state" in
      OPEN|open) printf 'task list references open child #%s\n' "$child"; return 0 ;;
      CLOSED|closed) ;;
      *) return 2 ;;
    esac
  done < <(printf '%s\n' "$body" \
    | awk '/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\][[:space:]]/ { print }' \
    | { grep -Eo '(#[1-9][0-9]*|/issues/[1-9][0-9]*)' || [[ $? == 1 ]]; } \
    | sed -E 's#^.*/issues/##; s/^#//' | sort -u)

  if jq -e '((.subIssuesSummary.total // 0) > 0) or ((.subIssues.totalCount // 0) > 0) or (((.subIssues.nodes // []) | length) > 0)' \
      <<< "$json" >/dev/null; then
    printf 'has GitHub sub-issues\n'
    return 0
  fi
  if jq -e 'has("subIssuesSummary") or has("subIssues")' <<< "$json" >/dev/null; then
    return 1
  fi
  if ! sub_issues="$(gh api "repos/$REPO/issues/$n/sub_issues?per_page=100" 2>/dev/null)" \
      || ! jq -e 'type == "array"' <<< "$sub_issues" >/dev/null; then
    return 2
  fi
  if jq -e 'length > 0' <<< "$sub_issues" >/dev/null; then
    printf 'has GitHub sub-issues\n'
    return 0
  fi
  return 1
}


issue_body_is_direct_main_lane() {
  local text="${1:-}" paths
  if issue_body_mentions_product_scope "$text"; then return 1; fi
  paths="$(issue_body_file_paths_json "$text")" || return 1
  jq -e 'type == "array" and length > 0' <<< "$paths" >/dev/null 2>&1 || return 1
  [ "$(node "$REPO_DIR/scripts/branch-delivery-policy.mjs" --classify-path-set "$paths" 2>/dev/null)" = eligible ]
}


selection_scope_roots_json() {
  jq -c '[.[]? | split("/") as $parts | if ($parts | length) > 2 then ($parts[0:2] | join("/")) else ($parts | join("/")) end] | unique' <<< "$1"
}


package_scope_add_root() {
  local issue="$1" root="$2" current
  [ -n "$root" ] || return 0
  current=" ${PACKAGE_SCOPE_ISSUES[$root]:-} "
  [[ "$current" == *" $issue "* ]] && return 0
  PACKAGE_SCOPE_ISSUES[$root]="${PACKAGE_SCOPE_ISSUES[$root]:-}${PACKAGE_SCOPE_ISSUES[$root]:+ }$issue"
  PACKAGE_SCOPE_COUNT[$root]=$(( ${PACKAGE_SCOPE_COUNT[$root]:-0} + 1 ))
}


package_scope_add_issue() {
  local issue="$1" scope_json="$2" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    package_scope_add_root "$issue" "$root"
  done < <(selection_scope_roots_json "$scope_json" | jq -r '.[]')
}


package_scope_is_full() {
  local issue="$1" scope_json="$2" cap="$3" root count current
  PACKAGE_SCOPE_BLOCKING_ROOT=""
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    count=${PACKAGE_SCOPE_COUNT[$root]:-0}
    current=" ${PACKAGE_SCOPE_ISSUES[$root]:-} "
    [[ "$current" == *" $issue "* ]] && count=$((count - 1))
    if [ "$count" -ge "$cap" ]; then
      PACKAGE_SCOPE_BLOCKING_ROOT="$root"
      return 0
    fi
  done < <(selection_scope_roots_json "$scope_json" | jq -r '.[]')
  return 1
}


# Exact prefix predicate for the scheduler's already-selected scope. Unlike
# path_in_expected_packages(), this intentionally does not widen a supplied
# expected_paths entry to its package; that widening remains merge gate 4.
path_in_selection_scope() {
  local scope_json="$1" path="$2"
  echo "$scope_json" | jq -e --arg p "$path" \
    '[.[]? | . as $item | ($p == $item or ($p | startswith($item + "/")))] | any' > /dev/null
}


selection_scope_has_exact_path() {
  echo "$1" | jq -e --arg p "$2" 'any(.[]?; . == $p)' >/dev/null
}


shared_collision_path() {
  case "$1" in
    package.json|*/package.json|pnpm-lock.yaml|*/pnpm-lock.yaml|package-lock.json|*/package-lock.json|yarn.lock|*/yarn.lock|*/src/index.ts|*/src/index.tsx|*/src/index.js|*/src/index.mjs|packages/*/index.ts|packages/*/index.tsx|packages/*/index.js|packages/*/index.mjs) return 0 ;;
    *) return 1 ;;
  esac
}


path_in_expected_packages() {
  local expected_json path
  expected_json="$(normalize_expected_packages "$1")"
  path="$2"
  echo "$expected_json" | jq -e --arg p "$path" \
    '[.[] | . as $item | ($p == $item or ($p | startswith($item + "/")))] | any' > /dev/null
}
