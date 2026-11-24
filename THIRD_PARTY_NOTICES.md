# Third-party notices

## Matt Pocock's agent skills (MIT)

The directories under `.agents/skills/` that the manifest lists (and the `.claude/skills/` symlinks that point at them) are Matt Pocock's agent skills, copied byte-identical from <https://github.com/mattpocock/skills> at the commit pinned in [`.agents/matt-skills.manifest.json`](.agents/matt-skills.manifest.json). Copyright (c) 2026 Matt Pocock. `.agents/skills/delete-comment/` is Zenoforge's own and is not a copy of Matt's skills.

These files stay under the MIT License, not under the PolyForm Noncommercial License that covers the rest of this repository. The full license text is kept at [`.agents/skills/LICENSE-mattpocock-skills`](.agents/skills/LICENSE-mattpocock-skills). Do not edit these files by hand; change the pin with `tools/sync-matt-skills.sh`.

Also under the same MIT license and copyright, verbatim copies of files from the upstream `setup-matt-pocock-skills` skill, kept in `docs/agents/` where the skills look for them: `docs/agents/domain.md` (upstream `domain.md`), `docs/agents/issue-tracker.md` (upstream `issue-tracker-github.md`) and `docs/agents/triage-labels.md` (upstream `triage-labels.md`).

## pstack (MIT)

`engine/vendor/pstack` is copied from <https://github.com/cursor/plugins> (`pstack/`) at the commit in its `UPSTREAM` file. The license is kept at [`engine/vendor/pstack/LICENSE`](engine/vendor/pstack/LICENSE).

## ub-mode (MIT)

`engine/vendor/ub-mode` is copied from <https://github.com/unclebob/ub-mode> at the commit in its `UPSTREAM` file. The license is kept at [`engine/vendor/ub-mode/LICENSE`](engine/vendor/ub-mode/LICENSE).

`.agents/skills/ask-zeno` and `.agents/skills/solve` are part of this repository and have no third-party license.
