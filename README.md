# Zenoforge

A self-hosted software factory: coding agents take GitHub issues through triage, implementation, review, CI repair and merge. Some tickets are routed to a person, and the maintainer gets mail for decisions.

> **Status: alpha.** Zenoforge was extracted from the pipeline that builds a production product, where it lands dozens of agent-written changes a day. The engine is real and running; the packaging for other repositories is new. Expect rough edges and Bash.
>
> Parts of the project are in Chinese: the dashboard UI, the maintainer mail, some worker prompt modules (for example `engine/factory/common.md`), and many code comments and strings. About 50 of the 230 non-test files under `engine/` and `tools/` contain Chinese text. English translation is planned.

## What it does

- **Issue to merge.** Issues move through a fixed stage chain: triage, recut, implement, self-check, review, repair, and merge. Review is meant to use a different model provider from the implementer; when none is available, the fallback is recorded. GitHub labels carry the state.
- **Quota-aware workers.** One worker interface over two coding-agent CLIs, Codex and ZCode. The shipped unit-loop config uses Claude for review. Circuit breakers, failover, and escalation to a stronger model after repeated failures.
- **Capacity admission.** Workers start only when CPU and memory allow, so the host is not overloaded.
- **Safe merging.** Merges pin the reviewed head SHA and go through a serial merge queue. When main goes red, the engine searches for the culprit commit and reverts it automatically.
- **Health and cost.** A node health scorecard with healthy and unhealthy bounds, a dashboard, and per-ticket cost and CI-spend accounting.
- **Learning loop.** Incidents can become lessons in the target repository, and the engine can generate enforcement checks from them.

## What is not included

The release, acceptance and advisor stages are not shipped. Their runners (for example `engine/run-release.sh`) are absent, and the advisor provider does not ship. The stage chain therefore ends at merge.

## Layout

```
engine/            the pipeline engine
  mac-autopilot/   unit loop: scheduler, bell (anomaly scan), dashboard, node health
  night/           maintenance, dispatch, health mail
  hotfix/          hotfix lane
  prompts/         stage prompts and output schemas
  bin/             worker wrappers (worker, luna, zc, terra, lw, ...)
  factory/         work-queue feeder and launcher
  eval/            evaluation harness (no case files in this checkout)
tools/             repository tooling (test runner)
```

The issue loop runs from systemd user timers: `engine/run-tick.sh` every 5 minutes, with units in `engine/systemd/`. The unit loop, `engine/mac-autopilot/loop.sh` every 2 minutes, is started by `engine/mac-autopilot/start.sh`. This repository ships no systemd units for it.

## Documentation

- [Architecture](docs/architecture.md): the loops, stage chain, workers, merging and state.
- [Installing on one host](docs/install.md): requirements, configuration, systemd units, and what is not generic yet.
- [Security](SECURITY.md): read the threat model before you run it. Agents run unsandboxed and act on issue text.

## Running the tests

```
bash tools/run-engine-tests.sh          # all suites
bash tools/run-engine-tests.sh 0 8      # shard 0 of 8
```

## License

Zenoforge is **source-available**, not OSI open source. It is free for personal, noncommercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE). Commercial use requires a commercial license from the maintainer.

To ask about a commercial license, open a GitHub issue titled "Commercial license" in [ZenoWangzy/zenoforge](https://github.com/ZenoWangzy/zenoforge/issues), or contact the maintainer through the maintainer's [GitHub profile](https://github.com/ZenoWangzy). The end of [LICENSE](LICENSE) gives the same instructions.

Contributions are welcome under the [Contributor License Agreement](CLA.md); see [CONTRIBUTING.md](CONTRIBUTING.md).
