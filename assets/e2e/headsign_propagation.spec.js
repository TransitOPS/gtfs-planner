import { test, expect } from "@playwright/test";
import { logInAs } from "./browser_helpers";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Headsign propagation journeys (spec 20).
 *
 * Every journey owns one BROWSER-HS* pattern from `test/support/browser_seed.exs`,
 * so a mutating journey never inherits another's writes: the Details usage line
 * and the read-only review-drawer render read BROWSER-HS1, the inline edit, save
 * and undo drives BROWSER-HS2, the review drawer fixes a typo on BROWSER-HS3,
 * the timing disclosure BROWSER-HS4, and the schedules surface BROWSER-HS5. The
 * continuation trips live on the BROWSER_HEADSIGNS_20 route and share each
 * pattern's block id.
 *
 * The details journey here runs against the wired Details task. Until step 11
 * wires the components into the page, the recorded smoke for this spec is the
 * component render test; the selectors below are the final ones.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const CAPTURE_DIR = process.env.HEADSIGN_CAPTURE_DIR;

async function capture(page, name) {
  if (!CAPTURE_DIR) return;

  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`), fullPage: true });
}

// Waits for the LiveView root to report itself connected, so an interaction is
// never clicked into a server-rendered page that has not been hydrated yet.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });

  await page.waitForFunction(
    () => {
      const main = document.querySelector("[data-phx-main]");
      return Boolean(main) && main.classList.contains("phx-connected") && window.liveSocket?.isConnected();
    },
    { timeout: 20000 },
  );
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

async function openPattern(page, versionId, routeId, patternId, task) {
  await page.goto(`/gtfs/${versionId}/routes/${routeId}/patterns/${patternId}?task=${task}`);
  await page.waitForSelector("#pattern-editor-content", { timeout: 15000 });
  await waitForLiveView(page);
}

let versionId;

test.beforeEach(async ({ page }) => {
  await logInAs(page, EDITOR_USER);
  versionId = await getVersionId(page);
});

test("usage line on details", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "details");

  const usage = page.locator("#headsign-usage");
  await expect(usage).toContainText("Used by 5 trips");
  await expect(usage).toContainText("2 show a different headsign");
  await expect(usage.getByText("1 likely typo")).toBeVisible();
  await expect(page.locator("#headsign-usage-review")).toContainText("Review 2 trips");

  await capture(page, "details-hs1-usage-1440");
});

// Read-only render journey: the drawer opens from the usage line's Review link
// and shows the seeded typo and interline groups. Opening is a step-12 event,
// so until `open_headsign_review` is wired this records the pre-wiring
// failure, like the details journey above.
test("review drawer renders", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "details");

  await page.locator("#headsign-usage-review").click();

  const drawer = page.locator("#headsign-review-drawer");
  await expect(drawer).toBeVisible();
  await expect(drawer).toContainText("Trips with a different headsign");
  await expect(drawer).toContainText("Lincoln city");
  await expect(drawer).toContainText("Likely typo");
  await expect(drawer).toContainText("Roads End via Lincoln City");
  await expect(drawer).toContainText("Next in block: Route H20 at 10:15 toward Roads End");
  await expect(drawer).toContainText("Change trips");

  await capture(page, "review-hs1-drawer-1440");
});
