import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, expect, test } from "vitest";

import { parseFlags, formatStepReply, sendCommand } from "../../qa/drive.mjs";
import { EventBuffer } from "../../qa/events.mjs";
import {
  appendRecord,
  attachListeners,
  bodyLength,
  createCommandServer,
  createRegistry,
  executeStep,
  handleLine,
  hasUploadRef,
  parseDriverArgs,
  prepareSocketPath,
  registerStep,
  setupRecord,
  stepsPath,
  trimSnapshot,
  uploadFilePath
} from "../../qa/driver.mjs";

// The browser is not started here: the socket protocol, the command table and
// the record shape are what this step owns, and all three are reachable
// without Chromium. A real browser launch is proven by the launcher's smoke.

const temporary = [];

function temporaryDirectory() {
  const directory = mkdtempSync(join(tmpdir(), "qa-driver-test-"));

  temporary.push(directory);

  return directory;
}

afterEach(() => {
  while (temporary.length > 0) {
    rmSync(temporary.pop(), { recursive: true, force: true });
  }
});

test("parseDriverArgs requires a run directory and reads the headed flag", () => {
  expect(parseDriverArgs(["--run", "/tmp/run", "--headed"])).toEqual({
    runDir: "/tmp/run",
    headed: true
  });
  expect(parseDriverArgs(["--run", "/tmp/run"])).toEqual({ runDir: "/tmp/run", headed: false });
  expect(() => parseDriverArgs([])).toThrow(/--run is required/);
  expect(() => parseDriverArgs(["--nope"])).toThrow(/unknown argument/);
});

test("parseFlags reads pairs, booleans and bare words", () => {
  expect(
    parseFlags(["JRNY-001/import", "--run", "/tmp/run", "--headed"], ["headed"])
  ).toEqual({
    _: ["JRNY-001/import"],
    run: "/tmp/run",
    headed: true
  });
});

test("the setup record is a setup line with no step number", () => {
  const record = setupRecord("/tmp/run", true, "2026-01-01T00:00:00.000Z");

  expect(record).toEqual({
    kind: "setup",
    run: "/tmp/run",
    t: "2026-01-01T00:00:00.000Z",
    action: "sign-in",
    ok: true
  });
  expect(record.n).toBeUndefined();
});

test("appendRecord writes one JSON object per line", () => {
  const runDir = temporaryDirectory();

  appendRecord(runDir, setupRecord(runDir, true, "t1"));
  appendRecord(runDir, setupRecord(runDir, false, "t2"));

  const lines = readFileSync(stepsPath(runDir), "utf8").trim().split("\n");

  expect(lines).toHaveLength(2);
  expect(lines.map(line => JSON.parse(line))).toEqual([
    { kind: "setup", run: runDir, t: "t1", action: "sign-in", ok: true },
    { kind: "setup", run: runDir, t: "t2", action: "sign-in", ok: false }
  ]);
});

test("a later step registers a command without changing the loop", async () => {
  const registry = createRegistry().register("status", () => ({ ok: true, code: 0, ready: true }));
  registry.register("step", () => ({ ok: true, code: 0, n: 1 }));

  expect(registry.commands()).toEqual(["status", "step"]);
  await expect(handleLine('{"cmd":"status"}', registry)).resolves.toEqual({
    ok: true,
    code: 0,
    ready: true
  });
  await expect(handleLine('{"cmd":"step"}', registry)).resolves.toMatchObject({ n: 1 });
});

test("a malformed line and an unknown command answer instead of throwing", async () => {
  const registry = createRegistry().register("close", () => ({ ok: true, code: 0 }));

  await expect(handleLine("not json", registry)).resolves.toMatchObject({ ok: false, code: 2 });
  await expect(handleLine('{"cmd":"step"}', registry)).resolves.toMatchObject({
    ok: false,
    code: 2,
    error: expect.stringContaining("unknown command")
  });
});

test("a throwing handler becomes a harness error reply", async () => {
  const registry = createRegistry().register("boom", () => {
    throw new Error("the browser is gone");
  });

  await expect(handleLine('{"cmd":"boom"}', registry)).resolves.toEqual({
    ok: false,
    code: 2,
    error: "the browser is gone"
  });
});

test("a command travels over the socket and its reply comes back", async () => {
  const socketPath = join(temporaryDirectory(), "driver.sock");
  const registry = createRegistry().register("status", command => ({
    ok: true,
    code: 0,
    run: command.run
  }));
  const server = createCommandServer({ socketPath, registry });

  await new Promise(resolve => server.once("listening", resolve));

  try {
    await expect(sendCommand(socketPath, { cmd: "status", run: "/tmp/run" })).resolves.toEqual({
      ok: true,
      code: 0,
      run: "/tmp/run"
    });
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test("an unreachable socket is a harness error rather than a hang", async () => {
  const reply = await sendCommand(join(temporaryDirectory(), "absent.sock"), { cmd: "status" }, {
    timeoutMs: 2_000
  });

  expect(reply).toMatchObject({ ok: false, code: 2 });
  expect(reply.error).toBeTruthy();
});

test("a stale socket file is removed and a live one is refused", async () => {
  const socketPath = join(temporaryDirectory(), "driver.sock");
  const server = createCommandServer({
    socketPath,
    registry: createRegistry().register("status", () => ({ ok: true, code: 0 }))
  });

  await new Promise(resolve => server.once("listening", resolve));

  try {
    await expect(prepareSocketPath(socketPath)).rejects.toThrow(/already listening/);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }

  // The path survives a close that did not remove it, which is exactly the
  // leftover the next run has to clear.
  await expect(prepareSocketPath(socketPath)).resolves.toBe(true);
  await expect(prepareSocketPath(join(temporaryDirectory(), "never.sock"))).resolves.toBe(false);
});
// A page stand-in for the step executor. It answers the calls the executor
// makes and nothing else, and counts them, so a step that must not reach the
// browser can be proven not to. `page.evaluate` is recognised by function
// identity: the quiet probe is `bodyLength`, anything else is the page facts.
// `upload` shapes the page the upload executor meets: `ref` is whether the
// chooser's input carries a LiveView upload ref, `listed` whether the page ever
// shows the file's name, and `downloads` are the files the page hands over
// while the step acts.
function fakePage({
  url = "http://localhost:4001/gtfs/1/import",
  fail = null,
  liveView = "settles",
  ref = true,
  listed = true,
  downloads = []
} = {}) {
  const calls = [];
  const facts = {
    headings: ["Import a feed"],
    announcements: [{ role: "alert", text: "Name is already taken" }],
    focused: { role: "link", name: "GTFS" },
    hrefs: ["/gtfs/1/export", "/gtfs/1/import"],
    // What the page's own text already says, so a confirmation can pass on the
    // text the page had rather than on a file this step set.
    pageText: "Feed files"
  };

  const locator = (kind, target) => ({
    click: async () => {
      calls.push(`${kind}:${JSON.stringify(target)}`);

      for (const name of downloads) emit("download", name);

      if (fail !== null) throw new Error(fail);
    },
    fill: async () => calls.push(`${kind}:${JSON.stringify(target)}`),
    selectOption: async () => calls.push(`${kind}:${JSON.stringify(target)}`),
    waitFor: async () => calls.push(`${kind}:${JSON.stringify(target)}`),
    count: async () => 2,
    nth: () => ({
      evaluate: async () => "Import"
    }),
    ariaSnapshot: async () => "- heading \"Import a feed\" [level=1]"
  });

  // The input a chooser hands back; its ref is what the upload waits for.
  const input = { getAttribute: name => (ref ? `${name}-ref` : null) };
  const chooser = {
    element: async () => input,
    setFiles: async path => {
      calls.push(`setFiles:${path}`);

      if (listed) files.add(String(path).split("/").pop());
    }
  };
  const files = new Set();
  // The page's own event handlers, so a download can be raised while a step is
  // acting and reach the driver's own listener rather than a stand-in for it.
  const handlers = new Map();

  const emit = (name, payload) => {
    const value = typeof payload === "string" ? download(payload) : payload;

    for (const handler of handlers.get(name) ?? []) handler(value);
  };

  // A download that saves itself after a turn of the event loop, so a caller
  // that builds a record before the save lands is observably wrong.
  const download = name => ({
    suggestedFilename: () => name,
    saveAs: async path => {
      await new Promise(resolve => setTimeout(resolve, 1));

      writeFileSync(path, "zip");
      calls.push(`saved:${path}`);
    }
  });

  return {
    calls,
    url: () => url,
    getByRole: (role, options) => locator(`role:${role}`, options),
    getByText: (text, options) => locator("text", { text, options }),
    getByLabel: (label, options) => locator(`label:${label}`, options),
    locator: () => locator("body", null),
    keyboard: { press: async () => calls.push("press") },
    mouse: { wheel: async () => calls.push("scroll") },
    goto: async href => {
      calls.push(`goto:${href}`);

      if (fail !== null) throw new Error(fail);
    },
    goBack: async () => calls.push("back"),
    title: async () => "GTFS Planner",
    screenshot: async ({ path }) => calls.push(`screenshot:${path}`),
    waitForSelector: async () => {
      if (liveView === "never") throw new Error("no LiveView on this page");
    },
    waitForEvent: async name => {
      calls.push(`waitFor:${name}`);

      return chooser;
    },
    waitForFunction: async (fn, arg) => {
      if (fn === hasUploadRef) {
        calls.push(`waitRef:${fn(arg)}`);

        if (!fn(arg)) throw new Error("the input carries no upload ref");

        return;
      }

      if (typeof arg === "string") {
        calls.push(`waitText:${arg}`);

        if (!files.has(arg) && !facts.pageText.includes(arg)) {
          throw new Error(`the page never lists ${arg}`);
        }

        return;
      }

      if (liveView === "never") throw new Error("the LiveView never reconnected");
    },
    waitForTimeout: async () => {},
    evaluate: async fn => (fn === bodyLength ? 42 : facts),
    on: (name, handler) => {
      handlers.set(name, [...(handlers.get(name) ?? []), handler]);
    },
    emit: (name, payload) => emit(name, payload)
  };
}

function fakeState(page, runDir) {
  return {
    session: { run: runDir, port: 4001, scenario: "JRNY-001/import" },
    scenario: { startPath: "/", files: ["sample-feed.zip"] },
    page,
    buffer: new EventBuffer(),
    downloads: [],
    attempt: 0,
    observedHrefs: new Set(),
    url: "http://localhost:4001/gtfs/1/import"
  };
}

function stepRecords(runDir) {
  return readFileSync(stepsPath(runDir), "utf8")
    .trim()
    .split("\n")
    .map(line => JSON.parse(line));
}

test("a rejected step is recorded and never reaches the page", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage();
  const reply = await executeStep(fakeState(page, runDir), {
    flags: { action: "click", selector: "#import-form", intent: "start", expect: "the form" }
  });

  expect(reply).toMatchObject({ ok: false, code: 1, n: 1, observation: null });
  expect(reply.rejected).toMatch(/selector is not in the vocabulary/);
  expect(page.calls).toEqual([]);

  const [record] = stepRecords(runDir);

  expect(record).toMatchObject({
    kind: "step",
    run: runDir,
    n: 1,
    action: "click",
    ok: false,
    rejected: expect.stringContaining("selector is not in the vocabulary"),
    capture: null
  });
  expect(record.intent).toBe("start");
  expect(record.expected).toBe("the form");
});

test("a step records contract C-5 fields and returns the observation", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage();
  const state = fakeState(page, runDir);
  const reply = await executeStep(state, {
    flags: { action: "click", role: "link", name: "Export", intent: "open export", expect: "the form" }
  });

  expect(reply).toMatchObject({ ok: true, code: 0, n: 1, error: null });
  expect(reply.observation).toMatchObject({
    url: "/gtfs/1/import",
    title: "GTFS Planner",
    headings: ["Import a feed"],
    alerts: [{ role: "alert", text: "Name is already taken" }],
    focused: { role: "link", name: "GTFS" },
    consoleErrors: { count: 0 },
    httpErrors: { count: 0 }
  });
  expect(reply.observation.screenshot).toMatch(/captures\/s001\.png$/);

  const [record] = stepRecords(runDir);

  expect(record).toEqual({
    kind: "step",
    run: runDir,
    n: 1,
    t: expect.any(String),
    action: "click",
    target: { role: "link", name: "Export" },
    intent: "open export",
    expected: "the form",
    urlBefore: "http://localhost:4001/gtfs/1/import",
    urlAfter: "/gtfs/1/import",
    ok: true,
    rejected: false,
    error: null,
    ms: expect.any(Number),
    capture: reply.observation.screenshot,
    consoleErrors: 0,
    httpErrors: 0,
    alerts: [{ role: "alert", text: "Name is already taken" }],
    downloads: []
  });
});

test("a page link seen during a step becomes a goto the validation accepts", async () => {
  const runDir = temporaryDirectory();
  const state = fakeState(fakePage(), runDir);

  await executeStep(state, { flags: { action: "look" } });

  const reply = await executeStep(state, { flags: { action: "goto", path: "/gtfs/1/export" } });

  expect(reply).toMatchObject({ ok: true, code: 0, n: 2 });
  expect(state.observedHrefs.has("/gtfs/1/export")).toBe(true);
});

test("a goto the run has not seen is rejected without reaching the page", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage();
  const reply = await executeStep(fakeState(page, runDir), {
    flags: { action: "goto", path: "/organizations/9" }
  });

  expect(reply).toMatchObject({ ok: false, code: 1 });
  expect(reply.rejected).toMatch(/neither the start path nor an observed href/);
  expect(page.calls).toEqual([]);
});

test("a failing action reports its first line and the names the page does use", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage({ fail: "locator.click: Timeout 30000ms exceeded\nCall log:\n  - waiting for getByRole" });
  const reply = await executeStep(fakeState(page, runDir), {
    flags: { action: "click", role: "link", name: "Expor", intent: "open export", expect: "the form" }
  });

  expect(reply).toMatchObject({ ok: false, code: 1 });
  expect(reply.error).toBe(
    "locator.click: Timeout 30000ms exceeded (link names here: Import, Import)"
  );
  expect(reply.record.error).toBe(reply.error);
  expect(stepRecords(runDir)[0]).toMatchObject({ ok: false, rejected: false, error: reply.error });
});

test("a page that never reconnects still completes the step and its observation", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage({ liveView: "never" });
  const reply = await executeStep(fakeState(page, runDir), {
    flags: { action: "click", text: "Import", intent: "start", expect: "the form" }
  });

  expect(reply).toMatchObject({ ok: true, code: 0 });
  expect(reply.observation.url).toBe("/gtfs/1/import");
});

test("a recorded step runs through the same executor without an intent or expectation", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage();
  const reply = await executeStep(fakeState(page, runDir), {
    flags: { action: "click", role: "link", name: "Export" },
    requireIntent: false
  });

  expect(reply).toMatchObject({ ok: true, code: 0 });
  expect(reply.record).toMatchObject({ intent: "", expected: "", ok: true });

  // The same flags through the live path are still rejected, so the exemption
  // is the caller's and not the executor's.
  const live = await executeStep(fakeState(fakePage(), runDir), {
    flags: { action: "click", role: "link", name: "Export" }
  });

  expect(live).toMatchObject({ ok: false, code: 1 });
  expect(live.rejected).toMatch(/click needs --intent/);
});

test("the step handler is a registry entry like every other driver command", async () => {
  const runDir = temporaryDirectory();
  const state = fakeState(fakePage(), runDir);
  const registry = registerStep(createRegistry(), state);

  await expect(handleLine('{"cmd":"step","action":"look"}', registry)).resolves.toMatchObject({
    ok: true,
    code: 0,
    n: 1
  });
});

test("an upload waits for the upload ref, sets the file and confirms the entry", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage();
  const reply = await executeStep(fakeState(page, runDir), {
    flags: {
      action: "upload",
      text: "Choose a .zip file",
      file: "sample-feed.zip",
      intent: "give the page a feed",
      expect: "the file listed"
    }
  });

  expect(reply).toMatchObject({ ok: true, code: 0, n: 1, error: null });

  const chooser = page.calls.indexOf("waitFor:filechooser");
  const ref = page.calls.indexOf("waitRef:true");
  const set = page.calls.findIndex(call => call.startsWith("setFiles:"));
  const listed = page.calls.indexOf("waitText:sample-feed.zip");

  // The chooser is awaited with the click that opens it, the ref is waited for
  // before the file is set, and the page's own listing is what confirms it.
  expect(chooser).toBeGreaterThan(-1);
  expect(ref).toBeGreaterThan(chooser);
  expect(set).toBeGreaterThan(ref);
  expect(listed).toBeGreaterThan(set);
  expect(page.calls[set]).toMatch(/test\/fixtures\/gtfs\/ux_qa\/sample-feed\.zip$/);
});

test("an upload the page never lists is retried three times and then fails", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage({ listed: false });
  const reply = await executeStep(fakeState(page, runDir), {
    flags: {
      action: "upload",
      text: "Choose a .zip file",
      file: "sample-feed.zip",
      intent: "give the page a feed",
      expect: "the file listed"
    }
  });

  expect(reply).toMatchObject({ ok: false, code: 1, n: 1 });
  expect(reply.error).toBe("the file name did not appear after 3 attempts");
  expect(reply.record).toMatchObject({ ok: false, rejected: false, downloads: [] });
  expect(page.calls.filter(call => call === "waitFor:filechooser")).toHaveLength(3);
});

test("an input with no upload ref yet is waited for, not raced", async () => {
  const runDir = temporaryDirectory();
  const page = fakePage({ ref: false });
  const reply = await executeStep(fakeState(page, runDir), {
    flags: {
      action: "upload",
      text: "Choose a .zip file",
      file: "sample-feed.zip",
      intent: "give the page a feed",
      expect: "the file listed"
    }
  });

  expect(reply).toMatchObject({ ok: false, code: 1 });
  expect(page.calls.some(call => call.startsWith("setFiles:"))).toBe(false);
  expect(page.calls.filter(call => call.startsWith("waitRef:"))).toEqual([
    "waitRef:false",
    "waitRef:false",
    "waitRef:false"
  ]);
});

test("a file name outside the upload folder is refused before the page is touched", async () => {
  expect(uploadFilePath("sample-feed.zip", "/repo")).toBe("/repo/test/fixtures/gtfs/ux_qa/sample-feed.zip");
  expect(() => uploadFilePath("../secret.env", "/repo")).toThrow(
    /upload --file ..\/secret.env is not a file of test\/fixtures\/gtfs\/ux_qa/
  );
  expect(() => uploadFilePath("/etc/passwd", "/repo")).toThrow(/is not a file of/);
});

test("a download is saved into the run and awaited before the observation", async () => {
  const runDir = temporaryDirectory();
  mkdirSync(join(runDir, "downloads"), { recursive: true });
  const page = fakePage({ downloads: ["feed.zip"] });
  const state = fakeState(page, runDir);

  attachListeners(state);

  const reply = await executeStep(state, {
    flags: { action: "click", text: "Export", intent: "download the feed", expect: "the file" }
  });

  const saved = join(runDir, "downloads", "feed.zip");

  expect(readFileSync(saved, "utf8")).toBe("zip");
  expect(reply.observation.downloads).toEqual(["feed.zip"]);
  expect(reply.record.downloads).toEqual(["feed.zip"]);
  // The save is awaited before the capture, so a record never names a file
  // that is not on disk yet.
  expect(page.calls.indexOf(`saved:${saved}`)).toBeLessThan(
    page.calls.findIndex(call => call.startsWith("screenshot:"))
  );
  expect(state.downloads).toEqual([]);
});

test("a download that cannot be saved fails the step that produced it", async () => {
  const runDir = temporaryDirectory();
  mkdirSync(join(runDir, "downloads"), { recursive: true });
  const page = fakePage();
  const state = fakeState(page, runDir);

  attachListeners(state);
  page.emit("download", {
    suggestedFilename: () => "feed.zip",
    saveAs: async () => {
      throw new Error("no space left on device");
    }
  });

  const reply = await executeStep(state, {
    flags: { action: "click", text: "Export", intent: "download the feed", expect: "the file" }
  });

  expect(reply).toMatchObject({ ok: false, code: 1 });
  expect(reply.error).toBe("the download feed.zip did not save: no space left on device");
});

test("trimSnapshot keeps a prefix and marks it as truncated", () => {
  expect(trimSnapshot("short", 100)).toBe("short");
  expect(trimSnapshot("abcdef", 3)).toBe("abc [truncated]");
});

test("a step reply prints the observation as key: value lines and a screenshot", () => {
  const text = formatStepReply({
    ok: true,
    code: 0,
    n: 4,
    observation: {
      url: "/gtfs/1/import",
      title: "GTFS Planner",
      headings: ["Import a feed"],
      alerts: [{ role: "alert", text: "Name is already taken" }],
      focused: { role: "link", name: "GTFS" },
      snapshot: "- heading \"Import a feed\"",
      downloads: ["feed.zip"],
      consoleErrors: { count: 2, first: ["boom", "bang"] },
      httpErrors: { count: 0, first: [] },
      screenshot: "/run/captures/s004.png"
    }
  });

  expect(text.split("\n")).toEqual([
    "step 4: ok",
    "url: /gtfs/1/import",
    "title: GTFS Planner",
    "headings: Import a feed",
    "alerts: alert: Name is already taken",
    "focused: link: GTFS",
    'snapshot: - heading "Import a feed"',
    "downloads: feed.zip",
    "consoleErrors: 2 (boom | bang)",
    "httpErrors: 0",
    "screenshot: /run/captures/s004.png",
    ""
  ]);
});

test("a rejected or failed step prints its reason and no page", () => {
  expect(
    formatStepReply({ ok: false, code: 1, n: 9, rejected: "step limit reached", error: "step limit reached" })
  ).toBe("step 9: not ok\nrejected: step limit reached\n");

  expect(
    formatStepReply({ ok: false, code: 1, n: 3, error: "locator.click: Timeout 30000ms exceeded" })
  ).toBe("step 3: not ok\nerror: locator.click: Timeout 30000ms exceeded\n");
});
