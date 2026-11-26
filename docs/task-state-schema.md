# Task state schema

The task store lives at `$AGENT_HOME/task-state/<task id>/`. Each task has one current `task.json` record and an `events.jsonl` history. Records use `schema_version: 1`; readers refuse other versions. Unknown fields are additive and ignored.

`task.json` contains `id`, `goal`, `done_when`, `owner`, `stage`, `blocker`, and `next_step`. A task is active until its stage is `done` or `cancelled`. The event log contains `handoff` records (`from`, `to`, `reason`, `next_step`) and `decision` records (`decision`, `by`, `why`); event order is append order.

Run `node engine/task-state.mjs resume "$AGENT_HOME/task-state"` to print the active tasks with their latest handoff and decision. An empty store prints `No active tasks.`. `engine/bin/luna` runs this command for each new session and prepends the result to the agent prompt, so recovery does not depend on a previous session id.
