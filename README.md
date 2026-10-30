# Zenoforge

A self-hosted software factory: coding agents take GitHub issues through triage, implementation, review, CI repair and merge. Some tickets are routed to a person, and the maintainer gets mail for decisions.

## Quickstart

You need Node 20+, `git`, the GitHub CLI (`gh auth login` done), `jq`, `python3`, `bash` 4+, and at least one coding-agent CLI (`codex`, `claude` or `zcode`). Linux, WSL2 and macOS work; Windows needs WSL2. `zenoforge doctor` checks all of this and prints the exact fix command for anything missing.

```
npx zenoforge doctor        # check the host first
npx zenoforge init          # guided setup for one repository
```

`pnpm dlx zenoforge init` and `npm i -g zenoforge && zenoforge init` do the same thing. `init` asks which repository to use and which agent does which job, then:

- clones a **dedicated checkout** of the repository (the engine resets and cleans it every tick, so it never touches your working copy);
- installs the engine to `~/.zenoforge/engine/<version>/` and links it into that checkout (`zenoforge upgrade` and `zenoforge rollback` flip a `current` link, so nothing points into the npx cache);
- writes `~/.zenoforge/env` and `capacity.env` (mode 600) with safe defaults: 2 workers, advisor off, no mail recipients, auto-merge only when your branch protection names required checks (or you pass `--auto-merge`);
- creates the pipeline's GitHub labels and sets `AGENT_SUPERVISOR=observe` and `AGENT_PIPELINE=triage` on the repository (`off` with `--no-scheduler`);
- installs systemd user units (Linux, WSL2) or LaunchAgents (macOS), after you confirm the security warning below. With neither available it prints how to run in the foreground.

```
zenoforge status            # scheduler, engine version, pipeline switches
zenoforge logs -f           # follow the engine logs
zenoforge stop              # switch the scheduler off (zenoforge start switches it on)
zenoforge upgrade           # install the engine of the newer package you just ran
zenoforge rollback          # back to the previous engine version
zenoforge uninstall         # remove the units; add --purge to delete ~/.zenoforge too
```

Then label an issue `needs-triage` to hand it to the factory. For scripts and CI: `zenoforge init --repo owner/name --yes`, plus `--checkout-dir`, `--implement`, `--review`, `--max-workers`, `--required-check`, `--no-scheduler`. `--dry-run` prints every file it would write and every command it would run, and changes nothing. [docs/install.md](docs/install.md) explains each step and the manual path.

**Before you run `init`, read [SECURITY.md](SECURITY.md).** In plain words: the agents run unsandboxed with your user's permissions and your `gh` login, text in issues is untrusted input that can steer them, and merges happen automatically once review and required checks pass. Use a dedicated OS account (or a machine you can rebuild), a dedicated GitHub account or fine-grained token, and a repository where only people you trust can file issues. `init` asks you to confirm this (or pass `--yes`) before it switches anything on.

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
cli/               the `zenoforge` command (installer and operator CLI), tests in cli/*.test.mjs
```

The issue loop runs from systemd user timers: `engine/run-tick.sh` every 5 minutes, with units in `engine/systemd/`. The unit loop, `engine/mac-autopilot/loop.sh` every 2 minutes, is started by `engine/mac-autopilot/start.sh`. The engine ships no units for it; `zenoforge init` generates them.

## Documentation

- [Architecture](docs/architecture.md): the loops, stage chain, workers, merging and state.
- [Installing on one host](docs/install.md): what `zenoforge init` does step by step, the manual path, configuration, systemd units, and what is not generic yet.
- [Security](SECURITY.md): read the threat model before you run it. Agents run unsandboxed and act on issue text.

## Running the tests

```
bash tools/run-engine-tests.sh          # all engine suites
bash tools/run-engine-tests.sh 0 8      # shard 0 of 8
node --test cli/*.test.mjs              # the zenoforge CLI
```

## License

Zenoforge is **source-available**, not OSI open source. It is free for personal, noncommercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE). Commercial use requires a commercial license from the maintainer.

To ask about a commercial license, open a GitHub issue titled "Commercial license" in [ZenoWangzy/zenoforge](https://github.com/ZenoWangzy/zenoforge/issues), or contact the maintainer through the maintainer's [GitHub profile](https://github.com/ZenoWangzy). The end of [LICENSE](LICENSE) gives the same instructions.

Contributions are welcome under the [Contributor License Agreement](CLA.md); see [CONTRIBUTING.md](CONTRIBUTING.md).
