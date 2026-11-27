# Resume versus fresh repair sessions

## Question

For a rejected implementation with an eligible Codex session below 8 million raw tokens, does resuming that session improve the first repair result enough to keep repair on the resume path?

## Protocol recorded before the run

- Use the five frozen task inputs in `engine/eval/cases/end-to-end.json`, each based on a public Zenoforge issue and its known hidden check.
- Run each case twice with `--stage end-to-end --from-implement --repair-arms paired`. This gives at most 10 chains. Triage and advisor calls are outside the measured work.
- Count only complete pairs whose initial Codex implement call has known raw usage below 8,000,000. A pair exists only when the first review rejects the implementation and the resume arm has a recorded Codex session.
- Primary result: first repair pass count for cold versus resume. A pass after one repair is the observable proxy for whether the unit needs another repair round.
- Secondary results: discordant pairs, median repair tokens, and median model-call time. Unknown usage stays unknown.
- The runner performs one repair round per arm. It does not measure multi-round repair trajectories, other models, or production units.

## Decision rule

Change the repair default to fresh for the under-8M group only if there are at least four complete under-8M pairs across at least two tasks, and cold has at least two more first-repair passes than resume with the same direction visible in repeated runs. Keep the current resume cutoff if resume matches or beats cold. If the sample or effect is smaller, call the result inconclusive and keep the current cutoff.

The two-pass margin is the noise floor for this small, single-model sample. A one-pair difference does not change the default.

## Result

The run completed zero of the 10 planned chains and produced zero eligible pairs. The first implement stage was deferred by execution admission because available memory stayed below the configured 6 GiB floor; no model call started. A one-worker CPU-target retry kept that memory floor and remained deferred. This is an infrastructure-limited sample, not evidence for either repair arm.

Keep the current Codex resume cutoff of 20,000,000 raw tokens. The measured sample is below the predeclared four-pair minimum, so the result is inconclusive and does not justify changing the default.
