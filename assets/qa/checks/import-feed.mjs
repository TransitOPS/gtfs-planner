// The import scenario's success check (AC-11).
//
// `node assets/qa/checks/import-feed.mjs --run DIR` passes when the run left
// a published version that was not in the pre-run baseline and that version's
// route, stop, trip, stop-time and calendar row counts equal the row counts of
// the same files in the source zip the scenario was given. The import is still
// running when the tester finishes, so the check polls for up to 60 seconds
// and then reports the state it last saw.
//
// Every expected number is counted from the source zip or read from the run's
// own throwaway database. Nothing here reads a rendered page, the in-app
// validator counts or the tester's own claim, and nothing writes.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import {
  countCsvRows,
  countRows,
  listVersions,
  readZipMember,
  waitFor,
} from "./lib.mjs";
import { BASELINE_FILE } from "../baseline.mjs";
import { loadScenarios, selectScenarios } from "../scenario.mjs";
import { readSession } from "../session.mjs";

// The tables a feed's row counts come from, each with the zip member it is
// counted in. `calendar.txt` is singular in GTFS and `calendars` is the
// application's table, so the two names are deliberately not the same word.
export const SOURCE_FILES = {
  routes: "routes.txt",
  stops: "stops.txt",
  trips: "trips.txt",
  stop_times: "stop_times.txt",
  calendars: "calendar.txt",
};

// How long an import may still be writing. An import of the fixture feed is
// seconds, so a minute is a bound rather than a wait: a run that needs more
// than this is reported as failed rather than holding the harness open.
const POLL_TIMEOUT_MS = 60_000;

// The newest version the run created that is published. `listVersions` orders
// by insert time, so the last new published row is the latest one. A version
// that is still staging or draft is not an import the tester finished, and a
// version the baseline already held is the untouched state, not a new one.
export function latestNewPublished(versions, baselineIds) {
  const known = new Set(baselineIds);

  const newPublished = versions.filter(
    version => !known.has(version.id) && version.publication_status === "published",
  );

  return newPublished.length === 0 ? null : newPublished[newPublished.length - 1];
}

// The one pure decision of this check: does the version the import created
// hold exactly the rows the source zip holds?
export function evaluateImport({ sourceCounts, versions, baselineIds, counts }) {
  const version = latestNewPublished(versions, baselineIds);

  if (version === null) {
    return {
      pass: false,
      observations: ["no published version that the run did not start from exists yet"],
    };
  }

  const observations = [];

  for (const [table, member] of Object.entries(SOURCE_FILES)) {
    const inZip = sourceCounts[table];
    const inVersion = counts?.[table];

    if (inZip !== inVersion) {
      observations.push(`${table}: ${inZip} in the zip, ${inVersion} in the version`);
    }
  }

  return {
    pass: observations.length === 0,
    observations: observations.length === 0
      ? [`version ${version.id} holds the zip's ${Object.keys(SOURCE_FILES).join(", ")} counts`]
      : observations,
  };
}

// The records of each of the zip's five files, counted from the zip itself.
export function sourceCounts(zipPath) {
  return Object.fromEntries(
    Object.entries(SOURCE_FILES).map(([table, member]) => [
      table,
      countCsvRows(readZipMember(zipPath, member).toString("utf8")),
    ]),
  );
}

function runDirFrom(argv) {
  const at = argv.indexOf("--run");

  if (at === -1 || at + 1 >= argv.length) {
    throw new Error("usage: node assets/qa/checks/import-feed.mjs --run DIR");
  }

  return argv[at + 1];
}

// The zip the scenario's tester was given. The first `Files` entry is the
// import itself; a scenario that names none has nothing to compare against.
function scenarioZip(session, { docsDir = "docs/journeys", fixturesDir = "test/fixtures/gtfs/ux_qa" } = {}) {
  const [scenario] = selectScenarios(loadScenarios(docsDir), session.scenario);

  const [file] = scenario.files;

  if (file === undefined) {
    throw new Error(`${scenario.id} names no file to import`);
  }

  return join(fixturesDir, file);
}

async function main(argv) {
  const runDir = runDirFrom(argv);

  const session = readSession(runDir);
  const baseline = JSON.parse(readFileSync(join(runDir, BASELINE_FILE), "utf8"));

  const zipCounts = sourceCounts(scenarioZip(session));
  const baselineIds = baseline.versions.map(({ id }) => id);

  const result = await waitFor(
    async () => {
      const versions = listVersions(session.dbUrl);
      const version = latestNewPublished(versions, baselineIds);

      const counts =
        version === null
          ? null
          : Object.fromEntries(
              Object.keys(SOURCE_FILES).map(table => [table, countRows(session.dbUrl, table, version.id)]),
            );

      return evaluateImport({ sourceCounts: zipCounts, versions, baselineIds, counts });
    },
    { timeoutMs: POLL_TIMEOUT_MS },
  );

  process.stdout.write(`${JSON.stringify({ id: "import-feed", ...result })}\n`);

  process.exitCode = result.pass ? 0 : 1;
}

// Exit 2 is the harness's "could not be judged" code: a missing run directory,
// an absent baseline or an unreadable database is never a passing run.
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(`${error.message}\n`);
    process.exit(error.exitCode ?? 2);
  });
}