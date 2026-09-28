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
import { bodyFitsViewport } from "./browser_helpers.js";

// The Playwright runner starts in `assets/`, so repository-relative inputs are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Fare Zones Version";

const DESKTOP = { width: 1440, height: 1000, label: "desktop" };
const NARROW = { width: 320, height: 800, label: "narrow" };

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

// ── settings entry ────────────────────────────────────────────────────────

// Ordinary entry through Settings: the overview lists Fares as an Available
// page linking to the workspace, and that entry opens it. Fares stopped being a
// Coming soon destination in step 15, so the placeholder body must be gone.
test("settings entry", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await faresVersionId(page);

  for (const viewport of [DESKTOP, NARROW]) {
    await page.setViewportSize(viewport);
    await page.goto(`/gtfs/${versionId}/settings`);
    await waitForLiveView(page);

    const entry = page.locator("#settings-entry-fares");
    const entryLink = entry.locator("a");

    await expect(entryLink).toHaveText("Fares");
    await expect(entryLink).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/settings/fares`,
    );
    await expect(entry).toContainText("Available");
    await expect(entry).not.toContainText("Coming soon");
    await expect(entry.locator("#coming-soon-status")).toHaveCount(0);
    await expect(entryLink).toBeVisible();

    await entryLink.focus();
    await expect(entryLink).toBeFocused();
    await capture(page, testInfo, `settings-entry-${viewport.label}-focus`, {
      fullPage: false,
    });

    await entryLink.click();
    await page.waitForURL(new RegExp(`/gtfs/${versionId}/settings/fares$`));
    await waitForLiveView(page);

    await expect(page.locator("h1")).toHaveText("Fare zones");
    await expect(page.locator("#fare-zones-panel")).toBeAttached();
    await expect(page.locator("#coming-soon")).toHaveCount(0);
    await expect(page.locator("#settings-tab-fares")).toHaveAttribute(
      "aria-current",
      "page",
    );

    await capture(page, testInfo, `settings-entry-${viewport.label}`);
  }
});

// ── zones inventory ───────────────────────────────────────────────────────

// The Zones tab's inventory is the page's navigation: All stops, one row per
// zone in the version, and Unassigned, each a patch link carrying its own
// filter. The seeded "Browser Fare Zones Version" carries Central (11 boardable
// stops), Eastbank (12), a fare-rule-referenced C with no stops and no record,
// the declared-but-empty Airport, and 4 unassigned stops of 27.
test("zones inventory", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  const versionId = await openFares(page, "zones");

  const inventory = page.locator("#fare-zone-inventory");

  await expect(inventory).toBeVisible();
  await expect(page.locator("#fare-zone-inventory-count")).toHaveText("4");
  await expect(inventory).toContainText("Each stop belongs to one zone.");
  await expect(inventory).toContainText(
    "Zone names help your team. Zone IDs travel with your GTFS feed.",
  );

  const allStops = page.locator("#fare-zone-row-all");

  await expect(allStops).toContainText("All stops");
  await expect(allStops).toContainText("Every zone");
  await expect(page.locator("#fare-zone-row-all-count")).toHaveText("27");
  await expect(allStops).toHaveAttribute("href", `/gtfs/${versionId}/settings/fares`);
  await expect(allStops).toHaveAttribute("aria-current", "page");
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("All stops");
  await expect(page.locator("#fare-zone-stage-subtitle")).toHaveText(
    "27 stops in this version",
  );

  const zones = [
    { index: 1, id: "A", name: "Central", count: "11", subtext: "ID A" },
    { index: 2, id: "B", name: "Eastbank", count: "12", subtext: "ID B" },
    { index: 3, id: "C", name: "C", count: "0", subtext: "ID C · Empty zone" },
    { index: 4, id: "D", name: "Airport", count: "0", subtext: "ID D · Empty zone" },
  ];

  for (const zone of zones) {
    const row = page.locator(`#fare-zone-row-${zone.index}`);

    await expect(row).toContainText(zone.name);
    await expect(row).toContainText(zone.subtext);
    await expect(page.locator(`#fare-zone-row-${zone.index}-count`)).toHaveText(zone.count);
    await expect(row).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/settings/fares?zone=${zone.id}`,
    );
    await expect(row).not.toHaveAttribute("aria-current", "page");
  }

  const unassigned = page.locator("#fare-zone-row-unassigned");

  await expect(unassigned).toContainText("Unassigned");
  await expect(unassigned).toContainText("Needs assignment");
  await expect(page.locator("#fare-zone-row-unassigned-count")).toHaveText("4");
  await expect(unassigned).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings/fares?filter=unassigned`,
  );

  // Selecting a zone keeps the filter in the URL and renames the stage.
  await page.locator("#fare-zone-row-2").click();

  await expect(page).toHaveURL(new RegExp(`zone=B$`));
  await expect(page.locator("#fare-zone-row-2")).toHaveAttribute("aria-current", "page");
  await expect(page.locator("#fare-zone-row-2")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings/fares?zone=B`,
  );
  await expect(allStops).not.toHaveAttribute("aria-current", "page");
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Eastbank");
  await expect(page.locator("#fare-zone-stage-subtitle")).toHaveText("12 stops · Zone ID B");

  for (const viewport of [DESKTOP, NARROW]) {
    await page.setViewportSize(viewport);
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);

    await expect(page.locator("#fare-zone-row-all")).toBeVisible();

    if (viewport === NARROW) {
      expect(await bodyFitsViewport(page), "body overflows").toBe(true);
    }

    await capture(page, testInfo, `zones-inventory-${viewport.width}`, { fullPage: false });
  }

  await captureReference(page, testInfo, "", "ref-zones");
});

// ── stop list ─────────────────────────────────────────────────────────────

// The stage's stop list: one page of rows from the version's boardable stops,
// the subtexts that explain a row's assignment, the unlocated count that belongs
// to the filter, pagination, and the search's own empty state. The seeded
// "Browser Fare Zones Version" carries 27 boardable stops - 12 Eastbank, 11
// Central (one of them without coordinates) and 4 unassigned - so one page holds
// all of them and both pagination controls are disabled.
test("stop list", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await openFares(page, "zones");

  const rows = page.locator("#fare-zone-stops tr");

  await expect(page.locator("#fare-zone-search")).toHaveValue("");
  await expect(page.locator("#fare-zone-without-location")).toHaveText(
    "1 without map location",
  );
  await expect(page.locator("#fare-zone-stop-head")).toContainText("27 shown");
  await expect(page.locator("#fare-zone-stops")).toBeVisible();
  await expect(rows).toHaveCount(27);
  await expect(page.locator("#fare-zone-stops-container thead th")).toHaveText([
    "Stop",
    "Stop ID",
    "Fare zone",
  ]);

  // Zone membership is rendered per row, so the count of rows naming a zone is
  // that zone's boardable membership.
  await expect(page.locator("#fare-zone-stops tr", { hasText: "Eastbank" })).toHaveCount(12);
  await expect(page.locator("#fare-zone-stops tr", { hasText: "Unassigned" })).toHaveCount(4);

  const depot = page.locator("#fare-zone-stops tr", { hasText: "Central Depot" });

  await expect(depot).toHaveCount(1);
  await expect(depot).toContainText("Central");
  await expect(depot).toContainText("No map location · list selection available");

  const platform = page.locator("#fare-zone-stops tr", {
    hasText: "Central Union Platform 1",
  });

  await expect(platform).toHaveCount(1);
  await expect(platform).toContainText("Central");
  await expect(platform).toContainText("Platform · assigned separately");

  const pagination = page.locator("#fare-zone-stops-pagination");

  await expect(pagination).toContainText("Showing 1–27 of 27 stops");
  await expect(pagination.locator("button", { hasText: "Previous" })).toBeDisabled();
  await expect(pagination.locator("button", { hasText: "Next" })).toBeDisabled();

  await capture(page, testInfo, "stop-list-1440", { fullPage: false });

  // A search that matches nothing names the search, keeps the filter's unlocated
  // count, and offers the one action that leaves both.
  await page.fill("#fare-zone-search", "zzzz");

  await expect(page).toHaveURL(/[?&]q=zzzz$/);
  await expect(page.locator("#fare-zone-stops")).toHaveCount(0);
  await expect(page.locator("#fare-zone-stops-empty")).toContainText(
    "No stops match your search",
  );
  await expect(page.locator("#fare-zone-stops-empty")).toContainText(
    "Try a stop name or ID, or clear your search.",
  );
  await expect(page.locator("#fare-zone-stops-empty-action")).toHaveText(
    "Clear search and filters",
  );
  await expect(page.locator("#fare-zone-stop-head")).toContainText("0 shown");
  await expect(page.locator("#fare-zone-without-location")).toHaveText(
    "1 without map location",
  );

  await capture(page, testInfo, "stop-list-empty", { fullPage: false });

  await page.locator("#fare-zone-stops-empty-action").click();
  await expect(rows).toHaveCount(27);
  await expect(page.locator("#fare-zone-search")).toHaveValue("");

  // The narrow layout keeps the page inside the viewport; the table presents one
  // labeled record per row instead of scrolling a wide grid.
  await page.setViewportSize(NARROW);
  await expect(page.locator("#fare-zone-stops")).toBeVisible();
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  await capture(page, testInfo, "stop-list-320", { fullPage: false });
});
