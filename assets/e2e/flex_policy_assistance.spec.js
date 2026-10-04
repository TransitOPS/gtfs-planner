// The approved policy source intake and the Flex policy helper on the service
// page, for feature `ai-09-flex-assistance`.
//
// Step 4 owns the shell: login, version selection, the seeded Newport
// Dial-a-Ride service page, the source intake's own states and the captures
// step 4's subspec names. Step 7 adds the whole assisted journey on top of it:
// the supported policy reviewed, staged and saved through the page's own Save,
// the refusals the helper cannot represent, the source-overflow refusal, an
// unsaved contact that survives staging, the overlap choices, and the 320×800
// and 1440×900 captures the QA tour links.
//
// Every journey drives ordinary navigation and ordinary controls. The only
// fake boundary is the final provider HTTP, through the repository's existing
// `GtfsPlanner.Agents.BrowserOpenRouter`, so the pack, the assistant, the
// native comparison and the guarded save are all the real ones.
//
// Capture root follows the run's own spec root so a worktree writes beside the
// specs it implements. The Playwright runner starts in `assets/`, so
// repository-relative inputs resolve from the checkout root the way
// `playwright.config.js` does.
import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SPEC_ROOT =
  process.env.AI09_SPEC_ROOT ||
  resolve(REPO_ROOT, ".specs", "ai-09-flex-assistance");
const CAPTURE_DIR = resolve(SPEC_ROOT, "evidence", "captures");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const FLEX_VERSION = "Browser Flex Version";
const SERVICE_NAME = "Newport Dial-a-Ride";

const POLICY_TEXT =
  "Newport Dial-a-Ride runs weekdays 7:00 am to 6:00 pm. " +
  "Riders must call at least 30 minutes ahead. " +
  "The office is closed on federal holidays.";

const DESKTOP = { width: 1440, height: 900 };
const NARROW = { width: 320, height: 800 };

// Every map tile request is answered with a blank tile, so this journey never
// depends on the Geoapify plan.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

async function logIn(page) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// A click that lands before the LiveView joins is dropped, so every navigation
// waits for the mounted view first.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return Boolean(
      main &&
      main.classList.contains("phx-connected") &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.isConnected(),
    );
  });
}

// Accepts the editor's own authorized policy text through the intake's form.
// This is the only thing that gives the helper a source to work from: the
// pack refuses a conversation whose context carries no accepted source, so
// every journey below accepts one before it opens the panel.
async function acceptSource(
  page,
  { label = "Newport flex policy", text = POLICY_TEXT } = {},
) {
  await page.fill("#flex-policy-source-label", label);
  await page.fill("#flex-policy-source-text", text);
  await page.locator("#flex-policy-accept").click();
  await expect(page.locator("#flex-policy-source-accepted")).toContainText(
    label,
  );
}

// Opens the panel and starts a conversation of its own. Helper sessions live in
// the server process and survive between tests for this user and version, so a
// journey that reuses one would read another test's entries.
async function openHelper(page) {
  await page.locator("#agent-helper-open").click();
  await expect(page.locator("#agent-panel")).toBeVisible();
  await page.locator("#agent-new-conversation").click();
  await expect(page.locator("#agent-composer-input")).toBeVisible();
}

// Sends one question and waits for the settled turn: the scripted stand-in
// reads the saved policy, prepares the candidate and replies, so the prepared
// card is the last thing to arrive.
async function askHelper(page, message, preparedCardSelector) {
  await page.locator("#agent-composer-input").fill(message);
  await page.locator("#agent-send").click();
  await expect(
    page.locator(preparedCardSelector || '[id^="agent-prepared-"]').last(),
  ).toBeVisible({
    timeout: 60_000,
  });
}

// The prepared card's own action is the only way a review opens, so the
// journeys click it rather than reaching for a surface directly.
async function openReview(page) {
  await page.locator('[id^="agent-review-prepared-"]').last().click();
  await expect(page.locator("#flex-policy-review")).toBeVisible();
  await expect(page.locator("#flex-policy-review-state")).toContainText(
    "Reviewing a prepared change",
  );
}

async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

// Resolves the seeded version by its exact name through the version panel, so
// the journey reads the fixture it names instead of the organization's default.
async function versionIdByName(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function openServicePage(page) {
  await logIn(page);
  const versionId = await versionIdByName(page, FLEX_VERSION);
  await page.goto(`/gtfs/${versionId}/flex`);
  await page.waitForSelector("#flex-services", { timeout: 15_000 });

  // The list's first row is Newport Dial-a-Ride (name order).
  await page.getByRole("link", { name: SERVICE_NAME, exact: true }).click();
  await waitForLiveView(page);
  await expect(page.locator("#svc-status")).toContainText("Ready");

  return versionId;
}

// The intake adds a full section, so no capture may show a horizontal
// scrollbar: the body must not be wider than its own client width.
async function capture(page, name) {
  mkdirSync(CAPTURE_DIR, { recursive: true });

  const overflows = await page.evaluate(
    () => document.body.scrollWidth > document.body.clientWidth + 1,
  );

  expect(overflows, `${name} must not scroll horizontally`).toBe(false);

  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: true,
  });
}

test.describe("the approved policy source intake", () => {
  for (const viewport of [DESKTOP, NARROW]) {
    test(`the intake and its empty state at ${viewport.width}x${viewport.height}`, async ({
      page,
    }) => {
      test.setTimeout(180_000);
      await page.setViewportSize(viewport);
      await routeBlankTiles(page);
      await openServicePage(page);

      // The intake sits beside the hours and booking sections and is its own
      // form: nothing in it is a field of the service draft.
      await expect(page.locator("#sec-when")).toBeVisible();
      await expect(page.locator("#sec-booking")).toBeVisible();
      await expect(page.locator("#sec-flex-policy-source")).toBeVisible();
      await expect(page.locator("#flex-policy-source-form")).toBeVisible();
      await expect(page.locator("#flex-policy-source-label")).toBeVisible();
      await expect(page.locator("#flex-policy-source-revision")).toBeVisible();
      await expect(page.locator("#flex-policy-source-text")).toBeVisible();
      await expect(page.locator("#flex-policy-accept")).toBeVisible();
      await expect(page.locator("#agent-helper-open")).toBeVisible();

      // The status region announces the empty state.
      await expect(page.locator("#flex-policy-source-state")).toContainText(
        "No policy source accepted yet.",
      );
      await expect(page.locator("#flex-policy-source-accepted")).toHaveCount(0);

      await capture(page, `step-004-source-empty-${viewport.width}`);
    });
  }

  test("an unaccepted source stays visible in the form and writes nothing", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await openServicePage(page);

    await page.fill("#flex-policy-source-label", "");
    await page.fill("#flex-policy-source-text", POLICY_TEXT);
    await page.locator("#flex-policy-accept").click();

    // The refusal is visible, the whole text is still here to fix, and the one
    // Save did not appear, because accepting a source is not a service change.
    await expect(page.locator("#flex-policy-source-refusal")).toBeVisible();
    await expect(page.locator("#flex-policy-source-text")).toHaveValue(
      POLICY_TEXT,
    );
    await expect(page.locator("#flex-policy-source-accepted")).toHaveCount(0);
    await expect(page.locator("#save-bar")).toHaveCount(0);

    await capture(page, "step-004-source-refused-1440");
  });

  test("an accepted source is announced and the page stays clean", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await openServicePage(page);

    await page.fill("#flex-policy-source-label", "Newport flex policy");
    await page.fill("#flex-policy-source-revision", "rev 3");
    await page.fill("#flex-policy-source-text", POLICY_TEXT);
    await page.locator("#flex-policy-accept").click();

    await expect(page.locator("#flex-policy-source-accepted")).toContainText(
      "Newport flex policy",
    );
    await expect(page.locator("#flex-policy-source-accepted")).toContainText(
      "Revision rev 3",
    );
    await expect(page.locator("#flex-policy-source-state")).toContainText(
      "Accepted Newport flex policy",
    );

    // Accepting froze a source; it did not write the service, so the page is
    // still clean and nothing was saved.
    await expect(page.locator("#flex-service-page")).toHaveAttribute(
      "data-dirty",
      "false",
    );
    await expect(page.locator("#save-bar")).toHaveCount(0);

    await capture(page, "step-004-source-accepted-1440");
  });
});

// The question the scripted stand-in answers with the complete hours
// replacement of the seeded service: both saved rows, with the weekday window
// moved to 08:00-17:00 and the Saturday window exactly as saved.
const SUPPORTED_QUESTION =
  "Set the weekday hours to 8 am to 5 pm from this policy.";
const DISCRETION_QUESTION = "Add same-day bookings when the dispatcher agrees.";
const OFFICE_QUESTION = "Book a business day ahead using the office calendar.";

// Captures one state at both viewports the tour names, so a reader compares the
// same surface at 320 px and 1440 px. Each capture refuses a horizontal
// scrollbar: an intake and a review that push the page sideways are a defect,
// not a narrow-screen variant.
async function captureBothViewports(page, name) {
  for (const viewport of [DESKTOP, NARROW]) {
    await page.setViewportSize(viewport);
    await expect(page.locator("#flex-service-page")).toBeVisible();
    await capture(page, `${name}-${viewport.width}`);
  }

  await page.setViewportSize(DESKTOP);
}

// The supported journey, end to end, at one viewport. The step-7 cases below
// reuse it at the other size rather than repeating the whole walk.
async function supportedJourney(page, viewport) {
  await page.setViewportSize(viewport);
  await routeBlankTiles(page);
  await openServicePage(page);

  await acceptSource(page);
  await openHelper(page);
  await askHelper(page, SUPPORTED_QUESTION);
  await openReview(page);

  // The review is the native comparison: both saved rows, the one the
  // proposal moved, the fields nothing touched, and the generated wording on
  // both sides.
  await expect(page.locator("#flex-policy-review-hours")).toContainText(
    "Row 1",
  );
  await expect(page.locator("#flex-policy-review-hours")).toContainText(
    "07:00 → 08:00",
  );
  await expect(page.locator("#flex-policy-review-hours")).toContainText(
    "1 row unchanged",
  );
  await expect(page.locator("#flex-policy-review-unchanged")).toContainText(
    "phone",
  );
  await expect(page.locator("#flex-policy-review-wording")).toContainText(
    "With this change",
  );

  await captureBothViewports(page, "step-007-supported-review");

  // Reviewing wrote nothing and staged nothing: the page is still clean, so
  // the one Save in this journey is the page's own.
  await expect(page.locator("#flex-service-page")).toHaveAttribute(
    "data-dirty",
    "false",
  );
  await expect(page.locator("#save-bar")).toHaveCount(0);
  await expect(page.locator("#flex-policy-staged")).toHaveCount(0);

  // A supported policy needs no overlap answer, because the draft is still the
  // saved page.
  await expect(page.locator("#flex-policy-overlap")).toHaveCount(0);

  await page.locator("#flex-policy-stage").click();

  // Staging put the reviewed rows in the page's own form and dirtied it, and
  // said plainly that nothing is saved yet.
  await expect(page.locator("#flex-policy-staged")).toBeVisible();
  await expect(page.locator("#flex-service-page")).toHaveAttribute(
    "data-dirty",
    "true",
  );
  await expect(page.locator("#save-bar")).toBeVisible();
  await expect(page.locator("#service_hours_0_start")).toHaveValue("08:00");
  await expect(page.locator("#service_hours_0_end")).toHaveValue("17:00");
  await expect(page.locator("#rider-preview")).toContainText(
    "Weekdays 8:00 am–5:00 pm",
  );

  await page.locator("#save-btn").click();

  // The page's own Save wrote it, the receipt is the native one, and the
  // assistant's state is spent with it.
  await expect(page.locator("#flash-group")).toContainText(
    "Saved Newport Dial-a-Ride.",
  );
  await expect(page.locator("#save-bar")).toHaveCount(0);
  await expect(page.locator("#flex-service-page")).toHaveAttribute(
    "data-dirty",
    "false",
  );
  await expect(page.locator("#flex-policy-staged")).toHaveCount(0);
  await expect(page.locator("#flex-policy-review")).toHaveCount(0);
  await expect(page.locator("#rider-preview")).toContainText(
    "Weekdays 8:00 am–5:00 pm",
  );
}

// The browser suite shares one seeded database, and `flex.spec.js` reads
// Newport Dial-a-Ride as seeded after this file (its service journey moves the
// 18:00 weekday close to 17:00). The first two assisted journeys save the page,
// so this puts back the weekday window, phone line and booking link they
// changed, through the page's own form and Save.
async function restoreSeededService(browser, baseURL) {
  const context = await browser.newContext({ baseURL });
  const page = await context.newPage();

  try {
    await openServicePage(page);

    // Nothing was saved when the weekday close is still the seeded 18:00.
    if ((await page.locator("#service_hours_0_end").inputValue()) === "18:00")
      return;

    await page.fill("#service_hours_0_start", "07:00");
    await page.fill("#service_hours_0_end", "18:00");
    await page.fill("#service_phone", "(541) 555-0142");
    await page.fill(
      "#service_info_url",
      "https://northcoast.example/dial-a-ride",
    );
    await page.locator("#service_info_url").blur();
    await page.locator("#save-btn").click();
    await expect(page.locator("#flash-group")).toContainText(
      "Saved Newport Dial-a-Ride.",
    );
  } finally {
    await context.close();
  }
}

test.describe("the assisted journey", () => {
  test.afterAll(async ({ browser }, workerInfo) => {
    await restoreSeededService(browser, workerInfo.project.use.baseURL);
  });

  test("supported policy reviews, stages and saves through the page's own Save", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    await routeBlankTiles(page);
    await supportedJourney(page, DESKTOP);

    await captureBothViewports(page, "step-007-saved");
  });

  test("unsaved contact work survives the assisted save", async ({ page }) => {
    test.setTimeout(180_000);
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await openServicePage(page);

    // Work the helper never saw: a new phone line and a second booking link,
    // typed into the page's own form before the review opens.
    await page.fill("#service_phone", "(541) 555-0999");
    await page.fill(
      "#service_info_url",
      "https://northcoast.example/dial-a-ride-newport",
    );
    await page.locator("#service_phone").blur();
    await expect(page.locator("#flex-service-page")).toHaveAttribute(
      "data-dirty",
      "true",
    );

    await acceptSource(page);
    await openHelper(page);
    await askHelper(page, SUPPORTED_QUESTION);
    await openReview(page);

    // Staging merged the reviewed hours into the whole draft: the assistant
    // replaced the array it targeted and nothing else (AC-9).
    await page.locator("#flex-policy-stage").click();
    await expect(page.locator("#flex-policy-staged")).toBeVisible();
    await expect(page.locator("#service_hours_0_start")).toHaveValue("08:00");
    await expect(page.locator("#service_phone")).toHaveValue("(541) 555-0999");
    await expect(page.locator("#service_info_url")).toHaveValue(
      "https://northcoast.example/dial-a-ride-newport",
    );

    await page.locator("#save-btn").click();

    // The native save wrote the whole page, the contact work included.
    await expect(page.locator("#flash-group")).toContainText(
      "Saved Newport Dial-a-Ride.",
    );
    await expect(page.locator("#service_phone")).toHaveValue("(541) 555-0999");
    await expect(page.locator("#service_info_url")).toHaveValue(
      "https://northcoast.example/dial-a-ride-newport",
    );
    await expect(page.locator("#rider-preview")).toContainText(
      "(541) 555-0999",
    );
  });

  test("an overlap asks before it stages and the answer is the editor's", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await openServicePage(page);

    // The editor moves the same weekday window the proposal targets, so the
    // two disagree and the page must ask rather than choose (AC-9).
    await page.fill("#service_hours_0_end", "16:00");
    await page.locator("#service_hours_0_end").blur();
    await expect(page.locator("#flex-service-page")).toHaveAttribute(
      "data-dirty",
      "true",
    );

    await acceptSource(page);
    await openHelper(page);
    await askHelper(page, SUPPORTED_QUESTION);
    await openReview(page);

    // Both answers are visible and actionable, and nothing is chosen yet.
    await expect(page.locator("#flex-policy-overlap")).toBeVisible();
    await expect(page.locator("#flex-policy-review-state")).toContainText(
      "1 overlapping field needs your answer",
    );
    await expect(
      page.locator("#flex-policy-overlap-hours-draft"),
    ).toBeVisible();
    await expect(
      page.locator("#flex-policy-overlap-hours-proposal"),
    ).toBeVisible();

    await captureBothViewports(page, "step-007-overlap");

    // Staging is refused while the question is open.
    await page.locator("#flex-policy-stage").click();
    await expect(page.locator("#flex-policy-review-notice")).toContainText(
      "Choose what to keep",
    );
    await expect(page.locator("#flex-policy-staged")).toHaveCount(0);

    // The editor answers with the proposal, and the proposal's window is what
    // reaches the draft.
    await page.locator("#flex-policy-overlap-hours-proposal").click();
    await expect(
      page.locator("#flex-policy-overlap-hours-proposal"),
    ).toBeChecked();

    await page.locator("#flex-policy-stage").click();
    await expect(page.locator("#flex-policy-staged")).toBeVisible();
    await expect(page.locator("#service_hours_0_end")).toHaveValue("17:00");

    // The comparison is gone and the section now reads as the staged draft, so
    // there is no second "Use these changes" to press.
    await expect(page.locator("#flex-policy-review-state")).toContainText(
      "Staged into this page",
    );
    await expect(page.locator("#flex-policy-stage")).toHaveCount(0);
    await expect(page.locator("#flex-policy-overlap")).toHaveCount(0);
  });

  test("an unsupported same-day ask is refused and nothing is staged", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await openServicePage(page);

    await acceptSource(page);
    await openHelper(page);
    await page.locator("#agent-composer-input").fill(DISCRETION_QUESTION);
    await page.locator("#agent-send").click();

    // Operational discretion is not a native rule, so the preparation refuses
    // and the panel carries the assistant's own reason.
    await expect(page.locator("#agent-entries")).toContainText(
      "This policy cannot be represented here",
      { timeout: 60_000 },
    );
    await expect(page.locator("#agent-entries")).toContainText(
      "same-day bookings when the dispatcher agrees",
    );

    // No candidate was prepared, so no review could open and the page's own
    // fields never moved.
    await expect(page.locator('[id^="agent-prepared-"]')).toHaveCount(0);
    await expect(page.locator("#flex-policy-review")).toHaveCount(0);
    await expect(page.locator("#flex-service-page")).toHaveAttribute(
      "data-dirty",
      "false",
    );
    await expect(page.locator("#save-bar")).toHaveCount(0);
    await expect(page.locator("#flex-policy-source-accepted")).toBeVisible();

    await captureBothViewports(page, "step-007-refused-same-day");
  });

  test("a booking rule on a missing office calendar is refused", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await openServicePage(page);

    await acceptSource(page);
    await openHelper(page);
    await page.locator("#agent-composer-input").fill(OFFICE_QUESTION);
    await page.locator("#agent-send").click();

    // A weekday calendar is not an office calendar, and a rule naming one the
    // version does not hold is refused rather than resolved to a substitute.
    await expect(page.locator("#agent-entries")).toContainText(
      "is not a calendar in office_service_id",
      { timeout: 60_000 },
    );
    await expect(page.locator('[id^="agent-prepared-"]')).toHaveCount(0);
    await expect(page.locator("#flex-policy-review")).toHaveCount(0);
    await expect(page.locator("#save-bar")).toHaveCount(0);
  });

  test("an oversized source is refused with the whole text kept", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await openServicePage(page);

    // The cap is the whole context's, so the text only has to be longer than
    // the intake admits; the refusal keeps every byte of it.
    const oversized =
      "Newport Dial-a-Ride runs weekdays 7:00 am to 6:00 pm. ".repeat(2200);
    await page.fill("#flex-policy-source-label", "Newport flex policy");
    await page.fill("#flex-policy-source-text", oversized);
    await page.locator("#flex-policy-accept").click();

    await expect(page.locator("#flex-policy-source-refusal")).toContainText(
      "does not fit in one helper answer of 65,536 bytes",
    );
    await expect(page.locator("#flex-policy-source-accepted")).toHaveCount(0);
    await expect(page.locator("#flex-policy-source-text")).toHaveValue(
      oversized,
    );
    await expect(page.locator("#save-bar")).toHaveCount(0);

    await captureBothViewports(page, "step-007-source-overflow");
  });
});
