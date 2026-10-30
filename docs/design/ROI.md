# Zenoforge cost and return: measuring traffic, tokens, money and time, and computing ROI continuously

Status: design, not implemented. Written 2026-10-29 (US Pacific; the ledgers it cites run to 2026-10-30 UTC) against the exported engine tree (`engine/`) and the origin deployment's live copy and ledgers. Nothing in this document was changed on the host that was probed; the only things created were transient systemd units that removed themselves (section 2.3).

Scope: one append-only ledger that records, at the end of every unit of work, the tokens, money, wall time, CPU, memory, network bytes and GitHub API calls it used; one rollup that turns the ledger plus the delivered outcomes into ROI; and four surfaces that read that rollup (dashboard, daily report, node health, `zenoforge roi`).

Landing rule: until the source of truth moves, every change below lands first in the origin deployment's copy of the engine, at the same relative path, and reaches this repository through the export. Tickets are changes to `engine/<path>`; the one ticket that lives in the npm CLI repository says so. Tests ship with each ticket; whether they run before or after landing follows the deployment's policy for engine code.

Vocabulary used throughout:

| Term | Meaning |
|---|---|
| ticket | a GitHub issue |
| work order | one entry of the scheduler's unit ledger (`units.json`): the lifecycle of a ticket or PR through the stages |
| unit | one launched piece of work with a start and an end: a systemd transient unit, one unit-loop worker invocation, one scratch worker run, or one CI workflow run |
| stage | triage, implement, review, repair, rereview, land, release, and so on |
| delivered | merged to the default branch; and, where the deployment has a release stage, released (accepted in production). Section 3.1 says which one counts where |
| host | one machine running the engine, named by `ZF_HOST_ID` (DISTRIBUTED.md section 4.1), never by its hostname |
| measured / n/a / missing | a number was read / the platform cannot supply it / it should exist but the reader found nothing. Only the last counts as a data-quality defect |

## 0. What this document decides

1. **ROI** is `(V - C) / C`. `V` is the human-equivalent value of the tickets delivered in the window: `sum over delivered tickets of effort_hours(size class) x hourly_rate`, both from a price table the operator owns. `C` is everything the pipeline spent in the window, including units that delivered nothing: model + CI + host compute + traffic. **Waste share** is the cost of units and tickets that ended without a delivery, divided by `C`. Time-to-value is reported against a stated human lead-time baseline and is off in the money formula unless a cost-of-delay rate is set. Section 3.
2. **One ledger**, `metrics/units-YYYY-MM.jsonl` under the agent home, one JSON line per unit end, plus one `gh-quota` sample row per collector run. It uses the same append protocol as the existing efficiency ledger (exclusive `flock`, one object per line, stable `event_id`). One process, the collector, is the only writer. Prices are applied at read time, so a price change re-prices history. Section 4.
3. **Traffic**: systemd's `IPAccounting=` is the mature mechanism and it **does not work for `systemd --user` units**. The systemd manual says so ("currently only available for system services, not for per-user services") and the probe on this host confirmed it: the property is accepted and every counter reads `[no data]`. The origin runs all stage units as user units, so the primary mechanism is the rootless socket sampler the origin already runs (`ss` byte counters with their cgroup), read as a per-unit delta; the IP-accounting read stays in the code for hosts whose units run under the system manager. Where neither works the field is `n/a`, never 0. Section 2.
4. **CPU and memory per unit** are available today without any new dependency: the unit's own cgroup (`cpu.stat`, `memory.peak`) on Linux, `getrusage` elsewhere. They must be captured before the unit ends because the counters vanish with the cgroup (probe E4 and E5). Section 2.3.
5. **Nothing is re-derived per report.** A single rollup module produces one report document. The dashboard, the daily report, `node_health.py` and the CLI all read or call that module. Section 8.
6. **Thirteen tickets**, one of them in the rule lane (node health) and none touching the two files that are on hold. After the second ticket a person can run one command and see per-ticket ROI computed from real worker tokens. Section 9.

## 1. Problem statement, solution and user stories

The pipeline spends model tokens, CI runner minutes, host CPU and network on every ticket, and it records some of that in at least nine places that do not agree with each other. A maintainer who asks "what did ticket 1234 cost, what did the pipeline cost yesterday, and was it worth it?" gets one of these answers today:

- tokens, but not dollars, for the unit-loop workers (`worker_cost.py`), and only for the 60 most recent harvested workers by name (older logs lose their model);
- a single token number per model call for triage, recut, advisor and hand dispatches (the spend log), with no input/cached/output split and none for implement, review or repair workers;
- dollars only on the dashboard, only for Codex rollouts of yesterday and today, with two priced models;
- CI minutes for a 5-hour window and a 24-hour cache, with no runner class, no dollar value and no ticket;
- host-wide network bytes by category every minute, but no per-unit figure (the samples are overlapping 20-minute windows);
- GitHub API calls per unit from an opt-in shim, but nothing about the shared quota;
- no CPU-seconds or memory peak for any unit.

Nothing combines them, so the fixed costs of the pipeline (cancelled runs, workers that die without a report, tickets closed unmerged) are invisible, and nobody can say whether a change to the pipeline improved the return on it. The maintainer's request is to measure traffic, tokens, money and time continuously and compute ROI from them continuously.

### 1.1 Solution

Every unit of work writes, at its end, one row to a per-host ledger with the model tokens it used by model, its wall time, CPU, peak memory, network bytes and GitHub calls, each marked with how it was obtained. Every completed CI run does the same with minutes by runner class. A single rollup prices those quantities from an auditable price table, joins them to the outcomes the pipeline already records (merged, released, closed, reverted), and produces one report: cost by component, value of what was delivered, ROI, waste share, and the lead time against a human baseline. The dashboard, the daily report, the node-health scorecard and `zenoforge roi` all show that report; none of them recomputes it. A number that cannot be measured says `n/a`; a number that should exist and does not says `missing`; neither is ever 0.

### 1.2 User stories

1. As a maintainer, I want to see what one ticket cost end to end (model, CI, host, traffic), so that I can judge whether it was worth running.
2. As a maintainer, I want the pipeline's cost per day and per week, so that I can budget it.
3. As a maintainer, I want ROI as one number with the assumptions printed next to it, so that I can audit how it was produced.
4. As a maintainer, I want to change the hourly rate and the effort table and re-run the report on old data, so that I can see how sensitive ROI is to my assumptions.
5. As a maintainer, I want the report to say "assumed rate" until I set my own, so that nobody quotes a placeholder as a fact.
6. As a maintainer, I want waste (cancelled CI runs, workers that died, tickets closed unmerged, reverted tickets) as a share of cost with its causes, so that I know where to fix the pipeline first.
7. As a maintainer, I want an unpriced model to show `n/a` with its token count, so that a missing price is never read as free.
8. As a maintainer, I want a quantity the platform cannot measure shown as `n/a` and one that went missing shown as `missing`, so that I can tell a limitation from a defect.
9. As a maintainer, I want both API-list and subscription cost, so that I can tell whether a flat plan pays off.
10. As a maintainer on a flat plan, I want to see how much of the plan's list-price value I used, so that I can decide whether to change plan.
11. As a maintainer, I want input, cached, cache-write, output and reasoning tokens per model per unit, so that cache problems and reasoning-heavy runs are visible.
12. As a maintainer, I want the cache hit rate bounded, so that a prompt change that kills caching is flagged before the bill shows it.
13. As a maintainer, I want CI minutes and cost by runner class and by ticket, so that I know what CI costs per delivered ticket and which class is dear.
14. As a maintainer, I want CI minutes that could not change a verdict counted as waste cost, so that cancelled and superseded runs show up in money.
15. As a maintainer, I want CPU-seconds and peak memory per unit, so that I can price host compute and find the unit that eats the machine.
16. As a maintainer, I want network bytes in and out per unit and per category, so that a unit that pulls gigabytes is visible by name.
17. As a maintainer on a budgeted link, I want GB per delivered ticket bounded, so that the traffic budget is spent on tickets and not on churn.
18. As a maintainer, I want git fetch volume visible, so that a clone-per-run pattern is caught.
19. As a maintainer, I want GitHub calls per unit and the share of the shared hourly quota used, so that I find the unit or loop that burns the quota.
20. As a maintainer, I want lead time from issue to delivery compared with a stated human baseline per size class, so that "faster than a human" is a measured claim.
21. As a maintainer, I want the share of tickets slower than the human baseline, so that slowness is visible even when the median is fine.
22. As a maintainer, I want every number to have a healthy and an unhealthy bound with a stated source, so that I know when to act.
23. As a maintainer, I want a metric with too little history to say it is provisional, so that early bounds are not mistaken for tuned ones.
24. As a supervisor agent, I want the economics rows in the scorecard to feed the existing health-issue and inbox rules, so that a cost regression is handled like any other unhealthy node.
25. As a supervisor agent, I want to be told when the collector stops, so that a silent ledger is treated as an incident.
26. As an on-call engineer, I want a dashboard panel with today's cost, waste and ROI and status markers, so that I can read the state at a glance.
27. As an on-call engineer, I want a failing economics section to show "data unavailable" for itself only, so that a broken rollup does not blank the dashboard.
28. As a maintainer who reads the daily report, I want a "Cost and return" block with yesterday against the day before and the 7-day mean, so that I see the trend without opening the dashboard.
29. As a maintainer, I want the three costliest tickets of the day with their outcome in the daily report, so that I can look at the outliers.
30. As a CLI user, I want `zenoforge roi` with a window, a grouping and a ticket filter, so that I can answer a question in one command.
31. As a CLI user, I want `--json`, so that I can feed the report to other tools.
32. As a CLI user, I want a clear error and a non-zero exit when there is nothing to report, so that an empty window is not mistaken for zero cost.
33. As a CLI user, I want to price the same ledger with another price file, so that I can answer "what if the plan changes".
34. As a fleet operator, I want each host to keep its own ledger with no shared lock, so that adding a host adds capacity without coordination.
35. As a fleet operator, I want to merge copies of several hosts' ledgers into one report, so that a ticket whose work ran on two hosts shows its full cost.
36. As a fleet operator, I want a host-local report to say it is host-local, so that nobody quotes it as the fleet's ROI.
37. As a fleet operator sharing one API token between hosts, I want the quota view to show what my own calls explain and what they do not, so that I can see when another host is the heavy user.
38. As a pipeline developer, I want one ledger event per unit end that every report reads, so that two reports can never disagree about the same unit.
39. As a pipeline developer, I want to add a unit family by writing a stash that the collector turns into a row, so that I do not touch the ledger protocol.
40. As a pipeline developer, I want the hook on the hot path to be unable to change a unit's exit status, so that measuring never breaks work.
41. As a pipeline developer, I want to re-run the collector over the same inputs and get the same ledger, so that crashes and replays are harmless.
42. As an adopter on macOS or a host without systemd, I want the numbers the platform can give and `n/a` for the rest, so that the tool works everywhere without lying.
43. As an auditor, I want to trace any dollar figure to its ledger rows, prices and their sources and dates, so that I can reproduce it by hand.
44. As an auditor, I want prices to carry a source and a retrieval date, so that I can tell stale prices from current ones.
45. As a maintainer, I want batch units split across their tickets instead of repeated, so that a triage batch does not multiply its cost.
46. As a maintainer, I want the cost of in-flight tickets shown separately, so that a busy day does not look like waste.
47. As a maintainer, I want tickets awaiting release shown with their value, so that ROI is not understated while a release is pending.

## 2. Traffic and the other per-unit resource counters

### 2.1 What has to be measured

| Quantity | Why |
|---|---|
| bytes in and out per unit, and per category (model API, git, GitHub API, package installs) | capacity (the origin enforces GB per hour and GB per day budgets through an admission gate) before price |
| git fetch and clone volume | the one category that scales with repository size |
| GitHub REST/GraphQL/search calls per unit, against the shared quota | the quota belongs to an identity (5,000 REST calls per hour per token) and is shared by every unit, every host using that token, and CI |
| CPU-seconds and memory peak per unit | host compute cost; capacity |

### 2.2 Choice

Tiered, and each row of the ledger says which tier produced it (`net.source`, `cpu.source`):

| Tier | Mechanism | Granularity | Works when |
|---|---|---|---|
| 1 | `IPAccounting=yes` on the unit, read as `IPIngressBytes` / `IPEgressBytes` at unit end | exact, per unit, IPv4 and IPv6 | the unit runs under the **system** manager and the kernel has cgroup BPF |
| 2 | the host's rootless socket sampler: `ss -tinpe` byte counters (`bytes_received`, `bytes_acked`) which carry the socket's `cgroup`, attributed to the unit by cgroup name or by pid ancestry, read as the delta over the unit's life | sampled (2 s), TCP only, loses sockets shorter than the interval; loopback legs to a local proxy are counted on both sides | Linux, any manager, no root |
| 3 | nothing | `null`, `source: "n/a"` | macOS and hosts where `ss` is absent. A per-process `nettop` read is possible on macOS and is not planned (not verified: no macOS host was available) |

Protocol-level counters complete the picture where they exist and are cheap: GitHub calls per unit from the existing `gh` measurement shim (count, by resource class), the quota from `gh api rate_limit` (free), and for git the growth of the object store (`git count-objects -v`) around a fetch. Git's own Trace2 does not help (probe E7).

Rejected: moving the stage units to the system manager only to get IP accounting (large blast radius for one number that is a capacity metric at the origin); an nftables `socket cgroupv2` counter per unit and a BPF tracer (both need root and a rule or program per unit); a per-unit network namespace (heavy); counting at the egress proxy with a per-unit credential (the proxy exists only on some hosts, and a credential per unit is more machinery than the sampler).

### 2.3 What was observed on this host

Host: systemd 257.13, Linux 6.18.54.1-microsoft-standard-WSL2 (kernel config has `CONFIG_BPF_SYSCALL=y` and `CONFIG_CGROUP_BPF=y`), cgroup v2 with `nsdelegate`, `kernel.unprivileged_bpf_disabled=2`. The user manager runs with one effective capability bit (`CapEff=0x0000000800000000`, `CAP_WAKE_ALARM`); it has no `CAP_BPF`, `CAP_NET_ADMIN` or `CAP_SYS_ADMIN`. `sudo` needs a password, so nothing was run under the system manager.

| # | Probe | Result |
|---|---|---|
| E1 | `systemd-run --user -p IPAccounting=yes --wait --collect curl -sS -o /dev/null https://api.github.com/zen` (with the proxy variables the host needs imported with `-E`) | unit ran, `Finished with result: success`, runtime 1.2 s. The `--wait` summary printed `Service runtime`, `CPU time consumed: 73ms` and `Memory peak: 5.5M (swap: 0B)` and **no** `IP traffic` line. Afterwards (the unit is gone because of `--collect`) `systemctl --user show` returns `IPIngressBytes=[no data]`, `IPEgressBytes=[no data]` |
| E2 | same command as a long-lived unit without `--collect`, polled while the curl had finished and the unit was still active | `IPAccounting=yes` is accepted and shown back, but `IPIngressBytes`, `IPEgressBytes`, `IPIngressPackets` and `IPEgressPackets` are all `[no data]` while `CPUUsageNSec` (79.9 ms) and `MemoryCurrent` are populated. After the unit exits, `CPUUsageNSec` and `MemoryPeak` read `[not set]` |
| E3 | `man systemd.resource-control` (the installed page) | "Note that this functionality is currently only available for system services, not for per-user services." This is documented behavior, not a quirk of this kernel |
| E4 | `ExecStopPost=` script of a transient user unit that runs `systemctl --user show` on its own unit | still readable: `ActiveState=deactivating`, `SubState=stop-post`, `CPUUsageNSec=159159000`, `MemoryPeak=2908160`; `IPIngressBytes` / `IPEgressBytes` `[no data]`. `SERVICE_RESULT=success`, `EXIT_STATUS=0` and `INVOCATION_ID` are in the environment |
| E5 | a script inside a transient user unit reading `/sys/fs/cgroup$(own cgroup)` | `cpu.stat` (`usage_usec`, `user_usec`, `system_usec`), `memory.peak` and `pids.peak` are readable; `io.stat` is missing (the io controller is not delegated to the user subtree) |
| E6 | a `systemd-run --user --scope` unit (the shape `bin/luna` and `bin/zc` use) polled from outside while it ran | `CPUUsageNSec`, `MemoryPeak`, `MemoryCurrent` populated while running, `[not set]` after exit; IP counters `[no data]` |
| E7 | `GIT_TRACE2_EVENT` on a shallow clone with git 2.47.3 | events present: `version`, `start`, `cmd_name`, `child_start`, `region_enter/leave`, `data` (`transfer negotiated-version`, `negotiation_v2 total_rounds`, `fetch filter/none`), `counter` (`fsync hardware-flush`), `data_json` (`traverse_trees statistics`), `exit`. **No byte counter.** `git count-objects -v` reports `size-pack` |
| E8 | `ss -tinpe` as the unprivileged user | per-socket `bytes_received`, `bytes_acked`, `bytes_sent`, `users:(("comm",pid=...))` and `cgroup:` are present without root |
| E9 | `gh api rate_limit` | free call; `core` limit 5000 with `used`; the same numbers arrive as `X-Ratelimit-*` headers on every response |
| E10 | the origin's rows in `metrics/traffic-<day>.jsonl` | every one of 800 sampled process records in the last 40 samples carried a `cgroup`, so a per-unit join on cgroup name is possible with the data the sampler already holds |

Conclusions:

- `IPAccounting=` does not work for user units on this host or, per the manual, on any host. That is a platform fact, so the design does not wait for a fix.
- CPU time and peak memory per unit are free and exact on Linux when read inside the unit (guardian, `ExecStopPost`) or by polling a scope; `--wait` prints them too but as rounded text (`2.5M`), which is why the ledger does not parse it.
- Per-unit network bytes come from the socket sampler. Its limits are documented in its own `limitation` field (short-lived TCP, UDP/VPN and permission-hidden processes stay unknown; categories include local app-to-proxy legs and can exceed the interface counter). The ledger therefore labels such numbers `source: "socket-sampler"` and `coverage: "sampled"`.
- Not verified: IP accounting under the system manager (needs root), macOS `nettop`, and containers where the cgroup is shared by every process of the container.

Reproduction commands are in Appendix A.

### 2.4 Portability

PORTABILITY.md defines the runners. What each yields:

| Platform (PORTABILITY.md section 2) | CPU and memory per unit | Network per unit | GitHub calls per unit |
|---|---|---|---|
| Linux with a systemd user manager (the origin, WSL2 with systemd) | cgroup `cpu.stat` and `memory.peak`, read in the unit; scopes polled | tier 2 sampler; tier 1 not available | shim, by cgroup unit name |
| Linux with units under the system manager | cgroup, as above | tier 1 exact (untested here) | shim |
| Linux or WSL2 without systemd (`ZF_RUNNER=pidfile`) | `getrusage(RUSAGE_CHILDREN)` in the runner: CPU exact, memory is the largest single descendant's peak RSS (`maxrss`, normalised from KiB) | tier 2 if `ss` exists and the processes are visible, else `n/a` | shim, by run-ledger unit name |
| macOS (launchd, pidfile runner) | `getrusage(RUSAGE_CHILDREN)` (CPU exact, `maxrss` in bytes) | `n/a` | shim |
| containers | `getrusage`; the cgroup is the container's, not the unit's | tier 2 if allowed, else `n/a` | shim |

Rules that hold on every platform:

1. A quantity the platform cannot supply is `null` with `source: "n/a"`. It is never written as 0 and never summed as 0: the rollup prints `n/a (k of N units)` next to any total built from a partly measured column.
2. A quantity the platform should supply but the collector did not find is `null` with `source: "missing"`; those rows feed `roi.unknown_cost_pct_7d` (section 3.8).
3. Platform facts come from the helper layer PORTABILITY.md designs (`hostinfo.py`, `proc.sh`). This design adds one function, `unit_meter()`; it lives in the collector module and moves beside those helpers when they exist. The execution-admission module already isolates `/proc` behind `ZF_EXECUTION_PROC_ROOT`; the same seam covers cgroup paths in tests.

## 3. ROI definition

### 3.1 Formula

Window `W`: fixed UTC windows, default 7 days; also 1 day and 30 days. A unit belongs to the window of its end timestamp; a ticket is delivered in the window of its delivery event.

```
D        tickets delivered in W (released if the deployment has releases, else merged),
         minus tickets reverted before the end of W
V_effort sum over t in D of  H(class(t)) x R
V_time   sum over t in D of  max(0, L_h(class(t)) - L(t)) x R_delay          (R_delay default 0: term off)
V        V_effort + V_time

C_model  see 3.2        C_ci see 3.3        C_host see 3.4        C_net see 3.4
C        C_model + C_ci + C_host + C_net, summed over EVERY cost event ending in W

ROI      (V - C) / C                       (null when C = 0)
waste    C_waste / C                       (3.6)
cost per delivered ticket   C / |D|
```

`H(class)` is effort in hours, `R` the hourly rate, `L_h(class)` the human lead time in hours, `L(t)` the ticket's actual lead time (issue created to delivered, the join that `node_health.py:delivery_metrics` already performs). All four are rows of the price table (3.7).

"Delivered" depends on the deployment: with a release stage (the origin, where release acceptance is recorded as `release-closer: deployed=<sha> closed=[ids]`) a ticket counts when released; merged-but-unreleased tickets are shown as `awaiting release` with their value, and a second ROI figure "if awaiting-release counted" is printed beside the headline. Without a release stage, merged is delivered.

`V_time` is deliberately off. The money value of being earlier than a human is business-specific; shipping an invented cost-of-delay rate would make ROI look more precise than it is. Lead time against the human baseline is reported as its own number (`roi.slower_than_human_pct_7d`, 3.8) and `R_delay` can be set when the operator has a defensible rate.

### 3.2 Model cost

For each model on a unit-end row, with `p` the model's price per million tokens:

```
api_list:     (input_fresh x p_in + cached x p_cached + cache_write x p_cache_write + output x p_out) / 1e6
```

where `input_fresh = input - cached` for providers that report cached tokens as a subset of input (Codex), and the three Anthropic-style counters (plain input, cache read, cache creation) are kept separate so cache creation can be priced at its own rate. Reasoning tokens are recorded when the provider reports them and are not added to output cost; this assumes the provider already counts them inside output tokens, which has to be checked per provider when its price row is added (the Codex event carries `reasoning_output_tokens` beside `output_tokens`; not verified that it is a subset).

Two cost bases per provider, set in the price table:

| `mode` | Meaning | Use |
|---|---|---|
| `api_list` (default) | tokens x public API list price, "API-equivalent". It is not an invoice | the only basis computable without private billing facts; the one-off retrospective ledger used it |
| `subscription` | the provider's monthly fee, prorated to the window and allocated to units by their share of fresh tokens | the real marginal-zero, average-nonzero cost of a flat plan |

Both are always computed when a fee is configured. The headline uses `cost_basis` from the price table; the report prints the other beside it and `cost.subscription_utilization_7d` = (API-equivalent cost of the window) / (prorated fee): above 1 the plan is cheaper than list price, below 0.3 it is more than three times dearer. A model with no price row has `cost = null` and its tokens still count; a row whose models are not all priced is `cost_known: false` and is excluded from `C` but listed with its token count under "unpriced".

### 3.3 CI cost

One `ci-run-end` row per completed workflow run (section 4): jobs with `minutes`, `conclusion` and a `runner_class`. The class is derived from the runner labels with an ordered match list in the price table (the dashboard's `runner_pool` already classifies live runners the same way). `C_ci = sum(job_minutes x usd_per_minute[class])`.

A class priced `0.0` must say why in its `basis` field (for example "self-hosted: compute is counted under host") and the report footnotes every class priced at zero, so "free" is a stated choice rather than a default. A class with no price is `null`: minutes counted, dollars unknown.

Attribution: PR runs map to a ticket through the PR head branch (`agent/issue-<n>`) and the work order's PR number, as `ci_spend.py` already links runs to work orders; postsubmit runs on the default branch map to the tickets of the landing batch for that sha; anything else is overhead (3.6).

### 3.4 Host and traffic cost

```
C_host = cpu_core_hours x core_hour_usd          core_hour_usd = monthly host cost / (730 h x cores)
C_net  = (rx_bytes + tx_bytes) / 1e9 x usd_per_gb
```

The same price can be given as a whole-host hour: `host_hour_usd x (unit core-seconds / host core-seconds)`; the table stores `core_hour_usd` and derives it from `host_hour_usd` and `cores` when those are given instead. Memory is not priced: machines are priced by core, and peak memory is a capacity number (admission already uses a memory floor). `usd_per_gb` defaults to `0.0` with `basis: "flat-rate link"`; the origin treats traffic as a budgeted capacity limit (GB per hour, GB per day), so the GB figure matters more than its price. Both are `null` for `n/a` units.

### 3.5 Attribution rules (the places double counting would happen)

1. Every row has `tickets: [...]`. A unit that served several tickets (triage batch, advisor batch, release batch) is split **equally** across its members at read time. The existing `issue_spend_budget_status` replicates a `batch:` row to every member because each member "paid for that call"; that is right for a budget gate and wrong for a cost total.
2. Resumed Codex sessions: tokens are the delta past the dispatch baseline (`worker_cost.measure` already does this); the ledger stores the delta, never the cumulative counter.
3. A worker that failed over to another backend produces two rows (two units), each with its own tokens.
4. A token count that cannot be read is `null` with `source: "missing"` and `complete: false`; it is never 0 (`usage_reader.Unavailable` already enforces that for the sources it reads).
5. Units with no ticket (index refresh, worktree cleanup, maintenance, main-red recovery steps) are `overhead`; they are in `C` and shown on their own line. The scheduler's own ticks and the dashboards are not units and are not measured in the first version, and interactive operator sessions are out of scope (section 10); they are the largest known omission.

### 3.6 Waste

Waste is the cost of units and tickets that produced nothing delivered:

| Class | Definition | Source of the verdict |
|---|---|---|
| `no-output` | the unit ended without the report or diff it exists to produce, or was killed (OOM, timeout, signal) | work-order history `worker-no-output`; `terminal_cause` of `attempt-terminal` |
| `quota-aborted` | the provider limit ended the run | history `worker-provider-limit` |
| `closed-unmerged` | the ticket or PR was closed, `wontfix`, duplicate or superseded without a delivery: **all** units of that ticket | work-order stage `closed` with no `merged`/`landed` event; ticket labels |
| `reverted` | delivered and then reverted by the end of the window or within 30 days: value goes to 0 and the ticket's whole cost counts as waste | the revert marker match already used by `delivery.revert_rate_30d_pct` |
| `ci-cancelled`, `ci-superseded`, `ci-nonproduct` | CI minutes that could not change a verdict | `ci_spend.py:classify` |

Not waste: repair and rereview units of a ticket that is eventually delivered. That is rework, a productive overhead reported on its own (`loop.rework_token_pct` already bounds it). Tickets still open at the end of the window are **in flight**: their cost is in `C`, in neither waste nor delivered, and printed as `in_flight_cost`.

### 3.7 The price table

`engine/state/roi-prices.json` (versioned) with an optional per-host override `$AGENT_HOME/roi-prices.local.json`. It extends the shape of the one-off retrospective's price file (per-model rates with cache write tiers and a price card for long prompts, each with `source_url` and `retrieved`) and of `config.template.json`'s `pricing` block. Illustrative shape:

```json
{
  "schema": "zf-roi-prices/v1", "currency": "USD", "version": "2026-10-29",
  "cost_basis": "api_list",
  "models": { "example-model": { "provider": "example",
      "per_million": {"input": 0.10, "cached": 0.01, "cache_write": null, "output": 0.50},
      "long_prompt": null, "source_url": "https://...", "retrieved": "2026-10-24" } },
  "providers": { "example": {"mode": "api_list", "subscription_usd_per_month": null} },
  "ci":   { "classes": [ {"match": {"label": "self-hosted"}, "usd_per_minute": 0.0, "basis": "counted under host"},
                         {"match": {"os": "linux", "hosted": true}, "usd_per_minute": null} ] },
  "host": { "core_hour_usd": null, "basis": "monthly cost / (730 h x cores)" },
  "traffic": { "usd_per_gb": 0.0, "basis": "flat-rate link" },
  "value": { "human_hour_usd": 75, "assumed": true, "has_releases": true,
             "size_from": ["label:size/", "lines"], "size_bands_lines": [300, 800, 2000], "default_class": "M",
             "effort_hours": {"S": 3, "M": 6, "L": 12, "XL": 24},
             "lead_hours":   {"S": 24, "M": 48, "L": 96, "XL": 168}, "delay_usd_per_hour": 0 }
}
```

Defaults and what backs them:

| Default | Basis |
|---|---|
| `effort_hours.S = 3` | the engine's own human baseline for a small change, "2-4 h focused work (estimate)" (`NODE-HEALTH.md`, `implement.wall_p50`) |
| `M`, `L`, `XL` = 6, 12, 24 | doubling per size band. **No measured source.** The size bands are the ones `node_health.py` already uses for rework by size (under 300, 300-800, 800-2000, over 2000 changed lines, from `pr-sizes.json`); a `size/<class>` label overrides them |
| `lead_hours.S = 24` | DORA elite lead time under one day, the engine's existing healthy bound for `delivery.issue_to_accept_p50_*` |
| `lead_hours.XL = 168` | one week, the engine's existing unhealthy bound for `delivery.issue_to_accept_p95_*` |
| `M`, `L` lead = 48, 96 | interpolation. Estimates |
| `human_hour_usd = 75`, `assumed: true` | **placeholder**. The operator must replace it with a fully loaded rate; while `assumed` is true every ROI figure is printed with "assumed rate" |
| unknown size | a ticket with no label and no PR line count (direct-main landings without a PR) takes `default_class` and is counted in `quality.size_assumed` |

The value side is assumption-driven by construction; the cost side is measured. The report therefore prints cost per delivered ticket, waste share and the unknown share as the numbers that can be audited without trusting the table, and ROI beside them. ROI is for ranking configurations and for catching a broken economy, not for stating a truth.

A worked example with illustrative inputs: one S ticket delivered, `V = 3 h x $75 = $225`; model cost `$0.87` (the highest pipeline-worker figure in the retrospective, below), CI `$0` (self-hosted, counted under host), host `3.0 core-h x $0.04 = $0.12`, traffic `0.6 GB x $0 = $0`; `C = $0.99`; `ROI = (225 - 0.99) / 0.99 = 226`. With 35% waste the same delivered ticket carries `0.99 / 0.65 = $1.52` and `ROI = 147`. At the healthy waste bound (20%) it is `$1.24` and 181.

### 3.8 Standards: healthy and unhealthy bounds

Every new number follows `NODE-HEALTH.md`: one row with an id, a healthy bound, an unhealthy bound, a direction, a meaning, a source, and evidence for the bound. Where a history exists the bound is derived the way `usage_reader.daily_bound` and `worker_cost.ticket_bound` derive theirs (healthy = p50 x 1.5, unhealthy = p90 x 2 of the preceding values, provisional below 7 samples) with a frozen fallback. A metric that cannot be computed reports `NO-DATA` (for example the subscription utilization when no fee is configured); it never reports a number. All frozen fallbacks below are first-cut, dated 2026-10-29, and are replaced by history after seven samples. Where the evidence is a capacity envelope rather than a measurement, the row says so.

| Metric id | Node | Healthy | Unhealthy | Direction | Evidence for the bound |
|---|---|---|---|---|---|
| `roi.net_ratio_7d` | economics | >= 5 | <= 1 | higher is better | First cut. 0 is break-even; <= 1 means value under twice cost. At the defaults a delivered S ticket is worth $225 against under $1 of cost, so the bound trips only when cost per ticket rises more than 100x or output collapses. It guards the economy, not the noise. Re-bases when the price table changes |
| `roi.cost_per_ticket_usd_7d` | economics | <= 1.5 | >= 3.0 | lower | Fallback only: the highest pipeline-worker figure in the 2026-10-22..24 retrospective was $0.87 per landing (Codex rollout cross-check, $143 over 164 landings), so 1.7x and 3.4x of it. History-derived after 7 daily samples |
| `roi.waste_cost_pct_7d` | economics | <= 20 | >= 35 | lower | Same bounds as `ci.waste_runner_pct` (lean: work that cannot change the outcome is waste) |
| `roi.unknown_cost_pct_7d` | economics | <= 5 | >= 20 | lower | Same bounds as `review.findings_missing_pct`: a missing quantity is counted, never read as zero. Counts `missing` and unpriced, not `n/a` |
| `roi.slower_than_human_pct_7d` | economics | <= 25 | >= 50 | lower | First cut, anchored to `lead_hours` (itself anchored to the existing `delivery.issue_to_accept_*` bounds of 24/72 h) |
| `cost.cache_hit_pct_7d` | economics | >= 90 | <= 70 | higher | Observed 95.6-98.2% across the four models of the retrospective (cache reads / (input + cache reads + cache writes)). Cached input costs about a tenth of fresh input (`usage_reader.py`), so 70% makes input about 2.9x dearer than 97% |
| `cost.subscription_utilization_7d` | economics | >= 1 | <= 0.3 | higher | First cut: below 1 a flat plan costs more than list price; below 0.3 more than 3x. `NO-DATA` unless a fee is configured |
| `ci.runner_min_per_ticket_7d` | ci+merge | <= 150 | >= 400 | lower | Fallback from one 5-hour `ci-spend.json` sample on 2026-10-30 (1,876 runner-minutes, about 9,000 a day) over 40-136 landings a day (66-225 per landing). One sample; history replaces it |
| `host.cpu_core_hours_per_ticket_7d` | host | <= 8 | >= 45 | lower | Provisional, **not measured** (no CPU-seconds exist today): a capacity envelope of 12 cores x 24 h x the 85% CPU target of the launch gate (`bin/luna`) = 245 core-hours a day, over the daily landings 10-23..29 gives 3.8, 4.5, 6.1, 22.3, 12.3, 5.3, 1.8; p50 x 1.5 and p90 x 2. Replaced by history after 7 samples |
| `traffic.gb_per_ticket_7d` | host | <= 0.9 | >= 4.3 | lower | Host-wide wire GB per landing over the 7 days 10-23..29: 0.38, 0.45, 0.56, 0.59, 0.85, 1.29, 2.17; p50 x 1.5 and p90 x 2. Host-wide, so an upper bound; landings stand in for tickets |
| `gh.core_used_pct` | host | <= 50 | >= 75 | lower | DISTRIBUTED.md section 4.10 sheds optional reads below 25% remaining, which is 75% used |
| `gh.calls_per_ticket_7d` | host | <= 600 | >= 3,500 | lower | Shim rows per landing, same 7 days: 126, 136, 390, 405, 690, 951, 1,744; p50 x 1.5 and p90 x 2. A lower bound on calls because the shim is opt-in |

Time and flow numbers are not duplicated: wall time per stage is `implement.wall_p50`, `review.wall_p50`, `repair.wall_p50`, `time_sinks`; lead time is `delivery.issue_to_accept_*`; throughput is `flow.*`. ROI reads those rather than re-measuring.

## 4. The ledger

### 4.1 Location, writer, protocol

| Item | Decision |
|---|---|
| File | `$AGENT_HOME/metrics/units-YYYY-MM.jsonl` (UTC month of the event), next to `efficiency-YYYY-MM.jsonl` and `traffic-YYYY-MM-DD.jsonl` |
| Why not the efficiency ledger | it has the append protocol and the cross-language helpers, but it is read in full by `efficiency-regression.mjs` and the daily report; at the origin it already grows by 0.06-3 MB a day (1.5 MB on 2026-10-29, 7.3 MB so far in October), and about 1,500 unit-end rows a day would add about 1.2 MB, roughly doubling the busiest days. A separate file family avoids slowing readers that do not need cost rows. The outcome events the rollup needs (`merged`, `source-landed`, `ticket-released`, `ticket-closed`, `production-roll-completed`) already live there and are read from there |
| Protocol | the one `efficiency_metrics_append_rows` implements: directory 0700, file 0600, exclusive `flock` on `<file>.lock`, one JSON object per line, stable `event_id`, at-least-once. The collector implements the same protocol in Python (about 15 lines); shell callers get the same helper with a family argument if they ever need it |
| Single writer | the **collector** (`roi_collect.py`), started by a 5-minute timer listed in `pipeline-timers.list`. Hooks that must act while a unit is still alive only stash perishable counters (4.3); they never append to the ledger |
| Dedupe | readers keep the **last** row per `event_id` ("last wins"). The collector may re-emit a row when late data arrives (token logs flushed after the unit ended); nothing is rewritten |
| Schema evolution | `schema_version: 1`; readers ignore unknown fields; a new field is additive |
| Volume | 885 worker logs and about 530 execution units were the peak days at the origin: at most about 1,500 rows a day, about 800 bytes a row, about 36 MB a month |
| Retention | raw monthly files kept at least 400 days; months older than 60 days may be gzipped (the reader accepts `.jsonl.gz`); a derived per-day aggregate (`metrics/roi-daily.json`, quantities not dollars) is disposable and rebuilt from the ledger |
| Time | UTC everywhere; the dashboard converts for display only |

### 4.2 Event types

`unit-end` (one per unit), `ci-run-end` (one per completed workflow run; a CI run is a unit with its own end), and `gh-quota` (one sample per collector run: the shared API quota has no unit). All share the envelope below.

```json
{
  "schema_version": 1, "record_type": "event", "event_type": "unit-end",
  "event_id": "host-a:unit-loop:issue-1234:impl-issue-1234-20261029T181200Z.worker.log:unit-end",
  "ts": "2026-10-29T18:31:07Z", "start_ts": "2026-10-29T18:12:00Z", "wall_s": 1147.0,
  "host": "host-a",
  "unit": {"family": "unit-loop", "stage": "implement", "key": "issue-1234", "attempt": 1,
           "backend": "codex", "outcome": "ok", "exit": {"status": 0, "result": "success"}},
  "tickets": [1234], "pr": 5678, "sha": null,
  "models": [{"model": "example-model", "provider": "example", "effort": "high", "calls": 1,
              "input": 4200000, "cached": 4000000, "cache_write": null, "output": 61000, "reasoning": null,
              "reported_cost_usd": null, "source": "codex-turn-events", "complete": true}],
  "cpu":  {"seconds": 301.4, "source": "cgroup"},
  "mem":  {"peak_bytes": 1830000000, "source": "cgroup"},
  "net":  {"rx_bytes": 920000000, "tx_bytes": 41000000, "source": "socket-sampler", "coverage": "sampled"},
  "gh":   {"core": 41, "graphql": 6, "search": 0, "failed": 1, "source": "shim"},
  "git":  {"object_store_growth_bytes": null, "source": "n/a"}
}
```

`ci-run-end`: `{event_id: "<repo-run-id>:<attempt>:ci-run-end", ts, workflow, event, branch, head_sha, pr, tickets, jobs: [{name, runner_class, minutes, conclusion}], waste: "ci-cancelled" | "ci-superseded" | "ci-nonproduct" | null}`. `gh-quota`: `{event_type: "gh-quota", ts, host, resource: "core", limit, used, reset_at}`.

`outcome` values are `ok`, `no-output`, `killed`, `oom`, `timeout`, `quota`, `cancelled`, `failed`. Ticket-level outcomes (merged, released, closed unmerged, reverted) are never stored on a unit row: the rollup joins them from the outcome events, so a late revert changes the report without touching history.

### 4.3 Who captures what, by launch family

| Family | Launch path | Perishable counters (die with the unit) | Durable sources the collector joins later | End of unit |
|---|---|---|---|---|
| A. issue-loop transient services: triage, recut, advisor, release, land, node owners, hand sessions, post-land | `issue-pipeline.sh:dispatch` and siblings use `systemd-run --user --unit ... --collect`; the PATH shim `execution-shim/systemd-run` wraps every worker command in `execution-admission.py run-unit` | the **guardian** (the Python process that already waits on the child) reads the unit's cgroup (`cpu.stat`, `memory.peak`) or `getrusage`, and the net delta, then writes a stash file | spend-log rows (`lib.sh:record_premium_spend`), `state/<n>.json` `unit_results`, `execution-release` and `attempt-terminal` events, `gh-calls.tsv` rows by unit name and time | `child.wait()` returns in the guardian (the same place `execution-release` is emitted) |
| B. unit-loop workers: implement, repair, review, rereview, scheduler-run triage | `scheduler.sh:dispatch` runs `codex exec` or `claude -p` under `setsid`, no systemd unit, no cgroup; harvest in `scheduler.sh:harvest_workers` | none today: cpu, mem and net are `n/a` until RT-13 | `workers.json` rows and the durable `*.worker.log` files through `worker_cost.run_rows` and `usage_reader` | harvest (read after the fact; no edit to the scheduler) |
| C. scratch and hand workers | `bin/luna`, `bin/zc`, `bin/worker` (`systemd-run --user --scope`, memory-capped), `night/dispatch.sh` (scope), `dispatch-codex.sh` (owner-session service with `ExecStop`) | the wrapper polls its scope every 30 s and stashes the last poll (E6); error bound: the last 30 s | `events.jsonl` (`turn.completed` usage, zcode `result` lines), `hand:<name>` spend rows | wrapper exit |
| D. CI runs | GitHub Actions | n/a | jobs API (`ci_spend.py`) | run completed |

The stash is `$AGENT_HOME/run/unit-meter/<safe event_id>.json`, written atomically by the hook, consumed and deleted by the collector after it appends the ledger row, pruned after 7 days if the collector is down. If the stash cannot be written the unit's exit status is unchanged and the row will say `source: "missing"`; a hook on the hot path never changes what the unit does.

Why a stash and a single writer rather than every hook appending: the perishable counters can only be read at the unit's end, the tokens are only readable after the worker's log is flushed and (for batches) after the batch is split, and the ticket outcome comes later still. The collector is the one place where those meet, it is idempotent, and it can be run again over the same inputs.

### 4.4 N hosts (DISTRIBUTED.md)

- The ledger is **per host**, like the other `metrics/*` files and `units.json`; there is no shared file and no shared lock. `host` is `ZF_HOST_ID`; every `event_id` starts with it, so rows from different hosts cannot collide.
- A ticket's cost can span hosts (implement on one, repair on another). The ticket number is on every row, so a **reader that merges** per-host files sums them. `zenoforge roi --merge DIR [DIR...]` (and the rollup's `--merge`) takes copies of other hosts' `units-*.jsonl[.gz]` and `efficiency-*.jsonl`, gathered by any transport the operator already has (rsync, a shared drive, a release artifact), dedupes by `event_id`, and labels the report `scope: merged (hosts: a, b)`. Merging only reads copies, so it needs no lock.
- Without a merge the report is labelled `scope: host-local` and carries no fleet ROI claim; a delivered ticket whose cost is partly on another host shows `cost_partial: true`.
- Outcomes (merged, released) are global facts recorded by whichever host performed the action; the union of the hosts' outcome events is complete.
- Windows use each row's own `ts` (each host's own clock); cross-host skew moves a row across a window edge by seconds, which the design accepts.
- An optional later step publishes a small day summary in the host's `refs/status/<host>` record next to `tokens.day_used` (DISTRIBUTED.md section 4.9), so a fleet view needs no file copying. It is not in the tickets: it waits for the distributed work.
- The GitHub quota belongs to an identity. Two hosts sharing one `GH_TOKEN` both see the global `used` in `gh-quota` rows and each sees only its own call counts; the report shows `unattributed = used - sum(own calls)`.

## 5. Inventory of what is measured today

Granularity key: U = unit/worker invocation, T = ticket, W = work order, S = stage, M = model, D = day, H = host-wide, B = backend. Paths are relative to `engine/`.

### 5.1 Tokens

| What | Where (file:function) | Source of truth | Granularity | Gaps |
|---|---|---|---|---|
| Codex tokens per worker invocation | `mac-autopilot/worker_cost.py:measure`, `run_rows`; reader `mac-autopilot/usage_reader.py:codex_stream_facts`, `TurnEventStore` | the worker's `*.worker.log` (`turn.completed` usage, cumulative; resume runs subtract the dispatch baseline) | U, W, T, S, B | keeps input, cached, output only: the event also carries `reasoning_output_tokens` and `cache_write_input_tokens` (key names read from a real event). Model comes from the `workers.json` row, which keeps 60 harvested rows: older logs report model `""` and attribute by file name |
| ZCode tokens | `usage_reader.py:zcode_stream_usage` | last `{"type":"result"}` line of the log | U | drops `reasoningTokens`, `modelRequestCount`, web search and fetch counts, all present in the line |
| Claude review tokens | `usage_reader.py:claude_session_usage`, `claude_window_usage` | Claude project transcripts, one record per API response | session, D | cache creation is folded into input, so cache writes cannot be priced; the worker log has no usage (`worker_cost.measure` returns none). Interactive operator sessions are outside the meter (the module says so) |
| Daily token meter | `usage_reader.py:_codex_day`, `daily_bound` | Codex rollouts + Claude transcripts; writes `budget.json`, `budget-history.json` | D, provider | fresh tokens only; bound is p50 x 1.5 / p90 x 2 of earlier days (the convention reused here) |
| Tokens per work order | `mac-autopilot/scheduler.sh:harvest_workers` (`set_unit ... .tokens +=`), `workers.json` `token_accounting` | session usage end minus start | W | raw input+output (cached included), no model split, no reasoning |
| Per-ticket token rollup | `worker_cost.py:aggregate`, `ticket_spend`, `ticket_of`; `mac-autopilot/workorder_cost.py:work_orders` | the cost rows above joined to `units.json` | T, S, B, D (24 h) | tokens only; node_health keeps the 60 largest in `ticket_spend` |
| Spend log | `lib.sh:record_premium_spend`; readers `lib.sh:issue_spend_budget_status`, `night/efficiency-regression.mjs:readSpend` | `spend/YYYY-MM-DD.log`: epoch, role, model, issue or `batch:` list or `hand:<name>`, cost_usd, tokens, note | one model call | written by triage (single and batch), recut, advisor, release outcome and hand dispatch only (no implement, review or repair worker); one token number (fresh for json streams, raw for the legacy footer); `cost_usd` only when the CLI reports `total_cost_usd`, otherwise `unobservable`; `batch:` rows count once per member in the budget gate |
| Codex quota gate | `lib.sh:codex_budget_status`, `codex_budget_reserve`, `_codex_budget_actual_usage` | the spend log (codex rows) | D, role | a gate, not a measure; it undercounts for the reason above, so the gate and `usage_reader`'s meter disagree |
| Headline "tokens per released issue" | `night/efficiency-regression.mjs` (`metrics.tokens_per_released_issue`, rule at `metricRules`), `night/daily-perf-report.sh` | spend-log tokens / released state files | D | same undercount |
| Eval runs | `worker_cost.py:eval_costs` | `eval/<label>/results.json` | label | tokens and wall only |
| One-off cost retrospective | the retrospective's `cost-ledger.py` and `model-prices.json` (outside the engine) | Claude transcripts, Codex events and rollouts, ZCode events | provider, model, day, category, run key | not wired into the pipeline; the only place with cache-write tiers, long-prompt price cards, and interactive sessions |

### 5.2 Money

| What | Where | Source | Granularity | Gaps |
|---|---|---|---|---|
| Price per model | `mac-autopilot/config.template.json` `pricing` (in/cached/out per million; two models and a default), `mac-autopilot/gen_dashboard.py` `MODEL_PRICING` | list prices, hard-coded | M | no cache-write rate, no long-prompt card, no dates or sources, unknown models fall back to a cheap default (flagged in the pricing note, but the dollar figure is still a number) |
| Dollars on the dashboard | `gen_dashboard.py` (module level: `session_rows`, `by_model`, `by_unit`, `cost_data`) | Codex rollouts of yesterday and today | session, M, U, D | Codex only; mixed-model sessions unpriced; two days; Claude and ZCode never priced |
| Reported dollars | `lib.sh:model_cost_usd` into spend-log field 5 | the CLI's `total_cost_usd` | one call | triage/recut Claude calls only |
| Subscription fees | nowhere | n/a | n/a | not recorded; the retrospective left them `null` because the plan tier was not established. No field says which provider is on a flat plan |
| CI dollars | nowhere | n/a | n/a | minutes only |

### 5.3 CI

| What | Where | Source | Granularity | Gaps |
|---|---|---|---|---|
| Runner minutes and waste by reason | `mac-autopilot/ci_spend.py:job_minutes`, `classify`, `main` writing `ci-spend.json` and `ci-spend-cache.json` | Actions jobs API (jobs that held a runner) | window (default 5 h), reason | no runner class (`runner_name` and labels are in the job object but only `[conclusion, minutes]` is kept), no dollars, no per-day or lifetime figure (cache pruned at 24 h), no ticket, no PR |
| Live runner pool and queue | `gen_dashboard.py` (`runner_pool`, `ci_live`), `node_health.py` `CI_STANDARDS` | `actions/runners`, `actions/runs?status=queued` | pool, now | classifies by label for the dashboard only |
| Sampled CI timing and waste share | `night/efficiency-regression.mjs` (`ciJobTimings`, `sampledWorkflowRuns`, `ci_waste_share`), cache `night/efficiency-ci-jobs.json` | stratified bottom-k sample of runs | D | sampled, not complete |
| Cancellation audit | `ci.cancel_*` rows of `node_health.py`, `logs/actions-run-cancellations.jsonl` | the audit log | D | counts of runs, not minutes |
| Large PRs and PR sizes | `ci_spend.py:gh_pr_sizes` into `pr-sizes.json`; `node_health.py:rework_by_size` | GraphQL `additions` + `deletions` | PR | window of 30 days of ledger activity |
| CI repair spend | `mac-autopilot/waste_report.py:ci_repair_usage_section`, `ci_review_events_section` | rollouts + audit | event | read-only report, "never run from a tick" |

### 5.4 Time

| What | Where | Source | Granularity | Gaps |
|---|---|---|---|---|
| Stage durations queue to implement to review to CI to merge to production | `throughput-metrics.mjs:collectThroughputMetrics` | `state/<issue>.json` run timestamps | T, S, p50/p95 | production leg needs the real-user-path evidence markers |
| Worker wall time | `worker_cost.py:measure` | start from the log file name, end from its mtime | U | an mtime is "last write", not process end |
| Phase wait and work | `node_health.py:time_sinks`, `worker_runs`; `implement.wall_p50`, `review.wall_p50`, `repair.wall_p50` | `units.json` events + `scheduler.log` dispatch lines | S, p50/p90 | |
| Lead time issue to release accepted | `node_health.py:delivery_metrics` (`delivery.issue_to_accept_*`), release acceptance via `release_acceptances` | GitHub `createdAt` + `release-closer: deployed=... closed=[...]` | T, 7 d / 30 d | needs the full issue-unit-PR-merge-release join; unlinked ones are counted and excluded |
| Land timing | `delivery-metrics.sh:delivery_metrics_record` | `land-enqueued`, `source-landed`, `land-terminal` events | landing | |
| Stage transitions | `lib.sh:ticket_stage_record` into `state/ticket-transitions.jsonl` and `stage-entered`/`stage-exited` events | | T, S | `ticket-created` has 17 events in October, far fewer than tickets: lead-time starts use GitHub, not this |
| Human baseline | `NODE-HEALTH.md` (a single "2-4 h focused work" estimate, DORA, Google review latency) | cited | node | no per-size-class baseline |

### 5.5 Network

| What | Where | Source | Granularity | Gaps |
|---|---|---|---|---|
| Host wire bytes by category (git, gh API, model, package managers, other, unmapped) | the origin's host sampler `network-traffic.py` (called from `lib.sh:codex_budget_reserve`; not in this export) into `metrics/traffic-<day>.jsonl`, `night/network-traffic-last-result.json`; shown in `gen_dashboard.py` | interface counters + `ss` per-socket bytes | H, minute; day totals | rows are overlapping 20-minute windows (about 1,400 rows and 15 MB a day), not increments, so a per-unit sum from them double counts; per-process records carry `cgroup` (probe E10) |
| Traffic budget | `state/traffic-budget.json` (GB per hour, per day, per category) with an admission gate | | H | rule-lane file |
| GitHub calls per unit | `gh-measure/bin/gh` (opt-in via PATH) into `measure/gh-calls.tsv` (ts, systemd unit, caller, subcommand, normalized endpoint, exit code, ms); `gh-measure/summary.py` | the shim | call, unit, call site | opt-in, so counts are lower bounds; scheduler workers all appear as the scheduler service; REST, GraphQL and search not separated; no bytes |
| Scheduler call profile | `call-profile.sh`, `call-profile-summary.py` | optional per-tick TSV | tick, call site | classes of call, not cost |
| GitHub quota | not measured (DISTRIBUTED.md 4.10 designs `gh.remaining` per tick; not in the engine) | `gh api rate_limit` works (E9) | | |
| git volume | not measured | | | Trace2 has no byte counter (E7) |

### 5.6 Host compute

| What | Where | Gaps |
|---|---|---|
| CPU-seconds and memory peak per unit | nowhere (no code reads `CPUUsageNSec`, `MemoryPeak`, `cpu.stat` or `getrusage`) | everything |
| Admission snapshot: cpu %, load1, available MB at launch | `execution-admission.py` (`execution-admission` and `execution-release` events); `night/efficiency-regression.mjs:dailyResourceUtilization` | a gate sample, not a cost |
| Caps and controls | `thread-budget.sh:agent_thread_budget` (threads per run), `MemoryMax` and `CPUWeight` in `issue-pipeline.sh`, `bin/luna`, `bin/zc` | controls, not measures |
| Occupancy | `execution-admission.py` lease counts | |

## 6. Surfaces

All four read one report document, `roi-report.json`, produced by the rollup module (`roi_rollup.py`). The rollup is incremental: it keeps a per-file byte offset and a per-day aggregate of **quantities**, so a tick reads only new rows and a price change needs no re-read.

Report document (schema `zf-roi-report/v1`): `window`, `scope` (`host-local` or `merged`), `assumptions` (price table version, whether the hourly rate is assumed), `totals` (`delivered`, `cost` by component, `value`, `roi`, `waste` by class, `in_flight_cost`, `awaiting_release`), `quality` (rows, incomplete rows, unpriced tokens, `missing` and `n/a` counts per component, `size_assumed`), and breakdowns `by_day`, `by_ticket`, `by_model`, `by_stage`, `by_host`.

1. **Dashboard panel "Economics"** (`gen_dashboard.py` and `dashboard.html`): tiles for ROI, cost per delivered ticket, waste share and lead time against the human baseline, each with the healthy/warn/unhealthy marker taken from the node-health row; a 14-day stacked bar of cost by component; a table of the ten costliest tickets and the ten lowest-ROI tickets; a per-model table (tokens, cache hit, dollars or `n/a`); traffic and GitHub quota tiles; a footer with the `n/a` and `missing` counts so a partly measured total is never shown as a clean one.
2. **Daily report section "Cost and return"** (`night/daily-perf-report.sh`): yesterday against the day before and the 7-day mean in the existing metric-line shape: tickets delivered, cost by component, cost per ticket, ROI, waste share, tokens per delivered ticket, the three costliest tickets with their outcome, and the unknown count. The block must pass `maintainer_health_mail_output_contract`, the validator every report passes before it is recorded or sent.
3. **Node health rows**: the twelve rows of section 3.8 in `node_health.py` (`CRITERIA`, `MEANING`, `SOURCE`) and in `NODE-HEALTH.md` in the same landing, as the document requires. `node_health.test.sh` already fails a metric without a meaning and a source.
4. **`zenoforge roi`** (npm CLI, `cli/commands.mjs`, `cli/render.mjs`; read-only). It shells to the engine's rollup with `--json` and renders the result:

```
zenoforge roi [--days N] [--by ticket|model|stage|day|host] [--ticket N] [--json]
              [--home DIR] [--merge DIR ...] [--prices FILE]
```

Illustrative output (invented numbers):

```
ROI 2026-10-22 .. 2026-10-29 (7 d, UTC)   scope: host-local   hourly rate: ASSUMED $75
delivered       41 tickets (38 released, 3 awaiting release)
value           $11,430      (effort S 22, M 14, L 5; 2 sizes assumed)
cost            $61.20       model $44.10 (api_list) | ci $9.50 | host $7.60 | traffic $0.00
                n/a: traffic 12 of 311 units; missing: tokens 4 of 311 units (1.3%)
ROI             186.8        waste 17.4% ($10.65)   in flight $3.20
per ticket      $1.49        lead time p50 7.9 h vs human 24 h
standards       roi.net_ratio_7d OK | roi.waste_cost_pct_7d OK | roi.unknown_cost_pct_7d OK
```

`--prices FILE` answers "what if": the same ledger priced with another table. Exit codes: 0 report printed, 2 bad arguments, 3 no ledger rows in the window (a report of nothing is an error, not a zero).

## 7. Implementation decisions

Module level; paths are in section 9.

- **New modules** (Python standard library, beside `worker_cost.py`): a *ledger* module (schema check, append, read with last-wins and gzip, the price loader), a *collector* (the only writer; reads the durable sources through the existing readers), a *rollup* (ledger + outcomes + prices into the report; also the module-level CLI the npm command calls).
- **Reuse, not rewrite**: `usage_reader.Usage` gains optional `reasoning` and `cache_write` (positional callers keep working; `__add__` and `ledger_fields` extend); `worker_cost.run_rows` and `ticket_of` supply the unit-loop rows and the unit-to-ticket join; `ci_spend.classify` supplies CI waste classes; `node_health.status_of` and the `ticket_bound` convention supply the standards; `execution-admission.py` is the one hook for family A because every execution unit already passes through it; the `gh-measure` shim already gives per-unit call counts; the host sampler already holds per-cgroup bytes.
- **No new daemon** except the 5-minute collector timer; the optional unit-loop meter (RT-13) is a second, separate service and is the only other process this design adds.
- **Outcome source**: the rollup reads `merged`, `source-landed`, `ticket-released`, `ticket-closed`, `production-roll-completed` from the efficiency ledger, work-order history from `units.json`, PR line counts from `pr-sizes.json`, revert markers the way `delivery_metrics` does, and release acceptance from the `release-closer` events. It never calls GitHub per ticket.
- **Overhead and unknowns are first-class**: every total carries its `n/a` and `missing` counts; there is no code path that turns a null into a zero.
- **Rule lane**: bounds, node-health rows and the mechanism registry entry are control signals (`engine/state/rule-files.json`); the price table is a reporting input and is deliberately not in the lane, so a price change is an ordinary landing. If the maintainer wants price changes gated, adding one line to `rule-files.json` does it.
- **Held files**: nothing here edits `scheduler.sh` or `run-release.sh`. Family B is read after the fact; release units are covered by the guardian; `node_health.py`, `ci_spend.py` and `gen_dashboard.py` are already called from the scheduler, so their new behavior needs no scheduler edit.

## 8. Testing decisions

- **Good test**: it feeds external inputs and checks the report, not how the report was built. Rows, prices and outcome events in; totals, null handling and standards out.
- **Seam**: one. The rollup's function from `(ledger rows, outcome events, units, price table, window)` to `zf-roi-report/v1`. The dashboard, daily block, node-health rows and CLI renderers are each tested against a fixed report fixture, so none of them re-tests the arithmetic. The collector is tested by a contract: every row it emits validates against the schema and is accepted by the rollup.
- **Fixtures to cover**: unpriced model (cost `null`, tokens counted, ROI says partial); a `batch` row with five tickets (splits sum to the row); a resumed session (delta only); `n/a` versus `missing` (only `missing` raises the unknown share); a reverted ticket (value 0, cost waste); in-flight tickets (cost in `C`, not waste); an assumed size class; two hosts with an overlapping `event_id` (counted once); last-wins on a re-emitted row; a price change re-pricing old rows.
- **Hot path**: the guardian hook is tested for the property that matters: an unwritable stash directory, an unreadable cgroup and a `[no data]` IP read leave the unit's exit status unchanged.
- **Prior art**: `worker_cost.test.py` and `usage_reader.test.py` (fixture logs), `ci_spend.test.sh` (`--fixture`), `node_health.test.sh` (every metric needs a meaning and source), `efficiency-regression.test.mjs`, `daily-perf-report.test.sh`, `dashboard-modules.test.sh`, `execution-admission` tests with `ZF_EXECUTION_PROC_ROOT`.
- **Not tested**: the arithmetic of the price table's contents (they are data), and the real IP counters under a system manager (no root here; the test uses a recorded `systemctl show` output).

## 9. Tickets

Format: `to-tickets` issue template. Sizes: S under about 150 changed lines with tests, M 150-500, L over 500. Each ticket fits one fresh context. "Files" is listed because the maintainer asked for it; the descriptions do not depend on it. Flags: **RULE-LANE** = the file is in `engine/state/rule-files.json` and must land through the supervisor rule channel with a `Rule-Replay:` trailer (report from `rule-replay.mjs`, schema `zf-control-rule-replay/v1`, `falseStops` 0); **HOLD** = `engine/mac-autopilot/scheduler.sh` and `engine/run-release.sh` are on hold for another owner's landing. No ticket below touches a HOLD file. Exactly one (RT-8) touches RULE-LANE files.

| # | Title | Size | Blocked by | RULE-LANE | HOLD |
|---|---|---|---|---|---|
| RT-1 | Price table, ledger and the first cost report (unit-loop workers) | M | none | no | no |
| RT-2 | Value, waste and ROI in the rollup | M | RT-1 | no | no |
| RT-3 | Issue-loop and batch units in the ledger | M | RT-1 | no | no |
| RT-4 | CI runs in the ledger | M | RT-1 | no | no |
| RT-5 | CPU and memory per unit | M | RT-1 | no | no |
| RT-6 | GitHub API calls per unit and the shared quota | S | RT-1 | no | no |
| RT-7 | Network bytes per unit, with `n/a` where unsupported | M | RT-5 | no | no |
| RT-8 | Node-health rows, standards and mechanism heartbeat | M | RT-2 | **yes** | no |
| RT-9 | Dashboard "Economics" panel | M | RT-2 | no | no |
| RT-10 | Daily report "Cost and return" section | S | RT-2 | no | no |
| RT-11 | `zenoforge roi` in the npm CLI | S | RT-2 | no | no |
| RT-12 | Merge per-host ledgers | S | RT-2 | no | no |
| RT-13 | Unit-loop worker meter (optional) | M | RT-5, RT-7 | no | no (see note) |

Order of landing: RT-1, RT-2 first (a person can then run one command and see per-ticket ROI from real worker tokens); then RT-3 to RT-6 in any order; RT-7 after RT-5; the four surfaces RT-8 to RT-12 after RT-2 in any order; RT-13 last and only if the numbers justify it.

### RT-1: Price table, ledger and the first cost report (unit-loop workers)

**Parent:** this document.

**What to build:** A maintainer runs one command on a host and sees, for every unit-loop worker that finished in the last day, the ticket, stage, model, tokens (input, cached, output, reasoning where reported) and dollars, or `n/a` when the model has no price. A 5-minute timer keeps a ledger of those rows up to date by itself. Unit-loop workers are read from the durable worker logs after the fact, so the scheduler is not edited.

**Files:** NEW `engine/mac-autopilot/roi_ledger.py` (schema, append, read, price loader), `roi_collect.py`, `roi_rollup.py`, with tests; NEW `engine/state/roi-prices.json`; NEW `engine/systemd/zenoforge-roi.service`, `zenoforge-roi.timer`; EDIT `engine/systemd/pipeline-timers.list`; EDIT `engine/mac-autopilot/usage_reader.py` and its tests (optional `reasoning`, `cache_write` on `Usage`). RULE-LANE: none. HOLD: none.

**Acceptance criteria**
- [ ] A fixture of worker logs (codex, zcode, claude, a resumed session, a trimmed `workers.json`) produces ledger rows that validate against the schema; the collector run twice appends nothing the second time.
- [ ] A model absent from the price table gives `cost: null` and its tokens still count; no output anywhere shows `$0` for an unpriced model.
- [ ] Per-ticket token sums from the rollup equal `worker_cost.aggregate()` for the same fixture, and the old callers of `Usage` pass unchanged.
- [ ] Prices are applied at read time: changing the table changes the report without touching the ledger.
- [ ] Live: within 15 minutes of landing, `roi_rollup.py report --days 1` lists every worker harvested since landing, and the count equals the harvested rows in `workers.json` for the same period.

**Blocked by:** None (can start immediately).

### RT-2: Value, waste and ROI in the rollup

**Parent:** this document.

**What to build:** The same command now prints, per ticket and in total, value, cost, ROI and waste class, and the total over a window, using the outcome events the pipeline already records. Costs that are not measured yet are named in the output as missing components, so a partial ROI is labelled partial rather than looking complete.

**Files:** EDIT `engine/mac-autopilot/roi_rollup.py`; EDIT `engine/state/roi-prices.json` (value block); tests with fixtures of `metrics/efficiency-*.jsonl` outcome events, `units.json`, `pr-sizes.json`, `alerts/events.md` release lines. RULE-LANE: none. HOLD: none.

**Acceptance criteria**
- [ ] Section 3 formulas hold on fixtures, including: released versus merged-awaiting-release, a reverted ticket (value 0, whole cost waste), an in-flight ticket (cost in `C`, not waste), a closed-unmerged ticket (all units waste), `size/<class>` label overriding line bands, an assumed class counted in `quality.size_assumed`.
- [ ] With `human_hour_usd.assumed` true every ROI line says "assumed rate".
- [ ] The report lists `components_present` and `components_missing`; ROI is flagged `partial` while any component is missing.
- [ ] Sum over tickets of cost plus overhead plus in-flight equals the window total to the cent.
- [ ] Live: the next day's `roi_rollup.py report --days 1` shows, for each ticket delivered that day, value, cost, ROI and waste class with real numbers, and the per-ticket costs add up to the day total.

**Blocked by:** RT-1.

### RT-3: Issue-loop and batch units in the ledger

**Parent:** this document.

**What to build:** Triage, recut, advisor, release and hand units, and every batch, appear in the ledger and the report with their model calls and cost, split equally across the tickets of a batch instead of repeated for each.

**Files:** EDIT `engine/mac-autopilot/roi_collect.py`, `roi_ledger.py`, tests. Reads (no edit): `spend/*.log`, `metrics/efficiency-*.jsonl` (`execution-release`, `attempt-terminal`), `state/<n>.json`. RULE-LANE: none. HOLD: none (the release unit is covered by its guardian; `run-release.sh` is not edited).

**Acceptance criteria**
- [ ] A `batch:` spend row with five tickets becomes one unit row with five `tickets` and splits to five equal allocations that sum to the row.
- [ ] `cost_usd` of `unobservable` stays `null`; a numeric `cost_usd` is kept as `reported_cost_usd` and shown beside the computed one.
- [ ] A spend-log row and a worker log for the same stage are never both counted (each family has its own rows).
- [ ] Live: the next triage batch and the next release batch each produce one `unit-end` row, with the member tickets listed, within one collector interval.

**Blocked by:** RT-1.

### RT-4: CI runs in the ledger

**Parent:** this document.

**What to build:** Every completed workflow run is a ledger row with its jobs' minutes by runner class, the ticket it belongs to, and the waste reason `ci_spend.py` already computes, so CI cost per ticket and per day exists and the 24-hour cache is no longer the only record.

**Files:** EDIT `engine/mac-autopilot/ci_spend.py` and `ci_spend.test.sh` (keep runner labels per job; emit `ci-run-end` rows through the ledger module), EDIT `engine/mac-autopilot/roi_ledger.py`, `engine/state/roi-prices.json` (CI classes). RULE-LANE: none. HOLD: none (`ci_spend.py` is started by the scheduler already).

**Acceptance criteria**
- [ ] A fixture of runs and jobs yields one row per completed run; re-running over overlapping windows adds no duplicates (`event_id` = run id and attempt).
- [ ] Minutes per class sum to `ci-spend.json`'s `total_min` for the same runs; waste reasons match `classify`.
- [ ] A class with no price shows minutes and `null` dollars; a class priced `0.0` appears in the footnote with its stated basis.
- [ ] PR runs attribute to the ticket via the `agent/issue-<n>` branch; a postsubmit run attributes to its landing batch or to overhead.
- [ ] Live: after landing, the ledger has a `ci-run-end` row for every workflow run that completed since, and `report --days 1` shows CI minutes by class and CI cost per ticket.

**Blocked by:** RT-1.

### RT-5: CPU and memory per unit

**Parent:** this document.

**What to build:** Every execution unit and every scratch worker records its CPU-seconds and peak memory at the moment it ends, and the report shows host compute cost per ticket. On a host without cgroups the same fields come from `getrusage` and say so.

**Files:** EDIT `engine/execution-admission.py` and its tests (guardian reads cgroup or `getrusage` after `child.wait()` and writes the stash; best effort), EDIT `engine/bin/luna` and `engine/bin/zc` (30-second scope poll; replace the file atomically, as the script's own comment requires), `engine/mac-autopilot/roi_collect.py`, `engine/state/roi-prices.json` (`host.core_hour_usd`). The `unit_meter()` function lives in the collector module until PORTABILITY.md's helper layer exists. RULE-LANE: none. HOLD: none.

**Acceptance criteria**
- [ ] With the cgroup root pointed at a fixture (`ZF_EXECUTION_PROC_ROOT` style seam), the stash carries `cpu.seconds` and `mem.peak_bytes` with `source: "cgroup"`; with no cgroup it carries the `getrusage` values with `source: "rusage"` and `maxrss` normalised to bytes.
- [ ] An unwritable stash directory, an unreadable cgroup file, and a missing `memory.peak` each leave the unit's exit status and output unchanged (tested).
- [ ] A unit with no stash gets `cpu.source: "missing"`, not 0.
- [ ] Live: the next implement-class unit and the next scratch worker produce rows with non-null `cpu.seconds` and `mem.peak_bytes`; `report --days 1` shows core-hours per ticket.

**Blocked by:** RT-1.

### RT-6: GitHub API calls per unit and the shared quota

**Parent:** this document.

**What to build:** Each unit row shows how many REST (core), GraphQL and search calls it made, and the report shows how much of the shared hourly quota is used, so a unit or a polling loop that burns the quota is visible by name.

**Files:** EDIT `engine/mac-autopilot/roi_collect.py` and tests. Reads `measure/gh-calls.tsv` (existing shim) by unit name and time window; samples `gh api rate_limit` once per run into a `gh-quota` row. No edit to the shim: the resource class is derived from the endpoint column (`graphql`, `search/...`, otherwise core). RULE-LANE: none. HOLD: none.

**Acceptance criteria**
- [ ] A fixture TSV gives per-unit counts by class; rows of units outside any unit window are counted as `unattributed` in the quota view, not dropped.
- [ ] If the shim is not on for a unit the `gh` field is `source: "n/a"`, not zeros.
- [ ] With two hosts sharing a token the report shows `unattributed = used - sum(own calls)`.
- [ ] A failed `rate_limit` call writes no row and is logged; it never writes a 0.
- [ ] Live: after landing, `gh-quota` rows appear every collector run and `report --days 1` shows REST calls per unit and the latest `used` of `limit`.

**Blocked by:** RT-1.

### RT-7: Network bytes per unit, with `n/a` where unsupported

**Parent:** this document.

**What to build:** Each unit that can be measured shows bytes in and out and which mechanism produced them; units that cannot be measured say `n/a` and are listed as such. Hosts whose units run under the system manager use exact IP accounting.

**Files:** EDIT `engine/execution-admission.py` (read `IPIngressBytes`/`IPEgressBytes` through `systemctl show` when numeric; add `-p IPAccounting=yes` at the dispatch sites only for system-manager hosts), EDIT `engine/mac-autopilot/roi_collect.py` (per-cgroup delta from the sampler file), origin-only `network-traffic.py` (not in this export: emit a cumulative per-cgroup counter file alongside the existing rows), tests with a recorded `systemctl show` showing `[no data]`. RULE-LANE: none (`state/traffic-budget.json` is not touched). HOLD: none.

**Acceptance criteria**
- [ ] A `[no data]` or `[not set]` IP read yields `net.source` from the next tier, never 0.
- [ ] A unit shorter than the sampler interval gets `n/a` (not 0); a unit that lived several intervals gets the delta of its cgroup's counters.
- [ ] Bytes of the proxy bridge's cgroup are reported under the bridge, not under the units that talked to it, and the report states that app-to-proxy legs can double count.
- [ ] Live, on a user-manager host: the next implement-class unit alive for at least 10 s has `net.source: "socket-sampler"` with non-null rx/tx; `report --days 1` shows GB per ticket and the `n/a` count.

**Blocked by:** RT-5.

### RT-8: Node-health rows, standards and mechanism heartbeat

**Parent:** this document. **RULE-LANE.**

**What to build:** The twelve economics numbers of section 3.8 appear in the node-health scorecard each tick with a healthy/warn/unhealthy/no-data status and an explanation, are documented in `NODE-HEALTH.md` in the same landing, and an unhealthy one is handled by the existing health-issue and inbox rules. The collector is registered as a mechanism so a collector that stops running is reported as silent.

**Files:** EDIT `engine/mac-autopilot/node_health.py` (`CRITERIA`, `MEANING`, `SOURCE`, `main`: call the rollup; history-derived bounds with the frozen fallbacks above), EDIT `engine/mac-autopilot/NODE-HEALTH.md`, EDIT `engine/mac-autopilot/node_health.test.sh`, EDIT `engine/state/mechanism-registry.json` (silence bound 2 hours for the collector). RULE-LANE: `node_health.py`, `NODE-HEALTH.md`, `mechanism-registry.json` all in `engine/state/rule-files.json`: land as the supervisor with a `Rule-Replay:` report; the rule replays nothing that stops a unit, so `falseStops` is expected to be 0. HOLD: none (`node_health.py` is started by the scheduler already).

**Acceptance criteria**
- [ ] `node_health.test.sh` passes: each new id has a meaning and a source, and the table in `NODE-HEALTH.md` lists the same ids with the same bounds.
- [ ] A metric that cannot be computed (no fee configured, no rows in the window) reports `NO-DATA` with the reason, never a number; one with fewer than 7 samples uses its frozen fallback and says `provisional`.
- [ ] `roi.unknown_cost_pct_7d` counts `missing` and unpriced, and not `n/a`.
- [ ] Live: on the first tick after landing `node-health.txt` lists all twelve rows with a status; `mechanism.silent` is 0 with the collector registered; stopping the collector timer for longer than its bound makes `mechanism.silent` report it.

**Blocked by:** RT-2.

### RT-9: Dashboard "Economics" panel

**Parent:** this document.

**What to build:** The dashboard shows ROI, cost per delivered ticket, waste share and lead time against the human baseline with status markers, cost by component for 14 days, the costliest and lowest-ROI tickets, per-model tokens and cost, traffic and GitHub quota, and the `n/a`/`missing` counts.

**Files:** EDIT `engine/mac-autopilot/gen_dashboard.py` (read `roi-report.json`; a section that fails shows "data unavailable" for itself only, as the other sections do), EDIT `engine/mac-autopilot/dashboard.html`, EDIT `dashboard-modules.test.sh` and `dashboard-front.test.sh`. RULE-LANE: none. HOLD: none (`gen_dashboard.py` is started by the scheduler already).

**Acceptance criteria**
- [ ] Rendering a fixed report fixture shows every tile and table; a missing or malformed report shows "data unavailable" and nothing else on the page changes.
- [ ] A partial ROI is visibly marked partial; an assumed rate is visibly marked assumed.
- [ ] Status markers come from the node-health rows when present and say "no standard" when not.
- [ ] Live: at the next dashboard refresh after landing, the panel shows today's numbers and its ROI tile equals `report --days 7` run by hand.

**Blocked by:** RT-2 (markers appear fully after RT-8).

### RT-10: Daily report "Cost and return" section

**Parent:** this document.

**What to build:** The daily report gains a short section: yesterday against the day before and the 7-day mean for tickets delivered, cost by component, cost per ticket, ROI, waste share and tokens per delivered ticket, plus the three costliest tickets and the unknown count.

**Files:** EDIT `engine/night/daily-perf-report.sh` (a block function called from `daily_perf_report_build`), EDIT `engine/night/maintainer-health-mail.sh` (output-contract allowance and rendering helper), EDIT `engine/night/daily-perf-report.test.sh`, `maintainer-health-mail-output-contract.test.sh`. RULE-LANE: none. HOLD: none.

**Acceptance criteria**
- [ ] The report built from a fixture ledger contains the section and passes the output contract; a rollup failure drops only that section and says so.
- [ ] The existing `tokens_per_released_issue` line is kept until this section's value has been compared with it once; the new line states which sources it covers.
- [ ] Live: the next day's report contains the section with the previous day's per-ticket numbers for the three costliest tickets, with real values.

**Blocked by:** RT-2.

### RT-11: `zenoforge roi` in the npm CLI

**Parent:** this document. Lives in the npm CLI repository (branch `feat/npm-cli`), not in `engine/`.

**What to build:** `zenoforge roi` prints the report of section 6 for the configured agent home, with `--days`, `--by`, `--ticket`, `--json`, `--merge` and `--prices`, read-only, and fails clearly when there are no rows.

**Files:** EDIT `cli/commands.mjs` (new `roi`), `cli/render.mjs` (text renderer), `cli/zenoforge.mjs` (help text and options), `cli/cli.test.mjs`, `cli/render.test.mjs`, `docs/install.md`. The packaged `engine/` must contain RT-2's rollup. RULE-LANE: not applicable. HOLD: not applicable.

**Acceptance criteria**
- [ ] With a fixture agent home the command prints the report and `--json` equals the rollup's document; exit code 3 and a message when the window has no rows; exit code 2 on bad arguments.
- [ ] The command never writes: running it with the home mounted read-only succeeds.
- [ ] Live: on a running host, `zenoforge roi --days 7` prints the same ROI, cost and delivered counts as the dashboard panel.

**Blocked by:** RT-2.

### RT-12: Merge per-host ledgers

**Parent:** this document.

**What to build:** Given copies of several hosts' ledgers, the rollup produces one report with a per-host breakdown and a ticket whose work ran on two hosts shows its full cost; without copies the report says it is host-local and claims no fleet ROI.

**Files:** EDIT `engine/mac-autopilot/roi_rollup.py` and `roi_ledger.py` (multiple directories, `.gz`, `scope` label, `cost_partial`), tests. RULE-LANE: none. HOLD: none.

**Acceptance criteria**
- [ ] Two fixture hosts with one overlapping `event_id` count it once; a ticket with rows on both hosts has the summed cost.
- [ ] Without `--merge`, `scope` is `host-local`; a delivered ticket with a cost row missing on another host's side is flagged `cost_partial`, not silently low.
- [ ] A merge reads only the given copies and takes no lock (tested by making the directories read-only).
- [ ] Live: on a deployment with a second host, `report --merge <copy>` totals equal the sum of the two hosts' own reports minus the shared outcome events.

**Blocked by:** RT-2.

### RT-13: Unit-loop worker meter (optional)

**Parent:** this document.

**What to build:** Workers started by the scheduler, which have no cgroup of their own, get CPU, memory and network figures from a small meter that samples their process trees, so unit-loop rows stop being `n/a` for those fields. Build this only if the traffic and compute numbers of the other families show it matters.

**Files:** NEW `engine/mac-autopilot/roi_meter.py`, NEW `engine/systemd/zenoforge-roi-meter.service`, EDIT `engine/systemd/pipeline-timers.list`, EDIT `engine/mac-autopilot/roi_collect.py`, tests. Reads `workers.json` pids, `/proc/<pid>/stat` (`utime`, `stime`, `cutime`, `cstime`), the sampler's per-pid records by ancestry. RULE-LANE: none. HOLD: none. Note: the cleaner alternative, running each worker in its own `systemd-run --user --scope` from `scheduler.sh:dispatch`, edits a HOLD file and is therefore not part of this ticket; it can replace the meter once the hold is lifted.

**Acceptance criteria**
- [ ] For a fixture process tree the meter's last sample before exit is within one sampling interval of the true CPU; reaped children's time is included through `cutime`/`cstime`.
- [ ] Worker pids that are reused or exited between samples never attach another worker's counters (identity is pid plus start ticks).
- [ ] Live: the next implement and review workers of the unit loop have non-null cpu and mem with `source: "meter"` and `coverage: "sampled"`.

**Blocked by:** RT-5, RT-7.

## 10. Out of scope

- Interactive operator and supervisor sessions (Claude Code and similar). They were the largest share of spend in the one-off retrospective (Claude transcripts were $2,165 of the $2,210 API-equivalent total over three days) and are the largest known omission of this ledger. A later ticket can add a `supervisor-session` unit family using the retrospective's transcript reader; until then `C` is the pipeline's cost and the report says so.
- Using the ledger to drive admission or budget gates (`codex_budget_*`, the traffic admission gate). The ledger would be a better input than the spend log, but changing a gate is a control change with its own review.
- Reducing cost. This measures; it does not tune prompts, models or concurrency.
- Product runtime cost of the software the pipeline builds; human review time beyond the existing `delivery.human_actions_per_merge_30d`.
- Forecasting, per-customer billing, carbon.
- Moving stage units to the system manager to obtain IP accounting.
- Native Windows.

## 11. Further notes

Questions the `to-tickets` process would put to the maintainer before publishing; none was asked because this document was produced without an interview:

1. Is the breakdown right-sized? RT-2 could be split into value and waste. RT-8 to RT-12 are independent surfaces and could be merged.
2. The effort table (S 3 h, then 6, 12, 24) and the hourly rate are placeholders. Only the maintainer can state them; ROI is only as meaningful as they are.
3. Default cost basis: API-equivalent list price (computable now) or the real subscription fee (needs the plan facts the retrospective did not have)?
4. Should the price table be rule-lane? The design says no (it is a reporting input).
5. Should interactive operator sessions count in `C`? They dominate cost in the one period measured.

Pushbacks, in the order they would save the most work:

- **Traffic is a capacity number at the origin before it is a price.** The origin already budgets GB per hour and per day. The money path (RT-1 to RT-4) and the standards (RT-8) deliver the ROI; RT-7 and RT-13 refine a figure whose price defaults to zero. They are last for that reason.
- **Do not move units to the system manager for IP accounting.** The exact mechanism is real but the move is large and the number is a capacity metric.
- **The time-value term is off.** Lead time against a human baseline is a bounded metric of its own; adding an invented cost-of-delay to ROI would trade honesty for a bigger number.
- **One ledger family, not two.** Cost rows in the efficiency ledger would make every reader of that file slower for data it does not use; the outcome events it holds are read from it as they are.

Risks and unknowns:

- The seeds for the frozen fallbacks come from one retrospective (2026-10-22..24), seven days of traffic and call counts, and one CI sample. They are labelled first-cut and replaced by history after seven samples.
- The size classes of direct-main landings with no PR are assumed; the report counts them.
- Reasoning tokens might or might not be a subset of output tokens for a given provider. The design stores them and does not price them separately; check per provider when its price row is added.
- The socket sampler counts only TCP and only what it sees; per-unit network numbers from it are lower bounds with a stated coverage.
- Trimmed `workers.json` rows lose the model of old logs; the collector runs every five minutes so it normally sees a row before it is trimmed, and falls back to the stage's configured model (flagged `model_source: "configured"`) when it does not.

## Appendix A. Probe commands

All harmless; each unit is transient. Proxy variables are imported with `-E` only when the host needs them. Nothing here prints a credential.

```sh
# E1: the requested probe
systemd-run --user --unit zf-roi-probe-$$ -p IPAccounting=yes --wait --collect \
  curl -sS -o /dev/null https://api.github.com/zen
systemctl --user show zf-roi-probe-$$ -p IPIngressBytes -p IPEgressBytes   # [no data]

# E2: while the unit is alive
systemd-run --user --unit zf-roi-live -p IPAccounting=yes --quiet \
  bash -c 'curl -sS -o /dev/null https://api.github.com/zen; sleep 6'
systemctl --user show zf-roi-live -p IPAccounting -p IPIngressBytes -p IPEgressBytes -p CPUUsageNSec -p MemoryCurrent

# E3
zcat /usr/share/man/man5/systemd.resource-control.5.gz | grep -A12 '^IPAccounting='

# E4: counters readable from ExecStopPost
systemd-run --user --wait --collect --quiet -p "ExecStopPost=/path/to/probe.sh /path/to/out" some-command
#   probe.sh: systemctl --user show "$(sed -n 's#^0::.*/##p' /proc/self/cgroup)" -p ActiveState -p SubState -p CPUUsageNSec -p MemoryPeak -p IPIngressBytes

# E5: inside a unit
d=/sys/fs/cgroup$(sed -n 's#^0::##p' /proc/self/cgroup); cat $d/cpu.stat $d/memory.peak $d/pids.peak

# E6: scope polled from outside
systemd-run --user --scope --quiet --unit=zf-roi-scope -p MemoryMax=1G some-command &
systemctl --user show zf-roi-scope.scope -p CPUUsageNSec -p MemoryPeak -p MemoryCurrent

# E7: git has no byte counter
GIT_TRACE2_EVENT=/path/to/t2.json git clone --depth 1 <small public repo>
# E8
ss -tinpe state established     # look for bytes_received, bytes_acked, cgroup:
# E9
gh api rate_limit --jq '.resources.core'
gh api -i rate_limit | grep -i '^x-ratelimit'
# environment facts
systemctl --version | head -1; uname -r; cat /sys/fs/cgroup/cgroup.controllers
cat /proc/sys/kernel/unprivileged_bpf_disabled; grep Cap /proc/$(pgrep -u "$(id -u)" -x systemd | head -1)/status
```

## Appendix B. How the seeds were computed

| Seed | Recipe |
|---|---|
| landings per day | count of `event_type == "source-landed"` per `ts[0:10]` in `metrics/efficiency-YYYY-MM.jsonl` (65, 54, 40, 11, 20, 46, 136 for 10-23..29) |
| host wire GB per day | `daily.wire_bytes` of the last row of `metrics/traffic-<day>.jsonl` (38.3, 30.4, 15.0, 9.4, 43.4, 59.5, 60.8) |
| GitHub calls per day | rows per day in `measure/gh-calls.tsv` (8,851, 6,795, 16,218, 19,184, 19,019, 31,740, 52,993) |
| bound from a series | `usage_reader.daily_bound` / `worker_cost.ticket_bound`: healthy = value at the 50th percentile index x 1.5, unhealthy = value at index `int(0.9 x n)` x 2, on the sorted series |
| cache hit | cache reads / (non-cached input + cache reads + cache writes) per model from the retrospective: 97.3% (Codex model), 97.8%, 98.2%, 95.6% (three Anthropic models) |
| pipeline-worker cost per landing | retrospective Codex rollout cross-check, $143.04 over 2026-10-22..24, divided by 164 landings (45 + 65 + 54) |
| CI minutes per landing | `ci-spend.json` of 2026-10-30T02:10Z (1,876 runner-minutes, 5 h window) scaled to a day, over 40 and 136 landings |
