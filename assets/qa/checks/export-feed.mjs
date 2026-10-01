// The export scenario's success check (AC-13).
//
// `node assets/qa/checks/export-feed.mjs --run DIR` passes when the tester
// downloaded a zip, that zip holds the same routes, stops, trips and
// stop-times rows as the source feed, the tracked validator reports no ERROR
// code for it that it does not also report for the source, and the working
// version has a completed validation run started after the run began. The
// check feed is asynchronous, so the last condition is polled for up to 180
// seconds and then reported as the state it last saw.
//
// Every expected value is counted from the source zip or read from the
// downloaded zip, the validator jar or the run's own throwaway database.
// Nothing here reads a rendered page, the in-app validator counts or the
// tester's own claim, and nothing writes.

import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import {
  countCsvRows,
  errorCodes,
  readZipMember,
  runValidator,
  validationRuns as versionValidationRuns,
  waitFor,
} from "./lib.mjs";
import { BASELINE_FILE } from "../baseline.mjs";
import { loadScenarios, selectScenarios } from "../scenario.mjs";
import { readSession } from "../session.mjs";

// The tables a downloaded feed's row counts come from, each with the zip
// member it is counted in. `calendar.txt` is deliberately absent: a full
// export writes the application's own calendars, which the goal does not
// promise to match the fixture byte for byte, so comparing them would fail a
// correct export.
export const EXPORT_FILES = {
  routes: "routes.txt",
  stops: "stops.txt",
  trips: "trips.txt",
  stop_times: "stop_times.txt",
};

// The feed the export scenario started from. The journey page names no file
// for it, because the tester uploads nothing to export, so the fixture the
// harness seeds it with is the source. A scenario that does name a file is
// compared against that file instead.
export const DEFAULT_SOURCE = "sample-feed.zip";

// How long the application's feed check may still be running. The journey
// presses "Download file" while the check may still be in flight, so the poll
// is a bound rather than a wait.
const POLL_TIMEOUT_MS = 180_000;

// The validator jar the application itself is configured with: the same
// `GTFS_VALIDATOR_JAR` override `config/runtime.exs` reads, and the same
// tracked jar when it is unset.
export const DEFAULT_JAR = "priv/gtfs_validator/gtfs-validator-cli.jar";

// `psql` prints a `timestamp without time zone` as `2026-09-30 20:03:11.123456`
// while the run's own start is an ISO instant. Both hold UTC, so a missing
// offset is read as UTC rather than as this machine's local time; an offset
// that is present is honoured as written.
function momentOf(text) {
  if (typeof text !== "string") return Number.NaN;

  const normalized = text.trim().replace(" ", "T");

  if (normalized === "") return Number.NaN;

  const zoned = /(Z|[+-]\d{2}(:?\d{2})?)$/.test(normalized) ? normalized : `${normalized}Z`;

  return Date.parse(zoned);
}

// The one pure decision of this check. A run that started at a moment this
// function cannot read is a run it cannot judge, so that case throws with the
// harness's "could not be judged" code rather than reporting a difference.
export function evaluateExport({
  downloadCounts,
  sourceCounts,
  downloadErrors,
  sourceErrors,
  validationRuns,
  startedAt,
}) {
  const runStartedAt = momentOf(startedAt);

  if (Number.isNaN(runStartedAt)) {
    throw Object.assign(new Error(`the run recorded no readable start time: ${startedAt}`), {
      exitCode: 2,
    });
  }

  if (downloadCounts === null || downloadCounts === undefined) {
    return {
      pass: false,
      observations: ["no zip has been downloaded yet"],
    };
  }

  const observations = [];

  for (const table of Object.keys(EXPORT_FILES)) {
    const inSource = sourceCounts[table];
    const inDownload = downloadCounts[table];

    if (inSource !== inDownload) {
      observations.push(`${table}: ${inSource} in the source zip, ${inDownload} in the download`);
    }
  }

  // A source feed that already has errors is a valid baseline, so the download
  // is judged on the codes it adds rather than on having none at all.
  const sourceSet = new Set(sourceErrors ?? []);

  for (const code of downloadErrors ?? []) {
    if (!sourceSet.has(code)) {
      observations.push(`validator error ${code} is not one the source zip reports`);
    }
  }

  const checked = (validationRuns ?? []).some(
    run => run?.status === "completed" && momentOf(run?.started_at) > runStartedAt,
  );

  if (!checked) {
    observations.push(`no completed validation run of the working version started after ${startedAt}`);
  }

  return {
    pass: observations.length === 0,
    observations:
      observations.length === 0
        ? [
            `the download holds the source's ${Object.keys(EXPORT_FILES).join(", ")} rows, ` +
              "reports no validator error the source does not, and the feed check completed",
          ]
        : observations,
  };
}

// The records of the four files a feed's row counts come from, counted from
// the zip itself.
export function zipCounts(zipPath) {
  return Object.fromEntries(
    Object.entries(EXPORT_FILES).map(([table, member]) => [
      table,
      countCsvRows(readZipMember(zipPath, member).toString("utf8")),
    ]),
  );
}

// The newest zip the tester downloaded, or null when none was. The check runs
// after the run ends, so the newest download is the one the tester meant.
export function latestDownload(downloadsDir) {
  let entries;

  try {
    entries = readdirSync(downloadsDir, { withFileTypes: true });
  } catch {
    return null;
  }

  const zips = entries
    .filter(entry => entry.isFile() && /\.zip$/i.test(entry.name))
    .map(entry => join(downloadsDir, entry.name))
    .map(path => ({ path, mtimeMs: statSync(path).mtimeMs }))
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  return zips.length === 0 ? null : zips[0].path;
}

// The source feed the run started from, resolved from the journey page's own
// `Files` value when it has one.
export function sourceZipPath(
  session,
  { docsDir = "docs/journeys", fixturesDir = "test/fixtures/gtfs/ux_qa" } = {},
) {
  const [scenario] = selectScenarios(loadScenarios(docsDir), session.scenario);

  const [file] = scenario.files.length === 0 ? [DEFAULT_SOURCE] : scenario.files;

  return join(fixturesDir, file);
}

// The validator writes its report into a directory of its own, so each call
// gets a throwaway one that is removed whether the call succeeded or not.
function withReportDirectory(work) {
  const outDir = mkdtempSync(join(tmpdir(), "ux-qa-export-"));

  try {
    return work(outDir);
  } finally {
    rmSync(outDir, { recursive: true, force: true });
  }
}

function runDirFrom(argv) {
  const at = argv.indexOf("--run");

  if (at === -1 || at + 1 >= argv.length) {
    throw new Error("usage: node assets/qa/checks/export-feed.mjs --run DIR");
  }

  return argv[at + 1];
}

async function main(argv) {
  const runDir = runDirFrom(argv);

  const session = readSession(runDir);
  const baseline = JSON.parse(readFileSync(join(runDir, BASELINE_FILE), "utf8"));

  // The blank seed leaves no working version, so there is nothing to check the
  // feed of and the run could not be judged at all.
  if (!baseline.workingVersionId) {
    throw Object.assign(
      new Error(`the baseline recorded no working version for ${session.scenario}`),
      { exitCode: 2 },
    );
  }

  const javaPath = session.javaPath ?? "java";
  const jarPath = process.env.GTFS_VALIDATOR_JAR ?? DEFAULT_JAR;
  const sourceZip = sourceZipPath(session);

  // The source feed is the same for every poll, so it is counted and validated
  // once rather than once per poll.
  const source = {
    sourceCounts: zipCounts(sourceZip),
    sourceErrors: errorCodes(
      withReportDirectory(outDir => runValidator(sourceZip, outDir, { javaPath, jarPath })),
    ),
  };

  // The download is read once, before the poll: the check runs after the run
  // ended, so a zip the tester never downloaded is a state to report rather
  // than one to wait for.
  const download = latestDownload(join(runDir, "downloads"));

  if (download === null) {
    const result = evaluateExport({
      downloadCounts: null,
      ...source,
      validationRuns: [],
      startedAt: session.startedAt,
    });

    report(result);

    return;
  }

  const downloaded = {
    downloadCounts: zipCounts(download),
    downloadErrors: errorCodes(
      withReportDirectory(outDir => runValidator(download, outDir, { javaPath, jarPath })),
    ),
  };

  // Only the feed check is asynchronous, so it is the only condition polled
  // (AC-13): the counts and the notice codes are settled by the time the
  // tester pressed "Download file".
  const result = await waitFor(
    async () =>
      evaluateExport({
        ...downloaded,
        ...source,
        validationRuns: versionValidationRuns(session.dbUrl, baseline.workingVersionId),
        startedAt: session.startedAt,
      }),
    { timeoutMs: POLL_TIMEOUT_MS },
  );

  report(result);
}

// One line of JSON on stdout and the exit code the harness reads: 0 passes, 1
// fails and 2, raised above, means the run could not be judged.
function report(result) {
  process.stdout.write(`${JSON.stringify({ id: "export-feed", ...result })}\n`);

  process.exitCode = result.pass ? 0 : 1;
}

// Exit 2 is the harness's "could not be judged" code: a missing run directory,
// an absent baseline, a missing validator jar or an unreadable database is
// never a passing run.
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(error => {
    process.stderr.write(`${error.message}\n`);
    process.exit(error.exitCode ?? 2);
  });
}