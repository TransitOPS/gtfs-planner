import { test, expect } from "@playwright/test";

/**
 * Service-answer journeys for the Schedule and Calendars helpers (step 7).
 *
 * The fixture is the Browser Service Answers Version seeded by
 * `test/support/browser_seed.exs`, and the scripted stand-in
 * (`test/support/agents/browser_open_router.ex`) asks about the same dates
 * through `GtfsPlanner.Agents.BrowserServiceAnswers`, so a card that drifted
 * from the feed behind it fails here:
 *
 *   H8 — a holiday Thursday on which the weekday baseline is removed and an
 *     exception-only calendar takes over, a loop that visits Central Station
 *     twice, a frequency trip boarding 15 minutes after its first stop, a trip
 *     with no readable time and one departure before 18:00
 *   H12 — a Sunday-only calendar that keeps running after H8's standard
 *     calendar has ended
 *
 * Only the OpenRouter HTTP boundary is scripted; the page, the panel, the
 * facade, the session, the turn loop, the packs and the domain reads are the
 * shipped ones.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const ANSWERS_VERSION = "Browser Service Answers Version";
const HARBOR_ROUTE = "H8";
const UNTOUCHED = "#schedules-add-trips";
const PROSE = "#agent-prose-2";

const VIEWPORTS = [
  { label: "1440", width: 1440, height: 1000 },
  { label: "320", width: 320, height: 800 },
];

const EXTENSION_DAYS = 200;
const APPROVAL_TEXT =
  "Board approved running the weekday baseline past the holiday weekend.";

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

async function openRouteSchedules(page) {
  await logIn(page);
  const versionId = await versionIdFor(page, ANSWERS_VERSION);
  await page.goto(schedulesPath(versionId, HARBOR_ROUTE));
  await expect(page.locator("#planning-summary")).toBeVisible();
  return versionId;
}

async function openCalendars(page) {
  await logIn(page);
  const versionId = await versionIdFor(page, ANSWERS_VERSION);
  await page.goto(`/gtfs/${versionId}/calendars`);
  await page.waitForSelector(
    "#calendars-list-container, #calendars-first-use-empty, #calendars-unavailable",
    { timeout: 15_000 },
  );
  return versionId;
}

/** Opens the panel and starts a fresh conversation on the bound page. */
async function openPanel(page) {
  if ((await page.locator("#agent-panel").count()) === 0) {
    await page.locator("#agent-helper-open").click();
  }

  await expect(page.locator("#agent-panel")).toBeVisible();
  await page.locator("#agent-new-conversation").click();
  await expect(page.locator("#agent-composer-input")).toBeVisible();
}

/** The element the browser currently has focus on, by its DOM id. */
function focusedId(page) {
  return page.evaluate(() => document.activeElement?.id ?? "");
}

async function ask(page, message) {
  await page.locator("#agent-composer-input").fill(message);
  await page.locator("#agent-send").click();
}

function isoDaysFromNow(days) {
  return new Date(Date.now() + days * 86400000).toISOString().slice(0, 10);
}

/**
 * The document fits the viewport. The shared header (version switcher and user
 * menu) is wider than a 320px viewport with or without the panel, so at phone
 * width the assertion is scoped to the panel step 7 added.
 */
async function answerFitsWidth(page, viewportWidth) {
  return page.evaluate((width) => {
    if (width >= 1024) {
      return document.documentElement.scrollWidth <= window.innerWidth;
    }

    const panel = document.querySelector("#agent-panel");
    return panel !== null && panel.scrollWidth <= panel.clientWidth + 1;
  }, viewportWidth);
}

test.describe("holiday departures (A02)", () => {
  for (const viewport of VIEWPORTS) {
    test(`answers with the server's departures at ${viewport.width}x${viewport.height}`, async ({
      page,
    }, testInfo) => {
      test.setTimeout(90_000);

      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      const versionId = await openRouteSchedules(page);

      // The page's own schedule controls are live before the panel opens.
      await expect(page.locator(UNTOUCHED)).toBeEnabled();
      await expect(page.locator("#agent-panel")).toHaveCount(0);

      await openPanel(page);

      // Opening the panel moves focus into the composer, so the first question
      // can be typed without reaching for the mouse.
      expect(await focusedId(page)).toBe("agent-composer-input");

      await ask(page, "What leaves Central Station after 6pm on Thanksgiving?");

      // The card carries the server's count, the occurrences the model had to
      // name, the frequency windows translated to the boarding stop and the
      // trips whose time could not be read.
      const card = page.locator("#agent-evidence-2-1");
      await expect(card).toBeVisible({ timeout: 30_000 });
      await expect(card).toContainText("Server result");
      await expect(card).toContainText("2 departures");
      await expect(card).toContainText("departures after 18:00:00");
      await expect(card).toContainText("Central Station (occurrence 2)");
      await expect(card).toContainText("America/New_York");
      await expect(card).toContainText("HOLIDAY");
      await expect(card).toContainText("Frequency windows");
      await expect(card).toContainText("Trips with no readable time");
      await expect(card).toContainText("Complete");
      await expect(card).toContainText("gtfs_service_queries");

      // The boundary and the after-midnight rule are disclosed, not hidden.
      await expect(card).toContainText("before_boundary · 2");
      await expect(card).toContainText("after_midnight_excluded · 1");

      // Exactly one link, and it is this route's own Schedules page.
      const links = card.locator("a");
      await expect(links).toHaveCount(1);
      await expect(links).toHaveAttribute(
        "href",
        new RegExp(
          `${schedulesPath(versionId, HARBOR_ROUTE).replaceAll("/", "\\/")}$`,
        ),
      );

      // The stand-in's sentence contradicts the card on purpose: the card is
      // the answer the panel credits.
      await expect(page.locator(PROSE)).toContainText("Model reply");
      await expect(page.locator(PROSE)).toContainText(
        "Five trips leave Central Station after 6:00pm.",
      );

      // The schedule behind the panel is unchanged and still editable.
      await expect(page.locator(UNTOUCHED)).toBeEnabled();
      await expect(page.locator("#schedules-sections")).toBeVisible();

      const fitsViewport = await answerFitsWidth(page, viewport.width);
      expect(fitsViewport).toBe(true);

      await page.screenshot({
        path: testInfo.outputPath(`holiday-departures-${viewport.label}.png`),
        animations: "disabled",
      });
    });
  }

  test("refuses a question the loop makes ambiguous instead of guessing", async ({
    page,
  }, testInfo) => {
    test.setTimeout(90_000);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openRouteSchedules(page);
    await openPanel(page);

    await ask(
      page,
      "Which visit at Central Station should I read for the last departure on Thanksgiving?",
    );

    await expect(page.locator("#agent-entries")).toContainText(
      "I did not answer, because Central Station is visited more than once",
      { timeout: 30_000 },
    );
    await expect(page.locator("#agent-entries")).toContainText(
      "Ask which visit you mean",
    );

    // A refused turn renders no card and leaves the page's own controls live.
    await expect(page.locator("[data-evidence-kind]")).toHaveCount(0);
    await expect(page.locator(UNTOUCHED)).toBeEnabled();

    await page.screenshot({
      path: testInfo.outputPath("ambiguous-occurrence-1440.png"),
      animations: "disabled",
    });
  });

  test("reports a provider failure and keeps both the Retry and the page live", async ({
    page,
  }, testInfo) => {
    test.setTimeout(90_000);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openRouteSchedules(page);
    await openPanel(page);

    await ask(page, "Is the provider key still valid?");

    await expect(page.locator("#agent-entries")).toContainText(
      "The helper is unavailable right now.",
      { timeout: 30_000 },
    );
    await expect(page.locator("#agent-retry-2")).toBeVisible();
    await expect(page.locator("[data-evidence-kind]")).toHaveCount(0);

    // The failure is announced, and the schedule is still the editor's.
    await expect(page.locator("#agent-status")).toHaveCount(1);
    await expect(page.locator(UNTOUCHED)).toBeEnabled();
    await expect(page.locator("#schedules-sections")).toBeVisible();

    const fitsViewport = await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    );
    expect(fitsViewport).toBe(true);

    await page.screenshot({
      path: testInfo.outputPath("provider-failure-1440.png"),
      animations: "disabled",
    });
  });
});

test.describe("calendar coverage (A19)", () => {
  for (const viewport of VIEWPORTS) {
    test(`shows the gap and the alternate service at ${viewport.width}x${viewport.height}`, async ({
      page,
    }, testInfo) => {
      test.setTimeout(90_000);

      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await openCalendars(page);
      await openPanel(page);

      await ask(
        page,
        "Which dates keep service on H8 and H12 after the standard calendar ends?",
      );

      const card = page.locator("#agent-evidence-2-1");
      await expect(card).toBeVisible({ timeout: 30_000 });
      await expect(card).toContainText("Server result");
      await expect(card).toContainText("2 routes over 2 dates");
      await expect(card).toContainText("4 route and date records");
      await expect(card).toContainText("REGULAR");
      await expect(card).toContainText("Complete");
      await expect(card).toContainText("gtfs_service_queries");

      // Both reviewed routes are linked, and nothing else is.
      const links = card.locator("a");
      await expect(links).toHaveCount(2);
      await expect(links.nth(0)).toHaveAttribute("href", /\/routes\/H12/);
      await expect(links.nth(1)).toHaveAttribute("href", /\/routes\/H8/);

      // H8 has nothing left on either date; H12 keeps Sunday service through
      // its own calendar, which is what the answer is about.
      await expect(page.locator("#agent-entries")).toContainText(
        "H8 has no service on either date",
      );
      await expect(page.locator("#agent-entries")).toContainText(
        "H12 keeps Sunday service through SCHOOL",
      );

      // A read-only answer prepares nothing, so nothing offers Apply.
      await expect(page.locator('[id^="agent-prepared-"]')).toHaveCount(0);
      await expect(page.locator("#agent-entries")).not.toContainText("Apply");

      const fitsViewport = await answerFitsWidth(page, viewport.width);
      expect(fitsViewport).toBe(true);

      await page.screenshot({
        path: testInfo.outputPath(`coverage-card-${viewport.label}.png`),
        animations: "disabled",
      });
    });
  }

  test("refuses more dates than one answer can cover", async ({ page }) => {
    test.setTimeout(90_000);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);
    await openPanel(page);

    await ask(
      page,
      "Check every date for the next two months for H8 and H12 on the standard calendar.",
    );

    await expect(page.locator("#agent-entries")).toContainText(
      "Ask about fewer dates at a time.",
      { timeout: 30_000 },
    );
    await expect(page.locator("[data-evidence-kind]")).toHaveCount(0);
    await expect(page.locator('[id^="agent-prepared-"]')).toHaveCount(0);
  });

  test("refuses a calendar the service version does not have", async ({
    page,
  }) => {
    test.setTimeout(90_000);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);
    await openPanel(page);

    await ask(
      page,
      "Which dates run for the retired calendar on Thanksgiving?",
    );

    await expect(page.locator("#agent-entries")).toContainText(
      "No calendar with service_id RETIRED in this service version.",
      { timeout: 30_000 },
    );
    await expect(page.locator("[data-evidence-kind]")).toHaveCount(0);
  });

  test("hands an approved extension to the page's own review", async ({
    page,
  }, testInfo) => {
    test.setTimeout(90_000);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    await page.locator("#calendar-extension-approval").scrollIntoViewIfNeeded();
    await page.selectOption("#calendar-extension-service", "WEEKDAY");
    await page.fill(
      "#calendar-extension-end-date",
      isoDaysFromNow(EXTENSION_DAYS),
    );
    await page.fill("#calendar-extension-approval-text", APPROVAL_TEXT);
    await page.locator("#calendar-extension-approve").click();
    await expect(page.locator("#calendar-extension-approved")).toContainText(
      "Approved extending",
      { timeout: 15_000 },
    );

    await openPanel(page);
    await ask(page, "Can we extend the harbor weekday calendar?");

    const prepared = page.locator('[id^="agent-prepared-"]').last();
    await expect(prepared).toBeVisible({ timeout: 45_000 });
    await expect(prepared).toContainText("Review extension");
    await expect(prepared).toContainText(APPROVAL_TEXT);

    await page.locator('[id^="agent-review-prepared-"]').last().click();

    const impact = page.locator("#calendar-extension-impact");
    await expect(impact).toBeVisible();
    await expect(impact).toContainText("Result after applying");
    await expect(impact).toContainText(APPROVAL_TEXT);

    // The review takes focus into its own end-date control, the one the editor
    // would change before applying.
    expect(await focusedId(page)).toBe("calendar-extension-review-end-date");

    await page.screenshot({
      path: testInfo.outputPath("coverage-extension-review-1440.png"),
      animations: "disabled",
    });

    // Cancelling the review writes nothing, returns focus to the card and
    // leaves it ready to review again.
    await page.locator("#calendar-extension-cancel").click();
    await expect(impact).toHaveCount(0);
    await expect(prepared).toContainText("Ready to review");
    expect(await focusedId(page)).toBe(await prepared.getAttribute("id"));
  });
});
