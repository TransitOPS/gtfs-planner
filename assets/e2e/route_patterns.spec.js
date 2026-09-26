import { test, expect } from "@playwright/test";

/**
 * Read-only slice of the route pattern editor.
 *
 * It renders the route Patterns list with its counts and labels, the
 * first-use and unlinked-trips states, and the navigation into a pattern's
 * Stops task, at 1440px and 320px. Every scenario navigates and never saves:
 * the mutation journeys belong to the stops/timings/review step, and the seeded
 * routes stay untouched for those runs.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VIEWPORTS = [
  { label: "1440px", width: 1440, height: 1000 },
  { label: "320px", width: 320, height: 800 },
];

async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");
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

async function bodyFitsViewport(page) {
  return page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
}

function collectPageErrors(page) {
  const problems = [];
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  return problems;
}

let versionId;
let problems;

test.beforeEach(async ({ page }) => {
  problems = collectPageErrors(page);
  await logIn(page);
  versionId = await getVersionId(page);
});

test.afterEach(() => {
  expect(problems ?? [], "browser reported errors").toEqual([]);
});

for (const viewport of VIEWPORTS) {
  test(`pattern list, empty and unlinked states, and details navigation at ${viewport.label}`, async ({
    page,
  }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });

    // Ready list: counts, honest labels and the route's own patterns.
    await page.goto(`/gtfs/${versionId}/routes/BROWSER_PATTERNS_READY/patterns`);
    await page.waitForSelector("#patterns-list-container", { timeout: 10000 });

    await expect(page.locator("#patterns-count")).toContainText("2 patterns");
    await expect(page.locator("#pattern-trip-count")).toContainText("2 trips in this version");
    await expect(page.locator("#patterns-BROWSER-P1")).toContainText("Central – Valley Hospital");
    await expect(page.locator("#patterns-BROWSER-P1")).toContainText("All day");
    await expect(page.locator("#patterns-BROWSER-P1")).toContainText("Direction 0");
    await expect(page.locator("#patterns-BROWSER-P1")).toContainText("Typical");
    await expect(page.locator("#patterns-BROWSER-P2")).toContainText("Direction 1");
    await expect(page.locator("#patterns-BROWSER-P2")).toContainText("Not used yet");
    await expect(page.getByText("Outbound", { exact: true })).toHaveCount(0);
    await expect(page.getByText("Inbound", { exact: true })).toHaveCount(0);
    expect(await bodyFitsViewport(page), "list overflows").toBe(true);

    // Details navigation: opening a pattern lands on Stops.
    await page.locator("#pattern-open-BROWSER-P1").click();
    await page.waitForSelector("#pattern-stops", { timeout: 10000 });
    await expect(page.locator("#pattern-task-stops")).toHaveAttribute("aria-current", "page");
    await expect(page.locator("#pattern-stop-1")).toContainText("Pattern Stop 1");
    await expect(page.locator("#pattern-stop-1")).toContainText("First stop");
    await expect(page.locator("#edit-status")).toContainText("Saved in this version");
    await expect(page.locator("#published-version-notice")).toContainText(
      "a published version",
    );

    // The Details task shows the stored values and the Pattern ID disclosure.
    await page.locator("#pattern-task-details").click();
    await page.waitForSelector("#pattern-details-form", { timeout: 10000 });
    await expect(page.locator("#pattern-details-name")).toHaveValue("Central – Valley Hospital");
    await expect(page.locator("#pattern-details-form")).toContainText("Headsign for new trips");
    await page.locator("#pattern-details-additional summary").click();
    await expect(page.locator("#pattern-details-id")).toContainText("BROWSER-P1");
    expect(await bodyFitsViewport(page), "details overflows").toBe(true);

    // First use: a route with no trips and no patterns.
    await page.goto(`/gtfs/${versionId}/routes/BROWSER_PATTERNS_EMPTY/patterns`);
    await page.waitForSelector("#patterns-empty", { timeout: 10000 });
    await expect(page.locator("#patterns-empty")).toContainText("Add the first pattern");
    await expect(page.locator("#patterns-create-empty")).toBeVisible();
    expect(await bodyFitsViewport(page), "empty state overflows").toBe(true);

    const createBox = await page.locator("#patterns-create-empty").boundingBox();
    expect(createBox).not.toBeNull();
    expect(createBox.height).toBeGreaterThanOrEqual(44);

    // Unlinked trips: build affordance without mutating anything.
    await page.goto(`/gtfs/${versionId}/routes/BROWSER_PATTERNS_UNLINKED/patterns`);
    await page.waitForSelector("#patterns-unlinked", { timeout: 10000 });
    await expect(page.locator("#patterns-unlinked")).toContainText(
      "Group existing trips into patterns",
    );
    await expect(page.locator("#patterns-build")).toBeVisible();
    expect(await bodyFitsViewport(page), "unlinked state overflows").toBe(true);

    const buildBox = await page.locator("#patterns-build").boundingBox();
    expect(buildBox).not.toBeNull();
    expect(buildBox.height).toBeGreaterThanOrEqual(44);
  });
}
