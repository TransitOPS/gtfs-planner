import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, expect, test } from "vitest";

import { parseFlags, sendCommand } from "../../qa/drive.mjs";
import {
  appendRecord,
  createCommandServer,
  createRegistry,
  handleLine,
  parseDriverArgs,
  prepareSocketPath,
  setupRecord,
  stepsPath
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