---
name: ask-zeno
description: "The router over every skill in this repo: Matt skills, pstack, ub-mode and the solve flow. Picks the one skill or the chain that fits, then runs it. Use first for any request that is not a plain question or a one-look edit: a problem, an alert, an idea, a feature, a design, a review, a refactor, research, writing, a handoff; when unsure which skill fits; or when the user types /ask-zeno."
---

# Ask Zeno

The person states only the intent. You pick the route, say it in one line, and run it:

`Route: reframe, sharpen, diagnosing-bugs, tdd. Reason: the same alert came back twice.`

## Rules

1. Take the shortest chain that reaches the outcome. One skill beats a chain. No skill beats a skill that adds nothing: answer a plain question, make a one-look edit.
2. Read a skill's `SKILL.md` before you use it or skip it. The lines here are only for choosing. Several skills refuse to be invoked as a command; reading the file is enough.
3. Do not ask the person which skill to use. Ask only for a product or business decision that no source and no experiment can settle.
4. Change route when the evidence says so, and say the new route in one line.
5. Order of authority: the owner's rules and the repository's instructions, then this file, then the skill. The host decides about agents, models, cost, landing and pushing. A skill that says otherwise does not change that.

## Step 1: which situation

Stop at the first line that fits.

| The situation | Chain |
| --- | --- |
| The same problem came back, or two fixes failed the same check | **Fix**, starting at `principle-attack-the-premise` |
| The person cannot name what they want, or asks which classic problem or best practice applies | **Name** |
| Something is broken, red, slow, costly, or an alert fired | **Fix** |
| A spec or ticket already exists | **Deliver** |
| A change is ready to judge | **Judge** |
| Raw issues or requests are piling up | **Intake** |
| Work too big for one session, and the way is not visible | **Chart** |
| The code works and should be easier to change | **Reshape** |
| Understand code, a decision, or a subject | **Understand** |
| A document, an article, a message | **Write** |
| Stop, resume, hand over, catch up | **Continue** |
| Make the agents or the repo better | **Improve** |
| Any other idea or request to build | **Build** |

## Step 2: the chains

Skills in order. A skill in brackets is used only when its condition holds.

- **Name:** `solve` steps 1 to 5, which run `reframe` then `sharpen`. Then return to step 1 with the new words. This is also the way in when a problem has no precedent in this repo.
- **Fix:** `solve`, with `diagnosing-bugs` for the red command, `principle-fix-root-causes` for the cause, `tdd` for the regression test, `correct` so it cannot return, `retro` when it went badly. [a number is the symptom: `principle-explain-the-number`, `benchmark-checklist`] [crash, retry, race or duplicate work: `principle-make-operations-idempotent`, `statechart`] [risky paths: `blast-radius`].
- **Build:** [no precedent: **Name** first] `grill-with-docs`, `to-spec`, `to-tickets`, then **Deliver**. [no working directory: `grill-me`] [a choice you can settle by running it: `prototype`] [the answer is in someone else's head: `to-questionnaire`] [types and module shape matter: `architect` with `codebase-design`]. When nobody is there to interview, decide from evidence and write the decision down.
- **Deliver:** `implement` per ticket, or `implement-spec` for a whole spec. Inside each change: `tdd`, in the order of `ub-mode` (make it work, make it right, practice), with `typescript-best-practices` for TypeScript. Then **Judge**, then `pr`.
- **Chart:** `wayfinder`, then **Build** at `to-spec`. [unattended, needs an audit trail: `figure-it-out` with `show-me-your-work`].
- **Intake:** `triage`, then **Deliver**. Tickets from `to-tickets` skip triage.
- **Reshape:** `improve-codebase-architecture`, `codebase-design`, `principle-subtract-before-you-add`, then `to-spec` or `implement`. [comments to remove: `delete-comment`].
- **Judge:** `code-review` against a fixed point. [it can break something far away: `blast-radius`] [contested or high stakes: `interrogate`] [it must work for a user: the project's own verification skill, or `create-verification-skill`] [a bug there costs most and tests reach least: `create-formal-verification-skill`].
- **Understand:** code today: `how`. Why it is so: `why`. Both, explained to a person: pstack `teach`. A subject over several sessions: Matt `teach`. Outside sources: `research`. The words themselves: `domain-modeling`.
- **Write:** for agents: `writing-for-agents`. Docs, PRs and commits: `technical-writing`. A PR body: `pr`. An article: `writing-fragments` to collect, then `writing-beats` or `writing-shape`. Any prose at the end: `unslop`.
- **Continue:** to another agent or place: `handoff`, or `claude-handoff` to start a background agent now. Find my own context again: `recall`. Tell the person what changed: `ketchup`, or `ketchup-video`. They did not understand: `wait-what` with the missing context, or `bro` for plain words. Check that you understood them: `in-your-own-words`.
- **Improve:** this session: `retro` for the environment, `reflect` for the skills. Mistakes that repeat: `correct`. The person's own style: `automate-me`. Verification that drifted: `maintain-verification-skill`, `maintain-formal-verification-skill`. A factory: `software-factory`. A workflow spec: `loop-me`.

## Step 3: when two skills look alike

| Choice | Rule |
| --- | --- |
| `tdd` (Matt or pstack) | Matt's. It owns the process. |
| `teach` (Matt or pstack) | A person learning a subject: Matt. Explaining a body of work: pstack. |
| `grilling` or `interrogate` | A person's plan: `grilling`. An agent's code or design: `interrogate`. |
| `prototype` or `arena` | One question: `prototype`. Competing full attempts: `arena`, only when the host allows the agents. |
| `architect` or `codebase-design` | Sketch this change: `architect`. The vocabulary for module depth: `codebase-design`. |
| `research` or `solve` | A topic to read up on: `research`. A problem to end: `solve`. |
| `no-comments` or `delete-comment` | `delete-comment`. `no-comments` starts an agent. |
| `swarm`, `arena`, `chief-of-staff` | They start agents. Use them only when the host's rules allow it. |
| `poteto-mode` or `ask-matt` | Detail maps of one family. Read `ask-matt` for Matt phases, and `poteto-mode` for its playbooks and principles. `poteto-help` explains pstack. |

`poteto-mode` playbooks fill the gaps: Hillclimb (move a metric), Runtime forensics and Trace forensics (read a live process or a trace), Visual parity, Eval, Session pickup, Pause safely, Worktree cleanup. Read `playbooks/<title>.md` beside its `SKILL.md`. Principles are `principle-<name>`; read the leaf before you cite it.

## Step 4: who is asking

- **A person in a session:** run the route. Show the route line, then the result.
- **A supervisor with an alert or an anomaly:** **Fix**. Leave the `solve` record in the research file. The owner of the row is the owner of the guard.
- **A factory worker:** the stage already chose the process, so use this file only for a problem inside the stage. Nobody answers, so skip every step that interviews, starts an agent, publishes or pushes. Put the record in the report.

## Setup and special tools

Use only when the task is exactly this: `setup-matt-pocock-skills`, `setup-pstack`, `setup-pre-commit`, `setup-ts-deep-modules`, `git-guardrails-claude-code`, `migrate-to-shoehorn`, `scaffold-exercises`, `wizard` (steps only a person can do), `make-bot-ui`.

Skills outside this repo (browser, charts, documents, an assistant's own commands) stay available. Choose them by their description, at the step that needs them.

## Where the files are

A prompt that gives paths wins. Otherwise start from the real path of this file, with symlinks resolved:

- Matt skills, `solve` and `delete-comment`: `../<name>/SKILL.md`
- pstack: `../../../engine/vendor/pstack/skills/<name>/SKILL.md`
- ub-mode: `../../../engine/vendor/ub-mode/SKILL.md`

If a file is missing, say so and follow its line here.
