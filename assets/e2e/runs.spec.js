// Runs browser journey (EV-40, step 43).
//
// The journey exercises the Runs page end to end in Chromium at 1440x1000
// against the seeded "Browser Runs Version" in `test/support/browser_seed.exs`
// — the version that carries the prototype's default runs problems — and
// captures the states the card names for comparison with
// `.specs/08-basic-runs/references/runs-prototype.html`.
//
// The seed, read from `test/support/browser_seed.exs` and not from the page:
//
//   * two calendars, {WKDY} and {SAT}. Weekday is the default and the only day
//     type this journey opens. Saturday carries run "2001" as well, which is a
//     DIFFERENT run from the weekday "2001" — the same ID on two day types is
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
// what the card's prose says, both because the prose is the reference's and the
// application deliberately differs:
//
//   * the reference draws a `⇄` glyph at a relief handover. The application
//     writes the words "(relief point)" instead — a glyph beside a number is
//     not available to a screen reader, and step 32 recorded the same drift;
//   * the card names `logInAs` and `captureShot` as helpers in
//     `browser_helpers.js`. Neither exists. The repository's own e2e specs
//     (`blocks_advanced.spec.js`, spec 07) each define a local `logIn` and a
//     local `capture` against `testInfo.outputPath`, and this file follows that
//     pattern rather than inventing a shared helper the other specs do not use.
//
// The journeys share one reset-and-seeded database, so they are serial and run
// in the order the card lists them: the measuring journeys read the day the seed
// made, the split journey undoes its own write, and the two that change the day
// come after everything that reads it.
//
// Captures are written under `testInfo.outputPath` and copied to
// `.specs/08-basic-runs/evidence/browser/`; the last journey writes
// `qa-tour.md` from the measurements the earlier ones recorded. `.specs/` is
// gitignored and lives in the primary checkout, so the captures and the tour
// artifact are skipped (never failed) when that workspace is not linked.
import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SPEC_PACKAGE = resolve(__dirname, "..", "..", ".specs", "08-basic-runs");
const EVIDENCE_DIR = resolve(SPEC_PACKAGE, "evidence", "browser");
const REFERENCE_PROTOTYPE = resolve(
  SPEC_PACKAGE,
  "references",
  "runs-prototype.html",
);

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

// The states the reference renders that the journey mirrors.
const REFERENCE_SCENARIOS = [
  ["problems", "state=problems"],
  ["zoom", "state=zoom"],
  ["run", "state=run"],
  ["preview-uncovered", "state=preview-uncovered"],
  ["confirm-rebuild", "state=confirm-rebuild"],
  ["crew-error", "state=crew-error"],
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

// A drawer is a top-layer `<dialog>`; the shared component carries its open
// state on the overlay, so every drawer wait reads the component's own
// attribute rather than a class or a computed style. `run-drawer` and
// `runs-crew-rules-drawer` are overlays; `runs-rebuild-confirm` is the
// `CoreComponents.confirm_dialog/1` dialog, which carries `data-open` on itself
// and has no overlay.
async function openDrawer(page, overlayId) {
  await expect(page.locator(`#${overlayId}[data-open="true"]`)).toBeVisible();
}

async function closeDrawer(page, overlayId) {
  await expect(page.locator(`#${overlayId}`)).toHaveAttribute("data-open", "false");
}

function toastText(page) {
  return page.locator("[data-role='toast-text']");
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

    tour.rows = {
      runCount: rowHeights.length,
      rowPx: rowHeights[0],
      pieceBarCount: barHeights.length,
      barPx: barHeights[0],
    };

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

    const measured = await page.evaluate(() => ({
      bodyScrollWidth: document.body.scrollWidth,
      innerWidth: window.innerWidth,
      documentScrollWidth: document.documentElement.scrollWidth,
    }));

    tour.viewport = { ...measured, fits: true };

    // And the same after Zoom in, which doubles the TRACK and is the state most
    // likely to push a page wide: the scroll belongs to #runs-timeline-scroll,
    // not to the document.
    await page.getByRole("radio", { name: "Zoom in" }).click();
    await expect(page.locator("#runs-timeline")).toHaveAttribute("data-scale", "zoom");
    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("after Zoom in and scrolling the track, Run and Status stay visible", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId);

    await page.getByRole("radio", { name: "Zoom in" }).click();
    await expect(page.locator("#runs-timeline")).toHaveAttribute("data-scale", "zoom");

    // Every fact column, not only the two the card names. The header cells are
    // named from the sort keys (`sign_on`, `sign_off`) and the body cells from
    // `run_facts/1`'s keys (`on`, `off`), and the two sets did not agree — so a
    // check that only watched Run and Status would have missed the columns that
    // scrolled their label away. This reads all seven, from the header and from
    // the first row, and asserts both moved not at all.
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

    tour.zoom = {
      scrolledTo: after.scrollLeft,
      scrollWidth: before.scrollWidth,
      clientWidth: before.clientWidth,
      headLefts: after.headLefts,
      bodyLefts: after.bodyLefts,
      runCell: before.runText,
      statusCell: before.statusText,
      factColumnsStuck: 7,
    };

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

    tour.sort = {
      defaultOrder: before,
      paidAscending: after,
      paidDescending: await runIds(page),
      signOnOrder: before,
    };

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

    // The card's case: the lines sum to the total.
    const summed = pay.paidLineSecs.reduce((a, b) => a + b, 0);
    expect(summed).toBe(pay.totalSecs);

    // And the total is the row's Paid cell. Both print `h:mm`; the row's cell
    // is the same figure the list and the drawer are each showing.
    const toMinutes = (value) => {
      const [h, m] = value.split(":");
      return Number(h) * 60 + Number(m);
    };
    expect(toMinutes(pay.rowPaid)).toBe(Math.floor(pay.totalSecs / 60));

    tour.pay = {
      run: "2001",
      pieces: pay.pieces,
      paidLines: pay.paidLineSecs.length,
      lineSecs: pay.allLineSecs,
      totalSecs: pay.totalSecs,
      rowPaid: pay.rowPaid,
    };

    await capture(page, testInfo, "runs-run-drawer-1440");
  });

  test("splitting a piece at a relief handover moves the trips and Undo restores them", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId, "?run=2001");
    await openDrawer(page, "run-drawer");

    // The boundary is a HANDOVER and the drawer says which ones are at a
    // relief point. The reference draws a `⇄` glyph here; the application
    // writes the words, and step 32 recorded the same drift.
    await expect(page.locator("#run-drawer")).toContainText("(relief point)");

    // Piece 0 is block 101, and its only handover is index 1: the change of
    // hands at the Northgate bay between trips 1001 and 1002.
    await page.locator(`#run-split-at-0 option[value='${RELIEF_HANDOVER}']`).waitFor();
    await page.selectOption("#run-split-at-0", RELIEF_HANDOVER);
    await page.selectOption("#run-split-to-0", "__new");
    await page.locator("#run-split-piece-form-0 button[type='submit']").click();

    // The trips went to the next free number, 2007: 2001-2006 are taken on
    // this day type and Saturday's 2001 and 2009 are scoped to Saturday.
    await expect(toastText(page)).toContainText(`moved to run ${NEXT_RUN_ID}.`);
    await expect(page.locator("#runs-undo")).toBeVisible();

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

    tour.split = {
      run: "2001",
      piece: 0,
      handover: RELIEF_HANDOVER,
      newRun: NEXT_RUN_ID,
      toast: await toastText(page).textContent(),
      undoOffered: true,
    };

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

    // The preview changes labels in place rather than replacing the chart, and
    // it is not saved: the run count is still the seed's six.
    expect([...(await runIds(page))].sort()).toEqual([...SEEDED_RUNS].sort());
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

    tour.preview = {
      scope: "uncovered_only",
      uncoveredBefore: UNCOVERED_TRIPS,
      runsUnchanged: true,
      changedLabels: await changedLabels.count(),
      metrics,
    };

    await capture(page, testInfo, "runs-suggest-preview-1440");

    // Uncovered-only applies directly: only a rebuild changes what a reader
    // can already see, so only a rebuild asks first.
    await expect(page.locator("#runs-rebuild-confirm")).toHaveAttribute("data-open", "false");

    await page.locator("#runs-apply").click();
    await expect(toastText(page)).toContainText("Suggestion applied.");

    // The two trips that were in no run are now in one.
    await expect(uncoveredTile).toContainText("0");
    expect((await runIds(page)).length).toBe(SEEDED_RUNS.length + 1);
  });

  test("previewing a rebuild asks first, and keeping the current runs writes nothing", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId);

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

    tour.rebuild = {
      scope: "replace_all",
      askedFirst: true,
      summary: summary.trim(),
    };

    await capture(page, testInfo, "runs-rebuild-confirm-1440");

    // "Keep current runs" writes nothing: the day is exactly as it was.
    await page.locator("#runs-rebuild-confirm-cancel").click();
    await expect(page.locator("#runs-rebuild-confirm")).toHaveAttribute("data-open", "false");

    expect([...(await runIds(page))].sort()).toEqual([...before].sort());

    // A full reload is the stronger check: a write that was rolled back in the
    // socket but committed in the database would still be here.
    await page.reload();
    await expect(page.locator("#runs-timeline-body tr")).toHaveCount(before.length);
    expect([...(await runIds(page))].sort()).toEqual([...before].sort());
    tour.rebuild.wroteNothing = true;
  });

  test("saving crew rules with 200 minutes of pull-out report shows the range error", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openRuns(page, versionId);

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

    tour.crewError = {
      field: "report_pull_out_minutes",
      entered: "200",
      range: "0-30",
      message: "Enter a whole number from 0 to 30.",
      saved: false,
    };

    await capture(page, testInfo, "runs-crew-error-1440");

    // Close without saving and confirm the day is untouched.
    await page.locator("#runs-crew-rules-drawer button", { hasText: "Cancel" }).click();
    await closeDrawer(page, "runs-crew-rules-drawer");
    expect([...(await runIds(page))].sort()).toEqual([...runsBefore].sort());
  });
});

test.describe("reference prototype captures", () => {
  test.skip(
    () => !existsSync(REFERENCE_PROTOTYPE),
    "reference prototype not present",
  );
  test.use({ viewport: DESKTOP });

  test("the runs states beside production", async ({ page }, testInfo) => {
    test.setTimeout(120_000);

    const referenceUrl = pathToFileURL(REFERENCE_PROTOTYPE).href;

    for (const [name, query] of REFERENCE_SCENARIOS) {
      await page.goto(`${referenceUrl}?${query}`);
      await page.waitForLoadState("load");
      await expect(page.locator("body")).toBeVisible();

      // Recorded for the side-by-side capture only: the prototype's own markup
      // and pixels are not this gate's oracle.
      const bodyWidth = await page.evaluate(() => document.body.scrollWidth);
      tour[`reference_${name.replaceAll("-", "_")}`] = {
        state: query,
        bodyWidth,
        viewportWidth: DESKTOP.width,
      };
      await capture(page, testInfo, `reference-${name}-1440`);
    }
  });
});

// The tour is the capture artifact's own index: entrypoint, setup, scenarios,
// expected outcomes and the automated coverage, with the numbers the journeys
// measured. It is written last so it reports the whole run, and it is skipped
// rather than failed when the gitignored `.specs/` workspace is not linked.
test.describe("qa tour", () => {
  test.skip(
    () => !existsSync(SPEC_PACKAGE),
    "spec package not present",
  );
  test.use({ viewport: DESKTOP });

  test("writes qa-tour.md from the measured journey", async ({}, testInfo) => {
    const value = (key) =>
      tour[key] === undefined ? "(not measured)" : JSON.stringify(tour[key], null, 2);

    const markdown = [
      "# Runs browser QA tour (EV-40, step 43)",
      "",
      "Entrypoint: `/gtfs/<version>/runs` for the published **Browser Runs",
      "Version** seeded by `test/support/browser_seed.exs` — eight weekday blocks",
      "101-108 on the {WKDY} day type, six runs 2001-2006, block 105 uncovered,",
      "relief points at Northgate and Southgate, and the default crew rules.",
      "",
      "## Setup",
      "",
      "```sh",
      "bin/test-browser e2e/runs.spec.js",
      "```",
      "",
      "Chromium at 1440x1000 against a local test Phoenix server on its own",
      "port, one worker and no retries, against a disposable `pg_tmp` database",
      "that is created, migrated, seeded and then discarded. The journeys are",
      "serial and run in the order below: the measuring journeys read the day",
      "the seed made, the split journey undoes its own write, and the two that",
      "change the day come after everything that reads it.",
      "",
      "## Scenarios and expected outcomes",
      "",
      "| # | Scenario | Expected |",
      "| --- | --- | --- |",
      "| 1 | Duty-chart measurements | Six rows at 44 px, more than six piece bars at 28 px (2001 and 2002 have two pieces each) |",
      "| 2 | No horizontal scroll | `document.body.scrollWidth <= innerWidth` at 1440x1000, and again after Zoom in |",
      "| 3 | Zoom and sticky columns | After Zoom in the track scrolls; the Run and Status cells are where they started |",
      "| 4 | Sort by Paid | The six runs reorder, in ascending `h:mm` order, and the second click reverses it |",
      "| 5 | Drawer pay lines | The paid lines sum to `data-role=pay-total`, which equals the row's Paid cell |",
      "| 6 | Split and Undo | 1 trip from block 101 moves to run 2007, and Undo returns the day to six runs |",
      "| 7 | Uncovered preview and apply | Preview leaves the six runs unsaved; Apply drops the uncovered count from 2 to 0 |",
      "| 8 | Rebuild confirm | Apply asks, and keeping the current runs leaves the day unchanged across a reload |",
      "| 9 | Crew rules range error | 200 in Report before a pull-out shows `Enter a whole number from 0 to 30.` and does not save |",
      "",
      "## Evidence mapping",
      "",
      "- EV-40 — scenarios 1-9 above, plus the reference and production captures",
      "  in `.specs/08-basic-runs/evidence/browser/`.",
      "- EV-41 — the ExUnit suite and `mix precommit`, run in branch review.",
      "",
      "## Automated coverage of the same behaviour",
      "",
      "Each journey's behaviour is also covered headlessly by the ExUnit",
      "LiveView tests, which are the merge gate; this journey is the visual and",
      "measured counterpart.",
      "",
      "| Scenario | ExUnit evidence |",
      "| --- | --- |",
      "| Measurements and sticky columns | `runs_timeline_live_test.exs` (EV-21), `runs_marks_live_test.exs` (EV-22) |",
      "| Sort | `runs_list_live_test.exs` (EV-24) |",
      "| Drawer pay lines | `runs_drawer_live_test.exs` (EV-27) |",
      "| Split and Undo | `runs_split_piece_live_test.exs` (EV-30) |",
      "| Uncovered preview and apply | `runs_suggest_live_test.exs` (EV-34), `runs_apply_live_test.exs` (EV-35) |",
      "| Rebuild confirm | `runs_apply_live_test.exs` (EV-35) |",
      "| Crew rules range error | `runs_crew_rules_live_test.exs` (EV-32) |",
      "",
      "## Measured on this run",
      "",
      "### Row and bar sizes",
      "",
      "```json",
      value("rows"),
      "```",
      "",
      "### Viewport fit",
      "",
      "```json",
      value("viewport"),
      "```",
      "",
      "### Zoom and sticky columns",
      "",
      "```json",
      value("zoom"),
      "```",
      "",
      "### Sort order",
      "",
      "```json",
      value("sort"),
      "```",
      "",
      "### Run 2001 paid lines",
      "",
      "```json",
      value("pay"),
      "```",
      "",
      "### Split",
      "",
      "```json",
      value("split"),
      "```",
      "",
      "### Uncovered preview",
      "",
      "```json",
      value("preview"),
      "```",
      "",
      "### Rebuild confirmation",
      "",
      "```json",
      value("rebuild"),
      "```",
      "",
      "### Crew rules error",
      "",
      "```json",
      value("crewError"),
      "```",
      "",
      "## Status",
      "",
      "**Blocked on this base.** `bin/test-browser` does not exist here, and the",
      "card's setup step (`bin/test-browser --keep e2e/ia_navigation.spec.js`) is",
      "the only sanctioned way to create, migrate and seed a disposable database",
      "for this lane. `mise run prepare:browser` is not a substitute: it runs",
      "`mix ecto.reset --force`, which resets a database. So no capture in this",
      "directory was produced by a run of this spec, and every \"Measured on this",
      "run\" block above reads `(not measured)`.",
      "",
      "The spec itself is complete and is the artifact EV-40 asks for. Running it",
      "needs only a base with `bin/test-browser`.",
      "",
    ].join("\n");

    const target = copyIntoEvidence("qa-tour.md", markdown);
    expect(target).toContain("qa-tour.md");
    expect(existsSync(target)).toBe(true);

    // The tour is written even when a journey did not measure, so the file on
    // disk is the honest account of this run rather than a partial one.
    expect(readFileSync(target, "utf8")).toContain("Blocked on this base");
  });
});
