# Pipeline evaluation suite

A frozen task suite for changing one pipeline decision at a time. Run the same
cases before and after a change, twice by default, then inspect regressions and
inconsistency. This is an evaluation suite, not an observation window. It does
not change the pipeline architecture or write to GitHub.

Run on WSL with each selected `codex`/`zcode` CLI installed; the runner checks this before starting cases.

## Tooling choice

Checked the existing replay scripts (`failure-triage-replay.mjs` and
`main-ci-red-replay.mjs`), root dependencies, and Promptfoo's
[exec providers](https://www.promptfoo.dev/docs/providers/custom-script/) and
[repeat configuration](https://www.promptfoo.dev/docs/configuration/reference/).
Promptfoo provides repetition, but would still need our shell provider, frozen
Git worktrees, fix-test injection, and paired case/run comparison. It is not an
existing dependency. A small dependency-free Node runner therefore removes the
extra provider/config/result translation layer. The runner follows the replay
tools' explicit unknown usage, pinned Git evidence and pure grading/comparison
functions; model execution reuses `lib.sh`'s lower seams, not the GitHub-writing
stage wrappers.

## Run

```bash
# Default: every stage's cases, each twice. The supervisor baseline command below runs once.
node engine/eval/run-eval.mjs --label baseline

# One stage or selected IDs (comma-separated), with a distinct experiment label.
node engine/eval/run-eval.mjs --stage triage --runs 2 --label triage-before
node engine/eval/run-eval.mjs --stage triage --case zf-4186 --runs 1 --label proof
node engine/eval/run-eval.mjs --stage implement --label repair-after
node engine/eval/run-eval.mjs --compare triage-before triage-after

# Historical supervisor arbiter baseline: one call per action, with concurrent case execution.
node engine/eval/run-eval.mjs --stage supervisor --runs 1 --concurrency 8 --label supervisor-arbiter-baseline
node engine/eval/run-eval.mjs --compare supervisor-arbiter-baseline supervisor-arbiter-baseline

# Inner loop: failing cases only, in parallel; fill an interrupted label; then one full run.
node engine/eval/run-eval.mjs --stage review --case zf-4181,zf-4026 --runs 1 --concurrency 3 --label fix-wip
node engine/eval/run-eval.mjs --stage review --runs 2 --concurrency 3 --resume --label fix-wip

# Check corpus test discrimination without any models: broken base red, fix green.
node engine/eval/run-eval.mjs --stage implement --verify-gold --runs 1 --label gold-check

# Unit/fixture tests: no models, external APIs or production services.
node --test engine/eval/*.test.mjs
```

`--case` runs only the listed case ids of each stage's set (unknown ids fail the
run instead of silently producing a smaller label); `--cases` is the same
option and also accepts a JSON case-set file, with `--stage` matching its
stage. `--concurrency N` (default 1) runs up to N case/run attempts in
parallel; every stage call keeps the pipeline's execution-admission capacity
gate, which is what bounds actual machine load. `--resume` continues an
existing label: finished case/runs are kept exactly as recorded (never rerun
or rewritten) and only missing ones run, appending to `results.json`. Use it
after an interrupted run, e.g. a WSL restart.

The default model/effort/tier policy is the current checkout's
`model-policy.default.json`. `--policy /absolute/path/to/model-policy.json`
selects an explicit experimental policy; `--override ROLE=provider:model[:effort[:tier]]`
(repeatable) rewrites roles in a copy of the chosen policy for a quick backend/model
comparison, e.g. `--override review=zcode:GLM-5.3:max`. Either way the policy is copied into the run's isolated agent
home and recorded in results. The existing non-secret capacity.env is also
carried into that home so isolation does not change execution admission. Each invocation uses the same
policy resolver and execution admission as the pipeline. No fallback model is
invented. A resource refusal is a failed execution with unknown tokens, not a
model verdict. Labels cannot overwrite prior results.

Every call and row records the `provider:model:effort` identity that actually ran
(`calls[].identity`, `identities`), resolved the way the pipeline resolves it:
triage/recut and implement by dispatch state, advisor by its role, review by
`review_model_for_implementer` (cross-provider review role, or the documented
same-provider fallback). Review dispatches by that provider (codex or zcode).

Outputs are `~/.zenoforge/eval/<label>/results.json`, with one row per
stage/case/run: pass/fail and reasons, individual call usage/time, summed usage
(or `null` if any call has unknown usage), total and model wall time and artifact locations.
Prompt, output, stderr, worker log, candidate diff and hidden-check logs stay
with the run. Comparison prints pass→fail **first**, totals, fail→pass,
unpaired case/runs, and mixed pass/fail cases within each label. Compare the
same selected cases and repeat count; missing cases are never treated as flips.
`--compare` also works on labels that hold only some cases (an inner-loop
label, or one finished with `--resume`): only case/runs present in both labels
are compared, the rest stay unpaired, and the `compared in both labels:` line
lists exactly which ids the verdict covers.

Each case uses a private bare repository that shares the source object store
through `objects/info/alternates` but copies no refs, with isolated worker and
grader worktrees inside the result directory. Its only ref is `origin/main` at
the frozen base, so `git log --all` or `git show main:<file>` in a case checkout
cannot reach the known fix or its tests. No shared clone refs are changed. Temporary files
live under eval; hidden fixtures use a short eval/t-* parent to fit Unix socket
path limits. The historical test-env helper is relocated there instead of
WSL `/tmp`. Only evaluator-owned
worktrees are removed, after their artifacts are saved.

Prepare dependencies using the historical lockfile. The two package cases and
the YAML workflow case declare offline pnpm setup commands; warm the pnpm
cache first if required. Missing dependencies fail the run and remain visible
in hidden logs. No Docker, database, production or host operation is required.

## Inner loop

Iterating on a prompt or contract change does not re-run the whole serial
suite at every step:

1. While iterating, run only the failing cases: `--case <ids> --runs 1`, with
   `--concurrency N` when the machine has headroom. One attempt per
   case/run, in worker threads, so nothing about a single chain changes.
2. If a run is interrupted (e.g. WSL restart), continue the same label with
   `--resume` instead of discarding finished results.
3. On the final version, run the full suite once (the default `--runs 2`) and
   `--compare` it against the last accepted label.

## Paired repair arms

```bash
node engine/eval/run-eval.mjs --stage end-to-end --runs 2 --repair-arms paired --label repair-paired
# Start at a ready ticket (no triage/advisor calls) when only a downstream decision is measured:
node engine/eval/run-eval.mjs --stage end-to-end --from-implement --runs 2 --repair-arms paired --label repair-paired
node engine/eval/run-eval.mjs --compare-arms repair-paired
```

This measures whether resuming the implementer's session helps repair a rejected
end-to-end implementation. Each rejection forks the same implementation diff
(including committed and untracked changes): cold repair runs in a copy, while
resume repair runs in the original checkout with the same prompt, resolved
provider/model/effort, and timeout. Codex implement calls persist their session
and record the `thread.started` id; other providers record `null`. Resume is
skipped with a reason when the provider has no resume support (currently only
Codex is supported) or no session was recorded. The historical standalone repair
cases have no implementer session and are unaffected.

A resumed Codex thread reports cumulative usage, so the resume arm's tokens are its log total minus the
implementer's tokens (unknown if either is unknown); both arms then count only the repair. The first end-to-end
implement call of every run, paired or not, uses the persistent `codex exec --json` invocation (no `--ephemeral`) so
its session can be recorded; the unpaired repair call is unchanged.

Both arms use the chain's hidden tests and record `pass`, `reasons`, `tokens`,
`wall_ms` (model call time), and `identity` in `repair_arms`. The chain's result,
`calls`, and token/model-time totals follow cold; overall elapsed time includes
both arms and grading. Without `--repair-arms paired`, repair remains cold.
Comparison reports chains with arms, executed/skipped counts, passes, discordant
pairs, and median/summed call tokens and time per arm. Skips are excluded from
paired verdicts and resource summaries; any unknown usage keeps that arm's token
median and sum unknown.

## Prompts and grading

* **Triage:** current `triage.md` and `triage.schema.json`, phase and index
  freshness header, frozen issue JSON and frozen no-open-PR intake. Compare
  category, state, risk, level, entry surface, acceptor, and package set
  exactly; package order is immaterial. For a required external deliverable,
  require the same target path and a nonempty reason while allowing equivalent
  wording. When no external work is required, compare all three fields exactly.
  The raw schema's ready-for-human spelling maps to the wrapper's
  needs-advisor route; it does not mean a human needs to implement the ticket. The graph is explicitly unconfirmed for historical
  code. Gold annotations use recorded classifications where applicable and the current
  risk rules (1417 is adjudicated P2 for persisted draft/history writes), plus the
  known delivered scope under the risk/level tables otherwise. Triage size
  measurements are described in [Triage size estimation](#triage-size-estimation).

* **Advisor:** `advisor.md` and `advisor.schema.json`; short required-fact
  rubrics with explicit aliases, all facts required, no model judge. Two cases
  use `advisor-batch.md` + `advisor.md` and the existing raw web batch seam with
  a frozen one-ticket manifest. This exercises both prompt variants without
  applying labels, comments, emails or state transitions.
* **Implement/repair:** current `implement-contract.md`; four cases start from the
  pre-fix implementation with the recorded CI failure text. A case with a
  `decisionLog` (unit history entries carrying scheduler/advisor decisions)
  gets the scheduler's own `decision_scope` pickup section rendered into the
  prompt, so pickup re-dispatches are measured as the pipeline sends them. Their earlier
  originating commit is retained separately. Capture the entire diff against
  base, including commits and untracked files, apply it in the grader worktree,
  overwrite tests with the known fix's test blobs, and run those tests. Worker
  tests cannot replace the hidden check. Setup failure and timeout cannot pass.
  Two premise-verification cases carry `expected.outcome` instead of only
  hidden tests: an optimization ticket whose quantified claim no longer
  reproduces from the frozen data must close itself (first line
  `OBSOLETE: <measured numbers>`, no implementing diff), while one whose
  numbers reproduce must implement and pass the fix's hidden tests
  (`gradeImplementDecision` in `graders.mjs`). `--verify-gold` on the close
  case checks the grader discriminates; it has no diff-level gold.
* **Review:** the Matt `code-review` skill (`.agents/skills/code-review/SKILL.md`)
  with `review-contract.md`, the
  original issue and fixed local base/head. The implementer report is optional.
  The grader reads the canonical `review-findings` object and requires a known
  blocking defect to be attributed to the candidate with base evidence.
* **End-to-end:** triage → advisor when unresolved/high risk → recut when asked
  → implement → independent review → one repair/re-review when rejected. Final
  diff is graded with the same hidden tests. No merge/release/external actions.
  Successful recuts carry the child acceptance bodies into implementation;
  this suite evaluates the final repository outcome, not issue creation.

### Triage size estimation

Each triage result with a frozen `source.fixSha` records `size_estimate`: the
model estimate, actual additions plus deletions at the frozen fix, signed
difference, absolute error, and percentage error. Actual size uses the
scheduler's admission exclusions (Markdown/docs, generated files, lockfiles,
and snapshots); these values are measurements, not triage verdict gates.

The historical issue/PR text, selected source comments (including review
history where it supports a finding and author disposition), full base/fix
SHAs, source URL, failure evidence and expectations are in each set. Review
history is stored inside `issue` so the reviewer receives it; source records
and grading expectations are never appended separately. GitHub userContentEdits was checked: intake bodies are unedited except
PR 4181, whose retained last edit precedes its frozen implementation base.
The negative review of PR 3209 also uses a body last edited before its pinned
review head.
The edit count/date is retained in source.textVersion.
NOT_READY cases are retrospective defects proved by subsequent merged fixes,
not fabricated historical reviewer verdicts. No credentials or additional
customer records are included.

The guard-retirement case's original fix changes only a registry. Its hidden
check is the immutable `run-ci-suites.sh` admission prefix through the guard
suite validation, stopping before any suite execution; this reproduces the
actual failure without running a full CI shard. The completion-parser case runs the original report-completion regression
block plus the original closed-queue-row regression block, avoiding unrelated
old scheduler and admission-cadence fixtures.
Other cases use the merged fix's own tests. Gold verification should accompany additions to the corpus.

## Add a case

1. Choose a resolved issue or merged PR; retain the intake title/body and only
   comments known before the base, plus source URL and immutable base/fix SHA.
   Strip secrets and avoid copying any additional customer materials.
2. Add a record to the relevant set. Annotate exact triage fields, short advisor
   facts/aliases, or the known review verdict and defect file. For a repair,
   retain the failed implementation SHA, CI/review failure text and its source.
3. For implementation, name the fix's own test blobs and focused commands in
   `hidden`. Declare dependency setup separately. Run `--verify-gold` on that
   ID: broken base must fail and the known fix must pass. Do not show these
   tests or expected facts in model prompts.
4. A review case whose `headSha` is not on main (a PR head) needs a kept ref, because the PR branch gets deleted:
   `git push origin <headSha>:refs/heads/eval-pins/<case-id>-head`, then set `source.pinRef` to
   `eval-pins/<case-id>-head`. The fixture test enforces it.
5. Run the fixture tests and keep IDs stable across experiments. A new or
   removed case is printed as unpaired by compare, never counted as a flip.
   `decision-gate.mjs` therefore accepts an earlier baseline that lacks
   newly added cases (they run in the candidate and stay unpaired); a
   baseline holding removed cases still fails the gate.
