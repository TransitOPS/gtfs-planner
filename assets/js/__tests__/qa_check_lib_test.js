import { expect, test } from "vitest";

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