import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { bodyFitsViewport } from "./browser_helpers.js";

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
const ZONES_VERSION = "Browser Fare Zones Version";

const VIEWPORTS = [
  { label: "1440", width: 1440, height: 1000 },
  { label: "320", width: 320, height: 800 },
];

// Set FARE_ASSISTANCE_CAPTURE_DIR to keep the captures beside the spec package;
// otherwise they stay in Playwright's own output directory.
const CAPTURE_DIR = process.env.FARE_ASSISTANCE_CAPTURE_DIR;

const ZONES_REQUEST =
  "Put unzoned Route 1 stops in the Coast zone except Newport Transit Center";

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

async function openZones(page, versionName = ASSISTANCE_VERSION) {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, versionName);
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

async function ask(page, message) {
  await page.locator("#agent-composer-input").fill(message);
  await page.locator("#agent-send").click();
}

// Opens the panel on a fresh conversation, asks the scripted helper for the
// Route 1 assignment and waits for its prepared card.
async function prepareZoneAssignment(page) {
  await page.locator("#agent-helper-open").click();
  await expect(page.locator("#agent-panel")).toBeVisible();
  await page.locator("#agent-new-conversation").click();
  await ask(page, ZONES_REQUEST);

  const card = page.locator("#agent-prepared-2");
  await expect(card).toBeVisible({ timeout: 15_000 });
  await expect(card).toContainText("Assign 2 stops to Coast zone");
  return card;
}

async function focusInside(page, selector) {
  return page.evaluate(
    (sel) => document.querySelector(sel)?.contains(document.activeElement) ?? false,
    selector,
  );
}

async function capture(page, testInfo, name, { fullPage = true } = {}) {
  let path = testInfo.outputPath(`${name}.png`);

  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    path = resolve(CAPTURE_DIR, `${name}.png`);
  }

  // The selection bar is sticky to the viewport's bottom; from the top of the
  // page a full-page capture shows it where a reader sees it.
  if (fullPage) await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path, fullPage });
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

test.describe("zones helper panel", () => {
  for (const viewport of VIEWPORTS) {
    test(`opens beside the stage at ${viewport.label}`, async ({ page }, testInfo) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await openZones(page, ZONES_VERSION);

      // The page's own controls work before the panel opens.
      await expect(page.locator("#fare-zone-create")).toBeVisible();
      await page.locator("#agent-helper-open").click();

      const panel = page.locator("#agent-panel");
      await expect(panel).toBeVisible();
      await expect(page.locator("#agent-composer-input")).toBeFocused();
      await expect(page.locator("#agent-helper-open")).toHaveAttribute("aria-expanded", "true");

      const stage = await page.locator("#fare-zones-panel").boundingBox();
      const box = await panel.boundingBox();

      if (viewport.width >= 1024) {
        // A 24rem column to the right of the workspace, which keeps its own width.
        expect(Math.round(box.width)).toBe(384);
        expect(box.x).toBeGreaterThanOrEqual(stage.x + stage.width);
        expect(stage.width).toBeGreaterThan(600);
      } else {
        // Stacked above the workspace the Open helper button belongs to.
        expect(box.y + box.height).toBeLessThanOrEqual(stage.y + 1);
      }

      expect(await bodyFitsViewport(page)).toBe(true);

      // The workspace is still usable with the panel open.
      await page.locator("#fare-zone-row-unassigned").click();
      await expect(page).toHaveURL(/[?&]filter=unassigned$/);

      await capture(page, testInfo, `zones-panel-${viewport.label}`);

      await page.locator("#agent-panel-close").click();
      await expect(panel).toHaveCount(0);
      await expect(page.locator("#agent-helper-open")).toBeFocused();
    });
  }
});

test.describe("zones review", () => {
  for (const viewport of VIEWPORTS) {
    test(`shows the prepared selection in the review at ${viewport.label}`, async ({
      page,
    }, testInfo) => {
      test.setTimeout(90_000);

      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await openZones(page);
      const card = await prepareZoneAssignment(page);

      // Nothing is saved by preparing: the page still counts four stops with no zone.
      await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("4");

      await page.locator("#agent-review-prepared-2").click();

      const dialog = page.locator("#fare-zone-assignment-dialog");
      await expect(dialog).toBeVisible();
      expect(await focusInside(page, "#fare-zone-assignment-dialog")).toBe(true);

      // The selection is the route's unzoned stops minus the exclusion, by name.
      await expect(page.locator("#fare-zone-assignment-row-1")).toContainText("Agate Beach");
      await expect(page.locator("#fare-zone-assignment-row-2")).toContainText("Depoe Bay");
      await expect(page.locator("#fare-zone-assignment-row-3")).toHaveCount(0);
      await expect(page.locator("#fare-zone-assignment-row-1-routes")).toHaveText("11");
      await expect(page.locator("#fare-zone-assignment-row-2-routes")).toHaveText("6");

      const helper = page.locator("#fare-zone-assignment-helper");
      await expect(helper).toContainText("Stops with no zone only");
      await expect(helper).toContainText("Excluded: Newport Transit Center (NTC)");
      await expect(helper).toContainText("Also served by");
      await expect(page.locator("#fare-zone-assignment-refresh")).toHaveCount(0);
      await expect(page.locator("#fare-zone-assignment-dialog-confirm")).toBeEnabled();

      expect(await bodyFitsViewport(page)).toBe(true);

      // A modal sits in the viewport, so its captures are viewport captures; the
      // rows list scrolls inside the dialog rather than the page.
      await capture(page, testInfo, `zones-review-${viewport.label}`, { fullPage: false });

      await page.locator("#fare-zone-assignment-row-2").scrollIntoViewIfNeeded();
      await expect(page.locator("#fare-zone-assignment-row-2")).toBeInViewport();
      await capture(page, testInfo, `zones-review-${viewport.label}-rows`, { fullPage: false });

      // Closing returns focus to the prepared card and saves nothing.
      await page.locator("#fare-zone-assignment-dialog-cancel").click();
      await expect(dialog).toHaveCount(0);
      await expect(card).toBeFocused();
      await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("4");
    });
  }
});

test.describe("zones journey", () => {
  for (const viewport of VIEWPORTS) {
    test(`asks, reviews, saves and undoes at ${viewport.label}`, async ({ page }, testInfo) => {
      test.setTimeout(120_000);

      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await openZones(page);
      const card = await prepareZoneAssignment(page);

      // The prepared card names what it will do and nothing is saved yet.
      await expect(card).toContainText("Stops with no zone only");
      await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("4");

      // Keyboard: Enter on the card's Review button opens the review, focus is
      // inside it, and Escape closes it back onto the card.
      await page.locator("#agent-review-prepared-2").focus();
      await page.keyboard.press("Enter");

      const dialog = page.locator("#fare-zone-assignment-dialog");
      await expect(dialog).toBeVisible();
      expect(await focusInside(page, "#fare-zone-assignment-dialog")).toBe(true);
      await page.keyboard.press("Escape");
      await expect(dialog).toHaveCount(0);
      await expect(card).toBeFocused();
      await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("4");

      // The review again, then the confirmed save.
      await page.locator("#agent-review-prepared-2").click();
      await expect(dialog).toBeVisible();
      await expect(page.locator("#fare-zone-assignment-row-2")).toContainText("Depoe Bay");
      await expect(page.locator("#fare-zone-assignment-helper")).toContainText(
        "This version's areas and stop areas export from these zones.",
      );

      await page.locator("#fare-zone-assignment-dialog-confirm").click();
      await expect(dialog).toHaveCount(0);

      const saved = page.locator("#fare-zone-saved");
      await expect(saved).toContainText("2 stops assigned to Coast zone.");
      await expect(page.locator("#fare-zone-undo")).toBeVisible();
      await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("2");

      // Saved, the prepared card has nothing left to review.
      await expect(page.locator("#agent-review-prepared-2")).toHaveCount(0);
      expect(await bodyFitsViewport(page)).toBe(true);
      await capture(page, testInfo, `zones-saved-${viewport.label}`);

      // Undo is the native writer's own, and it restores the seed state.
      await page.locator("#fare-zone-undo").click();
      await expect(saved).toContainText("Change undone.");
      await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("4");
    });

    test(`asks which stop when a name is ambiguous at ${viewport.label}`, async ({
      page,
    }, testInfo) => {
      test.setTimeout(90_000);

      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await openZones(page);

      await page.locator("#agent-helper-open").click();
      await expect(page.locator("#agent-panel")).toBeVisible();
      await page.locator("#agent-new-conversation").click();
      await ask(page, "Which zone is Beach in?");

      await expect(page.locator("#agent-entries")).toContainText(
        "Three stops match Beach: Agate Beach, Nye Beach and South Beach Park & Ride. Which one do you mean?",
        { timeout: 15_000 },
      );

      // A question is not a proposal: no prepared card, no review, nothing saved.
      await expect(page.locator('[id^="agent-prepared-"]')).toHaveCount(0);
      await expect(page.locator("#fare-zone-assignment-dialog")).toHaveCount(0);
      await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("4");

      await capture(page, testInfo, `zones-candidates-${viewport.label}`);
    });
  }
});
