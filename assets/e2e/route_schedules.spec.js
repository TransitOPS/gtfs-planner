import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { mkdirSync } from "node:fs";
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
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "EDITOR_PASSWORD_PLACEHOLDER",
};

const READY_ROUTE = "BROWSER_SCHEDULES_READY";
const WIDE_ROUTE = "BROWSER_SCHEDULES_WIDE";
const EMPTY_ROUTE = "BROWSER_SCHEDULES_EMPTY";
const NOCAL_ROUTE = "BROWSER_SCHEDULES_NOCAL";

const CALENDAR_ROUTE = "Every day service";

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

      // No mutation control ships before the write path is wired.
      await expect(page.locator("#schedules-add-trips")).toHaveCount(0);
      await expect(page.locator("#schedules-bulk-toolbar")).toHaveCount(0);
      await expect(page.getByRole("button", { name: "Add trips" })).toHaveCount(0);

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

      // 72 stop columns + selection, Start, Timing, Trip no. and Block.
      await expect(page.locator("#section-BROWSER-SCHED-PW-table thead th")).toHaveCount(77);
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
  });
}
