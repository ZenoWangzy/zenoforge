# ---------- 作者闸（#114）：非准入作者的新 issue 只到分诊，不进实现 ----------
# 准入表在 config issue_intake.author_routes（作者关联 → admit|hold）；OWNER/MEMBER/COLLABORATOR 缺省 admit，未知关联 hold（fail closed）。
# issue_intake.trusted_authors 是登录名白名单。被挡的 issue 转 needs-triage 并留一条说明评论；准入作者评论 /release-intake 后放行。
intake_author_route() { # association login → admit|hold
  jqf -r --arg a "$1" --arg l "$2" '
    if ((.issue_intake.trusted_authors // []) | index($l)) then "admit"
    else ({OWNER:"admit",MEMBER:"admit",COLLABORATOR:"admit"} + (.issue_intake.author_routes // {}))[$a] // "hold" end' <<<"$CFG"
}
intake_author_gate() { # issue issue_json → 0 放行；1 挡下或本拍重试（读取失败不改 issue）
  local n="$1" issue_json="$2" meta assoc login comments ca cl released=0 marker='<!-- zf-intake-author-hold -->'
  meta="$(intake_gh_read api "repos/{owner}/{repo}/issues/$n" 2>/dev/null)" || { say "intake issue #$n author read failed; retry next tick"; return 1; }
  assoc="$(jqf -r '.author_association // ""' <<<"$meta")"; login="$(jqf -r '.user.login // ""' <<<"$meta")"
  [[ -n "$assoc$login" ]] || { say "intake issue #$n author unknown; retry next tick"; return 1; }
  [[ "$(intake_author_route "$assoc" "$login")" == admit ]] && return 0
  comments="$(intake_gh_read api "repos/{owner}/{repo}/issues/$n/comments?per_page=100" --paginate 2>/dev/null)" || { say "intake issue #$n comments read failed; retry next tick"; return 1; }
  comments="$(jqf -cs 'add // [] | .[] | {a:(.author_association // ""), l:(.user.login // ""), b:(.body // "")}' <<<"$comments")" || return 1
  while IFS=$'\t' read -r ca cl; do
    [[ "$(intake_author_route "$ca" "$cl")" == admit ]] && { released=1; break; }
  done < <(jqf -r 'select(.b | test("(^|\\n)/release-intake\\b")) | [.a, .l] | @tsv' <<<"$comments")
  if (( released )); then
    scheduler_issue_transition "$n" ready-for-agent intake-author-release . 0 "$issue_json" || { say "intake issue #$n release record failed; retry next tick"; return 1; }
    say "intake issue #$n released by an admitted author"
    return 0
  fi
  if ! grep -Fq -- "$marker" <<<"$comments"; then
    gh issue comment "$n" --body "$marker
Zenoforge 没有开始实现：作者 \`$login\`（$assoc）不在准入名单内，这个 issue 只留在分诊。维护者确认后，在评论里写 \`/release-intake\`，并把 issue 放回 ready-for-agent。" >/dev/null 2>&1 \
      || { say "intake issue #$n author hold comment failed; retry next tick"; return 1; }
  fi
  scheduler_issue_transition "$n" needs-triage "intake-author-hold:$assoc" . 0 "$issue_json" || { say "intake issue #$n author hold transition failed; retry next tick"; return 1; }
  say "intake issue #$n held at triage: author association $assoc is not admitted"
  return 1
}
