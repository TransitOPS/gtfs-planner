import { expect, test } from "vitest";

import { evaluateImport } from "../../qa/checks/import-feed.mjs";
import { evaluateChangeTimes } from "../../qa/checks/timetable-change-times.mjs";
import {
  assertVersionId,
  compareSignatures,
  countCsvRows,
  errorCodes,
  expectedSignatures,
  toSeconds,
  tripSignature,
  waitFor,
} from "../../qa/checks/lib.mjs";

// Every expected value below is written out here rather than imported from a
// module under test, so a wrong number in the module shows up in the diff.

const EARLY = "AAMV|WE|0|[(BEATTY_AIRPORT,46800,46800),(AMV,50400,50400)]";
const LATE = "AAMV|WE|0|[(BEATTY_AIRPORT,49500,49500),(AMV,53100,53100)]";

function stop(stopId, sequence, arrival, departure) {
  return { stopId, sequence, arrival, departure };
}

test("toSeconds reads a one-digit and a two-digit hour as the same time", () => {
  expect(toSeconds("6:00:00")).toBe(21600);
  expect(toSeconds("06:00:00")).toBe(21600);
  expect(toSeconds("13:00:00")).toBe(46800);
  expect(toSeconds("17:00:00")).toBe(61200);
});

test("toSeconds counts hours past midnight", () => {
  expect(toSeconds("25:10:00")).toBe(90600);
  expect(toSeconds("24:00:00")).toBe(86400);
});

test("toSeconds rejects anything that is not a GTFS time", () => {
  expect(() => toSeconds("6:00")).toThrow();
  expect(() => toSeconds("6:60:00")).toThrow();
  expect(() => toSeconds("-1:00:00")).toThrow();
  expect(() => toSeconds("")).toThrow();
  expect(() => toSeconds(null)).toThrow();
  expect(() => toSeconds(21600)).toThrow();
});

test("a signature does not depend on how the hours are padded", () => {
  const padded = tripSignature({
    routeId: "AAMV",
    serviceId: "WE",
    directionId: 0,
    stops: [
      stop("BEATTY_AIRPORT", 1, "06:00:00", "06:00:00"),
      stop("AMV", 2, "09:00:00", "09:00:00"),
    ],
  });

  const bare = tripSignature({
    routeId: "AAMV",
    serviceId: "WE",
    directionId: 0,
    stops: [
      stop("BEATTY_AIRPORT", 1, "6:00:00", "6:00:00"),
      stop("AMV", 2, "9:00:00", "9:00:00"),
    ],
  });

  expect(padded).toBe(bare);
  expect(padded).toBe("AAMV|WE|0|[(BEATTY_AIRPORT,21600,21600),(AMV,32400,32400)]");
});

test("a signature of the seeded 1:00 p.m. trip is the literal the goal names", () => {
  const signature = tripSignature({
    routeId: "AAMV",
    serviceId: "WE",
    directionId: 0,
    stops: [
      stop("BEATTY_AIRPORT", 1, "13:00:00", "13:00:00"),
      stop("AMV", 2, "14:00:00", "14:00:00"),
    ],
  });

  expect(signature).toBe(EARLY);
});

test("a signature reads its stops in numeric sequence order", () => {
  const signature = tripSignature({
    routeId: "AAMV",
    serviceId: "WE",
    directionId: 0,
    stops: [
      stop("AMV", 20, "14:00:00", "14:00:00"),
      stop("BEATTY_AIRPORT", 3, "13:00:00", "13:00:00"),
    ],
  });

  expect(signature).toBe(EARLY);
});

test("a signature counts hours past midnight in seconds", () => {
  const signature = tripSignature({
    routeId: "AAMV",
    serviceId: "WE",
    directionId: 0,
    stops: [stop("AMV", 1, "25:10:00", "25:10:00")],
  });

  expect(signature).toBe("AAMV|WE|0|[(AMV,90600,90600)]");
});

test("a signature leaves a null direction and a null time readable", () => {
  const signature = tripSignature({
    routeId: "AAMV",
    serviceId: "WE",
    directionId: null,
    stops: [stop("BEATTY_AIRPORT", 1, null, "13:00:00")],
  });

  expect(signature).toBe("AAMV|WE||[(BEATTY_AIRPORT,null,46800)]");
});

test("identical signature lists have no differences", () => {
  expect(compareSignatures([EARLY, LATE], [LATE, EARLY])).toEqual({
    missing: [],
    unexpected: [],
  });
});

test("a moved trip is one missing and one unexpected signature", () => {
  expect(compareSignatures([LATE], [EARLY])).toEqual({
    missing: [LATE],
    unexpected: [EARLY],
  });
});

test("a duplicate signature is a difference even though the value matches", () => {
  expect(compareSignatures([EARLY], [EARLY, EARLY])).toEqual({
    missing: [],
    unexpected: [EARLY],
  });
});

test("expectedSignatures applies the one stated change", () => {
  const baseline = { signatures: ["OTHER", EARLY] };

  expect(expectedSignatures(baseline, { remove: [EARLY], add: [LATE] })).toEqual([
    "OTHER",
    LATE,
  ]);

  expect(expectedSignatures(baseline, { add: [LATE] })).toEqual([
    "OTHER",
    EARLY,
    LATE,
  ]);
});

test("expectedSignatures removes one occurrence of a repeated signature", () => {
  const baseline = { signatures: [EARLY, EARLY] };

  expect(expectedSignatures(baseline, { remove: [EARLY] })).toEqual([EARLY]);
});

test("expectedSignatures throws when the baseline does not hold the signature", () => {
  expect(() => expectedSignatures({ signatures: [] }, { remove: [EARLY] })).toThrow(
    /not in the baseline/,
  );
});

test("expectedSignatures throws rather than removing a second occurrence", () => {
  expect(() =>
    expectedSignatures({ signatures: [EARLY] }, { remove: [EARLY, EARLY] }),
  ).toThrow(/not in the baseline/);
});

test("countCsvRows drops the header, the trailing newline and blank lines", () => {
  expect(countCsvRows("route_id,route_short_name\nAAMV,Airport\n")).toBe(1);
  expect(
    countCsvRows("route_id,route_short_name\r\nAAMV,Airport\r\nBUS,Bus\r\n"),
  ).toBe(2);
  expect(countCsvRows("route_id,route_short_name\n\nAAMV,Airport\n\n\n")).toBe(1);
  expect(countCsvRows("")).toBe(0);
  expect(countCsvRows("route_id,route_short_name\n")).toBe(0);
});

// A clock that only moves when the poll sleeps, so the deadline in these
// cases is reached without any real waiting.
function fakeClock() {
  const clock = {
    now: () => clock.at,
    at: 0,
    slept: [],
    sleep: async milliseconds => {
      clock.slept.push(milliseconds);
      clock.at += milliseconds;
    },
  };

  return clock;
}

test("waitFor returns a first evaluation that already passes", async () => {
  const clock = fakeClock();
  let calls = 0;

  const result = await waitFor(
    async () => {
      calls += 1;
      return { pass: true, observations: ["ready"] };
    },
    { timeoutMs: 60_000, now: clock.now, sleep: clock.sleep },
  );

  expect(result).toEqual({ pass: true, observations: ["ready"] });
  expect(calls).toBe(1);
  expect(clock.slept).toEqual([]);
});

test("waitFor polls until the third evaluation passes", async () => {
  const clock = fakeClock();
  let calls = 0;

  const result = await waitFor(
    async () => {
      calls += 1;
      return { pass: calls === 3, observations: [`call ${calls}`] };
    },
    { timeoutMs: 60_000, now: clock.now, sleep: clock.sleep },
  );

  expect(result).toEqual({ pass: true, observations: ["call 3"] });
  expect(calls).toBe(3);
  expect(clock.slept).toEqual([2000, 2000]);
});

test("waitFor returns the last failing result at the deadline", async () => {
  const clock = fakeClock();
  let calls = 0;

  const result = await waitFor(
    async () => {
      calls += 1;
      return { pass: false, observations: [`call ${calls}`] };
    },
    { timeoutMs: 6000, now: clock.now, sleep: clock.sleep },
  );

  expect(result).toEqual({ pass: false, observations: [`call ${calls}`] });
  expect(clock.at).toBe(6000);
  // 6 s of budget at a 2 s interval is three sleeps, and the sleep that
  // would cross the deadline is shortened instead of overshooting.
  expect(clock.slept).toEqual([2000, 2000, 2000]);
});

test("waitFor sleeps once for a budget shorter than the interval", async () => {
  const clock = fakeClock();
  let calls = 0;

  await waitFor(
    async () => {
      calls += 1;
      return { pass: false, observations: [] };
    },
    { timeoutMs: 500, now: clock.now, sleep: clock.sleep },
  );

  expect(calls).toBe(2);
  expect(clock.slept).toEqual([500]);
});

test("waitFor refuses a deadline it could never reach", async () => {
  const clock = fakeClock();
  const never = async () => ({ pass: false, observations: [] });

  await expect(waitFor(never, { now: clock.now, sleep: clock.sleep })).rejects.toThrow(
    /finite timeoutMs/,
  );

  await expect(
    waitFor(never, { timeoutMs: Number.NaN, now: clock.now, sleep: clock.sleep }),
  ).rejects.toThrow(/finite timeoutMs/);
});

const REPORT = {
  summary: { validatorIssues: { errors: 2, warnings: 1, infos: 1 } },
  notices: [
    { code: "stop_time_with_arrival_before_previous_departure_time", severity: "ERROR", totalNotices: 1 },
    { code: "duplicate_trip", severity: "error", totalNotices: 1 },
    { code: "missing_trip_edge", severity: "ERROR", totalNotices: 1 },
    { code: "route_based_agency", severity: "WARNING", totalNotices: 1 },
    { code: "stop_without_zone_id", severity: "INFO", totalNotices: 1 },
  ],
};

test("errorCodes returns only the ERROR notice codes", () => {
  expect(errorCodes(REPORT)).toEqual([
    "duplicate_trip",
    "missing_trip_edge",
    "stop_time_with_arrival_before_previous_departure_time",
  ]);
});

test("errorCodes reads a report with no notices as no codes", () => {
  expect(errorCodes({ summary: {} })).toEqual([]);
  expect(errorCodes({ notices: [] })).toEqual([]);
});

test("errorCodes deduplicates a code the report lists more than once", () => {
  const report = { notices: [{ code: "duplicate_trip", severity: "ERROR" }, { code: "duplicate_trip", severity: "ERROR" }] };

  expect(errorCodes(report)).toEqual(["duplicate_trip"]);
});

test("a version id that is not a UUID is refused before any command runs", () => {
  let raised = null;

  try {
    assertVersionId("not-a-uuid");
  } catch (error) {
    raised = error;
  }

  expect(raised?.message).toMatch(/not a GTFS version id/);
  // Exit code 2 is the harness's "could not be judged", the same code a
  // missing psql or a refused connection raises.
  expect(raised?.exitCode).toBe(2);

  expect(() => assertVersionId("'; drop table trips; --")).toThrow(/not a GTFS version id/);
  expect(() => assertVersionId("")).toThrow(/not a GTFS version id/);
  expect(() => assertVersionId(null)).toThrow(/not a GTFS version id/);
});

test("a well-formed version id passes the check", () => {
  const id = "0f9a2b1c-3d4e-4f50-8a6b-7c8d9e0f1a2b";

  expect(assertVersionId(id)).toBe(id);
});
// The import check compares a version against the zip, so the counts below
// are written out rather than read from either one.

const ZIP_COUNTS = { routes: 5, stops: 9, trips: 11, stop_times: 28, calendars: 2 };

const SEEDED = {
  id: "1b3f5c2a-6d47-4b8e-9f10-2c5d8e4a7b31",
  name: "Empty feed",
  publication_status: "published",
  inserted_at: "2026-09-30T19:08:05.000000Z",
};

const IMPORTED = {
  id: "9c2e7d41-5a68-4f3b-8e02-71d4a6f9c8b2",
  name: "sample-feed.zip",
  publication_status: "published",
  inserted_at: "2026-09-30T19:12:41.000000Z",
};

const STAGING = { ...IMPORTED, id: "d5a1b8e3-7c40-4f62-91ad-3e8c0b5f2d74", publication_status: "staging" };
const LATER = { ...IMPORTED, id: "f0c3a9d7-2b58-4e91-8a63-5d1e7c4b9a08", inserted_at: "2026-09-30T19:14:02.000000Z" };

function evaluate(overrides) {
  return evaluateImport({
    sourceCounts: ZIP_COUNTS,
    versions: [SEEDED, IMPORTED],
    baselineIds: [SEEDED.id],
    counts: ZIP_COUNTS,
    ...overrides,
  });
}

test("a new published version holding the zip's counts passes the import check", () => {
  const result = evaluate();

  expect(result.pass).toBe(true);
  expect(result.observations).toEqual([
    `version ${IMPORTED.id} holds the zip's routes, stops, trips, stop_times, calendars counts`,
  ]);
});

test("no new version fails, because that is the untouched state", () => {
  const result = evaluate({ versions: [SEEDED] });

  expect(result.pass).toBe(false);
  expect(result.observations).toEqual([
    "no published version that the run did not start from exists yet",
  ]);
});

test("a new version that is not published yet does not count", () => {
  const result = evaluate({ versions: [SEEDED, STAGING] });

  expect(result.pass).toBe(false);
  expect(result.observations[0]).toMatch(/no published version/);
});

test("a partial import fails and names the count that differs", () => {
  const result = evaluate({ counts: { ...ZIP_COUNTS, trips: 10 } });

  expect(result.pass).toBe(false);
  expect(result.observations).toEqual(["trips: 11 in the zip, 10 in the version"]);
});

test("two new versions are judged by the latest one", () => {
  const result = evaluate({ versions: [SEEDED, IMPORTED, LATER], counts: { ...ZIP_COUNTS, routes: 3 } });

  expect(result.pass).toBe(false);
  expect(result.observations).toEqual(["routes: 5 in the zip, 3 in the version"]);

  const earlier = evaluate({ versions: [SEEDED, LATER, IMPORTED] });

  expect(earlier.pass).toBe(true);
});

test("every table that differs is named", () => {
  const result = evaluate({ counts: { routes: 5, stops: 0, trips: 11, stop_times: 28, calendars: 2 } });

  expect(result.observations).toEqual(["stops: 9 in the zip, 0 in the version"]);
});

test("a version counted before its rows exist fails rather than passing an absent count", () => {
  const result = evaluate({ counts: null });

  expect(result.pass).toBe(false);
  expect(result.observations).toHaveLength(5);
  expect(result.observations[0]).toMatch(/in the version/);
});

// The timetable check compares the pre-run baseline with only the stated
// change, so every row below is written out from the fixture's own stop times
// rather than read from the check or from the application.

const MORNING = "AAMV|WE|0|[(BEATTY_AIRPORT,28800,28800),(AMV,32400,32400)]";
const OUTBOUND = "AAMV|WE|1|[(AMV,36000,36000),(BEATTY_AIRPORT,39600,39600)]";
const EVENING = "AAMV|WE|1|[(AMV,54000,54000),(BEATTY_AIRPORT,57600,57600)]";

const TIMETABLE = {
  signatures: [MORNING, OUTBOUND, EARLY, EVENING],
};

function timetable(actual) {
  return evaluateChangeTimes({ baseline: TIMETABLE, actual });
}

test("moving only the 1:00 p.m. trip 45 minutes later passes the check", () => {
  const result = timetable([MORNING, OUTBOUND, LATE, EVENING]);

  expect(result.pass).toBe(true);
  expect(result.observations).toEqual([
    "only AAMV WE 0 moved from 46800 and 50400 to 49500 and 53100",
  ]);
});

test("the untouched timetable fails, because nothing moved", () => {
  const result = timetable([...TIMETABLE.signatures]);

  expect(result.pass).toBe(false);
  expect(result.observations).toEqual([
    `missing: ${LATE}`,
    `unexpected: ${EARLY}`,
  ]);
});

test("moving the 8:00 trip instead of the 1:00 p.m. one fails", () => {
  const morningMoved = "AAMV|WE|0|[(BEATTY_AIRPORT,31500,31500),(AMV,35100,35100)]";

  const result = timetable([morningMoved, OUTBOUND, EARLY, EVENING]);

  expect(result.pass).toBe(false);
  expect(result.observations).toEqual([
    `missing: ${MORNING}`,
    `missing: ${LATE}`,
    `unexpected: ${morningMoved}`,
    `unexpected: ${EARLY}`,
  ]);
});

test("changing only the first stop fails", () => {
  const firstOnly = "AAMV|WE|0|[(BEATTY_AIRPORT,49500,49500),(AMV,50400,50400)]";

  const result = timetable([MORNING, OUTBOUND, firstOnly, EVENING]);

  expect(result.pass).toBe(false);
  expect(result.observations).toEqual([
    `missing: ${LATE}`,
    `unexpected: ${firstOnly}`,
  ]);
});

test("moving the second stop by 15 minutes more than the goal fails", () => {
  const fifteenLate = "AAMV|WE|0|[(BEATTY_AIRPORT,49500,49500),(AMV,54000,54000)]";

  const result = timetable([MORNING, OUTBOUND, fifteenLate, EVENING]);

  expect(result.pass).toBe(false);
  expect(result.observations).toEqual([
    `missing: ${LATE}`,
    `unexpected: ${fifteenLate}`,
  ]);
});

test("an additional trip fails, because the trip count changed", () => {
  const added = "AAMV|WE|0|[(BEATTY_AIRPORT,61200,61200),(AMV,64800,64800)]";

  const result = timetable([MORNING, OUTBOUND, LATE, EVENING, added]);

  expect(result.pass).toBe(false);
  expect(result.observations).toEqual([`unexpected: ${added}`]);
});

test("a moved trip stored with unpadded hours equals the same trip stored padded", () => {
  const bare = tripSignature({
    routeId: "AAMV",
    serviceId: "WE",
    directionId: 0,
    stops: [
      stop("BEATTY_AIRPORT", 1, "13:45:00", "13:45:00"),
      stop("AMV", 2, "14:45:00", "14:45:00"),
    ],
  });

  const padded = tripSignature({
    routeId: "AAMV",
    serviceId: "WE",
    directionId: 0,
    stops: [
      stop("BEATTY_AIRPORT", 1, "013:45:00", "013:45:00"),
      stop("AMV", 2, "014:45:00", "014:45:00"),
    ],
  });

  expect(bare).toBe(LATE);
  expect(padded).toBe(bare);
  expect(timetable([MORNING, OUTBOUND, bare, EVENING]).pass).toBe(true);
});

test("a baseline that does not hold the 1:00 p.m. trip throws instead of judging", () => {
  let raised = null;

  try {
    evaluateChangeTimes({ baseline: { signatures: [MORNING] }, actual: [MORNING] });
  } catch (error) {
    raised = error;
  }

  expect(raised?.message).toMatch(/the baseline holds no/);
  // Exit code 2 is the harness's "could not be judged", not a failing run.
  expect(raised?.exitCode).toBe(2);
});
