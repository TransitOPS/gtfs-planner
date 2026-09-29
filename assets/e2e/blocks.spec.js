// Blocks browser journey (EV-28, step 29).
//
// The journey measures the Blocks page's layout and exercises its main edits
// against `.specs/05-basic-gtfs-blocking/refereneces/gtfs-blocking-prototype.html`
// (the reference's desktop workspace, cross-day review, pool paging and 375px
// list), reusing `assets/playwright.config.js`, `browser_helpers.js` and the
// login/`versionIdFor` pattern of `route_schedules.spec.js`.
//
// Every expectation is a literal value from the acceptance criteria or from the
// seeded "Browser Blocks Version" in `test/support/browser_seed.exs`, never a
// value read back from the surface under test: 34 blocks and 130 unassigned
// trips on the largest day type ({School days + Weekday service}, 24 dates), the
// same 34 blocks and the cross-day overlap's one fewer problem on {Weekday
// service} (16 dates), the three-hour `BB_LONG` bar over the day's 05:00–26:00
// axis, and `BB_SHARED`, which runs on both weekday day types and is assigned to
// the block whose school-day trip it overlaps only on the larger day type.
//
// Layout is measured with bounding boxes, not with pixels read from the design.
// One caveat from step 21 is load-bearing: `.blocks-bar` has `min-width: 24px`,
// so a five-minute bar (`BB_SHORT_HOP`) does not double under Zoom and is
// asserted at that floor instead; `BB_LONG` is three hours of a 21-hour axis and
// doubles exactly.
//
// Captures are written under `testInfo.outputPath` and copied to
// `.specs/05-basic-gtfs-blocking/evidence/browser/`; the last journey writes
// `qa-tour.md` from the measurements the earlier journeys recorded. `.specs/` is
// gitignored and lives in the primary checkout, so the reference render is
// skipped (never failed) when that workspace is not linked.
import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SPEC_PACKAGE = resolve(
  __dirname,
  "..",
  "..",
  ".specs",
  "05-basic-gtfs-blocking",
);
const EVIDENCE_DIR = resolve(SPEC_PACKAGE, "evidence", "browser");
const REFERENCE_PROTOTYPE = resolve(
  SPEC_PACKAGE,
  "refereneces",
  "gtfs-blocking-prototype.html",
);

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Blocks Version";
const DAY_TYPE_LARGEST = "School days + Weekday service";
const DAY_TYPE_WEEKDAY = "Weekday service";

const PAGE_SIZE = 100;
const BLOCKS = 34;
const POOL_TRIPS = 130;
const POOL_PAGE_1 = 100;
const POOL_PAGE_2 = POOL_TRIPS - POOL_PAGE_1;

// The seeded records each assertion names.
const LONG_TRIP = "BB_LONG"; // 05:15–08:15, well above the 24px bar floor
const SHORT_TRIP = "BB_SHORT_HOP"; // 06:00–06:05, clamped at the 24px floor
const BUSIEST_BLOCK = "BB-BUSIEST"; // six trips: the day's most
const CROSS_DAY_BLOCK = "BB-XOVER"; // one overlap on the largest day type only
const TARGET_BLOCK = "BB-TARGET"; // the assignment's destination
const SHARED_TRIP = "BB_SHARED"; // runs on both weekday day types
const FREQUENCY_TRIP = "BB_POOL_FREQ";
const UNTIMED_TRIP = "BB_POOL_UNTIMED";

const DESKTOP = { width: 1440, height: 1000 };
const NARROW = { width: 375, height: 812 };

// The reference states the journey renders beside production.
const REFERENCE_SCENARIOS = [
  ["workspace", "scenario=normal"],
  ["cross-day", "scenario=cross&panel=pool"],
  ["large", "scenario=large"],
];

// Measurements the qa tour reports; each journey fills its own keys.
const tour = {};

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// The seeded database names its published version, so the journey reads the
// version ID from the ordinary panel rather than assuming one.
async function versionIdFor(page, versionName = VERSION_NAME) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function blocksPath(versionId, query = "") {
  return `/gtfs/${versionId}/blocks${query}`;
}

// Saves a capture under the test's own output directory, then copies it into the
// spec package's browser-evidence folder (the card's capture artifact).
async function capture(page, testInfo, name, { fullPage = false } = {}) {
  const outputPath = testInfo.outputPath(`${name}.png`);
  mkdirSync(dirname(outputPath), { recursive: true });
  await page.screenshot({ path: outputPath, fullPage, animations: "disabled" });
  copyIntoEvidence(`${name}.png`, readFileSync(outputPath));
}

function copyIntoEvidence(name, contents) {
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  const target = resolve(EVIDENCE_DIR, name);
  writeFileSync(target, contents);
  return target;
}

// Selects one day type by its option label prefix ("Weekday service · 16 days").
async function selectDayType(page, label) {
  const value = await page.evaluate((prefix) => {
    const option = [...document.querySelectorAll("#blocks-day option")].find(
      (candidate) => candidate.textContent.trim().startsWith(prefix),
    );
    return option ? option.value : null;
  }, label);

  if (!value) throw new Error(`No day type option starts with ${label}`);
  await page.selectOption("#blocks-day", value);
  return value;
}

// The timeline's own geometry: how many whole 44px rows the scroll container
// shows, its width, and whether its table overflows it.
async function timelineGeometry(page) {
  return page.evaluate(() => {
    const container = document.querySelector("#blocks-timeline-scroll");
    if (!container) return null;

    const box = container.getBoundingClientRect();
    const rows = [...document.querySelectorAll("#blocks-timeline-body tr")];
    const complete = rows.filter((row) => {
      const rect = row.getBoundingClientRect();
      return rect.height > 0 && rect.top >= box.top - 1 && rect.bottom <= box.bottom + 1;
    });

    return {
      completeRows: complete.length,
      totalRows: rows.length,
      rowHeight: rows.length ? rows[0].getBoundingClientRect().height : 0,
      containerWidth: container.clientWidth,
      tableWidth: container.scrollWidth,
      scrollTop: container.scrollTop,
      scrollLeft: container.scrollLeft,
      overflowInside: container.scrollWidth > container.clientWidth,
    };
  });
}

// One rendered pool row, found by the natural trip ID its own controls carry.
function poolRow(page, tripId) {
  return page.locator(
    `#blocks-pool-table tr:has([phx-value-trip="${tripId}"])`,
  );
}

// The natural trip IDs of the rendered pool rows, in page order.
async function poolTripIds(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("#blocks-pool-table tr")].map(
      (row) => row.querySelector("strong")?.textContent.trim() ?? "",
    ),
  );
}

// The timeline streams its rows after mount, so every journey waits for the
// day's own 34 before measuring anything.
async function awaitTimeline(page, expected = BLOCKS) {
  await expect(page.locator("#blocks-timeline-body tr")).toHaveCount(expected);
}

async function blockBoxes(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("#blocks-timeline-body tr[data-block]")].map(
      (row) => ({
        block: row.dataset.block,
        trips: Number(row.querySelector(".blocks-meta-trips")?.textContent ?? -1),
      }),
    ),
  );
}

// The whole-day strip's Problems figure, read from the strip's own value cell.
async function problemsCount(page) {
  const value = page.locator(
    '#blocks-summary-counts [data-key="problems"] [data-role="count-strip-value"]',
  );
  await expect(value).toHaveCount(1);
  return Number(await value.textContent());
}

test.describe("Blocks page at 375x812", () => {
  test.use({ viewport: NARROW });

  test("the List view is the default and the page does not scroll sideways", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId));

    // The colocated hook patches `?view=list` once, so the narrow page never
    // renders the timeline.
    await expect(page).toHaveURL(/view=list/);
    await expect(page.locator("#blocks-timeline")).toHaveCount(0);
    await expect(page.locator('[data-role="list-block"]')).toHaveCount(BLOCKS);
    await expect(page.locator('[data-role="list-block"]').first()).toBeVisible();

    const listGeometry = await page.evaluate(() => ({
      bodyScrollWidth: document.body.scrollWidth,
      innerWidth: window.innerWidth,
      blocksLists: document.querySelectorAll("#blocks-lists section").length,
    }));
    expect(listGeometry.bodyScrollWidth).toBeLessThanOrEqual(
      listGeometry.innerWidth,
    );
    expect(await bodyFitsViewport(page)).toBe(true);

    tour.narrow = {
      view: "list",
      timelinePresent: false,
      listBlocks: BLOCKS,
      bodyScrollWidth: listGeometry.bodyScrollWidth,
      innerWidth: listGeometry.innerWidth,
    };

    await capture(page, testInfo, "blocks-list-375");

    // The List view itself, with each block's trips, gaps and issues stacked.
    await page.evaluate(() => window.scrollTo(0, 760));
    await capture(page, testInfo, "blocks-list-blocks-375");
  });
});

test.describe("Blocks workspace 1440x1000", () => {
  test.use({ viewport: DESKTOP });

  test("density, the quiet URL and the page-scoped theme", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId));

    // CR-7: the mount never patches the URL, and the page keeps one h1 and the
    // current Operations tab (CL-15).
    expect(new URL(page.url()).search).toBe("");
    await expect(page.locator("#blocks-page")).toBeVisible();
    await expect(page.locator("#blocks-page h1")).toHaveText("Blocks");
    await expect(
      page.locator("#operations-sub-nav a[aria-current='page']"),
    ).toHaveText("Blocks");

    // The largest day type is the default and holds the whole 34-block day.
    const selectedDay = await page
      .locator("#blocks-day")
      .evaluate((el) => el.selectedOptions[0].textContent.trim());
    expect(selectedDay).toBe(`${DAY_TYPE_LARGEST} · 24 days`);
    await expect(page.locator("#blocks-pager")).toContainText(
      `Showing 1–${BLOCKS} of ${BLOCKS} blocks`,
    );
    await awaitTimeline(page);

    const geometry = await timelineGeometry(page);
    expect(geometry.completeRows).toBeGreaterThanOrEqual(12);
    expect(geometry.totalRows).toBe(BLOCKS);
    expect(geometry.rowHeight).toBe(44);
    expect(geometry.containerWidth).toBe(geometry.tableWidth);
    expect(geometry.overflowInside).toBe(false);
    expect(await bodyFitsViewport(page)).toBe(true);

    // The page carries the design system's scope (`.ds-page` on `#blocks-page`):
    // the display font on the heading and the action colour on the page's one
    // primary control, the header's Review action.
    const heading = await page.locator("#blocks-page h1").evaluate((el) => {
      const style = getComputedStyle(el);
      return {
        family: style.fontFamily,
        size: style.fontSize,
        weight: style.fontWeight,
      };
    });
    expect(heading.family).toContain("Gabarito");
    expect(heading.size).toBe("28px");
    expect(heading.weight).toBe("600");

    const primary = await page
      .locator("#blocks-review-checks")
      .evaluate((el) => getComputedStyle(el).backgroundColor);
    expect(primary).toBe("rgb(200, 24, 112)");

    tour.desktop = {
      completeRows: geometry.completeRows,
      totalRows: geometry.totalRows,
      rowHeight: geometry.rowHeight,
      containerWidth: geometry.containerWidth,
      horizontalOverflow: geometry.overflowInside,
      headingFont: heading.family,
      headingSize: heading.size,
      primaryColor: primary,
    };

    await capture(page, testInfo, "blocks-desktop-1440");
  });

  test("the header row stays put while rows scroll inside the timeline", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId));
    await awaitTimeline(page);

    const container = page.locator("#blocks-timeline-scroll");
    await container.evaluate((node) => {
      node.scrollTop = 320;
    });

    const containerBox = await container.boundingBox();
    const headerBox = await page
      .locator("#blocks-timeline thead th.blocks-meta-block")
      .boundingBox();
    const axisHeaderBox = await page
      .locator("#blocks-timeline thead th.blocks-axis")
      .boundingBox();
    const axisTickBox = await page
      .locator("#blocks-timeline .blocks-axis-tick")
      .first()
      .boundingBox();
    const firstRowBox = await page
      .locator("#blocks-timeline-body tr")
      .first()
      .boundingBox();

    // The whole header row — the sticky sort cells and the axis cell — holds at
    // the top of the scrollport, and the axis labels stay in frame with it.
    for (const box of [headerBox, axisHeaderBox, axisTickBox]) {
      expect(box).not.toBeNull();
    }

    expect(Math.abs(headerBox.y - containerBox.y)).toBeLessThanOrEqual(1);
    expect(Math.abs(axisHeaderBox.y - containerBox.y)).toBeLessThanOrEqual(1);
    expect(axisTickBox.y).toBeGreaterThanOrEqual(containerBox.y - 1);
    expect(axisTickBox.y + axisTickBox.height).toBeLessThanOrEqual(
      containerBox.y + headerBox.height + 1,
    );
    // The first row has scrolled out, so the stickiness is doing the work.
    expect(firstRowBox.y + firstRowBox.height).toBeLessThanOrEqual(
      containerBox.y + 1,
    );

    tour.stickyHeader = {
      scrollTop: await container.evaluate((node) => node.scrollTop),
      headerOffset: Math.round((headerBox.y - containerBox.y) * 100) / 100,
      axisOffset: Math.round((axisHeaderBox.y - containerBox.y) * 100) / 100,
      axisTickOffset: Math.round((axisTickBox.y - containerBox.y) * 100) / 100,
    };

    await capture(page, testInfo, "sticky-scrolled-1440");
  });

  test("Zoom doubles a known bar and scrolls inside the timeline container", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId));
    await awaitTimeline(page);

    const longBar = page.locator(
      `[data-role="trip-bar"][data-trip="${LONG_TRIP}"]`,
    );
    await expect(longBar).toHaveCount(1);
    const dayWidth = (await longBar.boundingBox()).width;
    // Three hours of the day's 21-hour axis is far above the bar's 24px floor.
    expect(dayWidth).toBeGreaterThan(24);

    await page.locator('label[for="blocks-scale-option-zoom"]').click();
    await expect(page.locator("#blocks-timeline")).toHaveAttribute(
      "data-scale",
      "zoom",
    );

    const zoomWidth = (await longBar.boundingBox()).width;
    expect(Math.abs(zoomWidth - dayWidth * 2)).toBeLessThanOrEqual(2);

    // The five-minute bar is at the 24px floor at both scales, so no assertion
    // reads doubling off it (`min-width: 24px`): its Zoom width is the same
    // 24px, never twice the whole-day one.
    const shortBar = page.locator(
      `[data-role="trip-bar"][data-trip="${SHORT_TRIP}"]`,
    );
    const shortZoomWidth = (await shortBar.boundingBox()).width;
    expect(shortZoomWidth).toBe(24);
    expect(dayWidth).toBeGreaterThan(24);
    expect(shortZoomWidth).not.toBe(24 * 2);

    // Zoom's overflow stays inside `#blocks-timeline-scroll`, and the block
    // columns stay pinned while the track scrolls under them (FH-17).
    const geometry = await timelineGeometry(page);
    expect(geometry.overflowInside).toBe(true);

    const container = page.locator("#blocks-timeline-scroll");
    const beforeBox = await container.boundingBox();
    await container.evaluate((node) => {
      node.scrollLeft = 300;
    });
    const blockCellBox = await page
      .locator("#blocks-timeline-body tr .blocks-meta-block")
      .first()
      .boundingBox();
    const afterBox = await container.boundingBox();

    expect(await container.evaluate((node) => node.scrollLeft)).toBeGreaterThan(0);
    expect(await page.evaluate(() => window.scrollX)).toBe(0);
    expect(Math.abs(afterBox.x - beforeBox.x)).toBeLessThanOrEqual(1);
    expect(blockCellBox.x).toBeGreaterThanOrEqual(afterBox.x - 1);
    expect(await bodyFitsViewport(page)).toBe(true);

    tour.zoom = {
      dayWidth: Math.round(dayWidth * 100) / 100,
      zoomWidth: Math.round(zoomWidth * 100) / 100,
      shortBarZoomWidth: shortZoomWidth,
      containerWidth: geometry.containerWidth,
      tableWidth: geometry.tableWidth,
      pageScrollX: await page.evaluate(() => window.scrollX),
    };

    await capture(page, testInfo, "zoom-1440");
  });

  test("sorting by Trips puts the day's busiest block first", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId));
    await awaitTimeline(page);

    const before = await blockBoxes(page);
    expect(before.length).toBe(BLOCKS);
    expect(before[0].block).not.toBe(BUSIEST_BLOCK);

    const tripsHeader = page
      .locator("#blocks-timeline thead th")
      .filter({ has: page.locator("button.blocks-sort", { hasText: "Trips" }) });

    // The first click sorts ascending; the second reverses to descending, so
    // the day type's most-travelled block leads page 1.
    await tripsHeader.locator("button.blocks-sort").click();
    await expect(tripsHeader).toHaveAttribute("aria-sort", "ascending");
    await expect(tripsHeader.locator("button.blocks-sort")).toContainText("↑");
    expect((await blockBoxes(page))[0].block).not.toBe(BUSIEST_BLOCK);

    await tripsHeader.locator("button.blocks-sort").click();
    await expect(tripsHeader).toHaveAttribute("aria-sort", "descending");
    await expect(tripsHeader.locator("button.blocks-sort")).toContainText("↓");

    const sorted = await blockBoxes(page);
    expect(sorted[0]).toEqual({ block: BUSIEST_BLOCK, trips: 6 });
    // The order is non-increasing down the page, and the sort kept the whole day
    // type on one page: the pager still reports its own 34 blocks.
    for (let index = 1; index < sorted.length; index += 1) {
      expect(sorted[index - 1].trips).toBeGreaterThanOrEqual(sorted[index].trips);
    }
    expect(sorted[sorted.length - 1].trips).toBeLessThan(sorted[0].trips);
    await expect(page.locator("#blocks-pager")).toContainText(
      `Showing 1–${BLOCKS} of ${BLOCKS} blocks`,
    );
    await expect(page).toHaveURL(/sort=trips&dir=desc/);

    tour.sort = {
      defaultFirst: before[0].block,
      sortedFirst: sorted[0].block,
      sortedFirstTrips: sorted[0].trips,
      sortedLastTrips: sorted[sorted.length - 1].trips,
      pageSize: PAGE_SIZE,
      dayBlocks: sorted.length,
    };

    await capture(page, testInfo, "sorted-by-trips-1440");
  });

  test("the Unassigned panel pages: 100 trips, then the remaining 30", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId));

    await expect(page.locator("#panel-pool")).toContainText(
      new RegExp(`Unassigned trips\\s*${POOL_TRIPS}`),
    );
    await page.locator("#panel-pool").click();

    await expect(page.locator("#blocks-pool-table tr")).toHaveCount(POOL_PAGE_1);
    await expect(page.locator("#blocks-pool-pager")).toContainText(
      `Showing 1–${POOL_PAGE_1} of ${POOL_TRIPS} trips`,
    );
    // The pool names why a repeating trip and a trip without endpoint times
    // cannot be assigned (CL-16's eligibility copy in the pool). The untimed
    // trip sorts last in the pool, so page 1 does not hold its row at all (the
    // page's own `#blocks-untimed` disclosure is a separate list).
    await expect(
      poolRow(page, FREQUENCY_TRIP),
    ).toContainText("Repeats every 20 min · not a single trip");
    await expect(poolRow(page, UNTIMED_TRIP)).toHaveCount(0);

    const firstPageTrips = await poolTripIds(page);
    await page.locator("#blocks-pool-pager button", { hasText: "Next" }).click();

    await expect(page.locator("#blocks-pool-table tr")).toHaveCount(POOL_PAGE_2);
    await expect(page.locator("#blocks-pool-pager")).toContainText(
      `Showing ${POOL_PAGE_1 + 1}–${POOL_TRIPS} of ${POOL_TRIPS} trips`,
    );
    // The untimed trip is last, so it can only be reached on page 2.
    await expect(poolRow(page, UNTIMED_TRIP)).toContainText("Time missing");

    const secondPageTrips = await poolTripIds(page);
    expect(secondPageTrips.filter((trip) => firstPageTrips.includes(trip))).toEqual(
      [],
    );

    tour.pool = {
      total: POOL_TRIPS,
      page1Rows: firstPageTrips.length,
      page2Rows: secondPageTrips.length,
      frequencyText: "Repeats every 20 min · not a single trip",
      untimedText: "Time missing",
    };

    await capture(page, testInfo, "pool-page-2-1440");
  });

  test("the cross-day review lists “Also changes”, then persists", async ({
    page,
  }, testInfo) => {
    test.setTimeout(120_000);

    await logIn(page);
    const versionId = await versionIdFor(page);

    // The bigger day type holds the cross-day overlap and the smaller one does
    // not, so the journey assigns on the smaller one and reads the other's
    // consequence from the review (FH-9's cross-day case, AC-12).
    await page.goto(blocksPath(versionId));
    const largestProblems = await problemsCount(page);
    await expect(
      page.locator(`tr[data-block="${CROSS_DAY_BLOCK}"] [data-role="block-status"]`),
    ).toContainText("Overlap");

    await selectDayType(page, DAY_TYPE_WEEKDAY);
    await expect(
      page.locator(`tr[data-block="${CROSS_DAY_BLOCK}"] [data-role="block-status"]`),
    ).toContainText("No problems");
    const weekdayProblems = await problemsCount(page);
    expect(largestProblems).toBe(weekdayProblems + 1);

    await page.locator("#panel-pool").click();
    // The pool streams its first page in, so the journey waits for the page to
    // settle before it clicks a row: a click during a stream patch is dropped.
    await expect(page.locator("#blocks-pool-table tr")).toHaveCount(POOL_PAGE_1);

    const assignButton = page.locator(
      `[data-role="assign-trip"][phx-value-trip="${SHARED_TRIP}"]`,
    );
    await expect(assignButton).toHaveCount(1);

    // The assignment form lives in the trip drawer and patches `trip=`.
    await expect(async () => {
      await assignButton.click();
      await expect(page.locator("#trip-drawer")).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 15_000 });
    await expect(page).toHaveURL(new RegExp(`trip=${SHARED_TRIP}`));
    await expect(page.locator("#trip-drawer")).toBeVisible();
    await expect(page.locator("[data-role='trip-day-type']")).toHaveCount(2);

    // The picker lists at most 25 destinations, so the journey searches for the
    // exact block ID instead of expecting it in the unfiltered list (AC-26).
    await page.fill("#destination-search", TARGET_BLOCK);
    const targetOption = page.locator(
      `[data-role="destination-option"][data-block="${TARGET_BLOCK}"]`,
    );
    await expect(targetOption).toHaveCount(1);
    await expect(page.locator("#destination-summary")).toHaveText(
      "1 matching blocks",
    );
    await targetOption.locator("input").check();
    await page.locator("#assign-form button[type='submit']").click();

    // The review needs confirmation because the assignment adds an overlap on
    // the other weekday day type, which is listed under “Also changes”.
    await expect(page.locator("#block-review")).toBeVisible();
    const effects = page.locator('[data-role="review-effect"]');
    await expect(effects).toHaveCount(2);
    await expect(effects.first()).toHaveAttribute("data-selected", "true");
    await expect(effects.first()).toContainText("This service day");
    await expect(effects.first()).toContainText(DAY_TYPE_WEEKDAY);
    await expect(effects.first()).toContainText(
      "No new timing or transfer problems on these days.",
    );
    await expect(effects.nth(1)).toHaveAttribute("data-selected", "false");
    await expect(effects.nth(1)).toContainText("Also changes");
    await expect(effects.nth(1)).toContainText("School days + Weekday service");
    const added = effects.nth(1).locator('[data-role="review-added"]');
    await expect(added).toContainText("Overlap");
    await expect(added).toContainText("overlap by 30 min");
    await expect(page.locator("#block-review-confirm")).toHaveText("Assign 1 trip");
    await expect(page.locator("#block-review-changes-table")).toContainText(
      SHARED_TRIP,
    );

    await capture(page, testInfo, "review-cross-day-1440");

    await page.locator("#block-review-confirm").click();
    await expect(page.locator("#block-review")).toBeHidden();
    await expect(page.locator("#flash-info")).toContainText(
      `Assigned 1 trip to block ${TARGET_BLOCK}.`,
    );

    // The applied trip is in the destination block, off the pool, and the page
    // shows the row that now holds it.
    await expect(page.locator("#panel-pool")).toContainText(
      new RegExp(`Unassigned trips\\s*${POOL_TRIPS - 1}`),
    );
    await page.locator("#panel-blocks").click();
    await awaitTimeline(page);
    const targetRow = page.locator(
      `#blocks-timeline-body tr[data-block="${TARGET_BLOCK}"]`,
    );
    await expect(targetRow).toBeVisible();
    await expect(targetRow.locator(".blocks-meta-trips")).toHaveText("2");
    await expect(
      targetRow.locator(`[data-role="trip-bar"][data-trip="${SHARED_TRIP}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`[data-role="trip-bar"][data-trip="${SHARED_TRIP}"]`),
    ).toBeVisible();

    tour.review = {
      dayType: DAY_TYPE_WEEKDAY,
      largestDayTypeProblems: largestProblems,
      weekdayProblems,
      effects: 2,
      alsoChanges: "School days + Weekday service",
      addedProblem: "Overlap · Two trips in this block overlap by 30 min.",
      confirmLabel: "Assign 1 trip",
      poolAfter: POOL_TRIPS - 1,
    };

    await capture(page, testInfo, "assigned-trip-1440");
  });
});

test.describe("theme scope against a Routes page", () => {
  test.use({ viewport: DESKTOP });

  test("Routes keeps its own heading font and primary colour", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);

    await page.goto(`/gtfs/${versionId}/routes`);
    await expect(page.locator("main h1").first()).toHaveText("Routes");

    const routesHeading = await page.locator("main h1").first().evaluate((el) => {
      const style = getComputedStyle(el);
      return { family: style.fontFamily, size: style.fontSize };
    });
    const routesPrimary = await page
      .locator("#new-route-trigger")
      .evaluate((el) => getComputedStyle(el).backgroundColor);

    expect(routesHeading.family).toContain("Inter");
    expect(routesHeading.family).not.toContain("Gabarito");
    expect(routesPrimary).not.toBe("rgb(200, 24, 112)");

    // The same measurements inside the Blocks page, taken in the same session.
    await page.goto(blocksPath(versionId));
    const blocksHeading = await page.locator("#blocks-page h1").evaluate((el) => {
      const style = getComputedStyle(el);
      return { family: style.fontFamily, size: style.fontSize };
    });
    const blocksPrimary = await page
      .locator("#blocks-review-checks")
      .evaluate((el) => getComputedStyle(el).backgroundColor);

    expect(blocksHeading.family).toContain("Gabarito");
    expect(blocksHeading.size).toBe("28px");
    expect(blocksPrimary).toBe("rgb(200, 24, 112)");
    expect(blocksPrimary).not.toBe(routesPrimary);

    tour.themeScope = {
      routesHeadingFont: routesHeading.family,
      routesHeadingSize: routesHeading.size,
      routesPrimary,
      blocksHeadingFont: blocksHeading.family,
      blocksHeadingSize: blocksHeading.size,
      blocksPrimary,
    };

    await capture(page, testInfo, "routes-theme-1440");
  });
});

// The reference prototype, rendered from its own file beside production for the
// desktop, cross-day and large states and for the 375px list. The assertions
// come from the acceptance criteria, not from the prototype's pixels, so this
// journey records the side-by-side captures only; it is skipped when the
// gitignored `.specs/` workspace is not linked into the worktree.
test.describe("reference prototype captures", () => {
  test.skip(
    () => !existsSync(REFERENCE_PROTOTYPE),
    "reference prototype not present",
  );

  test("desktop and 375px states beside production", async ({
    page,
  }, testInfo) => {
    test.setTimeout(90_000);

    const referenceUrl = pathToFileURL(REFERENCE_PROTOTYPE).href;

    for (const [name, query] of REFERENCE_SCENARIOS) {
      await page.setViewportSize(DESKTOP);
      await page.goto(`${referenceUrl}?${query}`);
      await page.waitForLoadState("load");
      await expect(page.locator("body")).toBeVisible();

      // Recorded for the side-by-side capture only: the prototype's own markup
      // and pixels are not this gate's oracle.
      const bodyWidth = await page.evaluate(() => document.body.scrollWidth);
      tour[`reference_${name.replaceAll("-", "_")}`] = {
        scenario: query,
        bodyWidth,
        viewportWidth: DESKTOP.width,
      };
      await capture(page, testInfo, `reference-${name}-1440`);
    }

    await page.setViewportSize(NARROW);
    await page.goto(`${referenceUrl}?scenario=normal`);
    await page.waitForLoadState("domcontentloaded");
    await capture(page, testInfo, "reference-list-375");
  });
});

// The tour is the capture artifact's own index: entrypoint, setup, scenarios,
// expected outcomes and the automated coverage, with the numbers the journeys
// measured. It is written last so it reports the whole run.
test.describe("qa tour", () => {
  test.use({ viewport: DESKTOP });

  test("writes qa-tour.md from the measured journey", async ({}, testInfo) => {
    const value = (key) =>
      tour[key] === undefined ? "(not measured)" : JSON.stringify(tour[key]);

    const markdown = [
      "# Blocks browser QA tour (EV-28, step 29)",
      "",
      "Entrypoint: `/gtfs/<version>/blocks` for the published **Browser Blocks",
      `Version** seeded by \`test/support/browser_seed.exs\` (${BLOCKS} blocks and`,
      `${POOL_TRIPS} unassigned trips on the largest day type).`,
      "",
      "## Setup",
      "",
      "```sh",
      "bin/test-browser \\",
      "  e2e/blocks.spec.js e2e/ia_navigation.spec.js e2e/route_schedules.spec.js",
      "```",
      "",
      "The suite runs Chromium against a local test Phoenix server on a free port",
      "(`BROWSER_E2E=true`), one worker, no retries, against a throwaway Postgres",
      "that `bin/test-browser` creates, migrates and seeds for the run.",
      "`ia_navigation.spec.js` runs unchanged and `route_schedules.spec.js` keeps its",
      "read-only block assertions.",
      "",
      "## Scenarios and expected outcomes",
      "",
      "| Scenario | Expected outcome | Measured |",
      "|---|---|---|",
      "| Desktop workspace at 1440x1000 | \u2265 12 complete 44px rows, no page-level horizontal overflow, a quiet URL | " +
        value("desktop"),
      " |",
      "| Rows scrolled inside `#blocks-timeline-scroll` | The header row (sort cells and axis cell) stays at the scrollport top | " +
        value("stickyHeader"),
      " |",
      "| Zoom in | A known bar doubles within 2px, the overflow stays inside the container and the page does not scroll sideways | " +
        value("zoom"),
      " |",
      "| Sort by Trips (descending) | The day type's busiest block leads page 1 | " +
        value("sort"),
      " |",
      "| Unassigned panel | 100 trips on page 1, the remaining 30 on page 2 | " +
        value("pool"),
      " |",
      "| Assign the shared trip on the smaller weekday day type | The review lists the other day type under \u201cAlso changes\u201d with the added overlap; confirming persists it and shows the row that holds the trip | " +
        value("review"),
      " |",
      "| 375x812 | The List view is the default and the page does not scroll sideways | " +
        value("narrow"),
      " |",
      "| A Routes page | Keeps its own heading font and primary colour while `#blocks-page` uses Gabarito and #C81870 | " +
        value("themeScope"),
      " |",
      "",
      "## Automated coverage",
      "",
      "- `assets/e2e/blocks.spec.js` \u2014 the layout measurements, the workspace edits and",
      "  the reference captures above.",
      "- `assets/e2e/ia_navigation.spec.js` \u2014 unchanged: the Blocks link, its URL and",
      "  the Operations round trip.",
      "- `assets/e2e/route_schedules.spec.js` \u2014 the Schedules read view with the",
      "  read-only block assertions (`#trip-block-value`, `#trip-block-link`, no",
      "  `drawer[block_id]` input).",
      "- `test/support/browser_seed.exs` \u2014 the \u201cBrowser Blocks Version\u201d fixture the",
      "  journey above reads.",
      "",
      "## Prototype reference",
      "",
      "The reference prototype is rendered from its own file at `scenario=normal`,",
      "`scenario=cross&panel=pool` and `scenario=large` for the desktop captures and",
      "at `scenario=normal` for the 375px list, beside the production captures of the",
      "same states. Its footer controls are prototype-only and are not implemented.",
      "",
    ].join("\n");

    const outputPath = testInfo.outputPath("qa-tour.md");
    mkdirSync(dirname(outputPath), { recursive: true });
    writeFileSync(outputPath, markdown);
    const evidencePath = copyIntoEvidence("qa-tour.md", Buffer.from(markdown));

    expect(existsSync(evidencePath)).toBe(true);
    expect(readFileSync(evidencePath, "utf8")).toContain(
      "Blocks browser QA tour",
    );
    expect(readFileSync(evidencePath, "utf8")).toContain("bin/test-browser");
  });
});
