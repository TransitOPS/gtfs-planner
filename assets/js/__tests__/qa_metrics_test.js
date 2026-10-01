import { expect, test } from "vitest";

import { computeProxies, matchesRoute, routePattern } from "../../qa/metrics.mjs";

// A step log is built by hand below and the expected number beside it is the
// hand count, so a wrong count in the module is visible in the diff.

function step(overrides) {
  return {
    kind: "step",
    run: "JRNY-001/import",
    n: 1,
    t: 0,
    action: "click",
    target: { role: "button", name: "Import feed" },
    intent: "open the importer",
    expected: "the upload form appears",
    urlBefore: "http://localhost:4002/gtfs",
    urlAfter: "http://localhost:4002/gtfs",
    ok: true,
    rejected: false,
    error: null,
    ms: 10,
    capture: null,
    consoleErrors: { count: 0, first: [] },
    httpErrors: { count: 0, first: [] },
    alerts: [],
    downloads: [],
    ...overrides
  };
}

function finish(t) {
  return { kind: "finish", claim: "done", reason: "the version appears", eyes: "instructed", t };
}

test("look, wait and scroll do not raise the action count", () => {
  const records = [
    step({ n: 1, action: "look", urlAfter: "http://localhost:4002/gtfs" }),
    step({ n: 2, action: "wait", urlBefore: "http://localhost:4002/gtfs", urlAfter: "http://localhost:4002/gtfs" }),
    step({ n: 3, action: "scroll", urlBefore: "http://localhost:4002/gtfs", urlAfter: "http://localhost:4002/gtfs" })
  ];

  const proxies = computeProxies(records, { entryRoute: "/gtfs", startPath: "/gtfs" });

  // Three steps, none of them a counted action.
  expect(proxies.actions).toBe(0);
  expect(proxies.observations).toBe(2);
  expect(proxies.scrolls).toBe(1);
  expect(proxies.wrongTries).toBe(0);
});

test("an ok counted action raises actions and observations stay separate", () => {
  const records = [
    step({ n: 1, action: "click", urlBefore: "http://localhost:4002/gtfs", urlAfter: "http://localhost:4002/versions" }),
    step({ n: 2, action: "look", urlBefore: "http://localhost:4002/versions", urlAfter: "http://localhost:4002/versions" })
  ];

  const proxies = computeProxies(records, { entryRoute: "/gtfs", startPath: "/gtfs" });

  expect(proxies.actions).toBe(1);
  expect(proxies.observations).toBe(1);
});

test("a rejected step raises rejected and wrongTries but is not an action", () => {
  const records = [
    step({ n: 1, action: "click", ok: false, rejected: "click uses --role with --name, or --text" })
  ];

  const proxies = computeProxies(records, { entryRoute: "/gtfs", startPath: "/gtfs" });

  expect(proxies.rejected).toBe(1);
  expect(proxies.wrongTries).toBe(1);
  expect(proxies.actions).toBe(0);
  expect(proxies.errorsSeen.failedActions).toBe(0);
});

test("a failed executed step is a wrong try and a failed action", () => {
  const records = [
    step({ n: 1, action: "click", ok: false, error: "no such button" })
  ];

  const proxies = computeProxies(records, { entryRoute: "/gtfs", startPath: "/gtfs" });

  expect(proxies.wrongTries).toBe(1);
  expect(proxies.errorsSeen.failedActions).toBe(1);
  expect(proxies.actions).toBe(0);
});

test("a back step and a return to a left route count as two backtracks", () => {
  const records = [
    step({ n: 1, action: "goto", urlBefore: "http://localhost:4002/", urlAfter: "http://localhost:4002/gtfs/abc/import" }),
    step({ n: 2, action: "back", urlBefore: "http://localhost:4002/gtfs/abc/import", urlAfter: "http://localhost:4002/" }),
    step({ n: 3, action: "click", urlBefore: "http://localhost:4002/", urlAfter: "http://localhost:4002/gtfs/abc/import" })
  ];

  const proxies = computeProxies(records, { entryRoute: "/gtfs/abc/import", startPath: "/" });

  // The back step is one detour and the return to the import page is the
  // second; the return is not also counted as a back.
  expect(proxies.backtracks).toBe(2);
  expect(proxies.actions).toBe(3);
});

test("staying on one route is not a backtrack", () => {
  const records = [
    step({ n: 1, action: "click", urlBefore: "http://localhost:4002/versions", urlAfter: "http://localhost:4002/versions" }),
    step({ n: 2, action: "click", urlBefore: "http://localhost:4002/versions", urlAfter: "http://localhost:4002/versions" })
  ];

  expect(computeProxies(records, {}).backtracks).toBe(0);
});

test("consecutive identical alert text counts as one banner", () => {
  const records = [
    step({ n: 1, alerts: [{ role: "alert", text: "Import failed" }] }),
    step({ n: 2, alerts: [{ role: "alert", text: "Import failed" }] }),
    step({ n: 3, alerts: [{ role: "alert", text: "Import failed" }] })
  ];

  expect(computeProxies(records, {}).errorsSeen.banners).toBe(1);
});

test("the same alert text after another alert counts again", () => {
  const records = [
    step({ n: 1, alerts: [{ role: "alert", text: "Import failed" }] }),
    step({ n: 2, alerts: [{ role: "alert", text: "Name is required" }] }),
    step({ n: 3, alerts: [{ role: "alert", text: "Import failed" }] })
  ];

  // Three banners seen, one per run of identical text.
  expect(computeProxies(records, {}).errorsSeen.banners).toBe(3);
});

test("a non-alert dialog is not counted as a banner", () => {
  const records = [step({ n: 1, alerts: [{ role: "dialog", text: "Are you sure?" }] })];

  expect(computeProxies(records, {}).errorsSeen.banners).toBe(0);
});

test("errorsSeen sums the step counts and the failed actions", () => {
  const records = [
    step({ n: 1, consoleErrors: { count: 2, first: ["a", "b"] }, httpErrors: { count: 0, first: [] } }),
    step({ n: 2, consoleErrors: { count: 1, first: ["c"] }, httpErrors: { count: 1, first: ["404 /gtfs/abc"] } }),
    step({ n: 3, action: "click", ok: false, error: "click timed out" })
  ];

  expect(computeProxies(records, {}).errorsSeen).toEqual({
    banners: 0,
    httpErrors: 1,
    consoleErrors: 3,
    failedActions: 1,
    total: 5
  });
});

test("endedInError is true when the last executed step failed", () => {
  const records = [
    step({ n: 1 }),
    step({ n: 2, action: "click", ok: false, error: "no such button" })
  ];

  expect(computeProxies(records, {}).endedInError).toBe(true);
});

test("endedInError is false after the run recovers", () => {
  const records = [
    step({ n: 1, action: "click", ok: false, error: "no such button" }),
    step({ n: 2, action: "look" })
  ];

  expect(computeProxies(records, {}).endedInError).toBe(false);
});

test("endedInError is true when the last ok step shows an alert", () => {
  const records = [
    step({ n: 1 }),
    step({ n: 2, alerts: [{ role: "alert", text: "Import failed" }] })
  ];

  expect(computeProxies(records, {}).endedInError).toBe(true);
});

test("a rejected last attempt is not what endedInError reads", () => {
  const records = [
    step({ n: 1 }),
    step({ n: 2, action: "click", ok: false, rejected: "step limit reached" })
  ];

  const proxies = computeProxies(records, {});

  expect(proxies.endedInError).toBe(false);
  expect(proxies.rejected).toBe(1);
});

test("routePattern replaces a UUID and an all-digit segment", () => {
  expect(routePattern("/gtfs/3f2504e0-4f89-11d3-9a0c-0305e82c3301/versions/42")).toBe(
    "/gtfs/:id/versions/:id"
  );
});

test("the entry route with :version matches a concrete version path", () => {
  expect(matchesRoute("/gtfs/:version/import", "/gtfs/abc/import")).toBe(true);
  expect(matchesRoute("/gtfs/:version/import", "/gtfs/abc/versions")).toBe(false);
});

test("a route pattern ignores the query string", () => {
  expect(matchesRoute("/gtfs/:version/import", "/gtfs/abc/import?tab=files")).toBe(true);
});

test("actionsToEntryRoute counts the counted actions taken to reach the entry route", () => {
  const records = [
    step({ n: 1, action: "click", urlBefore: "http://localhost:4002/gtfs", urlAfter: "http://localhost:4002/versions" }),
    step({ n: 2, action: "click", urlBefore: "http://localhost:4002/versions", urlAfter: "http://localhost:4002/versions" }),
    step({ n: 3, action: "goto", urlBefore: "http://localhost:4002/versions", urlAfter: "http://localhost:4002/gtfs/abc/import" })
  ];

  const proxies = computeProxies(records, { entryRoute: "/gtfs/:version/import", startPath: "/gtfs" });

  // Three counted actions, the third of which lands on the entry route.
  expect(proxies.actionsToEntryRoute).toBe(3);
});

test("actionsToEntryRoute is 0 when the start path is already the entry route", () => {
  const records = [
    step({ n: 1, action: "click", urlBefore: "http://localhost:4002/gtfs/abc/import", urlAfter: "http://localhost:4002/gtfs/abc/versions" })
  ];

  const proxies = computeProxies(records, { entryRoute: "/gtfs/:version/import", startPath: "/gtfs/abc/import" });

  expect(proxies.actionsToEntryRoute).toBe(0);
});

test("actionsToEntryRoute is null when the run never reaches the entry route", () => {
  const records = [
    step({ n: 1, action: "click", urlBefore: "http://localhost:4002/gtfs", urlAfter: "http://localhost:4002/versions" }),
    step({ n: 2, action: "click", urlBefore: "http://localhost:4002/versions", urlAfter: "http://localhost:4002/versions" })
  ];

  const proxies = computeProxies(records, { entryRoute: "/gtfs/:version/import", startPath: "/gtfs" });

  expect(proxies.actionsToEntryRoute).toBeNull();
});

test("elapsedSeconds is the rounded span from the first record to the finish", () => {
  const records = [
    { kind: "setup", run: "JRNY-001/import", t: 1_700_000_000_000, action: "sign-in", ok: true },
    step({ n: 1, t: 1_700_000_001_000 }),
    step({ n: 2, t: 1_700_000_004_600 }),
    finish(1_700_000_009_400)
  ];

  expect(computeProxies(records, {}).elapsedSeconds).toBe(9);
});

test("elapsedSeconds is 0 when the run never finished", () => {
  const records = [
    { kind: "setup", run: "JRNY-001/import", t: 1_700_000_000_000, action: "sign-in", ok: true },
    step({ n: 1, t: 1_700_000_004_600 })
  ];

  expect(computeProxies(records, {}).elapsedSeconds).toBe(0);
});

test("notes are not steps and do not change the proxies", () => {
  const records = [
    step({ n: 1 }),
    { kind: "note", about: "the import button", observed: "labelled Import feed", confusion: "none" }
  ];

  expect(computeProxies(records, {}).actions).toBe(1);
});