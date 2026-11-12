# Agent-scale design principles

Status: reference, checked on 2026-11-12. Read it on demand when you design or review anything that runs many times a day: per worker, per tick, or per PR. Each principle is kept in three parts: what the article did, the principle, and what it means here.

Source: Anthropic, "Redesigning source control at Anthropic" (https://www.anthropic.com/research/redesigning-source-control), published 2026-10-13 and updated 2026-10-15.

## Summary

- Agent-written merges grew from about 2,500 a day in May 2026 to more than 30,000 a day in September. The bottleneck moved from writing code to the infrastructure built for human scale: version control, builds and CI.
- The monorepo's main history is close to 100 GB, the compressed working copy is over 25 GB, and there are about 25 million checkouts a day. Pulling it the way git does by default would move more than 600 PB a day.
- Standard git measures (shallow clone, sparse checkout, partial clone, hundreds of internal mirrors, periodic snapshots) bought time but got harder to run as merge volume rose.
- Seven engineers spent five months building Scion, a version system that replaced git there. Every cache tier hits more than 99%. Infrastructure CPU and memory are 1/200 of the old git mirror setup. Checkouts dropped from minutes to seconds, and CI saved 25% of CPU per job.
- We are orders of magnitude smaller, so we do not need Scion. We need its principles.

## Principles

### Caching

#### 2. Data that never changes can be cached safely

- **What the article did:** Every object is content-addressed: its name is a fingerprint of its content, and it is never changed after it is stored. Any server can cache it without asking whether it is still current.
- **Principle:** Cache invalidation is the hard part. Make data immutable and name it by its content, and the invalidation problem goes away. Keep mutable data in a separate place, and keep it small.
- **Here:** Plugin manifests, repository objects, dependency packages and API history should be stored once per version or fingerprint. The name stays the same and so does the content. Downloading the same name a second time is a defect.

#### 3. Give everyone the same answer to the same question

- **What the article did:** Git negotiates with the server: the client says what it already has, and the server builds a pack just for that client. That pack cannot be cached and costs server CPU. Scion reverses this. The client checks locally what is missing and requests each object by name. Every request has the same answer for every client, so any cache layer can serve it. Small, independent requests can resume after an interruption.
- **Principle:** A cache works only when the answer does not depend on who asks. Replace one large, customised response with many small, general, retryable responses.
- **Here:** Design APIs around "fetch one immutable object by ID" rather than "give me everything since last time", which can only be computed on demand and is large.

#### 5. Share one copy among the tasks on one machine

- **What the article did:** Each node runs one daemon, scion-daemon, which caches objects for the whole node. Tasks on the same node mostly need the same objects, so each object is fetched once. The daemon starts from a periodically refreshed snapshot, not from zero.
- **Principle:** Put the cache at the layer with the most sharers. Parallel units share read-only data, and a new unit starts from a warm snapshot.
- **Here:** On 2026-11-12 we measured that every codex process start downloaded the same 54.3 MB plugin manifest again. Over 12 days that was about 300 GB, 53% of all downloads. That is the cost of each process fetching its own copy.

#### 6. Layers speak the same protocol but may only ask the layer above; design the failure as well as the cache

- **What the article did:** Three tiers (the node daemon, a regional cache and the authoritative server) serve the same interface, so clients do not need to know the topology. Any tier could in theory ask any other. They enforce that each tier asks only the tier above it, to isolate failures: if a regional cache fails, traffic must not hit the authoritative server directly and take down the whole system.
- **Principle:** A uniform interface buys flexibility. Give up some of that flexibility on purpose to get fault isolation. When you design a cache, also design what the upstream receives at the moment the cache fails.
- **Here:** For every cache or retry, answer this question: when it fails, will hundreds of workers hit the same upstream at once? GitHub API rate limiting is exactly this failure.

#### 11. Keep the cache in the form the reader needs

- **What the article did:** The regional cache streams objects straight from memory in the format the daemon writes to disk. It does not compute what each request is missing, and it does no incremental compression on the request path.
- **Principle:** Move computation to write time, done once. Reads only transfer data. Do no conversion on the hot path.
- **Here:** Results that are read repeatedly, such as a PR's check status, should be stored in the form the caller can use directly. Do not rebuild them on every read.

### Lazy loading

#### 4. The cheapest download is none: ask for the answer, not the data

- **What the article did:** A working copy is optional. A CI job that needs a diff asks the server for the result and never clones the repository. When files must be on disk, a sparse checkout (only the paths you name) or a virtual checkout (a file is fetched when first read) is used. The client pays only for what it actually reads.
- **Principle:** Load lazily. Fetch nothing by default, fetch when used, and when you can ask a question instead of moving data, ask it.
- **Here:** A task that only needs the status of one PR or the content of one file should not clone the whole repository first. The 1,133 clones in the local clone pool are the opposite of this principle.

### Throughput and concurrency

#### 7. Cost follows the size of the change, not the size of the system

- **What the article did:** Creating a commit and updating its downstream data structures must cost in proportion to the change, not in proportion to the total repository size. Otherwise the servers cannot keep up.
- **Principle:** The cost of any frequent operation must not grow with total system size. Process increments. Do not recompute everything.
- **Here:** If every tick, merge or check scans all issues, all PRs or all clones, it slows down as the system grows. Change it to process only what changed.

#### 8. Do not use global state that everyone must agree on, and do not add global locks

- **What the article did:** Scion avoids refs (branches and tags), because a ref is global state that every server must agree on, and that becomes a scaling bottleneck sooner or later. Moving a ref is one compare-and-swap on a single row, separate from creating a commit. Committing, rebasing and merging take no lock.
- **Principle:** Shared mutable state is the enemy of concurrency. Keep it as small as possible, and use a single atomic update instead of a wide lock.
- **Here:** Machine-wide locks, global queues and "one red main blocks every PR" structures are what this principle checks.

#### 16. A process built for human scale must be redesigned for agent scale

- **What the article did:** A traditional merge queue relies on a global repository lock, which does not work at agent scale: hundreds of changes would merge while the tests were still running. They moved the checks to automated tests after merge and before deploy, accepted that concurrent changes can conflict, and have Claude fix conflicts quickly. The article also notes that demand for merged code is close to unlimited: every bottleneck removed raises output again.
- **Principle:** Move the check from serial gating before merge to parallel verification after merge, plus fast repair. Bottlenecks keep moving, so optimisation is ongoing work.
- **Here:** This matches the existing rules `zenoforge_batch_live_ci_later_2026_11_12` and "fix forward".

### Resource use

#### 9. Keep no long-lived state, so you need no maintenance and can scale at any time

- **What the article did:** No layer keeps a full copy of the repository, not even the servers. There are no packfiles, so no repository maintenance is needed. Each layer holds no long-term state, and adding capacity means adding machines.
- **Principle:** The less state a component holds, the easier it is to scale, replace and run without a person watching it. Anything that needs periodic cleaning is a burden.
- **Here:** Directories that grow without limit and need someone to clean them (the clone pool, temp files, logs) should either be disposable and rebuildable at any time, or have automatic reclamation.

#### 10. Separate facts from derived data; derived data can be computed now or later

- **What the article did:** The only fact is the changeset: an append-only log entry that records only which files changed. Blame, path history, commit-graph indexes and similar data are derived. A common mechanism computes them recursively from the facts. Each kind of derived data may be computed immediately or deferred. Clients never see the internal structure, so it can be optimised at any time without changing clients. They have added derived types several times to speed up specific operations.
- **Principle:** The write path records the minimum set of facts, so it stays fast. Read views are derived separately, and you decide when to compute each one. Keep internal structure hidden, so you stay free to optimise it.
- **Here:** Dashboard metrics, daily reports and queue state are derived data. They should be recomputable from the fact records (the event log), not stored in separate places where they disagree.

### Method

#### 1. Look at the real workload before you choose a design

- **What the article did:** Git assumes clients work offline, so every clone is a full repository. That is right for most repositories. But almost all of Anthropic's clients are agents and tasks, which are always online, so git's cost for offline work gives them no return.
- **Principle:** A design is good only if its assumptions match how it is actually used. Measure who uses it, how often, and what each use needs, and only then choose the structure.
- **Here:** The factory starts about 700 codex processes a day and makes 50,000 to 90,000 GitHub API calls. Any default that was designed for "one person uses it once in a while" must have its cost checked again at that rate.

#### 12. Use the proven standard methods first; when you must rebuild, start with the smallest useful slice

- **What the article did:** They pushed git's standard methods to their limit before building their own system. Even then, the first Scion handled only metadata queries (commit relationships, blame). The file content and working-copy design came later as a separate design. They adopted lessons from earlier systems (Google Piper, Meta Sapling/Mononoke).
- **Principle:** Prefer mature solutions. When you hit a problem, first identify which classic problem it is a variant of. Cut a large rebuild into slices by value, and ship the smallest one first.
- **Here:** At our scale the right tools are git local reference clones, HTTP conditional requests and incremental sync. A custom system is not needed.

#### 13. People keep the system's constraints, and must be able to say no to an agent

- **What the article did:** Engineers' value lies in understanding how systems relate and in making design trade-offs. They often have to tell Claude no. Two typical problems: first, an agent forces its way past a system constraint to finish a task (for example, reading commit logs one by one to find a merge time, instead of asking the existing review tool). Second, adversarial review tends to be short-sighted: it guards against imagined risks and makes the system more complex (for example, distrusting an internal service so much that it adds heavy validation). The team still reviews every change, but reviews intent, not every line of code.
- **Principle:** Write constraints down and have someone enforce them. Reject brute-force implementations and excessive defence. Review asks: what does this change try to do, and should it be done this way?
- **Here:** When a supervisor reviews, ask two questions first: does an existing service already answer what this code is brute-forcing? Does this validation guard against a problem that actually happened, or an imagined one?

#### 14. Turn cheap code output into quality

- **What the article did:** Because writing code is cheap, Scion became one of their most thoroughly tested codebases. They built a closed simulation for every infrastructure interaction they had encountered, plus fuzz testing and rate limiting.
- **Principle:** When production capacity is in surplus, spend it on repeatable verification rather than on more features.
- **Here:** Every root-cause fix leaves one deterministic check behind. This is already the factory-efficiency ruling of 2026-11-07.

#### 15. Give each component a watcher who looks only at it

- **What the article did:** They assign each component a Claude instance focused on its health, called superfan. It reads telemetry and logs, the way a senior engineer with nothing else to do would refresh charts looking for anomalies. Traditional alerts stay, but superfan finds subtle new problems that no alert rule covers.
- **Principle:** Threshold alerts find only the problems someone thought of in advance. A watcher that keeps reading the data can find the ones nobody anticipated.
- **Here:** The traffic problem in this audit was found by the founder, though a sampler had already been recording the daily numbers. Each resource (traffic, tokens, disk, API quota) should have a fixed watcher who reviews its trend on a schedule.

## Checklist: design and review questions

Ask these in order when you build a feature, change a pipeline or review a PR:

1. How many times a day does this operation run? Multiply by the count: what are the traffic, time and token costs?
2. Is the data it fetches immutable? If so, is there already a local copy that can be used directly?
3. Do other processes on the same machine fetch the same thing? Can they share one copy?
4. Does it move data back and then compute, or can it ask for the answer directly? Can it fetch only when used?
5. Does its cost grow with the size of this change, or with the total size of the system?
6. Does it add global state or a lock that everyone must wait for or agree on?
7. When its cache or retry fails, is the upstream hit by everyone at once?
8. Does it leave things behind that someone must clean up?
9. Is there a mature standard method for this? Which classic problem is it a variant of?
10. Does it brute-force past an existing service, or add complexity for an imagined risk?
11. After release, who watches which number to notice that it got worse?

## Cases

Each row is a measured incident or optimisation. Numbers are the measured values from the 2026-11-12 traffic audit.

| Date | What was measured | Principles broken | Fix or status |
|---|---|---|---|
| 2026-11-12 | Every codex process start downloaded the same 54.3 MB plugin manifest: about 300 GB in 12 days, 53% of all downloads | 2, 5 | Fixed by zenoforge#1026 (merged into main) |
| 2026-11-12 | Each full network clone of the origin product repository: 235 MiB | 2, 4 | `zf-clone` now borrows local objects: 44 MiB per clone. No PR recorded |
| 2026-11-12 | GitHub API polling: 622,826 calls in 12 days, 15 GB, quota exhausted | 3, 4, 6 | Not started |
| 2026-11-12 | The same data pulled repeatedly from the origin VPS: about 4.3 GB per day | 2, 7 | Not started |
| 2026-11-12 | The clone pool only grows: 1,133 entries, about 95 GB | 4, 9 | Not started. The process that creates them is not yet identified |

No deterministic check exists yet for the traffic cases. Once #1026 is live, plan to tighten the daily traffic budget for codex-class work so that a regression triggers an alert.

## How to add a case

- At the close of an incident or an optimisation, add one row to the table above: date, measured value, principles broken, and the fix (issue or PR number).
- Add a new principle only when no existing principle covers the case.
- Do not copy principle text into worker prompts or into `AGENTS.md`. `AGENTS.md` holds only the pointer to this file.
- Keep this file public-safe: no home-directory paths, hostnames, private repository names or customer names. Write "the origin deployment" instead.
