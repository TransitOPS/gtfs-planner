import { test, expect } from "@playwright/test";

/**
 * Fare helper journeys: the Fare zones helper on /settings/fares/zones and the
 * prices helper on the managed Prices tab of /settings/fares.
 *
 * The fixture is the "Browser Fare Assistance Version" seeded by
 * `test/support/browser_seed.exs`: the managed North Coast sample with the zone of
 * DEPOE, AGATE and NTC cleared, so "the unzoned Route 1 stops" selects exactly
 * those three. Route 1 (Coast Highway) also serves LCTC, which is in zone CST.
 * DEPOE is shared with route 6, AGATE with route 11 and NTC with routes 2, 3, 4,
 * 10, 11 and 30. The version is managed with Local ride adult cash at USD 1.50
 * and reduced cash at USD 0.75. CORVALLIS is in no zone in the feed either, so
 * the Zones page counts 4 stops with no zone.
 *
 * Only the OpenRouter HTTP boundary is scripted
 * (`test/support/agents/browser_open_router.ex`); the pages, the panel, the
 * session, the packs and the domain reads and writes are the shipped ones.
 */

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const ASSISTANCE_VERSION = "Browser Fare Assistance Version";

// A 1×1 transparent PNG. The zone workspace's map requests tiles, and answering
// them locally keeps a journey from depending on the Geoapify plan or on network
// access — the same stub `fare_zones.spec.js` installs.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

async function logIn(page) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.waitForSelector("[data-phx-main].phx-connected");
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

// Resolves a seeded version by its exact name through the version panel, so a
// journey reads the fixture it names instead of whichever version is the default.
async function versionIdByName(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function openZones(page) {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, ASSISTANCE_VERSION);
  await page.goto(`/gtfs/${versionId}/settings/fares/zones`);
  await waitForLiveView(page);
  await expect(page.locator("#fare-zones-panel")).toBeAttached();

  return versionId;
}

async function openPrices(page) {
  await logIn(page);

  const versionId = await versionIdByName(page, ASSISTANCE_VERSION);
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  return versionId;
}

test.describe("seed", () => {
  test("the fixture version is managed, with three unzoned Route 1 stops", async ({ page }) => {
    await openZones(page);

    // DEPOE, AGATE and NTC plus CORVALLIS, which the feed never zoned.
    await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("4");

    for (const name of ["Newport local", "Toledo and valley", "Coast zone"]) {
      await expect(page.locator("#fare-zones-panel")).toContainText(name);
    }

    await openPrices(page);

    // The managed grid has no setup or conversion prompt.
    await expect(page.locator("#setup-adult")).toHaveCount(0);
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");
  });
});
