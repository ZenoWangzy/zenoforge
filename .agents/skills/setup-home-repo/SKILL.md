---
name: setup-home-repo
description: Set up a private home repo with pointers to Zenoforge's shared AI rollout material.
disable-model-invocation: true
---

# Set Up a Home Repo

Matt Pocock's [Home Repo pattern article](https://www.aihero.dev/the-home-repo-pattern) describes four steps: inventory repositories, inventory shared material, agree a table, and apply it. Keep two layers:

- **Shared:** skills, practices, and factory terms stay in Zenoforge. Point to them, or use a sync tool that Zenoforge documents for downstream repos.
- **Private:** personal instructions, local paths, and private repo pointers stay in the user's private home repo.

## 1. Inventory repositories

Ask which directories contain the user's repositories and which private repo is the home repo. Inventory Git repositories only within those directories. For each one, record its name, local path, sanitized remote, and relevant agent instructions or personal AI material.

Read only files needed to identify agent instructions and AI material. Never open environment files, credential or token stores, private keys, or files that may contain secrets. If a file's purpose is unclear, treat it as secret. Redact credentials from remote URLs before displaying or recording them.

**Done when:** every repository in the named directories is listed with its local path, sanitized remote, and relevant agent instructions or personal AI material.

## 2. Inventory shared material

Use the user's Zenoforge checkout. If they have none, ask where to clone the public repository before cloning it. Inventory its skills under `.agents/skills/`, its practices index if present, and `GLOSSARY.md`. If the practices index is absent, record that and use `docs/enforced-rules.md` as the available practice reference.

Check whether Zenoforge documents a sync tool intended for downstream home repos. Record the tool and its destination rules. `tools/sync-matt-skills.sh` updates Zenoforge's upstream vendored skills; it is not a downstream home repo sync tool.

**Done when:** the shared items, available practices reference, and downstream sync tool (or none) are recorded.

## 3. Agree the table

Show one row for each item found, with its current location, layer, destination, and action:

| Item | Current location | Layer | Destination and action |
| --- | --- | --- | --- |
| Example: shared skill | Zenoforge checkout | Shared | Pointer to Zenoforge; no copy |
| Example: personal instructions | Existing repo | Private | Keep or move to the private home repo |

Classify every item as **Shared** or **Private**. For shared items, choose a pointer or a documented downstream sync tool. For private items, name the private destination. Mark any existing shared copies for removal only as a proposed action. Wait for the user to approve the complete table before writing, moving, or deleting files.

**Done when:** the user approves a table where every item has a layer, destination, and action.

## 4. Apply the table

Apply only approved rows. Keep shared source files in Zenoforge; do not copy them into the private repo. Use a downstream sync tool only when Zenoforge documents it and the approved row names its destination.

Preserve existing content in the private home repo's `AGENTS.md`. Add or update one `## Other Repos` section with a Zenoforge entry in this form, replacing the placeholders with the user's private local path and the available practice index path:

```markdown
## Other Repos

- Zenoforge (shared skills, practices, and glossary): <local path>. Clone from https://github.com/ZenoWangzy/zenoforge if missing.
  - Skills: `<local path>/.agents/skills/`
  - Practices: `<local path>/<practice index path>`
  - Glossary: `<local path>/GLOSSARY.md`
```

If `AGENTS.md` already has an `## Other Repos` section, update it in place and keep its unrelated entries. Review the diff and confirm it contains only approved private pointers and changes. Report the table, files changed, and any shared items that remain unavailable.

Do not push by default. If the user asks to push, show the diff, branch, and remote, then ask for explicit confirmation before running `git push`. Push only after an affirmative answer.

**Done when:** every discovered item has an approved layer and action, the approved table is applied, and the private `AGENTS.md` points to Zenoforge for skills, practices, and the glossary.
