import assert from "node:assert/strict";
import { appendFile, mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { judge, questionFor, recordShadowComparison, SHADOW_EVENTS_REQUIRED } from "./ts-judge.mjs";

async function fixture(t) {
  const dir = await mkdtemp(path.join(os.tmpdir(), "ts-judge-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return { dir, log: path.join(dir, "ts-judge.jsonl") };
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
