import { test, expect } from "@playwright/test";
import { bodyFitsViewport, readZipTextMember } from "./browser_helpers";
import { mkdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Read-view journeys for the route Schedules tab.
 *
 * These journeys cover the navigation, the URL state and the wide All-stops
 * table of the read view only; they never mutate a trip. Step 7 extends this
 * file with the Add trips, Edit, Duplicate and bulk-delete journeys and their
 * own scenario routes. The fixture routes come from `test/support/browser_seed.exs`:
 *
 *   BROWSER_SCHEDULES_READY — both directions, a linked series, a frequency
 *     window, a custom trip whose stops differ, an incomplete trip and two
 *     unlinked trips on CAL_DAILY
 *   BROWSER_SCHEDULES_WIDE — a 72-occurrence pattern with six trips
 *   BROWSER_SCHEDULES_EMPTY — a route with no patterns
 *   BROWSER_SCHEDULES_NOCAL — a route in a published version with no calendars
 *   BROWSER_SCHEDULES_MUTATE — the mutation route: a 62-occurrence pattern, a
 *     linked series with an adjacent pair, a frequency window, a custom trip
 *     whose stops differ, a compatible custom trip and a 25:10 departure
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "EDITOR_PASSWORD_PLACEHOLDER",
};

const READY_ROUTE = "BROWSER_SCHEDULES_READY";
const WIDE_ROUTE = "BROWSER_SCHEDULES_WIDE";
const EMPTY_ROUTE = "BROWSER_SCHEDULES_EMPTY";
const NOCAL_ROUTE = "BROWSER_SCHEDULES_NOCAL";
const MUTATE_ROUTE = "BROWSER_SCHEDULES_MUTATE";

// The mutation route's second pattern: six occurrences with the timing offsets
// the export journey asserts literally.
const SECONDARY_PATTERN = "BROWSER-SCHED-PM2";
const CALENDAR_ROUTE = "Every day service";

const EXPORT_STOP_TIME_ROWS = [
  ["BSS_1", "05:00:00", "05:00:00"],
  ["BSS_2", "05:05:00", "05:06:00"],
  ["BSS_3", "05:11:00", "05:12:00"],
  ["BSS_4", "05:17:00", "05:18:00"],
  ["BSS_5", "05:25:00", "05:26:00"],
  ["BSS_6", "05:30:00", "05:31:00"],
];

const VIEWPORTS = [
  { label: "1440x1000", width: 1440, height: 1000 },
  { label: "1280x900", width: 1280, height: 900 },
];

const CAPTURE_DIR = process.env.SCHEDULE_CAPTURE_DIR;

async function capture(page, name) {
  if (!CAPTURE_DIR) return;

  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: false,
    animations: "disabled",
  });
}

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function versionIdFor(page, versionName) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function schedulesPath(versionId, routeId) {
  return `/gtfs/${versionId}/routes/${routeId}/schedules`;
}

for (const viewport of VIEWPORTS) {
  test.describe(`Schedules read view ${viewport.label}`, () => {
    test.use({ viewport: { width: viewport.width, height: viewport.height } });

    test("the tab bar and the read view render for the route", async ({ page }) => {
      await logIn(page);
      const versionId = await versionIdFor(page, "Browser E2E Version");
      const base = `/gtfs/${versionId}/routes/${READY_ROUTE}`;

      await page.goto(schedulesPath(versionId, READY_ROUTE));
      await expect(page.locator("#planning-summary")).toBeVisible();

      const nav = page.locator("nav[aria-label='Route navigation']");
      await expect(nav.locator(`a[href='${base}']`)).toHaveText("Details");
      await expect(nav.locator(`a[href='${base}/patterns']`)).toHaveText("Patterns");
      await expect(nav.locator(`a[href='${base}/schedules']`)).toHaveAttribute(
        "aria-current",
        "page",
      );

      await expect(page.locator("#schedules-view-counts")).toContainText(CALENDAR_ROUTE);
      await expect(page.locator("#vehicles-needed-line")).toContainText(
        `At least 3 vehicles for route SR alone`,
      );
      await expect(page.locator("#vehicles-needed-context")).toContainText("most at 09:20");
      await expect(page.locator("#trips-per-hour")).toBeVisible();
      await expect(page.locator("#schedules-stops-legend")).toContainText("Timepoints");
      await expect(page.locator("#schedules-unlinked")).toContainText(
        "2 trips aren't linked to a pattern",
      );

      const section = page.locator("#section-BROWSER-SCHED-P1-heading");
      await expect(section).toContainText("Downtown – Valley College");
      await expect(page.locator("#trip-BROWSER_SCHED_T1-start")).toHaveText("06:00");
      await expect(page.locator("#trip-BROWSER_SCHED_TFREQ-frequency")).toContainText(
        "Every 20 min, 09:00–12:00",
      );
      await expect(page.locator("#section-BROWSER-SCHED-P1-omitted")).toContainText(
        "2 stops not shown",
      );

      // The write path is wired, so the mutation controls are present and the
      // page is no longer read-only for an editor.
      await expect(page.locator("#schedules-add-trips")).toBeVisible();
      await expect(page.locator("#schedules-bulk-toolbar")).toHaveCount(0);
      await expect(page.getByRole("button", { name: "Add trips" })).toHaveCount(1);

      await capture(page, `step-006-${viewport.label}-default`);
    });

    test("the URL params canonicalize, restore on reload and drive the stops view", async ({
      page,
    }) => {
      await logIn(page);
      const versionId = await versionIdFor(page, "Browser E2E Version");

      await page.goto(schedulesPath(versionId, READY_ROUTE));

      await expect(page).toHaveURL(
        new RegExp(`${schedulesPath(versionId, READY_ROUTE)}\\?service_id=CAL_DAILY$`),
      );

      await page.reload();
      await expect(page.locator("#trip-BROWSER_SCHED_T1-start")).toHaveText("06:00");

      await page.locator('label[for="stops-filter-option-all"]').click();

      await expect(page).toHaveURL(
        new RegExp(
          `${schedulesPath(versionId, READY_ROUTE)}\\?service_id=CAL_DAILY&stops=all$`,
        ),
      );

      await expect(page.locator("#schedules-stops-legend")).toContainText("All stops shown");
      await expect(page.locator("#section-BROWSER-SCHED-P1-omitted")).toHaveCount(0);
      await expect(page.locator("#section-BROWSER-SCHED-P1-table thead th")).toHaveCount(8);

      await page.goBack();
      await expect(page.locator("#section-BROWSER-SCHED-P1-omitted")).toContainText(
        "2 stops not shown",
      );
    });

    test("the wide All stops table scrolls inside its container and pins its first columns", async ({
      page,
    }) => {
      await logIn(page);
      const versionId = await versionIdFor(page, "Browser E2E Version");

      await page.goto(`${schedulesPath(versionId, WIDE_ROUTE)}?stops=all`);
      await expect(
        page.locator("#section-BROWSER-SCHED-PW-table tbody tr"),
      ).toHaveCount(6);

      // 72 stop columns + selection, Start, Timing, Trip no., Block and Actions.
      await expect(page.locator("#section-BROWSER-SCHED-PW-table thead th")).toHaveCount(78);
      expect(await bodyFitsViewport(page)).toBe(true);

      const container = page.locator("#section-BROWSER-SCHED-PW-table-container");
      const startCell = page.locator("#trip-BROWSER_SCHED_WIDE_1-start");
      const selectionCell = page.locator("#trip-select-BROWSER_SCHED_WIDE_1");

      const beforeScroll = await container.boundingBox();
      await container.evaluate((node) => {
        node.scrollLeft = 2400;
      });
      await expect(startCell).toBeVisible();

      const afterScroll = await container.boundingBox();
      const startBox = await startCell.boundingBox();
      const selectionBox = await selectionCell.boundingBox();

      expect(afterScroll.x).toBe(beforeScroll.x);
      expect(startBox.x).toBeGreaterThanOrEqual(afterScroll.x);
      expect(selectionBox.x).toBeGreaterThanOrEqual(afterScroll.x);
      expect(startBox.x).toBeLessThan(afterScroll.x + afterScroll.width);
      expect(await bodyFitsViewport(page)).toBe(true);

      await capture(page, `step-006-${viewport.label}-all-stops-scrolled`);
    });

    test("the no-patterns, no-calendars, no-trips and loading states render", async ({
      page,
    }) => {
      await logIn(page);
      const versionId = await versionIdFor(page, "Browser E2E Version");

      await page.goto(schedulesPath(versionId, EMPTY_ROUTE));
      await expect(page.locator("#schedules-no-patterns")).toContainText(
        "This route has no patterns yet",
      );
      await expect(page.locator("#planning-summary")).toHaveCount(0);
      await capture(page, `step-006-${viewport.label}-no-patterns`);

      await page.goto(`${schedulesPath(versionId, READY_ROUTE)}?direction=1`);
      await expect(page.locator("#schedules-no-trips")).toContainText(
        "No trips on Every day service going Direction 1",
      );
      await capture(page, `step-006-${viewport.label}-no-trips`);

      const noCalendarsVersion = await versionIdFor(page, "Browser Schedules No Calendars");
      await page.goto(schedulesPath(noCalendarsVersion, NOCAL_ROUTE));
      await expect(page.locator("#schedules-no-calendars")).toContainText(
        "This version has no calendars",
      );
      await capture(page, `step-006-${viewport.label}-no-calendars`);

      // The first paint before the socket connects is the table skeleton.
      await page.route("**/live/websocket**", (route) => route.abort());
      await page.goto(schedulesPath(versionId, READY_ROUTE));
      await expect(page.locator("#schedules-loading")).toBeVisible();
      await expect(page.locator("#planning-summary")).toHaveCount(0);
      await capture(page, `step-006-${viewport.label}-loading`);
      await page.unroute("**/live/websocket**");
    });

    test("the 62-occurrence mutation table keeps its pinned columns", async ({ page }) => {
      await logIn(page);
      const versionId = await versionIdFor(page, "Browser E2E Version");

      await page.goto(`${schedulesPath(versionId, MUTATE_ROUTE)}?stops=all`);

      // 62 stop columns + selection, Start, Timing, Trip no., Block and Actions.
      await expect(page.locator("#section-BROWSER-SCHED-PM1-table thead th")).toHaveCount(68);
      await expect(page.locator("#section-BROWSER-SCHED-PM1-table tbody tr")).toHaveCount(5);
      expect(await bodyFitsViewport(page)).toBe(true);

      const container = page.locator("#section-BROWSER-SCHED-PM1-table-container");
      const startCell = page.locator("#trip-SM_T1-start");
      const selectionCell = page.locator("#trip-select-SM_T1");
      const actionsCell = page.locator("#trip-SM_T1-edit");

      const before = await container.boundingBox();
      await container.evaluate((node) => {
        node.scrollLeft = 2400;
      });

      const after = await container.boundingBox();
      expect(after.x).toBe(before.x);
      expect((await selectionCell.boundingBox()).x).toBeGreaterThanOrEqual(after.x);
      expect((await startCell.boundingBox()).x).toBeGreaterThanOrEqual(after.x);
      expect((await actionsCell.boundingBox()).x).toBeLessThan(after.x + after.width);
      expect(await bodyFitsViewport(page)).toBe(true);

      await capture(page, `step-007-${viewport.label}-mutation-wide`);
    });
  });
}

/**
 * The editing journeys for the Schedules tab.
 *
 * They run once, in declaration order, against a freshly seeded database: each
 * journey works on its own trips of BROWSER_SCHEDULES_MUTATE, so a mutation made
 * by an earlier journey cannot change what a later one asserts. Workers stay at
 * one, as the config requires.
 */
test.describe("Schedules editing journeys", () => {
  test.use({ viewport: { width: 1440, height: 1000 } });

  test("keyboard add series, edit, duplicate and focus return", async ({ page }) => {
    test.setTimeout(90_000);

    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await page.goto(schedulesPath(versionId, MUTATE_ROUTE));
    await expect(page.locator("#trip-SM_T1-start")).toHaveText("06:00");

    // The after-midnight departure keeps its visible day marker.
    await expect(page.locator("#trip-SM_LATE-start")).toHaveText("25:10");
    await expect(page.locator("#trip-SM_LATE-marker")).toHaveText("+1");

    // Add a series with the keyboard only.
    await page.locator("#schedules-add-trips").focus();
    await page.keyboard.press("Enter");
    await page.locator("#trip-drawer").waitFor({ state: "visible" });

    await page.selectOption("#trip-pattern", { label: "Mutate secondary" });
    await page.fill("#trip-start", "06:00");
    await page.locator("#trip-repeat").check();
    await page.fill("#trip-every", "30");
    await page.fill("#trip-until", "06:30");

    await expect(page.locator("#trip-drawer-save")).toHaveText("Add 2 trips");
    await expect(page.locator("#trip-preview")).toContainText("Adds 2 trips, 06:00 → 06:30 every 30 min.");

    await page.locator("#trip-drawer-save").focus();
    await page.keyboard.press("Enter");
    await page.locator("#trip-drawer").waitFor({ state: "hidden" });

    await expect(page).toHaveURL(/pattern=/);

    // Focus returns to the control that opened the drawer.
    await expect(page.locator("#schedules-add-trips")).toBeFocused();

    // The two created trips are on the second pattern at the previewed starts.
    await expect(page.locator("#section-BROWSER-SCHED-PM2-table tbody tr")).toHaveCount(6);
    expect(await mutationTripIdsAtDeparture(page, "06:00")).toHaveLength(1);
    expect(await mutationTripIdsAtDeparture(page, "06:30")).toHaveLength(1);

    // Edit the created 06:30 trip: change its headsign and block.
    const [createdTrip] = await mutationTripIdsAtDeparture(page, "06:30");
    await page.locator(`#trip-${createdTrip}-edit`).click();
    await page.locator("#trip-drawer").waitFor({ state: "visible" });
    await page.fill("#trip-headsign", "Keyboard heading");
    await page.fill("#trip-block", "SM-9");
    await page.locator("#trip-drawer-save").click();
    await page.locator("#trip-drawer").waitFor({ state: "hidden" });

    await expect(page.locator(`#trip-${createdTrip}-start`)).toHaveText("06:30");
    await expect(page.locator(`#trip-${createdTrip}-edit`)).toBeFocused();

    // Duplicate the 06:30 trip: the default is the source start plus 30 minutes.
    await page.locator(`#trip-${createdTrip}-menu`).click();
    await page.locator(`#trip-${createdTrip}-duplicate`).click();
    await page.locator("#trip-drawer").waitFor({ state: "visible" });
    await expect(page.locator("#trip-start")).toHaveValue("07:00");
    await expect(page.locator("#trip-timing")).toContainText("Secondary");

    const beforeDuplicate = await page
      .locator("#section-BROWSER-SCHED-PM2-table tbody tr")
      .count();

    await page.locator("#trip-drawer-save").click();
    await page.locator("#trip-drawer").waitFor({ state: "hidden" });

    await expect(page.locator("#section-BROWSER-SCHED-PM2-table tbody tr")).toHaveCount(
      beforeDuplicate + 1,
    );

    await capture(page, "step-007-added-1440x1000");
  });

  test("bulk delete totals across sections, names the count and calendar, and clears", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await page.goto(schedulesPath(versionId, MUTATE_ROUTE));
    await expect(page.locator("#trip-SM_T1-start")).toBeVisible();

    await page.locator("#trip-select-SM_CUSTOM_DIFF").check();
    await page.locator("#trip-select-SM_LATE").check();

    await expect(page.locator("#schedules-bulk-toolbar")).toContainText("2 trips selected");
    await expect(page.locator("#schedules-delete-selected")).toHaveText("Delete 2 trips");

    await page.locator("#schedules-delete-selected").click();
    await expect(page.locator("#delete-dialog")).toBeVisible();
    await expect(page.locator("#delete-dialog-title")).toHaveText(
      "Delete 2 trips from Every day service?",
    );
    await expect(page.locator("#delete-dialog-body")).toContainText(
      "This removes the trips and their stop times from this published version. You cannot undo this.",
    );

    // Cancelling returns focus to the toolbar control and deletes nothing.
    await page.locator("#delete-dialog-cancel").click();
    await expect(page.locator("#delete-dialog")).toBeHidden();
    await expect(page.locator("#schedules-delete-selected")).toBeFocused();
    await expect(page.locator("#trip-SM_LATE-start")).toBeVisible();

    // Changing the view clears the selection, so the delete has nothing to act on.
    await page.locator('label[for="direction-filter-option-1"]').click();
    await expect(page.locator("#schedules-bulk-toolbar")).toHaveCount(0);
    await page.locator('label[for="direction-filter-option-0"]').click();
    await expect(page.locator("#trip-SM_LATE-start")).toBeVisible();

    // The real bulk delete removes both and shows the vehicle marker.
    await page.locator("#trip-select-SM_CUSTOM_DIFF").check();
    await page.locator("#trip-select-SM_LATE").check();
    await page.locator("#schedules-delete-selected").click();
    await page.locator("#delete-dialog-confirm").click();
    await expect(page.locator("#delete-dialog")).toBeHidden();

    await expect(page.locator("#trip-SM_LATE-start")).toHaveCount(0);
    await expect(page.locator("#trip-SM_CUSTOM_DIFF-start")).toHaveCount(0);
    await expect(page.locator("#schedules-bulk-toolbar")).toHaveCount(0);

    await capture(page, "step-007-deleted-1440x1000");
  });

  test("a stalled preview and a lost connection keep committing unavailable", async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await page.goto(schedulesPath(versionId, MUTATE_ROUTE));
    await expect(page.locator("#trip-SM_T1-start")).toBeVisible();

    // A departure that is not HH:MM is refused with the fixed copy and focus.
    await page.locator("#schedules-add-trips").click();
    await page.locator("#trip-start").fill("25:9");
    await page.locator("#trip-drawer-save").click();
    await expect(page.locator("#trip-start-error")).toContainText(
      "Enter a departure as HH:MM, for example 06:00 or 25:10.",
    );
    await expect(page.locator("#trip-start")).toBeFocused();
    await capture(page, "step-007-add-error-1440x1000");

    await page.locator("#trip-drawer-cancel").click();
    await page.locator("#trip-drawer").waitFor({ state: "hidden" });

    // The disconnected page disables Add and Save until the socket returns.
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator("#schedules-disconnected")).toBeVisible();
    await expect(page.locator("#schedules-add-trips")).toBeDisabled();

    await page.evaluate(() => window.liveSocket.connect());
    await expect(page.locator("#schedules-disconnected")).toBeHidden();
    await expect(page.locator("#schedules-add-trips")).toBeEnabled();

    await page.locator("#schedules-add-trips").click();
    await page.locator("#trip-drawer").waitFor({ state: "visible" });
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator("#trip-drawer-save")).toBeDisabled();
    await expect(page.locator("#schedules-disconnected")).toBeVisible();
    await capture(page, "step-007-disconnected-1440x1000");
  });

  test("the export after a mutation matches the fixture-authored stop times", async ({
    page,
  }) => {
    test.setTimeout(180_000);

    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await page.goto(schedulesPath(versionId, MUTATE_ROUTE));
    await expect(page.locator("#trip-SM_T1-start")).toHaveText("06:00");

    await page.locator("#schedules-add-trips").click();
    await page.locator("#trip-drawer").waitFor({ state: "visible" });
    await page.selectOption("#trip-pattern", { label: "Mutate secondary" });
    await page.fill("#trip-start", "05:00");
    await page.locator("#trip-drawer-save").click();
    await page.locator("#trip-drawer").waitFor({ state: "hidden" });

    const [createdTrip] = await mutationTripIdsAtDeparture(page, "05:00");
    expect(createdTrip).toBeTruthy();

    // Export the version through the real export workspace and download it.
    await page.goto(`/gtfs/${versionId}/export`);
    await page.locator("#gtfs-export-form").waitFor({ state: "visible" });
    await page.locator("#export-type-full").check();
    await page.locator("#start-export").click();

    await expect
      .poll(() => page.locator("#export-download-link").getAttribute("href"), {
        timeout: 60_000,
      })
      .toContain("/download");

    const downloadPromise = page.waitForEvent("download");
    await page.locator("#export-download-link").click();
    const download = await downloadPromise;

    const path = await download.path();
    const buffer = readFileSync(path);
    const stopTimes = readZipTextMember(buffer, "stop_times.txt");

    const rows = stopTimes
      .split("\n")
      .slice(1)
      .map((line) => line.split(","))
      .filter((cells) => cells[0] === createdTrip)
      .sort((a, b) => Number(a[4]) - Number(b[4]))
      .map((cells) => [cells[3], cells[1], cells[2]]);

    expect(rows).toEqual(EXPORT_STOP_TIME_ROWS);
  });
});

/**
 * The allocated trip ids (route-direction-service-HHMM) whose Start cell shows
 * this departure in the rendered tables, so the seeded trips are never included.
 */
async function mutationTripIdsAtDeparture(page, departure) {
  return page.evaluate(
    ({ value, prefix }) =>
      Array.from(document.querySelectorAll("tr[id^='trip-']"))
        .map((row) => ({
          id: row.id.replace(/^trip-/, ""),
          start: row.querySelector("[id$='-start']")?.textContent?.trim(),
        }))
        .filter((row) => row.start === value && row.id.startsWith(prefix))
        .map((row) => row.id),
    { value: departure, prefix: "BROWSER_SCHEDULES_MUTATE-" },
  );
}
