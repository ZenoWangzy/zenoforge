<h1 align="center">Zenoforge</h1>

<p align="center">A self-hosted software factory. Coding agents take your GitHub issues through triage, implementation, review, CI repair and merge, and it is built to run unattended.</p>

<p align="center">
  <a href="https://github.com/ZenoWangzy/zenoforge/actions/workflows/engine-tests.yml"><img alt="engine-tests" src="https://github.com/ZenoWangzy/zenoforge/actions/workflows/engine-tests.yml/badge.svg?branch=main"></a>
  <a href="LICENSE"><img alt="License: PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue"></a>
  <img alt="Status: alpha" src="https://img.shields.io/badge/status-alpha-orange">
</p>

<p align="center"><a href="#quickstart">Quickstart</a> · <a href="#how-it-works">How it works</a> · <a href="#what-it-does">What it does</a> · <a href="#before-you-run-it">Security</a> · <a href="#documentation">Docs</a></p>

Zenoforge runs the coding-agent CLIs you already have (`codex`, `claude`, `zcode`) against one GitHub repository. Labels on an issue carry it through a fixed chain of stages, and the engine reviews, repairs and merges the result. The goal is a factory that runs unattended and heals itself. Today some tickets are still routed to a person, which is a gap to remove, and the maintainer gets mail for decisions.

## Quickstart

You need Node 20+, `git`, the GitHub CLI (`gh auth login` done), `jq`, `python3`, `bash` 4+, and at least one coding-agent CLI (`codex`, `claude` or `zcode`). Linux, WSL2 and macOS work (on macOS the CLI installs the unit loop only, see [docs/install.md](docs/install.md)); Windows needs WSL2.

```bash
npx github:ZenoWangzy/zenoforge doctor   # check the host first
npx github:ZenoWangzy/zenoforge init     # guided setup for one repository
```

`doctor` prints one line per requirement, and the exact fix command for anything missing:

```
PASS  node >= 20 (found 22.23.2)
PASS  gh installed
...
All required items present.
```

`init` asks which repository to use and which agent does which job. It then creates a dedicated checkout, installs the engine under `~/.zenoforge/`, writes the config with safe defaults (2 workers, auto-merge only when your branch protection names required checks) and sets up the scheduler. [docs/install.md](docs/install.md) lists every step and the manual path.

Then label an issue `needs-triage` to hand it to the factory. `init` does not put `zenoforge` on your PATH, so run the operator commands through `npx` as well:

```bash
npx github:ZenoWangzy/zenoforge status      # scheduler, engine version, pipeline switches
npx github:ZenoWangzy/zenoforge logs -f     # follow the engine logs
npx github:ZenoWangzy/zenoforge stop        # scheduler off (start switches it on)
npx github:ZenoWangzy/zenoforge rollback    # back to the previous engine version
```

`upgrade` and `uninstall` (`--purge` also deletes `~/.zenoforge`) work the same way. For scripts and CI, use `init --repo owner/name --yes`; `--dry-run` prints every file it would write and every command it would run, and changes nothing.

## Before you run it

> [!WARNING]
> The agents run **unsandboxed**, with your user's permissions and your `gh` login. Text in issues is **untrusted input** that can steer them. Changes that pass review and required checks are **merged automatically**.
>
> Use a dedicated OS account (or a machine you can rebuild), a dedicated GitHub account or a fine-grained token, and a repository where only people you trust can file issues. `init` asks you to confirm this (or pass `--yes`) before it switches anything on. Read [SECURITY.md](SECURITY.md) first.

## How it works

```mermaid
flowchart LR
  A[needs-triage] --> B[triage]
  B --> C[implement]
  B --> D[recut]
  D -->|child issues| C
  C --> E[PR]
  E --> F[review]
  F --> G[repair]
  G --> H[merge]
  H -->|main goes red| I[main-red-bisect]
  I -->|revert PR| H
```

Two loops share GitHub labels and per-issue state. The issue loop (`engine/run-tick.sh`, every 5 minutes) decides stage changes and never merges. The unit loop (`engine/mac-autopilot/loop.sh`) runs the workers and owns the serial merge queue. A tick only decides and starts detached workers, then exits; the next tick reads what they left behind. See [docs/architecture.md](docs/architecture.md).

## What it does

- **Takes an issue to a merge.** Issues move through a fixed stage chain: triage, recut, implement, self-check, review, repair, and merge. GitHub labels carry the state.
- **Uses Matt Pocock's skills as its method.** Every stage follows [Matt Pocock's skills](https://github.com/mattpocock/skills), entered through `ask-matt`: triage, to-tickets, implement with tdd, diagnosing-bugs, code-review. They are vendored byte-identical under `.agents/skills/` and stay MIT ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)); see [Architecture](docs/architecture.md#23-method-matt-skills).
- **Reviews across providers.** Review is meant to use a different model provider from the implementer; when none is available, the fallback is recorded. The shipped unit-loop config uses Claude for review.
- **Keeps working when a quota runs out.** One worker interface over two coding-agent CLIs, Codex and ZCode, with circuit breakers, failover, and escalation to a stronger model after repeated failures.
- **Starts work only when the host can take it.** Capacity admission checks CPU and memory before a worker starts, so the host is not overloaded.
- **Merges one reviewed commit at a time.** Merges pin the reviewed head SHA and go through a serial merge queue. When main goes red, the engine searches for the culprit commit and reverts it automatically.
- **Reports health and cost.** A node health scorecard with healthy and unhealthy bounds, a dashboard, and per-ticket cost and CI-spend accounting.
- **Learns from incidents.** Incidents can become lessons in the target repository, and the engine can generate enforcement checks from them.

## Why Zenoforge

Zenoforge is not another coding agent. It is the factory around the agent CLIs you already run: work units dispatched under capacity limits, review by a second provider where one is available, a serial merge queue, and automatic culprit search and revert when main turns red.

It is **not for you** if you want an assistant inside your editor, if you cannot accept agents running without a sandbox, or if you need commercial use without buying a commercial license (see [License](#license)).

## Status

**Alpha.** Zenoforge was extracted from the pipeline that builds a production product, where it lands dozens of agent-written changes a day. The engine is real and running; the packaging for other repositories is new. Expect rough edges and Bash.

The release, acceptance and advisor stages are not shipped. Their runners (for example `engine/run-release.sh`) are absent, and the advisor provider does not ship. The stage chain therefore ends at merge.

Parts of the project are in Chinese: the dashboard UI, the maintainer mail, some worker prompt modules (for example `engine/factory/common.md`), and many code comments and strings. About 50 of the 230 non-test files under `engine/` and `tools/` contain Chinese text. English translation is planned.

## Documentation

- [Architecture](docs/architecture.md): the loops, stage chain, workers, merging and state.
- [Installing on one host](docs/install.md): what `init` does step by step, the manual path, configuration, systemd units, and what is not generic yet.
- [Security](SECURITY.md): the threat model. Agents run unsandboxed and act on issue text.
- Source: `engine/` is the pipeline, `cli/` is the `zenoforge` command, `tools/` is repository tooling.

Run the tests (`npm ci` first):

```bash
bash tools/run-engine-tests.sh      # all engine suites; add "0 8" for shard 0 of 8
node --test cli/*.test.mjs          # the zenoforge CLI
```

## Contributing

Contributions are welcome under the [Contributor License Agreement](CLA.md). See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Zenoforge is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). It is **source-available**, not OSI open source.

- Free for personal, noncommercial use.
- Commercial use requires a commercial license from the maintainer. To ask, open a GitHub issue titled "Commercial license" in [ZenoWangzy/zenoforge](https://github.com/ZenoWangzy/zenoforge/issues), or contact the maintainer through the maintainer's [GitHub profile](https://github.com/ZenoWangzy).

The one exception is the vendored Matt Pocock skills under `.agents/skills/`, which stay under the MIT License ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).
