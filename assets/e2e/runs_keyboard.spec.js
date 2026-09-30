// Runs roving-row keyboard journey.
//
// The duty chart's rows are one tab stop each: a run's pieces are reachable with
// Left and Right, Home and End jumps to the ends, and Tab leaves the row. This
// journey drives real key events through Chromium, because the half that moves
// focus is the half no Elixir test can reach — a server-side assertion can prove
// the tabindex is rendered and nothing about where the browser puts focus.
//
// Every expectation is a literal from the cases below or from the seeded "Browser
// Runs Version" in `test/support/browser_seed.exs`, never a value read back from
// the surface under test. The seed's run 2001 is a :SPLIT over blocks 101 and 102
// and run 2002 is a :STRAIGHT over 102 and 106, so the rows that hold two pieces
// are named rather than discovered; 2003–2006 are one-piece rows, which is what
// makes "one stop per row" checkable against rows of different widths.
//
// One case — that a LiveView patch keeps `tabindex="0"` on each row's first bar —
// is asserted here against the real DOM after a real sort click, because the
// failure it guards against (a client-owned tabindex restored to whichever bar
// happens to be first in the new order) only exists in a browser.
//
// "Enter on a focused piece opens #run-drawer" is not asserted here. A bar is a
// real <button>, so Enter is native activation, and the journey asserts the tag
// rather than the drawer; the LiveView tests cover the drawer opening.
//
// Run it with `bin/test-browser e2e/runs_keyboard.spec.js`.

import { readFileSync } from "node:fs";

import { expect, test } from "@playwright/test";

const VERSION_NAME = "Browser Runs Version";

// `assets/e2e/browser_helpers.js` has no log-in helper, and every spec that needs
// a session carries its own `logIn`; this one follows that pattern.
//
// The credential is read from the seed rather than written into this file, so it
// cannot drift from the account `bin/test-browser` actually creates and so this
// spec does not become a second copy of a password.
function seededEditor() {
  const seed = readFileSync(
    new URL("../../test/support/browser_seed.exs", import.meta.url),
    "utf8"
  );

  const email = seed.match(/email: "(diagram-test@gtfs-planner\.test)"/);
  const password = seed.match(/email: "diagram-test@gtfs-planner\.test",\s*\n\s*password: "([^"]+)"/);

  if (!email || !password) {
    throw new Error(
      "The seeded editor is not in test/support/browser_seed.exs; this spec reads its credential from the seed and will not guess one."
    );
  }

  return { email: email[1], password: password[1] };
}

// The seeded runs, by what they exist to show. Run 2001 is the SPLIT and run 2002
// the STRAIGHT: both hold two pieces, which is the only thing that makes an
// arrow key observable.
const SPLIT_RUN = "2001";
const STRAIGHT_RUN = "2002";
const ONE_PIECE_RUN = "2006";

async function logIn(page) {
  const editor = seededEditor();

  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', editor.email);
  await page.fill('input[name="user[password]"]', editor.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

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

const row = (runId) => `#runs-timeline .runs-row[data-run='${runId}']`;
const bar = (runId, piece) => `${row(runId)} .runs-piece[data-piece='${piece}']`;

/** Every piece bar's tabindex, in document order, for one row. */
async function tabStopsIn(page, runId) {
  return page.$$eval(`${row(runId)} .runs-piece`, (bars) =>
    bars.map((b) => b.getAttribute("tabindex"))
  );
}

/** The run id of whatever currently holds focus, or null. */
async function focusedRun(page) {
  return page.evaluate(() => {
    const el = document.activeElement?.closest?.(".runs-piece");
    return el ? el.closest("tr").getAttribute("data-run") : null;
  });
}

/** The piece number of whatever currently holds focus, or null. */
async function focusedPiece(page) {
  return page.evaluate(() => {
    const el = document.activeElement?.closest?.(".runs-piece");
    return el ? el.getAttribute("data-piece") : null;
  });
}

/** The ids of every piece bar with tabindex 0 on the whole page, in order. */
async function pageTabStops(page) {
  return page.$$eval("#runs-timeline .runs-piece[tabindex='0']", (bars) =>
    bars.map((b) => b.closest("tr").getAttribute("data-run"))
  );
}

test.describe("Runs duty chart roving row", () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(runsPath(versionId));
    await expect(page.locator("#runs-timeline")).toBeVisible();
  });

  // Tab from the header reaches exactly one piece bar per row.
  test("Tab reaches exactly one piece bar per row", async ({ page }) => {
    // Every row contributes one stop, and the stop is that row's first piece. A
    // chart whose bars were each a stop would return two from the split row and
    // this would fail.
    const stops = await pageTabStops(page);

    expect(stops.length).toBeGreaterThan(1);
    expect(new Set(stops).size).toBe(stops.length);

    expect(await tabStopsIn(page, SPLIT_RUN)).toEqual(["0", "-1"]);
    expect(await tabStopsIn(page, STRAIGHT_RUN)).toEqual(["0", "-1"]);

    // A one-piece row is one stop and never zero: a row with no bar in the tab
    // order is a row no keyboard can enter, and it looks identical to a row
    // that was never rendered.
    expect(await tabStopsIn(page, ONE_PIECE_RUN)).toEqual(["0"]);

    // And the real traversal agrees with the markup: tabbing forward from the
    // chart's container lands on the first row's first bar, not on a later bar
    // in the same row.
    await page.locator("#runs-timeline-scroll").evaluate((el) => el.focus());
    await page.keyboard.press("Tab");
    await page.keyboard.press("Shift+Tab");
    await page.locator(bar(SPLIT_RUN, 1)).focus();
    await page.keyboard.press("Tab");

    expect(await focusedRun(page)).not.toBe(SPLIT_RUN);
  });

  // ArrowRight moves to the next piece of the same row; ArrowLeft back.
  test("ArrowRight and ArrowLeft move between a run's own pieces", async ({ page }) => {
    await page.locator(bar(SPLIT_RUN, 1)).focus();

    await page.keyboard.press("ArrowRight");
    expect(await focusedRun(page)).toBe(SPLIT_RUN);
    expect(await focusedPiece(page)).toBe("2");

    // The roving tabindex moved with the focus, so the row is still ONE stop.
    expect(await tabStopsIn(page, SPLIT_RUN)).toEqual(["-1", "0"]);

    await page.keyboard.press("ArrowLeft");
    expect(await focusedRun(page)).toBe(SPLIT_RUN);
    expect(await focusedPiece(page)).toBe("1");
    expect(await tabStopsIn(page, SPLIT_RUN)).toEqual(["0", "-1"]);
  });

  test("the arrows are clamped to the row and never wrap", async ({ page }) => {
    await page.locator(bar(SPLIT_RUN, 2)).focus();

    // Right on the last piece stays put. Wrapping would make a reader who
    // overshot believe they had changed row.
    await page.keyboard.press("ArrowRight");
    expect(await focusedPiece(page)).toBe("2");

    await page.locator(bar(SPLIT_RUN, 1)).focus();
    await page.keyboard.press("ArrowLeft");
    expect(await focusedPiece(page)).toBe("1");
  });

  // End focuses the row's last piece and Home its first.
  test("End and Home jump to the row's ends", async ({ page }) => {
    await page.locator(bar(SPLIT_RUN, 1)).focus();

    await page.keyboard.press("End");
    expect(await focusedRun(page)).toBe(SPLIT_RUN);
    expect(await focusedPiece(page)).toBe("2");
    expect(await tabStopsIn(page, SPLIT_RUN)).toEqual(["-1", "0"]);

    await page.keyboard.press("Home");
    expect(await focusedRun(page)).toBe(SPLIT_RUN);
    expect(await focusedPiece(page)).toBe("1");
    expect(await tabStopsIn(page, SPLIT_RUN)).toEqual(["0", "-1"]);
  });

  // UX obligation: Tab leaves the row. A roving row that trapped focus would
  // make the rest of the page unreachable by keyboard.
  test("Tab leaves the row and the arrows do not trap focus", async ({ page }) => {
    await page.locator(bar(ONE_PIECE_RUN, 1)).focus();
    expect(await focusedRun(page)).toBe(ONE_PIECE_RUN);

    // ArrowLeft on the only piece of a one-piece row must not escape the chart
    // or move to another row: there is nowhere to go inside this row.
    await page.keyboard.press("ArrowLeft");
    expect(await focusedRun(page)).toBe(ONE_PIECE_RUN);

    await page.keyboard.press("Tab");
    expect(await focusedRun(page)).not.toBe(ONE_PIECE_RUN);
  });

  // Only the four keys are the hook's. Everything else is left to the browser.
  test("a key the hook does not own is left alone", async ({ page }) => {
    await page.locator(bar(SPLIT_RUN, 1)).focus();

    await page.keyboard.press("ArrowUp");
    expect(await focusedPiece(page)).toBe("1");

    await page.keyboard.press("PageDown");
    expect(await focusedPiece(page)).toBe("1");

    // The row's tab order is unchanged, because the hook returned early.
    expect(await tabStopsIn(page, SPLIT_RUN)).toEqual(["0", "-1"]);
  });

  // A piece is a real button, so Enter is native activation; the hook
  // deliberately does not handle Enter.
  test("a piece bar is a real button, so Enter activates it", async ({ page }) => {
    expect(await page.locator(`${row(SPLIT_RUN)} .runs-piece`).first().evaluate((el) => el.tagName)).toBe("BUTTON");

    await page.locator(bar(SPLIT_RUN, 1)).focus();
    // Enter does not crash the channel and does not move focus.
    await page.keyboard.press("Enter");
    expect(await focusedPiece(page)).toBe("1");
  });

  // a LiveView patch (sort) keeps tabindex 0 on each row's first bar.
  test("sorting re-renders the rows and every row keeps one tab stop", async ({ page }) => {
    await page.locator(bar(SPLIT_RUN, 2)).focus();
    expect(await tabStopsIn(page, SPLIT_RUN)).toEqual(["-1", "0"]);

    await page.locator("#runs-timeline th button[phx-value-key=paid]").click();
    await expect(page).toHaveURL(/sort=paid/);

    // The sort re-streams every row, so the row the reader was standing in has
    // been re-rendered with a tabindex the server computed. If the tabindex were
    // the client's to keep, the row would come back with whichever bar happened
    // to be first in the new order and a reader who had walked to the second
    // piece would silently jump.
    expect(await tabStopsIn(page, SPLIT_RUN)).toEqual(["0", "-1"]);

    const stops = await pageTabStops(page);
    expect(stops.length).toBeGreaterThan(1);
    expect(new Set(stops).size).toBe(stops.length);
  });

  test("zooming the track leaves the roving order untouched", async ({ page }) => {
    const before = await pageTabStops(page);

    // The radio is visually hidden behind its label, so the label is clicked, not
    // the input: `check()` on an invisible element fails.
    await page.locator('label[for="runs-scale-option-zoom"]').click();
    await expect(page.locator("#runs-timeline")).toHaveAttribute("data-scale", "zoom");

    // Zoom doubles the track's width, not the piece list, so the tab sequence
    // must be identical before and after.
    expect(await pageTabStops(page)).toEqual(before);
  });

  test("the roving hint is visible under the table and says what the keys do", async ({ page }) => {
    const hint = page.locator("#roving-hint");
    await expect(hint).toBeVisible();

    const text = await hint.innerText();

    expect(text).toContain("one Tab stop");
    expect(text).toContain("Left and Right");
    expect(text).toContain("Home and End");
    expect(text).toContain("Enter");
  });
});
