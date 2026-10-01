// Vocabulary and limits for a tester (person or script).
//
// This module is the single place where a tester step is checked against the
// vocabulary. It is a pure module: it imports nothing, touches no browser and
// writes no file, so the same validation serves live steps and replay steps.

export const MAX_STEPS = 80;

export const ACTIONS = [
  "click",
  "fill",
  "select",
  "upload",
  "press",
  "goto",
  "back",
  "scroll",
  "look",
  "wait"
];

// Actions that change the application and therefore carry an intent and an
// expectation.
export const MUTATING = ["click", "fill", "select", "upload", "press"];

// Actions counted as progress toward the goal.
export const COUNTED = ["click", "fill", "select", "upload", "press", "goto", "back"];

// Flags that would address the page by structure instead of by what a person
// sees.
export const REJECTED_FLAGS = ["selector", "css", "xpath", "testid", "test-id"];

// A value starting with one of these is a selector written inside an otherwise
// acceptable flag.
export const REJECTED_PREFIXES = ["css=", "xpath=", "text=", "id=", "data-testid=", "//"];

// Flags whose value is what a person reads on the page.
export const VALUE_FLAGS = ["name", "text", "label"];

const DEFAULT_WAIT_TIMEOUT = 30;
const MAX_WAIT_TIMEOUT = 120;

function ok(step) {
  return { ok: true, step };
}

function fail(reason) {
  return { ok: false, reason };
}

function present(flags, key) {
  const value = flags[key];
  return typeof value === "string" ? value.trim() : "";
}

function wholeNumber(value) {
  return /^-?\d+$/.test(value) ? Number.parseInt(value, 10) : null;
}

// Compare a path with an observed one on pathname and query, dropping any
// fragment, so "#" anchors and absolute URLs both resolve to one route key.
function routeKey(value) {
  try {
    const url = new URL(value, "http://ux-qa.local");
    return `${url.pathname}${url.search}`;
  } catch {
    return null;
  }
}

function namedTarget(flags, action) {
  const role = present(flags, "role");
  const name = present(flags, "name");
  if (role && name) return ok({ role, name });
  const text = present(flags, "text");
  if (text) return ok({ text });
  return fail(`${action} needs --role with --name, or --text`);
}

function target(flags, action) {
  switch (action) {
    case "click":
    case "upload":
      return namedTarget(flags, action);

    case "fill": {
      const label = present(flags, "label");
      if (!label) return fail("fill needs --label");
      // The value is carried into the step, because the driver fills with it and
      // a trail records it. A fill without one is rejected here rather than left
      // to fail inside the browser with no reason a tester can act on.
      if (typeof flags.value !== "string") return fail("fill needs --value");
      return ok({ label, value: flags.value });
    }

    case "select": {
      const label = present(flags, "label");
      if (!label) return fail("select needs --label");
      const option = present(flags, "option");
      if (!option) return fail("select needs --option");
      return ok({ label, option });
    }

    case "press": {
      const key = present(flags, "key");
      if (!key) return fail("press needs --key");
      return ok({ key });
    }

    case "goto": {
      const path = present(flags, "path");
      if (!path) return fail("goto needs --path");
      return ok({ path });
    }

    case "scroll": {
      const dy = wholeNumber(present(flags, "dy"));
      if (dy === null) return fail("scroll needs a whole number for --dy");
      return ok({ dy });
    }

    case "wait": {
      const text = present(flags, "text");
      if (!text) return fail("wait needs --text");
      const raw = present(flags, "timeout");
      if (!raw) return ok({ text, timeout: DEFAULT_WAIT_TIMEOUT });
      const timeout = wholeNumber(raw);
      if (timeout === null || timeout <= 0) {
        return fail("wait --timeout must be whole seconds");
      }
      // A timeout above the maximum is rejected rather than clamped, so the
      // step log records what the tester asked for and why it did not run.
      if (timeout > MAX_WAIT_TIMEOUT) {
        return fail(`wait --timeout is at most ${MAX_WAIT_TIMEOUT} seconds`);
      }
      return ok({ text, timeout });
    }

    default:
      return ok({});
  }
}

// flags carries the action under `action` plus its parsed flags. ctx is
// { attempt, startPath, observedHrefs, files }.
export function validateStep(flags, ctx = {}) {
  const { attempt = 1, startPath = "", observedHrefs = new Set(), files = [] } = ctx;
  const action = flags?.action;

  if (!ACTIONS.includes(action)) {
    const asked = action ?? "";
    return fail(`unknown action "${asked}"; the vocabulary is ${ACTIONS.join(", ")}`);
  }

  const rejectedFlag = REJECTED_FLAGS.find(flag => flags[flag] !== undefined);
  if (rejectedFlag) {
    return fail(`${action} names page structure; ${rejectedFlag} is not in the vocabulary`);
  }

  for (const flag of VALUE_FLAGS) {
    const value = present(flags, flag);
    const prefix = REJECTED_PREFIXES.find(candidate => value.startsWith(candidate));
    if (prefix) {
      return fail(`${action} --${flag} must be visible text, not "${prefix}" selector syntax`);
    }
  }

  const targeted = target(flags, action);
  if (!targeted.ok) return targeted;
  const step = { action, ...targeted.step };

  if (action === "upload") {
    const file = present(flags, "file");
    if (!file) return fail("upload needs --file");
    if (!files.includes(file)) {
      return fail(`upload --file ${file} is not a file of this scenario`);
    }
    step.file = file;
  }

  if (action === "goto") {
    const wanted = routeKey(step.path);
    const allowed = [startPath, ...observedHrefs]
      .filter(value => typeof value === "string" && value.trim() !== "")
      .map(routeKey);
    if (wanted === null || !allowed.includes(wanted)) {
      return fail(`goto ${step.path} is neither the start path nor an observed href`);
    }
    // A relative path is stored without its fragment so the replayed step and
    // the logged step address the same route.
    if (!/^[a-z]+:\/\//i.test(step.path)) step.path = wanted;
  }

  if (MUTATING.includes(action)) {
    if (!present(flags, "intent")) return fail(`${action} needs --intent`);
    if (!present(flags, "expect")) return fail(`${action} needs --expect`);
  }

  if (attempt > MAX_STEPS) return fail("step limit reached");

  return ok(step);
}