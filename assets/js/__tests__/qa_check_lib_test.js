import { expect, test } from "vitest";

import {
  compareSignatures,
  countCsvRows,
  expectedSignatures,
  toSeconds,
  tripSignature,
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