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
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
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
  // A referenced zone can only move to another inventory zone: every other zone
  // of the inventory is offered, the zone being deleted is not, and Unassigned
  // never is. The list is asserted by membership rather than as a literal set
  // because the drawer case above leaves its own created zone behind.
  const replacements = page.locator("#fare-zone-delete-replacement option");
  const inventoryCount = Number(
    await page.locator("#fare-zone-inventory-count").textContent(),
  );

  await expect(replacements).toHaveCount(inventoryCount - 1);

  for (const label of ["Eastbank · B", "C · C", "Airport · D"]) {
    await expect(replacements.filter({ hasText: label })).toHaveCount(1);
  }

  await expect(replacements.filter({ hasText: "Unassigned" })).toHaveCount(0);
  await expect(replacements.filter({ hasText: "Central · A" })).toHaveCount(0);
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

// ── fare rules ────────────────────────────────────────────────────────────

// The Fare rules tab's list: one card per UI rule, its fare, its journey, its
// route and the warning for a rule that references a zone with no boardable
// stops. The seeded "Browser Fare Zones Version" carries four rules from five
// rows: CITY A→A, CITY C→A (C has no stops and no record, so its rule is the
// warned one), CROSS A→B, and CROSS through A + B (two contains rows, one rule).
// Fares CITY $2.50 and CROSS $3.75 both exist; no rule uses the version's route,
// so every card reads "All routes".
test("rules list", async ({ page }, testInfo) => {
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);
  await openFares(page, "rules");

  await expect(page.locator("#fares-tab-rules")).toHaveAttribute("aria-current", "page");
  await expect(page.locator("#fare-rules-intro")).toContainText(
    "Define the journey, then choose the fare.",
  );
  await expect(page.locator("#fare-rules-intro")).toContainText(
    "Use existing fares. Prices and payment settings are managed separately.",
  );

  const cards = page.locator("#fare-rule-list article");

  // Five rows, four rules: the two contains rows never become a card of their own.
  await expect(cards).toHaveCount(4);

  const withinZone = cards.filter({ hasText: "From Central → Central" });

  await expect(withinZone).toHaveCount(1);
  await expect(withinZone).toContainText("CITY · $2.50");
  await expect(withinZone).toContainText("All routes · One direction · within the same zone");
  await expect(withinZone.locator("[id$='-stopless']")).toHaveCount(0);

  const stopless = cards.filter({ hasText: "From C → Central" });

  await expect(stopless).toHaveCount(1);
  await expect(stopless).toContainText("CITY · $2.50");
  await expect(stopless.locator("[id$='-stopless']")).toHaveText("Zone used without stops");

  const oneWay = cards.filter({ hasText: "From Central → Eastbank" });

  await expect(oneWay).toHaveCount(1);
  await expect(oneWay).toContainText("CROSS · $3.75");
  await expect(oneWay).toContainText("All routes · One direction");
  await expect(oneWay.locator("[id$='-stopless']")).toHaveCount(0);

  // The through-zone rule names every zone the journey must visit on its own
  // journey line, and no other card carries the warning badge.
  const through = cards.filter({ hasText: "Through Central + Eastbank" });

  await expect(through).toHaveCount(1);
  await expect(through).toContainText("CROSS · $3.75");
  await expect(through).toContainText("Any journey · Through Central + Eastbank");
  await expect(through).toContainText("All routes · Every listed zone must be visited");

  await expect(page.locator("[id$='-stopless']")).toHaveCount(1);

  await expect(page.locator("#fare-rules-note")).toContainText(
    "“Any origin” and “Any destination” leave that end of the journey unrestricted. A reverse journey needs its own rule.",
  );

  await capture(page, testInfo, "rules-1440", { fullPage: false });

  await page.setViewportSize(NARROW);

  await expect(cards).toHaveCount(4);
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  await capture(page, testInfo, "rules-320", { fullPage: false });

  await page.setViewportSize(DESKTOP);

  await captureReference(page, testInfo, "?tab=rules", "ref-rules");
});

// The fare rule drawer and removal. The drawer is opened from the CROSS A→B card
// the rules list case reads, its fields and plain-language summary are checked
// against the seeded zones and fares, the removal confirm is captured, and a new
// rule is created and removed again so the seeded version ends where it started.
// A version with no fare_attributes shows the disabled `Add fare rule` with its
// reason (AC-30), which is the one state the seeded fare-zones version cannot
// show.
test("rule drawer", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  // ── no fares ──
  const noFaresVersionId = await versionIdByName(page, "Browser E2E Version");

  await page.goto(`/gtfs/${noFaresVersionId}/settings/fares/rules`);
  await waitForLiveView(page);

  await expect(page.locator("#add-fare-rule")).toBeDisabled();
  await expect(page.locator("#add-fare-rule-reason")).toHaveText(
    "This version has no fares. Import fare_attributes.txt to add fares.",
  );

  // ── edit drawer ──
  await openFares(page, "rules");

  const cards = page.locator("#fare-rule-list article");
  const oneWay = cards.filter({ hasText: "From Central → Eastbank" });

  await expect(oneWay).toHaveCount(1);
  await oneWay.locator("[id$='-edit']").click();

  const drawer = page.locator("#fare-rule-drawer");

  await expect(drawer).toBeVisible();
  await expect(page.locator("#fare-rule-drawer-overlay")).toHaveAttribute("data-open", "true");
  await expect(page.locator("#fare-rule-drawer-title")).toHaveText("Edit fare rule");

  // Every field the reference puts in the dialog, in its own order and words.
  await expect(page.locator("#fare-rule-fare")).toHaveValue("CROSS");
  await expect(page.locator("#fare-rule-fare-help")).toHaveText(
    "Existing fares in this version. Prices are shown for context.",
  );
  await expect(page.locator("#fare-rule-origin")).toHaveValue("A");
  await expect(page.locator("#fare-rule-destination")).toHaveValue("B");
  await expect(page.locator("#fare-rule-route")).toHaveValue("");
  await expect(page.locator("#fare-rule-contains legend")).toContainText(
    "Must visit these zones",
  );
  await expect(page.locator("#fare-rule-contains-help")).toHaveText(
    "The journey must visit every checked zone. Leave all unchecked for no through-zone requirement.",
  );
  await expect(page.locator("#fare-rule-summary")).toHaveText(
    "Use CROSS · $3.75 for journeys from Central to Eastbank on all routes.",
  );
  await expect(drawer).toContainText(
    "Start and end zones are directional. To charge the same fare in reverse, add a second rule with those zones swapped.",
  );
  await expect(page.locator("#fare-rule-remove")).toHaveText("Remove this rule…");
  await expect(page.locator("#fare-rule-form button[type='submit']")).toHaveText("Save fare rule");

  // The two journey selects sit side by side at this width, one per column.
  const originBox = await page.locator("#fare-rule-origin").boundingBox();
  const destinationBox = await page.locator("#fare-rule-destination").boundingBox();

  expect(destinationBox.x).toBeGreaterThan(originBox.x + originBox.width);

  await capture(page, testInfo, "rule-drawer-1440", { fullPage: false });

  await page.setViewportSize(NARROW);

  await expect(drawer).toBeVisible();
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  const narrowOrigin = await page.locator("#fare-rule-origin").boundingBox();
  const narrowDestination = await page.locator("#fare-rule-destination").boundingBox();

  // Below `sm` the two selects stack instead of shrinking side by side.
  expect(narrowDestination.y).toBeGreaterThan(narrowOrigin.y + narrowOrigin.height - 1);

  await capture(page, testInfo, "rule-drawer-320", { fullPage: false });

  await page.setViewportSize(DESKTOP);

  // ── removal confirm ──
  await page.locator("#fare-rule-remove").click();

  await expect(page.locator("#fare-rule-remove-dialog")).toBeVisible();
  await expect(page.locator("#fare-rule-remove-dialog-title")).toHaveText(
    "Remove this fare rule?",
  );
  await expect(page.locator("#fare-rule-remove-consequence")).toHaveText(
    "The fare itself will remain. Journeys covered by this rule may no longer receive that fare.",
  );
  await expect(page.locator("#fare-rule-remove-dialog-confirm")).toHaveText("Remove rule");
  await expect(page.locator("#fare-rule-remove-dialog-cancel")).toHaveText("Keep rule");

  await capture(page, testInfo, "rule-remove", { fullPage: false });

  await page.locator("#fare-rule-remove-dialog-cancel").click();
  await expect(page.locator("#fare-rule-remove-dialog")).toHaveCount(0);
  await page.locator("#fare-rule-drawer-close").click();
  await expect(page.locator("#fare-rule-drawer-overlay")).toHaveAttribute("data-open", "false");

  // ── create and remove, ending where the case started ──
  await page.locator("#add-fare-rule").click();
  await expect(page.locator("#fare-rule-drawer-title")).toHaveText("Add a fare rule");

  await page.selectOption("#fare-rule-origin", "A");
  await page.selectOption("#fare-rule-destination", "B");
  await expect(page.locator("#fare-rule-summary")).toHaveText(
    "Use CITY · $2.50 for journeys from Central to Eastbank on all routes.",
  );

  await capture(page, testInfo, "rule-drawer-create", { fullPage: false });

  await page.locator("#fare-rule-form button[type='submit']").click();

  await expect(page.locator("#fare-rule-drawer-overlay")).toHaveAttribute("data-open", "false");
  await expect(page.locator("#fare-zone-notice")).toHaveText("Fare rule saved.");
  await expect(cards).toHaveCount(5);

  // The new CITY rule is the only card that is both a CITY fare and the
  // Central → Eastbank journey the form chose.
  const created = cards
    .filter({ hasText: "CITY · $2.50" })
    .filter({ hasText: "From Central → Eastbank" });

  await expect(created).toHaveCount(1);
  await created.locator("[id$='-edit']").click();
  await page.locator("#fare-rule-remove").click();
  await page.locator("#fare-rule-remove-dialog-confirm").click();

  await expect(page.locator("#fare-zone-notice")).toHaveText("Fare rule removed.");
  await expect(cards).toHaveCount(4);

  await captureReference(page, testInfo, "?dialog=rule", "ref-rule");
});

// ── checks ────────────────────────────────────────────────────────────────

// The Checks tab's issue rows and its all-clear line. The seeded "Browser Fare
// Zones Version" reports one needs-repair row (a fare rule uses C, which has no
// stops and no record), four of its 27 boardable stops without a zone, the
// declared-but-empty D Airport, and the conditional source check, so the tab
// badge reads 2. The scale version has five zones full of stops, nothing
// unassigned and no rule referencing a zone, which is the all-clear state.
test("checks", async ({ page }, testInfo) => {
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  const versionId = await openFares(page, "checks");

  await expect(page.locator("#fares-tab-checks")).toHaveAttribute("aria-current", "page");
  await expect(page.locator("#fare-checks-heading")).toHaveText("Check your fare-zone setup");
  await expect(page.locator("#fare-checks-subtitle")).toHaveText(
    "Review membership and references before publishing this version.",
  );
  await expect(page.locator("#fare-check-clean")).toHaveCount(0);

  const stopless = page.locator("#fare-check-stopless-0");

  await expect(stopless).toContainText("Needs repair");
  await expect(stopless).toContainText("Fare rules use C (C), which has no stops");
  await expect(stopless).toContainText(
    "Exported fares for this zone won't match any stop. Assign stops to this zone or edit the rules that use it.",
  );
  await expect(page.locator("#fare-check-stopless-0-link")).toHaveText("Show C");
  await expect(page.locator("#fare-check-stopless-0-link")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings/fares?zone=C`,
  );
  await expect(page.locator("#fare-check-stopless-1")).toHaveCount(0);

  await expect(page.locator("#fare-check-unassigned")).toContainText("Review");
  await expect(page.locator("#fare-check-unassigned")).toContainText("4 stops have no fare zone");
  await expect(page.locator("#fare-check-unassigned-link")).toHaveText("Review unassigned stops");
  await expect(page.locator("#fare-check-unassigned-link")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings/fares?filter=unassigned`,
  );

  await expect(page.locator("#fare-check-empty")).toContainText("Note");
  await expect(page.locator("#fare-check-empty")).toContainText("1 empty zone");
  await expect(page.locator("#fare-check-empty-link")).toHaveCount(0);

  await expect(page.locator("#fare-check-source")).toContainText("Source check");
  await expect(page.locator("#fare-check-source")).toContainText(
    "Verify assignments against your source feed",
  );
  await expect(page.locator("#fare-check-source-detail summary")).toHaveText(
    "What must be checked?",
  );

  // Two kinds count: the stopless referenced zone and the unassigned-stops row.
  await expect(page.locator("#fares-checks-count")).toHaveText("2");

  await capture(page, testInfo, "checks-1440", { fullPage: false });

  // The disclosure is a native `<details>`, so it opens without script and stays
  // keyboard-operable.
  await page.locator("#fare-check-source-detail summary").click();
  await expect(page.locator("#fare-check-source-detail")).toHaveAttribute("open", "");
  await expect(page.locator("#fare-check-source-detail")).toContainText(
    "Check that each stop has the same zone as in your source feed.",
  );

  await capture(page, testInfo, "checks-source-1440", { fullPage: false });

  await page.setViewportSize(NARROW);

  await expect(page.locator("#fare-checks-heading")).toBeVisible();
  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  await capture(page, testInfo, "checks-320", { fullPage: false });

  await page.setViewportSize(DESKTOP);

  // ── all clear ──
  const cleanVersionId = await versionIdByName(page, "Browser Fare Zones Scale Version");

  await page.goto(`/gtfs/${cleanVersionId}/settings/fares/checks`);
  await waitForLiveView(page);

  await expect(page.locator("#fare-check-clean h3")).toHaveText(
    "Every zone used by a fare rule has stops, and every stop has a zone.",
  );
  await expect(page.locator("#fare-check-clean")).toContainText("Ready");
  await expect(page.locator("#fare-check-stopless-0")).toHaveCount(0);
  await expect(page.locator("#fare-check-unassigned")).toHaveCount(0);
  await expect(page.locator("#fare-check-empty")).toHaveCount(0);
  await expect(page.locator("#fare-check-source")).toHaveCount(0);
  await expect(page.locator("#fares-checks-count")).toHaveText("0");

  await capture(page, testInfo, "checks-clean-1440", { fullPage: false });

  await captureReference(page, testInfo, "?tab=checks", "ref-checks");
  await captureReference(page, testInfo, "?state=import&tab=checks", "ref-checks-repair");
});

// ── stop details ──────────────────────────────────────────────────────────

// The read-only fare zone stop details carries, and the Fares link that leaves
// it. The seeded "Browser Fare Zones Version" gives Central Union Platform 1
// zone A (named Central), leaves the four Bayline stops unassigned, and gives
// Central Union Station two platforms in zone A while the station itself
// carries A too - so the station's entry is its platforms' zones, not its own.
test("stop details", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await faresVersionId(page);
  const stopPath = (stopId) => `/gtfs/${versionId}/stops/${stopId}`;

  // ── a boardable platform ──
  await page.goto(stopPath("BROWSER_FZ_PLATFORM_1"));
  await waitForLiveView(page);

  await expect(page.locator("dt", { hasText: /^Fare zone$/ })).toHaveCount(1);
  await expect(page.locator("#stop-fare-zone")).toHaveText("Central · A");
  await expect(page.locator("#stop-fare-zone-link")).toHaveText("View in Fares");
  await expect(page.locator("#stop-fare-zone-link")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings/fares?zone=A`,
  );
  await expect(page.locator("#station-platform-fare-zones")).toHaveCount(0);

  await capture(page, testInfo, "stop-details-1440", { fullPage: false });

  // ── the station over those platforms ──
  await page.goto(stopPath("BROWSER_FZ_STATION"));
  await waitForLiveView(page);

  await expect(page.locator("#stop-fare-zone")).toHaveCount(0);
  await expect(page.locator("#station-platform-fare-zones a")).toHaveCount(1);
  await expect(page.locator("#platform-fare-zone-0")).toHaveText("Central · A");
  await expect(page.locator("#platform-fare-zone-0")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings/fares?zone=A`,
  );

  await capture(page, testInfo, "stop-details-station-1440", { fullPage: false });

  // ── a boardable stop with no zone ──
  await page.goto(stopPath("BROWSER_FZ_UNASSIGNED_1"));
  await waitForLiveView(page);

  await expect(page.locator("#stop-fare-zone")).toHaveText("None");
  await expect(page.locator("#stop-fare-zone-link")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings/fares?filter=unassigned`,
  );

  await capture(page, testInfo, "stop-details-unassigned-1440", { fullPage: false });

  // ── the narrow viewport ──
  await page.setViewportSize(NARROW);

  await page.goto(stopPath("BROWSER_FZ_PLATFORM_1"));
  await waitForLiveView(page);

  await expect(page.locator("#stop-fare-zone")).toBeVisible();

  expect(await bodyFitsViewport(page), "body overflows").toBe(true);

  await capture(page, testInfo, "stop-details-320", { fullPage: false });

  // ── the link reaches that zone's filter ──
  await page.setViewportSize(DESKTOP);

  await page.goto(stopPath("BROWSER_FZ_PLATFORM_1"));
  await waitForLiveView(page);

  await page.locator("#stop-fare-zone-link").click();

  await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/settings/fares\\?zone=A$`));

  await waitForLiveView(page);

  await expect(page.locator("#fare-zone-stage-title")).toHaveText("Central");
  await expect(page.locator("#fare-zone-row-all")).not.toHaveAttribute("aria-current", "page");

  await capture(page, testInfo, "stop-details-fares-1440", { fullPage: false });
});

// ── journey (step 29, EV-27) ──────────────────────────────────────────────

// The ordinary-entry journey. Every case below enters through the account menu's
// Settings link and the Settings bar's Fares tab rather than a direct URL, so the
// journey covers the navigation an editor uses, and only the map's tile template
// is substituted. The seeded "Browser Fare Zones Version" carries 26 located
// boardable stops in two clusters 0.071 degrees apart - eight of them west of the
// fitted midpoint longitude, one stop with no coordinates, four unassigned - and
// a 10,000-stop sibling version for the scale measurement.
test.describe("fare zones journey", () => {
  const WEST_STOPS = [
    "Central West 1",
    "Central West 2",
    "Central West 3",
    "Central West 4",
    "Central West 5",
    "Central West 6",
    "Central West 7",
    "Central West 8",
  ];

  // Switches the header's version panel to the named version. The option carries
  // the version ID and the trigger navigates, so the journey reads the ID from the
  // panel instead of assuming which version is the organization's default.
  async function selectVersion(page, name) {
    const option = page
      .locator("#gtfs-version-panel [data-version-option]")
      .filter({ hasText: name });

    await expect(option).toHaveCount(1);

    const versionId = await option.getAttribute("data-version-id");
    if (!versionId) throw new Error(`${name} is missing its version ID`);

    if ((await option.getAttribute("aria-current")) === "true") return versionId;

    // A click that lands before the header's hook mounts is dropped, so the
    // panel and the option are retried until the version actually changed. The
    // panel opens on a server round trip, so the check precedes each click.
    await expect(async () => {
      if (!(await page.locator("#gtfs-version-panel").isVisible())) {
        await page.locator("#gtfs-version-trigger").click();
      }

      await expect(page.locator("#gtfs-version-panel")).toBeVisible({ timeout: 2000 });
    }).toPass({ timeout: 20000 });

    await option.click();
    await page.waitForURL(new RegExp(`/gtfs/${versionId}/`));
    await waitForLiveView(page);

    return versionId;
  }

  // Ordinary entry: the version, the account menu's Settings link, then the
  // Settings bar's Fares tab. Returns the version ID the workspace opened with.
  async function enterFaresThroughSettings(page) {
    await logIn(page);
    await waitForLiveView(page);

    const versionId = await selectVersion(page, VERSION_NAME);
    const trigger = page.locator("#user-menu [data-user-menu-trigger]");
    const settings = page.locator("#user-menu-panel #settings-link");

    await expect(async () => {
      if (!(await settings.isVisible())) await trigger.click();

      await expect(settings).toBeVisible({ timeout: 2000 });
    }).toPass({ timeout: 20000 });

    await expect(settings).toHaveAttribute("href", `/gtfs/${versionId}/settings`);
    await settings.click();
    await page.waitForURL(new RegExp(`/gtfs/${versionId}/settings$`));
    await waitForLiveView(page);
    await expect(page.locator("#settings-overview")).toBeVisible();

    await expect(async () => {
      if (!/\/settings\/fares$/.test(new URL(page.url()).pathname)) {
        await page.locator("#settings-tab-fares").click();
      }

      await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/settings/fares$`), {
        timeout: 3000,
      });
    }).toPass({ timeout: 25000 });

    await waitForLiveView(page);

    await expect(page.locator("#fares-tab-zones")).toHaveAttribute("aria-current", "page");
    await expect(page.locator("#fare-zones-panel")).toBeAttached();

    return versionId;
  }

  // The rows the server marks checked are the selection, so the list is the
  // readable shape of what a box, a click or Space selected.
  function selectedRows(page) {
    return page.locator("#fare-zone-stops tr", {
      has: page.locator('input[type="checkbox"]:checked'),
    });
  }

  // A dragged box: the pointer must go down on the canvas itself, so callers
  // start clear of the frame's controls. Intermediate moves are the pointermove
  // events the hook draws the box from.
  async function dragOnMap(page, start, end) {
    await page.mouse.move(start.x, start.y);
    await page.mouse.down();
    await page.mouse.move((start.x + end.x) / 2, (start.y + end.y) / 2, { steps: 8 });
    await page.mouse.move(end.x, end.y, { steps: 8 });
    await page.mouse.up();
  }

  // The map pane's transform is the pan's offset in container pixels, so a box
  // drawn after a pan is placed by the offset the map actually moved rather than
  // by the mouse delta an inertial release can overshoot.
  async function mapPaneOffset(page) {
    return page.evaluate(() => {
      const pane = document.querySelector("#fare-zone-map .leaflet-map-pane");
      if (!pane) throw new Error("the map pane is not rendered");
      const matrix = new DOMMatrixReadOnly(getComputedStyle(pane).transform);
      return { x: matrix.m41, y: matrix.m42 };
    });
  }

  async function settledPaneOffset(page) {
    let previous = await mapPaneOffset(page);

    for (let attempt = 0; attempt < 20; attempt += 1) {
      await page.waitForTimeout(150);
      const current = await mapPaneOffset(page);
      if (Math.abs(current.x - previous.x) < 0.5 && Math.abs(current.y - previous.y) < 0.5) {
        return current;
      }
      previous = current;
    }

    return previous;
  }

  // Tab until the focused element matches the selector. The journey walks the
  // real tab order instead of focusing a control directly, so the cap only fails
  // loudly when a control is unreachable by keyboard.
  async function tabTo(page, selector, { steps = 250 } = {}) {
    for (let step = 0; step < steps; step += 1) {
      await page.keyboard.press("Tab");
      const reached = await page.evaluate(
        (target) => Boolean(document.activeElement?.matches(target)),
        selector,
      );
      if (reached) return;
    }

    throw new Error(`Tab never reached ${selector} in ${steps} steps`);
  }

  // Writes the scale measurement beside the captures, so branch review's run
  // refreshes it with the machine it actually measured on.
  function writeScaleMeasurement(testInfo, record) {
    const dir = CAPTURE_DIR || testInfo.outputPath();

    mkdirSync(dir, { recursive: true });
    writeFileSync(resolve(dir, "map-scale.json"), `${JSON.stringify(record, null, 2)}\n`);

    return resolve(dir, "map-scale.json");
  }

  test("entry reaches the Zones tab through Settings", async ({ page }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);

    const versionId = await enterFaresThroughSettings(page);

    await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/settings/fares$`));
    await expect(page.locator("#fares-tab-zones")).toHaveAttribute("aria-current", "page");
    await expect(page.locator("#fare-zones-panel")).toBeAttached();
    await expect(page.locator("#fare-zone-stage-title")).toHaveText("All stops");
    await expect(page.locator("#fare-zone-inventory")).toBeVisible();
    // The entry opened the fixture's own version, not the organization's default.
    await expect(page.locator("#gtfs-version-trigger")).toHaveAttribute(
      "aria-label",
      `Version, ${VERSION_NAME}`,
    );
    await expect(page.locator("#fare-zone-map [data-map-canvas]")).toHaveAttribute(
      "data-map-state",
      "ready",
    );

    await capture(page, testInfo, "journey-zones-1440", { fullPage: false });
  });

  test("a box selects the west cluster and a pan keeps it", async ({ page }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await enterFaresThroughSettings(page);

    const frame = page.locator("#fare-zone-map");
    const canvas = page.locator("#fare-zone-map [data-map-canvas]");

    await expect(canvas).toHaveAttribute("data-map-state", "ready");
    await expect(canvas).toHaveAttribute("data-point-count", "26");

    await page.locator("#fare-zone-map [data-map-fit]").click();
    await expect(page.locator("#fare-zone-map [data-map-mode='select']")).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    // The fitted frame centres the fixture's bounds, and only the eight west stops
    // sit west of the midpoint longitude. The box starts left of the westmost stop
    // and below the frame's mode controls, and ends on the frame's centre column.
    const box = await frame.boundingBox();
    const first = { x: box.x + 6, y: box.y + 70 };
    const half = { x: box.x + box.width / 2, y: box.y + box.height - 6 };

    await dragOnMap(page, first, half);

    await expect(page.locator("#fare-zone-selection-count")).toHaveText("8 stops selected");
    await expect(canvas).toHaveAttribute("data-selected-count", "8");
    await expect(selectedRows(page)).toHaveCount(8);

    for (const name of WEST_STOPS) {
      await expect(selectedRows(page).filter({ hasText: name })).toHaveCount(1);
    }

    await expect(selectedRows(page).filter({ hasText: "Riverside" })).toHaveCount(0);
    await expect(selectedRows(page).filter({ hasText: "Bayline" })).toHaveCount(0);

    await capture(page, testInfo, "journey-zones-box-1440", { fullPage: false });

    // Pan mode owns the drag: the map moves, the hinted mode changes, and the
    // selection is left exactly as it was.
    await page.locator("#fare-zone-map [data-map-mode='pan']").click();
    await expect(page.locator("#fare-zone-map [data-map-mode='pan']")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    await expect(page.locator("#fare-zone-map [data-map-hint]")).toContainText(
      "Drag the map to move.",
    );

    const centre = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    const before = await settledPaneOffset(page);

    await dragOnMap(page, centre, { x: centre.x + 200, y: centre.y });

    await expect(page.locator("#fare-zone-selection-count")).toHaveText("8 stops selected");
    await expect(canvas).toHaveAttribute("data-selected-count", "8");

    const after = await settledPaneOffset(page);
    const moved = { x: after.x - before.x, y: after.y - before.y };

    expect(Math.round(moved.x)).toBeGreaterThanOrEqual(150);
    expect(Math.abs(Math.round(moved.y))).toBeLessThan(60);

    await capture(page, testInfo, "journey-zones-panned-1440", { fullPage: false });

    // Select mode owns the drag again, and the box's corners are projected after
    // the pan, so a box over the cluster's moved position selects exactly the same
    // eight stops rather than the pixels the cluster used to occupy.
    await page.locator("#fare-zone-map [data-map-mode='select']").click();
    await dragOnMap(
      page,
      { x: first.x + moved.x, y: first.y + moved.y },
      { x: half.x + moved.x, y: half.y + moved.y },
    );

    await expect(page.locator("#fare-zone-selection-count")).toHaveText("8 stops selected");
    await expect(canvas).toHaveAttribute("data-selected-count", "8");
    await expect(selectedRows(page)).toHaveCount(8);

    for (const name of WEST_STOPS) {
      await expect(selectedRows(page).filter({ hasText: name })).toHaveCount(1);
    }

    await capture(page, testInfo, "journey-zones-box-panned-1440", { fullPage: false });
  });

  test("the keyboard alone assigns a stop", async ({ page, context }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await enterFaresThroughSettings(page);

    const firstRow = page.locator("#fare-zone-stops tr").first();

    await expect(firstRow).toContainText("Bayline 1");

    // Tab to the first row's checkbox and Space selects it.
    await tabTo(page, "#fare-zone-stops tr:first-child input[type='checkbox']");
    await page.keyboard.press("Space");

    await expect(page.locator("#fare-zone-selection-count")).toHaveText("1 stop selected");

    // Tab on to Assign zone and open it with Enter.
    await tabTo(page, "#fare-zone-assign-selection");
    await page.keyboard.press("Enter");

    const dialog = page.locator("#fare-zone-assignment-dialog");

    await expect(dialog).toBeVisible();
    await expect(page.locator("#fare-zone-assignment-target")).toHaveValue("A");

    // The review's own focus starts on Keep selection; Tab walks the dialog's
    // focus order (Keep selection, Save assignments, body, the target select).
    await tabTo(page, "#fare-zone-assignment-target", { steps: 12 });

    // A closed native `<select>` ignores arrow keys in headless Chromium on this
    // host, so the zone is chosen with the control's own type-ahead: the option's
    // first letter selects it and fires the change the review is rebuilt from.
    await page.keyboard.press("e");

    await expect(page.locator("#fare-zone-assignment-target")).toHaveValue("B");
    await expect(page.locator("#fare-zone-assignment-summary")).toContainText(
      "1 assignment will change",
    );
    await expect(page.locator("#fare-zone-assignment-row-1")).toContainText("→ B");

    await capture(page, testInfo, "journey-zones-assignment-1440", { fullPage: false });

    await tabTo(page, "#fare-zone-assignment-dialog-confirm", { steps: 12 });
    await page.keyboard.press("Enter");

    await expect(page.locator("#fare-zone-saved")).toContainText(
      "1 stop assigned to Eastbank.",
    );
    await expect(firstRow).toContainText("Eastbank");

    // Tabbing scrolled the list, so the capture returns to the callout the save
    // left behind.
    await page.locator("#fare-zone-saved").scrollIntoViewIfNeeded();

    await capture(page, testInfo, "journey-zones-keyboard-saved-1440", { fullPage: false });

    // A second, freshly loaded page reads the stored zone: the save is not this
    // socket's state.
    const reloaded = await context.newPage();

    await reloaded.setViewportSize(DESKTOP);
    await routeBlankTiles(reloaded);
    await openFares(reloaded, "zones");
    await expect(
      reloaded.locator("#fare-zone-stops tr").filter({ hasText: "Bayline 1" }),
    ).toContainText("Eastbank");

    // Undo restores the zone the save replaced, and the reloaded page sees it.
    await page.locator("#fare-zone-undo").click();

    await expect(page.locator("#fare-zone-saved")).toContainText("Change undone.");
    await expect(firstRow).toContainText("Unassigned");

    await reloaded.reload();
    await waitForLiveView(reloaded);
    await expect(
      reloaded.locator("#fare-zone-stops tr").filter({ hasText: "Bayline 1" }),
    ).toContainText("Unassigned");

    await page.locator("#fare-zone-saved").scrollIntoViewIfNeeded();

    await capture(page, testInfo, "journey-zones-keyboard-undone-1440", { fullPage: false });

    await reloaded.close();
  });

  test("a failed map offers both ways out and rehydrates on retry", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await page.route("**/map/tiles/**", (route) => route.fulfill({ status: 500, body: "" }));
    await enterFaresThroughSettings(page);

    const canvas = page.locator("#fare-zone-map [data-map-canvas]");

    // The fallback replaces the frame, and the legend and the complete list stay.
    await expect(page.locator("#fare-zone-map")).toHaveCount(0);
    await expect(page.locator("#fare-zone-map-unavailable")).toBeVisible();
    await expect(page.locator("#fare-zone-map-unavailable")).toContainText(
      "The map is unavailable",
    );
    await expect(page.locator("#fare-zone-map-retry")).toHaveText("Retry map");
    await expect(page.locator("#fare-zone-stop-list")).toBeVisible();

    await capture(page, testInfo, "journey-zones-fallback-1440", { fullPage: false });

    // Use stop list is the fallback's other way out, and the list selects as it
    // always does.
    await page.locator("#fare-zone-map-use-list").click();

    await expect(page.locator("#fare-zone-map-unavailable")).toHaveCount(0);
    await expect(page.locator("#fare-zone-stop-list")).toBeVisible();

    await page
      .locator("#fare-zone-stops tr")
      .filter({ hasText: "Bayline 2" })
      .locator('input[type="checkbox"]')
      .check();

    await expect(page.locator("#fare-zone-selection-count")).toHaveText("1 stop selected");

    // Tiles answer again, and the stage returns to Map + list, which still holds
    // the failed state until Retry map is chosen.
    await page.unroute("**/map/tiles/**");
    await routeBlankTiles(page);
    await page.locator('label[for="fare-zone-view-option-map"]').click();

    await expect(page.locator("#fare-zone-map-retry")).toBeVisible();

    await page.locator("#fare-zone-map-retry").click();

    await expect(canvas).toHaveAttribute("data-map-state", "ready");
    await expect(canvas).toHaveAttribute("data-point-count", "26");
    // The fresh mount hydrated the selection made while the map was gone.
    await expect(canvas).toHaveAttribute("data-selected-count", "1");
    await expect(page.locator("#fare-zone-selection-count")).toHaveText("1 stop selected");

    await capture(page, testInfo, "journey-zones-retry-1440", { fullPage: false });
  });

  test("returning from Fare rules re-mounts the map with the selection", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await enterFaresThroughSettings(page);

    const canvas = page.locator("#fare-zone-map [data-map-canvas]");

    await expect(canvas).toHaveAttribute("data-map-state", "ready");

    await page
      .locator("#fare-zone-stops tr")
      .filter({ hasText: "Bayline 3" })
      .locator('input[type="checkbox"]')
      .check();

    await expect(canvas).toHaveAttribute("data-selected-count", "1");

    // The panel that owns the map leaves the document on the other tab, so the
    // returning hook is a new mount that hydrates from its own reply (CR-8).
    await openTab(page, "rules");
    await expect(page.locator("#fare-zone-map")).toHaveCount(0);

    await openTab(page, "zones");

    await expect(canvas).toHaveAttribute("data-map-state", "ready");
    await expect(canvas).toHaveAttribute("data-point-count", "26");
    await expect(canvas).toHaveAttribute("data-selected-count", "1");
    await expect(page.locator("#fare-zone-selection-count")).toHaveText("1 stop selected");

    await capture(page, testInfo, "journey-zones-tab-return-1440", { fullPage: false });
  });

  test("every tab fits 320 x 800", async ({ page }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await enterFaresThroughSettings(page);

    await page.setViewportSize(NARROW);

    for (const tab of ["zones", "rules", "checks"]) {
      if (tab !== "zones") await openTab(page, tab);

      await expect(page.locator(`#fare-${tab}-panel`)).toBeAttached();
      expect(await bodyFitsViewport(page), `body overflows on the ${tab} tab`).toBe(true);

      await capture(page, testInfo, `journey-${tab}-320`, { fullPage: false });
    }
  });

  test("the 10,000-stop version reaches a ready map", async ({ page }, testInfo) => {
    // The payload and the draw are the measurement this case exists for, so the
    // case's own deadline is longer than a normal page's.
    testInfo.setTimeout(180_000);

    await page.setViewportSize(DESKTOP);
    await routeBlankTiles(page);
    await logIn(page);
    await waitForLiveView(page);

    const versionId = await selectVersion(page, "Browser Fare Zones Scale Version");
    const startedAt = Date.now();

    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);

    const canvas = page.locator("#fare-zone-map [data-map-canvas]");

    await expect(canvas).toHaveAttribute("data-map-state", "ready", { timeout: 120_000 });
    await expect(canvas).toHaveAttribute("data-point-count", "10000");

    const elapsedMs = Date.now() - startedAt;
    const artifact = writeScaleMeasurement(testInfo, {
      version: "Browser Fare Zones Scale Version",
      version_id: versionId,
      points: 10_000,
      elapsed_ms: elapsedMs,
      method:
        "Date.now() before page.goto for /gtfs/<id>/settings/fares until #fare-zone-map [data-map-canvas] reported data-map-state=ready",
      viewport: `${DESKTOP.width}x${DESKTOP.height}`,
      user_agent: await page.evaluate(() => navigator.userAgent),
      measured_at: new Date().toISOString(),
    });

    expect(elapsedMs).toBeGreaterThan(0);
    expect(artifact.endsWith("map-scale.json")).toBe(true);

    await capture(page, testInfo, "journey-zones-scale-1440", { fullPage: false });
  });
});
