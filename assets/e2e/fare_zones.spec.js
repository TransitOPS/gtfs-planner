// Fare zones workspace browser journey.
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`. The seeded "Browser Fare Zones Version" is resolved by
// name through the version panel, so the journey reads the fare-zone fixture the
// later steps assert against instead of whichever version is the organization's
// default.
//
// Step 14 owns the `shell` case; the following UI steps add one capture case
// each to this file.
import { test, expect } from "@playwright/test";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// The Playwright runner starts in `assets/`, so repository-relative inputs are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Fare Zones Version";

const DESKTOP = { width: 1440, height: 1000 };

// A 1×1 transparent PNG. Every tile request is answered locally so the workspace
// never depends on the Geoapify plan or on network access.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

const TAB_PATH = {
  zones: "",
  rules: "/rules",
  checks: "/checks",
};

// The reference prototype lives in the gitignored .specs/ workspace, so the
// reference captures are skipped when the file is not present rather than
// depending on a path that is not checked in.
const REFERENCE_PATH = resolve(
  REPO_ROOT,
  ".specs",
  "21-fare-zones",
  "references",
  "fare-zones-prototype.html",
);

const CAPTURE_DIR = process.env.FARE_ZONES_CAPTURE_DIR;

// ── shared helpers ────────────────────────────────────────────────────────

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
      main && !main.hasAttribute("data-phx-pending") && window.liveSocket?.isConnected(),
    );
  });
}

async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

async function faresVersionId(page) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: VERSION_NAME });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${VERSION_NAME} is missing its version ID`);
  return versionId;
}

// Opens the workspace on the named tab and returns the version ID it selected.
async function openFares(page, tab = "zones") {
  await logIn(page);

  const versionId = await faresVersionId(page);
  await page.goto(`/gtfs/${versionId}/settings/fares${TAB_PATH[tab]}`);
  await waitForLiveView(page);
  await expect(page.locator(`#fare-${tab}-panel`)).toBeAttached();

  return versionId;
}

// Switching tabs patches the same LiveView, so a click that lands before the
// mounted view is dropped; retrying the click is the stable gate.
async function openTab(page, tab) {
  await expect(async () => {
    await page.locator(`#fares-tab-${tab}`).click();
    await expect(page.locator(`#fare-${tab}-panel`)).toBeAttached({ timeout: 2000 });
  }).toPass({ timeout: 15000 });

  await expect(page.locator(`#fares-tab-${tab}`)).toHaveAttribute("aria-current", "page");
}

async function capture(page, testInfo, name, { fullPage = true } = {}) {
  let path = testInfo.outputPath(`${name}.png`);

  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    path = resolve(CAPTURE_DIR, `${name}.png`);
  }

  await page.screenshot({ path, fullPage });
}

// Captures the prototype at the same viewport so the shell can be compared with
// the reference state it follows. The file is absent in a checkout without the
// gitignored .specs/ workspace, so the capture is skipped there.
async function captureReference(page, testInfo, query, name) {
  if (!existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}${query}`);
  await page.waitForLoadState("networkidle");
  await capture(page, testInfo, name, { fullPage: false });
}

// ── shell ─────────────────────────────────────────────────────────────────

test("shell", async ({ page }, testInfo) => {
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);
  await openFares(page, "zones");

  await expect(page.locator("h1")).toHaveText("Fare zones");
  await expect(page.locator("#settings-tab-fares")).toHaveAttribute("aria-current", "page");

  for (const tab of ["zones", "rules", "checks"]) {
    if (tab !== "zones") await openTab(page, tab);

    await expect(page.locator(`#fares-tab-${tab}`)).toHaveAttribute("aria-current", "page");
    await expect(page.locator(`#fare-${tab}-panel`)).toBeAttached();

    await capture(page, testInfo, `shell-${tab}`);
  }

  await captureReference(page, testInfo, "?tab=rules", "ref-rules");
  await captureReference(page, testInfo, "?tab=checks", "ref-checks");
});
