import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, existsSync, symlinkSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { applyOverrides, execute, hiddenChecks, renderPrompt, worktree } from './run-eval.mjs';
const scratch = resolve('.scratch'); mkdirSync(scratch, { recursive: true });
test('hidden grader applies the patch to base and replaces worker-forged tests', () => {
  const dir = mkdtempSync(join(scratch, 'eval-test-'));
  const fixture = join(dir, 'fixture'); mkdirSync(fixture);
  const git = (...args) => execFileSync('git', args, { cwd: fixture, encoding: 'utf8' }).trim();
  try {
    git('init', '-q'); git('config', 'user.name', 'Eval fixture'); git('config', 'user.email', 'eval@example.invalid');
    writeFileSync(join(fixture, 'value.mjs'), 'export default 0;\n');
    git('add', '.'); git('commit', '-qm', 'broken base'); const baseSha = git('rev-parse', 'HEAD');
    writeFileSync(join(fixture, 'value.mjs'), 'export default 1;\n');
    writeFileSync(join(fixture, 'check.mjs'), "import value from './value.mjs'; if (value !== 1) process.exit(1);\n");
    git('add', '.'); git('commit', '-qm', 'known fix with regression'); const fix = git('rev-parse', 'HEAD');
    const c = { baseSha, hidden: { ref: fix, files: ['check.mjs'], commands: [['node', 'check.mjs']] } };
    const goldDiff = git('diff', '--binary', baseSha, fix) + '\n';
    const run = (name, diff, input = c) => { const out = join(dir, name); mkdirSync(out); return hiddenChecks(input, diff, out, fixture); };
    assert.equal(run('base', '').pass, false);
    assert.equal(run('fixed', goldDiff).pass, true);
    const forged = goldDiff.replace('export default 1;', 'export default 0;').replace("+import value from './value.mjs'; if (value !== 1) process.exit(1);", '+process.exit(0);');
    assert.equal(run('forged', forged).pass, false);
    assert.equal(run('setup-only', goldDiff, { ...c, hidden: { ...c.hidden, setup: [['node', '-e', 'process.exit(0)']], commands: [] } }).pass, false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test('stage prompts reuse the pipeline contracts and keep answers out of model input', () => {
  const c = { baseSha: 'a'.repeat(40), issue: { number: 1, title: 'sample', body: 'acceptance' }, expected: { secretGold: 'never show' }, repair: { failureText: 'CI defect evidence' } };
  for (const stage of ['triage', 'advisor', 'recut', 'implement']) {
    const text = renderPrompt(stage, c);
    const name = ({ implement: 'implement-contract', review: 'review-contract' })[stage] ?? stage;
    assert.ok(text.includes(readFileSync(resolve('engine/prompts', `${name}.md`), 'utf8')));
    assert.ok(!text.includes('never show'));
    assert.ok(text.includes('acceptance'));
  }
  assert.match(renderPrompt('implement', c), /Previous attempt failed\nCI defect evidence/);
});

test('eval stage prompt reads a target config override', () => {
  const dir = mkdtempSync(join(scratch, 'eval-prompt-config-'));
  try {
    const prompts = join(dir, 'prompts'); mkdirSync(prompts);
    writeFileSync(join(prompts, 'triage.md'), 'CONFIG_EVAL_TRIAGE_PROMPT_OVERRIDE\n');
    const evalUrl = new URL('./run-eval.mjs', import.meta.url).href;
    const code = `import { renderPrompt } from ${JSON.stringify(evalUrl)}; console.log(renderPrompt('triage', {baseSha:'a'.repeat(40), issue:{number:1,title:'sample',body:'acceptance'}}));`;
    const output = execFileSync(process.execPath, ['--input-type=module', '-e', code], {
      encoding: 'utf8', env: { ...process.env, ZF_CONFIG_ROOT: dir, ZF_PACK_DIR: '' },
    });
    assert.ok(output.includes('CONFIG_EVAL_TRIAGE_PROMPT_OVERRIDE'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('implement pickup prompts carry the scheduler-rendered prior decisions', () => {
  const decisionLog = [
    { stage: 'supervisor-escalated', result: 'resume the interrupted owner', at: '2026-10-13T18:40:00Z',
      decision: { decision: 'Resume the interrupted owner patch', why: 'Focused checks passed before the interruption',
        evidence: 'impl-3754 report', rejected: ['open a fresh unit'], owner: 'supervisor' } },
    { stage: 'advisor-ruling', result: 'advised', at: '2026-10-13T18:41:00Z',
      decision: { decision: 'FIX', why: 'One defect, no split', evidence: 'review-3754-T1.md', rejected: ['SPLIT', 'SCOPE'], owner: 'advisor' } },
  ];
  const c = { baseSha: 'a'.repeat(40), issue: { number: 1, title: 'sample', body: 'acceptance' }, decisionLog };
  const pickup = renderPrompt('implement', c);
  assert.match(pickup, /^Decided earlier \(do not reopen without new evidence\):\n- 2026-10-13T18:40:00Z \[supervisor\] Resume the interrupted owner patch\n  Why: Focused checks passed before the interruption\n  Evidence: impl-3754 report\n  Rejected: open a fresh unit\n- 2026-10-13T18:41:00Z \[advisor\] FIX\n  Why: One defect, no split\n  Evidence: review-3754-T1.md\n  Rejected: SPLIT, SCOPE\n/m);
  assert.ok(!renderPrompt('implement', { ...c, decisionLog: undefined }).includes('Decided earlier'));
});

test('the implement prompt carries the premise rule and the optimization cases keep their data frozen', { skip: 'needs the the product eval case corpus (eval/cases), not exported' }, () => {
  const set = JSON.parse(readFileSync(new URL('./cases/implement.json', import.meta.url), 'utf8'));
  const close = set.cases.find((c) => c.id === 'zf-4025');
  const holds = set.cases.find((c) => c.id === 'zf-3185');
  assert.ok(close && holds, 'the premise-verification cases must stay in the implement set');
  assert.equal(close.expected.outcome, 'close');
  assert.equal(holds.expected.outcome, 'implement');
  assert.ok(!close.hidden, 'a close-graded case has no hidden fix blob to run');
  assert.ok(holds.hidden && holds.hidden.ref === holds.source.fixSha);
  for (const c of [close, holds]) {
    const prompt = renderPrompt('implement', c);
    assert.match(prompt, /Verify an optimization premise before implementing/);
    assert.match(prompt, /measurement window starts after[\s\S]*last change to the mechanism/);
    assert.ok(prompt.includes(JSON.stringify(c.issue, null, 2).slice(0, 200)), 'the frozen intake issue reaches the implementer');
  }
  assert.ok(!renderPrompt('implement', close).includes(close.expected.gold.closeLine), 'the gold close line never reaches the model');
  // The close case's data supports its verdict: zero agent runs in every window after the mechanism.
  const table = close.issue.comments[0].body;
  assert.ok(table.includes('| 10-23 16:53–24:00Z | 0 | 0 | 0 |'));
  assert.ok(table.includes('| 10-27 (to 15:15Z) | 0 | 0 | 0 |'));
});

test('comparison CLI reads saved labels and puts a regression before unchanged totals', () => {
  const dir = mkdtempSync(join(scratch, 'eval-cli-test-'));
  try {
    const before = { label: 'before', results: [{ stage: 'triage', caseId: 'a', run: 1, pass: true }, { stage: 'triage', caseId: 'b', run: 1, pass: false }] };
    const after = { label: 'after', results: [{ stage: 'triage', caseId: 'a', run: 1, pass: false }, { stage: 'triage', caseId: 'b', run: 1, pass: true }] };
    for (const value of [before, after]) {
      const out = join(dir, '.zenoforge/eval', value.label); mkdirSync(out, { recursive: true });
      writeFileSync(join(out, 'results.json'), JSON.stringify(value));
    }
    const output = execFileSync('node', ['engine/eval/run-eval.mjs', '--compare', 'before', 'after'], { env: { ...process.env, HOME: dir, AGENT_HOME: join(dir, '.zenoforge') }, encoding: 'utf8' });
    assert.match(output, /^REGRESSION pass→fail triage\/a run 1\nbefore: 1\/2; after: 1\/2\nfail→pass triage\/b/);
    assert.match(output, /inconsistency before: 0/);
    const armOutput = execFileSync('node', ['engine/eval/run-eval.mjs', '--compare-arms', 'after'], { env: { ...process.env, HOME: dir, AGENT_HOME: join(dir, '.zenoforge') }, encoding: 'utf8' });
    assert.match(armOutput, /^after: chains with arms=0; complete pairs=0/);
    assert.match(armOutput, /tokens median=unknown sum=unknown/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the real lower stage seam uses policy and records usage without a model call', () => {
  const dir = mkdtempSync(join(scratch, 'eval-stage-test-'));
  try {
    const bin = join(dir, 'bin'), home = join(dir, 'home'), artifact = join(dir, 'artifacts');
    for (const path of [bin, home, artifact]) mkdirSync(path);
    const output = { category: 'bug', state: 'ready-for-agent', risk_class: 'P0', level: 'L0', entry_surface: 'API', acceptor: 'none', brief_md: 'fixture', notes_md: '', expected_packages: ['engine'], expected_paths: [], estimated_changed_lines: 40, external_deliverable: { required: false, location: '', reason: '' } };
    const outputFile = join(dir, 'fake-output.json'); writeFileSync(outputFile, JSON.stringify(output));
    const fake = join(bin, 'codex');
    writeFileSync(fake, '#!/usr/bin/env bash\nset -euo pipefail\noutput=""\nwhile (($#)); do if [[ "$1" == --output-last-message ]]; then output=$2; shift; fi; shift; done\ncat > /dev/null\ncp "$EVAL_FAKE_OUTPUT_FILE" "$output"\nprintf "tokens used\\n1,234\\n"\n', { mode: 0o755 });
    const input = join(dir, 'input.json'), prompt = join(dir, 'prompt.md');
    writeFileSync(input, JSON.stringify({ issue: { number: 1 }, priorState: {}, failure: '' })); writeFileSync(prompt, 'fixture');
    const raw = execFileSync('bash', ['engine/eval/stage-call.sh', 'triage', resolve('.'), resolve('.'), prompt, artifact, input], {
      encoding: 'utf8', env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}`, GH_TOKEN: '', GITHUB_TOKEN: '',
        EVAL_POLICY_FILE: resolve('engine/model-policy.default.json'), EVAL_FAKE_OUTPUT_FILE: outputFile,
        ZF_AGENT_TEST_MODE: '1', ZF_AGENT_TEST_ROOT: dir,
        AGENT_EXECUTION_MIN_MEM_MB: '1', AGENT_EXECUTION_MAX_LOAD: '1000000' },
    });
    assert.deepEqual(JSON.parse(raw).structured_output, output);
    assert.equal(JSON.parse(raw).tokens_used, '1234');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('case checkout sees only history reachable from its frozen base', () => {
  const dir = mkdtempSync(join(scratch, 'eval-iso-test-'));
  const fixture = join(dir, 'fixture'); mkdirSync(fixture);
  const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
  try {
    git(fixture, 'init', '-q', '-b', 'main'); git(fixture, 'config', 'user.name', 'Eval fixture'); git(fixture, 'config', 'user.email', 'eval@example.invalid');
    writeFileSync(join(fixture, 'value.mjs'), 'broken\n');
    git(fixture, 'add', '.'); git(fixture, 'commit', '-qm', 'base'); const base = git(fixture, 'rev-parse', 'HEAD');
    writeFileSync(join(fixture, 'value.mjs'), 'fixed\n');
    git(fixture, 'commit', '-qam', 'known fix'); const fix = git(fixture, 'rev-parse', 'HEAD');
    git(fixture, 'tag', 'fix-tag');
    const wt = worktree(base, join(dir, 'case'), 'worker', fixture);
    const w = (...args) => git(wt, ...args);
    assert.equal(w('log', '--all', '--format=%H'), base);
    assert.equal(w('for-each-ref', '--format=%(refname)'), 'refs/remotes/origin/main');
    assert.throws(() => w('show', 'main:value.mjs'), /unknown revision|invalid object name|fatal/);
    assert.equal(readFileSync(join(wt, 'value.mjs'), 'utf8'), 'broken\n');
    assert.notEqual(w('rev-parse', 'origin/main'), fix);
  } catch (e) { rmSync(dir, { recursive: true, force: true }); throw e; }
  rmSync(dir, { recursive: true, force: true });
});

test('role overrides rewrite a policy copy without mutating the source policy', () => {
  const policy = JSON.parse(readFileSync(resolve('engine/model-policy.default.json'), 'utf8'));
  const copy = applyOverrides(policy, ['review=zcode:GLM-5.3:max', 'work=codex:gpt-6-luna:high:fast']);
  assert.deepEqual([copy.roles.review.provider, copy.roles.review.model, copy.roles.review.effort, copy.roles.review.service_tier], ['zcode', 'GLM-5.3', 'max', undefined]);
  assert.deepEqual([copy.roles.work.effort, copy.roles.work.service_tier], ['high', 'fast']);
  assert.equal(policy.roles.review.provider, 'codex');
  assert.throws(() => applyOverrides(policy, ['nope=zcode:x']), /existing role/);
  assert.throws(() => applyOverrides(policy, ['review=zcode']), /existing role/);
});

test('review dispatches on the pipeline-resolved provider and records that identity', () => {
  const dir = mkdtempSync(join(scratch, 'eval-review-test-'));
  try {
    const bin = join(dir, 'bin'), home = join(dir, 'home'), artifact = join(dir, 'artifacts');
    for (const path of [bin, home, artifact, join(home, '.zcode/v2')]) mkdirSync(path, { recursive: true });
    writeFileSync(join(home, '.zcode/v2/provider_config.json'), JSON.stringify({ config: { defaultModelSelection: { modelId: 'GLM-5.3' } } }));
    writeFileSync(join(bin, 'zcode'), '#!/usr/bin/env bash\ncat > /dev/null || true\nprintf "READY\\nfixture review\\n"\n', { mode: 0o755 });
    writeFileSync(join(bin, 'codex'), '#!/usr/bin/env bash\necho codex must not run >&2\nexit 99\n', { mode: 0o755 });
    const policy = applyOverrides(JSON.parse(readFileSync(resolve('engine/model-policy.default.json'), 'utf8')), ['review=zcode:GLM-5.3:max']);
    const policyFile = join(dir, 'policy.json'); writeFileSync(policyFile, JSON.stringify(policy));
    const input = join(dir, 'input.json'), prompt = join(dir, 'prompt.md');
    writeFileSync(input, JSON.stringify({ issue: { number: 1 }, priorState: {}, failure: '' })); writeFileSync(prompt, 'fixture');
    const raw = execFileSync('bash', ['engine/eval/stage-call.sh', 'review', resolve('.'), resolve('.'), prompt, artifact, input], {
      encoding: 'utf8', env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}`, GH_TOKEN: '', GITHUB_TOKEN: '',
        EVAL_POLICY_FILE: policyFile, ZF_AGENT_TEST_MODE: '1', ZF_AGENT_TEST_ROOT: dir,
        AGENT_EXECUTION_MIN_MEM_MB: '1', AGENT_EXECUTION_MAX_LOAD: '1000000' },
    });
    assert.match(raw, /^READY/);
    assert.equal(readFileSync(join(artifact, 'identity.txt'), 'utf8').trim(), 'zcode:GLM-5.3:max');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('supervisor execution uses an isolated historical context and the six-action arbitration prompt', () => {
  const dir = mkdtempSync(join(scratch, 'eval-supervisor-test-'));
  try {
    const stageCall = join(dir, 'stage-call.sh');
    writeFileSync(stageCall, '#!/usr/bin/env bash\nprintf "ACTION: requeue\\n"\n', { mode: 0o755 });
    const c = { id: 'supervisor-fixture', issue: { number: 4367 }, priorState: {},
      input: { escalationReason: { at: '2026-10-20T00:00:00Z', reason: 'worker failed' }, unitHistory: [],
        reviewFindings: { available: false, reportAt: null, report: '' }, ciEvidence: [] },
      expected: { action: 'requeue', knownUnsafeApprove: false } };
    const outcome = execute(c, 'supervisor', join(dir, 'attempt'), resolve('engine/model-policy.default.json'), { stageCall });
    assert.equal(outcome.pass, true);
    assert.equal(outcome.action, 'requeue');
    assert.equal(outcome.expectedAction, 'requeue');
    assert.ok(outcome.calls[0]);
    const prompt = readFileSync(join(dir, 'attempt/1-supervisor/prompt.md'), 'utf8');
    const arbiterPrompt = readFileSync(resolve('engine/prompts/supervisor-arbiter.md'), 'utf8');
    assert.ok(prompt.includes(arbiterPrompt), 'supervisor prompt must ship the six-action arbitration prompt verbatim');
    assert.ok(prompt.includes(JSON.stringify(c.input, null, 2)));
    assert.equal(existsSync(join(dir, 'attempt/historical-context')), false);

    const failingStageCall = join(dir, 'failing-stage-call.sh');
    writeFileSync(failingStageCall, '#!/usr/bin/env bash\necho provider failure >&2\nexit 2\n', { mode: 0o755 });
    const failed = execute(c, 'supervisor', join(dir, 'failed-attempt'), resolve('engine/model-policy.default.json'), { stageCall: failingStageCall });
    assert.equal(failed.pass, false);
    assert.equal(failed.action, null);
    assert.equal(failed.expectedAction, 'requeue');
    assert.equal(failed.calls.length, 1, 'failed model calls remain represented in the result denominator');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('repair arm arguments are opt-in and compare-arms takes a label', async () => {
  const { parseEvalArgs } = await import('./run-eval.mjs');
  assert.equal(parseEvalArgs(['--label', 'plain']).values['repair-arms'], undefined);
  assert.equal(parseEvalArgs(['--stage', 'end-to-end', '--repair-arms', 'paired', '--label', 'paired']).values['repair-arms'], 'paired');
  assert.equal(parseEvalArgs(['--compare-arms', 'paired']).values['compare-arms'], 'paired');
  assert.throws(() => parseEvalArgs(['--repair-arms', 'cold']), /--repair-arms must be paired/);
  assert.throws(() => parseEvalArgs(['--repair-arms', '']), /--repair-arms must be paired/);
  assert.throws(() => parseEvalArgs(['--repair-arms']), /argument/);
});

test('case selection and resume flags parse; --case and --cases are one option', async () => {
  const { parseEvalArgs } = await import('./run-eval.mjs');
  assert.equal(parseEvalArgs(['--case', 'zf-4186,zf-4026']).values.case, 'zf-4186,zf-4026');
  assert.equal(parseEvalArgs(['--cases', 'set.json']).values.cases, 'set.json');
  assert.equal(parseEvalArgs(['--label', 'x']).values.concurrency, '1');
  assert.equal(parseEvalArgs(['--concurrency', '4', '--label', 'x']).values.concurrency, '4');
  assert.equal(parseEvalArgs(['--resume', '--label', 'x']).values.resume, true);
  assert.throws(() => parseEvalArgs(['--case', 'a', '--cases', 'b']), /same option/);
});

test('eval case sets and their expected labels prefer target configuration over the retained pack', () => {
  const dir = mkdtempSync(join(scratch, 'eval-config-test-'));
  const configRoot = join(dir, '.zenoforge');
  const packDir = join(dir, 'pack');
  const configCase = (id, label) => ({ stage: 'triage', cases: [{ id, expected: { label } }] });
  const writeJson = (path, value) => {
    mkdirSync(path.slice(0, path.lastIndexOf('/')), { recursive: true });
    writeFileSync(path, JSON.stringify(value));
  };
  try {
    writeJson(join(configRoot, 'eval/config.json'), { case_dir: 'eval/custom-cases' });
    writeJson(join(configRoot, 'eval/custom-cases/triage.json'), configCase('target-case', 'target-label'));
    writeJson(join(packDir, 'eval/config.json'), { case_dir: 'eval/custom-cases' });
    writeJson(join(packDir, 'eval/custom-cases/triage.json'), configCase('pack-case', 'pack-label'));
    const script = "import { loadEvalCaseSet } from './engine/eval/run-eval.mjs'; console.log(JSON.stringify(loadEvalCaseSet('triage')));";
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      cwd: resolve('.'), encoding: 'utf8',
      env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: packDir },
    });
    assert.equal(child.status, 0, child.stderr);
    const loaded = JSON.parse(child.stdout);
    assert.equal(loaded.cases[0].id, 'target-case');
    assert.equal(loaded.cases[0].expected.label, 'target-label');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('eval output schemas prefer the target schema over the retained pack', () => {
  const dir = mkdtempSync(join(scratch, 'eval-schema-config-test-'));
  const configRoot = join(dir, '.zenoforge');
  const packDir = join(dir, 'pack');
  const schema = (field) => ({ type: 'object', required: [field], properties: { [field]: { type: 'string' } } });
  const writeJson = (path, value) => {
    mkdirSync(path.slice(0, path.lastIndexOf('/')), { recursive: true });
    writeFileSync(path, JSON.stringify(value));
  };
  try {
    writeJson(join(configRoot, 'prompts/triage.schema.json'), schema('targetOnly'));
    writeJson(join(packDir, 'prompts/triage.schema.json'), schema('packOnly'));
    const script = "import { validateStageOutput } from './engine/eval/graders.mjs'; console.log(JSON.stringify(validateStageOutput('triage', { targetOnly: 'ok' })));";
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      cwd: resolve('.'), encoding: 'utf8',
      env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: packDir },
    });
    assert.equal(child.status, 0, child.stderr);
    assert.deepEqual(JSON.parse(child.stdout), []);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('engine eval defaults to invented public cases when no target config or pack exists', () => {
  const dir = mkdtempSync(join(scratch, 'eval-default-cases-test-'));
  const configRoot = join(dir, '.zenoforge'); mkdirSync(configRoot, { recursive: true });
  try {
    const script = "import { loadEvalCaseSet } from './engine/eval/run-eval.mjs'; console.log(JSON.stringify(loadEvalCaseSet('triage')));";
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      cwd: resolve('.'), encoding: 'utf8',
      env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: '' },
    });
    assert.equal(child.status, 0, child.stderr);
    const loaded = JSON.parse(child.stdout);
    assert.equal(loaded.cases.length, 3);
    assert.ok(loaded.cases.every((item) => item.issue?.title && item.issue?.body));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('runPool caps in-flight jobs at the requested concurrency and runs every job', async () => {
  const { runPool } = await import('./run-eval.mjs');
  let active = 0, max = 0;
  const seen = [];
  await runPool([0, 1, 2, 3, 4, 5, 6, 7], 3, async (job) => {
    active++; max = Math.max(max, active); seen.push(job);
    await new Promise((done) => setTimeout(done, 5));
    active--;
  });
  assert.equal(seen.length, 8);
  assert.ok(max <= 3, `overlap ${max} exceeded the cap`);
  assert.ok(max > 1, 'jobs never overlapped');
});

// A stub codex plus a tiny-tree base keep the CLI tests hermetic: no model, no network.
function cliFixture() {
  const dir = mkdtempSync(join(scratch, 'eval-cli-'));
  const bin = join(dir, 'bin'), home = join(dir, 'home');
  mkdirSync(bin); mkdirSync(home);
  const events = join(dir, 'codex-events.log');
  const output = { category: 'bug', state: 'ready-for-agent', risk_class: 'P0', level: 'L0', entry_surface: 'API', acceptor: 'none', brief_md: 'fixture', notes_md: '', expected_packages: ['engine'], expected_paths: [], estimated_changed_lines: 40, external_deliverable: { required: false, location: '', reason: '' } };
  const outputFile = join(dir, 'triage-output.json');
  writeFileSync(outputFile, JSON.stringify(output));
  writeFileSync(join(bin, 'codex'), `#!/usr/bin/env bash
set -euo pipefail
output=""
while (( $# )); do if [[ "$1" == --output-last-message ]]; then output=$2; fi; shift; done
cat > /dev/null
printf 'S\n' >> ${JSON.stringify(events)}
sleep 1
printf 'E\n' >> ${JSON.stringify(events)}
cp ${JSON.stringify(outputFile)} "$output"
printf 'tokens used\n1,234\n'
`, { mode: 0o755 });
  // The repo's first commit gives fixture cases a real object with a tiny checkout.
  const baseSha = execFileSync('git', ['rev-list', '--max-parents=0', 'HEAD'], { encoding: 'utf8' }).trim().split('\n').at(-1);
  const caseFile = join(dir, 'cases.json');
  writeFileSync(caseFile, JSON.stringify({ stage: 'triage', cases: ['c1', 'c2', 'c3'].map((id) => ({ id, baseSha, issue: { number: 1, title: id, body: 'fixture' }, expected: output })) }));
  const env = { ...process.env, HOME: home, AGENT_HOME: join(home, '.zenoforge'), PATH: `${bin}:${process.env.PATH}`, GH_TOKEN: '', GITHUB_TOKEN: '',
    ZF_AGENT_TEST_MODE: '1', ZF_AGENT_TEST_ROOT: dir, AGENT_EXECUTION_MIN_MEM_MB: '1', AGENT_EXECUTION_MAX_LOAD: '1000000' };
  const run = (args, envOverrides = {}) => spawnSync('node', ['engine/eval/run-eval.mjs', ...args], {
    encoding: 'utf8', env: { ...env, ...envOverrides },
  });
  return { dir, home, events, caseFile, output, run };
}
const overlap = (events) => {
  let active = 0, max = 0;
  for (const line of readFileSync(events, 'utf8').split('\n').filter(Boolean)) { active += line === 'S' ? 1 : -1; max = Math.max(max, active); }
  return max;
};
function pathWithoutBackendCli(dir) {
  const bin = join(dir, 'minimal-bin'); mkdirSync(bin);
  symlinkSync(process.execPath, join(bin, 'node'));
  const gitPath = execFileSync('bash', ['-lc', 'command -v git'], { encoding: 'utf8' }).trim();
  symlinkSync(gitPath, join(bin, 'git'));
  return bin;
}

test('eval default model policy uses the target .zenoforge override', () => {
  const f = cliFixture();
  try {
    const configRoot = join(f.dir, 'target', '.zenoforge'); mkdirSync(configRoot, { recursive: true });
    const policy = JSON.parse(readFileSync(resolve('engine/model-policy.default.json'), 'utf8'));
    policy.switches['roadmap-order'] = !policy.switches['roadmap-order'];
    writeFileSync(join(configRoot, 'model-policy.default.json'), JSON.stringify(policy));
    const r = f.run(['--stage', 'triage', '--cases', f.caseFile, '--runs', '1', '--label', 'config-policy'], {
      ZF_CONFIG_ROOT: configRoot,
    });
    assert.equal(r.status, 0, r.stderr);
    const results = JSON.parse(readFileSync(join(f.home, '.zenoforge/eval/config-policy/results.json'), 'utf8'));
    assert.equal(results.policy.switches['roadmap-order'], policy.switches['roadmap-order']);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test('--concurrency 3 keeps at most 3 attempts running and records every row', () => {
  const f = cliFixture();
  try {
    const r = f.run(['--stage', 'triage', '--cases', f.caseFile, '--runs', '1', '--concurrency', '3', '--label', 'conc']);
    assert.equal(r.status, 0, r.stderr);
    const rows = JSON.parse(readFileSync(join(f.home, '.zenoforge/eval/conc/results.json'), 'utf8')).results;
    assert.deepEqual(rows.map((x) => x.caseId).sort(), ['c1', 'c2', 'c3']);
    assert.ok(rows.every((x) => x.pass), rows.map((x) => x.failures).join(';'));
    assert.ok(rows.every((x) => x.tokens === 1234 && x.identities.length === 1));
    assert.ok(overlap(f.events) <= 3, 'more than 3 codex calls overlapped');
    assert.ok(overlap(f.events) >= 2, 'attempts never ran in parallel');
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test('--case runs only the named cases of the real corpus and unknown ids fail the run', { skip: 'needs the the product eval case corpus (eval/cases), not exported' }, () => {
  const f = cliFixture();
  try {
    const r = f.run(['--stage', 'triage', '--case', 'zf-4186', '--runs', '1', '--label', 'one']);
    assert.equal(r.status, 0, r.stderr);
    const rows = JSON.parse(readFileSync(join(f.home, '.zenoforge/eval/one/results.json'), 'utf8')).results;
    assert.deepEqual(rows.map((x) => `${x.stage}/${x.caseId}`), ['triage/zf-4186']); // stub output: graded, not passed
    assert.equal(readFileSync(f.events, 'utf8').split('\n').filter((l) => l === 'S').length, 1);
    const bad = f.run(['--stage', 'triage', '--case', 'zf-4186,nope', '--runs', '1', '--label', 'bad']);
    assert.notEqual(bad.status, 0);
    assert.match(bad.stderr, /unknown case id: nope/);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test('missing selected backend CLI fails before any case starts', () => {
  const f = cliFixture();
  try {
    const minimalBin = pathWithoutBackendCli(f.dir);
    for (const provider of ['codex', 'zcode']) {
      const policy = JSON.parse(readFileSync(resolve('engine/model-policy.default.json'), 'utf8'));
      policy.roles.work.provider = provider;
      const policyFile = join(f.dir, `policy-${provider}.json`);
      writeFileSync(policyFile, JSON.stringify(policy));
      const label = `missing-${provider}`;
      const r = f.run(['--stage', 'triage', '--cases', f.caseFile, '--runs', '1', '--label', label, '--policy', policyFile], {
        PATH: minimalBin,
      });
      assert.notEqual(r.status, 0);
      assert.match(r.stderr, new RegExp(`host with the selected CLI installed \\(WSL\\); missing: ${provider}`));
      assert.equal(existsSync(join(f.home, '.zenoforge/eval', label)), false, 'failed startup created a result label');
    }
    assert.equal(existsSync(f.events), false, 'a case reached the fake backend');
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test('completed resume and model-free gold verification do not require a backend CLI', { skip: 'needs the the product eval case corpus (eval/cases), not exported' }, () => {
  const f = cliFixture();
  try {
    const minimalBin = pathWithoutBackendCli(f.dir);
    const resumeDir = join(f.home, '.zenoforge/eval/completed'); mkdirSync(resumeDir, { recursive: true });
    const results = ['c1', 'c2', 'c3'].map((caseId) => ({ stage: 'triage', caseId, run: 1, pass: true, failures: [], calls: [],
      artifacts: 'kept', tokens: 1, wallSeconds: 1, modelWallSeconds: 1, identities: [] }));
    writeFileSync(join(resumeDir, 'results.json'), JSON.stringify({ label: 'completed', results }));
    const resumed = f.run(['--stage', 'triage', '--cases', f.caseFile, '--runs', '1', '--resume', '--label', 'completed'], {
      PATH: minimalBin,
    });
    assert.equal(resumed.status, 0, resumed.stderr);
    assert.match(resumed.stdout, /0 missing to run/);

    const gold = f.run(['--stage', 'implement', '--case', 'zf-4025', '--runs', '1', '--verify-gold', '--label', 'gold'], {
      PATH: minimalBin,
    });
    assert.equal(gold.status, 0, gold.stderr);
    const goldRows = JSON.parse(readFileSync(join(f.home, '.zenoforge/eval/gold/results.json'), 'utf8')).results;
    assert.equal(goldRows.length, 1);
    assert.equal(goldRows[0].pass, true, goldRows[0].failures.join('; '));
    assert.equal(existsSync(f.events), false, 'a model-backed case ran without a backend CLI');
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test('--resume keeps finished results untouched and only runs the missing case/runs', () => {
  const f = cliFixture();
  try {
    const outDir = join(f.home, '.zenoforge/eval/rl');
    mkdirSync(outDir, { recursive: true });
    const row = (caseId, run) => ({ stage: 'triage', caseId, run, pass: true, failures: [], calls: [], artifacts: 'kept',
      tokens: 1, wallSeconds: 1, modelWallSeconds: 1, identities: [] });
    const prior = { version: 1, label: 'rl', suiteSha: 'f'.repeat(40), policy: {}, overrides: [], kind: 'evaluation',
      startedAt: '2026-10-28T00:00:00.000Z', results: [row('c1', 1), row('c1', 2), row('c2', 1)] };
    writeFileSync(join(outDir, 'results.json'), JSON.stringify(prior, null, 2) + '\n');
    const r = f.run(['--stage', 'triage', '--cases', f.caseFile, '--runs', '2', '--resume', '--label', 'rl']);
    assert.equal(r.status, 0, r.stderr);
    const after = JSON.parse(readFileSync(join(outDir, 'results.json'), 'utf8'));
    assert.deepEqual(new Set(after.results.map((x) => `${x.stage}/${x.caseId}/${x.run}`)),
      new Set(['triage/c1/1', 'triage/c1/2', 'triage/c2/1', 'triage/c2/2', 'triage/c3/1', 'triage/c3/2']));
    for (const [i, kept] of prior.results.entries()) assert.deepEqual(after.results[i], kept);
    assert.equal(after.startedAt, prior.startedAt);
    assert.equal(after.suiteSha, prior.suiteSha);
    assert.equal(readFileSync(f.events, 'utf8').split('\n').filter((l) => l === 'S').length, 3);
    const again = f.run(['--stage', 'triage', '--cases', f.caseFile, '--runs', '2', '--label', 'rl']);
    assert.notEqual(again.status, 0);
    assert.match(again.stderr, /already exists/);
    const missing = f.run(['--stage', 'triage', '--cases', f.caseFile, '--resume', '--label', 'never-started']);
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /--resume needs an existing label/);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test('--concurrency must be a positive integer and fails before creating a label', () => {
  const f = cliFixture();
  try {
    for (const value of ['0', '-1', 'x']) {
      const r = f.run(['--stage', 'triage', `--concurrency=${value}`, '--label', 'v']);
      assert.notEqual(r.status, 0, value);
      assert.match(r.stderr, /--concurrency must be a positive integer/);
    }
    assert.ok(!existsSync(join(f.home, '.zenoforge/eval/v')));
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

function pairedFixture({ identity = 'codex:fixture:high', session = 'fixture-session', coldValue = 1, resumeValue = 2, repairArms = 'paired', failCold = false, reviewReady = false, deferReview = false } = {}) {
  const dir = mkdtempSync(join(scratch, 'eval-paired-'));
  const fixture = join(dir, 'fixture'); mkdirSync(fixture);
  const git = (...args) => execFileSync('git', args, { cwd: fixture, encoding: 'utf8' }).trim();
  git('init', '-q'); git('config', 'user.name', 'Eval fixture'); git('config', 'user.email', 'eval@example.invalid');
  writeFileSync(join(fixture, 'value.mjs'), 'export default 0;\n');
  writeFileSync(join(fixture, 'removed.txt'), 'remove me');
  writeFileSync(join(fixture, 'binary.bin'), Buffer.from([0, 1, 2]));
  writeFileSync(join(fixture, 'check.mjs'), "import value from './value.mjs'; import { readFileSync, existsSync } from 'node:fs'; if (value !== 1 || readFileSync('new.txt', 'utf8') !== 'untracked' || existsSync('removed.txt') || readFileSync('binary.bin')[1] !== 9 || readFileSync('staged.txt', 'utf8') !== 'staged') process.exit(1);\n");
  git('add', '.'); git('commit', '-qm', 'base'); const baseSha = git('rev-parse', 'HEAD');
  const stub = join(dir, 'stage-call.sh'), script = join(dir, 'stage-call.mjs');
  writeFileSync(stub, '#!/usr/bin/env bash\nexec node "$(dirname "$0")/stage-call.mjs" "$@"\n');
  const triage = { category: 'bug', state: 'ready-for-agent', risk_class: 'P0', level: 'L0', entry_surface: 'API', acceptor: 'none', brief_md: 'fixture', notes_md: '', expected_packages: ['engine'], expected_paths: [], estimated_changed_lines: 40, external_deliverable: { required: false, location: '', reason: '' } };
  const readyReview = 'VERDICT: READY\n\n```review-findings\n{"findings":[],"dispositions":[]}\n```';
  const rejectedReview = 'VERDICT: NOT_READY\n\n```review-findings\n{"findings":[{"id":"F1","severity":"P1","file":"value.mjs","line":1,"rule":"Defect","status":"open","summary":"The known value defect remains.","introduced_by":"candidate","base_evidence":"The base value at value.mjs:1 is zero.","rerun_command":"node value.test.mjs","rerun_output":"FAIL value is 1"}],"dispositions":[]}\n```';
  writeFileSync(script, `
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import assert from 'node:assert/strict';
const [stage, repo, wt, prompt, artifact, inputFile] = process.argv.slice(2);
const input = JSON.parse(readFileSync(inputFile));
writeFileSync(join(artifact, 'identity.txt'), ${JSON.stringify(identity)});
// Implementer 7; a resumed thread reports its cumulative counter (7 + repair 5), a cold repair only its own 5.
writeFileSync(join(artifact, 'usage.json'), JSON.stringify({ tokens: stage !== 'implement' || !input.failure ? 7 : input.sessionId ? 12 : 5 }));
if (stage === 'triage') console.log(JSON.stringify({ structured_output: ${JSON.stringify(triage)} }));
if (stage === 'review' && ${deferReview} && !existsSync(join(artifact, 'deferred'))) { writeFileSync(join(artifact, 'deferred'), ''); process.exit(75); }
if (stage === 'review') {
  const rejected = !${reviewReady} && readFileSync(prompt, 'utf8').includes('report: implemented');
  console.log(rejected ? ${JSON.stringify(rejectedReview)} : ${JSON.stringify(readyReview)});
}
if (stage === 'implement') {
  if (!input.failure) {
    assert.equal(input.recordSession, true);
    writeFileSync(join(wt, 'value.mjs'), 'export default 9;\\n');
    execFileSync('git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qam', 'implement commit'], { cwd: wt });
    writeFileSync(join(wt, 'staged.txt'), 'staged');
    execFileSync('git', ['add', 'staged.txt'], { cwd: wt });
    writeFileSync(join(wt, 'new.txt'), 'untracked');
    writeFileSync(join(wt, 'binary.bin'), Buffer.from([0, 9, 2]));
    unlinkSync(join(wt, 'removed.txt'));
    writeFileSync(join(artifact, 'worker.log'), JSON.stringify({ type: 'thread.started', thread_id: ${JSON.stringify(session)} }) + '\\n');
    console.log('report: implemented');
  } else {
    assert.equal(readFileSync(join(wt, 'value.mjs'), 'utf8'), 'export default 9;\\n');
    assert.equal(readFileSync(join(wt, 'new.txt'), 'utf8'), 'untracked');
    assert.equal(readFileSync(join(wt, 'staged.txt'), 'utf8'), 'staged');
    assert.equal(readFileSync(join(wt, 'binary.bin'))[1], 9);
    if (input.sessionId) assert.equal(input.sessionId, ${JSON.stringify(session)});
    if (${failCold} && !input.sessionId) process.exit(23);
    writeFileSync(join(wt, 'value.mjs'), 'export default ' + (input.sessionId ? ${resumeValue} : ${coldValue}) + ';\\n');
    console.log('report: repaired');
  }
}
`);
  const c = { id: 'fixture', baseSha, issue: { number: 1, title: 'fixture', body: 'fix value' }, priorState: {}, hidden: { ref: baseSha, files: ['check.mjs'], commands: [['node', 'check.mjs']] } };
  const out = join(dir, 'out'); mkdirSync(out);
  return { dir, out, c, options: { repairArms, sourceRepo: fixture, stageCall: stub } };
}

test('paired repair starts both arms at the implement snapshot and keeps the chain on cold', { skip: 'the review stage reads .agents/skills/zf-code-review/SKILL.md, a the product skill, not exported' }, async () => {
  const { execute } = await import('./run-eval.mjs');
  for (const [coldValue, resumeValue] of [[1, 2], [2, 1]]) {
    const f = pairedFixture({ coldValue, resumeValue });
    try {
      const row = execute(f.c, 'end-to-end', f.out, 'unused-policy', f.options);
      assert.equal(row.pass, coldValue === 1);
      assert.deepEqual(Object.keys(row.repair_arms).sort(), ['cold', 'resume']);
      for (const arm of ['cold', 'resume']) {
        const value = row.repair_arms[arm];
        assert.equal(value.pass, (arm === 'cold' ? coldValue : resumeValue) === 1);
        assert.equal(value.tokens, 5); // the resume arm excludes the implementer's cumulative share
        assert.equal(value.identity, 'codex:fixture:high');
        assert.ok(value.wall_ms > 0);
        assert.equal(value.reasons.length, value.pass ? 0 : 1);
      }
      assert.equal(row.calls[1].session_id, 'fixture-session');
      assert.equal(row.calls.length, 5); // triage, implement, review, cold repair, re-review
      assert.equal(readFileSync(join(f.out, 'repair-cold/call/prompt.md'), 'utf8'), readFileSync(join(f.out, 'repair-resume/call/prompt.md'), 'utf8'));
      assert.match(readFileSync(join(f.out, 'candidate.patch'), 'utf8'), /new.txt/);
    } finally { rmSync(f.dir, { recursive: true, force: true }); }
  }
});

test('--from-implement starts the chain at implement with no triage or advisor call', { skip: 'the review stage reads .agents/skills/zf-code-review/SKILL.md, a the product skill, not exported' }, async () => {
  const { execute, parseEvalArgs } = await import('./run-eval.mjs');
  assert.equal(parseEvalArgs(['--stage', 'end-to-end', '--from-implement', '--label', 'x']).values['from-implement'], true);
  assert.throws(() => parseEvalArgs(['--stage', 'implement', '--from-implement']), /--from-implement needs --stage end-to-end/);
  const f = pairedFixture({ coldValue: 1, resumeValue: 1 });
  try {
    const row = execute(f.c, 'end-to-end', f.out, 'unused-policy', { ...f.options, fromImplement: true });
    assert.equal(row.calls.length, 4); // implement, review, cold repair, re-review
    assert.equal(row.calls[0].session_id, 'fixture-session');
    assert.deepEqual(Object.keys(row.repair_arms).sort(), ['cold', 'resume']);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test('resume is skipped without a session or provider support and never calls cold as fallback', { skip: 'the review stage reads .agents/skills/zf-code-review/SKILL.md, a the product skill, not exported' }, async () => {
  const { execute } = await import('./run-eval.mjs');
  for (const config of [{ session: null }, { identity: 'zcode:fixture:high' }]) {
    const f = pairedFixture(config);
    try {
      const row = execute(f.c, 'end-to-end', f.out, 'unused-policy', f.options);
      assert.equal(row.pass, true);
      assert.equal(row.calls[1].session_id, null);
      assert.equal(row.repair_arms.resume.status, 'skipped');
      assert.equal(row.repair_arms.resume.pass, null);
      assert.equal(row.repair_arms.resume.tokens, null);
      assert.equal(row.repair_arms.resume.wall_ms, null);
      assert.match(row.repair_arms.resume.reasons[0], config.session === null ? /no implementer session/ : /does not support resume/);
      assert.equal(row.calls.length, 5);
    } finally { rmSync(f.dir, { recursive: true, force: true }); }
  }
});

test('a cold repair execution failure still records the resume result', { skip: 'the review stage reads .agents/skills/zf-code-review/SKILL.md, a the product skill, not exported' }, async () => {
  const { execute } = await import('./run-eval.mjs');
  const f = pairedFixture({ failCold: true, resumeValue: 1 });
  try {
    const row = execute(f.c, 'end-to-end', f.out, 'unused-policy', f.options);
    assert.equal(row.pass, false);
    assert.equal(row.repair_arms.cold.pass, false);
    assert.match(row.repair_arms.cold.reasons[0], /stage implement failed \(23\)/);
    assert.equal(row.repair_arms.resume.pass, true);
    assert.equal(row.calls.length, 4); // A failed cold call still stops the chain before re-review.
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test('unpaired runs retain one cold repair and accepted reviews do not create arms', { skip: 'the review stage reads .agents/skills/zf-code-review/SKILL.md, a the product skill, not exported' }, async () => {
  const { execute } = await import('./run-eval.mjs');
  for (const config of [{ repairArms: null }, { reviewReady: true }]) {
    const f = pairedFixture(config);
    try {
      const row = execute(f.c, 'end-to-end', f.out, 'unused-policy', f.options);
      assert.equal(row.repair_arms, undefined);
      assert.equal(row.calls.length, config.reviewReady ? 3 : 5);
      assert.equal(row.pass, !config.reviewReady);
    } finally { rmSync(f.dir, { recursive: true, force: true }); }
  }
});

test('a deferred stage (exit 75) is rerun instead of failing the chain', { skip: 'the review stage reads .agents/skills/zf-code-review/SKILL.md, a the product skill, not exported' }, async () => {
  const { execute } = await import('./run-eval.mjs');
  const f = pairedFixture({ deferReview: true, reviewReady: true });
  process.env.EVAL_DEFER_WAIT_MS = '0';
  try {
    const row = execute(f.c, 'end-to-end', f.out, 'unused-policy', f.options);
    assert.equal(row.pass, false); // fixture value stays 9: the review accepted it, the hidden check rejects it
    assert.deepEqual(row.calls.map((call) => `${call.stage}:${call.exitCode}`), ['triage:0', 'implement:0', 'review:0']);
  } finally { delete process.env.EVAL_DEFER_WAIT_MS; rmSync(f.dir, { recursive: true, force: true }); }
});

test('Codex implement persists JSON events and resumes with the same policy identity and timeout', () => {
  const dir = mkdtempSync(join(scratch, 'eval-resume-stage-'));
  try {
    const bin = join(dir, 'bin'), home = join(dir, 'home');
    for (const path of [bin, home]) mkdirSync(path);
    writeFileSync(join(bin, 'timeout'), '#!/usr/bin/env bash\nprintf "%s\\n" "$@" >> "$EVAL_FAKE_TIMEOUT_FILE"\nexec /usr/bin/timeout "$@"\n', { mode: 0o755 });
    writeFileSync(join(bin, 'codex'), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$EVAL_FAKE_ARG_FILE"
pwd > "$EVAL_FAKE_CWD_FILE"
output=""
while (($#)); do if [[ "$1" == --output-last-message ]]; then output=$2; shift; fi; shift; done
cat > "$EVAL_FAKE_PROMPT_FILE"
printf 'fixture report\\n' > "$output"
printf '%s\\n' '{"type":"thread.started","thread_id":"fixture-session"}' '{"type":"turn.completed","usage":{"input_tokens":30,"cached_input_tokens":10,"output_tokens":5}}'
`, { mode: 0o755 });
    const input = join(dir, 'input.json'), prompt = join(dir, 'prompt.md');
    writeFileSync(prompt, 'same repair prompt');
    const policy = JSON.parse(readFileSync(resolve('engine/model-policy.default.json'), 'utf8'));
    const work = policy.roles.work;
    for (const mode of ['initial', 'cold', 'resume']) {
      const artifact = join(dir, mode); mkdirSync(artifact);
      writeFileSync(input, JSON.stringify({ issue: { number: 1 }, priorState: {}, failure: '', recordSession: mode === 'initial',
        sessionId: mode === 'resume' ? 'fixture-session' : null,
        repairIdentity: mode === 'initial' ? null : `${work.provider}:${work.model}:${work.effort}` }));
      const raw = execFileSync('bash', ['engine/eval/stage-call.sh', 'implement', resolve('.'), dir, prompt, artifact, input], {
        encoding: 'utf8', env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}`, GH_TOKEN: '', GITHUB_TOKEN: '',
          EVAL_POLICY_FILE: resolve('engine/model-policy.default.json'),
          EVAL_FAKE_ARG_FILE: join(artifact, 'args.txt'), EVAL_FAKE_CWD_FILE: join(artifact, 'cwd.txt'), EVAL_FAKE_PROMPT_FILE: join(artifact, 'stdin.txt'),
          EVAL_FAKE_TIMEOUT_FILE: join(artifact, 'timeout.txt'),
          ZF_AGENT_TEST_MODE: '1', ZF_AGENT_TEST_ROOT: dir, ZF_CODEX_SANDBOX: 'workspace-write',
          AGENT_EXECUTION_MIN_MEM_MB: '1', AGENT_EXECUTION_MAX_LOAD: '1000000' },
      });
      const args = readFileSync(join(artifact, 'args.txt'), 'utf8').trim().split('\n');
      assert.equal(args.includes('resume'), mode === 'resume');
      assert.equal(args.includes('--ephemeral'), mode === 'cold');
      assert.equal(args.includes('--json'), mode !== 'cold');
      assert.equal(args[args.indexOf('-m') + 1], work.model);
      assert.ok(args.includes(`model_reasoning_effort=${work.effort}`));
      if (work.service_tier) assert.ok(args.includes(`service_tier="${work.service_tier}"`));
      if (mode === 'resume') assert.equal(args[args.indexOf('resume') + 1], 'fixture-session');
      else assert.equal(args[args.indexOf('--cd') + 1], dir);
      assert.equal(args[args.indexOf('--sandbox') + 1], 'workspace-write');
      if (mode !== 'cold') assert.equal(readFileSync(join(artifact, 'cwd.txt'), 'utf8').trim(), dir);
      assert.equal(readFileSync(join(artifact, 'stdin.txt'), 'utf8'), 'same repair prompt');
      assert.ok(readFileSync(join(artifact, 'timeout.txt'), 'utf8').split('\n').includes('120m'));
      assert.equal(raw, 'fixture report\n');
      assert.equal(JSON.parse(readFileSync(join(artifact, 'usage.json'))).tokens, 25);
      assert.match(readFileSync(join(artifact, 'worker.log'), 'utf8'), /thread.started/);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
