// Fare editor browser journeys.
//
// Runs against the freshly seeded browser database the repository's Playwright
// configuration already uses (`bin/test-browser`, workers: 1, retries: 0) with
// `BROWSER_E2E=true`. Every seeded version is resolved by its exact name through
// the version panel, so a journey reads the fixture it names instead of
// whichever version is the organization's default.
//
// Step 31 seeds the five versions the editor's journeys draw. This file's `shell`
// block is step 32's: the Fares page shell, its five tabs and the routes between
// the two LiveViews. The following steps add one journey block each, the way
// `fare_zones.spec.js` grew alongside the zone workspace.
import { test, expect } from "@playwright/test";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bodyFitsViewport } from "./browser_helpers.js";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// The five versions `test/support/browser_seed.exs` creates for this package,
// each in the state the editor draws for it.
const VERSIONS = {
  managed: "Browser North Coast Fares Version",
  blank: "Browser Blank Fares Version",
  unmanaged: "Browser Unmanaged V1 Fares Version",
  mismatch: "Browser Fares Mismatch Version",
  gaps: "Browser Fares Gaps Version",
};

// The five tabs and the path each one names, in the order the strip shows them.
const TABS = [
  ["prices", ""],
  ["where", "/where"],
  ["transfers", "/transfers"],
  ["zones", "/zones"],
  ["checks", "/checks"],
];

const DESKTOP = { width: 1440, height: 900, label: "1440" };
const PHONE = { width: 390, height: 844, label: "390" };

// A 1×1 transparent PNG. The zone workspace's map requests tiles, and answering
// them locally keeps a shell journey from depending on the Geoapify plan or on
// network access — the same stub `fare_zones.spec.js` installs.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

// The prototype this shell follows. It lives in the gitignored .specs/ workspace,
// so the reference capture is skipped when the file is not present rather than
// depending on a path that is not checked in.
const REFERENCE_PATH = resolve(
  REPO_ROOT,
  ".specs",
  "29-fares-v1-v2-add-edit",
  "references",
  "fares-editor-prototype.html",
);

const CAPTURE_DIR = process.env.FARE_EDITOR_CAPTURE_DIR;

// ── shared helpers ────────────────────────────────────────────────────────

async function logIn(page) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.waitForSelector("[data-phx-main].phx-connected");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.locator('button:has-text("Log in")').click();
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

// Resolves any seeded version by its exact name through the version panel. The
// panel lists every published version of the organization, so a journey reads
// the fixture it names instead of whichever version is the default.
async function versionIdByName(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

async function capture(page, testInfo, name) {
  let path = testInfo.outputPath(`${name}.png`);

  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    path = resolve(CAPTURE_DIR, `${name}.png`);
  }

  // A drawer slides in over the page, so a capture taken as it arrives shows a
  // half-open panel. Playwright fast-forwards CSS animations so every capture
  // shows the settled state.
  await page.screenshot({ path, fullPage: true, animations: "disabled" });
  return path;
}

// A drawer and its confirm dialog are fixed to the edge of the viewport, so a
// full-page capture — which the Prices tab needs for its whole grid — leaves
// them off the image. Drawer states are captured in the viewport instead.
async function captureDrawer(page, testInfo, name) {
  let path = testInfo.outputPath(`${name}.png`);

  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    path = resolve(CAPTURE_DIR, `${name}.png`);
  }

  await page.screenshot({ path, fullPage: false, animations: "disabled" });
  return path;
}

// Captures the prototype beside the production page, at the viewport the
// comparison is made at.
async function captureReference(page, testInfo, query, name) {
  if (!existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}${query}`);
  await page.waitForLoadState("networkidle");
  await page.screenshot({
    path: testInfo.outputPath(`${name}.png`),
    fullPage: false,
  });
}

// ── shell ─────────────────────────────────────────────────────────────────

// The Fares page shell. The seeded fare editor fixtures are each found by their
// own name and the page opens on each of them without error, the five tabs name
// their own paths, the Zones tab lands on the zone workspace's own LiveView, the
// retired Fare rules path redirects to Where fares apply, and the header carries
// exactly one primary per tab. Every later journey block builds on this.
test("shell", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const found = {};

  for (const [key, name] of Object.entries(VERSIONS)) {
    found[key] = await versionIdByName(page, name);
  }

  // Five distinct versions: a name resolving to another version's row would
  // silently give a journey the wrong fixture.
  expect(new Set(Object.values(found)).size).toBe(Object.keys(VERSIONS).length);

  const versionId = found.managed;

  for (const key of Object.keys(VERSIONS)) {
    await page.goto(`/gtfs/${found[key]}/settings/fares`);
    await waitForLiveView(page);

    await expect(page.locator("h1")).toHaveText("Fares");
    await expect(page).toHaveURL(
      new RegExp(`/gtfs/${found[key]}/settings/fares$`),
    );

    // The journey reached the version it named: the switcher marks it current.
    await expect(
      page.locator(`#gtfs-version-option-${found[key]}`),
    ).toHaveAttribute("aria-current", "true");
  }

  // The page frame: the back link, the lede and the one primary.
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  await expect(page.locator("#fare-editor-page")).toBeAttached();
  await expect(page.locator("#settings-back")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings`,
  );
  await expect(page.locator("#fare-editor-page")).toContainText(
    "What riders pay and which fare each ride charges.",
  );

  // No Settings nav, and the loading skeleton is gone once the fares resolved.
  await expect(page.locator("#settings-nav")).toHaveCount(0);
  await expect(page.locator("#fare-editor-loading")).toHaveCount(0);

  // One primary per view, and it follows the tab.
  for (const [tab, suffix] of [
    ["prices", ""],
    ["where", "/where"],
    ["transfers", "/transfers"],
    ["checks", "/checks"],
  ]) {
    await page.goto(`/gtfs/${versionId}/settings/fares${suffix}`);
    await waitForLiveView(page);

    const primaries = page.locator("#fare-editor-page header button");
    const expected = tab === "checks" ? 0 : 1;

    await expect(primaries).toHaveCount(expected);
  }

  // Every tab names its own path, and exactly one of them is current.
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  for (const [tab, suffix] of TABS) {
    await expect(page.locator(`#fares-tab-${tab}`)).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/settings/fares${suffix}`,
    );
  }

  await expect(page.locator("#fares-tab-prices")).toHaveAttribute(
    "aria-current",
    "page",
  );

  for (const [tab] of TABS.filter(([name]) => name !== "prices")) {
    await expect(page.locator(`#fares-tab-${tab}`)).not.toHaveAttribute(
      "aria-current",
      "page",
    );
  }

  // The Checks tab carries the version's result, so a setup problem stays
  // visible from the other tabs. The seeded managed version is clean, so the
  // mark is a check beside a zero.
  await expect(
    page.locator("#fares-tab-checks #fares-checks-count"),
  ).toHaveText("0");

  // Zones is the other LiveView: the tab lands on the zone workspace's panel.
  await page.locator("#fares-tab-zones").click();
  await expect(page).toHaveURL(
    new RegExp(`/gtfs/${versionId}/settings/fares/zones$`),
    {
      timeout: 15000,
    },
  );
  await waitForLiveView(page);

  await expect(page.locator("#fare-zones-panel")).toBeAttached();
  await expect(page.locator("#fares-tab-zones")).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.locator("#fare-editor-page")).toHaveCount(0);

  // The retired Fare rules path redirects to Where fares apply rather than
  // rendering a tab of its own or 404ing.
  await page.goto(`/gtfs/${versionId}/settings/fares/rules`);
  await waitForLiveView(page);

  await expect(page).toHaveURL(
    new RegExp(`/gtfs/${versionId}/settings/fares/where$`),
  );
  await expect(page.locator("#fares-tab-where")).toHaveAttribute(
    "aria-current",
    "page",
  );

  // A version with no fares at all still opens the shell.
  await page.goto(`/gtfs/${found.blank}/settings/fares`);
  await waitForLiveView(page);

  await expect(page.locator("h1")).toHaveText("Fares");
  await expect(page.locator("#fares-tab-prices")).toHaveAttribute(
    "aria-current",
    "page",
  );

  // ── captures ────────────────────────────────────────────────────────────
  // The shell at both prepared viewports, beside the prototype states it
  // follows, so branch review compares the same page at the same sizes.
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({
      width: viewport.width,
      height: viewport.height,
    });
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);

    await expect(page.locator("#fare-editor-page")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `shell-${viewport.label}`);
  }

  await captureReference(page, testInfo, "?state=prices", "ref-prices");
  await captureReference(page, testInfo, "?state=loading", "ref-loading");
  await captureReference(page, testInfo, "?state=load-error", "ref-load-error");
});

// ── prices ─────────────────────────────────────────────────────────────────

// The Prices tab's fare grid, the save bar's unsaved preview, the conflict
// panel, and the older-format lens. Each state is proved through the DOM the
// LiveView renders — the grid is one cell per fare and rider type named for the
// row it writes, the save bar counts and describes what is unsaved, a concurrent
// change blocks the save until a price is chosen, and the lens tints exactly
// the cells the older format carries.
test("prices", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSIONS.managed);

  // The grid itself: one row per fare, one column per rider type, and the
  // payment method sub-row for a fare the app prices differently.
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  const table = page.locator("#fare-table");
  await expect(table).toBeAttached();
  await expect(page.locator("#fare-table-title")).toHaveText("Fare table");
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");
  await expect(page.locator("#price-local_ride-adult-app")).toHaveValue("$1.25");
  await expect(page.locator("#price-local_ride-child")).toHaveValue("Free");
  await expect(page.locator("#price-save-bar")).toHaveCount(0);

  // Editing one price raises the save bar, which names what is unsaved and how.
  await page.locator("#price-local_ride-adult").fill("1.75");
  await page.locator("#price-local_ride-adult").blur();

  const saveBar = page.locator("#price-save-bar");
  await expect(saveBar).toBeAttached();
  await expect(page.locator("#save-prices")).toHaveText("Save 1 price");
  await expect(saveBar).toContainText("Local ride · Adult $1.50 → $1.75");
  await expect(page.locator("#fares-conflict")).toHaveCount(0);

  // A price `Fares.Money.parse/1` refuses keeps its own text, is marked
  // invalid, and blocks the save rather than being read as a blank.
  await page.locator("#price-local_ride-adult").fill("1..5");
  await page.locator("#price-local_ride-adult").blur();

  await expect(page.locator("#price-local_ride-adult")).toHaveValue("1..5");
  await expect(page.locator("#price-local_ride-adult")).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await expect(page.locator("#save-prices")).toHaveAttribute(
    "aria-disabled",
    "true",
  );
  await expect(saveBar).toContainText("Fix the highlighted price to save.");

  // The lens tints exactly the cells the older format carries: the default
  // rider type on a single ride's own row, and nothing else.
  await page.locator("#price-local_ride-adult").fill("1.75");
  await page.locator("#price-local_ride-adult").blur();

  await page.locator("#fare-lens").check();
  await expect(page.locator("#fare-lens-note")).toBeAttached();

  const tinted = page.locator('#fare-table [data-lens="in"]');
  await expect(tinted).toHaveCount(5);
  await expect(page.locator("#price-local_ride-adult").locator("xpath=..")).toHaveAttribute(
    "data-lens",
    "in",
  );
  await expect(page.locator("#price-local_ride-adult-app").locator("xpath=..")).toHaveAttribute(
    "data-lens",
    "out",
  );
  await expect(page.locator("#price-local_ride-reduced").locator("xpath=..")).toHaveAttribute(
    "data-lens",
    "out",
  );

  await page.locator("#fare-lens").uncheck();
  await expect(page.locator("#price-local_ride-adult").locator("xpath=..")).toHaveAttribute(
    "data-lens",
    "off",
  );

  // Discarding throws the edit away without writing anything.
  await page.locator("#discard-prices").click();
  await expect(page.locator("#price-save-bar")).toHaveCount(0);
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

  // Saving writes the reviewed cell and notes it, with the Undo beside it.
  await page.locator("#price-local_ride-adult").fill("1.75");
  await page.locator("#price-local_ride-adult").blur();
  await page.locator("#save-prices").click();

  await expect(page.locator("#fare-note")).toContainText("1 price saved");
  await expect(page.locator("#undo-prices")).toBeAttached();
  await expect(page.locator("#price-save-bar")).toHaveCount(0);
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.75");

  // Undo puts the reviewed amount back.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-note")).toContainText("Change undone.");
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

  // ── captures ────────────────────────────────────────────────────────────
  // The grid and each of its states at both prepared viewports, beside the
  // prototype states they follow.
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });

    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);
    await expect(page.locator("#fare-table")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prices-${viewport.label}`);

    // The save bar with an unsaved price, the editing state.
    await page.locator("#price-local_ride-adult").fill("1.75");
    await page.locator("#price-local_ride-adult").blur();
    await expect(page.locator("#price-save-bar")).toBeAttached();
    await capture(page, testInfo, `prices-editing-${viewport.label}`);
    await page.locator("#discard-prices").click();

    // The invalid state: a price the parser refuses.
    await page.locator("#price-local_ride-adult").fill("1..5");
    await page.locator("#price-local_ride-adult").blur();
    await expect(page.locator("#save-prices")).toHaveAttribute(
      "aria-disabled",
      "true",
    );
    await capture(page, testInfo, `prices-invalid-${viewport.label}`);
    await page.locator("#discard-prices").click();

    // The saved state: the note with its Undo beside it.
    await page.locator("#price-local_ride-adult").fill("1.75");
    await page.locator("#price-local_ride-adult").blur();
    await page.locator("#save-prices").click();
    await expect(page.locator("#fare-note")).toContainText("1 price saved");
    await capture(page, testInfo, `prices-saved-${viewport.label}`);
    await page.locator("#undo-prices").click();
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

    // The conflict panel, reached the way it happens: a second editor on the
    // same version saves the cell between this editor's edit and their save.
    // The second tab is the same signed-in session, so it is the same operator
    // on another tab rather than a fixture-only shortcut.
    const second = await page.context().newPage();
    await second.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(second);

    await page.locator("#price-local_ride-adult").fill("1.75");
    await page.locator("#price-local_ride-adult").blur();

    await second.locator("#price-local_ride-adult").fill("1.60");
    await second.locator("#price-local_ride-adult").blur();
    await second.locator("#save-prices").click();
    await expect(second.locator("#fare-note")).toContainText("1 price saved");

    await page.locator("#save-prices").click();
    await expect(page.locator("#fares-conflict")).toBeAttached();
    await expect(page.locator("#save-prices")).toHaveAttribute(
      "aria-disabled",
      "true",
    );
    await expect(page.locator("#fares-conflict")).toContainText("Local ride · Adult");
    await expect(page.locator("#fares-conflict")).toContainText("$1.60");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prices-conflict-${viewport.label}`);

    // Choosing this editor's price resolves the conflict and saves. The panel
    // is scrolled to the top of the viewport first: the save bar is sticky to
    // the bottom of the panel, and a radio scrolled under it is not clickable.
    await page.locator("#fares-conflict").evaluate((panel) => {
      panel.scrollIntoView({ block: "start" });
    });
    await page
      .locator('#fares-conflict input[value="mine"]')
      .first()
      .check();
    await page.locator("#save-prices").click();
    await expect(page.locator("#fares-conflict")).toHaveCount(0);
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.75");

    // Undo takes that save back to what was stored when it was reviewed, and a
    // last edit puts the version back at the sample's own $1.50 so the journeys
    // after this one read the fixture they seeded.
    await page.locator("#undo-prices").click();
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.60");

    await second.close();

    await page.locator("#price-local_ride-adult").fill("1.50");
    await page.locator("#price-local_ride-adult").blur();
    await page.locator("#save-prices").click();
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

    // The older-format lens.
    await page.locator("#fare-lens").check();
    await expect(page.locator("#fare-lens-note")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prices-lens-${viewport.label}`);
    await page.locator("#fare-lens").uncheck();
  }

  await captureReference(page, testInfo, "?state=prices", "ref-prices-grid");
  await captureReference(page, testInfo, "?state=prices-editing", "ref-prices-editing");
  await captureReference(page, testInfo, "?state=prices-conflict", "ref-prices-conflict");
  await captureReference(page, testInfo, "?state=prices-lens", "ref-prices-lens");
});

// ── drawers ───────────────────────────────────────────────────────────────

// The three drawers the Prices tab owns — the fare, the rider type and the
// payment method — and the confirm dialog that settles a fare's rules.
//
// Each journey proves one thing through the DOM the LiveView renders: a
// rejected save lands on the error summary rather than on the first field, a
// priced fare cannot be deleted until the operator says what its rides charge
// instead, the rider type shown first offers no delete action, and Escape puts
// focus back on the control that opened the drawer.
test("drawers", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSIONS.managed);

  const openPrices = async () => {
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);
    await expect(page.locator("#fare-table")).toBeAttached();
  };

  // A refused save focuses the summary that lists what to fix, and the summary
  // links to the field each failure names. Both drawers, so the answer is not
  // the fare drawer's own habit.
  await openPrices();

  await page.locator("#create-fare").click();
  await expect(page.locator("#fare-drawer")).toBeAttached();
  await expect(page.locator("#fare-media-cash")).toBeChecked();
  await page.locator("#fare-price-adult").fill("1.00");
  await page.locator("#fare-save").click();

  const summary = page.locator("#error-summary");
  await expect(summary).toBeAttached();
  await expect(summary).toHaveAttribute("tabindex", "-1");
  await expect(page.locator('#error-summary a[href="#fare-name"]')).toHaveCount(1);
  await expect(
    await page.evaluate(() => document.activeElement?.id),
  ).toBe("error-summary");

  // No summary at all while the form is valid: it is drawn only for a refusal.
  await page.locator("#fare-name").fill("Summer beach shuttle");
  await page.locator("#fare-save").click();

  await expect(page.locator("#fare-drawer")).toHaveCount(0);
  await expect(page.locator("#error-summary")).toHaveCount(0);
  await expect(page.locator("#fare-note")).toContainText("Summer beach shuttle saved");
  await expect(page.locator("#fare-table")).toContainText("Summer beach shuttle");

  // The fare is removed again so the journeys after this one read the fixture
  // they seeded.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-note")).toContainText("Change undone.");
  await expect(page.locator("#fare-table")).not.toContainText(
    "Summer beach shuttle",
  );

  // Escape closes the drawer and puts focus back on the control that opened it,
  // which is the fare name the grid drew.
  await page.locator("#fare-open-local_ride").click();
  await expect(page.locator("#fare-drawer")).toBeAttached();
  await expect(page.locator("#fare-name")).toHaveValue("Local ride");

  await page.keyboard.press("Escape");
  await expect(page.locator("#fare-drawer")).toHaveCount(0);
  expect(await page.evaluate(() => document.activeElement?.id)).toBe(
    "fare-open-local_ride",
  );

  // A fare no rule charges deletes without a replacement question at all.
  await openPrices();
  await page.locator("#create-fare").click();

  await page.locator("#fare-name").fill("Summer beach shuttle");
  await page.locator("#fare-price-adult").fill("1.00");
  await page.locator("#fare-save").click();
  await expect(page.locator("#fare-table")).toContainText("Summer beach shuttle");

  // A priced fare will not go until its rules say what they charge instead.
  await page.locator("#fare-open-valley_ride").click();
  await page.locator("#fare-delete").click();
  await expect(page.locator("#fare-delete-dialog")).toBeAttached();
  await expect(page.locator("#fare-delete-rules")).toContainText("Valley ride");
  await expect(page.locator("#fare-delete-replacement")).toBeAttached();

  await page.locator("#fare-delete-dialog-confirm").click();
  await expect(page.locator("#fare-delete-dialog")).toBeAttached();
  await expect(page.locator("#fare-delete-replacement")).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await expect(page.locator("#fare-delete-replacement-error")).toHaveText(
    "Choose what these rides charge instead.",
  );
  await expect(page.locator("#fare-table")).toContainText("Valley ride");

  // Choosing Coast ride deletes the fare and points its rules there.
  await page.locator("#fare-delete-replacement").selectOption("coast_ride_adult_cash");
  await page.locator("#fare-delete-dialog-confirm").click();
  await expect(page.locator("#fare-delete-dialog")).toHaveCount(0);
  await expect(page.locator("#fare-table")).not.toContainText("Valley ride");

  // Undo is the whole way back, and it restores the fare and its rules.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-table")).toContainText("Valley ride");

  await page.locator("#fare-open-summer_beach_shuttle").click();
  await page.locator("#fare-delete").click();
  await expect(page.locator("#fare-delete-unused")).toBeAttached();
  await page.locator("#fare-delete-dialog-confirm").click();
  await expect(page.locator("#fare-table")).not.toContainText(
    "Summer beach shuttle",
  );

  // The rider type shown first is the one trip planners lead with, so it offers
  // no delete action; another one does.
  await page.locator("#rider-edit-adult").click();
  await expect(page.locator("#rider-drawer")).toBeAttached();
  await expect(page.locator("#rider-name")).toHaveValue("Adult");
  await expect(page.locator("#rider-delete")).toHaveCount(0);
  await expect(page.locator("#rider-default")).toBeDisabled();

  await page.locator("#rider-cancel").click();
  await expect(page.locator("#rider-drawer")).toHaveCount(0);

  await page.locator("#rider-edit-reduced").click();
  await expect(page.locator("#rider-delete")).toBeAttached();
  await page.locator("#rider-cancel").click();

  // A create states the starting prices it would create before it writes them.
  await page.locator("#create-rider").click();
  await expect(page.locator("#rider-starting-preview")).toBeAttached();
  await expect(page.locator("#rider-name")).toHaveValue("");
  await page.locator("#rider-save").click();
  await expect(page.locator('#error-summary a[href="#rider-name"]')).toHaveCount(1);

  await page.locator("#rider-name").fill("Senior (65+)");
  await page.locator("#rider-starting-half").check();
  await page.locator("#rider-save").click();
  await expect(page.locator("#rider-drawer")).toHaveCount(0);
  await expect(page.locator("#rider-edit-senior_65")).toBeAttached();

  await page.locator("#undo-prices").click();
  await expect(page.locator("#rider-edit-senior_65")).toHaveCount(0);

  // The payment method drawer offers GTFS's five kinds and the fares that
  // accept it.
  await page.locator("#create-media").click();
  await expect(page.locator("#media-drawer")).toBeAttached();
  await expect(page.locator("#media-kind-4")).toBeAttached();

  await page.locator("#media-save").click();
  await expect(page.locator('#error-summary a[href="#media-name"]')).toHaveCount(1);

  await page.locator("#media-name").fill("NCT Ride app");
  await page.locator("#media-kind-4").check();
  await page.locator("#media-fare-local_ride").check();
  await page.locator("#media-save").click();
  await expect(page.locator("#media-drawer")).toHaveCount(0);
  await expect(page.locator("#fare-payment-title")).toBeAttached();
  await expect(page.locator("#media-open-nct_ride_app")).toBeAttached();
  await expect(page.locator("#fare-payment-list")).toContainText(
    "NCT Ride app",
  );

  // The payment method this journey made is removed again through its own
  // drawer, so the captures below read the fixture this journey seeded.
  await page.locator("#media-open-nct_ride_app").click();
  await page.locator("#media-delete").click();
  await page.locator("#media-delete-dialog-confirm").click();
  await expect(page.locator("#media-drawer")).toHaveCount(0);
  // The seed already carries an app by that name, so what went is the method
  // this journey made — its own row, the one the drawer opened.
  await expect(page.locator("#media-open-nct_ride_app")).toHaveCount(0);
  await expect(page.locator("#media-open-app")).toBeAttached();

  // ── captures ────────────────────────────────────────────────────────────
  // Each drawer state at both prepared viewports, beside the prototype states
  // they follow.
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openPrices();

    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `drawers-prices-${viewport.label}`);

    // The fare drawer, empty and ready to be filled in.
    await page.locator("#create-fare").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
await captureDrawer(page, testInfo, `drawers-fare-create-${viewport.label}`);

    // The same drawer with prices typed, so the live result card is showing.
    await page.locator("#fare-name").fill("Summer beach shuttle");
    await page.locator("#fare-price-adult").fill("1.00");
    await page.locator("#fare-price-reduced").fill("0.50");
    await page.locator("#fare-differ").check();
    await expect(page.locator("#fare-result-card")).toBeAttached();
    await expect(page.locator("#fare-result-card")).toContainText("$1.00");
    await captureDrawer(page, testInfo, `drawers-fare-filled-${viewport.label}`);

    // The refused state: the summary focused and linked to the name.
    await page.locator("#fare-name").fill("");
    await page.locator("#fare-save").click();
    await expect(page.locator("#error-summary")).toBeAttached();
    await captureDrawer(page, testInfo, `drawers-fare-errors-${viewport.label}`);
    await page.locator("#fare-cancel").click();

    // The fare being edited, with its own prices.
    await page.locator("#fare-open-local_ride").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await expect(page.locator("#fare-result-card")).toContainText("$1.50");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-fare-edit-${viewport.label}`);
    await page.locator("#fare-cancel").click();

    // The delete dialog, and the refused delete that asks for a replacement.
    await page.locator("#fare-open-valley_ride").click();
    await page.locator("#fare-delete").click();
    await expect(page.locator("#fare-delete-dialog")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-fare-delete-${viewport.label}`);

    await page.locator("#fare-delete-dialog-confirm").click();
    await expect(page.locator("#fare-delete-replacement-error")).toHaveText(
      "Choose what these rides charge instead.",
    );
    await captureDrawer(page, testInfo, `drawers-fare-delete-error-${viewport.label}`);

    await page.locator("#fare-delete-replacement").selectOption("coast_ride_adult_cash");
    await expect(page.locator("#fare-delete-replacement")).toHaveValue(
      "coast_ride_adult_cash",
    );
    await page.locator("#fare-delete-dialog-cancel").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await page.locator("#fare-cancel").click();

    // The rider type drawer, and its create with the starting prices stated.
    await page.locator("#create-rider").click();
    await expect(page.locator("#rider-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-rider-create-${viewport.label}`);
    await page.locator("#rider-cancel").click();

    await page.locator("#rider-edit-reduced").click();
    await expect(page.locator("#rider-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-rider-edit-${viewport.label}`);
    await page.locator("#rider-cancel").click();

    // The payment method drawer and its create.
    await page.locator("#create-media").click();
    await expect(page.locator("#media-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-media-create-${viewport.label}`);
    await page.locator("#media-cancel").click();

    await page.locator("#media-open-app").click();
    await expect(page.locator("#media-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-media-edit-${viewport.label}`);

    await page.locator("#media-delete").click();
    await expect(page.locator("#media-delete-dialog")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-media-delete-${viewport.label}`);
    await page.locator("#media-delete-dialog-cancel").click();
  }

  await captureReference(page, testInfo, "?state=fare-create", "ref-fare-create");
  await captureReference(page, testInfo, "?state=fare-errors", "ref-fare-errors");
  await captureReference(page, testInfo, "?state=fare-delete", "ref-fare-delete");
  await captureReference(page, testInfo, "?state=rider-create", "ref-rider-create");
  await captureReference(page, testInfo, "?state=media-create", "ref-media-create");
});

// ── bulk ──────────────────────────────────────────────────────────────────

// The Change prices dialog. The journey proves the preview is computed and
// never written, that Update writes exactly what the preview listed, that Undo
// reverses it, and that choices moving nothing leave Update disabled with the
// reason on screen. The seeded North Coast version prices Local ride at $1.50
// adult on the cash method and $1.25 in the NCT Ride app, so the default
// +$0.25 preview lists both of those.
test("bulk", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSIONS.managed);

  const openPrices = async () => {
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);
    await expect(page.locator("#fare-table")).toBeAttached();
  };

  // The dialog opens on the prototype's defaults, with a preview rather than a
  // save: nothing is written until Update.
  await openPrices();
  await page.locator("#change-prices").click();
  await expect(page.locator("#price-change-dialog")).toBeAttached();
  await expect(page.locator("#price-change-preview-badge")).toHaveText(
    "Preview · not saved",
  );
  await expect(page.locator("#price-change-scope")).toHaveValue("single");
  await expect(page.locator("#price-change-amount")).toHaveValue("0.25");
  await expect(page.locator("#price-change-round")).toHaveValue("0.05");
  await expect(page.locator("#price-change-half")).toBeChecked();
  await expect(page.locator("#price-change-rider-child")).toBeDisabled();

  const count = Number(
    (await page.locator("#price-change-count").innerText()).split("\n")[0].trim(),
  );
  expect(count).toBeGreaterThan(0);
  await expect(page.locator("#price-change-largest")).toContainText("+$0.25");
  await expect(page.locator("#price-change-row-local_ride_adult_cash")).toContainText(
    "$1.75",
  );
  await expect(page.locator("#price-change-empty")).toHaveCount(0);

  // A preview writes nothing.
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

  // The choices recompute the preview: a percentage on one rider type.
  await page.locator("#price-change-rider-adult").check();
  await page.locator("#price-change-rider-reduced").uncheck();
  await page.locator("#price-change-rider-youth").uncheck();
  await page.locator("#price-change-how").selectOption("percent");
  await page.locator("#price-change-percent").fill("10");
  await page.locator("#price-change-round").selectOption("0.25");

  // 10% of Coast ride's $3.50 is $3.85, which rounds down to $3.75.
  await expect(page.locator("#price-change-row-coast_ride_adult_cash")).toContainText(
    "$3.75",
  );
  await expect(page.locator("#price-change-row-local_ride_reduced_cash")).toHaveCount(
    0,
  );

  // A choice that moves nothing disables Update and says why.
  await page.locator("#price-change-percent").fill("0");
  await expect(page.locator("#price-change-empty")).toBeAttached();
  await expect(page.locator("#price-change-dialog-confirm")).toBeDisabled();
  await expect(page.locator("#price-change-dialog-confirm")).toHaveText(
    "Update prices",
  );
  await expect(page.locator("#price-change-status")).toContainText(
    "Nothing changes until you update.",
  );

  // An unreadable amount is refused the same way, with its own reason.
  await page.locator("#price-change-percent").fill("ten percent");
  await expect(page.locator("#price-change-value-error")).toBeAttached();
  await expect(page.locator("#price-change-dialog-confirm")).toBeDisabled();

  // ── captures ────────────────────────────────────────────────────────────
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openPrices();

    await page.locator("#change-prices").click();
    await expect(page.locator("#price-change-dialog")).toBeAttached();
    await expect(page.locator("#price-change-count")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `bulk-${viewport.label}`);

    // The disabled state, with the reason on the status line.
    await page.locator("#price-change-amount").fill("0.00");
    await expect(page.locator("#price-change-empty")).toBeAttached();
    await expect(page.locator("#price-change-dialog-confirm")).toBeDisabled();
    await captureDrawer(page, testInfo, `bulk-empty-${viewport.label}`);

    await page.locator("#price-change-dialog-cancel").click();
    await expect(page.locator("#price-change-dialog")).toHaveCount(0);
  }

  // Update writes exactly what the preview listed, and Undo reverses it.
  await openPrices();
  await page.locator("#change-prices").click();
  await page.locator("#price-change-rider-reduced").uncheck();
  await page.locator("#price-change-rider-youth").uncheck();
  await page.locator("#price-change-rider-adult").check();

  await expect(page.locator("#price-change-dialog-confirm")).toHaveText(
    "Update 8 prices",
  );
  await page.locator("#price-change-dialog-confirm").click();
  await expect(page.locator("#price-change-dialog")).toHaveCount(0);
  await expect(page.locator("#fare-note")).toContainText("8 prices changed");
  await expect(page.locator("#undo-prices")).toBeAttached();
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.75");

  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-note")).toContainText("Change undone.");
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

  await captureReference(page, testInfo, "?state=bulk", "ref-bulk");
});

// ── setup ───────────────────────────────────────────────────────────────────

// The Prices tab's first-use setup, the fare-free summary, an imported
// version's read-only view with its conversion review, and the mismatch banner.
// Each state is proved through the DOM the LiveView renders, and each capture is
// taken at both prepared viewports beside the prototype state it follows.
test("setup", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const found = {};
  for (const [key, name] of Object.entries(VERSIONS)) {
    found[key] = await versionIdByName(page, name);
  }

  const openVersion = async (versionId) => {
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);
  };

  // ── the first-use setup ────────────────────────────────────────────────
  // A version with no fare rows asks the four questions instead of drawing the
  // grid, and carries its one primary inside the panel rather than in the
  // header beside it.
  await openVersion(found.blank);

  await expect(page.locator("#fare-setup")).toBeAttached();
  await expect(page.locator("#fare-table")).toHaveCount(0);
  await expect(page.locator("#create-fare")).toHaveCount(0);
  await expect(page.locator("#setup-create")).toBeAttached();
  await expect(page.locator("#setup-step-1")).toBeAttached();
  await expect(page.locator("#setup-step-2")).toBeAttached();

  // The live result card reads the answers as they stand.
  await expect(page.locator("#setup-result")).toContainText("$1.50");
  await expect(page.locator("#setup-result")).toContainText("Reduced fare $0.75");
  await expect(page.locator("#setup-result")).toContainText(
    "Creates 1 fare, 3 rider types, 1 transfer rule.",
  );

  // Choosing a different structure changes what is asked, and the card follows.
  await page.locator("#setup-kind-route").check();
  await expect(page.locator("#setup-groups")).toBeAttached();
  await expect(page.locator("#setup-adult")).toHaveCount(0);
  await expect(page.locator("#setup-group-0-name")).toHaveValue("Local routes");
  await expect(page.locator("#setup-group-0-price")).toHaveValue("1.50");

  // A third group is the one answer that is not a field.
  await page.locator("#add-route-group").click();
  await expect(page.locator("#setup-group-2-name")).toHaveValue("");

  // A price the writer will not read is refused on the field it names, and
  // nothing is written.
  await page.locator("#setup-kind-flat").check();
  await page.locator("#setup-adult").fill("one fifty");
  await page.locator("#setup-adult").blur();
  await page.locator("#setup-create").click();

  await expect(page.locator("#fare-setup")).toBeAttached();
  await expect(page.locator("#setup-error-summary")).toBeAttached();
  await expect(page.locator("#setup-adult-error")).toBeAttached();

  // ── captures ────────────────────────────────────────────────────────────
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(found.blank);

    await expect(page.locator("#fare-setup")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-first-use-${viewport.label}`);

    // The route structure, whose group rows are the widest answer.
    await page.locator("#setup-kind-route").check();
    await expect(page.locator("#setup-groups")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-first-use-route-${viewport.label}`);

    // The zone structure's own question.
    await page.locator("#setup-kind-zone").check();
    await expect(page.locator("#setup-adult")).toHaveValue("1.50");
    await expect(page.locator("#setup-zone-help")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-first-use-zone-${viewport.label}`);

    // A refused answer, with the summary and the field's own reason.
    await page.locator("#setup-kind-flat").check();
    await page.locator("#setup-adult").fill("one fifty");
    await page.locator("#setup-adult").blur();
    await page.locator("#setup-create").click();
    await expect(page.locator("#setup-error-summary")).toBeAttached();
    await capture(page, testInfo, `setup-refused-${viewport.label}`);
  }

  // Create fares writes the whole set and lands on the Prices grid.
  await openVersion(found.blank);
  await page.locator("#setup-adult").fill("1.50");
  await page.locator("#setup-adult").blur();
  await page.locator("#setup-create").click();

  await expect(page.locator("#fare-setup")).toHaveCount(0);
  await expect(page.locator("#fare-table")).toBeAttached();
  await expect(page.locator("#fare-note")).toContainText("Fares created");
  await expect(page.locator("#create-fare")).toBeAttached();
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");
  await expect(page.locator("#price-local_ride-reduced")).toHaveValue("$0.75");
  await expect(page.locator("#price-local_ride-child")).toHaveValue("Free");

  // The fare-free summary is the state the free structure leaves behind. Undo
  // takes the version back to the setup, so the same version draws it without a
  // second fixture.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-setup")).toBeAttached();

  await openVersion(found.blank);
  await page.locator("#setup-kind-free").check();
  await page.locator("#setup-create").click();
  await expect(page.locator("#fare-free")).toBeAttached();

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(found.blank);

    // The summary replaces the grid: there is no price here to type, and the
    // header carries no primary of its own.
    await expect(page.locator("#fare-free")).toBeAttached();
    await expect(page.locator("#fare-table")).toHaveCount(0);
    await expect(page.locator("#create-fare")).toHaveCount(0);
    await expect(page.locator("#fare-free-lede")).toContainText("Free");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-free-${viewport.label}`);

    // "Start charging fares" opens the fare the setup wrote, in the same drawer
    // the grid's own fare names open.
    await page.locator("#start-charging-fares").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await expect(page.locator("#fare-name")).toHaveValue("Free ride");
    await captureDrawer(page, testInfo, `setup-free-drawer-${viewport.label}`);
    await page.locator("#fare-drawer-close").click();
    await expect(page.locator("#fare-drawer")).toHaveCount(0);
  }

  // ── an imported version ────────────────────────────────────────────────
  // The stored fares are drawn, and none of them can be typed into.
  await openVersion(found.unmanaged);

  await expect(page.locator("#unmanaged-fares")).toBeAttached();
  await expect(page.locator("#edit-fares")).toBeAttached();
  await expect(page.locator("#unmanaged-v1-table")).toContainText("LOCAL");
  await expect(page.locator("#fare-table input[name^='price[']")).toHaveCount(0);
  await expect(page.locator("#change-prices")).toHaveCount(0);
  await expect(page.locator("#create-fare")).toHaveCount(0);

  await page.locator("#edit-fares").click();
  await expect(page.locator("#conversion-review")).toBeAttached();
  await expect(page.locator("#conversion-review-confirm")).toHaveText(
    "Convert fares",
  );
  await expect(page.locator("#conversion-price-differences")).toContainText("0");
  await expect(page.locator("#conversion-counts")).toContainText("5 fares");
  await expect(page.locator("#conversion-known-differences")).toBeAttached();
  await expect(page.locator("#conversion-kept-older")).toContainText("COAST");

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(found.unmanaged);
    await page.locator("#edit-fares").click();
    await expect(page.locator("#conversion-review")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `setup-conversion-review-${viewport.label}`);
    await page.locator("#conversion-review-cancel").click();
  }

  // Convert makes the grid editable, and the imported rows are left as they
  // were: the version exports what it imported until somebody changes a price.
  await openVersion(found.unmanaged);
  await page.locator("#edit-fares").click();
  await page.locator("#conversion-review-confirm").click();

  await expect(page.locator("#conversion-review")).toHaveCount(0);
  await expect(page.locator("#fare-table")).toBeAttached();
  await expect(page.locator("#create-fare")).toBeAttached();
  await expect(page.locator("#fare-note")).toContainText("Fares converted");
  await expect(page.locator("#fare-table input[name^='price[']")).not.toHaveCount(0);

  // ── the mismatch banner ────────────────────────────────────────────────
  await openVersion(found.mismatch);

  await expect(page.locator("#fares-mismatch")).toBeAttached();
  await expect(page.locator("#fares-mismatch-detail")).toContainText("LOCAL");
  await expect(page.locator("#fares-mismatch-detail")).toContainText("$1.75");

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(found.mismatch);
    await expect(page.locator("#fares-mismatch")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-mismatch-${viewport.label}`);
  }

  await captureReference(page, testInfo, "?state=first-use", "ref-setup-first-use");
  await captureReference(page, testInfo, "?state=first-use-route", "ref-setup-route");
  await captureReference(page, testInfo, "?state=first-use-zone", "ref-setup-zone");
  await captureReference(page, testInfo, "?state=imported-v1", "ref-setup-imported");
  await captureReference(page, testInfo, "?state=mismatch", "ref-setup-mismatch");
});
