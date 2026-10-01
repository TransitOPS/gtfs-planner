// The approved policy source intake and the Flex policy helper on the service
// page, for feature `ai-09-flex-assistance`.
//
// Step 4 owns this shell only: login, version selection, the seeded
// Newport Dial-a-Ride service page, the source intake's own states and the
// captures step 4's subspec names. The supported review, the overlap report,
// the staged application and the applied result belong to steps 5 to 7 and are
// added to this file as those steps land; nothing here asserts a review surface
// that does not exist yet.
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
  password: "[redacted]",
};

const FLEX_VERSION = "Browser Flex Version";
const SERVICE_NAME = "Newport Dial-a-Ride";

const POLICY_TEXT =
  "Newport Dial-a-Ride runs weekdays 7:00 am to 6:00 pm. " +
  "Riders must call at least 30 minutes ahead. " +
  "The office is closed on federal holidays.";

const DESKTOP = { width: 1440, height: 1000 };
const NARROW = { width: 390, height: 844 };

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
