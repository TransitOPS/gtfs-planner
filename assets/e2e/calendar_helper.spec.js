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
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
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

      await page.screenshot({
        path: testInfo.outputPath(`panel-${viewport.label}.png`),
      });

      await page.locator("#agent-panel-close").click();

      await expect(page.locator("#agent-panel")).toHaveCount(0);
      await expect(page.locator("#calendars-list")).toBeVisible();
      await expect(page.locator("#agent-helper-open")).toBeFocused();
    });
  }
});

test.describe("drawer review", () => {
  test("hands the prepared change to the existing drawer review", async ({
    page,
  }, testInfo) => {
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
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await openCalendars(page);

      await page.locator("#agent-helper-open").click();
      await expect(page.locator("#agent-panel")).toBeVisible();

      // Helper sessions live in the server process, so start a fresh one.
      await page.locator("#agent-new-conversation").click();

      await page
        .locator("#agent-composer-input")
        .fill("Which dates run next week?");
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
      await expect(page.locator("#agent-entries")).toContainText(
        "Three of those dates run service.",
      );

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

// The approved end-date extension journey. The approval is the editor's own
// sentence in the page's form; the scripted stand-in asks for exactly the
// calendar and end date the editor approved, because the tool reads the
// approval from the server-held context and refuses anything else.
const EXTENSION_DAYS = 200;
const APPROVAL_TEXT =
  "Board approved running the school connector through the 2027 spring term.";

function isoDaysFromNow(days) {
  const date = new Date(Date.now() + days * 86400000);
  return date.toISOString().slice(0, 10);
}

async function approveExtension(
  page,
  serviceId = "SCHOOL_WD",
  endDate = isoDaysFromNow(EXTENSION_DAYS),
) {
  await page.locator("#calendar-extension-approval").scrollIntoViewIfNeeded();
  await page.selectOption("#calendar-extension-service", serviceId);
  await page.fill("#calendar-extension-end-date", endDate);
  await page.fill("#calendar-extension-approval-text", APPROVAL_TEXT);
  await page.locator("#calendar-extension-approve").click();
  await expect(page.locator("#calendar-extension-approved")).toContainText(
    "Approved extending",
    { timeout: 15_000 },
  );
}

async function askForTheExtension(page, calendar = "school weekdays") {
  const panel = page.locator("#agent-panel");
  if (await panel.count()) {
    await expect(panel).toBeVisible();
  } else {
    await page.locator("#agent-helper-open").click();
    await expect(panel).toBeVisible();
  }

  // Helper sessions live in the server process, so start a new conversation.
  await page.locator("#agent-new-conversation").click();
  await page
    .locator("#agent-composer-input")
    .fill(`Can we extend the ${calendar} calendar?`);
  await page.locator("#agent-send").click();

  const card = page.locator('[id^="agent-prepared-"]').last();
  await expect(card).toBeVisible({ timeout: 45_000 });
  return card;
}

test.describe("approved calendar extension", () => {
  test("refuses an approval the editor did not write", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    await page.locator("#calendar-extension-approval").scrollIntoViewIfNeeded();
    await page.selectOption("#calendar-extension-service", "SCHOOL_WD");
    await page.fill(
      "#calendar-extension-end-date",
      isoDaysFromNow(EXTENSION_DAYS),
    );
    await page.locator("#calendar-extension-approve").click();

    await expect(page.locator("#calendar-extension-errors")).toContainText(
      "Enter why you are approving this extension.",
    );
    await expect(page.locator("#calendar-extension-approved")).toHaveCount(0);
  });

  test("prepares the approved extension and reviews its exact impact", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    await approveExtension(page);
    const card = await askForTheExtension(page);

    // The server evidence card, not the model's sentence, owns the counts.
    await expect(page.locator("#agent-evidence-2-1")).toContainText(
      "Server result",
    );
    await expect(page.locator("#agent-evidence-2-1")).toContainText(
      "dates newly in service",
    );
    await expect(card).toContainText("Extend School weekdays");
    await expect(card).toContainText(APPROVAL_TEXT);
    await expect(card).toContainText("Routes affected · 1 route");
    await expect(card).toContainText("Review extension");

    await page.locator('[id^="agent-review-prepared-"]').last().click();

    const impact = page.locator("#calendar-extension-impact");
    await expect(impact).toBeVisible();
    await expect(impact).toContainText("Result after applying");
    await expect(impact).toContainText(APPROVAL_TEXT);
    await expect(impact).toContainText("SCHOOL_ROUTE");
    // No holiday is inferred for the newly active dates.
    await expect(impact).toContainText(
      "newly active dates have no recorded day off",
    );

    // Cancelling writes nothing and leaves the card ready to review.
    await page.screenshot({
      path: testInfo.outputPath("extension-review-1440.png"),
      animations: "disabled",
    });
    await page.locator("#calendar-extension-cancel").click();

    await expect(page.locator("#calendar-extension-impact")).toHaveCount(0);
    await expect(card).toContainText("Ready to review");
  });

  for (const viewport of VIEWPORTS) {
    test(`reviews the extension at ${viewport.width}x${viewport.height}`, async ({
      page,
    }, testInfo) => {
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await openCalendars(page);

      await approveExtension(page);
      await askForTheExtension(page);
      await page.locator('[id^="agent-review-prepared-"]').last().click();

      await expect(page.locator("#calendar-extension-impact")).toBeVisible();

      const fitsViewport = await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      );
      expect(fitsViewport).toBe(true);

      await page.screenshot({
        path: testInfo.outputPath(`extension-review-${viewport.label}.png`),
        animations: "disabled",
      });
    });
  }

  test("applies the exact reviewed command and credits the card", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    await approveExtension(page);
    const card = await askForTheExtension(page);
    await page.locator('[id^="agent-review-prepared-"]').last().click();
    await expect(page.locator("#calendar-extension-impact")).toBeVisible();

    await page.locator("#calendar-extension-apply").click();

    await expect(page.locator("#calendar-extension-impact")).toHaveCount(0);
    await expect(page.locator("#calendars-extension-status")).toContainText(
      "Extended SCHOOL_WD",
    );
    await expect(card).toContainText("Applied");
    await expect(page.locator('[id^="agent-review-prepared-"]')).toHaveCount(0);

    await page.screenshot({
      path: testInfo.outputPath("extension-applied-1440.png"),
      animations: "disabled",
    });
  });

  test("an edited end date applies the edit and is not credited to the helper", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    // Its own calendar: the exact-command case above already extended
    // SCHOOL_WD, so a second approval of it would extend nothing.
    await approveExtension(page, "SCHOOL_EX");
    const card = await askForTheExtension(page, "school express");
    await page.locator('[id^="agent-review-prepared-"]').last().click();
    await expect(page.locator("#calendar-extension-impact")).toBeVisible();

    const approved = await page
      .locator("#calendar-extension-review-end-date")
      .inputValue();
    const edited = isoDaysFromNow(EXTENSION_DAYS - 60);
    await page.fill("#calendar-extension-review-end-date", edited);
    await expect(page.locator("#calendar-extension-impact")).toContainText(
      new Date(edited).getFullYear().toString(),
    );

    await page.locator("#calendar-extension-apply").click();

    await expect(page.locator("#calendars-extension-status")).toContainText(
      "Extended SCHOOL_EX",
    );
    await expect(page.locator("#agent-notice")).toContainText(
      "The original prepared change was not applied.",
    );
    await expect(card).toContainText("Ready to review");
    expect(edited).not.toBe(approved);
  });
});
