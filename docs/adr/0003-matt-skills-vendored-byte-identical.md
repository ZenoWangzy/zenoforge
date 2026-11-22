# Matt skills are vendored byte-identical at a pinned commit and never hand-edited
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** The Matt Pocock skills under `.agents/skills/` are byte-identical to the upstream commit pinned in `.agents/matt-skills.manifest.json`, and a new pin is made only by re-running `tools/sync-matt-skills.sh <commit>`.
> **Do not:** edit a file under `.agents/skills/` by hand; change the pin by editing the manifest; re-vendor without `tools/sync-matt-skills.sh`
> **Rejected:** none stated
> **Terms:** Matt skills, vendored, pinned commit, `.agents/skills/`, `tools/sync-matt-skills.sh`

The method for every stage follows Matt Pocock's skills (MIT), entered through `ask-matt`. The skills are vendored byte-identical under `.agents/skills/`. The script extracts files with `git archive`, rewrites `.agents/matt-skills.manifest.json` and recreates the `.claude/skills/<name>` symlinks. Its header says the skill set is every upstream `skills/<bucket>/<name>/SKILL.md` at that commit, all buckets except `deprecated`. Nothing in the script is hand-edited; re-running it is how the pin changes.

The engine prompts add a rule on top of the skills: no questions, no sub-agents, no tracker writes. The machine contracts (output schemas, the `VERDICT:` line, the `review-findings` block) win over a skill where they differ.

## Consequences
- A skill fix is an upstream change plus a re-vendor, so the local tree stays diffable against the pin.
- The license stays MIT for those files (`THIRD_PARTY_NOTICES.md`), not the repository's.
- A reviewer of a `.agents/skills/` diff should expect it to come from the script, not from an author's hand.

Sources: AGENTS.md#method-matt-skills, docs/architecture.md#23-method-matt-skills, tools/sync-matt-skills.sh (header comment), README.md#what-it-does
