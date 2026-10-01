// The add-trip scenario's success check (AC-12).
//
// `node assets/qa/checks/timetable-add-trip.mjs --run DIR` passes when the
// working version holds the pre-run baseline's trip signatures plus exactly
// one new AAMV weekend trip: 17:00 at the airport and 18:00 in the valley,
// keeping the run time of the baseline's 1:00 p.m. trip (3,600 s). Trip ids
// are not part of a signature, so an edit that reallocates an id is not a
// failure, and a second copy of the added trip is a difference rather than an
// interchangeable match.
//
// The added signature is the baseline's own REFERENCE trip moved to 17:00, so
// its stops and dwell are the goal's arithmetic over the seeded feed rather
// than numbers restated here. Nothing reads a rendered page, the in-app
// validator counts or the tester's own claim, and nothing writes.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import {
  compareSignatures,
  expectedSignatures,
  tripSignatures,
  waitFor,
} from "./lib.mjs";
import { BASELINE_FILE } from "../baseline.mjs";
import { readSession } from "../session.mjs";

// The trip the goal names. `START` and `REFERENCE` are the only expected
// values this check holds; every other trip is compared as it was captured.
export const ROUTE = "AAMV";
export const SERVICE = "WE";
export const DIRECTION = 0;
export const START = 61_200;

// The seeded 1:00 p.m. AAMV weekend trip whose run time the new trip copies.
export const REFERENCE = `${ROUTE}|${SERVICE}|${DIRECTION}|[(BEATTY_AIRPORT,46800,46800),(AMV,50400,50400)]`;

// How long adding and saving one trip may still take. It is a bound, not a
// wait.
const POLL_TIMEOUT_MS = 60_000;

// `route|service|direction|[(stop,arrival,departure),...]` as the helpers
// write it, so the added trip is built from the baseline's own stops.
function parseSignature(signature) {
  const match = /^(.*?)\|([^|]*)\|([^|]*)\|\[(.*)\]$/.exec(signature);

  if (match === null) throw new Error(`not a trip signature: ${signature}`);

  const [, routeId, serviceId, directionId, stops] = match;

  return {
    routeId,
    serviceId,
    directionId,
    stops: stops.split("),(").map(pair => {
      const [stopId, arrival, departure] = pair.replace(/^\(/, "").replace(/\)$/, "").split(",");

      return { stopId, arrival: Number(arrival), departure: Number(departure) };
    }),
  };
}

function formatSignature({ routeId, serviceId, directionId, stops }) {
  const times = stops.map(
    stop => `(${stop.stopId},${stop.arrival},${stop.departure})`,
  );

  return `${routeId}|${serviceId}|${directionId}|[${times.join(",")}]`;
}

// The one new trip: the reference trip's own stops and dwell, started at 17:00.
// The run time is the reference's second stop time less its first, 3,600 s, so
// this is the goal's arithmetic rather than a restated signature.
export function addedSignature() {
  const reference = parseSignature(REFERENCE);
  const offset = START - reference.stops[0].arrival;

  return formatSignature({
    ...reference,
    stops: reference.stops.map(stop => ({
      ...stop,
      arrival: stop.arrival + offset,
      departure: stop.departure + offset,
    })),
  });
}

// The one pure decision of this check: does the working version hold the
// baseline's signatures plus exactly the added trip? A baseline that does not
// hold `REFERENCE` is a seed the check cannot judge, so it throws with the
// harness's "could not be judged" code rather than reporting a difference that
// would say nothing about the tester's work.
export function evaluateAddTrip({ baseline, actual }) {
  if (!baseline.signatures.includes(REFERENCE)) {
    throw Object.assign(new Error(`the baseline holds no ${REFERENCE}`), { exitCode: 2 });
  }

  const expected = expectedSignatures(baseline, { add: [addedSignature()] });
  const { missing, unexpected } = compareSignatures(expected, actual);

  const observations = [
    ...missing.map(signature => `missing: ${signature}`),
    ...unexpected.map(signature => `unexpected: ${signature}`),
  ];

  return {
    pass: observations.length === 0,
    observations:
      observations.length === 0
        ? [`only ${ROUTE} ${SERVICE} ${DIRECTION} was added at 61200 and 64800`]
        : observations,
  };
}

function runDirFrom(argv) {
  const at = argv.indexOf("--run");

  if (at === -1 || at + 1 >= argv.length) {
    throw new Error("usage: node assets/qa/checks/timetable-add-trip.mjs --run DIR");
  }

  return argv[at + 1];
}

async function main(argv) {
  const runDir = runDirFrom(argv);

  const session = readSession(runDir);
  const baseline = JSON.parse(readFileSync(join(runDir, BASELINE_FILE), "utf8"));

  // The blank seed leaves no working version, so there is no timetable to
  // compare and the run could not be judged at all.
  if (!baseline.workingVersionId) {
    throw Object.assign(
      new Error(`the baseline recorded no working version for ${session.scenario}`),
      { exitCode: 2 },
    );
  }

  const result = await waitFor(
    async () => evaluateAddTrip({
      baseline,
      actual: tripSignatures(session.dbUrl, baseline.workingVersionId),
    }),
    { timeoutMs: POLL_TIMEOUT_MS },
  );

  process.stdout.write(`${JSON.stringify({ id: "timetable-add-trip", ...result })}\n`);

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