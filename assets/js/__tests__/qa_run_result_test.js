// The tester's own records and the result they lead to (contracts C-5 and
// C-6, rules R1, R2 and R8).
//
// The claim a tester writes at `finish` is recorded and never decides anything:
// the status and the pass come from the check's exit code and the server's
// state. Both of those are driven here through the real handlers and the real
// `buildResult`, over real files in a temporary run directory, so nothing below
// stands in for the code a run actually uses.

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, expect, test } from "vitest";

import { buildResult, formatReportReply } from "../../qa/drive.mjs";
import {
  appendRecord,
  createRegistry,
  executeStep,
  handleLine,
  readRecords,
  registerFinish,
  registerNote,
  registerStep,
  stepsPath
} from "../../qa/driver.mjs";

// The step executor is not under test here, so the run records a real
// `steps.jsonl` and the handlers are registered over a state with no page:
// a note and a finish never touch the browser.
const temporary = [];

function temporaryRun() {
  const runDir = mkdtempSync(join(tmpdir(), "qa-run-result-test-"));

  temporary.push(runDir);

  return runDir;
}

function records(runDir) {
  return readFileSync(stepsPath(runDir), "utf8")
    .trim()
    .split("\n")
    .map(line => JSON.parse(line));
}

function state(runDir, attempt = 0) {
  return {
    session: { run: runDir, port: 4001, scenario: "JRNY-001/import" },
    scenario: { startPath: "/", files: [] },
    attempt,
    finish: null
  };
}

function registryFor(runDir, attempt = 0) {
  const runState = state(runDir, attempt);

  return { runState, registry: registerFinish(registerNote(registerStep(createRegistry(), runState), runState), runState) };
}

const SESSION = {
  run: "/run",
  scenario: "JRNY-001/import",
  commit: "abc123",
  dirty: false,
  startedAt: "2026-01-01T00:00:00.000Z"
};

const SCENARIO = {
  id: "JRNY-001/import",
  startPath: "/",
  entryRoute: "/gtfs/:version/import",
  referenceActions: 5,
  successCheck: { id: "import-feed", text: "one new published version" }
};

afterEach(() => {
  while (temporary.length > 0) {
    rmSync(temporary.pop(), { recursive: true, force: true });
  }
});

test("a note records what the tester saw about the last step", async () => {
  const runDir = temporaryRun();
  const { registry } = registryFor(runDir, 7);

  await expect(
    handleLine('{"cmd":"note","about":"last","observed":"the form says nothing about names","confusion":"mild"}', registry)
  ).resolves.toMatchObject({ ok: true, code: 0 });

  expect(records(runDir)).toEqual([
    {
      kind: "note",
      t: expect.any(String),
      about: 7,
      observed: "the form says nothing about names",
      confusion: "mild"
    }
  ]);
});

test("a note addresses a named step and refuses a value outside its vocabulary", async () => {
  const runDir = temporaryRun();
  const { registry } = registryFor(runDir, 7);

  await expect(handleLine('{"cmd":"note","about":"3","observed":"the list is empty"}', registry)).resolves.toMatchObject(
    { ok: true }
  );

  // An omitted confusion is none, and an omitted `about` is the last step.
  expect(records(runDir)[0]).toMatchObject({ about: 3, confusion: "none" });

  await expect(
    handleLine('{"cmd":"note","observed":"whatever","confusion":"confused"}', registry)
  ).resolves.toMatchObject({ ok: false, code: 1, error: expect.stringContaining("--confusion") });

  await expect(
    handleLine('{"cmd":"note","about":"third","observed":"whatever"}', registry)
  ).resolves.toMatchObject({ ok: false, code: 1, error: expect.stringContaining("--about") });

  await expect(handleLine('{"cmd":"note","about":"1"}', registry)).resolves.toMatchObject({
    ok: false,
    code: 1,
    error: expect.stringContaining("--observed")
  });

  // Only the note that passed was written.
  expect(records(runDir)).toHaveLength(1);
});

test("a finish records the claim once and closes the run to further steps", async () => {
  const runDir = temporaryRun();
  const { runState, registry } = registryFor(runDir, 2);

  await expect(
    handleLine('{"cmd":"finish","claim":"done","reason":"the version is listed","eyes":"host-vision"}', registry)
  ).resolves.toMatchObject({ ok: true, code: 0 });

  expect(records(runDir)[0]).toMatchObject({
    kind: "finish",
    claim: "done",
    reason: "the version is listed",
    eyes: "host-vision"
  });

  expect(runState.finish).toMatchObject({ claim: "done" });

  // A step after the finish appends nothing and says the run has finished, so
  // the log keeps one ending.
  const step = await handleLine('{"cmd":"step","action":"look"}', registry);

  expect(step).toMatchObject({ ok: false, code: 1, error: "the run has finished" });
  expect(records(runDir)).toHaveLength(1);

  await expect(handleLine('{"cmd":"finish","claim":"done"}', registry)).resolves.toMatchObject({
    ok: false,
    code: 1,
    error: "the run has finished"
  });
  expect(records(runDir)).toHaveLength(1);
});

test("a finish refuses a claim or eyes value it does not define", async () => {
  const runDir = temporaryRun();
  const { registry } = registryFor(runDir);

  await expect(handleLine('{"cmd":"finish","claim":"finished"}', registry)).resolves.toMatchObject({
    ok: false,
    code: 1,
    error: expect.stringContaining("--claim")
  });

  await expect(handleLine('{"cmd":"finish","claim":"done","eyes":"by-myself"}', registry)).resolves.toMatchObject({
    ok: false,
    code: 1,
    error: expect.stringContaining("--eyes")
  });

  // An omitted reason and eyes are null, so a run that finished without them
  // still carries the keys contract C-6 requires.
  await expect(handleLine('{"cmd":"finish","claim":"gave-up"}', registry)).resolves.toMatchObject({ ok: true });
  expect(records(runDir)[0]).toMatchObject({ claim: "gave-up", reason: null, eyes: null });
});

test("executeStep itself refuses a step on a finished run without appending", async () => {
  const runDir = temporaryRun();
  const runState = state(runDir);

  runState.finish = { kind: "finish", claim: "done" };

  const reply = await executeStep(runState, { flags: { action: "look" } });

  expect(reply).toMatchObject({ ok: false, code: 1, error: "the run has finished", record: null });
  expect(runState.attempt).toBe(0);
  expect(readRecords(runDir)).toEqual([]);
});

test("a claim of done with no action is not completed, and the check decides", () => {
  const runDir = temporaryRun();
  const { registry } = registryFor(runDir);

  return handleLine('{"cmd":"finish","claim":"done"}', registry).then(() => {
    const finished = readRecords(runDir);
    const completed = buildResult({
      session: SESSION,
      scenario: SCENARIO,
      records: finished,
      check: { id: "import-feed", pass: false, observations: [] },
      checkExit: 1,
      serverAlive: true,
      finishedAt: "2026-01-01T00:05:00.000Z"
    });

    // AC-6: the claim is copied into the file and is not an input to the
    // status or the pass.
    expect(completed).toMatchObject({
      status: "not-completed",
      claim: "done",
      check: { id: "import-feed", pass: false, observations: [] }
    });
  });
});

test("a check that printed nothing and a dead server are both harness errors", () => {
  const crashed = buildResult({
    session: SESSION,
    scenario: SCENARIO,
    records: [],
    check: null,
    checkExit: 2,
    serverAlive: true,
    finishedAt: "2026-01-01T00:05:00.000Z"
  });

  // The check's own id comes from the scenario when the check printed nothing.
  expect(crashed).toMatchObject({ status: "harness-error", check: { id: "import-feed", pass: null } });

  const dead = buildResult({
    session: SESSION,
    scenario: SCENARIO,
    records: [],
    check: { id: "import-feed", pass: true, observations: ["a new version exists"] },
    checkExit: 0,
    serverAlive: false,
    finishedAt: "2026-01-01T00:05:00.000Z"
  });

  // A server that is gone outranks a check that passed.
  expect(dead).toMatchObject({ status: "harness-error", check: { pass: null } });
});

test("a run that never finished carries nulls for the claim, the reason and the eyes", () => {
  const result = buildResult({
    session: SESSION,
    scenario: SCENARIO,
    records: [],
    check: { id: "import-feed", pass: true, observations: [] },
    checkExit: 0,
    serverAlive: true,
    finishedAt: "2026-01-01T00:05:00.000Z"
  });

  expect(result).toMatchObject({
    run: "/run",
    scenario: "JRNY-001/import",
    status: "completed",
    claim: null,
    reason: null,
    eyes: null,
    referenceActions: 5,
    stubExclusions: ["/map/tiles/", "/map/buildings"],
    commit: "abc123",
    dirty: false,
    startedAt: "2026-01-01T00:00:00.000Z",
    finishedAt: "2026-01-01T00:05:00.000Z"
  });
});

test("the result's proxies are counted from the step log, not from the claim", () => {
  const runDir = temporaryRun();
  const session = { ...SESSION, run: runDir };

  appendRecord(runDir, { kind: "setup", run: runDir, t: 1_000, action: "sign-in", ok: true });
  appendRecord(runDir, {
    kind: "step",
    run: runDir,
    n: 1,
    t: 2_000,
    action: "click",
    ok: true,
    rejected: false,
    urlBefore: "/gtfs",
    urlAfter: "/gtfs/1/import"
  });
  appendRecord(runDir, {
    kind: "step",
    run: runDir,
    n: 2,
    t: 3_000,
    action: "click",
    ok: true,
    rejected: false,
    urlBefore: "/gtfs/1/import",
    urlAfter: "/gtfs/1/import"
  });
  appendRecord(runDir, { kind: "note", t: 4_000, about: 2, observed: "the list is empty", confusion: "mild" });
  appendRecord(runDir, { kind: "finish", t: 12_000, claim: "done", reason: null, eyes: null });

  const result = buildResult({
    session,
    scenario: SCENARIO,
    records: readRecords(runDir),
    check: { id: "import-feed", pass: false, observations: [] },
    checkExit: 1,
    serverAlive: true,
    finishedAt: "2026-01-01T00:05:00.000Z"
  });

  expect(result.proxies).toMatchObject({
    actions: 2,
    observations: 0,
    scrolls: 0,
    wrongTries: 0,
    rejected: 0,
    backtracks: 0,
    endedInError: false,
    actionsToEntryRoute: 1,
    elapsedSeconds: 11
  });
  expect(result.proxies.errorsSeen).toEqual({
    banners: 0,
    httpErrors: 0,
    consoleErrors: 0,
    failedActions: 0,
    total: 0
  });
});

test("report prints the proxies as the bare object", () => {
  expect(formatReportReply({ ok: true, code: 0, proxies: { actions: 3 } })).toBe(
    `${JSON.stringify({ actions: 3 }, null, 2)}\n`
  );
  expect(formatReportReply({ ok: false, code: 2, error: "no such run" })).toBe("null\n");
});

test("a run directory with no step log reads as no records at all", () => {
  const runDir = temporaryRun();
  const file = join(runDir, "steps.jsonl");

  expect(readRecords(runDir)).toEqual([]);

  writeFileSync(file, `${JSON.stringify({ kind: "setup", t: 1, ok: true })}\n\n`, "utf8");

  expect(readRecords(runDir)).toHaveLength(1);
});
