# Installing Zenoforge on one host

> **Alpha: expect to read the code.** The quickest path is the CLI: `npx zenoforge doctor`, then `npx zenoforge init`. This page explains what the CLI does so you can check it, and lists what the scripts expect when you install by hand (checked against `engine/`). Some parts are not generic yet. The list is in [Not generic yet](#not-generic-yet), and you will hit most of it on a first install.

Scope: one host, one target GitHub repository. The issue loop runs from systemd user timers. The unit loop is started by `engine/mac-autopilot/start.sh`; the CLI generates the service units for it. For how the pieces fit together, read [architecture.md](architecture.md).

## 0. The CLI path

```
npx zenoforge doctor
npx zenoforge init                       # or: pnpm dlx zenoforge init, npm i -g zenoforge
npx zenoforge init --repo owner/name --yes --dry-run     # print the plan, change nothing
```

`doctor` runs the checks of [section 1](#1-host-requirements) and prints the exact fix command for each missing item. It exits non-zero if a hard requirement is missing. The systemd or launchd check is a warning, because a foreground mode exists.

`init` asks for the repository (the `gh repo list` of your login, or `--repo owner/name`) and the agent for each role ([Agents and roles](#agents-and-roles)), shows the security warning from [SECURITY.md](../SECURITY.md), and asks you to confirm it (`--yes` confirms without asking). Only then does it write anything outside its own checks. It does these steps, in this order, and each maps to a manual step below:

| Step | Manual equivalent |
|---|---|
| Creates a dedicated checkout (`~/.zenoforge/checkout`, or `--checkout-dir`) with `gh repo clone`. It refuses a directory it did not create, the repository you are standing in, and a default branch other than `main` | [Section 2](#2-put-the-engine-where-the-scripts-look-for-it) |
| Copies the packaged engine to `~/.zenoforge/engine/<version>/`, then flips the `~/.zenoforge/engine/current` link to it. Links `<checkout>/engine` to `current` and lists `/engine`, `/.scratch-supervisor`, `/.scratch` in `<checkout>/.git/info/exclude` | [Section 2](#2-put-the-engine-where-the-scripts-look-for-it) |
| Writes `~/.zenoforge/env` (repository, worktree root, and a copy of your `gh` token when `gh` keeps it in a keyring or `GH_TOKEN`, which background jobs cannot read), `capacity.env` and `recipients.json`. All mode 600, never overwritten if present | [Sections 3, 5 and 6](#3-set-the-repository-and-the-agent-identity) |
| Renders `config.template.json` (worker caps, token budget, `auto_merge`, review model) and `required-pr-checks.json` into the engine version | [Section 5](#5-configuration-files) |
| Creates the pipeline labels that are missing. The list is read from `ALL_STATE_LABELS` in `engine/lib.sh`, plus `on-hold`, `tracker`, `hotfix`, `bug`, `enhancement` | [Section 3](#3-set-the-repository-and-the-agent-identity) |
| Sets `AGENT_SUPERVISOR=observe` and `AGENT_PIPELINE=triage` (`off` with `--no-scheduler`). Needs admin access; if `gh` refuses, it prints the two commands | [Section 4](#4-github-repository-variables) |
| Renders the units from `engine/systemd/` into the engine version, copies them to `~/.config/systemd/user/` (or LaunchAgents on macOS), enables the timers in `pipeline-timers.list` and two resident loop services | [Sections 7 and 8](#7-systemd-units) |

Defaults that differ from a bare engine: 2 workers (`--max-workers`), a 2,000,000-token daily budget (it only raises alerts), advisor off, no mail recipients, the release train and the supervisor arbiter off in `config.template.json` (their runners are not shipped), and **auto-merge off unless the repository's branch protection names required checks** or you pass `--auto-merge`. If you pass `--required-check NAME` (repeatable), those names replace the originating project's list.

Keep the default checkout location unless you have a reason: a few readers in the engine (`scheduling-policy.mjs`, `mac-autopilot/waste_report.py`) hardcode `~/.zenoforge/checkout`, and with `--checkout-dir` they find nothing there.

Running `init` again is safe: existing env files are kept, an unchanged engine is reused, and a changed setting installs a new `<version>+2` directory. One host serves one repository; a second `--repo` is refused.

After `init`: `zenoforge status`, `zenoforge logs -f`, `zenoforge stop` and `zenoforge start`. If you installed with `--no-scheduler`, the first `zenoforge start` shows the same security warning, asks for the same confirmation (or `--yes`), installs the units and sets `AGENT_PIPELINE=triage`. `zenoforge upgrade` (run from the newer package, for example `npx zenoforge@latest upgrade`) installs that package's engine as a new version, re-renders the units and restarts the two loop services; `zenoforge rollback` flips back. `zenoforge uninstall` disables and removes the units and the checkout's `engine` link and keeps `~/.zenoforge` (run `init` to set up again); `--purge --yes` deletes it, and the checkout if the CLI made it, also when an earlier `init` stopped before writing `cli.json`. `zenoforge status` warns when the repository's `main` starts tracking its own top-level `engine/` directory.

On macOS the CLI installs the unit loop only (two LaunchAgents). The issue loop dispatches stages with `systemd-run`, which macOS does not have. Without systemd or launchd, `zenoforge start` runs the unit loop as detached background processes with pid files in `~/.zenoforge/run/`.

### Agents and roles

| Role | Choices (first is the default) | What the choice changes |
|---|---|---|
| `implement` | `codex`, `zcode` | `codex`: the shipped unit-loop models. `zcode` with no `codex` installed: `WORKER_BACKEND=zc` in `capacity.env` (the `bin/worker` backend) |
| `review` | `claude`, `codex` | `models.review` in `config.template.json`: the shipped Claude entry, or a copy of the Codex implement entry |

The unit loop implements through Codex. Claude reviews there with a read-only tool list and cannot implement. The issue-loop model policy only accepts Codex roles. That is why the table is short.

## Installing by hand

The sections below are the manual path. They give the same result as `zenoforge init`.

## 1. Host requirements

| Need | Why | Where it is used |
|---|---|---|
| Linux with a systemd user manager (`systemctl --user`) | Timers, detached workers (`systemd-run --user`), unit installs | `engine/run-tick.sh`, `engine/issue-pipeline.sh` |
| `gh` CLI, logged in | All GitHub reads and writes: issues, labels, PRs, repository variables | `gh variable get` in `run-tick.sh`, `gh label` in `engine/lib.sh` |
| `git` | Dedicated checkout, worktrees, fetch, fast-forward | `run-tick.sh`, `bin/worker` |
| `jq` | JSON state; almost every script uses it | Nearly all `*.sh` files |
| Node 22 | The `.mjs` tools. CI pins Node 22 | `.github/workflows/engine-tests.yml` |
| `python3` | Admission check, time parsing | `engine/execution-admission.py`, `engine/mac-autopilot/runtime-env.sh` |
| `flock`, `setsid`, `timeout`, `tar`, `stat`, `systemd-run` | Locks, detached processes, time limits, archives | `bin/worker`, `engine/mac-autopilot/*.sh` |
| At least one coding-agent CLI | The workers | `codex` is the default (`bin/luna`, `scheduler.sh`). `zcode` is the failover backend (`bin/zc`). `claude` (Claude Code) runs the unit loop's review: the shipped `config.template.json` sets `models.review` to a Claude model |
| Optional: `notify-send`, `journalctl` | Desktop alerts; out-of-memory evidence | `engine/mac-autopilot/runtime-env.sh` |

If the timers should keep running with no login session open, enable lingering for your user (`loginctl enable-linger`). The engine's own operator notes recommend it.

## 2. Put the engine where the scripts look for it

The scripts expect the engine at `<checkout>/engine/`:

- `ZF_REPO_DIR` defaults to the parent of the `engine/` directory (set in `engine/lib.sh`), and the unit loop derives its root the same way (`engine/mac-autopilot/runtime-env.sh`).
- `start.sh` publishes the unit loop's runtime from `<checkout>/engine/`. When that path is a symlink, it copies the directory and pins the copy by the version directory's name. Otherwise it runs `git archive` of the checkout's HEAD.
- `write-guard.sh` accepts an engine that lives in `$AGENT_HOME/engine/<version>/`, outside the checkout.

So the engine and the repository it operates on are different trees. The CLI keeps the engine outside the repository and links it in:

```
git clone <repository> ~/.zenoforge/checkout                 # dedicated checkout, on main
cp -r <engine dir> ~/.zenoforge/engine/0.1.0
ln -sfn 0.1.0 ~/.zenoforge/engine/current
ln -s ~/.zenoforge/engine/current ~/.zenoforge/checkout/engine
printf '/engine\n/.scratch-supervisor\n/.scratch\n' >> ~/.zenoforge/checkout/.git/info/exclude
```

Keep `/engine` and the runtime directories in `.git/info/exclude`: each tick runs `git clean -fd` in the checkout, which would otherwise delete them. A repository that tracks its own top-level `engine/` directory cannot be used this way; the CLI refuses it. (The alternative is to commit the engine into the target repository, as the project it was extracted from does.)

Use a dedicated checkout. Do not use one you work in:

- `run-tick.sh` refuses to run unless the checkout is on `main`.
- Before each tick it saves uncommitted changes to `$AGENT_HOME/quarantine/` and resets the checkout to HEAD. Untracked files are removed too, after they are archived.

## 3. Set the repository and the agent identity

| Variable | Default | What to do |
|---|---|---|
| `ZF_REPO` | none; derived from the checkout's `origin` remote (`git remote get-url origin`, scheme, host and a trailing `.git` stripped, so `git@github.com:owner/name.git` becomes `owner/name`), as `engine/lib.sh` and `engine/run-tick.sh` do | Normally leave it unset. Set it to `owner/name` when the checkout has no `origin` remote (the value is then empty) or the remote URL does not reduce to `owner/name`. The shipped unit files do not set it (see section 7) |
| `ZF_GH_REPO` | none | Optional `owner/name` that overrides `ZF_REPO` for the `gh` calls of `land-direct-main.sh`, `pipeline-issue-upsert.sh` and `worktree-backlog-sweep.sh`; they fall back to `ZF_REPO`. `worktree-lifecycle.sh` falls back to the checkout path instead, so set `ZF_GH_REPO` when you run it |
| `AGENT_HOME` (or `ZF_HOME`) | `~/.zenoforge` | State root. Leave the default unless you need another location |
| `ZF_AGENT_GIT_USER_NAME` | `zenoforge-agent` | Commit identity for agent commits |
| `ZF_AGENT_GIT_USER_EMAIL` | `zenoforge-agent@users.noreply.github.com` | Commit identity for agent commits |

The engine creates any missing state label on the repository during a fast-lane tick (`ensure_state_labels`, `engine/lib.sh`). You do not need to create them yourself.

## 4. GitHub repository variables

These are read with `gh variable get`. Set them with `gh variable set NAME --repo owner/name --body VALUE`.

- **`AGENT_PIPELINE`**: the issue loop's mode. `off` makes `engine/issue-pipeline.sh` exit at once. The other values seen in code are `triage`, `implement`, and `release`. The comments say that while `triage` is set, the unit loop owns implementation. Read the mode handling in `engine/issue-pipeline.sh` before you change it.
- **`AGENT_SUPERVISOR`**: `off`, `observe`, or `act`. It is read on each supervisor run. Any other value, or an unreadable variable, is treated as `observe` (`read_supervisor_mode`, `engine/supervise-pipeline.sh`).
- **Timer switches**: the second column of `engine/systemd/pipeline-timers.list` names the variable that can switch a timer off. Set it to `off` to leave that timer alone.

## 5. Configuration files

| File | What reads it | What to change |
|---|---|---|
| `engine/model-policy.default.json` | Copied to `$AGENT_HOME/model-policy.json` (`MODEL_POLICY_DEFAULT` in `engine/lib.sh`). The copy is refreshed only when the default changes in git (`engine/model-policy-fast-forward.sh`) | Roles (`work`, `production`, `advisor`, `review`, `hand-zcode`), the `escalation` steps, and the `forbidden` words. The shipped roles use Codex (`gpt-6-luna`). The advisor role is disabled by default, and no advisor provider ships. `hand-zcode` is disabled |
| `engine/mac-autopilot/config.template.json` | Copied to `<checkout>/.scratch-supervisor/autopi/config.json`. The runtime copy is overwritten whenever it differs from the template (`engine/mac-autopilot/config-reconcile.sh`) | Edit the template and commit. Never edit the runtime copy, because the next sync overwrites it. With the CLI the template is the one in the installed engine version (`~/.zenoforge/engine/current/mac-autopilot/`), rendered by `init` and `upgrade` from their flags: change settings by re-running `init` with flags (`--max-workers`, `--required-check`, `--review`), because `upgrade` re-renders the file Keys: `tick_seconds`, `max_workers`, `implement_cap`, `dispatch_priority_order`, `auto_merge`, `hotfix_lane`, `models`, `release_train`, `supervisor_arbiter`, `daily_token_budget`, `pricing`, `node_health` |
| `engine/mac-autopilot/required-pr-checks.json` | The scheduler's `required_checks_without_pass` and `engine/hotfix/hf-merge.sh` | The check names every PR must pass. The shipped names come from another project's workflows. Replace them with the names your workflows report. See [Not generic yet](#not-generic-yet) |
| `$AGENT_HOME/capacity.env` | Sourced by `engine/lib.sh` with `set -a`, so any variable in it is exported | Capacity settings (below). It can also carry `ZF_*` variables |
| `engine/state/*.json` | Shipped state seeds: scheduling policy, rulings, incident guards, hand priority, comms profile, health mail, mechanism registry, rule files | Not audited for this page. Read the ones you use before you rely on them |

The `models` block in `config.template.json` holds `[model, effort]` pairs. The shipped keys are `review` (a Claude model), `implement`, `triage`, `review_fallback`, and `implement_hotfix`. The scheduler also looks up `<role>_hotfix` and `<role>_fallback` (`pick()` in `engine/mac-autopilot/scheduler.sh`).

### Capacity settings (`$AGENT_HOME/capacity.env`)

These are the keys the admission check reads (`configuration()` in `engine/execution-admission.py`). They are `AGENT_` keys, not `ZF_` keys.

| Key | Default | Meaning |
|---|---|---|
| `AGENT_GLOBAL_EXECUTION_CAP` | 10 (allowed 1 to 16) | Most workers admitted at once |
| `AGENT_EXECUTION_MIN_MEM_MB` | 6144 | Memory that must stay free |
| `AGENT_EXECUTION_MEM_PER_WORKER_MB` | 1024 | Memory budgeted for each extra worker |
| `AGENT_EXECUTION_MAX_LOAD` | CPU count | Load average the gate allows |
| `AGENT_EXECUTION_LOAD_PER_WORKER` | 1 | Load budgeted for each extra worker |
| `AGENT_EXECUTION_CPU_TARGET_PERCENT` | unset (1 to 95 if set) | Optional CPU busy target |

Bad values make the admission check defer. They do not fall back to defaults.

## 6. Environment variables

Set these in the unit files (with a drop-in, see section 7), in `capacity.env`, or in the shell that runs a script by hand.

| Variable | Default | Used for |
|---|---|---|
| `AGENT_HOME` / `ZF_HOME` | `~/.zenoforge` | State root |
| `ZF_REPO` / `ZF_GH_REPO` | `ZF_REPO`: the checkout's `origin` remote as `owner/name`; `ZF_GH_REPO`: none | `owner/name` for `gh` calls. Set `ZF_REPO` only if there is no usable `origin`; see section 3 |
| `ZF_REPO_DIR` | parent of `engine/` | Checkout root |
| `ZF_WORKTREE_ROOT` | `~/wt` | Git worktrees |
| `ZF_NIGHT_DIR` | `$AGENT_HOME/night` | Maintenance state |
| `ZF_CODEX_SANDBOX` | `danger-full-access` | Sandbox mode for the issue loop's `codex` runs. The unit loop always passes `danger-full-access` (see `architecture.md`, section 11) |
| `ZF_RELEASE_TRAIN_SCRIPT` | unset | Optional release-leg hook: path of a script the unit loop starts every 15 minutes (`run_release_train`, `engine/mac-autopilot/scheduler.sh`) when `release_train.enabled` is not false. Zenoforge ships none, so the step does nothing until you set it |
| `ZF_LOCAL_BIN_DIR` / `ZF_CODEX_RUNTIME_BIN_DIR` | `~/.local/bin` | Binaries that the night maintenance checks |
| `ZF_CHATGPT_RESOURCES_DIR` | a fixed path inside a desktop app bundle | Night-maintenance repair of Codex runtime binaries (`codex_runtime_bundle_dir`, `engine/lib.sh`). Set it to your own install, or leave it if you do not use that repair |
| `MAC_AUTOPILOT_ROOT` | derived from the engine location | Unit-loop root |
| `MAC_AUTOPILOT_SUPERVISOR_DIR` | `<root>/.scratch-supervisor` | Unit-loop versions and runtime |
| `MAC_AUTOPILOT_RUNTIME_DIR` | `<supervisor dir>/autopi` | Live unit-loop runtime |
| `AUTOPI_TICK_LIMIT_SECONDS` | 1800 | Time limit for one scheduler tick |
| `AUTOPI_REFILL_SECONDS` / `AUTOPI_REFILL_LIMIT_SECONDS` | 30 / 300 | Refill cadence and time limit |
| `WORKER_BACKEND` | unset (balance) | `luna` (Codex) or `zc` (ZCode) for `bin/worker` |
| `WORKER_STALL_MINUTES` | 10 | No-progress limit for one worker |
| `WORKER_BREAKER_SECONDS` | 1800 | How long a failed backend is skipped |
| `WORKER_SCRATCH_ROOT` | `~/.zenoforge/scratch` | Where `bin/worker` keeps its runs |
| `LUNA_MAX`, `LUNA_CPU_TARGET`, `LUNA_MEM_MAX`, `LUNA_PRIORITY` | 10, 85, 4G, `normal` | The Codex wrapper's gate. `LUNA_PRIORITY` can be `hotfix`, `opt`, or `normal` |
| `AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER` | 2 | Load limit for the fetch-starved guard in `run-tick.sh` |
| `GIT_FETCH_TIMEOUT_SEC`, `GH_CALL_TIMEOUT_SEC` | 60, 60 | Timeouts used by `run-tick.sh` |
| `HF_STALE_MINUTES` | 30 | How long a hotfix PR may sit idle before an alert |
| `PGTEST_URL` | a placeholder local URL | Database URL for integration tests, if the target repository has them |

## 7. systemd units

The unit files are in `engine/systemd/`:

| Unit | Timer | Runs | Notes |
|---|---|---|---|
| `zenoforge-agent` | every 5 min | `engine/run-tick.sh` (issue loop) | Install this one first |
| `zenoforge-supervisor` | every 10 min (first run after 2 min) | `engine/supervise-pipeline.sh` | Acts only when `AGENT_SUPERVISOR` is `act` |
| `zenoforge-health-maintenance` | every 10 min | `engine/night/health-maintenance.sh maintenance` | Bounded health checks |
| `zenoforge-health-mail` | every 6 h | `engine/night/health-maintenance.sh maintainer-mail` | Sends mail. Not in `pipeline-timers.list`, so `run-tick.sh` does not enable it |
| `zenoforge-label-churn` | every 30 min | `engine/detect-label-churn.sh` | Finds issues that loop between labels |
| `zenoforge-daily-perf-report` | daily at 01:00 UTC | `engine/night/daily-perf-report.sh` | Daily report |

**First install (by hand).** `run-tick.sh` installs unit files only from inside a running tick, so the first copy is manual:

```
mkdir -p ~/.config/systemd/user
cp engine/systemd/zenoforge-agent.service engine/systemd/zenoforge-agent.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now zenoforge-agent.timer
```

Before you run this, check the paths in the unit file. The shipped unit sets only `ZF_REPO_DIR` and `PATH`, so `ZF_REPO` comes from the checkout's `origin` remote. The CLI renders every unit with `EnvironmentFile=-%h/.zenoforge/env`, the real tool directories in `PATH` (a user unit does not read your shell profile), and without the local HTTP proxy lines of the original deployment. If the checkout has no `origin`, or the URL does not reduce to `owner/name`, set `ZF_REPO` in that env file or in a drop-in. Create a drop-in with `systemctl --user edit zenoforge-agent.service` and add:

```
[Service]
Environment=ZF_REPO=owner/name
```

**Later installs (by the tick).** Each tick copies every `*.service` and `*.timer` file from `engine/systemd/` into `${SYSTEMD_USER_UNIT_DIR:-~/.config/systemd/user}` when the file differs. It runs `daemon-reload` if anything changed. Then it enables or starts each timer in `pipeline-timers.list`. Two consequences:

- Edits made in `~/.config/systemd/user` are overwritten by the next tick. (The CLI renders its units into the engine version's own `systemd/` directory, so the tick copies identical files.) Put host-specific settings in drop-ins (`systemctl --user edit <unit>`), which the copy does not touch, or edit `engine/systemd/` and commit.
- The shipped health units set a local HTTP proxy and `ZF_WORKTREE_ROOT=$HOME/wt`. Change or remove those lines for your host, through a drop-in.

## 8. The unit loop and `start.sh`

`engine/mac-autopilot/start.sh` does three things:

1. Publishes a copy of `engine/` at the current HEAD into `<checkout>/.scratch-supervisor/autopi-versions/<sha>/`. It keeps two versions.
2. Reconciles `config.template.json` into the runtime `config.json` and switches the `autopi-live` symlink to the new version.
3. Starts the loop. If systemd units named `zenoforge-autopilot-scheduler`, `zenoforge-autopilot-bell`, and `zenoforge-autopilot-zombie` are installed, it restarts them. Otherwise it starts `loop.sh`, `bell-loop.sh`, and `zombie-loop.sh` with `nohup`.

`start.sh --sync-only` does steps 1 and 2 and exits. It is a safe way to see what would be published. `loop.sh` runs it on its own whenever the checkout's HEAD changes, so a merged change to `engine/mac-autopilot/` takes effect on the next tick.

Gaps for the unit loop (details in [Not generic yet](#not-generic-yet)):

- `engine/systemd/` has no `zenoforge-autopilot-*` units. `start.sh` refers to `ops/host-units/`, which is not in this repository.
- `zombie-loop.sh` is not in this checkout, so the `nohup` fallback fails for it.

The CLI supplies them: `zenoforge-autopilot-scheduler.service` (runs `start.sh --sync-only`, then `loop.sh`) and `zenoforge-autopilot-bell.service` (`bell-loop.sh`), both `Restart=always`, run from `<checkout>/.scratch-supervisor/autopi-live/`. By hand, write one unit each for `loop.sh` and `bell-loop.sh` of that shape. Start the unit loop last, after the issue loop works.

## 9. First run, in a safe order

1. Check that `gh` works for the repository: `gh auth status`, then `gh variable list --repo owner/name`.
2. Set safe modes: `gh variable set AGENT_PIPELINE --repo owner/name --body off` and `gh variable set AGENT_SUPERVISOR --repo owner/name --body observe`.
3. Install and enable the agent unit (section 7). Watch its output: `journalctl --user -u zenoforge-agent.service -f`.
4. Dry-run triage on one issue: `ZF_REPO=owner/name bash engine/run-triage.sh --dry-run <issue-number>`. The script's header says it runs the worktree setup and the model call, then prints the verdict without touching the issue.
5. Only when the dry-run verdict looks right, set `AGENT_PIPELINE` to `triage`. Then move on to the unit loop.

## 10. Stopping it

- Issue loop, no new work: `gh variable set AGENT_PIPELINE --repo owner/name --body off`. The next tick exits.
- Timer, no new ticks: `systemctl --user stop zenoforge-agent.timer`.
- Manual pause: write `$AGENT_HOME/PAUSE` as a JSON object. The engine checks it in `manual_pause_is_valid` (`engine/lib.sh`). It needs `caller` set to `operator`, non-empty `reason`, `issue`, `provider`, and `model` strings, and a `timestamp` in ISO UTC form, such as `2026-01-15T09:30:00Z`.
- Unit loop: stop the unit you wrote for it, or stop the processes that run from `autopi-live/`.

## Not generic yet

These are the places where the engine is still tied to the environment it was extracted from. Read this list before you install.

1. **The engine is reached as `<checkout>/engine`.** `ZF_REPO_DIR` and the unit loop's root are derived from that location, and about 60 places build `"$REPO_DIR/engine/..."` paths. The CLI satisfies this with a git-excluded symlink to an installed engine version (see [section 2](#2-put-the-engine-where-the-scripts-look-for-it)). It is a shortcut: a repository with its own top-level `engine/` directory is refused, and the scripts that read the engine from the target repository's git history (`land-direct-main.sh`, `pre-push-guard.sh`, `install-pre-push-guard.sh`) will not find it there. A real engine-directory seam (`ZF_ENGINE_DIR`) would remove both limits.

2. **Names and checks from the originating project.**
   - `engine/mac-autopilot/required-pr-checks.json` names checks from the originating project's workflows.
   - `pipeline_system_factory_infra_paths_valid` in `engine/issue-pipeline.sh` allows only workflow and script names from the originating project's CI and deploy setup.
   - `engine/hotfix/` refers to a product-specific hook installer. Its README names `hf-apply-hook.sh`, which is not in this checkout.
   - `engine/verification-plan.mjs`, `engine/run-ci-suites.sh`, `engine/focused-test-paths.mjs`, and `engine/land-direct-main.sh` contain many path and suite names from that project.
   - `engine/ts-judge.mjs` imports an external SDK package, and the CI workflow installs it with npm. Read that file before you rely on the judge.

3. **Scripts the code calls but this checkout does not have.**
   - `engine/run-release.sh`: the release dispatch calls it (`dispatch_release_batch`, `engine/issue-pipeline.sh`). Release cannot run from this checkout.
   - `engine/run-advisor-batch.sh`: the advisor batch dispatch calls it.
   - `engine/run-implement.sh`: named in the issue loop's header as the implement leg. Implement work runs through the unit loop's own dispatcher here.
   - `release_train.sh`: referenced by name.
   - `zombie-loop.sh`: called by `start.sh`.
   - `ops/host-units/`: named by `start.sh` as where unit files should live.
   - `engine/check-host-daemons.py`: `run-tick.sh` calls it when it exists, and skips the step silently when it does not.

4. **Files the engine expects in the target repository.**
   - `scripts/branch-delivery-policy.mjs` and `scripts/branch-delivery-preflight.mjs`. The direct-main lane refuses to land without them (`engine/land-direct-main-bootstrap.sh`).
   - `.agents/skills/<name>/SKILL.md` for the Matt skills the stages name. Optional: a target without them falls back to this engine's vendored copy (`architecture.md`, section 2.3).
   - `docs/agents/*.md`. The engine and its prompts cite about 65 of these, for example `docs/agents/issue-pipeline.md`. Without them, the references are dead.
   - The `lessons/` directory and its generated files (see `architecture.md`, section 9).
   - `eval/cases/*.json`. The eval harness has no case files in this checkout.

5. **Units and timers.**
   - `engine/systemd/pipeline-timers.list` names three timers that are not shipped: `zenoforge-local-rescue`, `zenoforge-disk-reclaim`, and `zenoforge-prod-anomaly`. Each tick tries to enable them, fails, and writes one alert per timer. Ship their units, or remove the lines.
   - No unit files for the unit loop are shipped in `engine/systemd/` (section 8). The CLI generates them.
   - `engine/systemd/user-units-path.test.sh` looks for an `ExecStart` under a `scripts/` path. The engine now lives under `engine/`, so the check skips every shipped unit and checks nothing.

6. **Operator notes are not install docs.** `engine/README.md` is a runbook for one deployment. It has host-specific paths and procedures. The top-level README is the public entry point.

7. **Variable names come in several prefixes.** The issue loop uses `ZF_` and `AGENT_`. The unit loop uses `MAC_AUTOPILOT_` and `AUTOPI_`. The Codex wrapper uses `LUNA_`, and the worker wrapper uses `WORKER_`. Capacity settings use `AGENT_`. Check which prefix a script reads before you set a value.

8. **Two model-selection systems.** The issue loop reads the live policy (`model-policy.json`). The unit loop reads the `models` block of `config.json`. Neither reads the other, and the forbidden-word check does not see the second one. The template's `implement_hotfix` uses `gpt-6.1-terra`, a name that the policy's forbidden list blocks in a policy role. See `architecture.md`, section 5.

9. **Language.** About 50 of the 230 non-test files under `engine/` and `tools/` contain Chinese text (comments, strings, prompts and state files).

10. **The installer is new.** `cli/*.test.mjs` runs `init`, `upgrade` and `uninstall` against a throwaway `HOME`, a local bare repository and fake `gh` and `systemctl`. Nothing runs the installed pipeline against a real GitHub repository in CI, and the launchd path is generated and tested as text only. The shell test suites source `engine/test-env.sh`, which isolates `HOME` and `AGENT_HOME`.

11. **Security.** Workers run with broad permissions by default: Codex runs in `danger-full-access`, and ZCode runs in yolo mode. Run the engine under a dedicated OS account on a machine you can rebuild. See the note in `architecture.md`, section 11.
