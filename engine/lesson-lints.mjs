#!/usr/bin/env node

// M6 lesson lints (#4503): every lesson with recurrence >= 2 in
// lessons/recurrence-ranking.json that has a structural prevention anchor
// gets a landing-time lint, in the same shape as the V930 tracer bullet
// (#4502, engine/supervisor-hold-lesson-lint.mjs): gated on the
// diff, checked against the head sources, refusing the landing with the
// repair guidance as the error text. V894 (node-owner-detail-churn-per-pr)
// is the one recurrence >= 2 lesson without a locatable structural anchor
// today and stays test-enforced instead.

import { realpathSync, existsSync, appendFileSync, mkdirSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const defaultRepo = path.resolve(scriptDir, '..');
const lintPath = 'engine/lesson-lints.mjs';
const rankingPath = 'lessons/recurrence-ranking.json';
export function formatLintRefusal(alternative, found, documentedIn = lintPath) {
  if (typeof alternative !== 'string' || !alternative.trim()) throw new Error('lesson lint refusal requires a blessed alternative');
  if (typeof documentedIn !== 'string' || !documentedIn.trim()) throw new Error('lesson lint refusal requires its guidance document');
  const finding = Array.isArray(found) ? found.join('; ') : String(found);
  return `REFUSAL found=${JSON.stringify(finding)} alternative=${JSON.stringify(alternative)} documented_in=${documentedIn}`;
}
const lib = 'engine/lib.sh';
const libIssueState = 'engine/lib.d/issue-state.sh';
const libCiChecks = 'engine/lib.d/ci-checks.sh';
const libTransport = 'engine/lib.d/transport.sh';
const libImplementGates = 'engine/lib.d/implement-gates.sh';
const libHolds = 'engine/lib.d/holds.sh';
const lander = 'engine/land-direct-main.sh';
const landQueue = 'engine/land-queue.sh';
const worktreeLifecycle = 'engine/worktree-lifecycle.sh';

export const lessonLints = [
  {
    lesson: 'V936',
    classTag: 'state-single-writer',
    files: {
      [libIssueState]: {
        require: [
          /issue_transition_allowed\(\)/,
          /ISSUE_TRANSITION_TABLE\[/,
          /__issue_transition_lock_held/,
        ],
      },
    },
    alternative: 'Route every pipeline state transition through issue_transition with the ISSUE_TRANSITION_TABLE legality check; state writes that run inside it must keep the __issue_transition_lock_held lock mode. Keep HEALTH label/state drift detection read-only.',
  },
  {
    lesson: 'V882',
    classTag: 'land-queue-serializes-nonproduct-landings',
    files: {
      [lander]: {
        require: [/mem_mb >= 3072/, /required_mb=3072/],
      },
      [landQueue]: {
        require: [/land-direct-main\.sh" "\$@"/],
      },
    },
    alternative: 'Keep queue-driven preflight admission memory-only (MemAvailable >= 3072 MiB, no load average gate) and start one independent land-direct-main.sh worker per enqueue request; the shared main lock covers only the final rebase and push.',
  },
  {
    lesson: 'V915',
    classTag: 'ci-runner-label-pool',
    files: {
      'scripts/ops/provision-cihost-ci-runner.sh': {
        require: [
          /runner_labels="cihost-ci,cihost-ci-testcontainers,cihost-ci-light,vecta-suites"/,
          /install -d -o "\$runner_user" -g "\$runner_user" -m 0700 "\$runner_home\/\.config"/,
        ],
      },
    },
    alternative: 'Keep the corrected PR-runner label pool (cihost-ci,cihost-ci-testcontainers,cihost-ci-light,vecta-suites) in scripts/ops/provision-cihost-ci-runner.sh and keep ~/.config owned by the runner user at creation time; a root-owned ~/.config breaks rootless setup.',
  },
  {
    lesson: 'V975',
    classTag: 'large-json-never-on-argv',
    files: {
      [libIssueState]: {
        require: [/jq_arg_file\(\)/],
      },
      'engine/jq-arg-safety.test.sh': {
        require: [/scan_files\(\)/, /--slurpfile|--rawfile|jq_arg_file/],
      },
    },
    alternative: 'Pass unbounded JSON (issue state, issue/PR lists, brief_md and other model prose) to jq on stdin or through jq_arg_file()/--slurpfile, never as --argjson/--arg: one argv element over 128 KiB makes execve fail with "Argument list too long". Extend jq-arg-safety.test.sh when a new unbounded variable name appears.',
  },
  {
    lesson: 'V797',
    classTag: 'postsubmit-in-progress-masks-red',
    files: {
      [libCiChecks]: {
        require: [/ci_main_completed_push_runs\(\)/, /status=completed&per_page=\d+&page=1/],
      },
    },
    alternative: 'Keep main Postsubmit verdict reads querying completed runs only (ci_main_completed_push_runs with status=completed); an "in progress" run is not a verdict and must never reset a red main to OK.',
  },
  {
    lesson: 'V803',
    classTag: 'commit-preflight-lone-negative',
    // Landing-test fixtures stub this file, so unlike the other lints the
    // runner path is not a gate here; V803 gets its own dedicated fixture.
    gate: [rankingPath],
    files: {
      'scripts/branch-delivery-preflight.mjs': {
        require: [/option\('--mode'\) \?\? 'commit'/, /\['commit', 'push', 'release'\]/],
      },
    },
    alternative: 'branch-delivery-preflight.mjs must keep commit as its default mode and run every locally reproducible gate in that mode; a gate that only runs in a mode nobody uses lets the same avoidable red reach CI on every PR.',
  },
  {
    lesson: 'V955',
    classTag: 'worktree-stats-per-worktree-scans',
    files: {
      [worktreeLifecycle]: {
        require: [
          /load_live_state\(\)/,
          /PROCESS_ARGS="\$\(ps -eo pid=,args=/,
          /stats\(\) \{[\s\S]*?load_live_state \|\| return 1/,
        ],
      },
    },
    alternative: 'worktree-lifecycle.sh must load host-wide state once per live-state snapshot (load_live_state with a single ps into PROCESS_ARGS) and filter rows per worktree; per-worktree rescans of node-owner records or the process table blow the reap/stats budget at load.',
  },
  {
    lesson: 'V1144',
    classTag: 'worktree-reap-issue-query-failure',
    files: {
      [worktreeLifecycle]: {
        require: [
          /load_rescue_issue_states/,
          /if ! load_rescue_issue_states; then/,
          /rescue-ref sweep aborted/,
          /phase=worktree-reap:rescue-issue-query/,
        ],
      },
    },
    alternative: 'The reap rescue-ref sweep must read rescue issue states in one cached batch (load_rescue_issue_states) and abort the whole sweep -- keeping refs and skipping issue-expiry and patch-equivalence cleanup -- when that refresh fails; per-ref GitHub queries and letting "unknown" states flow into the sweep are the recurrence.',
  },
  {
    lesson: 'V1188',
    classTag: 'write-guard-blocked-scratch-homes',
    files: {
      'engine/write-guard.sh': {
        require: [/\[\[ -e "\$agent_home\/checkout" \]\] \|\| return 0/],
      },
    },
    alternative: 'write-guard.sh must only guard agent homes that carry a runtime checkout ([[ -e "$agent_home/checkout" ]] || return 0); CI and AGENT_HOME=$(mktemp -d) preflights have no checkout and must not be refused at lib.sh initialization.',
  },
  {
    lesson: 'V1203',
    classTag: 'github-egress-transient-fetch-retry',
    files: {
      [libTransport]: {
        require: [
          /git_fetch_bounded\(\)/,
          /ZF_GIT_FETCH_TRANSIENT_RETRIES:-2/,
          /http\.lowSpeedTime=20/,
        ],
      },
    },
    alternative: 'Pipeline GitHub/git origin reads go through git_fetch_bounded with its recognized-transient retry (ZF_GIT_FETCH_TRANSIENT_RETRIES, 1s/2s backoff) and the 20s low-speed abort (http.lowSpeedTime=20); under the shared main lock, transient transport retries defer to land-queue instead of retrying in place.',
  },
  {
    lesson: 'V1267',
    classTag: 'hand-addendum-delivery-1011',
    files: {
      [landQueue]: {
        require: [
          /hand_addendum_pending_for_report/,
          /queue_hand_pending_addendum/,
          /\.addenda\.lock/,
        ],
      },
    },
    alternative: 'A running hand whose brief changed is not delivered by its original dispatch: land-queue must record live-run addenda (addenda.lock journal), check report acknowledgement at exit via hand_addendum_pending_for_report/queue_hand_pending_addendum, and enqueue exactly one resume for anything missed.',
  },
  {
    lesson: 'V368',
    classTag: 'cihost-ci-rootless-anonymous-volume-age-bound',
    files: {
      'engine/systemd/cihost-ci-rootless-volume-reclaim.sh': {
        require: [
          /24 hours ago/,
          /label=com\.docker\.volume\.anonymous/,
          /dangling=true/,
        ],
      },
    },
    alternative: 'CI rootless anonymous-volume reclaim must stay bounded to the CI daemons and to Docker-marked anonymous, still-dangling volumes older than 24 hours (64-hex names); widening the daemon set or dropping the age/label bound deletes live data.',
  },
  {
    lesson: 'V370',
    classTag: 'cihost-nexus-soft-deleted-blobs-fill-root',
    files: {
      'scripts/ops/nexus-retention.py': {
        require: [/blobstore\.compact/, /assetBlob\.cleanup/],
      },
    },
    alternative: 'Nexus soft deletes do not return disk space: nexus-retention.py must keep waiting on the Docker assetBlob.cleanup task and then run blobstore.compact on the default blobstore, with live components and the Compose rollback chain snapshotted before deletion.',
  },
  {
    lesson: 'V429',
    classTag: 'focused-test-filename-reference-miss',
    files: {
      'engine/focused-test-paths.mjs': {
        require: [/function filenameReferencedTests/, /'-F', filename/],
      },
    },
    alternative: 'focused-test-paths.mjs must keep filenameReferencedTests: besides the explicit mapping, every test file that textually references a changed or deleted file\'s filename joins the selection, plus the same-named suites of scripts that reference it (#4599: lesson-lints.mjs anchors lib.sh); dropping it lets fixture-loading suites miss their indirect lib.sh/supervise-pipeline.sh changes.',
  },
  {
    lesson: 'V603',
    classTag: 'transient-github-reads-in-direct-main-landing',
    files: {
      [lander]: {
        require: [/land_git_transport_retry\(\)/],
      },
      [landQueue]: {
        require: [/-E "http_proxy=\$proxy_url"/, /EnvironmentFile=\$AGENT_HOME\/env/],
      },
    },
    alternative: 'Direct-main transient GitHub reads retry only when landing preflight enables it and a second failure names the ruling or guard (land_git_transport_retry); detached landing units must keep every proxy and bypass variable plus EnvironmentFile from zenoforge-agent.env, or reads fail on hosts where only the unit has egress.',
  },
  {
    lesson: 'V651',
    classTag: 'postsubmit-read-failed-landed-push',
    files: {
      [lander]: {
        require: [
          /land_git_transport_retry land_git_network push/,
          /landing remains successful/,
        ],
      },
    },
    alternative: 'After a successful push, a failed read-only GitHub call must never fail the landing: keep the push inside land_git_transport_retry land_git_network push and keep postsubmit revalidation failures advisory ("landing remains successful") so a slow proxy response cannot turn a landed commit into a failed landing that skips cleanup and hold release.',
  },
  {
    lesson: 'V890',
    classTag: 'land-queue-network-and-worktree-recovery',
    files: {
      [landQueue]: {
        require: [
          /QUEUE_SNAPSHOT_ERROR/,
          /could not recreate missing worktree from branch=/,
        ],
      },
    },
    alternative: 'A queued landing that hits a shared network failure keeps its request and retries; a vanished worktree is recovered only when the recorded branch still points at the recorded commit (QUEUE_SNAPSHOT_ERROR otherwise) -- never recreate from whatever the branch points at now.',
  },
  {
    lesson: 'V925',
    classTag: 'failure-decisive-line-blind-rerun',
    files: {
      [libImplementGates]: {
        require: [
          /implement_failure_class_key\(\)/,
          /blind_rerun_failure_paths\(\)/,
        ],
      },
      [lib]: {
        require: [/last two implement failures share a stage/],
      },
    },
    alternative: 'Keep the blind-rerun gate: failure records keep the decisive line (implement_failure_class_key over the stage and failing commands), and a ticket whose last two implement failures share stage and failure class is parked, not redispatched, until an input actually changes (blind_rerun_failure_paths).',
  },
  {
    lesson: 'V931',
    classTag: 'cihost-units-landed-never-installed',
    files: {
      [lander]: {
        require: [/cihost_sync_path\(\)/, /landed but not installed on cihost/],
      },
    },
    alternative: 'A cihost unit or script landed on main is live on cihost in the same landing: the lander must run every sync-cihost-*.sh selected by cihost_sync_path() from origin/main and raise "landed but not installed on cihost" when a sync fails; cihost units must reference installed paths, never a WSL checkout path.',
  },
  {
    lesson: 'V933',
    classTag: 'hand-efficiency-regression-alarm',
    files: {
      'engine/night/efficiency-regression.mjs': {
        require: [/MIN_HISTORY_HOURS = 24/, /function violates\(/],
      },
    },
    alternative: 'efficiency-regression.mjs must keep alerting on baseline regressions (violates() over floor/delta rules) and must keep HEALTH UNKNOWN until MIN_HISTORY_HOURS = 24 of hourly history exist, naming the stage with the largest latency increase or most stuck tickets.',
  },
  {
    lesson: 'V1003',
    classTag: 'paused-implement-held-hands-redispatch',
    files: {
      [libHolds]: {
        require: [
          /scheduler_requeue_issue "\$n" "hold owner \$dead_owner is inactive"/,
          /scheduler_requeue_issue "\$n" "hold expired; \$release_condition"/,
        ],
      },
      'engine/supervisor-holds.sh': {
        require: [/scheduler_requeue_issue "\$n" "supervisor hold \$kind has no live owner"/],
      },
    },
    alternative: 'Ownerless and expired held work returns through scheduler_requeue_issue and issue_transition; the scheduler alone applies the implement cap. The hold sweep must not start a parallel hand owner, and post-release ops acceptance stays on hold for the supervisor inbox.',
  },
  {
    lesson: 'V1044',
    classTag: 'release-chain-gate-blames-preexisting-owner-content',
    files: {
      'scripts/release/run-release.sh': {
        require: [/record_preexisting_timing_miss\(\)/, /record_preexisting_e2e_failure\(\)/],
      },
    },
    alternative: 'The release gate over shared runtime content must accept what the deployed images themselves provision and what the owner chain already knows: keep record_preexisting_timing_miss()/record_preexisting_e2e_failure() so pre-existing owner-recorded content is classified, and fail only on content neither explains.',
  },
  {
    lesson: 'V1126',
    classTag: 'direct-main-dagger-prepush-suites',
    files: {
      [lander]: {
        require: [
          /dispatch_pipeline_suites_after_landing "\$main_sha"/,
          /land_main_rebase_after_advance\(\)/,
        ],
      },
    },
    alternative: 'Non-product direct-main landings dispatch Pipeline suites after push (dispatch_pipeline_suites_after_landing), and a main advance during landing rebases (land_main_rebase_after_advance) before the landed head is verified. Do not restore pre-push suite execution for this lane.',
  },
  {
    lesson: 'V1147',
    classTag: 'worktree-reap-multi-commit-patch-equivalence',
    files: {
      [worktreeLifecycle]: {
        require: [
          /main_patch_index_write_state/,
          /patches_in_main/,
          /merged_pr_content_is_reachable/,
        ],
      },
    },
    alternative: 'worktree reap must compare each non-merge rescue commit patch against the main patch index in bounded batches (main_patch_index_write_state cursor state, patches_in_main); any unmatched patch, merge commit, or timeout keeps the rescue ref -- a rescue is only deletable via merged_pr_content_is_reachable or a full patch match.',
  },
];

// Exact-second greps fail when a stall moves the elapsed value (three CI failures 11-07). No ranking row backs this class, so it is a plain scan of changed test files.
export const exactSecondLint = {
  classTag: 'exact-second-elapsed-grep',
  pattern: /grep -Fq\b.*\b(?:after|at) [0-9]+s\b/,
  alternative: 'Match an elapsed-seconds value with grep -Eq and [0-9]+s, never one exact second: SECONDS and scheduler timers keep ticking, so a stall moves the value by one. Example: grep -Eq "after [0-9]+s: ..." "$LOG".',
};

// A script run through the engine-live symlink has import.meta.url by real path and argv[1] as typed, so a plain compare is false and the script exits 0 doing nothing (release batch #1147, 11-07).
export const entryCheckLint = {
  classTag: 'symlink-blind-entry-check',
  pattern: /^\s*if \((?=.*process\.argv\[1\])(?=.*===)/,
  alternative: 'Use process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)), inline, so a script copied alone still runs; without existsSync an import under a non-path argv[1] throws: an entry check that compares process.argv[1] without realpathSync silently does nothing through a symlink and exits 0.',
};

export function entryCheckFailures(files, readSource) {
  const failures = [];
  for (const file of files.filter((p) => /\.m?js$/.test(p) && !/\.test\.m?js$/.test(p))) {
    let source;
    try {
      source = readSource(file);
    } catch {
      continue; // deleted at head
    }
    source.split(/\r?\n/).forEach((line, index) => {
      if (entryCheckLint.pattern.test(line) && !line.includes('existsSync(process.argv[1])')) failures.push(`${file}:${index + 1}`);
    });
  }
  return failures;
}

export function exactSecondFailures(files, readSource) {
  const failures = [];
  for (const file of files.filter((p) => p.endsWith('.test.sh'))) {
    let source;
    try {
      source = readSource(file);
    } catch {
      continue; // deleted at head
    }
    source.split(/\r?\n/).forEach((line, index) => {
      if (exactSecondLint.pattern.test(line)) failures.push(`${file}:${index + 1}`);
    });
  }
  return failures;
}

// A %(...Z)T or date +...Z stamp formats in the process TZ but ends in a literal Z, so Asia/Shanghai scopes wrote worker cost rows 8 h ahead (worker-scope.sh, 11-09).
export const utcStampLint = {
  classTag: 'local-tz-z-stamp',
  pattern: /%\(.*Z\)T|\bdate\s+(?!-u\b)[^|;&]*\+[^\s'"]*Z\b/,
  alternative: 'Put TZ=UTC0 on the stamp\'s own line (TZ=UTC0 printf -v now \'%(%Y-%m-%dT%H:%M:%SZ)T\' -1 in a builtin-only watcher) or use date -u +%Y-%m-%dT%H:%M:%SZ. The lint reads one line at a time, so a TZ set on an earlier line does not count.',
};

export function utcStampFailures(files, readSource) {
  const failures = [];
  for (const file of files.filter((p) => p.endsWith('.sh'))) {
    let source;
    try {
      source = readSource(file);
    } catch {
      continue; // deleted at head
    }
    source.split(/\r?\n/).forEach((line, index) => {
      if (utcStampLint.pattern.test(line) && !/\bTZ=UTC0?\b/.test(line)) failures.push(`${file}:${index + 1}`);
    });
  }
  return failures;
}

export function lintPaths(lint) {
  return lint.gate ?? [...Object.keys(lint.files), lintPath, rankingPath];
}

export function lintAppliesTo(lint, paths) {
  const exact = new Set(lintPaths(lint));
  return paths.some((file) => exact.has(file));
}

export function inspectLintSources(lint, readSource) {
  const missing = [];
  for (const [file, rules] of Object.entries(lint.files)) {
    let source;
    try {
      source = readSource(file);
    } catch (error) {
      missing.push(`${file} is unreadable at head (${error.message})`);
      continue;
    }
    for (const pattern of rules.require ?? []) {
      if (!pattern.test(source)) missing.push(`${file} no longer matches ${pattern}`);
    }
    for (const pattern of rules.forbid ?? []) {
      if (pattern.test(source)) missing.push(`${file} now matches forbidden ${pattern}`);
    }
  }
  return missing;
}

export function buildLessonLintVerdict({ lint, paths, readSource, ranking }) {
  if (!lintAppliesTo(lint, paths)) return { verdict: 'skip', missing: [] };
  const row = ranking?.ranking?.find((entry) => entry.lesson_id === lint.lesson && entry.incident_class_tag === lint.classTag);
  const missing = [];
  if (!row || !Number.isInteger(row.recurrence_count) || row.recurrence_count < 2) {
    missing.push(`recurrence ranking is missing ${lint.lesson} ${lint.classTag} evidence`);
  }
  missing.push(...inspectLintSources(lint, readSource));
  return {
    verdict: missing.length ? 'fail' : 'pass',
    missing,
    recurrence_count: row?.recurrence_count ?? 0,
    ...(missing.length ? { fix_guidance: lint.alternative } : {}),
  };
}

function parseArgs(args) {
  const options = { repo: defaultRepo, base: '', head: 'HEAD', ledger: '', lifecycle: false, days: 30 };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--lifecycle') {
      options.lifecycle = true;
    } else if (arg === '--repo' || arg === '--base' || arg === '--head' || arg === '--ledger' || arg === '--days') {
      const value = args[index + 1];
      if (!value) throw new Error(`${arg} requires a value`);
      const key = arg.slice(2);
      options[key] = key === 'days' ? Number(value) : value;
      index += 1;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (options.lifecycle) {
    if (!options.ledger) throw new Error('--ledger is required with --lifecycle');
    if (!Number.isInteger(options.days) || options.days < 1) throw new Error('--days must be a positive integer');
  } else if (!options.base) {
    throw new Error('--base is required');
  }
  return options;
}

function git(repo, args) {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
}

function appendLifecycleRow(ledger, row, log) {
  if (!ledger) return true;
  try {
    mkdirSync(path.dirname(ledger), { recursive: true });
    appendFileSync(ledger, `${JSON.stringify(row)}\n`);
    return true;
  } catch (error) {
    log(`lesson-lint: ledger-write-failed${error?.code ? ` code=${error.code}` : ''}`);
    return false;
  }
}

function effectiveMode(lint) {
  const mode = lint.mode ?? 'enforce';
  if (mode !== 'observe' && mode !== 'enforce') throw new Error(`invalid lesson lint mode: ${mode}`);
  return mode;
}

export const lessonLintRegistry = [...lessonLints, exactSecondLint, entryCheckLint, utcStampLint];

function lifecycleKey(lint) {
  return `${lint.lesson ?? 'none'}\u0000${lint.classTag}`;
}

export function runLessonLints({ repo, base, head = 'HEAD', ledger = '', log = (line) => console.log(line) }) {
  const paths = git(repo, ['diff', '--name-only', `${base}...${head}`, '--']).split(/\r?\n/).filter(Boolean);
  const ranking = JSON.parse(git(repo, ['show', `${head}:${rankingPath}`]));
  const readSource = (file) => git(repo, ['show', `${head}:${file}`]);
  const headSha = ledger ? git(repo, ['rev-parse', '--verify', `${head}^{commit}`]).trim() : '';
  let ledgerWritable = true;
  let failed = 0;
  for (const lint of lessonLints) {
    const result = buildLessonLintVerdict({ lint, paths, readSource, ranking });
    if (result.verdict === 'skip') continue;
    const mode = effectiveMode(lint);
    const verdict = result.verdict === 'fail' && mode === 'observe' ? 'would-fail' : result.verdict;
    const line = `lesson-lint: lesson=${lint.lesson} incident_class=${lint.classTag} recurrence_count=${result.recurrence_count ?? 0} verdict=${verdict}`;
    log(result.missing?.length ? `${line} ${formatLintRefusal(lint.alternative, result.missing)}` : line);
    if (result.verdict === 'fail') {
      if (mode === 'enforce') failed += 1;
    }
    if (ledgerWritable) ledgerWritable = appendLifecycleRow(ledger, {
      lesson: lint.lesson,
      classTag: lint.classTag,
      mode,
      verdict,
      head_sha: headSha,
      utc_time: new Date().toISOString(),
    }, log);
  }
  for (const [lint, matches, findFailures] of [
    [exactSecondLint, (file) => file.endsWith('.test.sh'), exactSecondFailures],
    [entryCheckLint, (file) => /\.m?js$/.test(file) && !/\.test\.m?js$/.test(file), entryCheckFailures],
    [utcStampLint, (file) => file.endsWith('.sh'), utcStampFailures],
  ]) {
    if (!paths.some(matches)) continue;
    const hits = findFailures(paths, readSource);
    const mode = effectiveMode(lint);
    const verdict = hits.length ? (mode === 'observe' ? 'would-fail' : 'fail') : 'pass';
    for (const hit of hits) log(`lesson-lint: lesson=none incident_class=${lint.classTag} verdict=${verdict} ${formatLintRefusal(lint.alternative, hit)}`);
    if (mode === 'enforce') failed += hits.length;
    if (ledgerWritable) ledgerWritable = appendLifecycleRow(ledger, {
      lesson: 'none',
      classTag: lint.classTag,
      mode,
      verdict,
      head_sha: headSha,
      utc_time: new Date().toISOString(),
    }, log);
  }
  return failed;
}

function lintAddedAt(repo, lint) {
  const anchor = lint.lesson ? `lesson: '${lint.lesson}'` : lint.classTag;
  try {
    const entries = git(repo, ['log', '--reverse', '--format=%cI', '-S', anchor, '--', lintPath]).trim();
    return entries ? new Date(entries.split(/\r?\n/)[0]) : null;
  } catch {
    return null;
  }
}

export function runLessonLintLifecycle({ repo, ledger, days = 30, now = Date.now(), log = (line) => console.log(line) }) {
  const rows = [];
  try {
    for (const line of readFileSync(ledger, 'utf8').split(/\r?\n/).filter(Boolean)) {
      try {
        rows.push(JSON.parse(line));
      } catch {
        // Ignore a partial ledger write without losing earlier rows.
      }
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const current = new Map(lessonLintRegistry.map((lint) => [lifecycleKey(lint), lint]));
  const events = new Map();
  for (const row of rows) {
    if (typeof row?.classTag !== 'string' || typeof row?.utc_time !== 'string') continue;
    const key = lifecycleKey(row);
    if (!current.has(key)) continue;
    const at = new Date(row.utc_time);
    if (!Number.isFinite(at.getTime())) continue;
    const list = events.get(key) ?? [];
    list.push({ ...row, at });
    events.set(key, list);
  }

  const cutoff = now - days * 24 * 60 * 60 * 1000;
  const summaries = lessonLintRegistry.map((lint) => {
    const lintEvents = events.get(lifecycleKey(lint)) ?? [];
    const window = lintEvents.filter((event) => event.at.getTime() >= cutoff && event.at.getTime() <= now);
    const first = lintEvents[0];
    const introduced = first ? first.at : lintAddedAt(repo, lint);
    const ageDays = introduced && Number.isFinite(introduced.getTime())
      ? Math.floor((now - introduced.getTime()) / (24 * 60 * 60 * 1000))
      : null;
    return {
      lint,
      mode: effectiveMode(lint),
      triggers: window.length,
      fails: window.filter((event) => event.verdict === 'fail').length,
      wouldFails: window.filter((event) => event.verdict === 'would-fail').length,
      ageDays,
      ageSource: first ? 'ledger' : introduced ? (lint.lesson ? 'git-log-lesson' : 'git-log-class') : 'unknown',
    };
  });

  log(`lesson-lifecycle: window=${days}d`);
  for (const item of summaries) {
    log(`lesson-lifecycle: lesson=${item.lint.lesson ?? 'none'} classTag=${item.lint.classTag} mode=${item.mode} `
      + `triggers=${item.triggers} fails=${item.fails} would-fails=${item.wouldFails} `
      + `age_days=${item.ageDays ?? 'unknown'} age_source=${item.ageSource}`);
  }
  log('candidates-to-enforce:');
  for (const item of summaries.filter((row) => row.mode === 'observe')) {
    log(`  lesson=${item.lint.lesson ?? 'none'} classTag=${item.lint.classTag} would-fails=${item.wouldFails}`);
  }
  log('candidates-to-retire:');
  for (const item of summaries.filter((row) => row.triggers === 0 && row.ageDays !== null && row.ageDays >= days)) {
    log(`  lesson=${item.lint.lesson ?? 'none'} classTag=${item.lint.classTag} age_days=${item.ageDays} age_source=${item.ageSource}`);
  }
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const repo = path.resolve(options.repo);
    if (options.lifecycle) {
      runLessonLintLifecycle({ repo, ledger: path.resolve(options.ledger), days: options.days });
    } else {
      const failed = runLessonLints({
        repo,
        base: options.base,
        head: options.head,
        ledger: options.ledger && path.resolve(options.ledger),
      });
      if (failed > 0) process.exitCode = 1;
    }
  } catch (error) {
    console.error(`lesson-lint: ${formatLintRefusal('correct the command or make the requested Git revision readable', error instanceof Error ? error.message : String(error))}`);
    process.exitCode = 1;
  }
}
