import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

import { expect, test } from "vitest";

import {
  assertRootIgnored,
  captureRoot,
  defaultCheck,
  journeyCapturePath,
  parseCaptureId,
  staleCaptureFiles
} from "../../qa/captures.mjs";

const ROOT = "/Users/x/proj/.specs/images";

test("the capture root is .specs/images in the primary checkout", () => {
  expect(captureRoot("/Users/x/proj")).toBe(ROOT);
});

test("step 3 of JRNY-001/import is journeys/JRNY-001/import-s003.png", () => {
  expect(journeyCapturePath(ROOT, "JRNY-001/import", 3)).toBe(
    "/Users/x/proj/.specs/images/journeys/JRNY-001/import-s003.png"
  );
});

test("a step number is zero-padded to three digits", () => {
  expect(journeyCapturePath(ROOT, "JRNY-002/add-trip", 7)).toBe(
    "/Users/x/proj/.specs/images/journeys/JRNY-002/add-trip-s007.png"
  );
  expect(journeyCapturePath(ROOT, "JRNY-002/add-trip", 128)).toBe(
    "/Users/x/proj/.specs/images/journeys/JRNY-002/add-trip-s128.png"
  );
});

test("both capture ID forms resolve to their owner folder", () => {
  expect(parseCaptureId("JRNY-001/import-s003", ROOT)).toEqual({
    owner: "JRNY-001",
    name: "import-s003",
    path: "/Users/x/proj/.specs/images/journeys/JRNY-001/import-s003.png"
  });

  expect(parseCaptureId("SCRN-001/empty", ROOT)).toEqual({
    owner: "SCRN-001",
    name: "empty",
    path: "/Users/x/proj/.specs/images/screens/SCRN-001/empty.png"
  });
});

test("a capture ID round-trips through the journey path rule", () => {
  const parsed = parseCaptureId("JRNY-002/change-times-s012", ROOT);

  expect(journeyCapturePath(ROOT, "JRNY-002/change-times", 12)).toBe(parsed.path);
});

test("a missing capture is simply absent and nothing is read to find that out", () => {
  const parsed = parseCaptureId("JRNY-003/export-s004", ROOT);

  expect(parsed.name).toBe("export-s004");
  expect(existsSync(parsed.path)).toBe(false);
});

test("a malformed capture ID is rejected naming the expected shape", () => {
  expect(() => parseCaptureId("JRNY-001", ROOT)).toThrow(/expected SCRN-###\/name or JRNY-###\/name/);
  expect(() => parseCaptureId("docs/screenshots/import-s003.png", ROOT)).toThrow(/not a capture ID/);
  expect(() => journeyCapturePath(ROOT, "SCRN-001/empty", 1)).toThrow(
    /not a journey scenario ID/
  );
});

test("a shorter trail keeps its own steps and prunes only the ones above it", () => {
  const names = [
    "add-s001.png",
    "add-s002.png",
    "add-s003.png",
    "add-s004.png",
    "add-s004-error.png",
    "add-s005.png",
    "change-times-s004.png",
    "add.six.png",
    "add-s006.txt"
  ];

  expect(staleCaptureFiles(names, "add", 3)).toEqual([
    "add-s004.png",
    "add-s004-error.png",
    "add-s005.png"
  ]);
});

test("another scenario's capture files are never pruned", () => {
  const names = ["import-s001.png", "import-s002.png", "import-s003.png", "import-s004.png"];

  expect(staleCaptureFiles(names, "add", 2)).toEqual([]);
  expect(staleCaptureFiles(names, "import", 2)).toEqual(["import-s003.png", "import-s004.png"]);
});

test("a shortened trail with no captures to prune returns nothing", () => {
  expect(staleCaptureFiles(["import-s001.png", "import-s002.png"], "import", 2)).toEqual([]);
});

test("the writer stops when the capture root is not git-ignored", () => {
  expect(() => assertRootIgnored(ROOT, () => false)).toThrow(
    /the capture root is not git-ignored, so a capture would be committed/
  );
  expect(assertRootIgnored(ROOT, () => true)).toBe(ROOT);
});

test("the default check reads the real repository ignore rules", () => {
  const commonDir = execFileSync(
    "git",
    ["rev-parse", "--path-format=absolute", "--git-common-dir"],
    { encoding: "utf8" }
  ).trim();
  const primary = join(commonDir, "..");

  expect(defaultCheck(captureRoot(primary))).toBe(true);
  expect(defaultCheck(join(primary, "docs"))).toBe(false);
  expect(assertRootIgnored(captureRoot(primary))).toBe(captureRoot(primary));
  expect(() => assertRootIgnored(join(primary, "docs"))).toThrow(/not git-ignored/);
});
