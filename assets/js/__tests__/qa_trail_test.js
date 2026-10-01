// The recorded trail and the replay that runs it (rule R9, contract C-7).
//
// The trail is built from a real step log and the replay is executed through
// the real driver registry, so both are the code a run uses. The browser and
// git are the two boundaries replaced here: a page stand-in answers the calls
// the executor makes, and the capture root is a temporary directory the test
// declares ignored, so nothing here writes into a real checkout.

import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { afterEach, expect, test } from "vitest";

import { buildTrail, formatReplayReply } from "../../qa/drive.mjs";
import { bodyLength, createRegistry, handleLine, pruneStaleCaptures, registerReplay, stepsPath } from "../../qa/driver.mjs";
import { EventBuffer } from "../../qa/events.mjs";
import { captureRoot, journeyCapturePath } from "../../qa/captures.mjs";
import { trailFileName } from "../../qa/session.mjs";

const temporary = [];

function temporaryDirectory() {
  const directory = mkdtempSync(join(tmpdir(), "qa-trail-test-"));

  temporary.push(directory);

  return directory;
}

afterEach(() => {
  while (temporary.length > 0) {
    rmSync(temporary.pop(), { recursive: true, force: true });
  }
});

const SESSION = {
  run: "/primary/.specs/ux-qa/runs/20260101T000000Z-JRNY-001-import",
  scenario: "JRNY-001/import",
  commit: "abc123",
  dirty: false
};

// A step log of the shape a completed run writes: a setup line, the steps the
// tester took, the ones that went wrong and the ones the trail must not carry.
const RECORDS = [
  { kind: "setup", action: "sign-in", ok: true },
  { kind: "step", n: 1, action: "goto", target: { path: "/" }, ok: true, rejected: false },
  { kind: "step", n: 2, action: "click", target: { role: "button", name: "Import feed" }, ok: true, rejected: false },
  { kind: "step", n: 3, action: "look", target: {}, ok: true, rejected: false },
  { kind: "step", n: 4, action: "click", target: { role: "button", name: "Deleted" }, ok: false, rejected: false, error: "gone" },
  { kind: "step", n: 5, action: "click", target: { selector: "#import-form" }, ok: false, rejected: "selector is not in the vocabulary" },
  { kind: "step", n: 6, action: "wait", target: { text: "Feed imported", timeout: 30 }, ok: true, rejected: false },
  { kind: "note", about: 2, observed: "the form is clear" },
  { kind: "step", n: 7, action: "scroll", target: { dy: 400 }, ok: true, rejected: false },
  { kind: "step", n: 8, action: "press", target: { key: "Enter" }, ok: true, rejected: false, replay: true },
  { kind: "finish", claim: "done", reason: null, eyes: null }
];

test("a trail keeps the ok action steps of a run in order and carries their targets", () => {
  const trail = buildTrail({ session: SESSION, records: RECORDS });

  expect(trail).toEqual({
    scenario: "JRNY-001/import",
    recordedFrom: SESSION.run,
    commit: "abc123",
    steps: [
      { action: "goto", path: "/" },
      { action: "click", role: "button", name: "Import feed" },
      { action: "wait", text: "Feed imported", timeout: 30 }
    ]
  });
});

test("a replayed step is not recorded into a trail again", () => {
  const trail = buildTrail({
    session: SESSION,
    records: RECORDS.filter(record => record.kind === "step")
  });

  // `press` is the only ok action step above marked `replay`, so dropping it
  // leaves the three steps a tester actually walked.
  expect(trail.steps.map(step => step.action)).toEqual(["goto", "click", "wait"]);
});

test("a trail file is named for its scenario", () => {
  expect(trailFileName("JRNY-001/import")).toBe("JRNY-001-import.json");
  expect(trailFileName("JRNY-002/add-trip")).toBe("JRNY-002-add-trip.json");
});

// A page stand-in for the replay: it answers the executor's calls, writes the
// file each screenshot is asked for, and can be told to fail one named action
// so the drift path is reachable without a browser.
function fakePage({ failOn = null } = {}) {
  const calls = [];
  const locator = target => ({
    click: async () => {
      calls.push(`click:${JSON.stringify(target)}`);

      if (failOn !== null && JSON.stringify(target).includes(failOn)) {
        throw new Error("locator.click: Timeout 30000ms exceeded");
      }
    },
    fill: async () => calls.push("fill"),
    selectOption: async () => calls.push("select"),
    waitFor: async () => calls.push("wait"),
    count: async () => 0,
    first: () => locator({ text: "first" }),
    nth: () => ({ evaluate: async () => "" }),
    ariaSnapshot: async () => "- heading \"Import a feed\" [level=1]"
  });

  return {
    calls,
    url: () => "http://localhost:4001/",
    getByRole: (role, options) => locator({ role, ...options }),
    getByText: (text, options) => locator({ text, options }),
    getByLabel: label => locator({ label }),
    locator: () => locator("body"),
    keyboard: { press: async () => calls.push("press") },
    mouse: { wheel: async () => calls.push("scroll") },
    goto: async href => calls.push(`goto:${href}`),
    goBack: async () => calls.push("back"),
    title: async () => "GTFS Planner",
    screenshot: async ({ path }) => {
      calls.push(`screenshot:${path}`);
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, "png");
    },
    waitForSelector: async () => {},
    waitForFunction: async () => {},
    waitForTimeout: async () => {},
    evaluate: async fn => (fn === bodyLength ? 42 : { headings: [], announcements: [], focused: null, hrefs: [] }),
    on: () => {}
  };
}

function replayState(page, runDir) {
  return {
    session: { run: runDir, port: 4001, scenario: "JRNY-001/import" },
    scenario: { id: "JRNY-001/import", slug: "import", startPath: "/", files: [] },
    page,
    buffer: new EventBuffer(),
    downloads: [],
    attempt: 0,
    observedHrefs: new Set(),
    url: "http://localhost:4001/",
    finish: null
  };
}

function replayRegistry(page, runDir, primary, { ignored = true } = {}) {
  const state = replayState(page, runDir);

  return registerReplay(createRegistry(), state, {
    primary: () => primary,
    isIgnored: () => ignored
  });
}

function records(runDir) {
  return readFileSync(stepsPath(runDir), "utf8")
    .trim()
    .split("\n")
    .map(line => JSON.parse(line));
}

const TRAIL = {
  scenario: "JRNY-001/import",
  recordedFrom: SESSION.run,
  commit: "abc123",
  steps: [
    { action: "click", role: "button", name: "Import feed" },
    { action: "wait", text: "Feed imported", timeout: 30 }
  ]
};

test("a replay runs the trail's steps through the executor and captures each one", async () => {
  const runDir = temporaryDirectory();
  const primary = temporaryDirectory();
  const page = fakePage();
  const registry = replayRegistry(page, runDir, primary);

  const reply = await handleLine(JSON.stringify({ cmd: "replay", trail: TRAIL }), registry);

  expect(reply).toEqual({ ok: true, code: 0, steps: 2, pruned: [] });
  expect(page.calls.filter(call => call === "wait")).toHaveLength(1);

  const root = captureRoot(primary);

  // Each step's capture is the capture-root path rule of R4, numbered by the
  // trail step rather than by the run.
  for (const n of [1, 2]) {
    const path = journeyCapturePath(root, "JRNY-001/import", n);

    expect(readFileSync(path, "utf8")).toBe("png");
  }

  const written = records(runDir);

  expect(written).toHaveLength(2);
  expect(written[0]).toMatchObject({
    kind: "step",
    n: 1,
    action: "click",
    target: { role: "button", name: "Import feed" },
    replay: true,
    ok: true,
    capture: journeyCapturePath(root, "JRNY-001/import", 1)
  });
  // A replayed step needs no intent and no expectation, and its record says so
  // rather than carrying a stand-in for either.
  expect(written[0].intent).toBe("");
  expect(written[0].expected).toBe("");
});

test("the first failing step stops the replay, names itself and saves a screenshot", async () => {
  const runDir = temporaryDirectory();
  const primary = temporaryDirectory();
  const page = fakePage({ failOn: "Deleted" });
  const registry = replayRegistry(page, runDir, primary);

  const reply = await handleLine(
    JSON.stringify({
      cmd: "replay",
      trail: {
        scenario: "JRNY-001/import",
        steps: [
          { action: "click", role: "button", name: "Import feed" },
          { action: "click", role: "button", name: "Deleted" },
          { action: "click", role: "button", name: "Save" }
        ]
      }
    }),
    registry
  );

  expect(reply.ok).toBe(false);
  expect(reply.code).toBe(1);
  expect(reply.failedStep).toBe(2);
  expect(reply.error).toMatch(/Timeout 30000ms exceeded/);
  expect(reply.screenshot).toBe(join(runDir, "captures", "fail-s002.png"));
  expect(readFileSync(reply.screenshot, "utf8")).toBe("png");

  // The step after the failure never ran, which is what makes this a drift
  // detector rather than an exploration.
  expect(page.calls.some(call => call.includes("Save"))).toBe(false);
  expect(records(runDir)).toHaveLength(2);

  // A drifted replay does not prune the steps it did reach: the captures of
  // the earlier trail stay as evidence.
  expect(readdirSync(dirname(journeyCapturePath(captureRoot(primary), "JRNY-001/import", 1)))).toHaveLength(2);
});

test("a drifted replay prunes the steps a shorter trail no longer has", async () => {
  const runDir = temporaryDirectory();
  const primary = temporaryDirectory();
  const folder = dirname(journeyCapturePath(captureRoot(primary), "JRNY-001/import", 1));

  mkdirSync(folder, { recursive: true });

  // What a previous, longer run of the same scenario left behind.
  for (const name of ["import-s001.png", "import-s002.png", "import-s003.png", "import-s004.png"]) {
    writeFileSync(join(folder, name), "png");
  }

  const registry = replayRegistry(fakePage({ failOn: "Deleted" }), runDir, primary);
  const reply = await handleLine(
    JSON.stringify({
      cmd: "replay",
      trail: {
        scenario: "JRNY-001/import",
        steps: [
          { action: "click", role: "button", name: "Import feed" },
          { action: "click", role: "button", name: "Deleted" }
        ]
      }
    }),
    registry
  );

  expect(reply).toMatchObject({ ok: false, failedStep: 2 });

  // The capture folder is shared with the previous run, so a capture past the
  // shorter trail's length is stale evidence and is removed however the replay
  // left.
  expect(readdirSync(folder).sort()).toEqual(["import-s001.png", "import-s002.png"]);
});

test("a capture root that is not ignored stops the replay before its first step", async () => {
  const runDir = temporaryDirectory();
  const primary = temporaryDirectory();
  const page = fakePage();
  const registry = replayRegistry(page, runDir, primary, { ignored: false });

  const reply = await handleLine(JSON.stringify({ cmd: "replay", trail: TRAIL }), registry);

  expect(reply).toMatchObject({ ok: false, code: 2 });
  expect(reply.error).toMatch(/capture root is not git-ignored/);
  expect(page.calls).toEqual([]);
  expect(readdirSync(runDir)).toEqual([]);
});

test("a trail with no steps is refused rather than treated as a clean run", async () => {
  const runDir = temporaryDirectory();
  const registry = replayRegistry(fakePage(), runDir, temporaryDirectory());

  await expect(handleLine('{"cmd":"replay"}', registry)).resolves.toMatchObject({
    ok: false,
    code: 1,
    error: expect.stringContaining("needs a trail with a steps array")
  });
});

test("a shorter trail removes its own stale captures and no other scenario's", async () => {
  const primary = temporaryDirectory();
  const folder = dirname(journeyCapturePath(captureRoot(primary), "JRNY-001/import", 1));

  mkdirSync(folder, { recursive: true });

  for (const name of ["import-s001.png", "import-s002.png", "import-s003.png", "change-times-s004.png"]) {
    writeFileSync(join(folder, name), "png");
  }

  const runDir = temporaryDirectory();
  const registry = replayRegistry(fakePage(), runDir, primary);
  const reply = await handleLine(JSON.stringify({ cmd: "replay", trail: TRAIL }), registry);

  expect(reply).toMatchObject({ ok: true, steps: 2, pruned: ["import-s003.png"] });
  expect(readdirSync(folder).sort()).toEqual([
    "change-times-s004.png",
    "import-s001.png",
    "import-s002.png"
  ]);

  // Replaying the same trail again removes nothing: the capture set already
  // describes this trail exactly.
  const again = await handleLine(JSON.stringify({ cmd: "replay", trail: TRAIL }), registry);

  expect(again).toMatchObject({ ok: true, steps: 2, pruned: [] });
  expect(readdirSync(folder).sort()).toEqual([
    "change-times-s004.png",
    "import-s001.png",
    "import-s002.png"
  ]);
});

test("a local replay leaves the shared capture folder untouched", async () => {
  const primary = temporaryDirectory();
  const folder = dirname(journeyCapturePath(captureRoot(primary), "JRNY-001/import", 1));

  mkdirSync(folder, { recursive: true });

  for (const name of ["import-s001.png", "import-s002.png", "import-s003.png"]) {
    writeFileSync(join(folder, name), "exploration");
  }

  const runDir = temporaryDirectory();
  const registry = replayRegistry(fakePage(), runDir, primary);

  const reply = await handleLine(JSON.stringify({ cmd: "replay", trail: TRAIL, local: true }), registry);

  // The recorded exploration's captures keep their content and their count;
  // the reference trail's steps are captured in the run folder instead.
  expect(reply).toEqual({ ok: true, code: 0, steps: 2, pruned: [] });
  expect(readdirSync(folder).sort()).toEqual(["import-s001.png", "import-s002.png", "import-s003.png"]);
  expect(readFileSync(join(folder, "import-s001.png"), "utf8")).toBe("exploration");
  expect(readdirSync(join(runDir, "captures"))).toHaveLength(2);
});

test("pruning selects only this scenario's files above the new count", () => {
  const removed = [];
  // A folder that does not exist has nothing to prune: the existsSync guard
  // answers before the injected list is reached.
  const pruned = pruneStaleCaptures(join(temporaryDirectory(), "never-created"), "import", 2, {
    list: () => [],
    remove: () => removed.push("x")
  });

  expect(pruned).toEqual([]);
  expect(removed).toEqual([]);

  const folder = temporaryDirectory();
  const names = ["import-s001.png", "import-s002.png", "import-s003.png", "import-s003-alt.png", "other-s009.png"];
  const selected = pruneStaleCaptures(folder, "import", 2, {
    list: () => names,
    remove: file => removed.push(file)
  });

  expect(selected).toEqual(["import-s003.png", "import-s003-alt.png"]);
  expect(removed).toEqual([join(folder, "import-s003.png"), join(folder, "import-s003-alt.png")]);
});

test("the replay line names the drifted step, its error and its screenshot", () => {
  expect(
    formatReplayReply({
      ok: false,
      code: 1,
      failedStep: 3,
      error: "locator.click: Timeout 30000ms exceeded",
      screenshot: "/run/captures/fail-s003.png"
    })
  ).toBe("drift at step 3: locator.click: Timeout 30000ms exceeded (screenshot: /run/captures/fail-s003.png)\n");

  expect(formatReplayReply({ ok: true, code: 0, steps: 12, pruned: [] })).toBe(
    "replay ok: 12 steps, no drift\n"
  );
  expect(formatReplayReply({ ok: true, code: 0, steps: 12, pruned: ["import-s013.png"] })).toBe(
    "replay ok: 12 steps, no drift; pruned 1 stale capture\n"
  );
});
