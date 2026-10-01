// The pre-run snapshot every later check compares against (contract C-8).
//
// `node assets/qa/baseline.mjs --run DIR` reads the run's `session.json`,
// learns the scenario's seed from the journey page, and writes
// `<run>/baseline.json`: the versions the seed left behind, which of them the
// run works in, and one signature per trip. A check that compares content in
// seconds has nothing trustworthy to compare against without this file, and
// the import check needs the version list to tell a new version from the
// seeded one.
//
// The file is written through a temporary name and renamed, so a reader never
// sees a half-written baseline.

import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { listVersions, tripSignatures } from "./checks/lib.mjs";
import { loadScenarios, selectScenarios } from "./scenario.mjs";
import { readSession } from "./session.mjs";

export const BASELINE_FILE = "baseline.json";

// The `blank` seed writes no trips, so a signature list would only ever be
// empty and the working version is recorded as null: the import check treats
// the version the import creates as the new one.
function workingVersion(versions, seed) {
  if (seed === "blank") return null;

  if (versions.length !== 1) {
    throw new Error(
      `the ${seed} seed must leave exactly one version, found ${versions.length}`,
    );
  }

  return versions[0].id;
}

export function captureBaseline(session, { now = () => new Date(), docsDir = "docs/journeys" } = {}) {
  const [scenario] = selectScenarios(loadScenarios(docsDir), session.scenario);

  const found = listVersions(session.dbUrl);
  const versions = found.map(({ id, name }) => ({ id, name }));
  const workingVersionId = workingVersion(versions, scenario.seed);

  return {
    capturedAt: now().toISOString(),
    versions,
    workingVersionId,
    signatures:
      workingVersionId === null ? [] : tripSignatures(session.dbUrl, workingVersionId),
  };
}

export function writeBaseline(runDir, baseline) {
  mkdirSync(runDir, { recursive: true });

  const target = join(runDir, BASELINE_FILE);
  const temporary = `${target}.${process.pid}.tmp`;

  writeFileSync(temporary, `${JSON.stringify(baseline, null, 2)}\n`, "utf8");
  renameSync(temporary, target);

  return target;
}

function runDirFrom(argv) {
  const at = argv.indexOf("--run");

  if (at === -1 || at + 1 >= argv.length) {
    throw new Error("usage: node assets/qa/baseline.mjs --run DIR");
  }

  return argv[at + 1];
}

function main(argv) {
  const runDir = runDirFrom(argv);
  const session = readSession(runDir);

  writeBaseline(runDir, captureBaseline(session));
}

// Exit 2 is the harness's "could not be judged" code, so a missing session, an
// unknown scenario or an unreadable database is never read as a passing run.
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(error.exitCode ?? 2);
  }
}
