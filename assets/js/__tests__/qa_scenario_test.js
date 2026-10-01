import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { expect, test } from "vitest";

import {
  briefText,
  loadScenarios,
  parseScenarios,
  selectScenarios,
  testerView
} from "../../qa/scenario.mjs";

// The fixtures below are literal markdown in the shape the page template's
// section 10 requires: one `### <slug>` per scenario, bullets written as
// `- **Key:** value`.

const PAGE = `---
id: JRNY-900
title: A fixture journey
---

## 9. Visual and evidence links

Nothing here is a scenario.

## 10. Test scenario

### import-feed

- **Persona:** Dispatcher at a two-bus agency.
- **Goal:** Load the Monday feed and see its stops listed.
- **Account:** editor
- **Seed:** sample-feed
- **Start path:** /
- **Files:** sample-feed.zip, second-feed.zip
- **Success check:** import-feed — one new published version holding the zip's rows
- **Reference actions:** 5
- **Entry route:** /gtfs/:version/import

The prose under the bullets is the reviewer reading, not a key.

### second

- **Persona:** Dispatcher at a two-bus agency.
- **Goal:** Rename the imported version.
- **Account:** editor
- **Seed:** blank
- **Start path:** /gtfs
- **Success check:** rename-version — the version's name changed
- **Reference actions:** 2
- **Entry route:** /gtfs/:version

## Open questions

- OQ-001 — none yet.
`;

function parse(markdown = PAGE, file = "JRNY-900-fixture.md") {
  return parseScenarios(markdown, file);
}

test("a page with a Test scenario section parses its scenarios", () => {
  const scenarios = parse();

  expect(scenarios).toHaveLength(2);

  const [first, second] = scenarios;

  expect(first.id).toBe("JRNY-900/import-feed");
  expect(first.journey).toBe("JRNY-900");
  expect(first.slug).toBe("import-feed");
  expect(first.persona).toBe("Dispatcher at a two-bus agency.");
  expect(first.goal).toBe("Load the Monday feed and see its stops listed.");
  expect(first.account).toBe("editor");
  expect(first.seed).toBe("sample-feed");
  expect(first.startPath).toBe("/");
  expect(first.files).toEqual(["sample-feed.zip", "second-feed.zip"]);
  expect(first.successCheck).toEqual({
    id: "import-feed",
    text: "one new published version holding the zip's rows"
  });
  expect(first.referenceActions).toBe(5);
  expect(first.entryRoute).toBe("/gtfs/:version/import");

  expect(second.id).toBe("JRNY-900/second");
  expect(second.files).toEqual([]);
});

test("a missing required key names the key", () => {
  const withoutCheck = PAGE.replace(
    "- **Success check:** import-feed — one new published version holding the zip's rows\n",
    ""
  );

  expect(() => parse(withoutCheck)).toThrow(
    'JRNY-900-fixture.md: scenario "import-feed" is missing required key "Success check"'
  );
});

test("an unknown key is rejected by name", () => {
  const withExtra = PAGE.replace(
    "- **Account:** editor\n",
    "- **Account:** editor\n- **Teaser:** secret\n"
  );

  expect(() => parse(withExtra)).toThrow(
    'JRNY-900-fixture.md: scenario "import-feed" has unknown key "Teaser"'
  );
});

test("a seed outside the known set is rejected", () => {
  const withSeed = PAGE.replace("- **Seed:** sample-feed\n", "- **Seed:** everything\n");

  expect(() => parse(withSeed)).toThrow(
    'JRNY-900-fixture.md: scenario "import-feed" seed must be blank or sample-feed'
  );
});

test("a non-integer reference action count is rejected", () => {
  const withCount = PAGE.replace("- **Reference actions:** 5\n", "- **Reference actions:** five\n");

  expect(() => parse(withCount)).toThrow(
    'JRNY-900-fixture.md: scenario "import-feed" reference actions must be an integer'
  );
});

test("selecting a journey returns every scenario of that journey", () => {
  const scenarios = parse();

  expect(selectScenarios(scenarios, "JRNY-900").map(scenario => scenario.id)).toEqual([
    "JRNY-900/import-feed",
    "JRNY-900/second"
  ]);

  expect(selectScenarios(scenarios, "JRNY-900/second").map(scenario => scenario.id)).toEqual([
    "JRNY-900/second"
  ]);

  expect(() => selectScenarios(scenarios, "JRNY-901")).toThrow(
    'unknown scenario journey "JRNY-901"'
  );
  expect(() => selectScenarios(scenarios, "JRNY-900/missing")).toThrow(
    'unknown scenario "JRNY-900/missing"'
  );
});

test("the brief carries the tester keys and none of the harness values", () => {
  const [scenario] = parse();
  const brief = briefText(scenario);

  expect(brief).toContain(scenario.goal);
  expect(brief).toContain("Dispatcher at a two-bus agency.");
  expect(brief).toContain("sample-feed.zip");
  expect(brief).toContain("second-feed.zip");
  expect(brief).toContain("Use only what you can see on the screen.");

  for (const harnessOnly of [
    scenario.account,
    scenario.seed,
    scenario.successCheck.id,
    scenario.successCheck.text,
    scenario.entryRoute,
    "/gtfs/:version/import",
    "Reference actions"
  ]) {
    expect(brief).not.toContain(harnessOnly);
  }

  expect(Object.keys(testerView(scenario)).sort()).toEqual([
    "files",
    "goal",
    "persona",
    "startPath"
  ]);
});

// The committed pilot pages are the parser's real inputs, so they are read from
// the repository rather than trusted as a copy. The path is resolved from this
// test file: assets/js/__tests__ -> repository root.
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const docsDir = join(repoRoot, "docs", "journeys");

test("the committed journey pages parse and carry the four pilot slugs", () => {
  const scenarios = loadScenarios(docsDir);

  const ids = scenarios.map(scenario => scenario.id);

  expect(ids).toContain("JRNY-001/import");
  expect(ids).toContain("JRNY-002/change-times");
  expect(ids).toContain("JRNY-002/add-trip");
  expect(ids).toContain("JRNY-003/export");

  for (const scenario of scenarios) {
    expect(scenario.goal).not.toBe("");
    expect(scenario.files.every(name => name.endsWith(".zip"))).toBe(true);
  }
});
