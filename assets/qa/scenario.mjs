// Scenarios read from the journey pages (rule R5, contract C-1).
//
// `docs/journeys/JRNY-###-<slug>.md` carries the only scenario source: the
// section whose level-2 heading ends with "Test scenario", one `### <slug>`
// heading per scenario, and bullets written as `- **Key:** value`. The syntax
// itself is defined once, in document-journey's page template section 10; this
// module implements it and does not restate it.
//
// A scenario is split in two here. Persona, Goal, Start path and Files are what
// the tester is given. Account, Seed, Success check, Reference actions and
// Entry route drive the harness and the review and never reach the brief, so
// `briefText` cannot leak them.
//
// Reading files is confined to `loadScenarios`; parsing and rendering are pure.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Keys the harness and the review read. None of them may reach the tester.
export const HARNESS_KEYS = [
  "Account",
  "Seed",
  "Success check",
  "Reference actions",
  "Entry route"
];

// Keys the tester is shown. `Files` is optional; a scenario that uploads
// nothing may omit it.
export const TESTER_KEYS = ["Persona", "Goal", "Start path", "Files"];

const REQUIRED_KEYS = [...TESTER_KEYS.slice(0, 3), ...HARNESS_KEYS];

// The seed a scenario may ask for. Each is a fixture the harness knows how to
// load; a new one needs a seed and a registry entry, not a parser change.
const SEEDS = ["blank", "sample-feed"];

const BULLET = /^-\s+\*\*([^*]+?):\*\*\s*(.*)$/;

const JOURNEY_IN_NAME = /^JRNY-\d+/;

const SLUG = /^[a-z0-9-]+$/;

function fail(file, slug, reason) {
  throw new Error(`${file}: scenario "${slug}" ${reason}`);
}

// The journey identity comes from the front matter's `id`, and the file name is
// the fallback so a page without front matter still parses.
function journeyOf(markdown, file) {
  const frontMatter = /^---\n([\s\S]*?)\n---/.exec(markdown);

  if (frontMatter !== null) {
    const declared = /^id:\s*(JRNY-\d+)\s*$/m.exec(frontMatter[1]);

    if (declared !== null) return declared[1];
  }

  const fromName = JOURNEY_IN_NAME.exec(file.split("/").pop());

  return fromName === null ? null : fromName[0];
}

// The section runs from its heading to the next level-2 heading; a page without
// one has no scenarios.
function sectionOf(markdown) {
  const lines = markdown.split("\n");
  const start = lines.findIndex(line => /^##\s+.*Test scenario\s*$/.test(line));

  if (start === -1) return [];

  const end = lines.findIndex((line, index) => index > start && /^##\s/.test(line));

  return lines.slice(start + 1, end === -1 ? lines.length : end);
}

function wholeNumber(value) {
  return /^\d+$/.test(value.trim()) ? Number.parseInt(value.trim(), 10) : null;
}

function fileNames(value) {
  return value
    .split(",")
    .map(name => name.trim())
    .filter(name => name !== "");
}

// "import-feed — one new published version ..." splits into the check's script
// id and what it observes.
function successCheck(value, where) {
  const text = value.trim();
  const separator = text.search(/\s/);
  const id = separator === -1 ? text : text.slice(0, separator);
  const rest = separator === -1 ? "" : text.slice(separator + 1).trim();

  if (id === "" || /^[—–-]/.test(id)) {
    fail(where.file, where.slug, 'has a "Success check" with no check id');
  }

  return { id, text: rest.replace(/^[—–-]+\s*/, "") };
}

function build(file, journey, slug, bullets) {
  const where = { file, slug };
  const values = new Map();

  for (const [key, value] of bullets) {
    if (REQUIRED_KEYS.includes(key) || TESTER_KEYS.includes(key)) {
      values.set(key, value);
      continue;
    }

    fail(file, slug, `has unknown key "${key}"`);
  }

  const missing = REQUIRED_KEYS.find(key => !values.has(key));

  if (missing !== undefined) {
    fail(file, slug, `is missing required key "${missing}"`);
  }

  const seed = values.get("Seed").trim();

  if (!SEEDS.includes(seed)) {
    fail(file, slug, `seed must be blank or sample-feed`);
  }

  const referenceActions = wholeNumber(values.get("Reference actions"));

  if (referenceActions === null) {
    fail(file, slug, "reference actions must be an integer");
  }

  const scenario = {
    id: `${journey}/${slug}`,
    journey,
    slug,
    persona: values.get("Persona").trim(),
    goal: values.get("Goal").trim(),
    account: values.get("Account").trim(),
    seed,
    startPath: values.get("Start path").trim(),
    files: values.has("Files") ? fileNames(values.get("Files")) : [],
    successCheck: successCheck(values.get("Success check"), where),
    referenceActions,
    entryRoute: values.get("Entry route").trim()
  };

  return scenario;
}

export function parseScenarios(markdown, file) {
  const journey = journeyOf(markdown, file);
  const lines = sectionOf(markdown);
  const scenarios = [];

  let slug = null;
  let bullets = [];

  const flush = () => {
    if (slug === null) return;

    scenarios.push(build(file, journey, slug, bullets));
    slug = null;
    bullets = [];
  };

  for (const line of lines) {
    const heading = /^###\s+(.+?)\s*$/.exec(line);

    if (heading !== null) {
      flush();
      slug = heading[1];

      if (!SLUG.test(slug)) {
        fail(file, slug, "has a slug that is not lowercase letters, digits and hyphens");
      }

      continue;
    }

    if (slug === null) continue;

    const bullet = BULLET.exec(line.trim());

    if (bullet !== null) bullets.push([bullet[1].trim(), bullet[2]]);
  }

  flush();

  return scenarios;
}

export function loadScenarios(docsDir = "docs/journeys") {
  return readdirSync(docsDir)
    .filter(name => /^JRNY-\d+.*\.md$/.test(name))
    .sort()
    .flatMap(name => parseScenarios(readFileSync(join(docsDir, name), "utf8"), name));
}

export function selectScenarios(list, id) {
  const [journey, slug] = String(id).split("/");

  if (slug === undefined) {
    const selected = list.filter(scenario => scenario.journey === journey);

    if (selected.length === 0) throw new Error(`unknown scenario journey "${id}"`);

    return selected;
  }

  const selected = list.find(
    scenario => scenario.journey === journey && scenario.slug === slug
  );

  if (selected === undefined) throw new Error(`unknown scenario "${id}"`);

  return [selected];
}

// The tester's view of a scenario: the four keys the brief is built from and
// nothing else.
export function testerView(scenario) {
  return {
    persona: scenario.persona,
    goal: scenario.goal,
    startPath: scenario.startPath,
    files: [...scenario.files]
  };
}

export function briefText(scenario) {
  const { persona, goal, startPath, files } = testerView(scenario);
  const lines = [
    "## Who you are",
    "",
    persona,
    "",
    "## What you are trying to do",
    "",
    goal,
    "",
    "## Where you start",
    "",
    `Open ${startPath}.`,
    ""
  ];

  if (files.length > 0) {
    lines.push("## Files you can upload", "", ...files.map(name => `- ${name}`), "");
  }

  lines.push("Use only what you can see on the screen.", "");

  return lines.join("\n");
}
