import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Pattern comparison journey (spec 19, step 11 and later visual steps).
 *
 * Step 11 owns this file's shared helpers (login, version, tile stub, capture).
 * Step 12 adds the `capture: shell` block for the page's own states; later
 * visual steps add their own blocks, and step 23 adds the journey over
 * BROWSER_COMPARE's seeded patterns (FULL, DEV, SHORT, LOOP, MOVED, BACK) and
 * the cross-route BROWSER-CMP-OTHER.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// Full-page captures go to PATTERN_COMPARE_CAPTURE_DIR when the operator sets
// it; a normal run writes nothing. The variable's path is anchored at the
// repository root, because `bin/test-browser` runs the suite through
// `npm --prefix assets`, whose script working directory is `assets/`: the
// prepared command names `.specs/19-pattern-comparison/evidence/captures/…`,
// which must land in the checkout's spec folder, not under `assets/`.
// An absolute setting is unaffected (resolve returns it as it is).
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const CAPTURE_DIR = process.env.PATTERN_COMPARE_CAPTURE_DIR
  ? resolve(REPO_ROOT, process.env.PATTERN_COMPARE_CAPTURE_DIR)
  : null;

// A verified-transparent 1×1 PNG served for every tile request, so captures
// never depend on the network or on Geoapify credits. (An earlier literal
// for this stub decoded to a half-green pixel and tinted the whole map.)
const BLANK_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=",
  "base64",
);

// Full-page captures go to PATTERN_COMPARE_CAPTURE_DIR when the operator sets
// it; a normal run writes nothing.
async function capture(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: true,
    animations: "disabled",
  });
}

async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function getVersionId(page, versionName = "Browser E2E Version") {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function collectPageErrors(page) {
  const problems = [];
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  return problems;
}

async function stubTiles(page) {
  await page.route("**/map/tiles/**", async (route) => {
    await route.fulfill({ contentType: "image/png", body: BLANK_PNG });
  });
}

// ── Shell captures (step 12) ─────────────────────────────────────────────────
//
// The compare page's own states: the title row with the view switch and the
// calendar, the loading skeleton and the phone layout. The skeleton is the
// page's disconnected render, so that capture holds the LiveView socket open
// and reads the static HTML.

const COMPARE_ROUTE = "BROWSER_COMPARE";

function compareUrl(versionId, query = "") {
  return `/gtfs/${versionId}/routes/${COMPARE_ROUTE}/patterns/compare${query}`;
}

test.describe("compare shell (step 12)", () => {
  test("capture: shell", async ({ page, context }) => {
    test.setTimeout(120_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    for (const [name, width, height] of [
      ["shell-1440", 1440, 900],
      ["shell-390", 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(compareUrl(versionId));
      await page.waitForSelector("#compare-calendar");
      await capture(page, name);
    }

    for (const [name, width, height] of [
      ["shell-loading-1440", 1440, 900],
      ["shell-loading-390", 390, 844],
    ]) {
      const loading = await context.newPage();

      await loading.route("**/live/websocket**", () => new Promise(() => {}));
      await stubTiles(loading);
      await loading.setViewportSize({ width, height });
      await loading.goto(compareUrl(versionId));
      await loading.waitForSelector("#compare-loading");
      await capture(loading, name);
      await loading.close();
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── Slot captures (step 13) ─────────────────────────────────────────────────
//
// The two slot cards and the swap in the prototype's states: the ideal pair,
// B on another route, an extension (B adds stops past A), the choose-B empty
// card and the unavailable B card. Every state waits on the part it adds.

test.describe("compare slots (step 13)", () => {
  test("capture: slots", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const states = [
      ["ideal", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT", "#slot-a h3"],
      ["cross-route", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-OTHER", "#slot-b h3"],
      ["extension", "?a=BROWSER-CMP-SHORT&b=BROWSER-CMP-FULL", "#slot-b h3"],
      ["choose-b", "?a=BROWSER-CMP-FULL", "#slot-b-empty"],
      ["stale-selection", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-UNKNOWN", "#slot-b-unavailable"],
    ];

    for (const [name, query, selector] of states) {
      for (const [width, height] of [
        [1440, 900],
        [390, 844],
      ]) {
        await page.setViewportSize({ width, height });
        await page.goto(compareUrl(versionId, query));
        await page.waitForSelector(selector);
        await capture(page, `slots-${name}-${width}`);
      }
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── Relationship captures (step 14) ─────────────────────────────────────────
//
// The relationship callouts and the reverse toggle: the opposite-direction
// pair before and after the reverse patch, an identical pair and a pair with
// no shared stops. The seed has no two distinct patterns with the same stops
// in the same order, so the identical state compares BROWSER-CMP-FULL with
// itself; EV-12's fixture covers two distinct patterns. The no-shared B is on
// another seeded route, as the prototype's own no-shared state is.

test.describe("compare relation (step 14)", () => {
  test("capture: relation", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const states = [
      ["reverse", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-BACK", "#relation-opposite"],
      ["reverse-on", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-BACK&reverse=1", "#relation-reversed"],
      ["identical", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-FULL", "#relation-identical"],
      ["no-shared", "?a=BROWSER-CMP-FULL&b=BROWSER-P1", "#relation-none"],
    ];

    for (const [name, query, selector] of states) {
      for (const [width, height] of [
        [1440, 900],
        [390, 844],
      ]) {
        await page.setViewportSize({ width, height });
        await page.goto(compareUrl(versionId, query));
        await page.waitForSelector(selector);
        await capture(page, `relation-${name}-${width}`);
      }
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── Summary captures (step 15) ──────────────────────────────────────────────
//
// The "What's different" card and its metric strip: the replacement pair (B
// adds two stops where A has one, 12 minutes longer over the stretch), the
// same pair read the other way (B skips them, 12 minutes less), the short turn
// (B ends where A continues) and the choose-B card's suggested comparisons.
// Every state waits on the part it adds.

test.describe("compare summary (step 15)", () => {
  test("capture: summary", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const states = [
      ["ideal", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV", "#summary-diff-1"],
      ["express", "?a=BROWSER-CMP-DEV&b=BROWSER-CMP-FULL", "#summary-diff-1"],
      ["short-turn", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT", "#summary-diff-1"],
      ["choose-b", "?a=BROWSER-CMP-FULL", "#summary-suggestions"],
    ];

    for (const [name, query, selector] of states) {
      for (const [width, height] of [
        [1440, 900],
        [390, 844],
      ]) {
        await page.setViewportSize({ width, height });
        await page.goto(compareUrl(versionId, query));
        await page.waitForSelector(selector);
        await capture(page, `summary-${name}-${width}`);
      }
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});
// ── Stop-table captures (step 16) ───────────────────────────────────────────
//
// The "Stop by stop" table: the deviation pair with its stretch note and
// running times, the short turn's −1:00 at the shared end stop, the loop's
// repeated visit, the moved stop's linked rows, the extension where B adds
// stops past A and the no-running-times side, whose cells read "—". Every
// state waits on the table's footer, which only renders with the table itself.
// The seed has no long pattern, so the reference's "large" (folded) state has
// no capture here; EV-14's 34-row fixture and the reference render cover the
// folds. The no-times pair compares BROWSER_PATTERNS_READY's BROWSER-P1 with a
// timings-less context pattern that serves the same first two stops, so the
// read has two shared anchors and no times to put in them.

test.describe("compare stop table (step 16)", () => {
  test("capture: table", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const noTimesUrl = `/gtfs/${versionId}/routes/BROWSER_PATTERNS_READY/patterns/compare?a=BROWSER-P1&b=BROWSER_CTX_01-P1`;

    const states = [
      ["ideal", compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV"), "#compare-rows tr[data-stop-id]"],
      ["short-turn", compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT"), "#stops-footer"],
      ["repeat", compareUrl(versionId, "?a=BROWSER-CMP-LOOP&b=BROWSER-CMP-FULL"), "#stops-footer"],
      ["moved", compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-MOVED"), "#stops-footer"],
      ["extension", compareUrl(versionId, "?a=BROWSER-CMP-SHORT&b=BROWSER-CMP-FULL"), "#stops-footer"],
      ["no-times", noTimesUrl, "#stops-footer"],
    ];

    for (const [name, url, selector] of states) {
      for (const [width, height] of [
        [1440, 900],
        [390, 844],
      ]) {
        await page.setViewportSize({ width, height });
        await page.goto(url);
        await page.waitForSelector(selector);
        await capture(page, `table-${name}-${width}`);
      }
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── Picker captures (step 18) ───────────────────────────────────────────────
//
// The pattern picker drawer over the seeded cross-route pair: the open list
// (ranked by stops in common, grouped this route by direction then Other
// routes, the other side disabled and the current row marked) and the
// filtered-empty state, at both viewports. The search filters in memory, so
// the browser types into #picker-q. The drawer's initial focus, the Clear
// search refocus and its return focus to Change B are client-side behaviour
// the ExUnit gate cannot observe, so they are asserted here.

test.describe("compare picker (step 18)", () => {
  test("capture: picker", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const pickerUrl = compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT&picker=b");

    for (const [width, height] of [
      [1440, 900],
      [390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(pickerUrl);
      await page.waitForSelector("#picker-list section");
      await expect(page.locator("#picker-q")).toBeFocused();
      await capture(page, `picker-open-${width}`);

      await page.fill("#picker-q", "Seal Rock");
      await page.waitForSelector("#picker-empty");
      await capture(page, `picker-empty-${width}`);
    }

    // Clear search empties the field and returns focus to it; the drawer's
    // Close button returns focus to the Change B button that opened it.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(pickerUrl);
    await page.waitForSelector("#picker-list section");
    await page.fill("#picker-q", "Seal Rock");
    await page.waitForSelector("#picker-empty");
    await page.click("#picker-clear");
    await expect(page.locator("#picker-q")).toBeFocused();
    await expect(page.locator("#picker-empty")).toHaveCount(0);

    await page.click("#compare-picker-close");
    await expect(page.locator("#compare-picker")).toHaveCount(0);
    await expect(page.locator("#slot-b-change")).toBeFocused();

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── All-patterns overview captures (step 19) ────────────────────────────────
//
// The direction's patterns as columns with the pick-two checkboxes: the plain
// overview at both viewports, the direction with a single pattern, and the two
// chosen columns the Compare button waits for. The picks are server state, so
// the picked capture clicks the checkboxes and waits for the header chips the
// server renders, which is the LiveView round trip rather than a client guess.

test.describe("compare overview (step 19)", () => {
  test("capture: overview", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    for (const [name, width, height] of [
      ["overview-1440", 1440, 900],
      ["overview-390", 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(compareUrl(versionId, "?view=all"));
      await page.waitForSelector("#overview-table tbody tr[data-stop-id]");
      await capture(page, name);
    }

    // Direction 1 holds BACK alone, so the overview is one column and its lane
    // runs the whole table.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(compareUrl(versionId, "?view=all&dir=1"));
    await page.waitForSelector("#overview-pattern-BROWSER-CMP-BACK");
    await capture(page, "overview-dir1-1440");

    for (const [name, width, height] of [
      ["overview-picked-1440", 1440, 900],
      ["overview-picked-390", 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(compareUrl(versionId, "?view=all"));
      await page.waitForSelector("#overview-table tbody tr[data-stop-id]");
      await page.click("#overview-pick-BROWSER-CMP-FULL");
      await page.click("#overview-pick-BROWSER-CMP-SHORT");

      await expect(page.locator("#overview-pattern-BROWSER-CMP-FULL")).toContainText("Pattern A");
      await expect(page.locator("#overview-pattern-BROWSER-CMP-SHORT")).toContainText("Pattern B");
      await expect(page.locator("#overview-compare")).toBeEnabled();
      await capture(page, name);
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── Map captures (step 21) ──────────────────────────────────────────────────
//
// The sticky map pane: the replacement pair (B replaces A's third stop with two
// stops) drawn from the map read at both viewports, with its numbered
// difference pins, and the pane's own unavailable composition. The database is
// healthy, so the unavailable map a browser can reach is the tile proxy
// failing: the hook's #compare-map-off then keeps the pane, the copy and the
// stop table, which is what the reference's map-unavailable state shows. The
// read-outage block #compare-map-unavailable is asserted by EV-19, which the
// browser cannot reach without a database outage.

test.describe("compare map (step 21)", () => {
  test("capture: map", async ({ page, context }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    for (const [name, width, height] of [
      ["map-1440", 1440, 900],
      ["map-390", 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV"));

      // Text readiness: the map read landed on the hook (both series drawn) and
      // the two differences are pinned (the replaced stop and the +1:00 stretch
      // into stop 5). The legend names what the hook drew.
      await page.waitForSelector(".compare-map-pin");
      await expect(page.locator("#compare-map")).toHaveAttribute(
        "data-map-payload",
        /"series":"both"/,
      );
      await expect(page.locator(".compare-map-pin")).toHaveCount(2);
      await expect(page.locator("#compare-map-legend")).toContainText("Only B");
      await expect(page.locator("#compare-map-legend")).toContainText("Difference");
      await capture(page, name);
    }

    // Below lg the pane stacks first at the map's 360 px height, above the
    // summary, so the map and the table are both on the one column.
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV"));
    await page.waitForSelector(".compare-map-pin");

    const mapBox = await page.locator("#compare-map").boundingBox();
    const paneBox = await page.locator("#compare-map-pane").boundingBox();
    const summaryBox = await page.locator("#compare-summary").boundingBox();

    expect(Math.round(mapBox.height)).toBe(360);
    expect(paneBox.y).toBeLessThan(summaryBox.y);

    // Tiles failing: the map degrades to the pane's notice and everything else
    // stays. The browser logs each failed tile, so only that line is ignored.
    const failed = await context.newPage();
    const failedProblems = collectPageErrors(failed);

    await failed.route("**/map/tiles/**", (route) => route.fulfill({ status: 500, body: "" }));
    await logIn(failed);

    for (const [name, width, height] of [
      ["map-unavailable-1440", 1440, 900],
      ["map-unavailable-390", 390, 844],
    ]) {
      await failed.setViewportSize({ width, height });
      await failed.goto(compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV"));

      await expect(failed.locator("#compare-map-off")).toBeVisible();
      await expect(failed.locator("#compare-map-off")).toContainText("The map is unavailable");
      await expect(failed.locator("#compare-map-off")).toContainText(
        "The stop list, differences and times still work.",
      );
      await expect(failed.locator("#compare-map-retry")).toHaveText("Retry map");
      await expect(failed.locator("#compare-stops")).toBeVisible();
      await capture(failed, name);
    }

    await failed.close();

    expect(problems, problems.join("\n")).toEqual([]);
    expect(
      failedProblems.filter((problem) => !problem.includes("Failed to load resource")),
      failedProblems.join("\n"),
    ).toEqual([]);
  });
});

// ── Entry captures (step 22) ────────────────────────────────────────────────
//
// The two entry points this step adds: the Patterns tab's secondary "Compare
// patterns" action beside Create pattern, and the pattern editor's "Compare
// with another pattern" link in the header's meta line. Each is followed in the
// browser, so the navigation itself is observed: the Patterns tab entry lands on
// the compare page and the mounted page patches in R8's default pair (FULL
// against SHORT on the seeded weekday calendar), and the editor link lands on
// the choose-B state with A alone, its suggestions and A's stops.

test.describe("compare entry (step 22)", () => {
  test("capture: entry", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const patternsUrl = `/gtfs/${versionId}/routes/${COMPARE_ROUTE}/patterns`;
    const editorUrl = `${patternsUrl}/BROWSER-CMP-FULL`;

    for (const [name, width, height] of [
      ["entry-1440", 1440, 900],
      ["entry-390", 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(patternsUrl);
      await page.waitForSelector("#patterns-compare");
      await expect(page.locator("#patterns-compare")).toContainText("Compare patterns");
      await expect(page.locator("#patterns-create")).toContainText("Create pattern");

      // The secondary entry and the primary beside it are both 44 px targets
      // (AC-24's floor); the route's one primary stays Create pattern.
      for (const selector of ["#patterns-compare", "#patterns-create"]) {
        const box = await page.locator(selector).boundingBox();
        expect(Math.round(box.height), `${selector} height`).toBeGreaterThanOrEqual(44);
      }

      await capture(page, name);
    }

    // The entry navigates to the compare page, which resolves R8's entry pair
    // from the seeded trips and patches it into the URL.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(patternsUrl);
    await page.locator("#patterns-compare").click();
    await page.waitForURL(
      (url) =>
        `${url.pathname}${url.search}` ===
        compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT"),
    );
    await page.waitForSelector("#slot-b");

    for (const [name, width, height] of [
      ["pattern-editor-1440", 1440, 900],
      ["pattern-editor-390", 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(editorUrl);
      await page.waitForSelector("#pattern-compare");
      await expect(page.locator("#pattern-compare")).toContainText(
        "Compare with another pattern",
      );

      const linkBox = await page.locator("#pattern-compare").boundingBox();
      expect(Math.round(linkBox.height), "#pattern-compare height").toBeGreaterThanOrEqual(44);

      await capture(page, name);
    }

    // The editor link opens the comparison with this pattern as A and no B.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(editorUrl);
    await page.locator("#pattern-compare").click();
    await page.waitForURL(
      (url) => `${url.pathname}${url.search}` === compareUrl(versionId, "?a=BROWSER-CMP-FULL"),
    );
    await page.waitForSelector("#summary-suggestions");

    for (const [name, width, height] of [
      ["choose-b-1440", 1440, 900],
      ["choose-b-390", 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(compareUrl(versionId, "?a=BROWSER-CMP-FULL"));
      await page.waitForSelector("#summary-suggestions");
      await expect(page.locator("#slot-b-empty")).toContainText("Choose a pattern to compare");
      await capture(page, name);
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── The journey (step 23) ───────────────────────────────────────────────────
//
// The end-to-end walk over the step-11 BROWSER_COMPARE fixtures, in acceptance
// order: the Patterns tab lands on R8's default pair (FULL against SHORT on the
// weekday calendar); clicking difference 1 marks its rows and reframes the
// Leaflet map; a stop marker click selects its row; the short turn reports
// −1:00 at the shared end stop; the loop keeps "visit 2 of 2"; the moved pair's
// "Go to B's visit" focuses the other row; the opposite pair asks to reverse B
// and then counts B's rings down; the picker finds the cross-route pattern by a
// stop name; the overview's two picks open the pair; tiles answering 500
// degrade only the map pane. The last test holds the 390 px obligations. Every
// scenario stubs the tiles before navigating (PM-7), so the journey is offline
// and spends no Geoapify credits.

const OTHER_PATTERN = "BROWSER-CMP-OTHER";
const STOP_1 = "BROWSER_CMP_STOP_1";
const STOP_2 = "BROWSER_CMP_STOP_2";
const STOP_3 = "BROWSER_CMP_STOP_3";
const STOP_3A = "BROWSER_CMP_STOP_3A";
const STOP_3B = "BROWSER_CMP_STOP_3B";
const STOP_4 = "BROWSER_CMP_STOP_4";
// The page's own formatters write U+2212 for a negative change and U+2019 in
// "Go to B's visit"; the journey asserts the same characters.
const MINUS_ONE_MINUTE = "\u22121:00";
// End to end is FULL's 18:30 against SHORT's 8:30 with R6's whole-percent
// change on the seeded difference.
const END_CHANGE = "\u221210:00 (\u221254%)";
const GOTO_B = "Go to B\u2019s visit";

// The LiveView root reports itself connected, so no interaction is clicked into
// a server-rendered page that has not hydrated or mounted its hooks yet
// (copied from pattern_alignment.spec.js).
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });

  await page.waitForFunction(
    () => {
      const main = document.querySelector("[data-phx-main]");
      return (
        Boolean(main) &&
        main.classList.contains("phx-connected") &&
        window.liveSocket?.isConnected()
      );
    },
    { timeout: 20000 },
  );
}

// One page load with the parts the scenario waits on. The tiles are already
// stubbed by the caller.
async function openCompare(page, versionId, query, ready = "#compare-stops") {
  await page.goto(compareUrl(versionId, query));
  await waitForLiveView(page);
  await page.waitForSelector(ready);
}

// The drawn route geometry in container pixels: the line paths only, not the
// stop circles, pins or rings, which are separate overlays. `fitBounds` resets
// the map pane to translate3d(0, 0, 0) on every setView (Leaflet's
// `_resetView`), so the pane's own transform cannot witness a reframe; the SVG
// lines are re-projected at zoomend, so a different set of `d` values is the
// map pane's evidence that the view moved.
async function mapGeometry(page) {
  await expect(page.locator("#compare-map")).not.toHaveClass(/leaflet-zoom-anim/);

  return page.evaluate(() => {
    const overlay = document.querySelector("#compare-map .leaflet-overlay-pane");
    if (!overlay) throw new Error("the comparison map has no overlay pane");
    return [...overlay.querySelectorAll('path[fill="none"]')]
      .map((path) => path.getAttribute("d"))
      .join("|");
  });
}

// The comparison view's projection origin: the overlay SVG's viewBox is
// written from the map's pixel origin, so it changes whenever the view is set
// (a load fit or a difference frame) and stays put while the same view is only
// decorated with selection or hover overlays.
async function mapViewBox(page) {
  return page.evaluate(() => {
    const svg = document.querySelector("#compare-map .leaflet-overlay-pane svg");
    if (!svg) throw new Error("the comparison map has no overlay svg");
    return svg.getAttribute("viewBox");
  });
}

// Clicks the square marker for one of DEV's own stops. The only-B stops draw as
// square divIcons, and their screen order follows their latitude, so the
// northern square is STOP_3B and the southern one STOP_3A. The click goes
// through the locator, which scrolls the pane into view and refuses to click
// when another element is the hit target.
async function clickStopSquare(page, stopId) {
  const squares = page.locator("#compare-map .compare-map-stop-square");
  await expect(squares).toHaveCount(2);

  const ys = await squares.evaluateAll((els) =>
    els.map((el) => el.getBoundingClientRect().y),
  );
  const order = ys[0] < ys[1] ? [0, 1] : [1, 0];
  const index = stopId === STOP_3B ? order[0] : order[1];

  await squares.nth(index).click();
}

// Every visible interactive target inside the compare page is at least 44 px
// high (AC-24), and the count proves the scan looked at real targets. A
// checkbox's target is the label that wraps it, and Leaflet's own attribution
// control is the map library's chrome rather than a compare control, so it is
// out of scope.
async function interactiveTargets(page) {
  return page.evaluate(() => {
    const root = document.querySelector("#compare-page");
    if (!root) throw new Error("the compare page is not rendered");

    let targets = 0;
    const short = [];
    const nodes = root.querySelectorAll(
      "a[href], button, select, input, summary, [role='button']",
    );

    for (const node of nodes) {
      if (node.closest(".leaflet-control-container")) continue;

      const target = node.closest("label") ?? node;
      const rect = target.getBoundingClientRect();
      if (node.closest("[hidden]") || rect.width === 0 || rect.height === 0) continue;

      targets += 1;

      if (rect.height < 44) {
        short.push(
          `${node.tagName.toLowerCase()}#${node.id || "-"} is ${Math.round(rect.height)}px`,
        );
      }
    }

    return { targets, short };
  });
}

test.describe("compare journey (step 23)", () => {
  test("opens the default pair from the Patterns tab", async ({ page }) => {
    test.setTimeout(120_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`/gtfs/${versionId}/routes/${COMPARE_ROUTE}/patterns`);
    await waitForLiveView(page);
    await page.locator("#patterns-compare").click();

    await page.waitForURL(
      (url) =>
        `${url.pathname}${url.search}` ===
        compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT"),
    );
    await waitForLiveView(page);

    await expect(page.locator("#slot-a")).toContainText("Browser Compare Full");
    await expect(page.locator("#slot-b")).toContainText("Browser Compare Short");
    // R8's default calendar is the seeded weekday one: FULL has 2 trips on it
    // and SHORT 1.
    await expect(page.locator("#compare-calendar")).toHaveValue("BROWSER_CMP_WEEKDAY");
    await expect(page.locator("#compare-calendar option:checked")).toHaveText(
      "Weekday (A 2 · B 1 trips)",
    );
    await capture(page, "journey-entry-1440");

    expect(problems, problems.join("\n")).toEqual([]);
  });

  test("marks a difference's rows, reframes the map and links a stop marker to its row", async ({
    page,
  }) => {
    test.setTimeout(240_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 900 });
    await openCompare(page, versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV");
    await page.waitForSelector(".compare-map-pin");
    // DEV replaces FULL's third stop with two stops and runs +1:00 into stop 5:
    // two differences, numbered 1 and 2 in the summary and on the map.
    await expect(page.locator(".compare-map-pin")).toHaveCount(2);
    const before = await mapGeometry(page);

    await page.locator("#summary-diff-1").click();
    await expect(page.locator("#summary-diff-1")).toHaveAttribute("aria-pressed", "true");

    const diffRows = (await page.locator("#summary-diff-1").getAttribute("data-diff-rows")).split(
      ",",
    );
    expect(diffRows.length).toBeGreaterThan(0);
    await expect(page.locator("#compare-rows tr.bg-selection")).toHaveCount(diffRows.length);
    expect(
      await page
        .locator("#compare-rows tr.bg-selection")
        .evaluateAll((rows) => rows.map((row) => row.dataset.row).sort()),
    ).toEqual([...diffRows].sort());
    await expect(page.locator("#stops-position")).toHaveText("Difference 1 of 2");

    // The click frames the map on the difference: the same stops project to a
    // different place.
    await expect.poll(() => mapGeometry(page), { timeout: 15000 }).not.toBe(before);

    await capture(page, "journey-difference-1440");

    // A stop marker click selects its row (AC-22). Each of DEV's own stops has
    // exactly one row, and the two clicks select their own rows.
    await openCompare(page, versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV", "#compare-rows tr[data-type='b']");
    await page.waitForSelector(".compare-map-stop-square");

    const loaded = await mapViewBox(page);

    for (const stopId of [STOP_3B, STOP_3A]) {
      await clickStopSquare(page, stopId);
      await expect(page.locator(`#compare-rows tr[data-stop-id="${stopId}"]`)).toHaveClass(
        /bg-selection/,
      );
      await expect(page.locator("#compare-rows tr.bg-selection")).toHaveCount(1);
      // Selecting a row is not a reframe: the map keeps the fit it made once at
      // load, and only a difference frames it again (FH-29).
      expect(await mapViewBox(page)).toBe(loaded);
    }

    await capture(page, "journey-marker-1440");

    expect(problems, problems.join("\n")).toEqual([]);
  });

  test("reports the short turn's −1:00 at the shared end stop", async ({ page }) => {
    test.setTimeout(120_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 900 });
    await openCompare(page, versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT");

    // The seeded offsets: FULL reaches stop 4 at 570 s and leaves at 630 s,
    // SHORT arrives at 510 s, so the stretch into stop 4 is 60 s quicker in B
    // and the two patterns end 10 minutes apart.
    await expect(page.locator(`#compare-rows tr[data-stop-id="${STOP_4}"]`)).toContainText(
      MINUS_ONE_MINUTE,
    );
    await expect(page.locator("#summary-end-a")).toHaveText("18:30");
    await expect(page.locator("#summary-end-b")).toHaveText("8:30");
    await expect(page.locator("#summary-end-change")).toHaveText(END_CHANGE);

    await capture(page, "journey-short-turn-1440");

    expect(problems, problems.join("\n")).toEqual([]);
  });

  test("keeps the loop's second visit and links the moved pair", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 900 });
    await openCompare(page, versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-LOOP");

    // LOOP visits stops 1 and 2 twice; each second visit keeps its own row and
    // says which visit it is. A's own rows carry no visit label.
    for (const stopId of [STOP_1, STOP_2]) {
      await expect(
        page.locator(`#compare-rows tr[data-type="b"][data-stop-id="${stopId}"]`),
      ).toContainText("visit 2 of 2");
      await expect(
        page.locator(`#compare-rows tr[data-type="same"][data-stop-id="${stopId}"]`),
      ).not.toContainText("visit");
    }

    await capture(page, "journey-loop-1440");

    // MOVED serves stop 3 before stop 2: both rows show "Order differs", and the
    // A-side row's link focuses B's visit of the same stop. The link is reached
    // with the keyboard, so its focusability is observed too.
    await openCompare(page, versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-MOVED");
    const movedRow = page.locator(
      `#compare-rows tr[data-type="a"][data-stop-id="${STOP_3}"][data-moved-row]`,
    );
    await expect(movedRow).toContainText("Order differs");
    await expect(movedRow).toContainText("Stop 3 in A · stop 2 in B");
    await expect(movedRow).toContainText(GOTO_B);
    await expect(
      page.locator(`#compare-rows tr[data-type="b"][data-stop-id="${STOP_3}"][data-moved-row]`),
    ).toContainText("Go to A\u2019s visit");

    // The difference cell renders twice (a phone copy and a desktop copy), so
    // the link is taken from the visible one.
    const link = movedRow.locator("a[data-goto-row]:visible");
    const target = await link.getAttribute("data-goto-row");
    await link.focus();
    await expect(link).toBeFocused();
    await page.keyboard.press("Enter");

    const targetRow = page.locator(`#compare-rows tr[data-row="${target}"]`);
    await expect(targetRow).toHaveClass(/bg-selection/);
    await expect(targetRow).toBeInViewport();
    await expect(page.locator("#compare-rows tr.bg-selection")).toHaveCount(1);
    // The anchor's href is the row id; the hook keeps the URL's hash empty.
    expect(new URL(page.url()).hash).toBe("");

    await capture(page, "journey-moved-1440");

    expect(problems, problems.join("\n")).toEqual([]);
  });

  test("asks to reverse an opposite pair and then counts B's rings down", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 900 });
    await openCompare(page, versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-BACK");

    await expect(page.locator("#relation-opposite")).toContainText(
      "These patterns run in opposite directions",
    );
    await expect(page.locator("#compare-reverse-toggle")).toHaveText("Show B in reverse order");
    await capture(page, "journey-opposite-1440");

    await page.locator("#compare-reverse-toggle").click();
    await page.waitForSelector("#relation-reversed");

    expect(new URL(page.url()).searchParams.get("reverse")).toBe("1");
    await expect(page.locator("#compare-reverse-toggle")).toHaveText("Show B in its own order");

    // B's rings count down from its own six visits while A's count up, and no
    // running times are compared (R4).
    const [aNumbers, bNumbers] = await page
      .locator("#compare-rows tr[data-row]")
      .evaluateAll((rows) => [
        rows.map((row) => row.children[0].textContent.trim()),
        rows.map((row) => row.children[1].textContent.trim()),
      ]);
    expect(aNumbers).toEqual(["1", "2", "3", "4", "5", "6"]);
    expect(bNumbers).toEqual(["6", "5", "4", "3", "2", "1"]);
    await expect(page.locator("#compare-stops")).not.toContainText("B vs A");

    await capture(page, "journey-reversed-1440");

    expect(problems, problems.join("\n")).toEqual([]);
  });

  test("finds the other route's pattern in the picker by a served stop name", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 900 });
    await openCompare(
      page,
      versionId,
      "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT&picker=b",
      "#picker-list section",
    );

    // The search reads served stop names: "Other Terminal" is a stop only
    // BROWSER-CMP-OTHER serves, so the filter leaves that one row.
    await page.fill("#picker-q", "Other Terminal");
    const otherRow = page.locator(`#picker-pattern-${OTHER_PATTERN}`);
    await expect(otherRow).toBeVisible();
    await expect(page.locator("#picker-list button[id^='picker-pattern-']")).toHaveCount(1);
    await expect(otherRow).toContainText("Browser Compare Other");
    await expect(otherRow).toContainText("stops at Browser Compare Other Terminal");
    await expect(
      page.locator("#picker-list section").filter({ hasText: "Other routes" }),
    ).toContainText("Browser Compare Other");

    await capture(page, "journey-picker-1440");

    await otherRow.click();
    await page.waitForURL(
      (url) =>
        url.pathname.endsWith("/patterns/compare") &&
        url.searchParams.get("a") === "BROWSER-CMP-FULL" &&
        url.searchParams.get("b") === OTHER_PATTERN &&
        !url.searchParams.has("picker"),
    );

    // B is on another route now, so its slot carries that route's badge.
    await expect(page.locator("#slot-b")).toContainText("Browser Compare Other");
    await expect(page.locator("#slot-b")).toContainText("BO");
    await expect(page.locator("#slot-a")).toContainText("Browser Compare Full");
    await capture(page, "journey-picker-chosen-1440");

    expect(problems, problems.join("\n")).toEqual([]);
  });

  test("opens the two picked patterns from the overview", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 900 });
    await openCompare(page, versionId, "?view=all", "#overview-table tbody tr[data-stop-id]");

    await page.click("#overview-pick-BROWSER-CMP-FULL");
    await page.click("#overview-pick-BROWSER-CMP-SHORT");
    await expect(page.locator("#overview-pattern-BROWSER-CMP-FULL")).toContainText("Pattern A");
    await expect(page.locator("#overview-pattern-BROWSER-CMP-SHORT")).toContainText("Pattern B");
    await expect(page.locator("#overview-compare")).toBeEnabled();
    await capture(page, "journey-overview-picked-1440");

    await page.locator("#overview-compare").click();
    await page.waitForURL(
      (url) =>
        `${url.pathname}${url.search}` ===
        compareUrl(versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT"),
    );

    await expect(page.locator("#slot-a")).toContainText("Browser Compare Full");
    await expect(page.locator("#slot-b")).toContainText("Browser Compare Short");
    await expect(page.locator("#compare-view-two")).toHaveAttribute("aria-current", "page");
    await capture(page, "journey-overview-compare-1440");

    expect(problems, problems.join("\n")).toEqual([]);
  });

  test("keeps the stop list when the tiles fail", async ({ page }) => {
    test.setTimeout(120_000);

    const problems = collectPageErrors(page);

    await page.route("**/map/tiles/**", (route) => route.fulfill({ status: 500, body: "" }));
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 900 });
    await openCompare(page, versionId, "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV", ".compare-map-pin");

    await expect(page.locator("#compare-map-off")).toBeVisible();
    await expect(page.locator("#compare-map-off")).toContainText("The map is unavailable");
    await expect(page.locator("#compare-map-retry")).toHaveText("Retry map");
    await expect(page.locator("#compare-stops")).toBeVisible();
    await capture(page, "journey-map-unavailable-1440");

    expect(
      problems.filter((problem) => !problem.includes("Failed to load resource")),
      problems.join("\n"),
    ).toEqual([]);
  });

  test("holds the compare page at 390 px", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    for (const [name, query, ready] of [
      ["journey-phone-pair-390", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-DEV", "#compare-rows tr[data-row]"],
      ["journey-phone-overview-390", "?view=all", "#overview-table tbody tr[data-stop-id]"],
    ]) {
      await page.setViewportSize({ width: 390, height: 844 });
      await openCompare(page, versionId, query, ready);

      expect(await bodyFitsViewport(page), `horizontal overflow for ${query}`).toBe(true);

      const primaries = await page.locator("#compare-page .btn-primary:visible").count();
      expect(primaries, `visible primary actions for ${query}`).toBeLessThanOrEqual(1);

      const { targets, short } = await interactiveTargets(page);
      expect(targets, `interactive targets found for ${query}`).toBeGreaterThan(10);
      expect(short, `targets under 44 px for ${query}`).toEqual([]);

      await capture(page, name);
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});
