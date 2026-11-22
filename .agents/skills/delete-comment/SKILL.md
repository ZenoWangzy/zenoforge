---
name: delete-comment
description: Remove code comments from a part of the codebase following Matt Pocock's comment prompt. Use when asked to delete comments, run /delete-comment, or sweep a directory for comments.
---

# Delete comments

Comments rot. Agents read them as spec, copy the hacks they excuse, and trust stale ones. This repository keeps no comments in code: the code says what, issues hold the work that is still owed, and ADRs hold the decisions code cannot show. Source: https://x.com/mattpocockuk/status/2123798388227403983.

## Scope

The task names a directory or file list. Read every comment in it. A comment is what `tools/comment-ratchet.mjs` counts. Shebangs, tool directives (`shellcheck`, `eslint-disable`, `@ts-expect-error`, `/// <reference`), and text inside strings or heredocs are not comments: leave them alone.

## Classify each comment

- **Tautology**: repeats what the code already shows. Delete it.
- **Stale**: names code, behaviour or facts that are no longer true. Delete it.
- **Excuse**: explains away a hacky or limited implementation (`shortcut:` marks are Excuses). Delete it, and record the hack it covers for an issue.
- **Decision Record**: an important, non-obvious decision, such as why a workaround exists or why the obvious approach is wrong. Delete it from the code, and record the decision as an ADR candidate.

When you cannot tell Stale from Decision Record, check `git log -S '<comment text>'` for the commit that added it, and read that commit's PR.

## Change only comments

Change nothing but comments. Keep the code byte-identical apart from removed comment lines and trailing comment text. Then prove it:

    node tools/comment-ratchet.mjs --proof origin/main

The proof must print `comment-only: ok`. A proof failure means you changed code: undo that change. Then tighten the baseline:

    node tools/comment-ratchet.mjs --tighten

## Report in the PR body

Add these two sections. Do not write ADR files or open issues yourself: one consolidation pass does both, so that parallel sweeps do not collide on ADR numbers or file duplicate issues.

    ## excuses
    - <path>: <the hack, in one line> (was: "<the comment text>")

    ## adr-candidates
    - <path>: <the decision, in one sentence>. Why: <the reason the comment gave>. Terms: <domain words a search would use>

Write `none` under a heading that has no entries. Group several comments about one decision into one candidate.

## Writing new code

Write no comments. Put a non-obvious decision in an ADR under `docs/adr/`, and file an issue for any shortcut. The comment ratchet fails a change that adds comments.
