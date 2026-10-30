#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { appendFile, mkdir, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { choice, noul, score, TypeSafeClient } from "@typesafe-ai/sdk";

export const CONFIDENCE_THRESHOLD = 0.8;
export const SHADOW_EVENTS_REQUIRED = 20;
export const SHADOW_AGREEMENT_REQUIRED = 0.9;
const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const REDACT_SCRIPT = path.join(REPO_ROOT, "engine/redact-secrets.sh");

const quietLogger = Object.freeze({
  debug() {},
  info() {},
  warn() {},
  error() {},
});

function mainRedCandidates(state) {
  const candidates = Array.isArray(state.candidates) ? state.candidates : [];
  if (candidates.length < 2 || candidates.length > 20) throw new Error("invalid candidate set");
  const criteria = {};
  for (const candidate of candidates) {
    if (!/^[0-9a-f]{40}$/.test(candidate.sha) || criteria[candidate.sha]) {
      throw new Error("invalid candidate SHA");
    }
    const files = Array.isArray(candidate.files) ? candidate.files.slice(0, 30) : [];
    criteria[candidate.sha] = [candidate.subject, ...files].filter(Boolean).join("; ") || null;
  }
  return criteria;
}

export function questionFor(questionSet, state) {
  switch (questionSet) {
    case "ci-failure":
      return {
        questions: {
          classification: choice(
            "Classify this completed CI failure as a flaky test, infrastructure failure, or real code defect. Use the failed test evidence and logs.",
            {
              code: "A reproducible failure caused by changed product or test code.",
              infra: "A runner, network, dependency, or service failure unrelated to the tested change.",
              flaky: "A nondeterministic test failure likely to pass on a rerun.",
            },
          ),
        },
        extract: (answers) => ({
          answer: answers.classification.choice,
          confidence: answers.classification.confidence,
        }),
      };
    case "main-red": {
      const candidates = mainRedCandidates(state);
      return {
        questions: {
          culprit: choice(
            `Choose the commit most likely to have caused the failing suite ${String(state.failedSuite ?? "unknown")}. Compare each commit's changed files and subject.`,
            candidates,
          ),
        },
        extract: (answers) => ({ answer: answers.culprit.choice, confidence: answers.culprit.confidence }),
      };
    }
    case "f12":
      return {
        questions: {
          action: choice(
            "Choose the next bounded supervisor action for this unit based on its escalation reason, history, review findings, and CI evidence.",
            {
              requeue: "Return the unit to a concrete implementation or repair step.",
              recut: "Send an oversized ticket through the existing guarded recut route.",
              escalate: "Ask the reporter or owner for the missing decision.",
              park: "Leave the unit parked with a concise reason for later supervisor handling.",
            },
          ),
        },
        extract: (answers) => ({ answer: answers.action.choice, confidence: answers.action.confidence }),
      };
    case "triage-size":
      return {
        questions: {
          size: score(
            "Score whether this issue is small enough for one implementation unit. Use the issue, expected package/path scope, risk, and level. 0-1 is bounded; 2 is broad; 3 should be split before implementation.",
            ["Small bounded change", "One ordinary implementation unit", "Broad scope with multiple concerns", "Too large for one implementation unit"],
          ),
        },
        extract: (answers) => ({
          answer: answers.size.score >= 2.5 ? "needs-recut" : "ready-for-agent",
          confidence: answers.size.confidence,
          score: answers.size.score,
        }),
      };
    case "recut":
      return {
        questions: {
          accept: noul("Is the proposed recut plan grounded in this ticket and its real domain, with children that are independently implementable and within the stated cap?"),
        },
        extract: (answers) => ({
          answer: answers.accept.noul >= 0.5 ? "accept" : "refuse",
          confidence: Math.max(answers.accept.noul, 1 - answers.accept.noul),
          probability: answers.accept.noul,
        }),
      };
    default:
      throw new Error("unknown question set");
  }
}

function redactState(state, apiKey) {
  const serializable = JSON.parse(JSON.stringify(state));
  function redactValue(value) {
    if (typeof value === "string") {
      const result = spawnSync("bash", [REDACT_SCRIPT], {
        input: value,
        encoding: "utf8",
        env: { ...process.env, TYPESAFE_API_KEY: apiKey },
        maxBuffer: 2 * 1024 * 1024,
      });
      if (result.status !== 0 || result.error) throw new Error("redaction failed");
      return result.stdout;
    }
    if (Array.isArray(value)) return value.map(redactValue);
    if (value && typeof value === "object") {
      return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, redactValue(item)]));
    }
    return value;
  }
  return redactValue(serializable);
}

function logPath() {
  if (process.env.TYPESAFE_JUDGE_LOG) return process.env.TYPESAFE_JUDGE_LOG;
  const agentHome = process.env.AGENT_HOME || path.join(os.homedir(), ".zenoforge");
  return path.join(agentHome, "logs", "ts-judge.jsonl");
}

async function shadowHistory(questionSet, file) {
  let contents;
  try {
    contents = await readFile(file, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
  const rows = contents.split(/\r?\n/).flatMap((line) => {
    if (!line) return [];
    try {
      const row = JSON.parse(line);
      return row.question_set === questionSet && row.mode === "shadow"
        && typeof row.event_id === "string" && row.event_id.length > 0
        && typeof row.agreement === "boolean" ? [row] : [];
    } catch {
      return [];
    }
  });
  const seen = new Set();
  return rows.filter((row) => {
    if (seen.has(row.event_id)) return false;
    seen.add(row.event_id);
    return true;
  });
}

function rolloutReady(history) {
  if (history.length < SHADOW_EVENTS_REQUIRED) return false;
  return history.filter((row) => row.agreement).length / history.length >= SHADOW_AGREEMENT_REQUIRED;
}

async function appendComparison(file, row) {
  await mkdir(path.dirname(file), { recursive: true });
  await appendFile(file, `${JSON.stringify(row)}\n`, { encoding: "utf8", mode: 0o600 });
}

function fallbackResult(questionSet, state, reason) {
  const baseline = state?.currentDecision;
  return {
    status: "fallback",
    question_set: questionSet,
    reason,
    candidate: null,
    confidence: null,
    decision: baseline ?? null,
    adopted: false,
    rollout_ready: false,
  };
}

export async function recordShadowComparison({
  questionSet,
  eventId,
  candidate,
  confidence,
  currentDecision,
  forceShadow = false,
  file = logPath(),
  now = new Date(),
}) {
  const history = await shadowHistory(questionSet, file);
  const ready = rolloutReady(history);
  const safeCandidate = String(candidate);
  const safeBaseline = String(currentDecision);
  const safeEventId = String(eventId ?? "");
  const previous = history.find((row) => row.event_id === safeEventId);
  if (previous) {
    return { rollout_ready: ready, agreement: previous.agreement, sample_count: history.length, duplicate: true };
  }
  const row = {
    at: now.toISOString(),
    question_set: questionSet,
    event_id: safeEventId,
    baseline: safeBaseline,
    candidate: safeCandidate,
    confidence,
    decision: safeBaseline,
    agreement: safeCandidate === safeBaseline,
    mode: forceShadow || !ready ? "shadow" : "active",
  };
  await appendComparison(file, row);
  return { rollout_ready: ready, agreement: row.agreement, sample_count: history.length + (forceShadow || !ready ? 1 : 0) };
}

async function recordAdoption({ questionSet, eventId, candidate, confidence, file = logPath(), now = new Date() }) {
  await appendComparison(file, {
    at: now.toISOString(),
    question_set: questionSet,
    event_id: String(eventId ?? ""),
    baseline: null,
    candidate: String(candidate),
    confidence,
    decision: String(candidate),
    agreement: null,
    mode: "active",
  });
}

export async function judge({
  questionSet,
  state,
  apiKey = process.env.TYPESAFE_API_KEY,
  client,
  file = logPath(),
  now = new Date(),
}) {
  if (!apiKey) return fallbackResult(questionSet, state, "missing-api-key");

  let safeState;
  try {
    safeState = redactState(state, apiKey);
  } catch {
    return fallbackResult(questionSet, state, "redaction-failed");
  }

  try {
    const { questions, extract } = questionFor(questionSet, safeState);
    const sdk = client ?? new TypeSafeClient({
      timeout: 800,
      retry: { maxRetries: 0 },
      logger: quietLogger,
    });
    const response = await sdk.systemOne({ state: safeState, questions, model: "jev-latest" });
    const normalized = extract(response.answers);
    const confidence = normalized.confidence;
    if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1 || normalized.answer == null) {
      return fallbackResult(questionSet, state, "invalid-answer");
    }

    const history = await shadowHistory(questionSet, file);
    const ready = rolloutReady(history);
    const baseline = safeState.currentDecision;
    const hasBaseline = baseline !== undefined && baseline !== null && baseline !== "";
    const eventId = safeState.event_id ?? "";
    let adopted = false;
    let decision = hasBaseline ? baseline : normalized.answer;
    let logging = "pending-baseline";

    if (hasBaseline && eventId) {
      adopted = ready && confidence >= CONFIDENCE_THRESHOLD;
      decision = adopted ? normalized.answer : baseline;
      const row = {
        at: now.toISOString(),
        question_set: questionSet,
        event_id: String(eventId),
        baseline: String(baseline),
        candidate: String(normalized.answer),
        confidence,
        decision: String(decision),
        agreement: String(normalized.answer) === String(baseline),
        mode: ready ? "active" : "shadow",
      };
      try {
        await appendComparison(file, row);
        logging = "recorded";
      } catch {
        adopted = false;
        decision = baseline;
        logging = "unavailable";
      }
    }

    return {
      status: "answered",
      question_set: questionSet,
      candidate: normalized.answer,
      confidence,
      confident: confidence >= CONFIDENCE_THRESHOLD,
      score: normalized.score ?? null,
      probability: normalized.probability ?? null,
      decision,
      adopted,
      rollout_ready: ready,
      sample_count: history.length,
      agreement_rate: history.length ? history.filter((row) => row.agreement).length / history.length : null,
      logging,
    };
  } catch {
    return fallbackResult(questionSet, state, "request-failed");
  }
}

async function readStdin() {
  let value = "";
  for await (const chunk of process.stdin) value += chunk;
  return JSON.parse(value);
}

async function main(argv) {
  if (argv[0] === "record-adoption") {
    const questionSet = argv[1];
    const input = await readStdin();
    await recordAdoption({ questionSet, eventId: input.event_id, candidate: input.candidate, confidence: input.confidence });
    process.stdout.write(`${JSON.stringify({ status: "recorded", question_set: questionSet, mode: "active" })}\n`);
    return;
  }
  if (argv[0] === "record") {
    const questionSet = argv[1];
    const input = await readStdin();
    const result = await recordShadowComparison({
      questionSet,
      eventId: input.event_id,
      candidate: input.candidate,
      confidence: input.confidence,
      currentDecision: input.currentDecision,
      forceShadow: input.force_shadow === true,
    });
    process.stdout.write(`${JSON.stringify({ status: "recorded", question_set: questionSet, ...result })}\n`);
    return;
  }

  const questionSet = argv[0];
  if (!questionSet) throw new Error("missing question set");
  const state = await readStdin();
  const result = await judge({ questionSet, state });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(() => {
    process.stdout.write(`${JSON.stringify({ status: "fallback", reason: "invalid-input", adopted: false })}\n`);
  });
}
