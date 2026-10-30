# Installing Zenoforge on one host

> **Alpha: expect to read the code.** There is no installer. This page lists what the scripts expect, checked against `engine/`. Some parts are not generic yet. The list is in [Not generic yet](#not-generic-yet), and you will hit most of it on a first install.

Scope: one host, one target GitHub repository. The issue loop runs from systemd user timers. The unit loop is started by `engine/mac-autopilot/start.sh`, and you may need to supply its service units yourself. For how the pieces fit together, read [architecture.md](architecture.md).

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

## 2. Put the engine inside a dedicated checkout

The engine expects to live at `<checkout>/engine/`:

- `ZF_REPO_DIR` defaults to the parent of the `engine/` directory (set in `engine/lib.sh`).
- The unit loop derives its root from its own location (`engine/mac-autopilot/runtime-env.sh`). `start.sh` then publishes `engine/` from the repository's HEAD with `git archive`.

In practice the engine is a directory inside the repository it operates on. The shipped unit files expect the checkout at `$HOME/.zenoforge/checkout` (`engine/systemd/*.service`). If yours is somewhere else, edit those paths.

Use a dedicated checkout. Do not use one you work in:

- `run-tick.sh` refuses to run unless the checkout is on `main`.
- Before each tick it saves uncommitted changes to `$AGENT_HOME/quarantine/` and resets the checkout to HEAD. Untracked files are removed too, after they are archived.

## 3. Set the repository and the agent identity

| Variable | Default | What to do |
|---|---|---|
| `ZF_REPO` | `example-maintainer/example-repo` (placeholder, not a usable target) | Set it to `owner/name`. The shipped unit files do not set it, so add it (see section 7) |
| `ZF_GH_REPO` | the same placeholder | Set it to `owner/name` too. Both variables exist, and this page does not trace why |
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
| `engine/mac-autopilot/config.template.json` | Copied to `<checkout>/.scratch-supervisor/autopi/config.json`. The runtime copy is overwritten whenever it differs from the template (`engine/mac-autopilot/config-reconcile.sh`) | Edit the template and commit. Never edit the runtime copy, because the next sync overwrites it. Keys: `tick_seconds`, `max_workers`, `implement_cap`, `dispatch_priority_order`, `auto_merge`, `hotfix_lane`, `models`, `release_train`, `supervisor_arbiter`, `daily_token_budget`, `pricing`, `node_health` |
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
| `ZF_REPO` / `ZF_GH_REPO` | placeholder, not a usable target | `owner/name` for `gh` calls. Must be set |
| `ZF_REPO_DIR` | parent of `engine/` | Checkout root |
| `ZF_WORKTREE_ROOT` | `~/wt` | Git worktrees |
| `ZF_NIGHT_DIR` | `$AGENT_HOME/night` | Maintenance state |
| `ZF_CODEX_SANDBOX` | `danger-full-access` | Sandbox mode for the issue loop's `codex` runs. The unit loop always passes `danger-full-access` (see `architecture.md`, section 11) |
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

Before you run this, check the paths in the unit file. The shipped unit sets only `ZF_REPO_DIR` and `PATH`, so `ZF_REPO` must come from a drop-in. Create one with `systemctl --user edit zenoforge-agent.service` and add:

```
[Service]
Environment=ZF_REPO=owner/name
```

**Later installs (by the tick).** Each tick copies every `*.service` and `*.timer` file from `engine/systemd/` into `${SYSTEMD_USER_UNIT_DIR:-~/.config/systemd/user}` when the file differs. It runs `daemon-reload` if anything changed. Then it enables or starts each timer in `pipeline-timers.list`. Two consequences:

- Edits made in `~/.config/systemd/user` are overwritten by the next tick. Put host-specific settings in drop-ins (`systemctl --user edit <unit>`), which the copy does not touch, or edit `engine/systemd/` and commit.
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

In practice you have to supply the unit loop's service units yourself. A simple shape is one unit each for `loop.sh` and `bell-loop.sh`, run from `<checkout>/.scratch-supervisor/autopi-live/`. Start the unit loop last, after the issue loop works.

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

1. **The engine must sit inside the repository it operates on.** `ZF_REPO_DIR` and the unit loop's root are both derived from the engine's own location. `start.sh` publishes `engine/` from the repository's HEAD. A separate engine checkout that operates on a different repository is not something the code supports.

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
   - `docs/agents/*.md`. The engine and its prompts cite about 65 of these, for example `docs/agents/issue-pipeline.md`. Without them, the references are dead.
   - The `lessons/` directory and its generated files (see `architecture.md`, section 9).
   - `eval/cases/*.json`. The eval harness has no case files in this checkout.

5. **Units and timers.**
   - `engine/systemd/pipeline-timers.list` names three timers that are not shipped: `zenoforge-local-rescue`, `zenoforge-disk-reclaim`, and `zenoforge-prod-anomaly`. Each tick tries to enable them, fails, and writes one alert per timer. Ship their units, or remove the lines.
   - No unit files for the unit loop are shipped (section 8).
   - `engine/systemd/user-units-path.test.sh` looks for an `ExecStart` under a `scripts/` path. The engine now lives under `engine/`, so the check skips every shipped unit and checks nothing.

6. **Operator notes are not install docs.** `engine/README.md` is a runbook for one deployment. It has host-specific paths and procedures. The top-level README is the public entry point.

7. **Variable names come in several prefixes.** The issue loop uses `ZF_` and `AGENT_`. The unit loop uses `MAC_AUTOPILOT_` and `AUTOPI_`. The Codex wrapper uses `LUNA_`, and the worker wrapper uses `WORKER_`. Capacity settings use `AGENT_`. Check which prefix a script reads before you set a value.

8. **Two model-selection systems.** The issue loop reads the live policy (`model-policy.json`). The unit loop reads the `models` block of `config.json`. Neither reads the other, and the forbidden-word check does not see the second one. The template's `implement_hotfix` uses `gpt-6.1-terra`, a name that the policy's forbidden list blocks in a policy role. See `architecture.md`, section 5.

9. **Language.** About 50 of the 230 non-test files under `engine/` and `tools/` contain Chinese text (comments, strings, prompts and state files).

10. **No installer and no install test.** The steps on this page are not tested by CI. The shell test suites source `engine/test-env.sh`, which isolates `HOME` and `AGENT_HOME`. Nothing in CI runs the install steps.

11. **Security.** Workers run with broad permissions by default: Codex runs in `danger-full-access`, and ZCode runs in yolo mode. Run the engine under a dedicated OS account on a machine you can rebuild. See the note in `architecture.md`, section 11.
