import { expect, test } from "vitest";

import { MAX_STEPS, validateStep } from "../../qa/actions.mjs";

const ctx = {
  attempt: 1,
  startPath: "/gtfs/import",
  observedHrefs: new Set(["/gtfs/import", "/gtfs/v1/stations"]),
  files: ["sample-feed.zip"]
};

test("a click addressed by a selector flag is rejected", () => {
  const result = validateStep({ action: "click", selector: "#firstuse-import" }, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("selector");
});

test("a click whose name is selector syntax is rejected", () => {
  const result = validateStep({ action: "click", role: "button", name: "css=.btn" }, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("--name");
});

test("a goto to a path that was never observed is rejected", () => {
  const result = validateStep({ action: "goto", path: "/gtfs/abc/import" }, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("observed href");
});

test("a goto to an observed href is accepted", () => {
  const result = validateStep({ action: "goto", path: "/gtfs/v1/stations" }, ctx);

  expect(result.ok).toBe(true);
  expect(result.step).toEqual({ action: "goto", path: "/gtfs/v1/stations" });
});

test("a goto to the scenario start path is accepted", () => {
  const result = validateStep({ action: "goto", path: "/gtfs/import" }, ctx);

  expect(result.ok).toBe(true);
  expect(result.step.path).toBe("/gtfs/import");
});

test("a goto path is normalized without its fragment", () => {
  const result = validateStep({ action: "goto", path: "/gtfs/import#upload" }, ctx);

  expect(result.ok).toBe(true);
  expect(result.step.path).toBe("/gtfs/import");
});

test("a goto on a foreign origin is rejected however well its path matches", () => {
  const result = validateStep({ action: "goto", path: "https://evil.example/gtfs/v1/stations" }, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("origin");
});

test("a goto on the origin the run has navigated is accepted", () => {
  const observed = {
    attempt: 1,
    startPath: "/gtfs/import",
    observedHrefs: new Set(["http://localhost:4001/gtfs/v1/stations"]),
    files: []
  };
  const result = validateStep({ action: "goto", path: "http://localhost:4001/gtfs/v1/stations" }, observed);

  expect(result.ok).toBe(true);
  expect(result.step.path).toBe("http://localhost:4001/gtfs/v1/stations");
});

test("a click without an expectation is rejected", () => {
  const click = { action: "click", role: "button", name: "Import feed", intent: "start it" };
  const result = validateStep(click, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("--expect");
});

test("a fill without an intent is rejected", () => {
  const fill = { action: "fill", label: "Feed name", value: "sample", expect: "the field holds it" };
  const result = validateStep(fill, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("--intent");
});

test("a fill carries its value into the step", () => {
  const fill = {
    action: "fill",
    label: "Version name",
    value: "QA Import",
    intent: "name the new version",
    expect: "the field holds the name"
  };
  const result = validateStep(fill, ctx);

  expect(result.ok).toBe(true);
  expect(result.step).toEqual({ action: "fill", label: "Version name", value: "QA Import" });
});

test("a fill without a value is rejected with a reason the tester can act on", () => {
  const fill = { action: "fill", label: "Version name", intent: "name it", expect: "it is named" };
  const result = validateStep(fill, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("--value");
});

test("an upload of a file outside the scenario is rejected", () => {
  const upload = {
    action: "upload",
    text: "Choose a .zip file",
    file: "other-feed.zip",
    intent: "supply the feed",
    expect: "the file name appears"
  };
  const result = validateStep(upload, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("not a file of this scenario");
});

test("an upload of a scenario file is accepted", () => {
  const upload = {
    action: "upload",
    text: "Choose a .zip file",
    file: "sample-feed.zip",
    intent: "supply the feed",
    expect: "the file name appears"
  };
  const result = validateStep(upload, ctx);

  expect(result.ok).toBe(true);
  expect(result.step.file).toBe("sample-feed.zip");
});

test("attempt 81 is rejected as the step limit", () => {
  const result = validateStep({ action: "look" }, { ...ctx, attempt: MAX_STEPS + 1 });

  expect(result.ok).toBe(false);
  expect(result.reason).toBe("step limit reached");
});

test("attempt 80 is accepted", () => {
  const result = validateStep({ action: "look" }, { ...ctx, attempt: MAX_STEPS });

  expect(result.ok).toBe(true);
  expect(result.step.action).toBe("look");
});

test("a click by role and name with an intent and an expectation is accepted", () => {
  const click = {
    action: "click",
    role: "button",
    name: "Import feed",
    intent: "start the import",
    expect: "the upload control appears"
  };
  const result = validateStep(click, ctx);

  expect(result.ok).toBe(true);
  expect(result.step).toEqual({ action: "click", role: "button", name: "Import feed" });
});

test("a wait timeout above 120 seconds is rejected", () => {
  const result = validateStep({ action: "wait", text: "done", timeout: "200" }, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("120");
});

test("a wait without a timeout uses the 30 second default", () => {
  const result = validateStep({ action: "wait", text: "Import complete" }, ctx);

  expect(result.ok).toBe(true);
  expect(result.step.timeout).toBe(30);
});

test("an action outside the vocabulary is rejected", () => {
  const result = validateStep({ action: "evaluate", path: "/gtfs/import" }, ctx);

  expect(result.ok).toBe(false);
  expect(result.reason).toContain("unknown action");
});