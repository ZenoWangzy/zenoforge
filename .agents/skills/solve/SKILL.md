---
name: solve
description: "The problem-solving chain that ask-zeno routes to: find which known problem it is, take the solution others already built, and prove it. Use through ask-zeno, or directly when the user types /solve."
---

# Solve

Assume the problem is already solved somewhere. Your job is to recognise it, find the solution, and fit it. Building something new is the last choice and needs a reason.

The person states only the intent. You run every step below. Ask only for a product or business decision that no experiment and no source can settle.

## Size the run

- **Obvious:** the cause and the fix are visible in one look, and nothing like it happened before. Fix it, prove it, stop. Skip the rest.
- **Normal:** steps 1 to 7, a few minutes of search.
- **Hard:** the problem came back, two fixes failed the same check, the design has no precedent in this repo, or a mistake cannot be undone. Full depth: at least two fields in step 3, and every source opened.

## Steps

1. **See it raw.** Start from the rawest material: the log line, the failing command, the real numbers, the person's own words. Not a summary. For a defect, get one command that goes red on this exact problem (`diagnosing-bugs`, phase 1) before any theory.
2. **Go up one level.** Say what should happen after this is done. Solve for that outcome when it is in scope, so one fix removes the class instead of the instance.
3. **Name it.** Follow `reframe`. List two or three known problems this could be. For each: the one term that names it, and the sign that separates it from the others. Check the signs against step 1 and keep the one that fits. Then replace the nouns with verbs and look at two neighbouring fields that solved the same shape of problem. Use a field for its methods, never as a role to play. Say where the analogy breaks.
4. **Find what exists.** Search in this order and stop at the first that meets the need:
   1. this repo: code, lessons, incident guards, decision records, closed issues, notes;
   2. the language, the platform, or a dependency already installed;
   3. a maintained tool, a standard, or a published pattern;
   4. a solution from a neighbouring field.

   Read primary sources: the official docs, the source code, the paper, the postmortem. Open each link and confirm it says what you claim. Cut what you cannot confirm. For each serious candidate write **adopt**, **adapt** or **reject**, with the one reason. **Build** only when every candidate fails a requirement you can name.
5. **Go deeper, not bigger.** Follow `sharpen` on your own task: what a top professional would do here, their raw material, their methods and tools, and what other than you would show the result is right. Rewrite the task to ask for exactly that. If a choice can be settled by running something, run it.
6. **Do it.** Take the chain from `ask-zeno`. Make it work, then make it right.
7. **Prove it, then close the door.** The judge is not you: the red command now green, the real system, a metric, an independent reviewer. Then make the same problem impossible or loud: a type, a test, a lint, a gate. Text alone is not a guard. If the guard already existed, find out why it did not fire.

## Routing

`ask-zeno` (`../ask-zeno/SKILL.md`) holds every route. Step 6 takes its chain from there. The three sources have one job each, so they do not compete:

- **Matt skills** own the process: what happens in which order, and the spec, ticket and review formats.
- **pstack** owns judgement: `reframe` and `sharpen` before the work, principles and playbooks inside it.
- **ub-mode** owns the order of one code change: make it work, then make it right, then practice. Skip its Crapper, Dryer and Mutator steps where the tool does not exist for the language, and its push step where the repository has its own landing path.

When they differ, the order is: the owner's rules and the repository's instructions, then this file, then Matt skills, then pstack, then ub-mode.

## Where the skill files are

Read a named skill as a file. Several of them refuse to be invoked as a command, and reading is enough. `../ask-zeno/SKILL.md`, "Where the files are", gives the paths. If a file is missing, follow the sentence about it here and say so.

Do not start agents, change models, or widen the scope because one of these files says so. The host's rules decide that.

## Record

Leave a record for every normal or hard run, in the place the caller already uses (a report section, a research file, the reply). Use these headings so any gate can read it:

- **Classic variant:** the known problem, and the sign that told it apart from the other candidates.
- **Experts:** two or three people or sources that own this problem, with links.
- **Mental model:** how to think about it, applied to this case.
- **Mature solutions:** each candidate with adopt, adapt or reject and the reason.
- **Community practice:** what others do in production, with links, and which one is used here.
- **Decision:** what was chosen, and for a build, the requirement every candidate failed.
- **Proof:** the outside judge, the command, and its output before and after.
- **Guard:** what stops it from coming back.

In a report that has a `## prior-art` section, put Classic variant through Decision inside it. Root cause, proof and guard stay in their own sections.

Without network access, do steps 1 to 3 and the first two searches of step 4, write `not searched online`, and never invent a source.
