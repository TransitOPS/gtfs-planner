// Rosters grid roving-row keyboard journey.
//
// A line's seven days are one tab stop each: Tab reaches a line, Left and
// Right move between its days, Home and End jump to Monday and Sunday, and
// Enter opens the focused day. This journey drives real key events through
// Chromium, because the half that moves focus is the half no Elixir test can
// reach — a LiveView test can prove the tabindex is rendered and nothing about
// where the browser puts focus.
//
// Every expectation is a literal from the cases below or from the seeded
// "Browser Rosters Version" in `test/support/browser_seed.exs`, never a value
// read back from the surface under test. The seed's line 1 is the Mon–Fri line
// and line 2 is the short-rest line (Monday run 1002, Sunday run 7001, the rest
// off), so the rows a key has to move through are named rather than discovered.
//
// The tab traversal starts from the first sortable header and asserts the whole
// sequence through the grid. A line's Line link and its Record pick control are
// real buttons in the prototype as well as here, so they are stops too; what
// this file pins is the part this step owns — each row's seven days
// contributing exactly one stop between them, and the next stop being the next
// line's rather than the next day of this one.
//
// "Enter opens #rosters-slot-drawer" is not asserted here. The drawer is step
// 29's, so the journey asserts the half that is true today: the focused slot is
// a real <button> and Enter dispatches the click its `phx-click="open_slot"`
// binds to. The drawer opening is the LiveView tests' proof.
//
// Run it with `bin/test-browser e2e/rosters_keyboard.spec.js`.

import { readFileSync } from "node:fs";

import { expect, test } from "@playwright/test";

const VERSION_NAME = "Browser Rosters Version";

// `assets/e2e/browser_helpers.js` has no log-in helper, and every spec that
// needs a session carries its own `logIn`; this one follows that pattern.
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
  const password = seed.match(
    /email: "diagram-test@gtfs-planner\.test",\s*\n\s*password: "([^"]+)"/
  );

  if (!email || !password) {
    throw new Error(
      "The seeded editor is not in test/support/browser_seed.exs; this spec reads its credential from the seed and will not guess one."
    );
  }

  return { email: email[1], password: password[1] };
}

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

// The seeded lines, by what they exist to show. Line 1 is the Mon–Fri line with
// an operator; line 2 is the short-rest line, whose Monday and Sunday are the
// only days it works.
const FIRST_LINE = 1;
const SECOND_LINE = 2;

const row = (line) => `#rosters-grid-body tr.rosters-line-row:has(#rosters-line-${line}-open)`;
const slot = (line, weekday) => `#slot-${line}-${weekday}`;
// The first header button, the start of the grid's own tab sequence.
const firstHeaderButton = "#rosters-grid thead button[phx-value-key='line']";

/** Every slot's tabindex in one row, Monday to Sunday. */
async function tabStopsIn(page, line) {
  return page.$$eval(`${row(line)} .rosters-slot`, (slots) =>
    slots.map((s) => s.getAttribute("tabindex"))
  );
}

/** The id of whatever currently holds focus inside the grid, or null. */
async function focusedSlot(page) {
  return page.evaluate(() => {
    const el = document.activeElement?.closest?.(".rosters-slot");
    return el ? el.id : null;
  });
}

/** The weekday (1 = Monday) currently focused, or null. */
async function focusedWeekday(page) {
  const id = await focusedSlot(page);
  if (!id) return null;
  return Number(id.split("-").pop());
}

/** The line numbers of every row that currently has a tab stop, in order. */
async function linesWithAStop(page) {
  return page.$$eval("#rosters-grid-body .rosters-slot[tabindex='0']", (slots) =>
    slots.map((s) => s.closest("tr").querySelector(".rosters-line-link").id.split("-")[2])
  );
}

/** The weekday currently holding one line's tab stop, or null. */
async function stopWeekday(page, line) {
  const stops = await tabStopsIn(page, line);
  const index = stops.indexOf("0");
  return index === -1 ? null : index + 1;
}

/**
 * Presses Tab until focus leaves `#rosters-grid`, and returns what it walked
 * through — the grid's real tab sequence, in the browser's own order. An element
 * with no id is named by the column it sorts, because that is what identifies
 * it; every other stop is named by its id.
 */
async function tabOrderWithinGrid(page) {
  await page.locator(firstHeaderButton).focus();

  const walked = [];
  for (let press = 0; press < 40; press += 1) {
    await page.keyboard.press("Tab");
    const id = await page.evaluate(() => {
      const el = document.activeElement;
      if (!el || !el.closest("#rosters-grid")) return null;
      return el.id || el.getAttribute("phx-value-key");
    });
    if (id === null) break;
    walked.push(id);
  }

  return walked;
}

test.describe("Rosters grid roving row", () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(`/gtfs/${versionId}/rosters`);
    await expect(page.locator("#rosters-grid")).toBeVisible();
  });

  // One Tab stop per row, and it is Monday in the server's own HTML.
  test("each row is one Tab stop and its stop is Monday", async ({ page }) => {
    expect(await tabStopsIn(page, FIRST_LINE)).toEqual([
      "0",
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
    ]);
    expect(await tabStopsIn(page, SECOND_LINE)).toEqual([
      "0",
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
    ]);

    // Every row contributes exactly one stop, and no row contributes two. A row
    // with no stop is a row no keyboard can enter, and it looks identical to a
    // row that was never rendered.
    const stops = await linesWithAStop(page);
    expect(stops.length).toBeGreaterThan(1);
    expect(new Set(stops).size).toBe(stops.length);
  });

  // Tab reaches line 1's Monday, and the next Tab leaves the row rather than
  // walking to line 1's Tuesday. The whole sequence is asserted, because the
  // part that matters is what a reader meets between two rows: the row's Line
  // link and its Record pick control are real buttons in this prototype and this
  // page, and the seven days contribute exactly one stop between them.
  test("Tab walks the rows, not the days", async ({ page }) => {
    // The two sortable headers before this one come first, then each row in
    // turn: its Line link, its one slot stop, and its Record pick control.
    const expected = ["paid", "operator"];
    for (const line of [1, 2, 3, 4, 5]) {
      expected.push(
        `rosters-line-${line}-open`,
        `slot-${line}-1`,
        `rosters-record-pick-${line}`
      );
    }

    expect(await tabOrderWithinGrid(page)).toEqual(expected);
  });

  // A row whose reader has walked to Wednesday comes back on Wednesday after a
  // re-stream, and is still one stop.
  test("a re-stream keeps one tab stop per row, where the reader left it", async ({
    page,
  }) => {
    await page.locator(slot(FIRST_LINE, 1)).focus();
    await page.keyboard.press("ArrowRight");
    const before = await tabStopsIn(page, FIRST_LINE);
    expect(before[1]).toBe("0");

    // Sorting re-streams every row, so the row the reader was standing in has
    // been re-rendered. A row that came back with seven stops, or none, would be
    // a row a keyboard could not enter; a row that came back on Monday would
    // silently move the reader back a day.
    await page.locator("#rosters-grid thead button[phx-value-key='paid']").click();
    await expect(page).toHaveURL(/sort=paid/);
    await expect(page.locator(row(FIRST_LINE))).toBeVisible();

    for (const line of [FIRST_LINE, SECOND_LINE]) {
      const stops = await tabStopsIn(page, line);
      expect(stops.filter((t) => t === "0").length).toBe(1);
    }
    expect(await stopWeekday(page, FIRST_LINE)).toBe(2);

    const stops = await linesWithAStop(page);
    expect(stops.length).toBeGreaterThan(1);
    expect(new Set(stops).size).toBe(stops.length);

    // And the row is still one stop after the patch: Tab from its stop reaches
    // the next control, not the next day of this row.
    await page.locator(slot(FIRST_LINE, 2)).focus();
    await page.keyboard.press("Tab");
    expect(await focusedSlot(page)).not.toBe(`slot-${FIRST_LINE}-3`);
  });

  // ArrowRight and ArrowLeft move between a line's own days.
  test("ArrowRight and ArrowLeft move between a line's days", async ({ page }) => {
    await page.locator(slot(FIRST_LINE, 1)).focus();

    await page.keyboard.press("ArrowRight");
    expect(await focusedSlot(page)).toBe(`slot-${FIRST_LINE}-2`);

    // The roving tabindex moved with the focus, so the row is still ONE stop.
    expect(await tabStopsIn(page, FIRST_LINE)).toEqual([
      "-1",
      "0",
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
    ]);

    await page.keyboard.press("ArrowLeft");
    expect(await focusedSlot(page)).toBe(`slot-${FIRST_LINE}-1`);
    expect(await tabStopsIn(page, FIRST_LINE)).toEqual([
      "0",
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
    ]);
  });

  // End is Sunday and Home is Monday, and the arrows are clamped rather than
  // wrapped: a reader who overshot must not believe they had changed row.
  test("End and Home jump to the week's ends and the arrows never wrap", async ({
    page,
  }) => {
    await page.locator(slot(FIRST_LINE, 1)).focus();

    await page.keyboard.press("End");
    expect(await focusedSlot(page)).toBe(`slot-${FIRST_LINE}-7`);
    expect(await tabStopsIn(page, FIRST_LINE)).toEqual([
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
      "-1",
      "0",
    ]);

    await page.keyboard.press("ArrowRight");
    expect(await focusedSlot(page)).toBe(`slot-${FIRST_LINE}-7`);

    await page.keyboard.press("Home");
    expect(await focusedSlot(page)).toBe(`slot-${FIRST_LINE}-1`);

    await page.keyboard.press("ArrowLeft");
    expect(await focusedSlot(page)).toBe(`slot-${FIRST_LINE}-1`);
  });

  // UX obligation: the arrows do not trap focus, and Tab leaves the row.
  test("Tab leaves the row and the arrows do not escape it", async ({ page }) => {
    await page.locator(slot(SECOND_LINE, 1)).focus();

    // ArrowLeft on the row's first day must not escape the row: there is nowhere
    // to go inside this row.
    await page.keyboard.press("ArrowLeft");
    expect(await focusedSlot(page)).toBe(`slot-${SECOND_LINE}-1`);

    // And Tab from a day leaves it, rather than walking on to Tuesday.
    await page.keyboard.press("Tab");
    expect(await focusedSlot(page)).not.toBe(`slot-${SECOND_LINE}-2`);
    expect(
      await page.evaluate(() => {
        const el = document.activeElement;
        return el?.closest?.("#rosters-line-2") ? el.id : null;
      })
    ).toBe("rosters-record-pick-2");
  });

  // Only four keys are the hook's. Everything else is the browser's.
  test("a key the hook does not own is left alone", async ({ page }) => {
    await page.locator(slot(FIRST_LINE, 1)).focus();

    await page.keyboard.press("ArrowUp");
    expect(await focusedSlot(page)).toBe(`slot-${FIRST_LINE}-1`);

    await page.keyboard.press("PageDown");
    expect(await focusedSlot(page)).toBe(`slot-${FIRST_LINE}-1`);

    // The row's tab order is unchanged, because the hook returned early.
    const stops = await tabStopsIn(page, FIRST_LINE);
    expect(stops[0]).toBe("0");
  });

  // A slot is a real button, so Enter is native activation: the click the
  // `open_slot` event binds to is dispatched on the focused day. The drawer
  // itself is step 29's.
  test("Enter activates the focused slot", async ({ page }) => {
    expect(
      await page
        .locator(slot(FIRST_LINE, 1))
        .evaluate((el) => el.tagName)
    ).toBe("BUTTON");
    expect(await page.locator(slot(FIRST_LINE, 1)).getAttribute("phx-click")).toBe(
      "open_slot"
    );

    // The click is observed in the page rather than inferred from a drawer that
    // does not exist yet, and it carries the line and the day it was for.
    await page.evaluate(() => {
      window.__slotClicks = [];
      document
        .querySelector("#rosters-grid")
        .addEventListener("click", (e) => window.__slotClicks.push(e.target.id), true);
    });

    await page.locator(slot(SECOND_LINE, 7)).focus();
    await page.keyboard.press("Enter");

    expect(await page.evaluate(() => window.__slotClicks)).toEqual([
      `slot-${SECOND_LINE}-7`,
    ]);
    // Focus stays on the day that was opened: the drawer is not this step's, and
    // a roving row must not move under the reader when a key is pressed.
    expect(await focusedSlot(page)).toBe(`slot-${SECOND_LINE}-7`);
  });

  // The keyboard hint is visible under the table and names the keys.
  test("the keyboard hint is visible under the table and names the keys", async ({
    page,
  }) => {
    const hint = page.locator("#rosters-grid-hint");
    await expect(hint).toBeVisible();

    const text = await hint.innerText();
    expect(text).toContain("one Tab stop");
    expect(text).toContain("Left and Right");
    expect(text).toContain("Home and End");
    expect(text).toContain("Enter");

    // The table names the hint, so a screen reader is offered the same sentence
    // a sighted reader reads.
    expect(await page.locator("#rosters-grid").getAttribute("aria-describedby")).toBe(
      "rosters-grid-hint"
    );
  });
});
