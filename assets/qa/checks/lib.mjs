// Helpers for the external checks of a tester run.
//
// Every expected value a check compares against comes from the source zip,
// the validator jar, the pre-run baseline or the goal's own arithmetic, so
// this module holds the shared reading of those inputs: GTFS times in
// seconds, one signature per trip, the expected multiset of signatures, the
// run's own database, the validator jar and a bounded poll.
//
// The checks only ever read. Every query is parameterized through `psql`
// variables rather than interpolated text, and every version id is checked
// against the UUID pattern before it reaches a command line.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// `H:MM:SS`, `HH:MM:SS` and hours of 24 or more, which GTFS allows so a
// service past midnight continues on the next clock day.
const HMS = /^(\d+):([0-5]\d):([0-5]\d)$/;

const ZIP_OUTPUT_LIMIT = 64 * 1024 * 1024;

// A version id is a UUID in every query; anything else is a harness bug, not
// a database condition, so it is refused before any process starts.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The tables `countRows` may read. A table name cannot be a `psql` variable,
// so it is checked against this list instead of being escaped.
const COUNT_TABLES = ["routes", "stops", "trips", "stop_times", "calendars"];

// The check boundary is the exit code the harness reads: 0 passes, 1 fails and
// 2 means the check could not be judged.
function harnessError(message) {
  return Object.assign(new Error(message), { exitCode: 2 });
}

export function assertVersionId(versionId) {
  if (typeof versionId !== "string" || !UUID.test(versionId)) {
    throw harnessError(`not a GTFS version id: ${versionId}`);
  }

  return versionId;
}

function timeOf(hms) {
  return hms === null || hms === undefined ? "null" : String(toSeconds(hms));
}

// Seconds since midnight. `6:00:00` and `06:00:00` are the same time and
// `25:10:00` is 90,600.
export function toSeconds(hms) {
  const match = typeof hms === "string" ? HMS.exec(hms) : null;

  if (match === null) throw new Error(`not a GTFS time: ${hms}`);

  const [, hours, minutes, seconds] = match;

  return Number(hours) * 3600 + Number(minutes) * 60 + Number(seconds);
}

// One trip's content, without its ID, so that an edit that reallocates an ID
// is not a false failure. `stops` is an array of
// `{ stopId, sequence, arrival, departure }` with the times as GTFS strings
// or null, and is read in numeric `sequence` order.
export function tripSignature({ routeId, serviceId, directionId, stops }) {
  const ordered = [...stops].sort((a, b) => a.sequence - b.sequence);

  const times = ordered.map(
    stop => `(${stop.stopId},${timeOf(stop.arrival)},${timeOf(stop.departure)})`,
  );

  return [
    routeId,
    serviceId,
    directionId ?? "",
    `[${times.join(",")}]`,
  ].join("|");
}

// The baseline's trips plus only the change the goal states. Each removed
// signature takes exactly one occurrence away; a signature the baseline does
// not hold means the run started from a state the check cannot judge, so it
// throws rather than reporting a difference that says nothing.
export function expectedSignatures(baseline, { remove = [], add = [] } = {}) {
  const remaining = [...baseline.signatures];

  for (const signature of remove) {
    const at = remaining.indexOf(signature);

    if (at === -1) throw new Error(`signature is not in the baseline: ${signature}`);

    remaining.splice(at, 1);
  }

  return [...remaining, ...add];
}

// Which signatures the run is missing and which extra ones it holds. Two trips
// with identical content are interchangeable, so a duplicate is a real
// difference: the counts are compared, not the sets.
function differences(from, other) {
  const counts = new Map();

  for (const signature of other) counts.set(signature, (counts.get(signature) ?? 0) + 1);

  const extra = [];

  for (const signature of from) {
    const left = counts.get(signature) ?? 0;

    if (left > 0) counts.set(signature, left - 1);
    else extra.push(signature);
  }

  return extra;
}

export function compareSignatures(expected, actual) {
  return {
    missing: differences(expected, actual),
    unexpected: differences(actual, expected),
  };
}

// The number of records in a GTFS csv file: the header row is not a record
// and a blank line is not one either.
export function countCsvRows(text) {
  const lines = text.split(/\r?\n/).filter(line => line.trim() !== "");

  return Math.max(lines.length - 1, 0);
}

// The bytes of one member of a zip, for the checks that read the source or a
// download. `assets/e2e/browser_helpers.js` `readZipTextMember` reads sizes
// from the local headers and cannot read an entry whose sizes are in a data
// descriptor; `unzip -p` reads any zip.
export function readZipMember(zipPath, name) {
  try {
    return execFileSync("unzip", ["-p", zipPath, name], {
      maxBuffer: ZIP_OUTPUT_LIMIT,
    });
  } catch (error) {
    throw new Error(`${name} is not present in ${zipPath}: ${error.message}`);
  }
}

// The rows of one query, as arrays of column values.
//
// `-X` skips `~/.psqlrc`, `-At` drops the header and the row count and `-F`
// makes the only separator a tab, so a value that itself contains a comma
// stays one field. The SQL arrives on stdin because `psql` only interpolates
// `:'name'` variables for input it reads there, and each variable is passed
// as its own `-v` so a value never becomes part of the command text. A
// missing `psql` and a refused connection are the same failure to a check.
export function psqlRows(dbUrl, sql, vars = {}) {
  const args = ["-X", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1"];

  for (const [name, value] of Object.entries(vars)) args.push("-v", `${name}=${value}`);

  args.push(dbUrl);

  let output;

  try {
    output = execFileSync("psql", args, {
      input: sql,
      encoding: "utf8",
      maxBuffer: ZIP_OUTPUT_LIMIT,
    });
  } catch (error) {
    throw harnessError(
      `psql could not read ${dbUrl}: ${error.stderr ?? error.message}`.trim(),
    );
  }

  return output
    .split("\n")
    .filter(line => line !== "")
    .map(line => line.split("\t"));
}

// The tables a version owns that the checks count, ordered by insert time so
// "the latest version" is the last row.
export function listVersions(dbUrl) {
  return psqlRows(
    dbUrl,
    `select id, name, publication_status, inserted_at
       from gtfs_versions
      order by inserted_at, id`,
  ).map(([id, name, publicationStatus, insertedAt]) => ({
    id,
    name,
    publication_status: publicationStatus,
    inserted_at: insertedAt,
  }));
}

// One signature per trip of a version, grouped in JavaScript so the reading
// order is the trip's own and the same `tripSignature` the oracle uses.
export function tripSignatures(dbUrl, versionId) {
  assertVersionId(versionId);

  const rows = psqlRows(
    dbUrl,
    `select t.trip_id, t.route_id, t.service_id, coalesce(t.direction_id::text, ''),
            s.stop_id, s.stop_sequence, s.arrival_time, s.departure_time
       from trips t
       join stop_times s
         on s.trip_id = t.trip_id and s.gtfs_version_id = t.gtfs_version_id
      where t.gtfs_version_id = :'vid'
      order by t.trip_id, s.stop_sequence`,
    { vid: versionId },
  );

  const trips = new Map();

  for (const [tripId, routeId, serviceId, directionId, stopId, sequence, arrival, departure] of rows) {
    if (!trips.has(tripId)) {
      trips.set(tripId, { routeId, serviceId, directionId, stops: [] });
    }

    trips.get(tripId).stops.push({
      stopId,
      sequence: Number(sequence),
      arrival,
      departure,
    });
  }

  return [...trips.values()].map(trip => tripSignature(trip));
}

// How many records of one table a version holds. A timepoint-only import
// writes no calendars, so zero is a real answer and not a failure.
export function countRows(dbUrl, table, versionId) {
  assertVersionId(versionId);

  if (!COUNT_TABLES.includes(table)) {
    throw harnessError(`not a countable GTFS table: ${table}`);
  }

  const [count] = psqlRows(
    dbUrl,
    `select count(*) from ${table} where gtfs_version_id = :'vid'`,
    { vid: versionId },
  );

  return Number(count);
}

// The validation runs of a version, oldest first, so a caller can look for a
// run started after a moment it recorded itself.
export function validationRuns(dbUrl, versionId) {
  assertVersionId(versionId);

  return psqlRows(
    dbUrl,
    `select status, started_at
       from gtfs_validation_runs
      where gtfs_version_id = :'vid'
      order by started_at, id`,
    { vid: versionId },
  ).map(([status, startedAt]) => ({ status, started_at: startedAt }));
}

// The decoded `report.json` of the tracked validator CLI, with the same
// argument shape as `test/support/gtfs_validator_cli.ex`, so the check reads
// the same report the application itself reads. `--skip_validator_update` is
// what keeps this call offline.
export function runValidator(zipPath, outDir, { javaPath = "java", jarPath } = {}) {
  if (typeof jarPath !== "string" || jarPath === "") {
    throw harnessError("no validator jar: pass jarPath");
  }

  const args = ["-jar", jarPath, "-i", zipPath, "-o", outDir, "--skip_validator_update"];

  let output;

  try {
    output = execFileSync(javaPath, args, { encoding: "utf8", maxBuffer: ZIP_OUTPUT_LIMIT });
  } catch (error) {
    throw harnessError(`${javaPath} failed for ${zipPath}: ${error.stderr ?? error.message}`.trim());
  }

  let report;

  try {
    report = JSON.parse(readFileSync(join(outDir, "report.json"), "utf8"));
  } catch {
    throw harnessError(`the validator wrote no readable report.json for ${zipPath}: ${output}`);
  }

  return report;
}

// The notice codes a report calls an error, deduplicated and sorted so two
// runs of the same feed produce the same message. A source feed with errors is
// still a valid baseline, which is why this is a set the caller compares
// against rather than a pass or fail.
export function errorCodes(report) {
  const notices = Array.isArray(report?.notices) ? report.notices : [];

  const codes = new Set();

  for (const notice of notices) {
    if (String(notice?.severity ?? "").toUpperCase() === "ERROR") codes.add(notice.code);
  }

  return [...codes].sort();
}

function sleepFor(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

// Poll `evaluate` until it reports `pass` or the deadline passes, and return
// the last result either way, so a failed check reports the state it last
// saw rather than nothing. `now` and `sleep` are injected so the tests
// exercise the deadline without waiting for it.
export async function waitFor(
  evaluate,
  { timeoutMs, intervalMs = 2000, now = Date.now, sleep = sleepFor } = {},
) {
  if (!Number.isFinite(timeoutMs) || timeoutMs < 0) {
    throw harnessError(`waitFor needs a finite timeoutMs: ${timeoutMs}`);
  }

  const deadline = now() + timeoutMs;

  let result = await evaluate();

  while (!result.pass) {
    const remaining = deadline - now();

    if (remaining <= 0) return result;

    await sleep(Math.min(intervalMs, remaining));
    result = await evaluate();
  }

  return result;
}
