import { test, expect } from "@playwright/test";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const SEEDED_NAMES = [
  "Every day service",
  "Legacy service",
  "Metadata only",
  "Odd service id",
  "School days",
  "Unused calendar",
];

const VIEWPORTS = [
  { label: "1440x1000", width: 1440, height: 1000 },
  { label: "1280x900", width: 1280, height: 900 },
];

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

async function openCalendars(page, versionName = "Browser E2E Version") {
  await logIn(page);
  const versionId = await versionIdFor(page, versionName);
  await page.goto(`/gtfs/${versionId}/calendars`);
  await page.waitForSelector(
    "#calendars-list-container, #calendars-first-use-empty, #calendars-unavailable",
    { timeout: 15000 },
  );
  return versionId;
}

async function expectRows(page, names, timeout = 8000) {
  await expect.poll(() => rowNames(page), { timeout }).toEqual(names);
  await expect(page.locator("#calendars-list tr")).toHaveCount(names.length);
}

async function rowNames(page) {
  const names = await page
    .locator("#calendars-list tr td:first-child a")
    .allTextContents();

  return names.map((name) => name.trim());
}

test.describe("calendar list", () => {
  test("renders the scoped list with shared controls, statuses and layout at both desktop viewports", async ({
    page,
  }) => {
    await page.setViewportSize(VIEWPORTS[0]);
    const versionId = await openCalendars(page);

    for (const viewport of VIEWPORTS) {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await page.goto(`/gtfs/${versionId}/calendars`);
      await page.waitForSelector("#calendars-list-container", { timeout: 15000 });

      // The navigation item owns an active Calendars surface.
      const calendarsNav = page.locator('nav[aria-label="Main navigation"] a', {
        hasText: "Calendars",
      });
      await expect(calendarsNav).toHaveText("Calendars", { timeout: 5000 });
      await expect(calendarsNav).toHaveAttribute("aria-current", "page");

      // Semantic table with the reference's five columns.
      const table = page.locator("#calendars-list-container table");
      await expect(table).toBeVisible();
      await expect(table.locator("thead th")).toHaveText([
        /Calendar/,
        "Regular days",
        /Service dates/,
        "Trips",
        "Status",
      ]);

      expect(await rowNames(page)).toEqual(SEEDED_NAMES);

      // Count strip, agency-local today, and the feed-gap callout.
      await expect(page.locator("#calendar-counts-item-calendars")).toContainText("6");
      await expect(page.locator("#calendar-counts-item-run-today")).toContainText("1");
      await expect(page.locator("#calendars-today")).toContainText("Today ·");
      await expect(page.locator("#calendars-feed-gap")).toBeVisible();

      // Status presentation comes from the real computed summaries.
      const rows = await page.locator("#calendars-list tr").allTextContents();
      const statusText = rows.join(" | ");
      expect(statusText).toContain("Runs today");
      expect(statusText).toContain("Ended");
      expect(statusText).toContain("No service");
      expect(statusText).toContain("Ends in 10 days");
      expect(statusText).toContain("Ends in 5 days");
      expect(statusText).toContain("Not used by trips");

      // Grouped trip usage is numeric and right-aligned in its own column.
      const dailyRow = page.locator("#calendars-list tr", { hasText: "Every day service" });
      await expect(dailyRow.locator("td").nth(3)).toHaveText("3");
      await expect(page.locator("#calendars-list tr", { hasText: "School days" }).locator("td").nth(3)).toHaveText("2");
      await expect(page.locator("#calendars-list tr", { hasText: "Legacy service" }).locator("td").nth(3)).toHaveText("1");

      // Detail links keep URI-encoded service IDs.
      const oddLink = page.locator("#calendars-list tr", { hasText: "Odd service id" }).locator("td").first().locator("a");
      await expect(oddLink).toHaveAttribute("href", /service_id=svc%2Fodd\+name/);

      // No control owned by the create/editor/date-change steps is presented.
      for (const label of [
        "Create calendar",
        "Change service on a date",
        "Add break",
        "Duplicate calendar",
        "Delete calendar",
        "Extend end date",
      ]) {
        await expect(page.getByText(label, { exact: false })).toHaveCount(0);
      }

      // The table keeps its hierarchy without horizontal page overflow.
      const overflows = await page.evaluate(
        () => document.body.scrollWidth > window.innerWidth + 1,
      );
      expect(overflows).toBe(false);
    }
  });

  test("search, status filters and sorting round-trip through the URL", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    // Search by name.
    await page.fill("#calendar-search", "school");
    await expect.poll(() => rowNames(page), { timeout: 5000 }).toEqual(["School days"]);
    await expect(page.locator("#calendars-list tr")).toHaveCount(1);
    await expect(page.locator("#result-count")).toHaveText("1 of 6 calendars");

    // Search by service ID.
    await page.fill("#calendar-search", "CAL_LEGACY");
    await expect.poll(() => rowNames(page), { timeout: 5000 }).toEqual(["Legacy service"]);

    // A search with no matches keeps the counts and offers to clear the filters.
    await page.fill("#calendar-search", "no such calendar");
    await expect(page.locator("#calendars-filtered-empty")).toBeVisible({ timeout: 5000 });
    await expect(page.locator("#result-count")).toHaveText("0 of 6 calendars");
    await page.click("#calendars-clear-filters");
    await expect(page.locator("#calendars-list tr")).toHaveCount(6, { timeout: 5000 });

    // Status filters with the documented allowlist.
    await page.selectOption("#calendar-status", "ended");
    await expectRows(page, ["Legacy service"]);

    await page.selectOption("#calendar-status", "active_today");
    await expectRows(page, ["Every day service"]);

    await page.selectOption("#calendar-status", "active_period");
    await expectRows(page, ["Every day service", "School days", "Unused calendar"]);

    await page.selectOption("#calendar-status", "unused");
    await expectRows(page, ["Metadata only", "Odd service id", "Unused calendar"]);

    await page.selectOption("#calendar-status", "all");
    await expectRows(page, SEEDED_NAMES);

    // The URL carries the state, and reloading it reproduces the list.
    await page.fill("#calendar-search", "service");
    await page.selectOption("#calendar-status", "all");
    await expectRows(page, ["Every day service", "Legacy service", "Odd service id"]);
    expect(page.url()).toContain("search=service");

    await page.reload();
    await page.waitForSelector("#calendars-list-container");
    await expect(page.locator("#calendar-search")).toHaveValue("service");
    await expectRows(page, ["Every day service", "Legacy service", "Odd service id"]);

    // Keyboard-reachable sort controls toggle direction through the URL.
    await page.goto(page.url().split("?")[0]);
    await page.waitForSelector("#calendars-list-container");

    const nameHeader = page.locator("#calendars-list-container thead th").first();
    await expect(nameHeader).toHaveAttribute("aria-sort", "ascending");

    await nameHeader.locator("button").click();
    await expect(nameHeader).toHaveAttribute("aria-sort", "descending", { timeout: 5000 });
    await expectRows(page, [...SEEDED_NAMES].reverse());
    expect(page.url()).toContain("sort_dir=desc");

    // Period sorting keeps identities without an active date last in both directions.
    const periodHeader = page.locator("#calendars-list-container thead th", {
      hasText: "Service dates",
    });
    await periodHeader.locator("button").click();
    await expect(periodHeader).toHaveAttribute("aria-sort", "ascending", { timeout: 5000 });
    await expect
      .poll(async () => (await rowNames(page)).at(-1), { timeout: 8000 })
      .toBe("Metadata only");

    await periodHeader.locator("button").click();
    await expect(periodHeader).toHaveAttribute("aria-sort", "descending", { timeout: 5000 });
    await expect
      .poll(async () => (await rowNames(page)).at(-1), { timeout: 8000 })
      .toBe("Metadata only");
  });

  test("a version without calendars shows the first-use empty state, not a failed read", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await openCalendars(page, "Catalog Empty Version");

    await expect(page.locator("#calendars-first-use-empty")).toBeVisible();
    await expect(page.locator("#calendars-first-use-empty")).toContainText("No calendars yet");
    await expect(page.locator("#calendars-list-container")).toHaveCount(0);
    await expect(page.locator("#calendars-unavailable")).toHaveCount(0);
    await expect(page.getByText("Create calendar", { exact: false })).toHaveCount(0);
  });
});
