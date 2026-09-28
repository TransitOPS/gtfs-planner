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
import { bodyFitsViewport, readPendingStates, watchPendingState } from "./browser_helpers.js";

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
  const versionId = await versionIdByName(page, VERSION_NAME);
  if (!versionId) throw new Error(`${VERSION_NAME} is missing its version ID`);
  return versionId;
}

// Resolves any seeded version by its exact name through the version panel, so a
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
  // The checkbox column is the table's first one: step 18 added it, so the stop
  // list's own columns now follow it.
  await expect(page.locator("#fare-zone-stops-container thead th")).toHaveText([
    "Select",
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

  // Pressing Enter in the search field must not hand the form to the browser: a
  // native GET would replace the whole query string, and the filter the operator
  // is reading would be gone. The zone key has to survive the submit.
  await page.setViewportSize(DESKTOP);
  await openFares(page, "zones");
  await page.locator("#fare-zone-row-2").click();
  await expect(page).toHaveURL(/zone=B$/);

  await page.fill("#fare-zone-search", "Riverside");
  await page.press("#fare-zone-search", "Enter");

  await expect(page).toHaveURL(/zone=B&q=Riverside$/);
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Eastbank");
  await expect(page.locator("#fare-zone-row-2")).toHaveAttribute("aria-current", "page");
  await expect(page.locator("#fare-zone-search")).toHaveValue("Riverside");
  await expect(rows).toHaveCount(12);
});

// ── selection bar ─────────────────────────────────────────────────────────

// The table's checkbox column, the head's two select actions and the sticky
// selection bar. The selection is the server's own state and stays out of the
// URL, so a filter change keeps it: the seeded version's 4 unassigned stops are
// selected on the Unassigned filter and then hidden by the Eastbank filter,
// which the bar counts out loud instead of dropping.
test("selection bar", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await openFares(page, "zones");

  const bar = page.locator("#fare-zone-selection-bar");
  const checkboxes = page.locator('#fare-zone-stops input[type="checkbox"]');

  // Nothing selected: the reference's hint sits where the bar will be.
  await expect(bar).toContainText("Select stops to assign or remove a fare zone.");
  await expect(page.locator("#fare-zone-selection-count")).toHaveCount(0);

  // The checkbox column is the table's first one, and every row has a box.
  await expect(page.locator("#fare-zone-stops-container thead th")).toHaveText([
    "Select",
    "Stop",
    "Stop ID",
    "Fare zone",
  ]);
  await expect(checkboxes).toHaveCount(27);

  await page.locator("#fare-zone-row-unassigned").click();
  await expect(page).toHaveURL(/[?&]filter=unassigned$/);
  await expect(checkboxes).toHaveCount(4);

  await checkboxes.nth(0).check();
  await checkboxes.nth(1).check();

  await expect(checkboxes.nth(0)).toBeChecked();
  await expect(checkboxes.nth(1)).toBeChecked();
  await expect(page.locator("#fare-zone-selection-count")).toHaveText("2 stops selected");
  await expect(page.locator("#fare-zone-selection-outside")).toHaveCount(0);

  await capture(page, testInfo, "selection-bar-1440", { fullPage: false });

  // A filter that holds neither selected stop keeps the selection and discloses
  // both hidden stops.
  await page.locator("#fare-zone-row-2").click();
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Eastbank");
  await expect(checkboxes).toHaveCount(12);
  await expect(page.locator("#fare-zone-selection-count")).toHaveText("2 stops selected");
  await expect(page.locator("#fare-zone-selection-outside")).toHaveText(
    "2 outside current filter",
  );

  // The head selects the page or the whole match: this filter matches 12 stops
  // and its page holds all 12, so selecting the page adds them to the 2 stops the
  // filter cannot show.
  await expect(page.locator("#fare-zone-select-shown")).toHaveText("Select 12 shown");
  await expect(page.locator("#fare-zone-select-matching")).toHaveText(
    "Select all 12 matching",
  );

  await page.locator("#fare-zone-select-shown").click();
  await expect(page.locator("#fare-zone-selection-count")).toHaveText("14 stops selected");
  await expect(page.locator("#fare-zone-selection-outside")).toHaveText(
    "2 outside current filter",
  );

  // Clear empties it and the hint returns.
  await page.locator("#fare-zone-clear-selection").click();
  await expect(page.locator("#fare-zone-selection-hint")).toHaveText(
    "Select stops to assign or remove a fare zone.",
  );
  await expect(checkboxes).toHaveCount(12);
  await expect(
    page.locator('#fare-zone-stops input[type="checkbox"]:checked'),
  ).toHaveCount(0);

  // The narrow layout keeps the bar inside the viewport, and it stays pinned to
  // the bottom of the viewport while the page scrolls under it.
  await checkboxes.nth(0).check();
  await page.setViewportSize(NARROW);
  await expect(page.locator("#fare-zone-selection-count")).toHaveText("1 stop selected");
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  const pinned = await bar.boundingBox();

  expect(Math.round(pinned.y + pinned.height)).toBeLessThanOrEqual(NARROW.height);

  await capture(page, testInfo, "selection-bar-320", { fullPage: false });

  await page.evaluate(() => window.scrollTo(0, 600));
  expect(await page.evaluate(() => window.scrollY)).toBeGreaterThan(0);

  const scrolled = await bar.boundingBox();

  expect(Math.round(scrolled.y)).toBe(Math.round(pinned.y));

  // At the end of the page the bar sits below the pagination, so it never
  // covers the last table row.
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));

  const barBox = await bar.boundingBox();
  const paginationBox = await page.locator("#fare-zone-stops-pagination").boundingBox();

  expect(Math.round(paginationBox.y + paginationBox.height)).toBeLessThanOrEqual(
    Math.round(barBox.y) + 1,
  );
});

// ── assignment review ─────────────────────────────────────────────────────

// The reviewed assignment: the bar's two actions, the dialog's review of what a
// save would change, the success callout and Undo. The seeded version holds 8
// "Central West" stops in zone A (Central) and 12 "Riverside" stops in zone B
// (Eastbank), so moving two west stops to Eastbank is a real change between two
// declared zones and Undo has exact previous zones to restore.
test("assignment review", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await openFares(page, "zones");

  const rows = page.locator("#fare-zone-stops tr");
  const rowFor = (stopName) => rows.filter({ hasText: stopName });
  const checkboxFor = (stopName) => rowFor(stopName).locator('input[type="checkbox"]');

  await expect(rows).toHaveCount(27);
  await checkboxFor("Central West 1").check();
  await checkboxFor("Central West 2").check();
  await expect(page.locator("#fare-zone-selection-count")).toHaveText("2 stops selected");

  // Assign zone opens the review. Its default target is the first zone of the
  // inventory (Central, ID A), which both selected stops already have, so the
  // review changes nothing and says why its confirm button is disabled.
  await page.locator("#fare-zone-assign-selection").click();

  const dialog = page.locator("#fare-zone-assignment-dialog");

  await expect(dialog).toBeVisible();
  await expect(dialog.locator("#fare-zone-assignment-dialog-title")).toHaveText(
    "Assign selected stops",
  );
  await expect(dialog.locator("#fare-zone-assignment-intro")).toHaveText(
    "Review 2 selected stops before saving.",
  );
  await expect(dialog.locator("#fare-zone-assignment-target")).toHaveValue("A");
  await expect(dialog.locator("#fare-zone-assignment-reason")).toHaveText(
    "Nothing to change: every selected stop already has this zone.",
  );
  await expect(dialog.locator("#fare-zone-assignment-dialog-confirm")).toBeDisabled();

  // Choosing Eastbank reviews a real move: two assignments change, both move
  // between zones, and the moved-stop warning appears with the rows.
  await dialog.locator("#fare-zone-assignment-target").selectOption("B");

  await expect(dialog.locator("#fare-zone-assignment-summary")).toContainText(
    "2 assignments will change",
  );
  await expect(dialog.locator("#fare-zone-assignment-summary-change")).toHaveText(
    "0 unassigned stops added · 2 moved from another zone",
  );
  await expect(dialog.locator("#fare-zone-assignment-summary-unchanged")).toHaveText(
    "0 already in this zone · left unchanged",
  );
  await expect(dialog.locator("#fare-zone-assignment-moved")).toContainText(
    "Moving stops can change which fares apply to their journeys.",
  );
  await expect(dialog.locator("#fare-zone-assignment-row-1")).toContainText("Central West 1");
  await expect(dialog.locator("#fare-zone-assignment-row-1")).toContainText("A → B");
  await expect(dialog.locator("#fare-zone-assignment-dialog-confirm")).toBeEnabled();

  await capture(page, testInfo, "assignment-1440", { fullPage: false });

  // At 320 px the panel fits the viewport and its body scrolls, so the review
  // stays readable on the narrow layout.
  await page.setViewportSize(NARROW);
  await expect(dialog).toBeVisible();
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  const panel = await page.locator("#fare-zone-assignment-dialog > div > div").boundingBox();

  expect(Math.round(panel.width)).toBeLessThanOrEqual(NARROW.width);
  expect(Math.round(panel.x)).toBeGreaterThanOrEqual(0);

  await capture(page, testInfo, "assignment-320", { fullPage: false });

  await page.setViewportSize(DESKTOP);

  // Save shows its pending label, then closes the dialog and reports what was
  // written. The dialog is gone rather than merely hidden.
  await watchPendingState(page, "#fare-zone-assignment-dialog-confirm");
  await dialog.locator("#fare-zone-assignment-dialog-confirm").click();

  const pendingStates = await readPendingStates(page);

  expect(
    pendingStates.some(({ disabled }) => disabled),
    `no disabled pending state observed in ${JSON.stringify(pendingStates)}`,
  ).toBe(true);

  await expect(page.locator("#fare-zone-assignment-dialog")).toHaveCount(0);
  await expect(page.locator("#fare-zone-saved")).toContainText("2 stops assigned to Eastbank.");
  await expect(rowFor("Central West 1")).toContainText("Eastbank");
  await expect(rowFor("Central West 2")).toContainText("Eastbank");
  await expect(page.locator("#fare-zone-row-2-count")).toHaveText("14");
  await expect(page.locator("#fare-zone-selection-hint")).toBeVisible();

  await capture(page, testInfo, "assignment-saved", { fullPage: false });

  // Undo restores the zones the save replaced and ends the offer.
  await page.locator("#fare-zone-undo").click();

  await expect(page.locator("#fare-zone-saved")).toContainText("Change undone.");
  await expect(page.locator("#fare-zone-undo")).toHaveCount(0);
  await expect(rowFor("Central West 1")).toContainText("Central");
  await expect(rowFor("Central West 2")).toContainText("Central");
  await expect(page.locator("#fare-zone-row-2-count")).toHaveText("12");

  await captureReference(page, testInfo, "?dialog=assignment", "ref-assignment");
});

// ── zone drawer ───────────────────────────────────────────────────────────

// The create/edit zone drawer and the first-use state. The first-use state needs
// a version whose inventory carries no zone at all, which the seeded "Browser E2E
// Version" is: it carries the diagram journey's stops and no fare-zone row. The
// drawer's own journeys run on the version this file owns, and the case leaves one
// created zone behind, named so a re-run without `prepare:browser` is obvious.
test("zone drawer", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  // ── first use ──
  const emptyVersionId = await versionIdByName(page, "Browser E2E Version");

  await page.goto(`/gtfs/${emptyVersionId}/settings/fares`);
  await waitForLiveView(page);

  const firstUse = page.locator("#fare-zone-first-use");

  await expect(firstUse).toBeVisible();
  await expect(firstUse).toContainText("Start with your first fare zone");
  await expect(firstUse).toContainText(
    "A zone groups stops that share a fare area. Give it a name, then select its stops on the map or in a list.",
  );
  await expect(firstUse).toContainText(
    "Already have a feed? Stop zone IDs from an imported feed appear here.",
  );
  await expect(page.locator("#fare-zones-panel")).toHaveCount(0);
  await expect(page.locator("#fare-zone-create")).toBeVisible();

  await capture(page, testInfo, "zone-first-use-1440", { fullPage: false });

  // The state's CTA opens the same drawer. Nothing is written on this version, so
  // the diagram journey's fixture stays untouched.
  await page.locator("#fare-zone-first-use-create").click();
  await expect(page.locator("#fare-zone-drawer-title")).toHaveText("Create a fare zone");
  await page.locator("#fare-zone-drawer-close").click();
  await expect(page.locator("#fare-zone-drawer-overlay")).toHaveAttribute("data-open", "false");

  // ── create drawer ──
  const versionId = await faresVersionId(page);

  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);
  await expect(page.locator("#fare-zone-create")).toBeEnabled();

  const drawer = page.locator("#fare-zone-drawer");

  await page.locator("#fare-zone-create").click();
  await expect(drawer).toBeVisible();
  await expect(page.locator("#fare-zone-drawer-title")).toHaveText("Create a fare zone");
  await expect(page.locator("#fare-zone-drawer-intro")).toHaveText(
    "Start with a name people recognize. You can assign stops next.",
  );
  await expect(drawer).toContainText("Zone name");
  await expect(drawer).toContainText("Zone ID");
  await expect(drawer).toContainText(
    "Unique in this version. Use letters, numbers, hyphens or underscores.",
  );
  await expect(drawer).toContainText("Map color");
  await expect(drawer).toContainText("Markers also show the zone ID, so color is never the only cue.");
  await expect(page.locator("#fare-zone-name")).toHaveValue("");
  await expect(page.locator("#fare-zone-id")).toHaveValue("");
  await expect(page.locator("#fare-zone-color")).toHaveValue("ochre");
  await expect(page.locator("#fare-zone-color option")).toHaveText([
    "Ocean blue",
    "Teal",
    "Plum",
    "Ochre",
    "Green",
  ]);
  await expect(page.locator("#fare-zone-drawer-note")).toContainText(
    "Your new zone starts empty. It remains available while you build its stop membership.",
  );
  await expect(page.locator("#fare-zone-drawer-summary")).toHaveCount(0);

  await capture(page, testInfo, "zone-drawer-1440", { fullPage: false });

  // At 320 px the panel fills the viewport and the page does not overflow.
  await page.setViewportSize(NARROW);
  await expect(drawer).toBeVisible();
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  const panel = await page.locator("#fare-zone-drawer").boundingBox();

  expect(Math.round(panel.width)).toBeLessThanOrEqual(NARROW.width);
  expect(Math.round(panel.x)).toBeGreaterThanOrEqual(0);

  await capture(page, testInfo, "zone-drawer-320", { fullPage: false });

  await page.setViewportSize(DESKTOP);

  // ── a duplicate ID is rejected beside its field ──
  await page.fill("#fare-zone-name", "Waterfront");
  await page.selectOption("#fare-zone-color", "teal");
  await page.fill("#fare-zone-id", "A");
  await page.locator('#fare-zone-form button[type="submit"]').click();

  await expect(page.locator("#fare-zone-id")).toHaveAttribute("aria-invalid", "true");
  await expect(drawer).toContainText("That zone ID is already in use. Choose another.");
  await expect(page.locator("#fare-zone-name")).toHaveValue("Waterfront");
  await expect(page.locator("#fare-zone-color")).toHaveValue("teal");
  await expect(drawer).toBeVisible();

  // Nothing was written: the inventory still holds its four zones and no zone
  // adopted the typed name.
  await expect(page.locator("#fare-zone-inventory-count")).toHaveText("4");
  await expect(page.locator("#fare-zone-inventory")).not.toContainText("Waterfront");

  await capture(page, testInfo, "zone-drawer-error-1440", { fullPage: false });

  // ── create ──
  await page.fill("#fare-zone-id", "W");
  await page.locator('#fare-zone-form button[type="submit"]').click();

  await expect(page.locator("#fare-zone-drawer-overlay")).toHaveAttribute("data-open", "false");
  await expect(page).toHaveURL(new RegExp(`[?&]zone=W$`));
  await expect(page.locator("#fare-zone-notice")).toHaveText(
    "Zone created. Select stops from All stops to get started.",
  );
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Waterfront");
  await expect(page.locator("#fare-zone-stops-empty")).toContainText("No stops in this zone yet");
  await expect(page.locator("#fare-zone-inventory-count")).toHaveText("5");
  await expect(page.locator("#fare-zone-row-5")).toContainText("Waterfront");

  await capture(page, testInfo, "zone-drawer-created-1440", { fullPage: false });

  // ── rename ──
  await page.locator("#fare-zone-edit").click();
  await expect(page.locator("#fare-zone-drawer-title")).toHaveText("Edit Waterfront");
  await expect(page.locator("#fare-zone-id")).toHaveValue("W");
  await expect(page.locator("#fare-zone-drawer-summary")).toContainText(
    "0 stops · 0 related fare rules.",
  );
  await page.fill("#fare-zone-id", "WW");
  await page.locator('#fare-zone-form button[type="submit"]').click();

  await expect(page.locator("#fare-zone-drawer-overlay")).toHaveAttribute("data-open", "false");
  await expect(page).toHaveURL(new RegExp(`[?&]zone=WW$`));
  await expect(page.locator("#fare-zone-notice")).toHaveText("Zone updated.");
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Waterfront");

  await capture(page, testInfo, "zone-drawer-renamed-1440", { fullPage: false });

  // ── the edit summary names what a rename rewrites ──
  // Central carries 11 boardable stops, a station member and four rule references,
  // so its drawer states all three before anything is typed.
  await page.locator("#fare-zone-row-1").click();
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Central");
  await page.locator("#fare-zone-edit").click();

  await expect(page.locator("#fare-zone-drawer-title")).toHaveText("Edit Central");
  await expect(page.locator("#fare-zone-id")).toHaveValue("A");
  await expect(page.locator("#fare-zone-drawer-summary")).toContainText(
    "11 stops · 4 related fare rules.",
  );
  await expect(page.locator("#fare-zone-drawer-summary-updates")).toHaveText(
    "Changing this ID updates these references together.",
  );
  await expect(page.locator("#fare-zone-drawer-summary-others")).toHaveText(
    "Also updates 1 station or entrance with this zone ID.",
  );

  await capture(page, testInfo, "zone-drawer-edit-1440", { fullPage: false });

  await page.locator("#fare-zone-drawer-close").click();
  await expect(page.locator("#fare-zone-drawer-overlay")).toHaveAttribute("data-open", "false");

  // Eastbank has no station member, so the station line is absent and the summary
  // counts its twelve stops and two rule references.
  await page.locator("#fare-zone-row-2").click();
  await page.locator("#fare-zone-edit").click();

  await expect(page.locator("#fare-zone-drawer-title")).toHaveText("Edit Eastbank");
  await expect(page.locator("#fare-zone-drawer-summary")).toContainText(
    "12 stops · 2 related fare rules.",
  );
  await expect(page.locator("#fare-zone-drawer-summary-others")).toHaveCount(0);

  await page.locator("#fare-zone-drawer-close").click();
  await expect(page.locator("#fare-zone-drawer-overlay")).toHaveAttribute("data-open", "false");

  await captureReference(page, testInfo, "?dialog=zone", "ref-zone");
});

// ── delete dialog ─────────────────────────────────────────────────────────

// The dialog the zone drawer's destructive exit opens. It is a capture case as
// well as a behavioural one, so it reads the copy, the replacement select and
// the two shapes the seeded fixture carries - Central, which three rule groups
// and a station member carry, and the empty Airport - against the reference's
// own `?dialog=delete`. Nothing is confirmed: the case must be able to run
// without mutating the fixture other cases read.
test("delete dialog", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await openFares(page, "zones");

  // Central: 11 boardable stops, a station member and four rule references.
  await page.locator("#fare-zone-inventory-filters a").filter({ hasText: "Central" }).click();
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Central");

  await page.locator("#fare-zone-edit").click();
  await expect(page.locator("#fare-zone-drawer-overlay")).toHaveAttribute("data-open", "true");
  await expect(page.locator("#fare-zone-delete")).toHaveText("Delete zone…");

  await page.locator("#fare-zone-delete").click();

  const dialog = page.locator("#fare-zone-delete-dialog");

  await expect(dialog).toHaveAttribute("data-open", "true");
  await expect(dialog).toHaveAttribute("role", "alertdialog");
  // The confirm replaces the drawer rather than stacking on it.
  await expect(page.locator("#fare-zone-drawer-overlay")).toHaveAttribute("data-open", "false");
  await expect(page.locator("#fare-zone-delete-dialog-title")).toHaveText("Delete Central?");

  await expect(page.locator("#fare-zone-delete-consequence")).toHaveText(
    "11 stops and 4 fare rules use this zone.",
  );
  await expect(page.locator("#fare-zone-delete-others")).toHaveText(
    "Also moves 1 station or entrance with this zone ID.",
  );
  await expect(page.locator("#fare-zone-delete-replacement-form")).toContainText(
    "Replace references with",
  );
  // A referenced zone can only move to another inventory zone: no Unassigned.
  await expect(page.locator("#fare-zone-delete-replacement option")).toHaveText([
    "Eastbank · B",
    "C · C",
    "Airport · D",
  ]);
  await expect(page.locator("#fare-zone-delete-warning")).toHaveText(
    "Stops and fare rules will move together. This changes which journeys the related fares cover.",
  );
  await expect(page.locator("#fare-zone-delete-dialog-confirm")).toHaveText("Replace & delete");
  await expect(page.locator("#fare-zone-delete-dialog-cancel")).toHaveText("Keep zone");
  await expect(page.locator("#fare-zone-delete-dialog-confirm")).toBeEnabled();
  await expect(page.locator("#fare-zone-delete-reason")).toHaveCount(0);

  await capture(page, testInfo, "delete-1440", { fullPage: false });

  // At 320 px the panel fits the viewport and the page does not overflow.
  await page.setViewportSize(NARROW);
  await expect(dialog).toBeVisible();
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  const panel = await page.locator("#fare-zone-delete-dialog > div > div").boundingBox();
  expect(Math.round(panel.width)).toBeLessThanOrEqual(NARROW.width);
  expect(Math.round(panel.x)).toBeGreaterThanOrEqual(0);

  await capture(page, testInfo, "delete-320", { fullPage: false });

  await page.setViewportSize(DESKTOP);

  // Keeping the zone closes the dialog and returns focus to the control that
  // opened the drawer, which is the only one still on screen.
  await page.locator("#fare-zone-delete-dialog-cancel").click();
  await expect(dialog).toHaveCount(0);
  await expect(page.locator("#fare-zone-edit")).toBeFocused();

  // The empty unreferenced zone: no select, its own sentence and label.
  await page.locator("#fare-zone-inventory-filters a").filter({ hasText: "Airport" }).click();
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Airport");
  await page.locator("#fare-zone-edit").click();
  await page.locator("#fare-zone-delete").click();

  await expect(page.locator("#fare-zone-delete-dialog-title")).toHaveText("Delete Airport?");
  await expect(page.locator("#fare-zone-delete-consequence")).toHaveText(
    "0 stops and 0 fare rules use this zone.",
  );
  await expect(page.locator("#fare-zone-delete-empty")).toHaveText(
    "This empty zone has no references. Deleting it will not change stops or fares.",
  );
  await expect(page.locator("#fare-zone-delete-replacement-form")).toHaveCount(0);
  await expect(page.locator("#fare-zone-delete-dialog-confirm")).toHaveText("Delete empty zone");

  await capture(page, testInfo, "delete-empty-1440", { fullPage: false });

  await page.locator("#fare-zone-delete-dialog-cancel").click();
  await expect(page.locator("#fare-zone-delete-dialog")).toHaveCount(0);

  await captureReference(page, testInfo, "?dialog=delete", "ref-delete");
});

// ── zones map ─────────────────────────────────────────────────────────────

// The Zones tab's map. The hook hydrates from the server's `fare_zone_map_ready`
// reply and draws beside the stop list, the stage header's switch removes it, and
// a map that cannot load becomes the reference's fallback with both ways out.
// Tiles are answered locally in each direction: a blank PNG while the map is
// expected to work, and a 500 when it is expected to fail.
test("zones map", async ({ page, context }, testInfo) => {
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);
  await openFares(page, "zones");

  const canvas = page.locator("#fare-zone-map [data-map-canvas]");

  // The seeded version carries 26 located boardable stops. `ready` means the
  // handshake reply arrived and was applied, so the count beside it is the
  // hydrated snapshot rather than a placeholder.
  await expect(page.locator("#fare-zone-map")).toBeVisible();
  await expect(canvas).toHaveAttribute("data-map-state", "ready");
  await expect(canvas).toHaveAttribute("data-point-count", "26");
  await expect(page.locator("#fare-zone-stage-title")).toHaveText("All stops");

  // Map + list is one stage: the map, its legend and the complete list below it.
  await expect(page.locator("#fare-zone-map-legend")).toContainText("Central");
  await expect(page.locator("#fare-zone-map-legend")).toContainText("Eastbank");
  await expect(page.locator("#fare-zone-map-legend")).toContainText("Unassigned");
  await expect(page.locator("#fare-zone-stop-list")).toBeVisible();
  await expect(page.locator("#fare-zone-map [data-map-hint]")).toContainText(
    "Click stops or drag a box to select.",
  );
  await expect(page.locator("#fare-zone-map [data-map-mode='select']")).toHaveAttribute(
    "aria-pressed",
    "true",
  );
  await expect(page.locator("#fare-zone-map [data-map-zoom='in']")).toHaveAttribute(
    "aria-label",
    "Zoom in",
  );

  await capture(page, testInfo, "zones-map-1440", { fullPage: false });

  // List takes the stage: the map root and its hook go, the list stays.
  await page.locator('label[for="fare-zone-view-option-list"]').click();

  await expect(page.locator("#fare-zone-map")).toHaveCount(0);
  await expect(page.locator("#fare-zone-map-legend")).toHaveCount(0);
  await expect(page.locator("#fare-zone-stop-list")).toBeVisible();

  await capture(page, testInfo, "zones-map-list-1440", { fullPage: false });

  // Back to Map + list, where a fresh hook hydrates from its own reply.
  await page.locator('label[for="fare-zone-view-option-map"]').click();

  await expect(page.locator("#fare-zone-map")).toBeVisible();
  await expect(canvas).toHaveAttribute("data-map-state", "ready");
  await expect(canvas).toHaveAttribute("data-point-count", "26");

  // At 320 px the frame is full width and the page does not overflow.
  await page.setViewportSize(NARROW);
  await expect(page.locator("#fare-zone-map")).toBeVisible();
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  await capture(page, testInfo, "zones-map-320", { fullPage: false });

  await page.setViewportSize(DESKTOP);

  // A map whose tiles fail becomes the fallback on a fresh page, so the first
  // tile error is the one this render sees.
  const failed = await context.newPage();

  await failed.setViewportSize(DESKTOP);
  await failed.route("**/map/tiles/**", (route) => route.fulfill({ status: 500, body: "" }));
  await openFares(failed, "zones");

  await expect(failed.locator("#fare-zone-map")).toHaveCount(0);
  await expect(failed.locator("#fare-zone-map-unavailable")).toBeVisible();
  await expect(failed.locator("#fare-zone-map-unavailable")).toContainText(
    "The map is unavailable",
  );
  await expect(failed.locator("#fare-zone-map-unavailable")).toContainText(
    "You can still find and assign every stop in the list.",
  );
  await expect(failed.locator("#fare-zone-map-retry")).toHaveText("Retry map");
  await expect(failed.locator("#fare-zone-map-use-list")).toHaveText("Use stop list");
  // The legend stays under the fallback, as the reference keeps it.
  await expect(failed.locator("#fare-zone-map-legend")).toContainText("Central");
  // The list is the complete alternative, exactly as the copy says.
  await expect(failed.locator("#fare-zone-stop-list")).toBeVisible();

  await capture(failed, testInfo, "zones-map-unavailable", { fullPage: false });

  // Use stop list is the fallback's other way out.
  await failed.locator("#fare-zone-map-use-list").click();

  await expect(failed.locator("#fare-zone-map-unavailable")).toHaveCount(0);
  await expect(failed.locator("#fare-zone-stop-list")).toBeVisible();

  await failed.close();

  await captureReference(page, testInfo, "?state=ready", "ref-zones");
  await captureReference(page, testInfo, "?state=map-error", "ref-zones-map-error");
});
