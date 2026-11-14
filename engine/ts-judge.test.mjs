import assert from "node:assert/strict";
import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { judge, questionFor, recordShadowComparison, SHADOW_EVENTS_REQUIRED, typesafeClientOptions } from "./ts-judge.mjs";

async function fixture(t) {
  const dir = await mkdtemp(path.join(os.tmpdir(), "ts-judge-test-"));
  const savedAgentHome = process.env.AGENT_HOME;
  process.env.AGENT_HOME = dir;
  t.after(async () => {
    if (savedAgentHome === undefined) delete process.env.AGENT_HOME;
    else process.env.AGENT_HOME = savedAgentHome;
    await rm(dir, { recursive: true, force: true });
  });
  return {
    dir,
    log: path.join(dir, "ts-judge.jsonl"),
    outcomeFile: path.join(dir, "state", "ts-judge-last.json"),
  };
}

function fakeClient(answer) {
  const calls = [];
  return {
    calls,
    client: {
      async systemOne(request) {
        calls.push(request);
        return { answers: answer };
      },
    },
  };
}

async function seedAgreementLog(file, questionSet = "ci-failure", count = SHADOW_EVENTS_REQUIRED) {
  const rows = Array.from({ length: count }, (_, index) => JSON.stringify({
    mode: "shadow",
    question_set: questionSet,
    event_id: `event-${index}`,
    agreement: true,
  }));
  await appendFile(file, `${rows.join("\n")}\n`);
}

test("missing key uses the caller's decision without constructing a client", async (t) => {
  const { log } = await fixture(t);
  const state = { currentDecision: "code", event_id: "ci:42:1" };
  const result = await judge({ questionSet: "ci-failure", state, apiKey: "", file: log });
  assert.equal(result.status, "fallback");
  assert.equal(result.reason, "missing-api-key");
  assert.equal(result.decision, "code");
  assert.equal(result.adopted, false);
});

test("an answered call records its outcome without retaining request data", async (t) => {
  const { log, outcomeFile } = await fixture(t);
  const at = "2026-11-14T00:00:00.000Z";
  const mock = fakeClient({ classification: { choice: "infra", confidence: 0.95 } });
  const result = await judge({
    questionSet: "ci-failure",
    state: { currentDecision: "code", event_id: "ci:42:1", detail: "private message" },
    apiKey: "mock-secret-key",
    client: mock.client,
    file: log,
    now: new Date(at),
  });

  assert.equal(result.status, "answered");
  assert.deepEqual(JSON.parse(await readFile(outcomeFile, "utf8")), {
    updated_at: at,
    last: { at, status: "answered", reason: null },
    window: [{ at, status: "answered", reason: null }],
  });
});

test("outcome history drops entries older than one hour", async (t) => {
  const { dir, log, outcomeFile } = await fixture(t);
  const at = "2026-11-14T01:00:00.000Z";
  const recent = { at: "2026-11-14T00:30:00.000Z", status: "fallback", reason: "credits-exhausted" };
  await mkdir(path.dirname(outcomeFile), { recursive: true });
  await writeFile(outcomeFile, JSON.stringify({
    updated_at: "2026-11-14T00:30:00.000Z",
    last: recent,
    window: [
      { at: "2026-11-13T23:59:59.999Z", status: "fallback", reason: "rate-limited" },
      recent,
    ],
  }));

  await judge({
    questionSet: "ci-failure",
    state: { currentDecision: "code", event_id: "ci:43:1" },
    apiKey: "mock-key",
    client: fakeClient({ classification: { choice: "infra", confidence: 0.95 } }).client,
    file: log,
    now: new Date(at),
  });

  const record = JSON.parse(await readFile(outcomeFile, "utf8"));
  assert.deepEqual(record.window, [
    recent,
    { at, status: "answered", reason: null },
  ]);
});

test("outcome history keeps only its newest 200 entries", async (t) => {
  const { log, outcomeFile } = await fixture(t);
  const now = new Date("2026-11-14T01:00:00.000Z");
  const entries = Array.from({ length: 205 }, (_, index) => ({
    at: new Date(Date.parse("2026-11-14T00:30:00.000Z") + index * 1000).toISOString(),
    status: "fallback",
    reason: "credits-exhausted",
  }));
  await mkdir(path.dirname(outcomeFile), { recursive: true });
  await writeFile(outcomeFile, JSON.stringify({ updated_at: entries.at(-1).at, last: entries.at(-1), window: entries }));

  await judge({
    questionSet: "ci-failure",
    state: {},
    apiKey: "mock-key",
    client: fakeClient({ classification: { choice: "infra", confidence: 0.95 } }).client,
    file: log,
    now,
  });

  const record = JSON.parse(await readFile(outcomeFile, "utf8"));
  assert.equal(record.window.length, 200);
  assert.equal(record.window[0].at, entries[6].at);
  assert.deepEqual(record.window.at(-1), { at: now.toISOString(), status: "answered", reason: null });
});

test("an unavailable outcome directory does not change the judge result", async (t) => {
  const { dir, log } = await fixture(t);
  const blocker = path.join(dir, "not-a-directory");
  await writeFile(blocker, "occupied");
  process.env.AGENT_HOME = blocker;
  const originalWrite = process.stderr.write;
  let stderr = "";
  process.stderr.write = (chunk) => {
    stderr += chunk;
    return true;
  };

  let result;
  try {
    result = await judge({
      questionSet: "ci-failure",
      state: {},
      apiKey: "mock-key",
      client: fakeClient({ classification: { choice: "infra", confidence: 0.95 } }).client,
      file: log,
      now: new Date("2026-11-14T00:00:00.000Z"),
    });
  } finally {
    process.stderr.write = originalWrite;
  }

  assert.equal(result.status, "answered");
  assert.equal(result.candidate, "infra");
  assert.equal(result.decision, "infra");
  assert.equal(result.adopted, false);
  assert.equal(stderr, "ts-judge: outcome record unavailable\n");
});

test("a 402 credit error stays classified and is logged without credentials", async (t) => {
  const { log, outcomeFile } = await fixture(t);
  const at = "2026-11-14T00:00:00.000Z";
  const originalWrite = process.stderr.write;
  let stderr = "";
  process.stderr.write = (chunk) => {
    stderr += chunk;
    return true;
  };

  let result;
  try {
    result = await judge({
      questionSet: "intake-priority",
      state: {
        currentDecision: "priority:normal",
        event_id: "intake:42",
        policy: {
          labels: {
            top: "priority:top",
            high: "priority:high",
            normal: "priority:normal",
            low: "priority:low",
            needsTriage: "priority:unsure",
            routePrefix: "route:",
          },
          scoreThresholds: { normal: 0.5, high: 1.5, top: 2.5 },
          minimumConfidence: 0.9,
        },
      },
      apiKey: "mock-secret-key",
      client: {
        async systemOne() {
          const error = new Error("Your organization has no available TypeSafe API credits. Add credits at https://console.typesafe.ai/settings/billing");
          error.status = 402;
          error.headers = { authorization: "Bearer mock-secret-key" };
          throw error;
        },
      },
      file: log,
      now: new Date(at),
    });
  } finally {
    process.stderr.write = originalWrite;
  }

  assert.equal(result.status, "fallback");
  assert.equal(result.reason, "credits-exhausted");
  assert.match(stderr, /^ts-judge: credits-exhausted \(402\): Your organization has no available TypeSafe API credits\./);
  assert.equal(stderr.trim().split(/\r?\n/).length, 1);
  assert.doesNotMatch(stderr, /mock-secret-key|authorization|Bearer/);
  assert.deepEqual(JSON.parse(await readFile(outcomeFile, "utf8")), {
    updated_at: at,
    last: { at, status: "fallback", reason: "credits-exhausted" },
    window: [{ at, status: "fallback", reason: "credits-exhausted" }],
  });
});

test("high confidence answers shadow the baseline until 20 events agree, then can be adopted", async (t) => {
  const { log } = await fixture(t);
  const mock = fakeClient({ classification: { choice: "infra", confidence: 0.93 } });
  const state = {
    currentDecision: "code",
    event_id: "ci:42:1",
    failedLog: "SELECT * FROM events\ninstance_secret | test-secret-value\nAuthorization: Bearer api-secret-value",
  };

  const shadow = await judge({
    questionSet: "ci-failure", state, apiKey: "api-secret-value", client: mock.client, file: log,
  });
  assert.equal(shadow.decision, "code");
  assert.equal(shadow.adopted, false);
  assert.equal(mock.calls[0].model, "jev-latest");
  assert.equal(mock.calls[0].questions.classification.type, "choice");
  assert.doesNotMatch(JSON.stringify(mock.calls[0].state), /api-secret-value|test-secret-value/);

  await seedAgreementLog(log);
  const active = await judge({
    questionSet: "ci-failure",
    state: { currentDecision: "code", event_id: "ci:43:1" },
    apiKey: "api-secret-value",
    client: mock.client,
    file: log,
  });
  assert.equal(active.rollout_ready, true);
  assert.equal(active.decision, "infra");
  assert.equal(active.adopted, true);
  const journal = await readFile(log, "utf8");
  assert.doesNotMatch(journal, /api-secret-value|test-secret-value/);
  assert.match(journal, /"mode":"active"/);
});

test("low confidence falls back even after the shadow sample is ready", async (t) => {
  const { log } = await fixture(t);
  await seedAgreementLog(log);
  const mock = fakeClient({ classification: { choice: "flaky", confidence: 0.79 } });
  const result = await judge({
    questionSet: "ci-failure",
    state: { currentDecision: "code", event_id: "ci:44:1" },
    apiKey: "present",
    client: mock.client,
    file: log,
  });
  assert.equal(result.rollout_ready, true);
  assert.equal(result.decision, "code");
  assert.equal(result.adopted, false);
});

test("a delayed Terra result stays in shadow when its Jev request started before maturity", async (t) => {
  const { log } = await fixture(t);
  await seedAgreementLog(log, "f12");
  const result = await recordShadowComparison({
    questionSet: "f12",
    eventId: "f12:unit:old-request",
    candidate: "requeue",
    currentDecision: "park",
    confidence: 0.95,
    forceShadow: true,
    file: log,
  });
  assert.equal(result.rollout_ready, true);
  assert.equal(result.sample_count, 21);
  const rows = (await readFile(log, "utf8")).trim().split(/\r?\n/).map((line) => JSON.parse(line));
  assert.equal(rows.at(-1).mode, "shadow");
  assert.equal(rows.at(-1).agreement, false);
});

test("a repeated shadow event id is not counted as a second comparison", async (t) => {
  const { log } = await fixture(t);
  const input = {
    questionSet: "f12",
    eventId: "f12:unit:entry-1",
    candidate: "requeue",
    currentDecision: "park",
    confidence: 0.95,
    forceShadow: true,
    file: log,
  };
  await recordShadowComparison(input);
  const repeated = await recordShadowComparison({ ...input, candidate: "park" });
  assert.equal(repeated.duplicate, true);
  assert.equal(repeated.agreement, false);
  assert.equal(repeated.sample_count, 1);
  assert.equal((await readFile(log, "utf8")).trim().split(/\r?\n/).length, 1);
});

test("each pipeline question set adopts its high-confidence answer after its own shadow sample", async (t) => {
  const { dir } = await fixture(t);
  const sha1 = "a".repeat(40);
  const sha2 = "b".repeat(40);
  const cases = [
    {
      set: "ci-failure",
      baseline: "code",
      candidate: "infra",
      state: {},
      answer: { classification: { choice: "infra", confidence: 0.95 } },
    },
    {
      set: "main-red",
      baseline: sha1,
      candidate: sha2,
      state: { failedSuite: "scheduler.test.sh", candidates: [{ sha: sha1, files: ["a.sh"] }, { sha: sha2, files: ["b.sh"] }] },
      answer: { culprit: { choice: sha2, confidence: 0.95 } },
    },
    {
      set: "f12",
      baseline: "park",
      candidate: "requeue",
      state: {},
      answer: { action: { choice: "requeue", confidence: 0.95 } },
    },
    {
      set: "triage-size",
      baseline: "ready-for-agent",
      candidate: "needs-recut",
      state: {},
      answer: { size: { score: 3, confidence: 0.95 } },
    },
    {
      set: "recut",
      baseline: "accept",
      candidate: "refuse",
      state: {},
      answer: { accept: { noul: 0.05 } },
    },
  ];

  for (const [index, item] of cases.entries()) {
    const file = path.join(dir, `${item.set}.jsonl`);
    await seedAgreementLog(file, item.set);
    const mock = fakeClient(item.answer);
    const result = await judge({
      questionSet: item.set,
      state: { ...item.state, currentDecision: item.baseline, event_id: `event-${index}` },
      apiKey: "mock-key",
      client: mock.client,
      file,
    });
    assert.equal(result.status, "answered", item.set);
    assert.equal(result.candidate, item.candidate, item.set);
    assert.equal(result.decision, item.candidate, item.set);
    assert.equal(result.adopted, true, item.set);
  }
});

test("all requested question types expose bounded answers and confidence", () => {
  const sha1 = "a".repeat(40);
  const sha2 = "b".repeat(40);
  assert.equal(questionFor("main-red", { failedSuite: "suite.test.sh", candidates: [
    { sha: sha1, subject: "first", files: ["scripts/a.sh"] },
    { sha: sha2, subject: "second", files: ["scripts/b.sh"] },
  ] }).questions.culprit.type, "choice");
  assert.equal(questionFor("f12", {}).questions.action.type, "choice");
  assert.equal(questionFor("triage-size", {}).questions.size.type, "score");
  assert.equal(questionFor("recut", {}).questions.accept.type, "noul");
});

test("intake priority asks four bounded questions and marks low confidence with the unsure label", () => {
  const questionSet = questionFor("intake-priority", {
    issue: { number: 51, title: "Improve release checks", body: "Protect production data." },
    roadmapContainers: [{ number: 901, title: "Release reliability" }],
    duplicateCandidates: [{ number: 42, title: "Existing release check" }],
    recentMainSubjects: ["Harden release checks"],
    policy: {
      labels: {
        top: "priority:top",
        high: "priority:high",
        normal: "priority:normal",
        low: "priority:low",
        needsTriage: "priority:unsure",
        routePrefix: "route:",
      },
      scoreThresholds: { normal: 0.5, high: 1.5, top: 2.5 },
      minimumConfidence: 0.9,
    },
  });

  assert.equal(Object.keys(questionSet.questions).length, 4);
  assert.equal(questionSet.questions.priority.type, "score");
  assert.equal(questionSet.questions.route.type, "choice");
  assert.ok(questionSet.questions.route.criteria["none-fits"]);
  assert.equal(questionSet.questions.duplicate.type, "noul");
  assert.equal(questionSet.questions.stale.type, "noul");
  assert.match(questionSet.questions.priority.instructions, /founder-facing impact/);
  assert.match(questionSet.questions.priority.instructions, /release blocker/);
  assert.match(questionSet.questions.priority.instructions, /customer path/);
  assert.match(questionSet.questions.priority.instructions, /production data safety/);

  const extracted = questionSet.extract({
    priority: { score: 3, confidence: 0.85 },
    route: { choice: "901", confidence: 0.95 },
    duplicate: { noul: 0.1 },
    stale: { noul: 0.05 },
  });
  const answer = JSON.parse(extracted.answer);
  assert.equal(answer.priority, "priority:top");
  assert.equal(answer.unsure, "priority:unsure");
  assert.equal(answer.route, "901");
  assert.equal(answer.duplicate, false);
  assert.equal(answer.stale, false);
  assert.equal(extracted.confidence, 0.85);

  const sure = questionSet.extract({
    priority: { score: 3, confidence: 0.95 },
    route: { choice: "901", confidence: 0.95 },
    duplicate: { noul: 0.1 },
    stale: { noul: 0.05 },
  });
  assert.strictEqual(JSON.parse(sure.answer).unsure, null);
});

async function withTypesafeEnv(t, { key, envFile }) {
  const saved = { TYPESAFE_API_KEY: process.env.TYPESAFE_API_KEY, TYPESAFE_ENV_FILE: process.env.TYPESAFE_ENV_FILE };
  t.after(() => {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });
  if (key === undefined) delete process.env.TYPESAFE_API_KEY;
  else process.env.TYPESAFE_API_KEY = key;
  if (envFile === undefined) delete process.env.TYPESAFE_ENV_FILE;
  else process.env.TYPESAFE_ENV_FILE = envFile;
}

test("judge reads the key from TYPESAFE_ENV_FILE when the env var is absent", async (t) => {
  const { dir, log } = await fixture(t);
  const envFile = path.join(dir, "typesafe.env");
  await writeFile(envFile, "# comment\nTYPESAFE_API_KEY=\"file-secret-value\"\n");
  await withTypesafeEnv(t, { key: undefined, envFile });
  const mock = fakeClient({ classification: { choice: "infra", confidence: 0.95 } });
  const result = await judge({
    questionSet: "ci-failure",
    state: { currentDecision: "code", event_id: "ci:50:1" },
    client: mock.client,
    file: log,
  });
  assert.equal(result.status, "answered");
  assert.equal(result.candidate, "infra");
});

test("the TYPESAFE_API_KEY env var wins over TYPESAFE_ENV_FILE", async (t) => {
  const { dir, log } = await fixture(t);
  const envFile = path.join(dir, "typesafe.env");
  await writeFile(envFile, "TYPESAFE_API_KEY=file-key\n");
  await withTypesafeEnv(t, { key: "env-key", envFile });
  const mock = fakeClient({ classification: { choice: "infra", confidence: 0.95 } });
  const result = await judge({
    questionSet: "ci-failure",
    state: { currentDecision: "code", event_id: "ci:51:1" },
    client: mock.client,
    file: log,
  });
  assert.equal(result.status, "answered");
  assert.equal(JSON.stringify(result).includes("file-key"), false);
});

test("a missing TYPESAFE_ENV_FILE falls back with missing-api-key", async (t) => {
  const { dir, log } = await fixture(t);
  await withTypesafeEnv(t, { key: undefined, envFile: path.join(dir, "absent.env") });
  const result = await judge({
    questionSet: "ci-failure",
    state: { currentDecision: "code", event_id: "ci:52:1" },
    file: log,
  });
  assert.equal(result.status, "fallback");
  assert.equal(result.reason, "missing-api-key");
  assert.equal(result.decision, "code");
});

test("intake-priority builds its client with a 15 s timeout and one retry", () => {
  assert.deepEqual(typesafeClientOptions("intake-priority", {}), { timeout: 15000, retry: { maxRetries: 1 } });
});

test("hot-path question sets keep the 800 ms timeout and no retry", () => {
  for (const set of ["ci-failure", "main-red", "f12", "triage-size", "recut"]) {
    assert.deepEqual(typesafeClientOptions(set, {}), { timeout: 800, retry: { maxRetries: 0 } }, set);
  }
});

test("a valid ZF_TS_JUDGE_TIMEOUT_MS overrides the timeout for every set and keeps its retry count", () => {
  const env = { ZF_TS_JUDGE_TIMEOUT_MS: "30000" };
  assert.deepEqual(typesafeClientOptions("f12", env), { timeout: 30000, retry: { maxRetries: 0 } });
  assert.deepEqual(typesafeClientOptions("intake-priority", env), { timeout: 30000, retry: { maxRetries: 1 } });
});

test("an invalid ZF_TS_JUDGE_TIMEOUT_MS is ignored", () => {
  for (const raw of ["99", "60001", "1.5", "-200", "abc", ""]) {
    assert.deepEqual(typesafeClientOptions("f12", { ZF_TS_JUDGE_TIMEOUT_MS: raw }), { timeout: 800, retry: { maxRetries: 0 } }, raw);
  }
});
