// Stops Map browser journeys (28-stop-add-edit, step 22 onward; EV-23..EV-38).
//
// Every state this file measures is the committed browser seed
// (`test/support/browser_seed.exs`, user 8) rendered through the real routes:
//
//   stops-map@gtfs-planner.test   # Stops Map Org → "Browser Stops Map Version"
//
// The version is resolved by name through the version panel, so a journey reads
// the stops-map fixture instead of whichever version the organization opens by
// default.
//
// The `@seed` case is the gate for the seed itself: it signs in, opens the
// Stops & stations list and proves the seeded stops are there with the names and
// types the later steps' fixtures name. It depends only on routes that already
// exist, so a failure here is a seed failure and not a Map view failure.
//
// Captures are written only when `STOPS_MAP_CAPTURE_DIR` is set, resolved
// against the assets working directory. They are the visual-loop and QA-tour
// inputs, not the gate's oracle.
import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

const EDITOR = {
  email: "stops-map@gtfs-planner.test",
  password: "StopsMapBrowser1",
};

const VERSION_NAME = "Browser Stops Map Version";

const DESKTOP = { width: 1440, height: 900, label: "desktop" };
const MOBILE = { width: 390, height: 844, label: "mobile" };

const CAPTURE_DIR = process.env.STOPS_MAP_CAPTURE_DIR;

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

async function versionIdByName(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function capture(page, testInfo, name, { fullPage = true } = {}) {
  if (!CAPTURE_DIR) return testInfo.outputPath(`${name}.png`);

  mkdirSync(CAPTURE_DIR, { recursive: true });
  const path = resolve(CAPTURE_DIR, `${name}.png`);
  await page.screenshot({ path, fullPage });
  return path;
}

// ── seed ──────────────────────────────────────────────────────────────────

// The seed gate. The stop names, the duplicate pair and the station are the
// fixture the Map view steps build on, so they are asserted here as literals
// rather than read back from the surface's own counts.
test("the seeded stops map organization @seed", async ({ page }, testInfo) => {
  await page.setViewportSize(DESKTOP);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSION_NAME);
  await page.goto(`/gtfs/${versionId}/stops`);
  await waitForLiveView(page);

  await expect(page.locator("#stops-page")).toBeAttached();
  await expect(page.locator("h1")).toHaveText("Stops & stations");

  // The stop the journey edits, the possible duplicate beside it, the unserved
  // stop and the station. Literal names, so a renamed fixture fails here.
  for (const name of [
    "US 101 & SE 1st St",
    "SE Bay Blvd & SE Moore Dr",
    "Newport Transit Center",
  ]) {
    await expect(page.locator("#stops-workbench").getByText(name, { exact: false }).first()).toBeAttached();
  }

  // The list is paginated; the two SE 1st St rows are the duplicate pair, so
  // both IDs are on the first page only if the seed really wrote both.
  await expect(page.getByText("1434", { exact: true }).first()).toBeAttached();
  await expect(page.getByText("1433", { exact: true }).first()).toBeAttached();

  await capture(page, testInfo, "seed-stops-list");
});
