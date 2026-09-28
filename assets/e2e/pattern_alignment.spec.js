import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Alignment task shell (spec 12, step 20 and later visual steps).
 *
 * Step 20 owns the `test.describe("alignment shell")` block: it opens
 * BROWSER-ALIGN-A's Alignment task and captures it at 1440×1000 and 320×900
 * against the Missing-section reference. Later visual steps add their own
 * describe blocks; step 30 adds the end-to-end journeys. Every mutating
 * journey uses its own `-B` pattern copy so viewports never share modified
 * records.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const ALIGN_ROUTE = "BROWSER_ALIGN";
const ALIGN_PATTERN = "BROWSER-ALIGN-A";

const CAPTURE_DIR = process.env.PATTERN_ALIGNMENT_CAPTURE_DIR;

// A verified-transparent 1×1 PNG served for every tile request, so captures
// never depend on the network or on Geoapify credits. (An earlier literal
// for this stub decoded to a half-green pixel and tinted the whole map.)
const BLANK_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=",
  "base64",
);

async function captureViewport(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`) });
}

async function captureFullPage(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: true,
    animations: "disabled",
  });
}

// An already authenticated session is redirected away from the login page, so
// the form is only filled when it is actually rendered.
async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

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

function collectPageErrors(page) {
  const problems = [];
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  return problems;
}

// Waits for the LiveView root to report itself connected, so an interaction is
// never clicked into a server-rendered page that has not been hydrated yet.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });

  await page.waitForFunction(
    () => {
      const main = document.querySelector("[data-phx-main]");
      return (
        Boolean(main) &&
        main.classList.contains("phx-connected") &&
        window.liveSocket?.isConnected()
      );
    },
    { timeout: 20000 },
  );
}

async function stubTiles(page) {
  await page.route("**/map/tiles/**", async (route) => {
    await route.fulfill({ contentType: "image/png", body: BLANK_PNG });
  });
}

test.describe("alignment shell", () => {
  test("renders the Alignment task at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(page.locator("#alignment-title")).toHaveText("Alignment");
    await expect(page.locator("#alignment-status")).toContainText("1 missing");
    await expect(page.locator("#alignment-section-2")).toBeVisible();
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "shell-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(page.locator("#alignment-title")).toHaveText("Alignment");
    await expect(page.locator("#alignment-section-2")).toBeVisible();
    await captureFullPage(page, "shell-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

test.describe("alignment map", () => {
  test("shows section lines on the Leaflet map at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    // Two saved sections plus the missing dashed connector, and one pin
    // per stop visit run.
    await expect(
      page.locator("#alignment-map-root .pa-stop-pin").first(),
    ).toBeVisible({ timeout: 15000 });
    await expect(page.locator("#alignment-map-root")).toContainText(
      "Hide stop labels",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "map-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    await captureFullPage(page, "map-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });

  test("shows the tile-failure notice when tiles return 500", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await page.route("**/map/tiles/**", async (route) => {
      await route.fulfill({ status: 500, body: "tile boom" });
    });
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(page.locator("#alignment-notice")).toContainText(
      "The background map couldn't load",
      { timeout: 20000 },
    );
    await expect(page.locator("#alignment-notice")).toContainText(
      "Your alignment and stop list are still available.",
    );
    // The sections stay usable behind the notice.
    await expect(page.locator("#alignment-section-2")).toBeVisible();
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "map-error-1440");

    // The refused tiles surface exactly one console resource error; nothing
    // else may fail.
    expect(problems.some((p) => p.includes("500"))).toBe(true);
    expect(problems.filter((p) => !p.includes("500"))).toEqual([]);
  });
});
