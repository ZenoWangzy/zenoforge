# The orchestrator is deterministic code, not an agent
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** The issue loop and the unit loop are Bash, Node and Python scripts that decide, start detached workers and exit; agent CLIs run only inside those workers.
> **Do not:** block a tick on an agent model call; let an agent session run the scheduler's loop in the foreground; move the stage chain's control flow into a prompt
> **Rejected:** none stated
> **Terms:** issue loop, unit loop, tick, detached worker, stage chain

Both loops are plain Bash, Node and Python scripts, started by systemd timers or by hand. Neither loop runs an agent in the foreground. A tick reads GitHub labels and the per-issue state, decides what should happen next, starts detached workers and exits. The next tick reads what the workers left behind. The issue-pipeline header says it "only ever decides, it never blocks on an agent model call."

Model calls happen inside workers. The scripts read their verdicts (for example the triage route or an advisor verdict) and act on them in code, under the transition table in `engine/lib.sh`. The product positions Zenoforge as the factory around the agent CLIs, not as one more coding agent.

## Consequences
- A tick finishes in bounded time, so a stuck model call cannot stop the scheduler.
- New stages are scripts plus a detached unit, not a long-running agent session.
- Recovery depends on state on disk and in GitHub labels, so a restarted tick rereads it rather than resuming a conversation.

Sources: docs/architecture.md#at-a-glance, docs/architecture.md#11-issue-loop, docs/architecture.md#2-stage-chain-and-labels, README.md#how-it-works, README.md#why-zenoforge
