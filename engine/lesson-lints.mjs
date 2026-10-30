#!/usr/bin/env node

// M6 lesson lints (#4503): every lesson with recurrence >= 2 in
// lessons/recurrence-ranking.json that has a structural prevention anchor
// gets a landing-time lint, in the same shape as the V930 tracer bullet
// (#4502, engine/supervisor-hold-lesson-lint.mjs): gated on the
// diff, checked against the head sources, refusing the landing with the
// repair guidance as the error text. V894 (node-owner-detail-churn-per-pr)
// is the one recurrence >= 2 lesson without a locatable structural anchor
// today and stays test-enforced instead.

import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const defaultRepo = path.resolve(scriptDir, '..');
const lintPath = 'engine/lesson-lints.mjs';
const rankingPath = 'lessons/recurrence-ranking.json';
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
    guidance: 'Route every pipeline state transition through issue_transition with the ISSUE_TRANSITION_TABLE legality check; state writes that run inside it must keep the __issue_transition_lock_held lock mode. Keep HEALTH label/state drift detection read-only.',
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
    guidance: 'Keep queue-driven preflight admission memory-only (MemAvailable >= 3072 MiB, no load average gate) and start one independent land-direct-main.sh worker per enqueue request; the shared main lock covers only the final rebase and push.',
  },
  {
    lesson: 'V915',
    classTag: 'ci-runner-label-pool',
    files: {
      'engine/provision-cihost-ci-runner.sh': {
        require: [
          /runner_labels="cihost-ci,cihost-ci-testcontainers,cihost-ci-light,vecta-suites"/,
          /install -d -o "\$runner_user" -g "\$runner_user" -m 0700 "\$runner_home\/\.config"/,
        ],
      },
    },
    guidance: 'Keep the corrected PR-runner label pool (cihost-ci,cihost-ci-testcontainers,cihost-ci-light,vecta-suites) in provision-cihost-ci-runner.sh and keep ~/.config owned by the runner user at creation time; a root-owned ~/.config breaks rootless setup.',
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
    guidance: 'Pass unbounded JSON (issue state, issue/PR lists, brief_md and other model prose) to jq on stdin or through jq_arg_file()/--slurpfile, never as --argjson/--arg: one argv element over 128 KiB makes execve fail with "Argument list too long". Extend jq-arg-safety.test.sh when a new unbounded variable name appears.',
  },
  {
    lesson: 'V797',
    classTag: 'postsubmit-in-progress-masks-red',
    files: {
      [libCiChecks]: {
        require: [/ci_main_completed_push_runs\(\)/, /status=completed&per_page=\d+&page=1/],
      },
    },
    guidance: 'Keep main Postsubmit verdict reads querying completed runs only (ci_main_completed_push_runs with status=completed); an "in progress" run is not a verdict and must never reset a red main to OK.',
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
    guidance: 'branch-delivery-preflight.mjs must keep commit as its default mode and run every locally reproducible gate in that mode; a gate that only runs in a mode nobody uses lets the same avoidable red reach CI on every PR.',
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
    guidance: 'worktree-lifecycle.sh must load host-wide state once per live-state snapshot (load_live_state with a single ps into PROCESS_ARGS) and filter rows per worktree; per-worktree rescans of node-owner records or the process table blow the reap/stats budget at load.',
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
    guidance: 'The reap rescue-ref sweep must read rescue issue states in one cached batch (load_rescue_issue_states) and abort the whole sweep -- keeping refs and skipping issue-expiry and patch-equivalence cleanup -- when that refresh fails; per-ref GitHub queries and letting "unknown" states flow into the sweep are the recurrence.',
  },
  {
    lesson: 'V1188',
    classTag: 'write-guard-blocked-scratch-homes',
    files: {
      'engine/write-guard.sh': {
        require: [/\[\[ -e "\$agent_home\/checkout" \]\] \|\| return 0/],
      },
    },
    guidance: 'write-guard.sh must only guard agent homes that carry a runtime checkout ([[ -e "$agent_home/checkout" ]] || return 0); CI and AGENT_HOME=$(mktemp -d) preflights have no checkout and must not be refused at lib.sh initialization.',
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
    guidance: 'Pipeline GitHub/git origin reads go through git_fetch_bounded with its recognized-transient retry (ZF_GIT_FETCH_TRANSIENT_RETRIES, 1s/2s backoff) and the 20s low-speed abort (http.lowSpeedTime=20); under the shared main lock, transient transport retries defer to land-queue instead of retrying in place.',
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
    guidance: 'A running hand whose brief changed is not delivered by its original dispatch: land-queue must record live-run addenda (addenda.lock journal), check report acknowledgement at exit via hand_addendum_pending_for_report/queue_hand_pending_addendum, and enqueue exactly one resume for anything missed.',
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
    guidance: 'CI rootless anonymous-volume reclaim must stay bounded to the CI daemons and to Docker-marked anonymous, still-dangling volumes older than 24 hours (64-hex names); widening the daemon set or dropping the age/label bound deletes live data.',
  },
  {
    lesson: 'V370',
    classTag: 'cihost-nexus-soft-deleted-blobs-fill-root',
    files: {
      'scripts/ops/nexus-retention.py': {
        require: [/blobstore\.compact/, /assetBlob\.cleanup/],
      },
    },
    guidance: 'Nexus soft deletes do not return disk space: nexus-retention.py must keep waiting on the Docker assetBlob.cleanup task and then run blobstore.compact on the default blobstore, with live components and the Compose rollback chain snapshotted before deletion.',
  },
  {
    lesson: 'V429',
    classTag: 'focused-test-filename-reference-miss',
    files: {
      'engine/focused-test-paths.mjs': {
        require: [/function filenameReferencedTests/, /'-F', filename/],
      },
    },
    guidance: 'focused-test-paths.mjs must keep filenameReferencedTests: besides the explicit mapping, every test file that textually references a changed or deleted file\'s filename joins the selection, plus the same-named suites of scripts that reference it (#4599: lesson-lints.mjs anchors lib.sh); dropping it lets fixture-loading suites miss their indirect lib.sh/supervise-pipeline.sh changes.',
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
    guidance: 'Direct-main transient GitHub reads retry only when landing preflight enables it and a second failure names the ruling or guard (land_git_transport_retry); detached landing units must keep every proxy and bypass variable plus EnvironmentFile from zenoforge-agent.env, or reads fail on hosts where only the unit has egress.',
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
    guidance: 'After a successful push, a failed read-only GitHub call must never fail the landing: keep the push inside land_git_transport_retry land_git_network push and keep postsubmit revalidation failures advisory ("landing remains successful") so a slow proxy response cannot turn a landed commit into a failed landing that skips cleanup and hold release.',
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
    guidance: 'A queued landing that hits a shared network failure keeps its request and retries; a vanished worktree is recovered only when the recorded branch still points at the recorded commit (QUEUE_SNAPSHOT_ERROR otherwise) -- never recreate from whatever the branch points at now.',
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
    guidance: 'Keep the blind-rerun gate: failure records keep the decisive line (implement_failure_class_key over the stage and failing commands), and a ticket whose last two implement failures share stage and failure class is parked, not redispatched, until an input actually changes (blind_rerun_failure_paths).',
  },
  {
    lesson: 'V931',
    classTag: 'cihost-units-landed-never-installed',
    files: {
      [lander]: {
        require: [/cihost_sync_path\(\)/, /landed but not installed on cihost/],
      },
    },
    guidance: 'A cihost unit or script landed on main is live on cihost in the same landing: the lander must run every sync-cihost-*.sh selected by cihost_sync_path() from origin/main and raise "landed but not installed on cihost" when a sync fails; cihost units must reference installed paths, never a WSL checkout path.',
  },
  {
    lesson: 'V933',
    classTag: 'hand-efficiency-regression-alarm',
    files: {
      'engine/night/efficiency-regression.mjs': {
        require: [/MIN_HISTORY_HOURS = 24/, /function violates\(/],
      },
    },
    guidance: 'efficiency-regression.mjs must keep alerting on baseline regressions (violates() over floor/delta rules) and must keep HEALTH UNKNOWN until MIN_HISTORY_HOURS = 24 of hourly history exist, naming the stage with the largest latency increase or most stuck tickets.',
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
    guidance: 'Ownerless and expired held work returns through scheduler_requeue_issue and issue_transition; the scheduler alone applies the implement cap. The hold sweep must not start a parallel hand owner, and post-release ops acceptance stays on hold for the supervisor inbox.',
  },
  {
    lesson: 'V1044',
    classTag: 'release-chain-gate-blames-preexisting-owner-content',
    files: {
      'engine/run-release.sh': {
        require: [/record_preexisting_timing_miss\(\)/, /record_preexisting_e2e_failure\(\)/],
      },
    },
    guidance: 'The release gate over shared runtime content must accept what the deployed images themselves provision and what the owner chain already knows: keep record_preexisting_timing_miss()/record_preexisting_e2e_failure() so pre-existing owner-recorded content is classified, and fail only on content neither explains.',
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
    guidance: 'Non-product direct-main landings dispatch Pipeline suites after push (dispatch_pipeline_suites_after_landing), and a main advance during landing rebases (land_main_rebase_after_advance) before the landed head is verified. Do not restore pre-push suite execution for this lane.',
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
    guidance: 'worktree reap must compare each non-merge rescue commit patch against the main patch index in bounded batches (main_patch_index_write_state cursor state, patches_in_main); any unmatched patch, merge commit, or timeout keeps the rescue ref -- a rescue is only deletable via merged_pr_content_is_reachable or a full patch match.',
  },
];

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
    ...(missing.length ? { fix_guidance: lint.guidance } : {}),
  };
}

function parseArgs(args) {
  const options = { repo: defaultRepo, base: '', head: 'HEAD' };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--repo' || arg === '--base' || arg === '--head') {
      const value = args[index + 1];
      if (!value) throw new Error(`${arg} requires a value`);
      options[arg.slice(2)] = value;
      index += 1;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!options.base) throw new Error('--base is required');
  return options;
}

function git(repo, args) {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
}

export function runLessonLints({ repo, base, head, log = (line) => console.log(line) }) {
  const paths = git(repo, ['diff', '--name-only', `${base}...${head}`, '--']).split(/\r?\n/).filter(Boolean);
  const ranking = JSON.parse(git(repo, ['show', `${head}:${rankingPath}`]));
  const readSource = (file) => git(repo, ['show', `${head}:${file}`]);
  let failed = 0;
  for (const lint of lessonLints) {
    const result = buildLessonLintVerdict({ lint, paths, readSource, ranking });
    if (result.verdict === 'skip') continue;
    const line = `lesson-lint: lesson=${lint.lesson} incident_class=${lint.classTag} recurrence_count=${result.recurrence_count ?? 0} verdict=${result.verdict}`;
    log(result.missing?.length ? `${line} missing=${result.missing.join('; ')}` : line);
    if (result.verdict === 'fail') {
      log(`lesson-lint: fix: ${lint.guidance}`);
      failed += 1;
    }
  }
  return failed;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const failed = runLessonLints({ repo: path.resolve(options.repo), base: options.base, head: options.head });
    if (failed > 0) process.exitCode = 1;
  } catch (error) {
    console.error(`lesson-lint: verdict=fail error=${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
