// The edit-schedule scenario's success check (AC-12).
//
// `node assets/qa/checks/timetable-change-times.mjs --run DIR` passes when the
// working version holds the pre-run baseline's trip signatures with only the
// one change the goal states: the 1:00 p.m. AAMV weekend trip moved 45 minutes
// later, which is 2,700 seconds added to each of its two times. Trip ids are
// not part of a signature, so an edit that reallocates an id is not a failure.
//
// Every expected signature is the baseline's own or this file's `TO`, which is
// the goal's arithmetic written out. Nothing here reads a rendered page, the
// in-app validator counts or the tester's own claim, and nothing writes.

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

// The trip the goal names. The two signatures below are the only expected
// values this check holds; every other trip is compared as it was captured.
export const ROUTE = "AAMV";
export const SERVICE = "WE";
export const DIRECTION = 0;

// 1:00 p.m. at the airport and 2:00 p.m. in the valley, then 45 minutes
// later: 46,800 + 2,700 = 49,500 and 50,400 + 2,700 = 53,100.
export const FROM = `${ROUTE}|${SERVICE}|${DIRECTION}|[(BEATTY_AIRPORT,46800,46800),(AMV,50400,50400)]`;
export const TO = `${ROUTE}|${SERVICE}|${DIRECTION}|[(BEATTY_AIRPORT,49500,49500),(AMV,53100,53100)]`;

// How long the edit may still be saving. Editing two times is immediate, so a
// minute is a bound rather than a wait.
const POLL_TIMEOUT_MS = 60_000;

// The one pure decision of this check: does the working version hold the
// baseline's signatures with only the stated change applied? A baseline that
// does not hold `FROM` is a seed the check cannot judge, so it throws with the
// harness's "could not be judged" code rather than reporting a difference that
// would say nothing about the tester's work.
export function evaluateChangeTimes({ baseline, actual }) {
  if (!baseline.signatures.includes(FROM)) {
    throw Object.assign(new Error(`the baseline holds no ${FROM}`), { exitCode: 2 });
  }

  const expected = expectedSignatures(baseline, { remove: [FROM], add: [TO] });
  const { missing, unexpected } = compareSignatures(expected, actual);

  const observations = [
    ...missing.map(signature => `missing: ${signature}`),
    ...unexpected.map(signature => `unexpected: ${signature}`),
  ];

  return {
    pass: observations.length === 0,
    observations:
      observations.length === 0
        ? [`only ${ROUTE} ${SERVICE} ${DIRECTION} moved from 46800 and 50400 to 49500 and 53100`]
        : observations,
  };
}

function runDirFrom(argv) {
  const at = argv.indexOf("--run");

  if (at === -1 || at + 1 >= argv.length) {
    throw new Error("usage: node assets/qa/checks/timetable-change-times.mjs --run DIR");
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
    async () => evaluateChangeTimes({
      baseline,
      actual: tripSignatures(session.dbUrl, baseline.workingVersionId),
    }),
    { timeoutMs: POLL_TIMEOUT_MS },
  );

  process.stdout.write(`${JSON.stringify({ id: "timetable-change-times", ...result })}\n`);

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