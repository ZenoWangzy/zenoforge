#!/usr/bin/env node
// #4655：统一调度策略与单元状态机的消费者/校验器。
// 契约（state/scheduling-policy.json，schema zf-scheduling-policy/v1）：
//   1. 状态机自洽：transitions/initial/escalation 引用的状态都在 states 里；
//   2. 链接真实：每个 area 的 enforced_by 路径存在，引用的 ruling id 存在于 rulings.json，
//      且该 ruling 的 enforced_by 反向包含策略文件（策略与裁决登记的双向锁，防单边漂移）；
//   3. 源码封闭：state_machine.executed_by 里 scheduler 源码写出的每个 .stage 值都必须是
//      已声明的非 legacy 状态（挡拼错/未登记的新状态）；
//   4. 台账封闭（live ledger 存在时；CI/隔离 fixture 里没有就跳过）：每个单元当前 stage 是
//      已声明状态（台账里躺过 14 个 done、2 个 repair 这类调度器不再书写的僵尸状态；
//      10-29 06:32Z 还发生过手改 live units.json）。legacy 状态只读兼容，不计失败。
//      转移表不按台账回放校验：event→stage 语义只存在于调度器源码，复制第二份映射必漂移；
//      新转移由改调度器的人在同一次落地里经规则通道补登记。
// check-rulings.sh（落地预检 + Pipeline suites）以无参模式运行本脚本；--units <path> 供
// supervisor/健康检查对任意台账单独跑。
import { existsSync, readFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { zfConfigFile } from './pack-dir.mjs';

const REPO_ROOT = resolve(process.env.ZF_REPO_DIR || join(dirname(fileURLToPath(import.meta.url)), '..'));
const POLICY_PATH = zfConfigFile('state/scheduling-policy.json', REPO_ROOT);
const RULINGS_PATH = zfConfigFile('state/rulings.json', REPO_ROOT);
const LEDGER_PATH = `${process.env.AGENT_HOME ?? `${process.env.HOME}/.zenoforge`}/checkout/.scratch-supervisor/autopi/units.json`;

const errors = [];
const notes = [];
const fail = (message) => errors.push(message);

function resolveRepoPath(label, path) {
  if (typeof path !== 'string' || path === '' || isAbsolute(path)) {
    fail(`${label} must be a non-empty repo-relative path: ${path}`);
    return null;
  }
  const absolute = resolve(REPO_ROOT, path);
  const fromRoot = relative(REPO_ROOT, absolute);
  if (fromRoot === '..' || fromRoot.startsWith(`..${sep}`)) {
    fail(`${label} escapes the repository: ${path}`);
    return null;
  }
  return absolute;
}

if (!POLICY_PATH || !RULINGS_PATH) {
  fail('scheduling policy or rulings config file is unavailable');
  process.stderr.write(`ERROR scheduling-policy: ${errors.join('; ')}\n`);
  process.exit(1);
}

const policy = JSON.parse(readFileSync(POLICY_PATH, 'utf8'));
if (policy.schema !== 'zf-scheduling-policy/v1') fail(`unsupported schema: ${policy.schema}`);
if (!Number.isInteger(policy.version) || policy.version < 1) fail('version must be a positive integer');

const machine = policy.state_machine;
if (!machine || typeof machine !== 'object') {
  fail('state_machine must be an object');
} else {
  const states = machine.states ?? {};
  const stateIds = new Set(Object.keys(states));
  for (const [id, state] of Object.entries(states)) {
    if (!state || typeof state !== 'object' || typeof state.meaning !== 'string' || state.meaning === '') {
      fail(`state ${id} must declare a meaning`);
    }
  }
  const declared = (ids, label) => {
    for (const id of ids) if (!stateIds.has(id)) fail(`${label} references undeclared state: ${id}`);
  };
  declared(machine.initial_states ?? [], 'initial_states');
  declared(machine.escalation_targets ?? [], 'escalation_targets');
  for (const [from, tos] of Object.entries(machine.transitions ?? {})) {
    if (!stateIds.has(from)) fail(`transitions key is not a declared state: ${from}`);
    if (!Array.isArray(tos) || tos.length === 0) fail(`transitions.${from} must be a non-empty array`);
    else declared(tos, `transitions.${from}`);
  }

  for (const source of machine.executed_by ?? []) {
    const absolute = resolveRepoPath('state_machine.executed_by', source);
    if (!absolute) continue;
    if (!existsSync(absolute)) {
      fail(`state_machine.executed_by path does not exist: ${source}`);
      continue;
    }
    const written = new Set();
    for (const match of readFileSync(absolute, 'utf8').matchAll(/\.stage=\\?"([a-z][a-z-]*)/g)) {
      written.add(match[1]);
    }
    for (const stage of written) {
      if (!stateIds.has(stage)) fail(`${source} writes undeclared stage "${stage}"`);
      else if (states[stage].legacy) fail(`${source} writes legacy stage "${stage}"`);
    }
  }
}

const { rulings } = JSON.parse(readFileSync(RULINGS_PATH, 'utf8'));
const rulingsById = new Map(rulings.map((ruling) => [ruling.id, ruling]));
const policyRef = 'engine/state/scheduling-policy.json';
for (const [name, area] of Object.entries(policy.areas ?? {})) {
  if (!Array.isArray(area.enforced_by) || area.enforced_by.length === 0) {
    fail(`area ${name} must declare enforced_by`);
  }
  for (const path of area.enforced_by ?? []) {
    const absolute = resolveRepoPath(`area ${name} enforced_by`, path);
    if (absolute && !existsSync(absolute)) fail(`area ${name} enforced_by path does not exist: ${path}`);
  }
  for (const id of area.rulings ?? []) {
    if (!rulingsById.has(id)) fail(`area ${name} references unknown ruling: ${id}`);
    else if (!(rulingsById.get(id).enforced_by ?? []).includes(policyRef)) {
      fail(`ruling ${id} is referenced by the policy but does not list ${policyRef} in enforced_by`);
    }
  }
}

// 台账封闭（--units 显式给定，或无参且 live ledger 存在）。
const ledgerArg = process.argv.indexOf('--units');
const ledgerPath = ledgerArg !== -1 ? process.argv[ledgerArg + 1] : (existsSync(LEDGER_PATH) ? LEDGER_PATH : null);
if (ledgerPath) {
  const absolute = isAbsolute(ledgerPath) ? ledgerPath : resolve(process.cwd(), ledgerPath);
  if (!existsSync(absolute)) {
    fail(`units ledger not found: ${ledgerPath}`);
  } else {
    const states = machine.states ?? {};
    const stateIds = new Set(Object.keys(states));
    let units = 0;
    let legacy = 0;
    for (const unit of JSON.parse(readFileSync(absolute, 'utf8')).units ?? []) {
      units += 1;
      const stage = unit.stage;
      if (!stateIds.has(stage)) {
        fail(`unit ${unit.id} is in undeclared stage "${stage}"`);
      } else if (states[stage].legacy) {
        legacy += 1;
      }
    }
    notes.push(`${units} unit(s) checked`);
    if (legacy > 0) notes.push(`${legacy} unit(s) in legacy read-only states`);
  }
}

if (notes.length > 0) for (const note of notes) process.stderr.write(`scheduling-policy: ${note}\n`);
if (errors.length > 0) {
  for (const error of errors) process.stderr.write(`ERROR scheduling-policy: ${error}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write('scheduling-policy: checks passed\n');
}
