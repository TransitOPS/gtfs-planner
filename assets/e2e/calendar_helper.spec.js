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

test.describe("drawer review", () => {
  test("hands the prepared change to the existing drawer review", async ({ page }, testInfo) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();

    // A conversation from an earlier test persists for this user and version.
    await page.locator("#agent-new-conversation").click();

    await page
      .locator("#agent-composer-input")
      .fill("No school service next Monday and Tuesday");
    await page.locator("#agent-send").click();

    const reviewButton = page.locator('[id^="agent-review-prepared-"]').last();
    await expect(reviewButton).toBeVisible({ timeout: 30_000 });

    await reviewButton.click();

    const reviewPanel = page.locator("#calendar-date-change-review-panel");
    await expect(reviewPanel).toBeVisible();
    await expect(reviewPanel).toContainText("School weekdays");
    await expect(reviewPanel).toContainText("School express");

    // Fast-forward the drawer's slide-in so the capture shows the settled state.
    await page.screenshot({
      path: testInfo.outputPath("drawer-review-1440.png"),
      animations: "disabled",
    });

    await page.locator("#calendar-date-change-drawer-close").click();

    await expect(reviewPanel).toHaveCount(0);
    // Focus returns to the stable prepared-card container the handoff came from.
    await expect(page.locator('[id^="agent-prepared-"]').last()).toBeFocused();
  });
});

test.describe("server evidence card", () => {
  for (const viewport of VIEWPORTS) {
    test(`shows the server count above contradicting prose at ${viewport.width}x${viewport.height}`, async ({
      page,
    }, testInfo) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await openCalendars(page);

      await page.locator("#agent-helper-open").click();
      await expect(page.locator("#agent-panel")).toBeVisible();

      // Helper sessions live in the server process, so start a fresh one.
      await page.locator("#agent-new-conversation").click();

      await page.locator("#agent-composer-input").fill("Which dates run next week?");
      await page.locator("#agent-send").click();

      // The scripted stand-in answers "Three of those dates run service." after
      // reading the calendar; the server card carries the real count.
      const card = page.locator("#agent-evidence-2-1");
      await expect(card).toBeVisible({ timeout: 30_000 });
      await expect(card).toContainText("Server result");
      await expect(card).toContainText("5 dates run");
      await expect(card).toContainText("Complete");
      await expect(card).toContainText("gtfs_calendars");

      // Exactly one link, and it is the panel's own scoped calendar path.
      const links = card.locator("a");
      await expect(links).toHaveCount(1);
      await expect(links).toHaveAttribute(
        "href",
        /\/gtfs\/[0-9a-f-]+\/calendars\/show\?service_id=SCHOOL_WD/,
      );

      const prose = page.locator("#agent-prose-2");
      await expect(prose).toContainText("Model reply");
      await expect(prose).toContainText("Three of those dates run service.");
      await expect(page.locator("#agent-entries")).toContainText("Three of those dates run service.");

      const fitsViewport = await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      );
      expect(fitsViewport).toBe(true);

      await page.screenshot({
        path: testInfo.outputPath(`evidence-card-${viewport.label}.png`),
        animations: "disabled",
      });
    });
  }
});

test.describe("helper journey", () => {
  test("prepares a change, applies it through the drawer and declines out-of-scope asks", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    await page.locator("#agent-helper-open").click();

    await expect(page.locator("#agent-panel")).toBeVisible();
    await expect(page.locator("#agent-composer-input")).toBeFocused();

    // Helper sessions live in the server process and persist between tests
    // for this user and version, so every journey starts a new conversation.
    await page.locator("#agent-new-conversation").click();

    await page
      .locator("#agent-composer-input")
      .fill("No school service next Monday and Tuesday");
    await page.locator("#agent-composer-input").press("Control+Enter");

    const preparedCard = page.locator('[id^="agent-prepared-"]').last();
    await expect(preparedCard).toContainText("Stop · School express", {
      timeout: 30_000,
    });
    await expect(preparedCard).toContainText("Stop · School weekdays");

    await page.locator('[id^="agent-review-prepared-"]').last().click();

    const reviewPanel = page.locator("#calendar-date-change-review-panel");
    await expect(reviewPanel).toBeVisible();
    await expect(reviewPanel).toContainText("School weekdays");
    await expect(reviewPanel).toContainText("School express");

    await page.locator("#calendar-date-change-apply").click();

    await expect(reviewPanel).toHaveCount(0);
    await expect(preparedCard).toContainText("Applied");

    await page.locator("#agent-composer-input").fill("Delete route 12");
    await page.locator("#agent-composer-input").press("Control+Enter");

    await expect(page.locator("#agent-entries")).toContainText(
      "That isn't available in Calendars",
      { timeout: 30_000 },
    );

    await page.locator("#agent-panel-close").click();

    await expect(page.locator("#agent-panel")).toHaveCount(0);
    await expect(page.locator("#agent-helper-open")).toBeFocused();
  });

  test("keeps the helper usable at phone width", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await openCalendars(page);

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();

    // Helper sessions live in the server process and persist between tests
    // for this user and version, so every journey starts a new conversation.
    await page.locator("#agent-new-conversation").click();
    await expect(page.locator("#agent-composer-input")).toBeVisible();

    const fitsViewport = await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    );
    expect(fitsViewport).toBe(true);

    await page.locator("#agent-panel-close").click();

    await expect(page.locator("#agent-panel")).toHaveCount(0);
    await expect(page.locator("#agent-helper-open")).toBeFocused();
  });
});
