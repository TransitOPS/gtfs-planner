// Runs browser journey.
//
// The journey exercises the Runs page end to end in Chromium at 1440x1000 against
// the seeded "Browser Runs Version" in `test/support/browser_seed.exs` — the
// version that carries the prototype's default runs problems — and captures the
// key states for comparison with the Runs design prototype.
//
// The seed, read from `test/support/browser_seed.exs` and not from the page:
//
//   * two calendars, {WKDY} and {SAT}. Weekday is the default and the only day
//     type this journey opens. Saturday carries run "2001" as well, which is a
//     different run from the weekday "2001" — the same ID on two day types is
//     two pieces of saved work, and the Saturday one is never opened here;
//   * six weekday runs, 2001-2006. 2001 works blocks 101 and 104 and is a
//     :SPLIT (the break between them is 30060 s, past the 30-minute paid-break
//     maximum). 2002 works blocks 102 and 106 with a 300 s break and is
//     :STRAIGHT — the only difference between the two is the length of the gap.
//     2003 works five trips of block 103 and raises :piece_too_long; the
//     handover from 2003 to 2004 happens at Market Street, which is not a
//     relief point, so it raises :not_at_relief. 2005 and 2006 are one-piece
//     runs on 107 and 108;
//   * block 105 is assigned to nothing. Its two trips, 1033 and 1034, are the
//     uncovered work, so the count is 2;
//   * relief points at Northgate and Southgate, each a location_type 1 station
//     with one bay beneath it. Block 101 hands over at the Northgate bay
//     between trips 1001 and 1002, which is the relief window the split uses;
//   * `max_piece_minutes` 330 and the default crew rules: 15 min pull-out
//     report, 5 min relief, 5 min sign-off, 30 min paid break, 720 min spread.
//     The pull-out report is 0-30, so 200 is out of range.
//
// Two places where this journey asserts what the application does rather than
// what the design reference shows, because the application deliberately differs:
//
//   * the reference draws a `⇄` glyph at a relief handover. The application
//     writes the words "(relief point)" instead — a glyph beside a number is
//     not available to a screen reader;
//   * `browser_helpers.js` has no shared log-in or capture helper. The
//     repository's own e2e specs (`blocks_advanced.spec.js`) each define a local
//     `logIn` and a local `capture` against `testInfo.outputPath`, and this file
//     follows that pattern rather than inventing a shared helper the other specs
//     do not use.
//
// The journeys share one reset-and-seeded database, so they are serial and run in
// this order: the measuring journeys read the day the seed made, the split
// journey undoes its own write, and the two that change the day come after
// everything that reads it.
//
// Captures are written under `testInfo.outputPath`.
import { test, expect } from "@playwright/test";
import { bodyFitsViewport, captureShot } from "./browser_helpers";

// The seeded editor, the same account `blocks_advanced.spec.js` uses.
const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Runs Version";

// The six seeded weekday runs and the two trips that belong to no run.
const SEEDED_RUNS = ["2001", "2002", "2003", "2004", "2005", "2006"];
const UNCOVERED_TRIPS = 2;
// The next free number after 2001-2006 on the weekday day type. Saturday's
// 2001 and 2009 are scoped to Saturday and do not consume it.
const NEXT_RUN_ID = "2007";
// The handover in block 101, between trips 1001 and 1002, at the Northgate bay.
const RELIEF_HANDOVER = "1";

const ROW_PX = 44;
const BAR_PX = 28;

const DESKTOP = { width: 1440, height: 1000 };
// The mobile viewport the toast shell is asserted and captured at.
const MOBILE = { width: 390, height: 844 };

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

function runsPath(versionId, query = "") {
  return `/gtfs/${versionId}/runs${query}`;
}

// The timeline streams its rows after mount, so every journey waits for the day
// to draw its runs before measuring or clicking anything. The row count is the
// seed's six, which is the first thing a wrong day type or a partial load
// would change.
async function openRuns(page, versionId, query = "", expected = SEEDED_RUNS.length) {
  await page.goto(runsPath(versionId, query));
  const rows = page.locator("#runs-timeline-body tr");
  await expect(rows).toHaveCount(expected, { timeout: 30_000 });
  await expect(page.locator("#runs-timeline")).toBeVisible();
}

// The run IDs as the page prints them, in the order it prints them.
async function runIds(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("#runs-timeline-body tr")].map((row) =>
      row.getAttribute("data-run"),
    ),
  );
}

// The seven fact cells the timeline and the list share, so a journey can read a
// run's figures without going to the drawer.
async function runFacts(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("#runs-timeline-body tr")].map((row) => ({
      run: row.getAttribute("data-run"),
      type: row.getAttribute("data-type"),
      paid: row.querySelector("[data-role='run-paid']")?.textContent.trim(),
      status: row.querySelector("[data-role='run-status-label']")?.textContent.trim(),
    })),
  );
}

// Saves a capture under the test's own output directory.
async function capture(page, testInfo, name, { fullPage = false } = {}) {
  await page.screenshot({
    path: testInfo.outputPath(`${name}.png`),
    fullPage,
    animations: "disabled",
  });
}

// A drawer is a top-layer `<dialog>`; the shared component carries its open
// state on the overlay, so every drawer wait reads the component's own
// attribute rather than a class or a computed style. `CoreComponents.drawer/1`
// renders that dialog as `<id>-overlay`, so these take the drawer's own id.
async function openDrawer(page, drawerId) {
  await expect(page.locator(`#${drawerId}-overlay[data-open="true"]`)).toBeVisible();
}

async function closeDrawer(page, drawerId) {
  await expect(page.locator(`#${drawerId}-overlay`)).toHaveAttribute("data-open", "false");
}

function toastText(page) {
  return page.locator("[data-role='toast-text']");
}

// The toast shell's computed bounds at the width being measured: the shell
// sits inside the viewport, the dismiss control keeps its 44px target, and
// the Undo action keeps its 44px height.
async function expectToastShellFits(page, width) {
  const shell = await page.locator("#runs-toast").boundingBox();
  const dismiss = await page
    .locator("#runs-toast [data-role='dismiss-toast']")
    .boundingBox();
  const undo = await page.locator("#runs-undo").boundingBox();

  expect(shell, "the toast shell must be rendered").not.toBeNull();
  expect(dismiss, "the dismiss control must be rendered").not.toBeNull();
  expect(undo, "the Undo control must be rendered").not.toBeNull();
  expect(shell.x).toBeGreaterThanOrEqual(0);
  expect(shell.x + shell.width).toBeLessThanOrEqual(width);
  expect(dismiss.width).toBeGreaterThanOrEqual(44);
  expect(dismiss.height).toBeGreaterThanOrEqual(44);
  expect(undo.height).toBeGreaterThanOrEqual(44);
}

// The suggestion drawer, opened from the page's own Suggest runs control.
async function openSuggest(page) {
  await page.locator("[data-role='suggest-runs']").click();
  await openDrawer(page, "runs-suggest-drawer");
}

test.describe("Runs page at 1440x1000", () => {
  test.use({ viewport: DESKTOP });
  // The journeys share one seeded database and the later ones write; running
  // them out of order would read a day an earlier one had already changed.
  test.describe.configure({ mode: "serial" });

  test("duty-chart rows measure 44 px and piece bars 28 px", async ({ page }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId);

    // The seed's own six runs, so a journey that measured the wrong day would
    // not measure six rows and quietly pass.
    expect([...(await runIds(page))].sort()).toEqual([...SEEDED_RUNS].sort());

    // A row is a person, so it gets the 44 px target. The bar inside it is the
    // one target the design system allows below 44.
    const rowHeights = await page
      .locator("#runs-timeline-body tr")
      .evaluateAll((rows) => rows.map((row) => row.getBoundingClientRect().height));

    expect(rowHeights.length).toBe(SEEDED_RUNS.length);
    for (const height of rowHeights) {
      expect(height).toBeCloseTo(ROW_PX, 0);
    }

    const barHeights = await page
      .locator("#runs-timeline [data-role='piece']")
      .evaluateAll((bars) => bars.map((bar) => bar.getBoundingClientRect().height));

    // Every run has at least one piece, and 2001 and 2002 have two each, so a
    // chart that drew one bar per run would measure six and pass the loop.
    expect(barHeights.length).toBeGreaterThan(SEEDED_RUNS.length);
    for (const height of barHeights) {
      expect(height).toBeCloseTo(BAR_PX, 0);
    }

    await capture(page, testInfo, "runs-default-chart-1440");
  });

  test("the page has no horizontal scroll at 1440×1000", async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId);

    // The reader asked for a wide frame, and the chart fits inside it: the
    // track is the flexible column and the fact columns are fixed, so a chart
    // wider than the page would mean one of the two grew.
    expect(await bodyFitsViewport(page)).toBe(true);

    // And the same after Zoom in, which doubles the track and is the state most
    // likely to push a page wide: the scroll belongs to #runs-timeline-scroll,
    // not to the document.
    // The radio is visually hidden behind its label, so the label is clicked.
    await page.locator('label[for="runs-scale-option-zoom"]').click();
    await expect(page.locator("#runs-timeline")).toHaveAttribute("data-scale", "zoom");
    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("after Zoom in and scrolling the track, Run and Status stay visible", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId);

    // The radio is visually hidden behind its label, so the label is clicked.
    await page.locator('label[for="runs-scale-option-zoom"]').click();
    await expect(page.locator("#runs-timeline")).toHaveAttribute("data-scale", "zoom");

    // Every fact column, not only Run and Status. The header cells are named from
    // the sort keys (`sign_on`, `sign_off`) and the body cells from `run_facts/1`'s
    // keys (`on`, `off`), and the two sets did not agree — so a check that only
    // watched Run and Status would have missed the columns that scrolled their
    // label away. This reads all seven, from the header and from the first row,
    // and asserts both moved not at all.
    const before = await page.evaluate(() => {
      const scroller = document.querySelector("#runs-timeline-scroll");
      const row = document.querySelector("#runs-timeline-body tr");
      const lefts = (nodes) =>
        [...nodes].map((node) => Math.round(node.getBoundingClientRect().left));
      return {
        scrollLeft: scroller.scrollLeft,
        scrollWidth: scroller.scrollWidth,
        clientWidth: scroller.clientWidth,
        headLefts: lefts(document.querySelectorAll("#runs-timeline thead th.runs-meta")),
        bodyLefts: lefts(row.querySelectorAll("[class*='runs-meta-']")),
        runText: row.querySelector("[data-role='run-id']").textContent.trim(),
        statusText: row.querySelector(".runs-meta-status").textContent.trim(),
      };
    });

    // Seven fact columns on each side, in the order the table declares them.
    expect(before.headLefts).toHaveLength(7);
    expect(before.bodyLefts).toHaveLength(7);

    // Zoom has to have widened the track, or there is nothing to scroll and
    // the sticky check below would pass without moving.
    expect(before.scrollWidth).toBeGreaterThan(before.clientWidth);

    await page.evaluate(() => {
      const scroller = document.querySelector("#runs-timeline-scroll");
      scroller.scrollLeft = scroller.scrollWidth;
    });

    const after = await page.evaluate(() => {
      const scroller = document.querySelector("#runs-timeline-scroll");
      const row = document.querySelector("#runs-timeline-body tr");
      const lefts = (nodes) =>
        [...nodes].map((node) => Math.round(node.getBoundingClientRect().left));
      return {
        scrollLeft: scroller.scrollLeft,
        headLefts: lefts(document.querySelectorAll("#runs-timeline thead th.runs-meta")),
        bodyLefts: lefts(row.querySelectorAll("[class*='runs-meta-']")),
        scrollerLeft: Math.round(scroller.getBoundingClientRect().left),
      };
    });

    // The scroller really moved.
    expect(after.scrollLeft).toBeGreaterThan(0);

    // And not one of the seven fact columns moved, header or body. A sticky
    // cell without a `left` keeps `top` and loses its horizontal anchor, so
    // this is the check that would have caught the `sign_on`/`on` mismatch.
    expect(after.headLefts).toEqual(before.headLefts);
    expect(after.bodyLefts).toEqual(before.bodyLefts);

    // The first fact column is pinned to the scroller's own left edge.
    expect(after.headLefts[0]).toBe(after.scrollerLeft);
    expect(after.bodyLefts[0]).toBe(after.scrollerLeft);

    // The fact columns are laid out left to right, so their offsets ascend:
    // a rule that pinned two of them to the same edge would fail here.
    const ordered = [...after.bodyLefts].sort((a, b) => a - b);
    expect(after.bodyLefts).toEqual(ordered);

    await capture(page, testInfo, "runs-zoomed-chart-1440");
  });

  test("sorting by Paid reorders rows", async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId);

    // The default order is sign-on, ascending, and the page says so in the
    // header's own `aria-sort` rather than in a class.
    const paidHeader = page.locator("th.runs-meta-paid");
    const signOnHeader = page.locator("th.runs-meta-sign_on");
    await expect(signOnHeader).toHaveAttribute("aria-sort", "ascending");

    const before = await runIds(page);

    await page.locator("th.runs-meta-paid button").click();
    await expect(paidHeader).toHaveAttribute("aria-sort", "ascending");

    const after = await runIds(page);
    const facts = await runFacts(page);

    // Still the same six runs, in a different order.
    expect([...after].sort()).toEqual([...SEEDED_RUNS].sort());
    expect(after).not.toEqual(before);

    // And they are in fact ordered by the column that was clicked. The Paid
    // cell reads `h:mm`, so it is compared as minutes rather than as text —
    // "10:00" sorts before "9:00" as a string and after it as a time.
    const minutes = facts.map((fact) => {
      const [h, m] = fact.paid.split(":");
      return Number(h) * 60 + Number(m);
    });

    const sorted = [...minutes].sort((a, b) => a - b);
    expect(minutes).toEqual(sorted);

    // The second click reverses it, which is what a reader toggling a column
    // expects and what a one-way sort would not do.
    await page.locator("th.runs-meta-paid button").click();
    await expect(paidHeader).toHaveAttribute("aria-sort", "descending");
    const descending = (await runFacts(page)).map((fact) => {
      const [h, m] = fact.paid.split(":");
      return Number(h) * 60 + Number(m);
    });
    expect(descending).toEqual([...descending].sort((a, b) => b - a));

    // Put the page back on sign-on for the journeys that follow.
    await page.locator("th.runs-meta-sign_on button").click();
  });

  test("the run drawer's paid-time lines sum to the row's Paid cell", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);

    // Run 2001 is the seeded :SPLIT — two pieces, two blocks, and a break
    // between them that is not paid — so its pay table is the interesting one.
    await openRuns(page, versionId, "?run=2001");
    await openDrawer(page, "run-drawer");

    const pay = await page.evaluate(() => {
      const lines = [...document.querySelectorAll("#run-pay-table [data-role='pay-line']")];
      const paidLines = lines.filter(
        (line) => line.getAttribute("data-paid") === "true",
      );
      return {
        totalSecs: Number(
          document.querySelector("#run-pay-table [data-role='pay-total']").getAttribute("data-secs"),
        ),
        totalText: document
          .querySelector("#run-pay-table [data-role='pay-total']")
          .textContent.trim(),
        // An unpaid break carries `data-paid="false"` and shows no value at
        // all, so summing the rendered values would silently drop it. The
        // seconds on each paid line are the source.
        paidLineSecs: paidLines.map((line) => Number(line.getAttribute("data-secs"))),
        allLineSecs: lines.map((line) => ({
          kind: line.getAttribute("data-kind"),
          paid: line.getAttribute("data-paid"),
          secs: Number(line.getAttribute("data-secs")),
        })),
        pieces: document.querySelectorAll("#run-drawer-pieces-table [data-role='run-piece']").length,
        rowPaid: document
          .querySelector("#runs-timeline-body tr[data-run='2001'] [data-role='run-paid']")
          .textContent.trim(),
      };
    });

    // A two-piece run, so a pay table that summed one piece's lines would be
    // short by exactly the other piece.
    expect(pay.pieces).toBe(2);
    expect(pay.paidLineSecs.length).toBeGreaterThan(2);

    // The lines sum to the total.
    const summed = pay.paidLineSecs.reduce((a, b) => a + b, 0);
    expect(summed).toBe(pay.totalSecs);

    // And the total is the row's Paid cell. Both print `h:mm`; the row's cell
    // is the same figure the list and the drawer are each showing.
    const toMinutes = (value) => {
      const [h, m] = value.split(":");
      return Number(h) * 60 + Number(m);
    };
    expect(toMinutes(pay.rowPaid)).toBe(Math.floor(pay.totalSecs / 60));

    await capture(page, testInfo, "runs-run-drawer-1440");
  });

  test("splitting a piece at a relief handover moves the trips and Undo restores them", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId, "?run=2001");
    await openDrawer(page, "run-drawer");

    // Piece 1 is block 101, and its only relief handover is position 1: the
    // change of hands at the Northgate bay between trips 1001 and 1002. The
    // drawer numbers pieces from 1, as the reader counts them.
    await expect(page.locator("#run-split-piece-form-1")).toBeVisible();
    await page.locator(`#run-split-at-1 option[value='${RELIEF_HANDOVER}']`).waitFor({ state: "attached" });
    await page.selectOption("#run-split-at-1", RELIEF_HANDOVER);
    await page.selectOption("#run-split-to-1", "__new");
    await page.locator("#run-split-piece-form-1 button[type='submit']").click();

    // The trips went to the next free number, 2007: 2001-2006 are taken on
    // this day type and Saturday's 2001 and 2009 are scoped to Saturday.
    await expect(toastText(page)).toContainText(`moved to run ${NEXT_RUN_ID}.`);
    await expect(page.locator("#runs-undo")).toBeVisible();

    // The shared shell at 1440x1000: root, text, icon, dismiss target, and the
    // Undo action carrying its event and page contract.
    const toast = page.locator("#runs-toast");
    await expect(toast).toBeVisible();
    await expect(toast).toHaveAttribute("role", "status");
    await expect(toast).toHaveAttribute("aria-live", "polite");
    await expect(toast).toHaveAttribute("data-role", "runs-toast");
    await expect(page.locator("#runs-toast-text")).toBeVisible();
    await expect(page.locator("#runs-toast [data-role='toast-icon']")).toHaveCount(1);
    await expect(page.locator("#runs-toast [data-role='dismiss-toast']")).toBeVisible();

    const undo = page.locator("#runs-undo");
    await expect(undo).toHaveAttribute("data-role", "undo");
    await expect(undo).toHaveAttribute("phx-click", "undo");
    expect(await undo.getAttribute("data-trips")).toBeTruthy();

    await expectToastShellFits(page, DESKTOP.width);
    // These two captures go to ROUTE16_CAPTURE_DIR alongside the Rosters
    // journey's, so the package evidence holds both viewports of both shells.
    await captureShot(page, "runs-split-undo-1440", { fullPage: false });

    // The same shell at 390x844: it stays inside the mobile viewport and both
    // targets keep their 44px.
    await page.setViewportSize(MOBILE);
    await expect(toast).toBeVisible();
    await expectToastShellFits(page, MOBILE.width);
    await captureShot(page, "runs-split-undo-390", { fullPage: false });
    await page.setViewportSize(DESKTOP);

    // The drawer follows the run the trips went to, and the new run is on the
    // chart: the write is visible, not only reported.
    await expect(page.locator("#runs-run-2007")).toBeVisible();
    expect((await runIds(page)).sort()).toEqual(
      [...SEEDED_RUNS, NEXT_RUN_ID].sort(),
    );

    const afterSplit = await page.evaluate(() => ({
      row2001: document.querySelector(
        "#runs-timeline-body tr[data-run='2001'] [data-role='run-paid']",
      ).textContent.trim(),
      row2007: document.querySelector(
        "#runs-timeline-body tr[data-run='2007'] [data-role='run-paid']",
      ).textContent.trim(),
    }));
    expect(afterSplit.row2001).not.toBe(afterSplit.row2007);

    // Undo is the same write reversed, and the day comes back: 2007 is gone
    // and 2001 is whole again.
    await page.locator("#runs-undo").click();
    await expect(toastText(page)).toHaveText("Undone.");
    await expect(page.locator("#runs-undo")).toHaveCount(0);
    await expect(page.locator("#runs-run-2007")).toHaveCount(0);
    expect([...(await runIds(page))].sort()).toEqual([...SEEDED_RUNS].sort());
  });

  test("previewing Uncovered work only then applying drops the uncovered count to 0", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId);

    // Block 105 is assigned to nothing, so the count strip starts at 2.
    const uncoveredTile = page.locator("#runs-count-strip-item-uncovered");
    await expect(uncoveredTile).toContainText(String(UNCOVERED_TRIPS));

    await openSuggest(page);

    // The uncovered scope is the one that would do something, so it is the
    // checked one; it is also the only scope that applies without asking.
    await page.locator("#runs-scope-uncovered").click();
    await expect(page.locator("#runs-scope-uncovered")).toBeChecked();

    await page.locator("#runs-preview").click();
    await expect(page.locator("#runs-suggestion")).toBeVisible();

    // The preview is drawn over the chart rather than replacing it: every saved
    // run is still there, beside the run proposed for block 105's uncovered work.
    expect(await runIds(page)).toEqual(expect.arrayContaining(SEEDED_RUNS));
    expect((await runIds(page)).length).toBeGreaterThan(SEEDED_RUNS.length);
    const changedLabels = page.locator("[data-role='changed-label']");
    expect(await changedLabels.count()).toBeGreaterThan(0);

    const metrics = await page
      .locator("[data-role='suggestion-metric']")
      .evaluateAll((nodes) =>
        nodes.map((node) => ({
          label: node.textContent.trim(),
          before: node.querySelector("[data-role='metric-before']")?.textContent.trim(),
          after: node.querySelector("[data-role='metric-after']")?.textContent.trim(),
        })),
      );
    expect(metrics.length).toBeGreaterThan(0);

    await capture(page, testInfo, "runs-suggest-preview-1440");

    // Uncovered-only applies directly: only a rebuild changes what a reader
    // can already see, so only a rebuild asks first.
    await expect(page.locator("#runs-rebuild-confirm")).toHaveAttribute("data-open", "false");

    await page.locator("#runs-apply").click();
    await expect(toastText(page)).toContainText("Suggestion applied.");

    // The two trips that were in no run are now in one, and the tile says so
    // in words rather than as a zero.
    await expect(uncoveredTile).toContainText("None");
    expect((await runIds(page)).length).toBe(SEEDED_RUNS.length + 1);
  });

  test("previewing a rebuild asks first, and keeping the current runs writes nothing", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    // The uncovered-work journey applied a suggestion, so the day has one run
    // more than the seed.
    await openRuns(page, versionId, "", SEEDED_RUNS.length + 1);

    // The journey before this one applied a suggestion, so the day now carries
    // a run the seed did not have. That is what a rebuild would renumber, and
    // it is the point: the confirmation exists because the numbers can move.
    const before = await runIds(page);
    expect(before.length).toBe(SEEDED_RUNS.length + 1);

    await openSuggest(page);
    await page.locator("#runs-scope-rebuild").click();
    await expect(page.locator("#runs-scope-rebuild")).toBeChecked();

    await page.locator("#runs-preview").click();
    await expect(page.locator("#runs-suggestion")).toBeVisible();

    await page.locator("#runs-apply").click();

    // A rebuild asks, and the dialog says what would change: the blocks are cut
    // again, the pieces paired again, and the runs renumbered, so a run the
    // reader tuned can come back under a different number.
    await expect(page.locator("#runs-rebuild-confirm[data-open='true']")).toBeVisible();
    await expect(page.locator("#runs-rebuild-confirm-summary")).toContainText(
      "renumbered in sign-on order",
    );
    const summary = await page
      .locator("#runs-rebuild-confirm-summary")
      .textContent();

    await capture(page, testInfo, "runs-rebuild-confirm-1440");

    // "Keep current runs" writes nothing: the day is exactly as it was.
    await page.locator("#runs-rebuild-confirm-cancel").click();
    await expect(page.locator("#runs-rebuild-confirm")).toHaveAttribute("data-open", "false");

    // The preview stays up, because the reader has not answered the suggestion
    // yet; the chart is still showing the proposal, not the saved day.
    await expect(page.locator("#runs-suggestion")).toBeVisible();

    // A reload drops the preview, which is not URL state, and shows the saved
    // day: a write that had been committed would be here.
    await page.reload();
    await expect(page.locator("#runs-timeline-body tr")).toHaveCount(before.length);
    expect([...(await runIds(page))].sort()).toEqual([...before].sort());
  });

  test("saving crew rules with 200 minutes of pull-out report shows the range error", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    // The uncovered-work journey applied a suggestion, so the day has one run
    // more than the seed.
    await openRuns(page, versionId, "", SEEDED_RUNS.length + 1);

    const runsBefore = await runIds(page);

    await page.locator("#runs-crew-rules-button").click();
    await openDrawer(page, "runs-crew-rules-drawer");

    // The seeded pull-out report is 15 and its range is 0-30, so 200 is out of
    // range by a long way and cannot be a rounding of a legal value.
    await expect(page.locator("#crew-report_pull_out_minutes")).toHaveValue("15");

    await page.fill("#crew-report_pull_out_minutes", "200");
    // The form is `novalidate` and validates on change, so the error comes
    // from the server's own range rather than from the browser's number input.
    await page.locator("#crew-report_pull_out_minutes").blur();

    await expect(page.locator("#crew-report_pull_out_minutes-error")).toHaveText(
      "Enter a whole number from 0 to 30.",
    );
    await expect(page.locator("#crew-report_pull_out_minutes")).toHaveAttribute(
      "aria-invalid",
      "true",
    );

    // Only the field the reader touched is marked: re-validating all five would
    // put an error under a field they have not reached.
    await expect(page.locator("#crew-report_relief_minutes")).toHaveAttribute(
      "aria-invalid",
      "false",
    );

    // And saving is refused: the value does not reach the database.
    await page.locator("#crew-rules-save").click();
    await expect(page.locator("#crew-report_pull_out_minutes-error")).toBeVisible();

    await capture(page, testInfo, "runs-crew-error-1440");

    // Close without saving and confirm the day is untouched.
    await page.locator("#runs-crew-rules-drawer button", { hasText: "Cancel" }).click();
    await closeDrawer(page, "runs-crew-rules-drawer");
    expect([...(await runIds(page))].sort()).toEqual([...runsBefore].sort());
  });
});
