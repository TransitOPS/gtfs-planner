// Flex workspace browser journey.
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`. The seeded "Browser Flex Version" is resolved by name
// through the version panel, so every case reads the flex fixture it names
// instead of whichever version is the organization's default.
//
// Step 17 owns this shell (login, version selection, blank tiles and the capture
// helpers); each of the following UI steps adds one case to it and captures the
// desktop and narrow views for comparison with the prototypes in
// `.specs/22-gtfs-flex/references/`.
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

const VERSION_NAME = "Browser Flex Version";

const DESKTOP = { width: 1440, height: 900, label: "desktop" };
const NARROW = { width: 320, height: 800, label: "narrow" };

// A 1×1 transparent PNG. Every tile request is answered locally so the
// workspace never depends on the Geoapify plan or on network access.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

// The spec package lives in the gitignored `.specs/` workspace, which a worktree
// checkout does not carry; FLEX_SPEC_ROOT points the captures and the prototype
// lookups at the checkout that holds it.
const SPEC_ROOT =
  process.env.FLEX_SPEC_ROOT || resolve(REPO_ROOT, ".specs", "22-gtfs-flex");
const CAPTURE_DIR = resolve(SPEC_ROOT, "evidence", "captures");
const REFERENCE_DIR = resolve(SPEC_ROOT, "references");

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

// Every map tile request is answered with the blank tile, so the journey never
// depends on the Geoapify plan. Register it before the first navigation.
async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

// Leaflet fades each tile in, so a capture taken as the first tiles land shows
// bands of half-opacity ground. A map capture waits for its tile layer to
// settle first, which keeps the ground one colour and the drawn areas the only
// thing the comparison sees change.
async function waitForTiles(page, mapSelector) {
  await page.waitForFunction((selector) => {
    const tiles = [...document.querySelectorAll(`${selector} img.leaflet-tile`)];

    return (
      tiles.length > 0 &&
      tiles.every(
        (tile) =>
          tile.complete &&
          tile.naturalWidth > 0 &&
          getComputedStyle(tile).opacity === "1",
      )
    );
  }, mapSelector);
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

async function flexVersionId(page) {
  const versionId = await versionIdByName(page, VERSION_NAME);
  if (!versionId) throw new Error(`${VERSION_NAME} is missing its version ID`);
  return versionId;
}

// Opens the flex workspace and returns the version ID it selected. `path` is
// appended to `/gtfs/<version>/flex`, which is how later cases open a service
// page or the area editor.
async function openFlex(page, path = "") {
  await logIn(page);

  const versionId = await flexVersionId(page);
  await page.goto(`/gtfs/${versionId}/flex${path}`);
  await waitForLiveView(page);

  return versionId;
}

// The capture name carries the viewport the case set, so one case covers the
// desktop and narrow sizes without repeating the label.
function viewportLabel(page) {
  const size = page.viewportSize();
  const viewport = [DESKTOP, NARROW].find(
    (candidate) => candidate.width === size.width && candidate.height === size.height,
  );

  if (!viewport) {
    throw new Error(`Declare the ${size.width}×${size.height} viewport before capturing it`);
  }

  return viewport.label;
}

// The capture name carries the viewport the case set, so one case covers the
// desktop and narrow sizes without repeating the label. A modal surface is
// captured in the viewport only: a full-page shot of a drawer would also show
// the page it covers, which is not what the reader is meant to compare.
async function capture(page, name, { fullPage = true } = {}) {
  mkdirSync(CAPTURE_DIR, { recursive: true });

  const path = resolve(CAPTURE_DIR, `${name}-${viewportLabel(page)}.png`);
  await page.screenshot({ path, fullPage });

  return path;
}

// Captures a prototype state at the current viewport for the side-by-side
// comparison. The reference lives in the gitignored `.specs/` workspace, so the
// capture is skipped in a checkout that does not carry it.
async function captureReference(page, file, state, name) {
  const reference = resolve(REFERENCE_DIR, file);
  if (!existsSync(reference)) return null;

  await page.goto(`file://${reference}?state=${state}`);
  await page.waitForLoadState("networkidle");

  mkdirSync(CAPTURE_DIR, { recursive: true });

  const path = resolve(CAPTURE_DIR, `ref-${name}.png`);
  await page.screenshot({ path, fullPage: false });

  return path;
}

// ── placeholder ───────────────────────────────────────────────────────────

// The shell holds no cases yet: each visual step below adds its own case and
// captures it through `capture`. The skipped placeholder keeps
// `playwright test e2e/flex.spec.js` green while the page is still the Coming
// soon placeholder.
test.skip("placeholder", async () => {});

// ── list ──────────────────────────────────────────────────────────────────

// The Flex list is the Flex area's landing surface: the services table beside the
// map card, with the export-state line above both. The seeded version holds the
// two services the earlier steps read.
test("list", async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await openFlex(page);

  await expect(page.locator("#flex-services-count")).toHaveText("2 flex services");
  await expect(page.locator("#flex-services tr")).toHaveCount(2);
  await expect(page.locator("#flex-services tr").first()).toContainText("Newport Dial-a-Ride");
  await expect(page.locator("#flex-services tr").nth(1)).toContainText("Valley Line detours");
  await expect(page.locator("#flex-exports")).toContainText("Exports also write a flex file");
  await expect(page.locator("#flex-list-map")).toBeVisible();

  await expectNoHorizontalPageScroll(page);
  await capture(page, "list");

  // The narrow view stacks the map card under the table, and the table scrolls
  // inside its own container rather than widening the page.
  await page.setViewportSize(NARROW);
  await page.waitForSelector("#flex-services-count");
  await expectNoHorizontalPageScroll(page);
  await capture(page, "list");

  await page.setViewportSize(DESKTOP);
  await captureReference(page, "flex-services-prototype.html", "list", "list");
});

// ── list map ──────────────────────────────────────────────────────────────

// The map card is the server's map payload drawn by the FlexAreaMap hook: the
// version's stored areas, its fixed route lines and its connecting stops, on the
// street basemap, with the legend under the stage. Tiles are blank in tests, so
// the areas and the lines are what the capture shows.
test("list-map", async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await openFlex(page);

  const map = page.locator("#flex-list-map");

  // The hook drew the payload: the area is an SVG path in Leaflet's overlay
  // pane, the route line is drawn beside it, and the connecting stop is named
  // on the map rather than on hover.
  await map.locator("path.flex-map-area").first().waitFor({ timeout: 60_000 });
  await waitForTiles(page, "#flex-list-map");
  await expect(map.locator("path.flex-map-area")).toHaveCount(1);
  await expect(map.locator(".leaflet-overlay-pane path")).toHaveCount(4);
  // Read-only: nothing on the map takes a click the map itself should get.
  await expect(map.locator("path.leaflet-interactive")).toHaveCount(0);
  await expect(
    map.locator(".flex-map-stop-label", { hasText: "Newport City Center" }),
  ).toBeVisible();

  // The legend names what is drawn, and the attribution stays visible.
  await expect(page.locator("#flex-list-map-legend")).toContainText("Flex area");
  await expect(page.locator("#flex-list-map-legend")).toContainText("Fixed route");
  await expect(page.locator("#flex-list-map-legend")).toContainText("Connecting stop");
  await expect(map.locator(".leaflet-control-attribution")).toContainText(
    "OpenStreetMap",
  );

  await expectNoHorizontalPageScroll(page);
  await capture(page, "list-map");

  await page.setViewportSize(NARROW);
  await page.waitForSelector("#flex-list-map path.flex-map-area");
  await waitForTiles(page, "#flex-list-map");
  await expectNoHorizontalPageScroll(page);
  await capture(page, "list-map");

  await page.setViewportSize(DESKTOP);
  await captureReference(page, "flex-services-prototype.html", "list", "list-map");
});

// ── create ────────────────────────────────────────────────────────────────

// The create drawer is the list's only way to add a service: the two kinds, the
// one-name question with its advice, the booked-stops pointer, a detour's route
// and the name. The capture takes the reference's "areas with their own names"
// state — the area kind and the "No, each area has its own name" answer — which
// is the state the prototype's own `create-several-names` state opens.
test("create", async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);

  const versionId = await openFlex(page);

  // The header's button opens the drawer on the kind question itself, and the
  // two kinds it offers are the only ones there are.
  await page.click("#create-service");

  const drawer = page.locator("#create-drawer");
  await expect(drawer).toBeVisible();
  await expect(drawer).toContainText("How does it work?");
  await expect(page.locator("#create-pattern-area")).toBeVisible();
  await expect(page.locator("#create-pattern-route")).toBeVisible();
  await expect(page.locator("#create-pattern-stops")).toHaveCount(0);
  await expect(drawer).toContainText("Booking required");
  await expect(page.locator("#create-named-one")).toHaveCount(0);

  // The one-name question follows the area kind, and its advice follows the
  // "each area has its own name" answer.
  await page.click("#create-pattern-area");
  await expect(page.locator("#create_name")).toBeVisible();
  await page.click("#create-named-several");
  await expect(drawer).toContainText("Create one service for each name");

  await expectNoHorizontalPageScroll(page);
  await capture(page, "create", { fullPage: false });

  await page.setViewportSize(NARROW);
  await expect(page.locator("#create-named-several")).toBeVisible();
  await expectNoHorizontalPageScroll(page);
  await capture(page, "create", { fullPage: false });

  await page.setViewportSize(DESKTOP);

  // The footer's button belongs to the form, and an unanswered submit lists what
  // is missing and stays on the page rather than creating anything.
  await page.click("#create-submit");
  await expect(page.locator("#create-error-summary")).toBeVisible();
  await expect(page.locator("#create-error-summary")).toContainText(
    "Enter the service name riders see.",
  );
  await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/flex$`));

  await captureReference(page, "flex-services-prototype.html", "create-several-names", "create");
});

// ── service page ──────────────────────────────────────────────────────────

// The service page is the Flex workspace's second surface: the short header with
// the readiness badge, the hours editor beside the sticky rider preview, and the
// map card. The case opens the seeded Newport Dial-a-Ride, captures the page as
// it stands, then changes one hours window and captures the save bar's
// rider-terms summary without saving anything.
test("service", async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  const versionId = await openFlex(page);

  // The list's first row is Newport Dial-a-Ride (name order).
  await page.getByRole("link", { name: "Newport Dial-a-Ride", exact: true }).click();
  await waitForLiveView(page);

  await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/flex/[0-9a-f-]+$`));
  await expect(page.locator("#svc-title")).toHaveText("Newport Dial-a-Ride");
  await expect(page.locator("#svc-status")).toContainText("Ready");
  await expect(page.locator("#flex-service-page")).toHaveAttribute("data-dirty", "false");
  await expect(page.locator("#sec-when")).toBeVisible();
  await expect(page.locator("#sec-booking")).toBeVisible();
  await expect(page.locator("#rider-preview")).toBeVisible();
  await expect(page.locator("#flex-service-map")).toBeVisible();
  await expect(page.locator("#save-bar")).toHaveCount(0);

  // The hours editor and the rider preview are above the 900 px fold.
  for (const selector of ["#f-hours", "#rider-preview"]) {
    const box = await page.locator(selector).boundingBox();
    expect(box.y).toBeLessThan(900);
  }

  await waitForTiles(page, "#flex-service-map");
  await expectNoHorizontalPageScroll(page);
  await capture(page, "service");

  await page.setViewportSize(NARROW);
  await expect(page.locator("#rider-preview")).toBeVisible();
  await expectNoHorizontalPageScroll(page);
  await capture(page, "service");

  // One hours window moves: the page is dirty, the save bar words the change in
  // rider terms, and the preview follows the draft before anything is saved.
  await page.setViewportSize(DESKTOP);
  await page.locator("#service_hours_0_end").fill("17:00");
  await page.locator("#service_hours_0_end").blur();

  await expect(page.locator("#flex-service-page")).toHaveAttribute("data-dirty", "true");
  await expect(page.locator("#save-bar")).toBeVisible();
  await expect(page.locator("#save-bar")).toContainText("1 unsaved change to Newport Dial-a-Ride");
  await expect(page.locator("#save-bar")).toContainText(
    "Weekdays: 7:00 am–6:00 pm → 7:00 am–5:00 pm",
  );
  await expect(page.locator("#rider-preview")).toContainText("Weekdays 7:00 am–5:00 pm");

  await expectNoHorizontalPageScroll(page);
  await capture(page, "service-editing");

  await page.setViewportSize(NARROW);
  await expect(page.locator("#save-bar")).toBeVisible();
  await expectNoHorizontalPageScroll(page);
  await capture(page, "service-editing");

  await page.setViewportSize(DESKTOP);
  await captureReference(page, "flex-services-prototype.html", "service", "service");
});

// ── service sections ────────────────────────────────────────────────────

// The service page's second half: where the bus can detour with its published
// distance, stretch and derived-zone summary, who can ride, in exports with the
// organization's realtime answer, and status and removal. The case opens the
// seeded Valley Line detours, captures the detour state, then answers the
// realtime question with "Its own schedule file" — which saves at once, outside
// the service's draft — and captures the warning beside it.
test("service-sections", async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  const versionId = await openFlex(page);

  await page.getByRole("link", { name: "Valley Line detours", exact: true }).click();
  await waitForLiveView(page);

  await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/flex/[0-9a-f-]+$`));
  await expect(page.locator("#svc-title")).toHaveText("Valley Line detours");

  // Where the bus can detour: the published distance, the stretch, the three
  // ways riders use detours and the derived zones the export will write.
  await expect(page.locator("#sec-where")).toBeVisible();
  await expect(page.locator("#f-distance")).toHaveValue("1200");
  await expect(page.locator("#dropoffs-tell-driver")).toBeChecked();
  await expect(page.locator("#where-summary")).toContainText("detour areas");
  await expect(page.locator("#where-summary")).toContainText("km² in all");

  // The rest of the page is the second half's sections.
  await expect(page.locator("#sec-riders")).toBeVisible();
  await expect(page.locator("#sec-export")).toContainText("Changes");
  await expect(page.locator("#export-r3-note")).toContainText("stop_sequence doubles");
  await expect(page.locator("#sec-status")).toBeVisible();

  await waitForTiles(page, "#flex-service-map");
  await expectNoHorizontalPageScroll(page);
  await capture(page, "detour");

  await page.setViewportSize(NARROW);
  await expect(page.locator("#f-distance")).toBeVisible();
  await expectNoHorizontalPageScroll(page);
  await capture(page, "detour");

  // The realtime answer belongs to the organization, not the service: it saves
  // without a Save and shows its warning for the vendor's own schedule file.
  await page.setViewportSize(DESKTOP);
  await page.selectOption("#f-realtime", "own");

  await expect(page.locator("#realtime-note")).toContainText("own trip IDs");
  await expect(page.locator("#save-bar")).toHaveCount(0);

  await expectNoHorizontalPageScroll(page);
  await capture(page, "detour-realtime-own");

  await page.setViewportSize(NARROW);
  await expect(page.locator("#realtime-note")).toContainText("own trip IDs");
  await expectNoHorizontalPageScroll(page);
  await capture(page, "detour-realtime-own");

  await page.setViewportSize(DESKTOP);
  await captureReference(page, "flex-services-prototype.html", "detour", "detour");
});

// ── export ────────────────────────────────────────────────────────────────

// The Export page carries no flex route, so this case logs in and resolves the
// seeded version the flex workspace uses, then opens `/gtfs/<version>/export`.
async function openExport(page) {
  await logIn(page);

  const versionId = await flexVersionId(page);
  await page.goto(`/gtfs/${versionId}/export`);
  await waitForLiveView(page);

  return versionId;
}

// The page must fit the viewport, so both download links and both validation
// buttons are visible without a horizontal scrollbar.
async function expectNoHorizontalPageScroll(page) {
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );

  expect(overflow).toBeLessThanOrEqual(1);
}

test("export-flex", async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);

  const versionId = await openExport(page);

  const flexLink = page.locator("#export-flex-download-link");

  // A freshly reset browser database has no export run, so the case starts one
  // and waits for its published flex artifact; a database that already ran this
  // case holds a ready pair the page can be captured from directly.
  if ((await flexLink.count()) === 0) {
    await page.click("#start-export");
    await flexLink.waitFor({ state: "visible", timeout: 150_000 });
  }

  await expect(page.locator("#export-download-link")).toBeVisible();
  await expect(page.locator("#export-flex-download-link")).toHaveAttribute(
    "href",
    new RegExp(`^/gtfs/${versionId}/export-runs/[0-9a-f-]+/download\\?file=flex$`),
  );
  await expect(page.locator("#run-validation")).toBeVisible();
  await expect(page.locator("#validate-flex-button")).toBeVisible();

  await expectNoHorizontalPageScroll(page);
  await capture(page, "export-flex");

  await page.setViewportSize(NARROW);
  await page.waitForSelector("#export-flex-download-link");
  await expectNoHorizontalPageScroll(page);
  await capture(page, "export-flex");

  await captureReference(page, "flex-services-prototype.html", "service-export", "export-flex");
});

// ── area editor ───────────────────────────────────────────────────────────

// The area editor's creation routes. The case enters the editor from the seeded
// Newport Dial-a-Ride's first area, captures the choose panel, then walks the
// Census picker: the extent's places with the CDP label, the chosen Newport
// boundary measured as the recorded land polygon (25.8 km²) with its GEOID and
// vintage, and "Use this area" keeping the work in the page's draft — the where
// section shows it and the page asks for a Save, which the case never presses.
test("area-editor", async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  const versionId = await openFlex(page);

  await page.getByRole("link", { name: "Newport Dial-a-Ride", exact: true }).click();
  await waitForLiveView(page);

  await page.locator("#edit-area-a1").click();
  await waitForLiveView(page);

  // The editor names the area it edits, starts on the choose panel, and keeps
  // "Use this area" disabled until the area is usable.
  await expect(page).toHaveURL(
    new RegExp(`/gtfs/${versionId}/flex/[0-9a-f-]+/area\\?area=a1$`),
  );
  await expect(page.locator("#area-title")).toHaveText("Edit area");
  await expect(page.locator("#area-mode-town")).toBeVisible();
  await expect(page.locator("#use-area")).toBeDisabled();
  await expect(page.locator("#use-area-reason")).toBeVisible();

  await waitForTiles(page, "#flex-area-map");
  await expectNoHorizontalPageScroll(page);
  await capture(page, "area-editor");

  // At 320 px the map stacks above the panel and the page still fits.
  await page.setViewportSize(NARROW);
  await expect(page.locator("#area-mode-import")).toBeVisible();
  await expectNoHorizontalPageScroll(page);
  await capture(page, "area-editor");

  // Town or city limits: the places the Census service answers, with the
  // census-designated place labelled as one.
  await page.setViewportSize(DESKTOP);
  await page.locator("#area-mode-town").click();

  await expect(page.locator("#census-place-4152450")).toContainText("Newport city");
  await expect(page.locator("#census-place-4104850")).toContainText("Census-designated place");

  await page.locator("#census-place-4152450 input").check();

  // The pick stores the water-removed land boundary with its provenance, and
  // the editor measures it against the version.
  await expect(page.locator("#area-stats")).toContainText("25.8 km²");
  await expect(page.locator("#area-source")).toContainText(
    "U.S. Census Bureau 2026 boundaries (GEOID 4152450)",
  );
  await expect(page.locator("#use-area")).toBeEnabled();

  await waitForTiles(page, "#flex-area-map");
  await expectNoHorizontalPageScroll(page);
  await capture(page, "area-town");

  await page.setViewportSize(NARROW);
  await expect(page.locator("#area-stats")).toBeVisible();
  await expectNoHorizontalPageScroll(page);
  await capture(page, "area-town");

  // "Use this area" returns to the service page with the area in the draft: the
  // where section shows the Census source and the page is dirty. Nothing is
  // stored, so the case stops before Save.
  await page.setViewportSize(DESKTOP);
  await page.locator("#use-area").click();
  await waitForLiveView(page);

  await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/flex/[0-9a-f-]+$`));
  await expect(page.locator("#flex-service-page")).toHaveAttribute("data-dirty", "true");
  await expect(page.locator("#f-area-a1")).toContainText("U.S. Census Bureau 2026");
  await expect(page.locator("#save-bar")).toBeVisible();

  await expectNoHorizontalPageScroll(page);
  await capture(page, "area-used");

  await captureReference(page, "flex-service-area-prototype.html", "choose", "area-choose");
  await captureReference(page, "flex-service-area-prototype.html", "town", "area-town");
});

// ── settings ────────────────────────────────────────────────────────────────

// The Settings › Export defaults page holds the two settings a full export
// reads: the flex switch and the realtime question. The case opens the page from
// the flex list's own link, captures it at both viewports, turns flex off and
// saves, then follows the switch into the flex list's export-state line — the
// reference's "Exports leave flex out" state. The switch goes back on at the end
// so the seeded version keeps the default the other cases read.
test("export-defaults", async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  const versionId = await openFlex(page);

  await page.locator("#flex-exports a").click();
  await waitForLiveView(page);

  await expect(page).toHaveURL(
    new RegExp(`/gtfs/${versionId}/settings/export-defaults$`),
  );
  await expect(page.locator("h1")).toHaveText("Export defaults");
  await expect(page.locator("#flex-switch")).toBeChecked();

  await expect(page.locator("#flex-switch-consequence")).toContainText(
    "Exports also write a flex file",
  );
  await expect(page.locator("#realtime-source")).toBeVisible();
  await expect(page.locator("#export-defaults-more")).toContainText(
    "More export defaults are coming",
  );

  await expectNoHorizontalPageScroll(page);
  await capture(page, "export-defaults");

  // At 320 px the switch and the question still stack inside the page.
  await page.setViewportSize(NARROW);
  await expect(page.locator("#flex-switch")).toBeVisible();
  await expect(page.locator("#realtime-source")).toBeVisible();

  await expectNoHorizontalPageScroll(page);
  await capture(page, "export-defaults");

  // The switch's consequence follows it before anything is saved.
  await page.setViewportSize(DESKTOP);
  await page.locator("#flex-switch").uncheck();

  await expect(page.locator("#flex-switch-consequence")).toContainText(
    "Exports leave flex out.",
  );

  await page.getByRole("button", { name: "Save changes" }).click();
  await expect(page.locator("#flash-group")).toContainText(
    "Export defaults saved.",
  );

  // The Flex list reads the same row, so its export-state line is the warning
  // that links back here.
  await page.goto(`/gtfs/${versionId}/flex`);
  await waitForLiveView(page);

  await expect(page.locator("#flex-exports")).toContainText(
    "Exports leave flex out.",
  );
  await expect(page.locator("#flex-exports")).toContainText(
    "Change in Settings › Export defaults",
  );

  await expectNoHorizontalPageScroll(page);
  await capture(page, "list-exports-off");

  await captureReference(
    page,
    "flex-services-prototype.html",
    "list-exports-off",
    "list-exports-off",
  );

  await page.setViewportSize(NARROW);
  await page.goto(`/gtfs/${versionId}/flex`);
  await waitForLiveView(page);

  await expect(page.locator("#flex-exports")).toContainText(
    "Exports leave flex out.",
  );
  await expectNoHorizontalPageScroll(page);
  await capture(page, "list-exports-off");

  // Restore the switch, so the seeded version keeps the default every other
  // case reads.
  await page.setViewportSize(DESKTOP);
  await page.goto(`/gtfs/${versionId}/settings/export-defaults`);
  await waitForLiveView(page);

  await page.locator("#flex-switch").check();
  await page.getByRole("button", { name: "Save changes" }).click();

  await expect(page.locator("#flash-group")).toContainText(
    "Export defaults saved.",
  );
  await expect(page.locator("#flex-switch")).toBeChecked();
});
