import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "vitest";

import {
  SOCKET_PATH_LIMIT,
  gitPrimary,
  primaryCheckout,
  readSession,
  resultStatus,
  runDirName,
  runsRoot,
  socketPathFor,
  writeSession
} from "../../qa/session.mjs";

test("the primary checkout is the directory holding the reported .git", () => {
  expect(primaryCheckout("/Users/x/proj/.git")).toBe("/Users/x/proj");
});

test("runs live under the primary checkout's .specs", () => {
  expect(runsRoot("/Users/x/proj")).toBe("/Users/x/proj/.specs/ux-qa/runs");
});

test("a run started from this worktree resolves the primary checkout", () => {
  const commonDir = execFileSync(
    "git",
    ["rev-parse", "--path-format=absolute", "--git-common-dir"],
    { encoding: "utf8" }
  ).trim();

  const primary = gitPrimary();

  expect(primary).toBe(primaryCheckout(commonDir));
  expect(existsSync(join(primary, ".git"))).toBe(true);
});

test("a run directory name is a UTC stamp and the scenario ID", () => {
  expect(runDirName(new Date("2026-09-30T19:08:05Z"), "JRNY-001/import")).toBe(
    "20260930T190805Z-JRNY-001-import"
  );
});

test("the socket path stays inside the platform limit for a long run directory", () => {
  const runDir = `/Users/x/proj/.specs/ux-qa/runs/${"a".repeat(160)}`;

  expect(Buffer.byteLength(socketPathFor(runDir))).toBeLessThan(SOCKET_PATH_LIMIT);
  expect(socketPathFor(runDir)).toMatch(
    new RegExp(`^${tmpdir().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/ux-qa-[0-9a-f]{8}\\.sock$`)
  );
});

test("the same run directory always derives the same socket", () => {
  const runDir = "/Users/x/proj/.specs/ux-qa/runs/20260930T190805Z-JRNY-001-import";

  expect(socketPathFor(runDir)).toBe(socketPathFor(runDir));
  expect(socketPathFor(runDir)).not.toBe(
    socketPathFor("/Users/x/proj/.specs/ux-qa/runs/20260930T190806Z-JRNY-001-import")
  );
});

test("a check exit code and the server state map to a three-valued result", () => {
  expect(resultStatus(0)).toEqual({ status: "completed", pass: true });
  expect(resultStatus(1)).toEqual({ status: "not-completed", pass: false });
  expect(resultStatus(2)).toEqual({ status: "harness-error", pass: null });
  expect(resultStatus(null)).toEqual({ status: "harness-error", pass: null });
  expect(resultStatus(undefined)).toEqual({ status: "harness-error", pass: null });
  expect(resultStatus(1, false)).toEqual({ status: "harness-error", pass: null });
  expect(resultStatus(0, false)).toEqual({ status: "harness-error", pass: null });
});

test("a written session round-trips and leaves no temporary file", () => {
  const runDir = join(mkdtempSync(join(tmpdir(), "ux-qa-session-")), "run");
  const session = {
    run: runDir,
    scenario: "JRNY-001/import",
    port: 4123,
    socket: socketPathFor(runDir),
    dbUrl: "postgres://127.0.0.1:54321/test",
    pids: { phoenix: 111, driver: 222 },
    commit: "abc123",
    dirty: false,
    startedAt: "2026-09-30T19:08:05Z",
    maxSteps: 80,
    javaPath: "/usr/bin/java"
  };

  writeSession(runDir, session);

  expect(readSession(runDir)).toEqual(session);
  expect(readdirSync(runDir)).toEqual(["session.json"]);
});

test("rewriting a session replaces the file in place", () => {
  const runDir = join(mkdtempSync(join(tmpdir(), "ux-qa-session-")), "run");

  writeSession(runDir, { port: 4123 });
  writeSession(runDir, { port: 4124, pids: { phoenix: 111, driver: null } });

  expect(readSession(runDir)).toEqual({ port: 4124, pids: { phoenix: 111, driver: null } });
  expect(readdirSync(runDir)).toEqual(["session.json"]);
});
