import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

// Execute the real shared functions and the actual advisor dispatch block,
// while replacing only model/remote side effects. No paid call or live HOME
// is used.
//
// Exercise the current advisor dispatch and polling contract with isolated local fixtures.
const here = dirname(fileURLToPath(import.meta.url));
const lib = join(here, 'lib.sh');
const advisorCore = join(here, 'advisor-core.sh');
// Load real shared helpers with isolated state and replace only model/remote
// effects. The full shell suites cover production entrypoint initialization.
const advisor = readFileSync(join(here, 'run-advisor.sh'), 'utf8');
const begin = advisor.indexOf('\nPENDING_VERDICT_RESULT="$(advisor_resume_check');
const end = advisor.indexOf('\nVERDICT="$(echo "$RESULT"', begin);
assert.ok(begin >= 0 && end > begin, 'the executable advisor dispatch block must be found');
const dispatchBlock = advisor.slice(begin, end);
const testJqHome = process.env.ADVISOR_CONVERGENCE_JQ_HOME || process.env.HOME;
const testJqBin = process.env.ADVISOR_CONVERGENCE_JQ_BIN || (() => {
  const testJq = spawnSync('sh', ['-c', 'command -v jq'], { encoding: 'utf8' });
  assert.equal(testJq.status, 0, testJq.stderr);
  return testJq.stdout.trim();
})();

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'zf-advisor-contract-'));
  const repo = spawnSync('git', ['init', '--quiet', root], { encoding: 'utf8' });
  assert.equal(repo.status, 0, repo.stderr);
  const fakeBin = join(root, 'fake-bin');
  mkdirSync(fakeBin, { recursive: true });
  writeFileSync(join(fakeBin, 'jq'), [
    '#!/usr/bin/env bash',
    'HOME="$ADVISOR_CONVERGENCE_JQ_HOME" LD_LIBRARY_PATH="$ADVISOR_CONVERGENCE_JQ_HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$ADVISOR_CONVERGENCE_JQ_BIN" "$@"',
    '',
  ].join('\n'));
  chmodSync(join(fakeBin, 'jq'), 0o755);
  const env = { ...process.env, LC_ALL: 'C', HOME: root, AGENT_HOME: join(root, 'agent'), AGENT_DRY_RUN: '0', ZF_REPO: 'fixture/repo', ZF_REPO_DIR: root, ZF_GCLOUD_BIN: '/nonexistent/gcloud', PATH: `${fakeBin}:${process.env.PATH}`, ADVISOR_CONVERGENCE_JQ_HOME: testJqHome, ADVISOR_CONVERGENCE_JQ_BIN: testJqBin, ADVISOR_CONVERGENCE_LIB: lib, ADVISOR_CONVERGENCE_ADVISOR_CORE: advisorCore, ADVISOR_CONVERGENCE_ADVISOR_CONFIG: join(here, 'advisor-config.sh') };
  mkdirSync(join(root, 'agent/state'), { recursive: true });
  writeFileSync(join(root, 'agent/state/90042.json'), '{"attempts":2,"advisor_ruled_at":"prior"}');
  const policy = JSON.parse(readFileSync(join(here, 'model-policy.default.json'), 'utf8'));
  policy.roles.advisor.disabled = false; // This fixture exercises the advisor path even with the generic engine policy.
  policy.switches['roadmap-order'] = false; // This fixture tests advisor transitions, not tree placement.
  writeFileSync(join(root, 'agent/model-policy.json'), JSON.stringify(policy));
  const functions = join(root, 'functions.sh');
  writeFileSync(functions, [
    'source "$ADVISOR_CONVERGENCE_LIB"',
    'source "$ADVISOR_CONVERGENCE_ADVISOR_CORE"',
    'source "$ADVISOR_CONVERGENCE_ADVISOR_CONFIG"',
    'gh() {',
    '  # Lane routing reads live labels first (7bc93004); the fixture issue is a product ticket.',
    '  if [ "$1" = api ] && [[ "$*" == *"/issues/90042/comments?"* ]]; then printf \'%s\\n\' \'[[]]\'; return 0; fi',
    '  if [ "$*" = "issue view 90042 --repo fixture/repo --json number,labels" ]; then printf \'%s\\n\' \'{"number":90042,"labels":[]}\'; return 0; fi',
    '  if [ "$*" = "issue view 90042 --repo fixture/repo --json labels -q .labels[].name" ]; then return 0; fi',
    '  [ "$*" = "issue view 90042 --repo fixture/repo --json state,labels" ] || { echo "unexpected gh call: $*" >&2; return 64; }',
    "  printf '%s\\n' '{\"state\":\"OPEN\",\"labels\":[]}'",
    '}',
    'record_advisor_lease_decision() { :; }',
    '',
  ].join('\n'));
  return { root, env, functions, close: () => rmSync(root, { recursive: true, force: true }) };
}
function run(f, body, extra = {}) {
  return spawnSync('bash', ['-c', `set -euo pipefail\nsource "$1"\n${body}`, 'fixture', f.functions, here], {
    // Bound hung fixtures; shared-host cold startup exceeded 27s at load 82, without a protocol failure.
    env: { ...f.env, ...extra }, encoding: 'utf8', timeout: 60000,
  });
}
function text(f, relative) {
  const p = join(f.root, relative);
  return existsSync(p) ? readFileSync(p, 'utf8') : '';
}

test('fixture keeps jq usable after HOME isolation', () => {
  const f = fixture();
  try {
    const r = run(f, 'jq -n 0');
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), '0');
  } finally { f.close(); }
});

for (const [name, output, status, expected] of [
  ['valid zero usage is data', '{"is_error":false,"tokens_used":0}', '0', 'none'],
  ['a successful semantic quota mention is not an outage', '{"is_error":false,"result":"explain quota"}', '0', 'none'],
  ['structured rate limit', '{"is_error":true,"api_error_status":429}', '0', 'quota'],
  ['CLI usage refusal', "ERROR: You've hit your usage limit.", '1', 'quota'],
  ['provider 503', '{"is_error":true,"api_error_status":503}', '0', 'transient'],
  ['timeout status', '', '124', 'transient'],
  ['configuration error is not capacity', '{"is_error":true,"api_error_status":400}', '0', 'execution'],
  ['structured configuration error outranks incidental quota text', '{"is_error":true,"api_error_status":400,"result":"invalid quota field"}', '1', 'execution'],
  ['unauthorized is not capacity', '{"is_error":true,"api_error_status":401}', '1', 'execution'],
  ['string error flag cannot become a success', '{"is_error":"true"}', '0', 'execution'],
  ['zero as entire response is invalid', '0', '0', 'malformed'],
  ['null as entire response is invalid', 'null', '0', 'malformed'],
  ['empty response is not success', '', '0', 'malformed'],
]) {
  test(name, () => {
    const f = fixture();
    try {
      const r = run(f, 'model_call_failure_kind "$REPLY" "$EXIT_STATUS"', { REPLY: output, EXIT_STATUS: status });
      assert.equal(r.status, 0, r.stderr);
      assert.equal(r.stdout.trim(), expected);
    } finally { f.close(); }
  });
}

for (const attempts of [0, 3, 4, 9]) {
  test(`shared admission enforces cap at ${attempts} attempts without caller guards`, () => {
    const f = fixture();
    try {
      writeFileSync(join(f.root, 'agent/state/90042.json'), JSON.stringify({ attempts, advisor_ruled_at: 'prior' }));
      const r = run(f, `
loop_break_check() { LOOP_BREAK_ESCALATED=0; }
guarded_write() { echo label >> "$HOME/actions"; }
record_run_decision() { echo decision >> "$HOME/actions"; }
conclude_run() { echo conclude >> "$HOME/actions"; }
route_to_advisor 90042
`);
      assert.equal(r.status, 0, r.stderr);
      const state = JSON.parse(text(f, 'agent/state/90042.json'));
      assert.equal(state.attempts, attempts, 'routing must not reset attempts');
      assert.equal(text(f, 'actions').includes('label'), attempts < 4);
      assert.equal(text(f, 'actions').includes('conclude'), attempts >= 4);
      assert.equal('advisor_ruled_at' in state, attempts >= 4, 'exhausted episode is not reopened');
    } finally { f.close(); }
  });
}

test('failed conclusion cannot move the issue or clear the previous ruling', () => {
  const f = fixture();
  try {
    writeFileSync(join(f.root, 'agent/state/90042.json'), '{"attempts":4,"advisor_ruled_at":"prior"}');
    const r = run(f, `
loop_break_check() { echo forbidden >> "$HOME/actions"; }
guarded_write() { echo forbidden >> "$HOME/actions"; }
record_run_decision() { return 0; }
conclude_run() { echo reached > "$HOME/conclusion-reached"; return 1; }
route_to_advisor 90042
`);
    assert.equal(r.status, 1);
    assert.equal(text(f, 'conclusion-reached').trim(), 'reached', 'a setup failure cannot satisfy this negative test');
    assert.equal(text(f, 'actions'), '');
    assert.equal(JSON.parse(text(f, 'agent/state/90042.json')).attempts, 4);
    assert.equal(JSON.parse(text(f, 'agent/state/90042.json')).advisor_ruled_at, 'prior');
  } finally { f.close(); }
});

for (const failure of ['state', 'edit', 'comment']) {
  test(`real conclusion stops at ${failure} failure even inside a shell conditional`, () => {
    const f = fixture();
    try {
      writeFileSync(join(f.root, 'agent/state/90042.json'), JSON.stringify({ attempts: 4, advisor_ruled_at: 'prior', acceptor: 'none', run: { evidence: { pr_number: 42 } } }));
      const r = run(f, `
ALL_STATE_LABELS=(needs-advisor concluded)
BOT_DISCLAIMER=fixture
if [ "$FAIL_AT" = state ]; then
  state_merge() { echo reached > "$HOME/state-failure"; return 1; }
fi
ensure_state_labels() { :; }
guarded_write() {
  echo "$3" >> "$HOME/actions"
  [ "$3" != "$FAIL_AT" ]
}
if conclude_run 90042 merged "fixture"; then echo success; else echo failed; fi
`, { FAIL_AT: failure });
      assert.equal(r.status, 0, r.stderr);
      assert.equal(r.stdout.trim(), 'failed');
      assert.equal(text(f, 'actions').trim(), { state: '', edit: 'edit', comment: 'edit\ncomment' }[failure]);
      if (failure === 'state') assert.equal(text(f, 'state-failure').trim(), 'reached');
      const state = JSON.parse(text(f, 'agent/state/90042.json'));
      assert.equal(state.attempts, 4, 'failed conclusion must preserve attempts');
      assert.equal(state.advisor_ruled_at, 'prior', 'failed conclusion must preserve prior advisor ruling');
      assert.equal(state.closed_by_pipeline, undefined);
    } finally { f.close(); }
  });
}

test('invalid attempt state stands aside: admission neither concludes nor refuses, the caller guard owns the failure', () => {
  const f = fixture();
  try {
    const r = run(f, 'state_attempts() { echo broken; }; advisor_retry_admission 90042; echo "admission=$?"');
    assert.equal(r.status, 0);
    assert.match(r.stdout, /admission=0/);
    assert.doesNotMatch(r.stdout, /admission=10/);
    assert.doesNotMatch(r.stderr, /Advisor retry admission exhausted/);
    assert.doesNotMatch(r.stderr, /No further advisor episode was admitted/);
  } finally { f.close(); }
});

// Shared harness for the dispatch block: N/WT/SCRIPT_DIR match production's
// own script-global variables at the point the slice begins; ISSUE_JSON/
// PRIOR_STATE are the two inputs run-advisor.sh normally reads from a real
// `gh issue view` and state_read() before this slice starts, supplied here
// as plain env vars per call (never a default baked into the fixture body:
// `set -u` means a test that forgets one fails loudly, not silently, on an
// unbound-variable error rather than a wrong result). web_advisor_provider_
// usable()/_poll()/_dispatch_async() are the only functions this slice
// depends on that reach outside the process (CDP, a spawned browser job);
// every other name it calls (advisor_resume_check, advisor_persist_pending,
// state_merge, record_env_fault, model_call_failure_kind, log_model_
// failure, scrub_git_object_ids, jq_arg_file) is the real one, extracted
// above.
const dispatchFixture = `
N=90042
WT="$HOME/worktree"
SCRIPT_DIR="$2"
BOT_DISCLAIMER=fixture-disclaimer
WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS=2400
WEB_ADVISOR_PROVIDER_CDP_PORT=9224
WEB_ADVISOR_PROVIDER_SCRIPT="$HOME/web-advisor-provider-fixture.cjs"
SPEND_DIR="$AGENT_HOME/spend"
git() {
  local arg add=0
  for arg in "$@"; do
    if [ "$add" = 1 ]; then
      case "$arg" in
        -*) ;;
        *) mkdir -p "$arg"; return 0 ;;
      esac
    elif [ "$arg" = add ]; then
      add=1
    fi
  done
  return 0
}
gitnexus_refresh_index_once() { :; }
fail_attempt() {
  [ "$2" = 0 ] || pause_for_backoff
  state_bump_attempts "$N"
  exit 1
}
pause_for_backoff() { touch "$HOME/PAUSE"; }
web_advisor_provider_usable() { [ "\${USABLE:-1}" = 1 ]; }
web_advisor_provider_poll() {
  printf 'poll:%s\\n' "$1" >> "$HOME/calls"
  if [ -n "\${POLL_OUTPUT:-}" ]; then printf '%s' "$POLL_OUTPUT"; fi
  return "\${POLL_STATUS:-0}"
}
web_advisor_provider_dispatch_async() {
  printf 'dispatch:%s\\n' "$1" >> "$HOME/calls"
}
`;
function runDispatch(f, { issueJson = '{"title":"t","body":"b","comments":[]}', priorState = '{"attempts":2}', ...envOverrides } = {}) {
  // PRIOR_STATE (the env var the slice itself reads) and the real on-disk
  // state file must agree: state_merge() inside the slice reads/writes the
  // FILE, not this env var, so a scenario claiming an existing job (or a
  // pending verdict) must also be on disk or a post-run assertion would be
  // checking a field the real state never had.
  writeFileSync(join(f.root, 'agent/state/90042.json'), priorState);
  return run(f, dispatchFixture + dispatchBlock + '\nprintf "RESULT=%s DEGRADED=%s\\n" "$RESULT" "$ADVISOR_DEGRADED"\n',
    { ISSUE_JSON: issueJson, PRIOR_STATE: priorState, ...envOverrides });
}
function envFaultText(f) {
  const dir = join(f.root, 'agent/env-faults');
  if (!existsSync(dir)) return '';
  return readdirSync(dir).map((name) => readFileSync(join(dir, name), 'utf8')).join('\n');
}

test('CDP unreachable records an environment fault and charges no attempt', () => {
  const f = fixture();
  try {
    const r = runDispatch(f, { USABLE: '0' });
    assert.equal(r.status, 0, r.stderr);
    assert.doesNotMatch(r.stdout, /RESULT=/, 'must exit before a verdict is ever computed');
    assert.match(envFaultText(f), /advisor/);
    assert.equal(JSON.parse(text(f, 'agent/state/90042.json')).attempts, 2, 'an unreachable CDP session is never charged to the ticket');
    assert.equal(existsSync(join(f.root, 'PAUSE')), false);
  } finally { f.close(); }
});

test('an in-flight job still polling exits cleanly without charging an attempt', () => {
  const f = fixture();
  try {
    const priorState = JSON.stringify({ attempts: 2, web_advisor_provider_job_id: 'advisor-90042-1', web_advisor_provider_job_started_at: Math.floor(Date.now() / 1000) });
    const r = runDispatch(f, { priorState, POLL_STATUS: '2' });
    assert.equal(r.status, 0, r.stderr);
    assert.doesNotMatch(r.stdout, /RESULT=/);
    assert.match(text(f, 'calls'), /^poll:advisor-90042-1$/m);
    assert.equal(envFaultText(f), '', 'still-running is normal in-flight state, not a fault');
    const state = JSON.parse(text(f, 'agent/state/90042.json'));
    assert.equal(state.attempts, 2);
    assert.equal(state.web_advisor_provider_job_id, 'advisor-90042-1', 'a live poll never touches the job record');
  } finally { f.close(); }
});

test('a job past its own timeout ceiling is treated as a dead session, not a running one', () => {
  const f = fixture();
  try {
    const priorState = JSON.stringify({ attempts: 2, web_advisor_provider_job_id: 'advisor-90042-9', web_advisor_provider_job_started_at: Math.floor(Date.now() / 1000) - 2401 });
    const r = runDispatch(f, { priorState, POLL_STATUS: '2' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(envFaultText(f), /web-advisor-provider/);
    const state = JSON.parse(text(f, 'agent/state/90042.json'));
    assert.equal(state.web_advisor_provider_job_id, undefined, 'a dead session is cleared so the next tick dispatches fresh');
    assert.equal(state.attempts, 2, 'an environment fault is never charged to the ticket');
  } finally { f.close(); }
});

test('a finished job whose call itself failed is an environment fault, not a charged attempt', () => {
  const f = fixture();
  try {
    const priorState = JSON.stringify({ attempts: 2, web_advisor_provider_job_id: 'advisor-90042-1' });
    const r = runDispatch(f, { priorState, POLL_STATUS: '0', POLL_OUTPUT: '{"subtype":"web_advisor_provider_call_failed","result":"CDP crashed mid-turn"}' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(envFaultText(f), /CDP crashed mid-turn/);
    const state = JSON.parse(text(f, 'agent/state/90042.json'));
    assert.equal(state.web_advisor_provider_job_id, undefined);
    assert.equal(state.attempts, 2);
    assert.equal(existsSync(join(f.root, 'PAUSE')), false);
  } finally { f.close(); }
});

test('a finished job with a malformed answer charges an attempt via the shared admission path', () => {
  const f = fixture();
  try {
    const priorState = JSON.stringify({ attempts: 2, web_advisor_provider_job_id: 'advisor-90042-1' });
    const r = runDispatch(f, { priorState, POLL_STATUS: '0', POLL_OUTPUT: '0' });
    assert.equal(r.status, 1, r.stderr);
    assert.doesNotMatch(r.stdout, /RESULT=/);
    const state = JSON.parse(text(f, 'agent/state/90042.json'));
    assert.equal(state.web_advisor_provider_job_id, undefined);
    assert.equal(state.attempts, 3, 'GPT-6 answered, just not usably -- a real failure, unlike an unreachable CDP session');
    assert.equal(existsSync(join(f.root, 'PAUSE')), false, 'the job itself completed; nothing here is a backoff-worthy exit status');
  } finally { f.close(); }
});

test('a finished job with a valid answer produces RESULT without charging an attempt', () => {
  const f = fixture();
  try {
    const priorState = JSON.stringify({ attempts: 2, web_advisor_provider_job_id: 'advisor-90042-1' });
    const r = runDispatch(f, { priorState, POLL_STATUS: '0', POLL_OUTPUT: '{"is_error":false,"structured_output":{"verdict":"advised"}}' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /RESULT=\{"verdict":"advised"\} DEGRADED=0/);
    const state = JSON.parse(text(f, 'agent/state/90042.json'));
    assert.equal(state.web_advisor_provider_job_id, undefined);
    assert.equal(state.attempts, 2);
  } finally { f.close(); }
});

test('resuming an existing pending verdict skips dispatch entirely and reuses the cached result', () => {
  const f = fixture();
  try {
    const issueJson = '{"title":"t","body":"b","comments":[]}';
    const priorState = JSON.stringify({
      attempts: 2,
      pending_advisor_verdict: {
        result: { verdict: 'advised' },
        input: { title: 't', body: 'b', comments: [] },
        computed_at: 'an earlier tick',
        episode_seq: 0,
        effects: {},
      },
    });
    const r = runDispatch(f, { issueJson, priorState });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /RESULT=\{"verdict":"advised"\} DEGRADED=0/);
    assert.equal(text(f, 'calls'), '', 'a resumed verdict must never touch usable()/poll()/dispatch_async()');
    assert.equal(JSON.parse(text(f, 'agent/state/90042.json')).attempts, 2);
  } finally { f.close(); }
});

test('no existing job dispatches a fresh one and exits, leaving the ticket to poll next tick', () => {
  const f = fixture();
  try {
    const r = runDispatch(f, { priorState: '{"attempts":2}' });
    assert.equal(r.status, 0, r.stderr);
    assert.doesNotMatch(r.stdout, /RESULT=/, 'a fresh dispatch never resolves a verdict on the same tick');
    assert.match(text(f, 'calls'), /^dispatch:advisor-90042-\d+$/m);
    const state = JSON.parse(text(f, 'agent/state/90042.json'));
    assert.match(state.web_advisor_provider_job_id, /^advisor-90042-\d+$/);
    assert.equal(typeof state.web_advisor_provider_job_started_at, 'number');
    assert.equal(state.web_advisor_provider_job_episode_seq, 0);
    assert.equal(state.attempts, 2);
  } finally { f.close(); }
});

test('the legacy triage/recut failure outlet cannot bypass shared admission', () => {
  const f = fixture();
  try {
    writeFileSync(join(f.root, 'agent/state/90042.json'), '{"attempts":4,"advisor_ruled_at":"prior"}');
    const r = run(f, `
guarded_write() { echo forbidden >> "$HOME/actions"; }
record_run_decision() { :; }
conclude_run() { echo reached > "$HOME/conclusion-reached"; }
give_up_on_issue 90042 "fixture failure"
`);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(text(f, 'conclusion-reached').trim(), 'reached');
    assert.equal(text(f, 'actions'), '');
    assert.equal(JSON.parse(text(f, 'agent/state/90042.json')).advisor_ruled_at, 'prior');
  } finally { f.close(); }
});
