// Measured proxies for one tester run (rule R8).
//
// Everything the run reports about efficiency is counted here from the step
// log written by the driver, so a rating never depends on retyping a number
// and wall-clock time is reported rather than banded.
//
// The action vocabulary is read from `actions.mjs` so that "an action" and
// "a counted action" have exactly one definition for the whole harness. This
// module is pure: no browser, no filesystem, no clock.

import { COUNTED } from "./actions.mjs";

const OBSERVED = ["look", "wait"];

const ALERT_ROLE = "alert";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ALL_DIGITS = /^\d+$/;

// Collapse the parts of a URL that identify one record rather than one route,
// so two visits to the same screen produce the same pattern.
export function routePattern(path) {
  const pathname = pathnameOf(path);

  if (pathname === null) return null;

  return pathname
    .split("/")
    .map(segment => (UUID.test(segment) || ALL_DIGITS.test(segment) ? ":id" : segment))
    .join("/");
}

// A route pattern matches a path when the segment counts agree and every
// `:param` matches whatever segment the run actually reached. The query is
// ignored: a filter does not make a different route.
export function matchesRoute(pattern, path) {
  const patternPath = routePattern(pattern);
  const pathPath = routePattern(path);

  if (patternPath === null || pathPath === null) return false;

  const patternSegments = patternPath.split("/");
  const pathSegments = pathPath.split("/");

  if (patternSegments.length !== pathSegments.length) return false;

  return patternSegments.every(
    (segment, index) => segment.startsWith(":") || segment === pathSegments[index]
  );
}

export function computeProxies(records, { entryRoute = null, startPath = null } = {}) {
  const steps = records.filter(record => record.kind === "step");

  let actions = 0;
  let observations = 0;
  let scrolls = 0;
  let wrongTries = 0;
  let rejected = 0;
  let banners = 0;
  let httpErrors = 0;
  let consoleErrors = 0;
  let failedActions = 0;
  let backtracks = 0;

  // A route the run walked away from; coming back to one is a detour.
  const leftRoutes = new Set();

  let previousAlertText = null;
  let lastExecuted = null;

  for (const step of steps) {
    const wasRejected = Boolean(step.rejected);
    const wasOk = step.ok === true && !wasRejected;

    if (wasRejected) rejected += 1;
    if (!wasOk) wrongTries += 1;
    if (wasRejected) continue;

    lastExecuted = step;

    if (wasOk && COUNTED.includes(step.action)) actions += 1;
    if (wasOk && OBSERVED.includes(step.action)) observations += 1;
    if (wasOk && step.action === "scroll") scrolls += 1;

    httpErrors += countOf(step.httpErrors);
    consoleErrors += countOf(step.consoleErrors);

    for (const alert of alertsOf(step)) {
      // The same message repeated in a row is one banner the person saw, not
      // several.
      if (alert.role === ALERT_ROLE && alert.text !== previousAlertText) banners += 1;
      previousAlertText = alert.text;
    }

    if (!wasOk) failedActions += 1;

    const before = routePattern(step.urlBefore);
    const after = routePattern(step.urlAfter);

    if (before !== null && after !== null && before !== after) leftRoutes.add(before);

    if (!wasOk) continue;

    // A `back` step is already the detour; counting its destination as a
    // return too would count one step twice.
    if (step.action === "back") backtracks += 1;
    else if (after !== null && leftRoutes.has(after)) backtracks += 1;
  }

  return {
    actions,
    observations,
    scrolls,
    wrongTries,
    rejected,
    backtracks,
    errorsSeen: {
      banners,
      httpErrors,
      consoleErrors,
      failedActions,
      total: banners + httpErrors + consoleErrors + failedActions
    },
    endedInError: endsInError(lastExecuted),
    actionsToEntryRoute: actionsToEntryRoute(steps, entryRoute, startPath),
    elapsedSeconds: elapsedSeconds(records)
  };
}

// The last step the run actually executed decides whether it stopped on an
// error or recovered from one.
function endsInError(lastExecuted) {
  if (!lastExecuted) return false;

  return (
    lastExecuted.ok !== true ||
    alertsOf(lastExecuted).some(alert => alert.role === ALERT_ROLE)
  );
}

// Ok counted actions up to and including the first step that landed on the
// entry route, so the number is what the run actually spent to get there.
function actionsToEntryRoute(steps, entryRoute, startPath) {
  if (entryRoute === null || entryRoute === undefined) return null;
  if (matchesRoute(entryRoute, startPath)) return 0;

  let actions = 0;

  for (const step of steps) {
    const wasOk = step.ok === true && !step.rejected;
    const isAction = wasOk && COUNTED.includes(step.action);

    if (wasOk && matchesRoute(entryRoute, step.urlAfter)) return actions + (isAction ? 1 : 0);

    if (isAction) actions += 1;
  }

  return null;
}

// Wall-clock seconds from the first record to the finish record. Reported as a
// number and never turned into a band.
function elapsedSeconds(records) {
  const finish = records.find(record => record.kind === "finish");
  const first = records[0];

  if (!finish || !first) return 0;

  const started = instantOf(first.t);
  const finished = instantOf(finish.t);

  if (started === null || finished === null || finished < started) return 0;

  return Math.round((finished - started) / 1000);
}

// A step carries a drained `{count, first}` object from the event buffer; a
// bare number is accepted so a hand-written log stays readable.
function countOf(value) {
  if (typeof value === "number") return value;
  if (value && typeof value.count === "number") return value.count;
  return 0;
}

function alertsOf(step) {
  return Array.isArray(step.alerts) ? step.alerts : [];
}

function pathnameOf(path) {
  if (typeof path !== "string" || path === "") return null;

  try {
    return new URL(path, "http://ux-qa.local").pathname;
  } catch {
    return null;
  }
}

// `t` is epoch milliseconds from the driver; an ISO string is accepted so a
// log written by another tool still yields a number.
function instantOf(value) {
  if (typeof value === "number") return value;

  if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) {
    return Number(value);
  }

  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
  }

  return null;
}