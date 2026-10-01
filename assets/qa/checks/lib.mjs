// Helpers for the external checks of a tester run.
//
// Every expected value a check compares against comes from the source zip,
// the validator jar, the pre-run baseline or the goal's own arithmetic, so
// this module holds the shared reading of those inputs: GTFS times in
// seconds, one signature per trip, and the expected multiset of signatures.

import { execFileSync } from "node:child_process";

// `H:MM:SS`, `HH:MM:SS` and hours of 24 or more, which GTFS allows so a
// service past midnight continues on the next clock day.
const HMS = /^(\d+):([0-5]\d):([0-5]\d)$/;

const ZIP_OUTPUT_LIMIT = 64 * 1024 * 1024;

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