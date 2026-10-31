#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { readFile, readFileSync, mkdir, rename, writeFile } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { zfConfigFile } from '../pack-dir.mjs';

export const PROBE_INTERVAL_MS = 60 * 60 * 1000;
const SCRIPT_PATH = fileURLToPath(import.meta.url);
const EMAIL_PATTERN = /^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+$/;
const CURL_WRITE_OUT = '%{http_code}\n%{time_namelookup}\n%{time_connect}\n%{time_appconnect}\n%{time_pretransfer}\n%{time_starttransfer}\n%{size_upload}\n%{size_download}';

export function loadAcceptanceSettings() {
  const configFile = zfConfigFile('night.json');
  if (!configFile) return null;
  const night = JSON.parse(readFileSync(configFile, 'utf8'));
  const rawAccountRef = night.acceptance?.account_ref;
  const accountRefs = Array.isArray(rawAccountRef) ? rawAccountRef : typeof rawAccountRef === 'string' ? [rawAccountRef] : [];
  const loginUrl = night.production?.urls?.acceptance_login;
  let parsedUrl;
  try { parsedUrl = new URL(loginUrl); } catch { return null; }
  if (!accountRefs.length || accountRefs.some((email) => typeof email !== 'string' || !EMAIL_PATTERN.test(email))
      || new Set(accountRefs).size !== accountRefs.length || parsedUrl.protocol !== 'https:') return null;
  const acceptance = night.acceptance ?? {};
  const credentials = night.credentials ?? {};
  const settings = {
    accountRefs,
    loginUrl,
    accountRefEnvName: acceptance.account_ref_env_name ?? 'NIGHT_ACCEPTANCE_ACCOUNT_REF',
    passwordEnvName: acceptance.password_env_name ?? 'NIGHT_ACCEPTANCE_PASSWORD',
    childAccountRefEnvName: acceptance.child_account_ref_env_name ?? 'NIGHT_ACCEPTANCE_ACCOUNT_REF',
    childPasswordEnvName: acceptance.child_password_env_name ?? 'NIGHT_ACCEPTANCE_PASSWORD',
    wrapperEnvName: credentials.wrapper_env_name ?? 'NIGHT_CREDENTIALS_WRAPPER',
  };
  if (Object.entries(settings).some(([key, value]) => key.endsWith('EnvName')
      && (typeof value !== 'string' || !/^[A-Z_][A-Z0-9_]*$/.test(value)))) return null;
  return settings;
}
export function isProbeDue(state, now = Date.now()) {
  return !Number.isFinite(state?.checkedAt) || now - state.checkedAt >= PROBE_INTERVAL_MS;
}

export function acceptanceProbeExitCode(states) {
  return Object.values(states).every((state) => ["OK", "UNKNOWN"].includes(state?.verdict)) ? 0 : 1;
}

export function classifyHttpStatus(status) {
  if (status === 401) return { verdict: "BROKEN", detail: "reason=credential-rejected http=401" };
  if (status >= 200 && status < 300) return { verdict: "OK", detail: `http=${status}` };
  return { verdict: "UNKNOWN", detail: `reason=http-${status}` };
}

export function formatAcceptanceLoginSummary(accountIndex, state) {
  return `${state.verdict} acceptance-login account-index=${accountIndex} checked-at=${new Date(state.checkedAt).toISOString()} ${state.detail}`;
}

function curlFailurePhase(stdout, requestBytes) {
  const [status, ...rawMetrics] = String(stdout || "").trim().split("|");
  if (rawMetrics.length !== 7) return null;
  const [nameLookup, connect, appConnect, preTransfer, startTransfer, uploaded, downloaded] = rawMetrics.map(Number);
  if (![nameLookup, connect, appConnect, preTransfer, startTransfer, uploaded, downloaded].every(Number.isFinite)) return null;
  if (connect === 0) return nameLookup > 0 ? "tcp-connect" : "dns-or-connect";
  if (appConnect === 0) return "tls-handshake";
  if (preTransfer === 0) return "request-setup";
  if (startTransfer === 0) return uploaded < requestBytes ? "request-send" : "response-wait";
  const httpStatus = Number(status);
  if (!Number.isInteger(httpStatus) || httpStatus < 100 || httpStatus > 599) return "response-headers";
  return downloaded > 0 ? "response-body" : "response-after-headers";
}

export function requestLogin(email, password, request = spawnSync, loginUrl = loadAcceptanceSettings()?.loginUrl) {
  if (!loginUrl) return { verdict: 'UNKNOWN', detail: 'login-url-unconfigured' };
  const requestBody = JSON.stringify({ employeeId: email, password });
  const result = request("curl", [
    "--disable",
    "--silent",
    "--show-error",
    "--output",
    "/dev/null",
    "--write-out",
    CURL_WRITE_OUT,
    "--max-time",
    "10",
    "--header",
    "Content-Type: application/json",
    "--data-binary",
    "@-",
    loginUrl,
  ], {
    input: requestBody,
    encoding: "utf8",
    maxBuffer: 1024,
    timeout: 12000,
  });
  if (result.error || result.status !== 0) {
    const cause = result.error?.code ? `error=${result.error.code}` : `exit=${result.status}`;
    const phase = curlFailurePhase(result.stdout, Buffer.byteLength(requestBody));
    const phaseDetail = phase ? `phase=${phase} ` : "";
    return { verdict: "UNKNOWN", detail: `reason=request-failed stage=curl ${phaseDetail}${cause}` };
  }
  const status = Number(String(result.stdout).trim().split("|")[0]);
  if (!Number.isInteger(status) || status < 100 || status > 599) {
    return { verdict: "UNKNOWN", detail: "reason=invalid-http-status" };
  }
  return classifyHttpStatus(status);
}

export async function probeOnce(state, now, persist, login) {
  if (!isProbeDue(state, now)) return state;
  const pending = { checkedAt: now, verdict: "UNKNOWN", detail: "reason=probe-in-progress" };
  try {
    await persist(pending);
  } catch {
    return { checkedAt: now, verdict: "UNKNOWN", detail: "reason=state-write-failed" };
  }
  let result;
  try {
    result = login();
  } catch {
    result = { verdict: "UNKNOWN", detail: "reason=login-call-threw" };
  }
  const completed = { checkedAt: now, ...result };
  try {
    await persist(completed);
    return completed;
  } catch {
    return { checkedAt: now, verdict: "UNKNOWN", detail: "reason=state-write-failed" };
  }
}

function isProbeState(state) {
  return Number.isFinite(state?.checkedAt)
    && ["OK", "BROKEN", "UNKNOWN"].includes(state.verdict)
    && typeof state.detail === "string";
}

export function readAcceptanceAccountRefs(settings = loadAcceptanceSettings()) {
  return settings ? [...settings.accountRefs] : null;
}

export async function probeAccounts(emails, initialStates, now, persist, login) {
  const states = { ...initialStates };
  for (const email of emails) {
    states[email] = await probeOnce(
      states[email],
      now,
      async (state) => {
        states[email] = state;
        await persist({ ...states });
      },
      () => login(email),
    );
  }
  return states;
}

async function readStates(file, emails) {
  try {
    const saved = JSON.parse(await readFile(file, "utf8"));
    if (saved.accounts && typeof saved.accounts === "object" && !Array.isArray(saved.accounts)) {
      return Object.fromEntries(Object.entries(saved.accounts).filter(([email, state]) => emails.includes(email) && isProbeState(state)));
    }
    // Preserve the previous single-account L1 state during the file-format change.
    return isProbeState(saved) ? { [emails[0]]: saved } : {};
  } catch {
    return {};
  }
}

async function writeState(file, state) {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  const temp = `${file}.${process.pid}.tmp`;
  await writeFile(temp, JSON.stringify(state), { mode: 0o600 });
  await rename(temp, file);
}

async function writeStates(file, states) {
  await writeState(file, { accounts: states });
}

export function loginDemoAccount(email, request = spawnSync, settings = loadAcceptanceSettings()) {
  if (!settings) return { verdict: 'UNKNOWN', detail: 'acceptance-settings-unavailable' };
  const wrapper = process.env[settings.wrapperEnvName];
  if (!wrapper) return { verdict: 'UNKNOWN', detail: 'credential-wrapper-unavailable' };
  const result = request('bash', [wrapper, '--demo-account', email, '--', process.execPath, SCRIPT_PATH, '--login-child'], {
    encoding: 'utf8', maxBuffer: 2048, timeout: 70_000,
  });
  if (result.error) {
    const detail = result.error.code === 'ETIMEDOUT' ? 'credential-helper-timeout' : 'credential-helper-error';
    return { verdict: 'UNKNOWN', detail };
  }
  if (result.status === 124) return { verdict: 'UNKNOWN', detail: 'credential-helper-timeout' };
  if (![0, 1].includes(result.status)) return { verdict: 'UNKNOWN', detail: 'credential-helper-failed' };
  try {
    const state = JSON.parse(String(result.stdout).trim().split(/\r?\n/).at(-1));
    return isProbeState({ checkedAt: 0, ...state })
      ? { verdict: state.verdict, detail: state.detail }
      : { verdict: 'UNKNOWN', detail: 'credential-helper-result-invalid' };
  } catch {
    return { verdict: 'UNKNOWN', detail: 'credential-helper-result-invalid' };
  }
}

function loginChild(settings) {
  const email = settings ? process.env[settings.childAccountRefEnvName] || settings.accountRefs[0] : '';
  const password = settings ? process.env[settings.childPasswordEnvName] || '' : '';
  const result = settings && email && password
    ? requestLogin(email, password, spawnSync, settings.loginUrl)
    : { verdict: 'UNKNOWN', detail: 'primary-credential-unavailable' };
  console.log(JSON.stringify(result));
  process.exitCode = result.verdict === 'OK' ? 0 : 1;
}

async function main() {
  const settings = loadAcceptanceSettings();
  if (!settings) {
    console.log('skip: acceptance login monitor needs account_ref and production.urls.acceptance_login in night.json');
    return;
  }
  const emails = readAcceptanceAccountRefs(settings);
  const agentHome = process.env.AGENT_HOME || join(process.env.HOME || process.cwd(), '.zenoforge');
  const stateFile = join(agentHome, 'night', 'acceptance-login.json');
  const now = Date.now();
  const email = process.env[settings.accountRefEnvName] || '';
  const password = process.env[settings.passwordEnvName] || '';
  const states = await readStates(stateFile, emails);
  const firstCredentialsAvailable = email.trim().toLowerCase() === emails[0].toLowerCase() && !!password;
  if (!firstCredentialsAvailable) {
    states[emails[0]] = { checkedAt: now, verdict: 'UNKNOWN', detail: 'primary-credential-unavailable' };
    try { await writeStates(stateFile, states); }
    catch { states[emails[0]] = { checkedAt: now, verdict: 'UNKNOWN', detail: 'state-write-failed' }; }
  }
  const checked = await probeAccounts(
    emails,
    states,
    now,
    (next) => writeStates(stateFile, next),
    (accountEmail) => accountEmail === emails[0]
      ? requestLogin(accountEmail, password, spawnSync, settings.loginUrl)
      : loginDemoAccount(accountEmail, spawnSync, settings),
  );
  for (const [index, accountEmail] of emails.entries()) {
    const state = checked[accountEmail] || { checkedAt: now, verdict: 'UNKNOWN', detail: 'probe-result-missing' };
    console.log(formatAcceptanceLoginSummary(index + 1, state));
  }
  process.exitCode = acceptanceProbeExitCode(checked);
}

if (process.argv[1] && resolve(process.argv[1]) === SCRIPT_PATH) {
  const settings = loadAcceptanceSettings();
  if (process.argv[2] === '--login-child') loginChild(settings);
  else main().catch(() => {
    console.log('FAIL: acceptance login monitor failed');
    process.exitCode = 1;
  });
}
