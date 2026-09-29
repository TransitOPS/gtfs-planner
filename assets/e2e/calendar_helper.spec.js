import { test, expect } from "@playwright/test";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const HELPER_VERSION = "Browser Helper Version";

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

// The helper version is seeded by test/support/browser_seed.exs for this journey.
async function openCalendars(page) {
  await logIn(page);
  const versionId = await versionIdFor(page, HELPER_VERSION);
  await page.goto(`/gtfs/${versionId}/calendars`);
  await page.waitForSelector(
    "#calendars-list-container, #calendars-first-use-empty, #calendars-unavailable",
    { timeout: 15000 },
  );
  return versionId;
}

const VIEWPORTS = [
  { label: "1440", width: 1440, height: 1000 },
  { label: "390", width: 390, height: 844 },
];

test.describe("helper panel layout", () => {
  for (const viewport of VIEWPORTS) {
    test(`opens beside the list at ${viewport.width}x${viewport.height}`, async ({
      page,
    }, testInfo) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await openCalendars(page);

      await expect(page.locator("#agent-panel")).toHaveCount(0);

      await page.locator("#agent-helper-open").click();

      await expect(page.locator("#agent-panel")).toBeVisible();
      await expect(page.locator("#agent-panel")).toContainText(
        "Calendars · " + HELPER_VERSION,
      );
      await expect(page.locator("#agent-composer-input")).toBeFocused();

      const fitsViewport = await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      );
      expect(fitsViewport).toBe(true);

      if (viewport.width < 1024) {
        // The panel replaces the workspace at phone width; the list returns after close.
        await expect(page.locator("#calendars-list")).toBeHidden();
      } else {
        // The panel never hides the list on desktop.
        await expect(page.locator("#calendars-list")).toBeVisible();
      }

      await page.screenshot({ path: testInfo.outputPath(`panel-${viewport.label}.png`) });

      await page.locator("#agent-panel-close").click();

      await expect(page.locator("#agent-panel")).toHaveCount(0);
      await expect(page.locator("#calendars-list")).toBeVisible();
      await expect(page.locator("#agent-helper-open")).toBeFocused();
    });
  }
});
