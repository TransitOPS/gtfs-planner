// Garages, Fleet and operations-export browser journey (EV-18, step 18).
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`, so `GtfsPlanner.BrowserGeocoding` replaces the Mox
// geocoding mock inside the server. Every run derives its own asset names and
// vehicle numbers, so the journey can be repeated against the same seeded
// database as long as the reset ran first.
import { test, expect } from "@playwright/test";
import fs from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bodyFitsViewport, readZipTextMember } from "./browser_helpers";

// The Playwright runner starts in `assets/`, so repository-relative inputs are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser E2E Version";
const ORGANIZATION_NAME = "Browser Test Org";

const GARAGE_FIXTURE = resolve(REPO_ROOT, "test/fixtures/tods/stops_supplement.txt");
const VEHICLE_FIXTURE = resolve(REPO_ROOT, "test/fixtures/tods/tods_example_vehicles.txt");

const DESKTOP = { width: 1440, height: 1000 };
const MOBILE = { width: 375, height: 812 };

// The deterministic result `GtfsPlanner.BrowserGeocoding` returns for any query
// of at least three characters.
const ADDRESS_QUERY = "Depot";
const ADDRESS_RESULT = "120 Depot Road, Cedar Valley";
const ADDRESS_LAT = "44.4759";
const ADDRESS_LON = "-73.2121";

// A public stop in "Browser E2E Version": a garage carrying this ID blocks the
// operations export until its ID is corrected.
const CONFLICTING_GARAGE_ID = "BROWSER_STATION";

const FILE_INPUT = "#tods-file-upload-input input";

// With no garages the first-use panel carries the create action; otherwise the
// page header does. Only one of the two is ever on the page.
const ADD_GARAGE = "#add-garage, #add-garage-empty";

// The same holds for vehicles: with none, the first-use panel carries Add vehicles.
const ADD_VEHICLES = "#add-vehicles-header, #add-vehicles";

// ── shared helpers ─────────────────────────────────────────────────────────

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// The seeded database names its published version, so the journey selects it
// the way the diagram and catalog journeys do: ordinary login, ordinary panel.
async function currentVersionId(page, name = VERSION_NAME) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function openMovedPage(page, path, name = VERSION_NAME) {
  const versionId = await currentVersionId(page, name);
  await page.goto(`/gtfs/${versionId}${path}`);
  return versionId;
}

// A click that lands before the LiveView joins is dropped, so an action that is
// not wrapped in its own retry waits for the mounted view first.
// A click sent before the view has joined its channel is dropped, and an open
// socket does not mean the join finished: the joined view carries `phx-connected`.
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

// The drawer slides in over 300ms. Capturing before the panel settles
// photographs a partially transformed panel, so the wait requires the panel's
// right edge to sit on the viewport edge and its animation to have finished.
async function settleDrawer(page, id) {
  const panel = page.locator(`#${id}`);
  await panel.waitFor({ state: "visible" });
  await page.waitForFunction(
    (selector) => {
      const element = document.querySelector(selector);
      if (!element) return false;

      const rect = element.getBoundingClientRect();
      const settled =
        Math.abs(rect.right - window.innerWidth) <= 2 && rect.left < window.innerWidth;
      const stillMoving = element
        .getAnimations()
        .some((animation) => animation.playState === "running");

      return settled && !stillMoving;
    },
    `#${id}`,
    { timeout: 8000 },
  );
}

async function openDrawer(page, trigger, id) {
  await expect(async () => {
    await page.locator(trigger).click();
    await expect(page.locator(`#${id}-overlay`)).toHaveAttribute("data-open", "true", {
      timeout: 2000,
    });
  }).toPass({ timeout: 15000 });

  await settleDrawer(page, id);
}

// LiveView starts an upload from the input's change event, which only reaches the
// server once the input holds an upload ref.
async function setUpload(page, file) {
  const input = page.locator(FILE_INPUT);

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await input.waitFor({ state: "attached" });
    await expect(input).toHaveAttribute("data-phx-upload-ref", /.+/, { timeout: 5000 });
    await input.setInputFiles(file);

    try {
      await expect(page.locator("#tods-import-preview")).toBeVisible({ timeout: 5000 });
      return;
    } catch (error) {
      if (attempt === 3) throw error;
    }
  }
}

async function createGarage(page, versionId, { name, garageId, lat, lon }) {
  await page.goto(`/gtfs/${versionId}/settings/garages`);
  await openDrawer(page, ADD_GARAGE, "garage-drawer");

  await page.fill("#garage_name", name);
  // The name field validates on blur, which is also when a new garage derives
  // its default ID.
  await page.keyboard.press("Tab");
  await expect(page.locator("#garage_garage_id")).not.toHaveValue("");

  if (garageId) await page.fill("#garage_garage_id", garageId);

  await page.fill("#garage_lat", lat ?? ADDRESS_LAT);
  await page.fill("#garage_lon", lon ?? ADDRESS_LON);
  await page.locator("#garage-save").click();
  await expect(page.locator("#garage-notice")).toHaveText(`${name} saved.`);
}

// A state change paints through a CSS transition, so a capture taken while the
// transition runs shows the previous paint. Wait for the transitions of the
// changed controls to finish before capturing.
async function settleTransitions(page, selector) {
  await page.waitForFunction(
    (sel) => {
      const elements = [...document.querySelectorAll(sel)];

      return (
        elements.length > 0 &&
        elements.every((element) =>
          element.getAnimations().every((animation) => animation.playState !== "running"),
        )
      );
    },
    selector,
    { timeout: 8000 },
  );
}

async function activeElementId(page) {
  return page.evaluate(() => document.activeElement?.id ?? null);
}

async function focusVisible(page) {
  return page.evaluate(() => {
    const element = document.activeElement;
    return Boolean(element && element.matches(":focus-visible"));
  });
}

// Reaches a control with real Tab presses, so the browser treats the following
// activation as keyboard use and paints the visible focus indicator.
async function tabTo(page, id, limit = 90) {
  await page.evaluate(() => document.activeElement?.blur?.());

  for (let presses = 1; presses <= limit; presses += 1) {
    await page.keyboard.press("Tab");
    if ((await activeElementId(page)) === id) return presses;
  }

  return null;
}

async function measureTargets(page, selectors) {
  const measured = [];

  for (const selector of selectors) {
    const locator = page.locator(selector);
    const count = await locator.count();

    for (let index = 0; index < count; index += 1) {
      const box = await locator.nth(index).boundingBox();
      measured.push({
        selector,
        index,
        width: box ? Math.round(box.width) : null,
        height: box ? Math.round(box.height) : null,
      });
    }
  }

  return measured;
}

// Activation areas are at least 44px. The sample must contain real controls: an
// empty loop would pass without observing anything. Checkbox labels carry the
// 44px area while the input inside them is the browser's own 24px box, so the
// wrapper label is what this samples.
async function expectActivationTargets(page, selectors) {
  const measured = await measureTargets(page, selectors);

  expect(measured.length, `no controls matched ${selectors.join(", ")}`).toBeGreaterThan(0);

  for (const target of measured) {
    const label = `${target.selector}[${target.index}]`;
    expect(target.height, `${label} must be at least 44px tall`).toBeGreaterThanOrEqual(44);
    expect(target.width, `${label} must be at least 44px wide`).toBeGreaterThanOrEqual(44);
  }

  return measured;
}

async function vehicleRows(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("#vehicles-table tr")].map((row) => ({
      id: row.querySelector("button")?.textContent?.trim() ?? null,
      selected: Boolean(row.querySelector("input[type='checkbox']")?.checked),
      type: row.querySelector("td[data-label='Type']")?.textContent?.trim() ?? null,
      garage: row.querySelector("td[data-label='Garage']")?.textContent?.trim() ?? null,
    })),
  );
}

// ── journey ────────────────────────────────────────────────────────────────

test.describe("Garages, Fleet and operations export", () => {
  test("Settings opens Garages and an address choice persists its coordinates", async ({
    page,
  }, testInfo) => {
    test.setTimeout(120_000);

    await logIn(page);
    const versionId = await currentVersionId(page);

    // The Settings overview is the in-app entry to the moved page, which returns
    // by the Settings link and says what its garages apply to.
    await page.goto(`/gtfs/${versionId}/settings`);
    await page.locator("#settings-entry-garages a").click();
    await page.waitForURL(new RegExp(`/gtfs/${versionId}/settings/garages$`));
    await expect(page.locator("h1")).toContainText("Garages");
    await expect(page.locator("#settings-nav")).toHaveCount(0);
    await expect(page.locator("#settings-back")).toHaveText("Settings");
    await expect(
      page.locator('#app-header nav[aria-label="Main navigation"] a[aria-current="page"]'),
    ).toHaveCount(0);
    await expect(page.locator("#garages-scope")).toContainText(
      `Applies to every service version at ${ORGANIZATION_NAME}.`,
    );
    await expect(page.locator("#garages-table, #garages-first-use-empty").first()).toBeVisible();

    const attempt = Date.now();
    const name = `Depot ${attempt}`;

    await openDrawer(page, ADD_GARAGE, "garage-drawer");
    await expect(page.locator("#garage-drawer-title")).toHaveText("Create garage");

    await page.fill("#garage_name", name);
    await page.keyboard.press("Tab");
    await expect(page.locator("#garage_garage_id")).not.toHaveValue("");

    // The address search runs the real LiveSelect path against the browser
    // geocoding adapter, so the option and the coordinates it fills are the
    // deterministic pair, not one the journey sets itself.
    const search = page.locator("#garage-address input[type='text']");
    await search.click();
    await search.fill(ADDRESS_QUERY);

    const option = page.locator("#garage-address ul li div[data-idx]").first();
    await expect(option).toHaveText(ADDRESS_RESULT);
    await option.click();

    await expect(page.locator("#garage_lat")).toHaveValue(ADDRESS_LAT);
    await expect(page.locator("#garage_lon")).toHaveValue(ADDRESS_LON);
    await expect(page.locator("#garage-address-unavailable")).toHaveCount(0);

    await page.setViewportSize(DESKTOP);
    await page.screenshot({ path: testInfo.outputPath("garage-drawer-1440x1000.png") });

    await page.locator("#garage-save").click();
    await expect(page.locator("#garage-notice")).toHaveText(`${name} saved.`);

    const row = page.locator("#garages-table tr").filter({ hasText: name });
    await expect(row).toHaveCount(1);
    await expect(row).toContainText(ADDRESS_RESULT);
    await expect(row).toContainText(ADDRESS_LAT);
    await expect(row).toContainText(ADDRESS_LON);

    // Both the address and the coordinates are stored, so a reload redisplay both.
    await page.reload();
    const reloaded = page.locator("#garages-table tr").filter({ hasText: name });
    await expect(reloaded).toHaveCount(1);
    await expect(reloaded).toContainText(ADDRESS_RESULT);
    await expect(reloaded).toContainText(ADDRESS_LAT);
    await expect(reloaded).toContainText(ADDRESS_LON);
  });

  test("the TODS import previews the fixture's counts and reasons and persists only its accepted rows", async ({
    page,
  }, testInfo) => {
    test.setTimeout(120_000);

    await logIn(page);
    await openMovedPage(page, "/settings/garages");
    await expect(page.locator("#garages-table, #garages-first-use-empty").first()).toBeVisible();

    await openDrawer(page, "#import-tods", "tods-import-drawer");
    await setUpload(page, GARAGE_FIXTURE);

    await expect(page.locator("#tods-import-preview")).toContainText("Review stops_supplement.txt");
    await expect(page.locator("#tods-import-count-add")).toHaveText("2");
    await expect(page.locator("#tods-import-count-update")).toHaveText("0");
    await expect(page.locator("#tods-import-count-skipped")).toHaveText("3");
    await expect(page.locator("#tods-import-count-error")).toHaveText("0");

    // The skipped rows are the fixture's own rows, numbered from the file, with
    // the reasons `Tods.classify/1` returns.
    const skipped = page.locator("#tods-import-skipped li");
    await expect(skipped).toHaveCount(3);
    await expect(skipped.nth(0)).toContainText(
      "Row 4 · garage-waypoint · Not a garage (TODS_location_type: waypoint).",
    );
    await expect(skipped.nth(1)).toContainText(
      "Row 5 · stop_401 · Changes or adds a public stop; not imported.",
    );
    await expect(skipped.nth(2)).toContainText(
      "Row 6 · garage_old · Requests a deletion; deletions are not imported.",
    );
    await expect(page.locator("#tods-import-ignored")).toContainText("location_type");
    await expect(page.locator("#tods-import-ignored")).toContainText("zone_id");

    await expect(page.locator("#apply-tods-import")).toBeEnabled();
    await expect(page.locator("#apply-tods-import")).toHaveText("Import 2 garages");

    await page.setViewportSize(DESKTOP);
    await page.screenshot({ path: testInfo.outputPath("garages-import-preview-1440x1000.png") });

    await page.locator("#apply-tods-import").click();
    await expect(page.locator("#garage-notice")).toHaveText("Garages imported: 2 added, 0 updated.");
    await expect(page.locator("#tods-import-drawer-overlay")).toHaveAttribute("data-open", "false");

    const table = page.locator("#garages-table");
    await expect(table).toContainText("garage_main");
    await expect(table).toContainText("garage_east");
    await expect(table).not.toContainText("garage-waypoint");
    await expect(table).not.toContainText("stop_401");
    await expect(table).not.toContainText("garage_old");

    await page.screenshot({ path: testInfo.outputPath("garages-with-data-1440x1000.png") });
  });

  test("Fleet adds a 10-hour type, a 15-vehicle group, a 3-vehicle garage change and a persisted filter", async ({
    page,
  }, testInfo) => {
    test.setTimeout(240_000);

    await logIn(page);
    const attempt = Date.now();
    const versionId = await currentVersionId(page);
    const garageName = `Bulk depot ${attempt}`;
    const typeName = `Ten hour type ${attempt}`;
    const rangeBase = 2000000 + (attempt % 800000);
    const rangeLast = rangeBase + 14;

    await createGarage(page, versionId, { name: garageName });
    await page.goto(`/gtfs/${versionId}/settings/fleet`);
    await expect(page.locator("h1")).toContainText("Fleet");

    // A type with a 10-hour limit: the drawer saves it and the matrix lists it.
    await openDrawer(page, "#add-vehicle-type", "vehicle-type-drawer");

    await page.fill("#vehicle_type_name", typeName);
    await page.fill("#vehicle_type_max_out_hours", "10");
    await page.getByRole("button", { name: "Save type" }).click();
    await expect(page.locator("#vehicle-type-notice")).toHaveText(`${typeName} saved.`);
    await expect(page.locator("#vehicle-types-table")).toContainText(typeName);
    await expect(page.locator("#vehicle-types-table")).toContainText("Up to 10 hours away");

    // Editing it redisplays the stored limit as hours.
    await page.locator("#vehicle-types-table button", { hasText: typeName }).click();
    await settleDrawer(page, "vehicle-type-drawer");
    await expect(page.locator("#vehicle_type_max_out_hours")).toHaveValue("10");
    await page.locator("#vehicle-type-drawer-close").click();
    await expect(page.locator("#vehicle-type-drawer-overlay")).toHaveAttribute("data-open", "false");

    // The saved type is selectable from the vehicle drawer.
    await openDrawer(page, ADD_VEHICLES, "vehicle-drawer");
    await expect(
      page.locator("#vehicle_vehicle_type_id option").filter({ hasText: typeName }),
    ).toHaveCount(1);

    await page.locator("label[for='vehicle-mode-option-range']").click();
    await expect(page.locator("#vehicle-mode-option-range")).toBeChecked();

    await page.fill("#range_first", String(rangeBase));
    await page.fill("#range_last", String(rangeLast));
    await page.selectOption("#range_vehicle_type_id", { label: typeName });
    await expect(page.locator("#range-preview")).toHaveText(
      `Adds ${rangeBase}–${rangeLast} (15 vehicles)`,
    );

    await page.setViewportSize(DESKTOP);
    await page.screenshot({ path: testInfo.outputPath("fleet-numbered-group-1440x1000.png") });

    await page.locator("#vehicle-range-form").getByRole("button", { name: "Add vehicles" }).click();
    await expect(page.locator("#vehicle-notice")).toHaveText("15 vehicles added.");
    await expect(page.locator("#vehicles-table tr")).toHaveCount(15);

    const added = await vehicleRows(page);
    const addedIds = added.map((row) => row.id);
    expect(new Set(addedIds).size).toBe(15);
    expect(addedIds.sort()).toEqual(
      Array.from({ length: 15 }, (_, index) => String(rangeBase + index)).sort(),
    );

    // Filtering by the type shows exactly the new group.
    await page.selectOption("#vehicle-filters #type", { label: typeName });
    await expect(page.locator("#vehicles-count")).toContainText(/15 of \d+ vehicles/);
    await expect(page.locator("#vehicles-table tr")).toHaveCount(15);

    // Three filtered vehicles get the garage; their types and every other row stay.
    const checkboxes = page.locator("#vehicles-table td[data-label='Select'] input");
    await checkboxes.nth(0).click();
    await checkboxes.nth(1).click();
    await checkboxes.nth(2).click();

    await expect(page.locator("#bulk-bar")).toBeVisible();
    await expect(page.locator("#bulk-bar-count")).toHaveText("3 vehicles selected");

    const selectedIds = (await vehicleRows(page)).filter((row) => row.selected).map((row) => row.id);
    expect(selectedIds).toHaveLength(3);

    await settleTransitions(page, "#vehicles-table input[type='checkbox']");
    await page.locator("#bulk-bar").scrollIntoViewIfNeeded();
    await page.screenshot({ path: testInfo.outputPath("fleet-bulk-bar-1440x1000.png") });

    await openDrawer(page, "#bulk-set-garage", "bulk-drawer");
    await page.selectOption("#bulk_value", { label: garageName });
    await page.locator("#bulk-form").getByRole("button", { name: "Set garage" }).click();

    await expect(page.locator("#vehicle-notice")).toHaveText("Garage updated on 3 vehicles.");
    await expect(page.locator("#bulk-bar")).toHaveCount(0);

    const afterBulk = await vehicleRows(page);
    expect(afterBulk).toHaveLength(15);

    for (const row of afterBulk) {
      expect(row.type).toBe(typeName);

      if (selectedIds.includes(row.id)) {
        expect(row.garage, `${row.id} must keep the chosen garage`).toBe(garageName);
      } else {
        expect(row.garage, `${row.id} must stay unassigned`).toBe("No garage");
      }
    }

    // The garage filter lives in the URL and survives a reload.
    await page.selectOption("#vehicle-filters #garage", { label: garageName });
    await expect(page.locator("#vehicles-count")).toContainText(/3 of \d+ vehicles/);
    await expect(page.locator("#vehicles-table tr")).toHaveCount(3);

    const filteredUrl = new URL(page.url());
    const garageParam = filteredUrl.searchParams.get("garage");
    expect(garageParam).toMatch(/^[0-9a-f-]{36}$/);

    await page.reload();
    await expect(page.locator("#vehicle-filters #garage")).toHaveValue(garageParam);
    await expect(page.locator("#vehicles-table tr")).toHaveCount(3);

    const filteredRows = await vehicleRows(page);
    expect(filteredRows.map((row) => row.garage)).toEqual([garageName, garageName, garageName]);
  });

  test("both pages fit 375x812, keep 44px activation areas and stack or scroll their tables", async ({
    page,
  }, testInfo) => {
    test.setTimeout(120_000);

    // This case runs after the Fleet journey above. The browser suite shares one
    // seeded database and one worker, so both tables carry the rows the earlier
    // scenarios created by the time these contracts are measured.
    await logIn(page);
    const versionId = await currentVersionId(page);
    await page.setViewportSize(MOBILE);

    await page.goto(`/gtfs/${versionId}/settings/garages`);
    await expect(page.locator("h1")).toContainText("Garages");
    await expect(page.locator("#garages-table")).toBeVisible();
    expect(await bodyFitsViewport(page), "Garages overflows at 375px").toBe(true);

    // Below the tablet width each garage is a stacked record, so the table needs
    // no horizontal scrolling of its own.
    const stacked = await page.evaluate(() =>
      [...document.querySelectorAll("#garages-table tbody tr")].map(
        (row) => getComputedStyle(row).display,
      ),
    );
    expect(stacked.length, "the garages table must have rows").toBeGreaterThan(0);
    expect(new Set(stacked), "each garage row stacks as a block").toEqual(new Set(["block"]));

    await expectActivationTargets(page, [
      "#import-tods",
      "#add-garage",
      "#settings-back",
      "#garages-table td[data-label='Garage'] button",
      "#garages-table td[data-label='Vehicles'] a",
    ]);
    await page.screenshot({ path: testInfo.outputPath("garages-375x812.png") });

    await page.goto(`/gtfs/${versionId}/settings/fleet`);
    await expect(page.locator("h1")).toContainText("Fleet");
    await expect(page.locator("#vehicles-table")).toBeVisible();
    expect(await bodyFitsViewport(page), "Fleet overflows at 375px").toBe(true);

    // Below the tablet width each vehicle is a card and each type a stacked
    // record, so neither table scrolls sideways.
    const fleetRows = await page.evaluate(() => ({
      vehicles: [...document.querySelectorAll("#vehicles-table tr")].map(
        (row) => getComputedStyle(row).display,
      ),
      types: [...document.querySelectorAll("#vehicle-types-rows tr")].map(
        (row) => getComputedStyle(row).display,
      ),
    }));
    expect(fleetRows.vehicles.length, "the vehicles table must have rows").toBeGreaterThan(0);
    expect(new Set(fleetRows.vehicles), "each vehicle row is a grid card").toEqual(
      new Set(["grid"]),
    );
    expect(new Set(fleetRows.types), "each type row stacks as a block").toEqual(new Set(["block"]));

    await expectActivationTargets(page, [
      "#import-tods",
      "#add-vehicles-header",
      "#settings-back",
      "#add-vehicle-type",
      "#vehicle-types-table th[scope='row'] button",
      // The checkbox input is the browser's own box; the label around it
      // carries the 44px activation area.
      "#vehicles-table-container thead label",
      "#vehicles-table td[data-label='Select'] label",
    ]);
    await page.screenshot({ path: testInfo.outputPath("fleet-375x812.png") });
  });

  test("keyboard opening and closing a drawer returns visible focus to its exact trigger", async ({
    page,
  }) => {
    test.setTimeout(120_000);

    await logIn(page);
    const versionId = await currentVersionId(page);

    await page.goto(`/gtfs/${versionId}/settings/garages`);
    await expect(page.locator("h1")).toContainText("Garages");
    await waitForLiveView(page);

    const garageTrigger = (await page.locator("#add-garage").count())
      ? "add-garage"
      : "add-garage-empty";
    expect(await tabTo(page, garageTrigger), `${garageTrigger} must be keyboard reachable`).not.toBeNull();
    await expect(page.locator(`#${garageTrigger}`)).toBeFocused();
    expect(await focusVisible(page), `${garageTrigger} must show visible focus`).toBe(true);

    await page.keyboard.press("Enter");
    await expect(page.locator("#garage-drawer-overlay")).toHaveAttribute("data-open", "true");
    await page.keyboard.press("Escape");
    await expect(page.locator("#garage-drawer-overlay")).toHaveAttribute("data-open", "false");
    await expect(page.locator(`#${garageTrigger}`)).toBeFocused();
    expect(await focusVisible(page), "focus must be visibly restored").toBe(true);

    await page.goto(`/gtfs/${versionId}/settings/fleet`);
    await expect(page.locator("h1")).toContainText("Fleet");
    await waitForLiveView(page);

    const fleetTrigger = (await page.locator("#add-vehicles-header").count())
      ? "add-vehicles-header"
      : "add-vehicles";
    expect(await tabTo(page, fleetTrigger), `${fleetTrigger} must be keyboard reachable`).not.toBeNull();
    await expect(page.locator(`#${fleetTrigger}`)).toBeFocused();
    expect(await focusVisible(page), `${fleetTrigger} must show visible focus`).toBe(true);

    await page.keyboard.press("Enter");
    await expect(page.locator("#vehicle-drawer-overlay")).toHaveAttribute("data-open", "true");
    await page.keyboard.press("Escape");
    await expect(page.locator("#vehicle-drawer-overlay")).toHaveAttribute("data-open", "false");
    await expect(page.locator(`#${fleetTrigger}`)).toBeFocused();
    expect(await focusVisible(page), "focus must be visibly restored").toBe(true);
  });

  test("a garage/stop ID collision blocks the operations export until the ID is corrected and downloads a real ZIP", async ({
    page,
  }, testInfo) => {
    test.setTimeout(300_000);

    await logIn(page);
    const attempt = Date.now();
    const versionId = await currentVersionId(page);
    const garageName = `Station garage ${attempt}`;
    const correctedGarageId = `garage_station_${attempt}`;

    await createGarage(page, versionId, {
      name: garageName,
      garageId: CONFLICTING_GARAGE_ID,
    });

    // The operations ZIP carries vehicles.txt only when the organization has
    // vehicles, so the journey imports the committed vehicle fixture first.
    await page.goto(`/gtfs/${versionId}/settings/fleet`);
    await openDrawer(page, "#import-tods", "tods-import-drawer");
    await setUpload(page, VEHICLE_FIXTURE);
    await expect(page.locator("#apply-tods-import")).toHaveText("Import 2 vehicles");
    await page.locator("#apply-tods-import").click();
    await expect(page.locator("#vehicle-notice")).toHaveText("Vehicles imported: 2 added, 0 updated.");

    await page.goto(`/gtfs/${versionId}/export?type=operations`);
    await expect(page.locator("#export-type-operations")).toBeChecked();
    await expect(page.locator("#operations-export-note")).toBeVisible();
    await expect(page.locator("#export-inventory")).toContainText("stops_supplement.txt");
    await expect(page.locator("#export-inventory")).toContainText("vehicles.txt");

    await waitForLiveView(page);
    await page.locator("#start-export").click();

    const conflicts = page.locator("#export-conflicts li");
    await expect(conflicts).toHaveCount(1, { timeout: 60_000 });
    await expect(conflicts.first()).toContainText(
      `Garage "${garageName}" (${CONFLICTING_GARAGE_ID}) matches the stop `,
    );
    await expect(page.locator("#export-download-link")).toHaveCount(0);
    await expect(page.locator("#retry-export")).toBeVisible();
    await expect(page.locator("#export-edit-garages")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/settings/garages`,
    );

    await page.setViewportSize(DESKTOP);
    await page.screenshot({ path: testInfo.outputPath("export-conflict-1440x1000.png") });

    // The recovery link itself must reach the moved Garages page, so the
    // correction continues through the conflict panel rather than a fresh URL.
    await page.locator("#export-edit-garages").click();
    await page.waitForURL(new RegExp(`/gtfs/${versionId}/settings/garages$`));
    await expect(page.locator("h1")).toContainText("Garages");
    await expect(page.locator("#settings-back")).toHaveText("Settings");

    // The list says which garage clashes and with which stop.
    await expect(page.locator("#garage-conflicts")).toContainText(garageName);
    await expect(page.locator("#garage-conflicts")).toContainText(CONFLICTING_GARAGE_ID);

    // Correcting the garage ID clears the collision.
    await page
      .locator("#garages-table tr")
      .filter({ hasText: garageName })
      .locator("button")
      .first()
      .click();
    await settleDrawer(page, "garage-drawer");
    await expect(page.locator("#garage_garage_id")).toHaveValue(CONFLICTING_GARAGE_ID);
    await page.fill("#garage_garage_id", correctedGarageId);
    await page.locator("#garage-save").click();
    await expect(page.locator("#garage-notice")).toHaveText(`${garageName} saved.`);
    await expect(page.locator("#garage-conflicts")).toHaveCount(0);

    await page.goto(`/gtfs/${versionId}/export?type=operations`);
    await waitForLiveView(page);

    // The first click can still race the view's join, so the retry is itself
    // retried until the ready artifact appears.
    await expect(async () => {
      await page.locator("#retry-export").click();
      await expect(page.locator("#export-download-link")).toBeVisible({ timeout: 20_000 });
    }).toPass({ timeout: 150_000 });

    await expect(page.locator("#export-conflicts")).toHaveCount(0);

    await page.screenshot({ path: testInfo.outputPath("export-ready-1440x1000.png") });

    const downloadPromise = page.waitForEvent("download");
    await page.locator("#export-download-link").click();
    const download = await downloadPromise;
    const zip = fs.readFileSync(await download.path());

    expect(download.suggestedFilename()).toMatch(/\.zip$/);
    expect(readZipTextMember(zip, "stops_supplement.txt")).toContain(correctedGarageId);
    expect(readZipTextMember(zip, "vehicles.txt")).toContain("vehicle_id,vehicle_label,license_plate");
  });
});
