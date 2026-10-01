// Stops Map browser journeys: the shell, the drawn map, the placement pin,
// search, the version checks, add, edit, move, delete, replace and make-station,
// the entry points from the stop list and the stop page, and one journey across
// them.
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
// The `@seed` case checks the seed itself: it signs in, opens the Stops &
// stations list and proves the seeded stops are there with the names and types
// the later cases' fixtures name. It depends only on routes that already exist,
// so a failure here is a seed failure and not a Map view failure.
//
// Captures are written only when `STOPS_MAP_CAPTURE_DIR` is set, resolved
// against the assets working directory. They are for visual inspection, not
// assertions.
import { test, expect } from "@playwright/test";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { bodyFitsViewport } from "./browser_helpers";

const EDITOR = {
  email: "stops-map@gtfs-planner.test",
  password: "StopsMapBrowser1",
};

const VERSION_NAME = "Browser Stops Map Version";

// A published version with no stops, for the list's first-use state.
const EMPTY_VERSION_NAME = "Browser Stops Map Empty Version";

const DESKTOP = { width: 1440, height: 900, label: "desktop" };
const MOBILE = { width: 390, height: 844, label: "mobile" };

const CAPTURE_DIR = process.env.STOPS_MAP_CAPTURE_DIR;

// The reference prototype is an HTML mock-up that is not committed to this
// repository. STOPS_MAP_SPEC_ROOT names a directory holding
// `references/stop-add-edit-prototype.html`; the reference captures, which put
// the prototype beside the real page for visual comparison, are skipped without
// it.
const SPEC_ROOT = process.env.STOPS_MAP_SPEC_ROOT || "";
const REFERENCE_FILE = SPEC_ROOT
  ? resolve(SPEC_ROOT, "references", "stop-add-edit-prototype.html")
  : "";

// A 1×1 transparent PNG, so the workspace never depends on the Geoapify plan or
// on network access. The stops, the lines and the chrome are the subject of
// these captures; the streets under them are not.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

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

// The capture name carries the viewport, so one case covers both sizes without
// a second label.
function viewportLabel(page) {
  const size = page.viewportSize();
  const viewport = [DESKTOP, MOBILE].find((c) => c.width === size.width);

  if (!viewport) {
    throw new Error(
      `Declare the ${size.width}×${size.height} viewport before capturing it`,
    );
  }

  return viewport.label;
}

// One state at both viewports: 1440×900 for the comparison with the reference,
// and 390×844 for the stacked workspace and the no-horizontal-scroll check.
async function captureBoth(page, testInfo, name, prefix = "shell-") {
  await expectFits(page);
  await capture(page, testInfo, `${prefix}${name}-desktop`);

  await page.setViewportSize(MOBILE);
  await expectFits(page);
  await capture(page, testInfo, `${prefix}${name}-mobile`);

  await page.setViewportSize(DESKTOP);
}

// The same state from the reference prototype, at the current viewport, for the
// side-by-side inspection. Skipped when STOPS_MAP_SPEC_ROOT is unset or the
// prototype file is missing, which is not a failure of this spec.
async function captureReference(
  page,
  testInfo,
  state,
  name,
  prefix = "shell-ref-",
) {
  if (!REFERENCE_FILE || !existsSync(REFERENCE_FILE)) return null;

  await page.setViewportSize(DESKTOP);
  await page.goto(`file://${REFERENCE_FILE}?state=${state}`);
  await page.waitForLoadState("load");

  await capture(page, testInfo, `${prefix}${name}-${state}-desktop`, {
    fullPage: false,
  });

  await page.setViewportSize(MOBILE);
  await page.goto(`file://${REFERENCE_FILE}?state=${state}`);
  await page.waitForLoadState("load");

  await capture(page, testInfo, `${prefix}${name}-${state}-mobile`, {
    fullPage: false,
  });

  await page.setViewportSize(DESKTOP);
  return true;
}

async function expectFits(page) {
  const { width } = page.viewportSize();

  expect(
    await bodyFitsViewport(page),
    `the map workspace scrolls horizontally at ${width} px`,
  ).toBe(true);
}

// The Map view of the seeded version, past the read and with the hook's view
// reported. The bounds are the seed's own extent with a margin, so the panel
// lists the stops the map is showing.
async function openMap(page, versionId) {
  await page.goto(`/gtfs/${versionId}/stops/map`);
  await waitForLiveView(page);

  await expect(page.locator("#stops-map-page")).toBeAttached();
  await expect(page.locator("#stops-map-panel")).toBeAttached();

  return page;
}

// Past the scene draw. The hook reports readiness by pushing `stop_map_ready`,
// which is what clears the stage's loading overlay, and Leaflet marks its own
// container once it owns it — so this waits for the drawing rather than for a
// timeout.
async function waitForMapReady(page) {
  await expect(page.locator("#stop-map.leaflet-container")).toBeAttached();
  await expect(
    page.locator("#stop-map .stop-map-marker").first(),
  ).toBeAttached();
  // The stage's loading overlay is the server's word that the map is not up yet.
  await expect(page.locator("#stops-map-loading-caption")).toHaveCount(0);
}

// How many of each mark the hook drew. Read from the DOM rather than from the
// hook, so a broken redraw is a wrong count and not a passing assertion about
// the hook's own bookkeeping.
async function drawnCounts(page) {
  return page.evaluate(() => ({
    stops: document.querySelectorAll("#stop-map .stop-map-marker").length,
    lines: document.querySelectorAll("#stop-map .leaflet-overlay-pane path")
      .length,
    ticks: document.querySelectorAll("#stop-map .stop-map-tick").length,
    bays: document.querySelectorAll("#stop-map .stop-map-bay").length,
  }));
}

// The workspace's own zoom stack, clicked the way a person would. A station's
// bays sit metres apart, so the map has to be closed in before they are marks
// of their own.
async function zoom(page, steps) {
  const label = steps > 0 ? "Zoom in" : "Zoom out";
  for (let step = 0; step < Math.abs(steps); step++) {
    await page.locator(`[aria-label="${label}"]`).click();
  }
}

// The tile URL carries its own zoom, which is the only place the map's zoom is
// readable from outside the hook — and what a mark shows is stated in zooms: a
// bay separates from its station at 18, a name is readable up to 16.
async function mapZoom(page) {
  return page.evaluate(() => {
    const tile = document.querySelector("#stop-map img.leaflet-tile");
    if (!tile) return null;

    return Number(new URL(tile.src).pathname.split("/").at(-3));
  });
}

// ── seed ──────────────────────────────────────────────────────────────────

// The seed check. The stop names, the duplicate pair and the station are the
// fixture the Map view cases build on, so they are asserted here as literals
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
    await expect(
      page
        .locator("#stops-workbench")
        .getByText(name, { exact: false })
        .first(),
    ).toBeAttached();
  }

  // The list is paginated; the two SE 1st St rows are the duplicate pair, so
  // both IDs are on the first page only if the seed really wrote both.
  await expect(page.getByText("1434", { exact: true }).first()).toBeAttached();
  await expect(page.getByText("1433", { exact: true }).first()).toBeAttached();

  await capture(page, testInfo, "seed-stops-list");
});

// ── shell ─────────────────────────────────────────────────────────────────

// The Map view's shell: the header with its List | Map switch, the map stage,
// and the browse panel holding the stops inside the current view. This is the
// state every later capture starts from, so its assertions are the ones a
// regression in the shell would break first.
//
// The drawn map has its own cases below; here the stage is captured as the shell
// leaves it.
test("the map view shell @shell", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);

  await expect(page.locator("h1")).toHaveText("Stops & stations");
  await expect(page.locator("#stops-map-view-list")).toHaveText("List");
  await expect(page.locator("#stops-map-view-map")).toHaveText("Map");
  await expect(page.locator("#stops-map-add-stop")).toContainText("Add stop");

  // The stage is the hook's container and nothing else: the hook owns every
  // child, so the page renders it empty.
  await expect(
    page.locator("#stop-map[phx-hook=StopMap][phx-update=ignore]"),
  ).toBeAttached();

  // The panel says what it holds, and its count is the header's count: one
  // sentence, two places, so the page never contradicts itself.
  await expect(page.locator("#stops-map-panel")).toContainText(
    "Stops in this area",
  );
  await expect(page.locator("#stops-map-panel")).toContainText(
    "16 stops and 1 station in Browser Stops Map Version",
  );
  await expect(page.locator("#stops-map-scope-note")).toHaveText(
    "16 stops and 1 station in Browser Stops Map Version",
  );
  await expect(page.locator("#stops-map-row-1434")).toContainText(
    "US 101 & SE 1st St",
  );
  await expect(page.locator("#stops-map-row-ST-NTC")).toContainText("Station");

  await captureBoth(page, testInfo, "map");
  await captureReference(page, testInfo, "map", "map");
});

test("the shell at both viewports @shell", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);

  // 1440 px puts the map and the 408 px panel side by side; 390 px stacks them.
  // Neither may scroll sideways.
  await page.setViewportSize(DESKTOP);
  expect(
    await page.evaluate(() => {
      const stage = document.querySelector("#stops-map-stage");
      const panel = document.querySelector("#stops-map-panel");
      return {
        stage: stage?.getBoundingClientRect(),
        panel: panel?.getBoundingClientRect(),
      };
    }),
  ).toMatchObject({ panel: expect.anything() });

  await captureBoth(page, testInfo, "workspace");
});

// ── render ────────────────────────────────────────────────────────────────

// The drawn map: stops as discs with a travel tick, a station as a filled
// square, a bay as a lettered disc, and every pattern as two parallel lines
// offset to the right of travel. The basemap toggle and the routes toggle are
// client-only, so both are driven here rather than round-tripped.
test("the drawn map @render", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  // The stage is fitted to the whole feed, so every located stop in the seed is
  // drawn except the two bays their station stands in for at this scale.
  const atFit = await drawnCounts(page);
  const fitZoom = await mapZoom(page);
  expect(atFit.lines).toBeGreaterThan(0);
  expect(atFit.ticks).toBeGreaterThan(0);
  // The canvas is focusable, which is what lets the arrow keys pan it once
  // Leaflet's keyboard handling has it.
  await expect(page.locator("#stop-map")).toHaveAttribute("tabindex", "0");
  // Below the bay zoom the station stands in for the bays folded into it; the
  // seed's two are thirteen metres apart and their discs would land on it.
  expect(atFit.bays).toBe(fitZoom >= 18 ? 2 : 0);
  expect(atFit.stops).toBe(fitZoom >= 18 ? 17 : 15);

  // The legend describes marks that are actually on the map: a station square.
  await expect(
    page.locator("#stop-map .stop-map-station").first(),
  ).toBeAttached();

  // The panel's list still follows the map: the hook's view report is what
  // filled it, and the seed's stops are all inside the fitted extent.
  await expect(page.locator("#stops-map-row-1434")).toBeAttached();

  await captureBoth(page, testInfo, "map", "render-");
  await capture(page, testInfo, "render-street-desktop");

  // At the fitted view no stop carries a name: the basemap's own street names
  // are the text at that scale, and the panel's list is where a stop's name
  // belongs.
  expect(await page.locator("#stop-map .stop-map-label").count()).toBe(0);

  // Closed in, the bays separate and take their letters and the stops take their
  // names. The lines stay: a road wide enough on screen carries one line
  // without the offset that keeps two buses apart.
  // Closed in only as far as the bays need: the feed's own extent is a few
  // blocks, so eight steps would put the camera somewhere past the last stop.
  await zoom(page, Math.max(1, 18 - fitZoom));
  expect((await mapZoom(page)) >= 18).toBe(true);
  const closed = await drawnCounts(page);
  expect(closed.bays).toBe(2);
  expect(closed.stops).toBe(17);
  expect(closed.lines).toBe(atFit.lines);
  expect(
    await page.locator("#stop-map .stop-map-label").count(),
  ).toBeGreaterThan(0);

  // The two bays are attached and carry their letters; the seed's station sits
  // at the west edge of the extent, so at this zoom they are drawn off the
  // captured canvas rather than in it. The capture is of the marks and names a
  // reader actually gets at street zoom.
  await expect(page.locator("#stop-map .stop-map-bay").first()).toBeAttached();
  await capture(page, testInfo, "render-street-zoom-desktop");

  await captureReference(page, testInfo, "map", "map", "render-ref-");
});

test("the basemap and routes toggles @render", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  const withRoutes = (await drawnCounts(page)).lines;

  // Unchecking Routes leaves the stops where they are and takes the lines away:
  // a line is context, and an editor reading one street wants the stops on it.
  await page.locator("#stops-map-legend [data-map-routes]").uncheck();
  expect((await drawnCounts(page)).lines).toBe(0);
  expect((await drawnCounts(page)).stops).toBeGreaterThan(0);

  await page.locator("#stops-map-legend [data-map-routes]").check();
  expect((await drawnCounts(page)).lines).toBe(withRoutes);

  // The basemap pair is a choice, so exactly one of the two is pressed.
  await expect(
    page.locator('#stops-map-legend [data-map-basemap="streets"]'),
  ).toHaveAttribute("aria-pressed", "true");

  await capture(page, testInfo, "render-streets-desktop");

  await page
    .locator('#stops-map-legend [data-map-basemap="satellite"]')
    .click();
  await expect(
    page.locator('#stops-map-legend [data-map-basemap="satellite"]'),
  ).toHaveAttribute("aria-pressed", "true");
  await expect(
    page.locator('#stops-map-legend [data-map-basemap="streets"]'),
  ).toHaveAttribute("aria-pressed", "false");

  await capture(page, testInfo, "render-satellite-desktop");
  await captureReference(
    page,
    testInfo,
    "satellite",
    "satellite",
    "render-ref-",
  );
});

test("the drawn map at both viewports @render", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  // 1440 px puts the map beside the 408 px panel; 390 px stacks them above it,
  // and the legend wraps rather than pushing the page sideways.
  await expectFits(page);
  await capture(page, testInfo, "render-map-desktop");

  await page.setViewportSize(MOBILE);
  await waitForMapReady(page);
  await expectFits(page);
  await capture(page, testInfo, "render-map-mobile");

  await page.setViewportSize(DESKTOP);
});

// ── pin ───────────────────────────────────────────────────────────────────

// Add mode and the placement pin: the crosshair the Enter key places at, the
// pin a click drops, and the drag and nudge that adjust it. The hook reports
// what a person did and the server decides what it means, so what this asserts
// is the round trip — a click is a placement, a nudge is a move, and cancelling
// is the browse panel with no caption left over.
test("the placement pin @pin", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  // Closed in first: the seed's extent is a few blocks, and a metre is a third
  // of a pixel at the fitted zoom — too small to move a pin with.
  await zoom(page, 3);
  await waitForMapReady(page);

  await page.locator("#stops-map-add-stop").click();

  // Add mode: the crosshair is there, the pin is not, and the caption says
  // both ways in — click, and Enter at the crosshair.
  await expect(page.locator("#stops-map-add-panel")).toBeAttached();
  await expect(page.locator("#stop-map-crosshair")).toBeVisible();
  await expect(page.locator("[data-stop-map-pin]")).toHaveCount(0);
  await expect(page.locator("#stops-map-caption")).toContainText(
    "Press Enter to place it at the crosshair",
  );

  await captureBoth(page, testInfo, "add-choose", "pin-");

  // A click on the canvas places the pin where it was clicked. The centre is
  // clicked because that is a point the assertions can name.
  const canvas = await page.locator("#stop-map").boundingBox();
  const centre = {
    x: canvas.x + canvas.width / 2,
    y: canvas.y + canvas.height / 2,
  };

  await page.mouse.click(centre.x, centre.y);

  await expect(page.locator("[data-stop-map-pin]")).toBeAttached();
  await expect(page.locator("#stop-map-crosshair")).toBeHidden();
  await expect(page.locator("#stops-map-caption")).toContainText(
    "Drag the pin to adjust",
  );

  // The pin is drawn where the click landed, which is what makes the caption's
  // promise about the crosshair and Enter the same promise the click makes.
  const placed = await pinPosition(page);
  expect(Math.abs(placed.x - canvas.width / 2)).toBeLessThan(3);
  expect(Math.abs(placed.y - canvas.height / 2)).toBeLessThan(3);

  // It is a focusable button that says what its keys do.
  await expect(page.locator("[data-stop-map-pin]")).toHaveAttribute(
    "aria-label",
    /arrow keys to move it about 3 feet, 30 feet with Shift/,
  );

  await capture(page, testInfo, "pin-add-placed-desktop");

  // The arrow keys nudge the pin and the nudge survives the server's echo.
  await page.locator("[data-stop-map-pin]").focus();
  const before = placed;
  await page.keyboard.press("Shift+ArrowUp");

  await expect
    .poll(async () => {
      const now = await pinPosition(page);
      return Math.round(now.y);
    })
    .not.toBe(Math.round(before.y));

  // Dragging it is the same report, once, on pointerup.
  const pin = await page.locator("[data-stop-map-pin]").boundingBox();
  await page.mouse.move(pin.x + pin.width / 2, pin.y + pin.height / 2);
  await page.mouse.down();
  await page.mouse.move(
    pin.x + pin.width / 2 + 60,
    pin.y + pin.height / 2 - 40,
    {
      steps: 8,
    },
  );
  await page.mouse.up();

  const dragged = await pinPosition(page);
  expect(Math.round(dragged.x)).toBeGreaterThan(Math.round(before.x));
  expect(dragged.y).toBeLessThan(before.y);

  await capture(page, testInfo, "pin-moved-desktop");

  // 390 px stacks the map above the panel, and the pin is still the pin — in
  // the canvas, not at the pixels a desktop window put it at.
  await page.setViewportSize(MOBILE);
  await waitForMapReady(page);
  await expectFits(page);
  await expect(page.locator("[data-stop-map-pin]")).toBeAttached();
  await expect(page.locator("[data-stop-map-pin]")).toBeInViewport();
  await capture(page, testInfo, "pin-add-placed-mobile");

  await page.setViewportSize(DESKTOP);

  // Escape cancels: the browse panel, no caption, and no pin left on the map.
  await page.locator("#stops-map-add-stop").click();
  await expect(page.locator("#stop-map-crosshair")).toBeVisible();
  await page.locator("#stop-map").focus();
  await page.keyboard.press("Escape");

  await expect(page.locator("#stops-map-list")).toBeAttached();
  await expect(page.locator("#stops-map-caption")).toHaveCount(0);
  await expect(page.locator("[data-stop-map-pin]")).toHaveCount(0);

  // The prototype's three placement states, at both viewports, for the
  // side-by-side inspection. Taken last: it leaves the browser on the file URL.
  for (const state of ["add-choose", "add-placed", "move"]) {
    for (const viewport of [DESKTOP, MOBILE]) {
      await page.setViewportSize(viewport);
      await page.goto(`file://${REFERENCE_FILE}?state=${state}`);
      await page.waitForLoadState("load");

      await capture(page, testInfo, `pin-ref-${state}-${viewport.label}`, {
        fullPage: false,
      });
    }
  }

  await page.setViewportSize(DESKTOP);
});

// Where the hook drew the pin, in container pixels. Read from the element's own
// positioning, because the hook keeps no global to read and the tile URL
// carries the map's zoom but not the pin's place in it.
async function pinPosition(page) {
  return page.evaluate(() => {
    const button = document.querySelector("[data-stop-map-pin]");
    return {
      x: parseFloat(button.style.left),
      y: parseFloat(button.style.top),
    };
  });
}

// ── search ─────────────────────────────────────────────────────────────────

// The panel's search: this version's stops by name or ID, and the address
// service's places, in one field. What this asserts is the round trip the
// server owns — a query reaches the adapter, the stops come back without the
// address service being needed, and choosing a place is a placement, which the
// map answers with a pin.
test("the panel search @search", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  // The field is there before anything is typed, and it says what it will
  // answer: a stop in this feed, or a place to put one at.
  await expect(page.locator("#stops-map-search")).toBeVisible();
  await expect(page.locator("#stops-map-search-query")).toBeVisible();
  await expect(page.locator("#stops-map-list")).toBeAttached();

  // "1st" is in the seeded version's own stop names, so this half of the answer
  // comes from this feed rather than from the address service.
  await page.locator("#stops-map-search-query").fill("1st");
  await expect(page.locator("#stops-map-search-results-stops")).toBeAttached();
  await expect(
    page.locator("#stops-map-search-results-stops li", {
      hasText: "SE 1st St",
    }),
    // Two, not one: the seed's duplicate pair shares this name, and a search
    // that hid one of them would be hiding a real stop.
  ).toHaveCount(2);

  // The browser adapter answers above its three-character minimum, so a place
  // comes back too — the two groups are the field's two answers.
  await expect(page.locator("#stops-map-search-results-places")).toBeAttached();
  await expect(
    page.locator("#stops-map-search-results-places", { hasText: "Depot Road" }),
  ).toHaveCount(1);

  // The list the search replaced is gone rather than pushed down: forty rows
  // under a result set is a page an editor scrolls past.
  await expect(page.locator("#stops-map-list")).toHaveCount(0);

  await captureBoth(page, testInfo, "results", "search-");

  // Choosing a stop result selects it, and the panel's heading says which one.
  await page
    .locator("#stops-map-search-results-stops li button")
    .first()
    .click();
  await expect(page.locator("#stops-map-panel h2")).toContainText("SE 1st St");
  await expect(page.locator("#stops-map-panel")).toContainText("Stop · ID");

  // Clearing the field gives the list back.
  await page.locator("#stops-map-search-query").fill("");
  await expect(page.locator("#stops-map-list")).toBeAttached();
  await expect(page.locator("#stops-map-search-results")).toHaveCount(0);

  // A query that matches nothing says what to try rather than showing nothing.
  // Two characters is the one a browser run can reach: the address service's
  // three-character minimum refuses a shorter query, so no place comes back to
  // sit beside the empty message.
  await page.locator("#stops-map-search-query").fill("zz");
  await expect(page.locator("#stops-map-search-results-empty")).toContainText(
    "Try a street name",
  );
  await capture(page, testInfo, "search-empty-desktop");

  // Add mode offers an address rather than this version's stops, and choosing
  // a place is a placement: the pin lands there and add mode ends.
  await page.locator("#stops-map-search-query").fill("");
  await page.locator("#stops-map-add-stop").click();
  await expect(page.locator("#stops-map-address-search")).toBeVisible();
  await expect(page.locator("#stops-map-address-hint")).toContainText(
    "Results favour places near your stops",
  );

  await page.locator("#stops-map-address-search-query").fill("Depot");
  await expect(
    page.locator("#stops-map-address-results-places"),
  ).toBeAttached();
  await expect(page.locator("#stops-map-list")).toHaveCount(0);

  await captureBoth(page, testInfo, "add-search", "search-");

  await page.locator("[data-stop-map-place]").first().click();
  await expect(page.locator("[data-stop-map-pin]")).toBeAttached();
  await expect(page.locator("#stops-map-crosshair")).toBeHidden();
  await expect(page.locator("#stops-map-caption")).toContainText(
    "Drag the pin to adjust",
  );

  await capture(page, testInfo, "search-add-placed-desktop");
  await page.setViewportSize(MOBILE);
  await waitForMapReady(page);
  await expectFits(page);
  // Attached rather than in the viewport: the browser adapter's place is in
  // Cedar Valley and this feed is in Newport, so the pin is legitimately off
  // the canvas the map is showing. Not asserted here.
  await expect(page.locator("[data-stop-map-pin]")).toBeAttached();
  await capture(page, testInfo, "search-add-placed-mobile");
  await page.setViewportSize(DESKTOP);

  // The prototype's two search states, at both viewports, for the side-by-side
  // inspection.
  if (REFERENCE_FILE && existsSync(REFERENCE_FILE)) {
    for (const state of ["search", "add-search"]) {
      for (const viewport of [DESKTOP, MOBILE]) {
        await page.setViewportSize(viewport);
        await page.goto(`file://${REFERENCE_FILE}?state=${state}`);
        await page.waitForLoadState("load");

        await capture(page, testInfo, `search-ref-${state}-${viewport.label}`, {
          fullPage: false,
        });
      }
    }
  }

  await page.setViewportSize(DESKTOP);
});

// ── checks ─────────────────────────────────────────────────────────────────

// The browse panel's "things to check" disclosure: the version's placement
// findings, read after the list rather than with it. What this asserts is that
// the findings reach the real page, that the disclosure is a control a person
// can open, and that "They're different stops" removes a row for this session
// and writes nothing to the feed.
test("the version checks @checks", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  // The disclosure is closed and says how much is inside it. It is a control,
  // not a decoration: the count is text and the state is `aria-expanded`.
  const toggle = page.locator("#stops-map-checks-toggle");
  await expect(toggle).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(toggle).toContainText("things to check");
  await expect(toggle).toContainText("Show");

  // The list is already painted while the findings are still being read, and
  // the findings never replace it.
  await expect(page.locator("#stops-map-list")).toBeAttached();

  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await expect(toggle).toContainText("Hide");

  // The seed's duplicate pair is 1.5 m apart, so the row names a distance an
  // editor can act on and offers both of the answers the finding allows.
  const duplicate = page
    .locator('#stops-map-checks li[data-check-kind="duplicate"]')
    .first();
  await expect(duplicate).toBeVisible();
  await expect(duplicate).toContainText(/Two stops \d+ (ft|mi) apart/);
  await expect(duplicate).toContainText("Riders see two stops at one sign");
  await expect(
    duplicate.getByRole("button", { name: "Review pair" }),
  ).toBeVisible();
  await expect(
    duplicate.getByRole("button", { name: "They’re different stops" }),
  ).toBeVisible();

  // The seed's unserved stop is listed as unserved, with the reason and the
  // one thing to try.
  const unserved = page
    .locator('#stops-map-checks li[data-check-kind="not_served"]')
    .first();
  await expect(unserved).toBeVisible();
  await expect(unserved).toContainText("isn’t served");
  await expect(unserved).toContainText("No pattern stops here");
  await expect(
    unserved.getByRole("button", { name: "Show stop" }),
  ).toBeVisible();

  await captureBoth(page, testInfo, "checks-open", "checks-");

  // "Show stop" names a stop, and the map goes to it: the stop the row is about
  // is the stop the panel's heading now names.
  await unserved.getByRole("button", { name: "Show stop" }).click();
  await expect(page.locator("#stops-map-panel h2")).not.toHaveText(
    "Stops in this area",
  );

  // Dismissing a finding removes that row and takes the count with it. Nothing
  // is written: the feed the browser reads back is the feed it started with.
  const before = await countDisclosureRows(page);
  await duplicate
    .getByRole("button", { name: "They’re different stops" })
    .click();
  await expect(
    page.locator('#stops-map-checks li[data-check-kind="duplicate"]'),
  ).toHaveCount(0);
  expect(await countDisclosureRows(page)).toBe(before - 1);

  await capture(page, testInfo, "checks-dismissed-desktop");
  await page.setViewportSize(MOBILE);
  await expectFits(page);
  await capture(page, testInfo, "checks-dismissed-mobile");
  await page.setViewportSize(DESKTOP);

  // The prototype's checks state, at both viewports, for the side-by-side
  // inspection.
  if (REFERENCE_FILE && existsSync(REFERENCE_FILE)) {
    for (const state of ["checks"]) {
      for (const viewport of [DESKTOP, MOBILE]) {
        await page.setViewportSize(viewport);
        await page.goto(`file://${REFERENCE_FILE}?state=${state}`);
        await page.waitForLoadState("load");

        await capture(page, testInfo, `checks-ref-${state}-${viewport.label}`, {
          fullPage: false,
        });
      }
    }
  }

  await page.setViewportSize(DESKTOP);
});

// How many findings the disclosure is currently showing, read from the rows
// rather than from the summary's own words, so a stale count fails here too.
async function countDisclosureRows(page) {
  return page.locator("#stops-map-checks-items li").count();
}

// ── add a stop ─────────────────────────────────────────────────────────────

// Adding a stop, end to end: a point on the map, a name from the streets, the
// warnings the placement deserves, a refusal the reader can act on, and the
// stop that exists afterwards.
//
// What is asserted here is the round trip the browser actually has — the pin's
// event, the reverse geocode, the panel's copy, the created panel. The rules
// behind the copy (which side of a line is the far side, when two stops are
// duplicates) are the LiveView test's job, because a click on a map cannot
// name a metre.
test("the add panel @add", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  // Closed in first, like a person who can see the street edge: at the fitted
  // zoom a click cannot land within thirty metres of a route's shape, and the
  // panel has nothing to say about a side from that far away.
  await zoom(page, 3);
  await waitForMapReady(page);

  // The panel offers the ways in, and says what the next click does before it
  // is asked for it.
  await page.locator("#stops-map-add-stop").click();
  await expect(page.locator("#stops-map-add-panel")).toBeAttached();
  await expect(page.locator("#stops-map-add-coords-toggle")).toHaveAttribute(
    "aria-expanded",
    "false",
  );
  await expect(page.locator("#stops-map-add-name")).toBeAttached();

  await captureBoth(page, testInfo, "panel", "add-");

  // A click on the line the map drew places the pin on it, which is the
  // placement the panel has the most to say about: the side it landed on, the
  // name the streets give it and the description a rider reads on the sign.
  await clickOnLine(page);
  await expect(page.locator("[data-stop-map-pin]")).toBeAttached();
  await expect(page.locator("#stops-map-add-where")).not.toHaveText("");
  await expect(page.locator("#stops-map-add-lat")).not.toHaveValue("");
  await expect(page.locator("#stops-map-add-lon")).not.toHaveValue("");

  await expect(page.locator("#stops-map-add-name")).toHaveValue("Depot Road", {
    timeout: 30_000,
  });

  // Beside a line the description is not empty: it is the side of the line the
  // pin is on, which is the thing the name cannot say.
  await expect(page.locator("#stops-map-add-where")).toContainText(
    "side of the",
  );
  await expect(page.locator("#stops-map-add-desc")).toHaveValue(/./);

  await captureBoth(page, testInfo, "suggested", "add-");

  // A pasted pair is the other way in: both numbers arrive at once, and the pin
  // follows them rather than the editor hunting for them on the map.
  await page.locator("#stops-map-add-cancel").click();
  await page.locator("#stops-map-add-stop").click();
  await page.locator("#stops-map-add-coords-toggle").click();
  await expect(page.locator("#stops-map-add-coords-toggle")).toHaveAttribute(
    "aria-expanded",
    "true",
  );
  await page.locator("#stops-map-add-lat").fill("44.6358, -124.0531");
  await expect(page.locator("#stops-map-add-lon")).toHaveValue("-124.0531");
  await expect(page.locator("[data-stop-map-pin]")).toBeAttached();

  await capture(page, testInfo, "add-pasted-desktop");

  // Creating without a name is refused, and the refusal survives the render:
  // the summary, the field marked for assistive technology, and nothing
  // written. The name the streets suggested is cleared the way an editor clears
  // it, so what is refused is the draft as it stands.
  await page.locator("#stops-map-add-name").fill("");
  await page.locator("#stops-map-add-create").click();
  await expect(page.locator("#stops-map-add-errors")).toBeAttached();
  await expect(page.locator("#stops-map-add-name")).toHaveAttribute(
    "aria-invalid",
    "true",
  );

  await captureBoth(page, testInfo, "refused", "add-");

  // The draft is still a draft: fixing the name and creating it works without
  // placing it again.
  await page.locator("#stops-map-add-name").fill("Cedar Valley Depot");
  await expect(page.locator("#stops-map-add-name")).toHaveAttribute(
    "aria-invalid",
    "false",
  );
  await page.locator("#stops-map-add-create").click();

  await expect(page.locator("#stops-map-created-panel")).toBeAttached();
  await expect(page.locator("#stops-map-created-panel")).toContainText(
    "Stop created",
  );
  await expect(page.locator("#stops-map-created-panel")).toContainText(
    "Cedar Valley Depot",
  );

  await captureBoth(page, testInfo, "created", "add-");

  // "Add another stop" opens a fresh draft rather than a second copy of this
  // one: the created panel is a confirmation, not a form.
  await page.locator("#stops-map-created-another").click();
  await expect(page.locator("#stops-map-add-panel")).toBeAttached();
  await expect(page.locator("#stops-map-add-name")).toHaveValue("");
  await expect(page.locator("[data-stop-map-pin]")).toHaveCount(0);

  // Cancelling that draft brings the version's list back, and the stop the
  // created panel named is in it: the write went to this version.
  await page.locator("#stops-map-add-cancel").click();
  await expect(page.locator("#stops-map-list")).toBeAttached();

  const inList = await page
    .locator("#stops-map-list li")
    .filter({ hasText: "Cedar Valley Depot" })
    .count();
  expect(inList).toBe(1);
});

// A station is the other kind of stop: it needs no line and no pattern, and the
// panel says so instead of asking for them.
test("adding a station @add", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  await page.locator("#stops-map-add-stop").click();
  await page.locator("#stops-map-add-kind-station").click();

  // The heading says what is being made, and the create button follows it.
  await expect(page.locator("#stops-map-add-panel h2")).toHaveText(
    "New station",
  );
  await expect(page.locator("#stops-map-add-create")).toContainText(
    "Create station",
  );

  await capture(page, testInfo, "add-station-panel-desktop");

  await clickCentre(page);
  await expect(page.locator("#stops-map-add-name")).toHaveValue("Depot Road", {
    timeout: 30_000,
  });

  await page.locator("#stops-map-add-create").click();
  await expect(page.locator("#stops-map-created-panel")).toContainText(
    "Station created",
  );

  await captureBoth(page, testInfo, "station-created", "add-");
});

// A placement that lands on top of what is already there is told so, with the
// two answers the finding allows, before anything is written.
test("what a placement is told @add", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  // Closed in so that a few pixels are a few metres, which is what makes a
  // click "the same place as a stop" rather than "somewhere near it".
  await zoom(page, 3);
  await waitForMapReady(page);

  await page.locator("#stops-map-add-stop").click();

  // A click beside a stop rather than on it: the mark itself opens the stop's
  // row, and the placement is what is being measured.
  const box = await onMapMarkerBox(page);

  for (const [dx, dy] of [
    [16, 16],
    [-16, 16],
    [16, -16],
    [-16, -16],
    [24, 0],
    [0, 24],
  ]) {
    await page.mouse.click(
      box.x + box.width / 2 + dx,
      box.y + box.height / 2 + dy,
    );
    if ((await page.locator("[data-stop-map-pin]").count()) > 0) break;

    // A click that landed on the mark opened that stop's row instead of placing
    // a draft. Back to add mode, and on to the next point.
    if ((await page.locator("#stops-map-add-panel").count()) === 0) {
      await page.locator("#stops-map-add-stop").click();
      await expect(page.locator("#stops-map-add-panel")).toBeAttached();
    }
  }

  await expect(page.locator("[data-stop-map-pin]")).toBeAttached();

  // The stop a few tens of feet away is named, with the distance a rider would
  // use. This placement is too far to be a duplicate, so the row is a sentence
  // and not a warning with a button.
  const nearby = page.locator('[data-add-warning="nearby"]').first();
  await expect(nearby).toBeVisible({ timeout: 30_000 });
  await expect(nearby).toHaveText(/.+ \(\d+ (ft|mi)\)\./);
  await expect(nearby.getByRole("button")).toHaveCount(0);

  await captureBoth(page, testInfo, "nearby", "add-");

  // On the line itself, the panel has a side to describe and says so. The click
  // is made at a point on the stroke itself, read from the SVG rather than
  // guessed from a box: a point a few pixels off a route is not "on" it.
  await clickOnLine(page);
  await expect(page.locator("#stops-map-add-where")).toContainText(
    "side of the",
  );
  await expect(page.locator("#stops-map-add-desc")).toHaveValue(/./);

  await captureBoth(page, testInfo, "on-the-line", "add-");

  // Every advisory row carries at most one action, and an action names what it
  // does. The rows themselves are the server's findings: which one appears is
  // the geometry's answer, and the LiveView test is what proves each action.
  const actions = await page
    .locator("#stops-map-add-warnings button")
    .allTextContents();

  for (const label of actions.map((text) => text.trim())) {
    expect(["Move it across the street"]).toContain(label);
  }
});

// The capture of the create in flight. The button's own label is the state, and
// it is asserted rather than photographed: the write is one round trip and the
// window in which the button says "Creating…" is narrower than a screenshot.
test("the creating state @add", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  await page.locator("#stops-map-add-stop").click();
  await clickCentre(page);
  await expect(page.locator("#stops-map-add-name")).toHaveValue("Depot Road", {
    timeout: 30_000,
  });

  await page.locator("#stops-map-add-create").click();
  await expect(page.locator("#stops-map-created-panel")).toBeAttached();

  await capture(page, testInfo, "add-saving-desktop");
});

// ── created ───────────────────────────────────────────────────────────────

// The panel after a stop exists is the one place that knows which patterns pass
// the point: the new stop is not on any pattern yet, and nothing about the map
// says where it would go. The journey places a stop on a line the map drew,
// creates it, and reads the list back — the pattern, the two stops it would fall
// between, and the link that carries the stop into the pattern editor.
test("the created panel's next steps @created", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);
  await waitForMapReady(page);

  await zoom(page, 3);
  await waitForMapReady(page);

  await page.locator("#stops-map-add-stop").click();
  await clickOnLine(page);

  await expect(page.locator("#stops-map-add-name")).toHaveValue("Depot Road", {
    timeout: 30_000,
  });

  await page.locator("#stops-map-add-create").click();
  await expect(page.locator("#stops-map-created-panel")).toBeAttached();
  await expect(page.locator("#stops-map-created-patterns")).toBeAttached();

  // At least one pattern passes this point, and each one says where on the
  // pattern the stop would go: a list without the neighbours is a list an editor
  // has to open the pattern to act on.
  const rows = page.locator("#stops-map-created-patterns li");
  await expect(rows.first()).toBeAttached();
  await expect(rows.first()).toContainText("Between ");

  // The link carries the stop the create command wrote, so the pattern editor
  // opens with this stop in hand rather than asking which one.
  const href = await rows.first().locator("a").getAttribute("href");
  expect(href).toMatch(/\?task=stops&add_stop=\d+$/);

  await captureBoth(page, testInfo, "patterns", "created-");
  await captureReference(page, testInfo, "created", "created", "created-ref-");
});

// ── edit a stop ──────────────────────────────────────────────────────────────

// The edit panel: the stop's own fields, where it is, what uses it, the footer
// that says whether there is anything to save, and the guard on every way out.
// The states are driven in the order a person meets them, so each capture is a
// step of the same journey.
test("the edit panel @edit", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  // A deep link opens the panel for the stop it names, which is where a link
  // from a pattern or a search result has to land.
  await page.goto(`/gtfs/${versionId}/stops/map?stop=1434`);
  await waitForLiveView(page);
  await waitForMapReady(page);

  await expect(page.locator("#stops-map-edit-panel")).toBeAttached();
  await expect(page.locator("#stops-map-edit-panel h2")).toHaveText(
    "US 101 & SE 1st St",
  );
  await expect(page.locator("#stops-map-edit-name")).toHaveValue(
    "US 101 & SE 1st St",
  );
  await expect(page.locator("#stops-map-edit-desc")).toHaveValue("Northbound");
  await expect(page.locator("#stops-map-edit-code")).toHaveValue("1434");
  await expect(page.locator("#stops-map-edit-lat")).toHaveValue("44.63561");
  await expect(page.locator("#stops-map-edit-lon")).toHaveValue("-124.05317");

  // Where it is, in the words the panel uses everywhere else: the route and the
  // end of it, rather than a pair of numbers to read twice.
  await expect(page.locator("#stops-map-edit-where")).toContainText("1");

  // The usage list answers after the fields do, so the wait is for the list.
  // A row per pattern, each with the route's own badge and the direction it
  // runs: those are what a rider recognises about a stop, not a total.
  await expect(page.locator("#stops-map-edit-used-items")).toContainText(
    "toward Lincoln City",
  );
  await expect(page.locator("#stops-map-edit-used-items")).toContainText(
    "toward Nye Beach",
  );

  const badges = await page
    .locator("#stops-map-edit-used-items .rounded-badge")
    .allTextContents();

  expect(badges.map((text) => text.trim()).sort()).toEqual(["1", "3"]);

  // The fare zone is a statement and a way to change it, not a control here:
  // the zone belongs to Settings › Fares.
  await expect(page.locator("#stops-map-edit-zone")).toHaveText(
    "Newport local",
  );
  await expect(page.locator("#stops-map-edit-zone-link")).toHaveAttribute(
    "href",
    /\/settings\/fares$/,
  );
  await expect(
    page.locator("#stops-map-edit-panel select[name*='zone']"),
  ).toHaveCount(0);

  // Nothing to save means nothing to press, and the footer says so in words.
  await expect(page.locator("#stops-map-edit-status")).toHaveText(
    "No changes yet",
  );
  await expect(page.locator("#stops-map-edit-save")).toBeDisabled();

  await captureBoth(page, testInfo, "edit", "edit-");

  // The dirty state is in the footer, and it is words rather than a colour.
  await page.locator("#stops-map-edit-desc").fill("Northbound, by Post Office");
  await expect(page.locator("#stops-map-edit-status")).toHaveText(
    "Unsaved changes",
  );
  await expect(page.locator("#stops-map-edit-save")).toBeEnabled();

  // The guard is on every exit. Escape is the one with no control of its own,
  // so the dialog it opens has to be the same one Cancel opens: the question is
  // about the draft, not about which key asked.
  await page.keyboard.press("Escape");
  await expect(page.locator("#stops-map-discard")).toHaveAttribute(
    "data-open",
    "true",
  );
  await expect(page.locator("#stops-map-discard")).toContainText(
    "Discard changes to US 101 & SE 1st St?",
  );

  await captureBoth(page, testInfo, "guard", "edit-");

  // Keeping the draft drops the exit and the draft survives it: the dialog is a
  // question, not a navigation.
  await page.locator("#stops-map-discard-keep").click();
  await expect(page.locator("#stops-map-discard")).toHaveAttribute(
    "data-open",
    "false",
  );
  await expect(page.locator("#stops-map-edit-desc")).toHaveValue(
    "Northbound, by Post Office",
  );

  // Cancel asks the same question and, on Discard changes, brings the
  // version's list back.
  await page.locator("#stops-map-edit-cancel").click();
  await expect(page.locator("#stops-map-discard")).toHaveAttribute(
    "data-open",
    "true",
  );
  await page.locator("#stops-map-discard-go").click();
  await expect(page.locator("#stops-map-edit-panel")).toHaveCount(0);
  await expect(page.locator("#stops-map-panel")).toBeAttached();

  await captureBoth(page, testInfo, "discarded", "edit-");

  // A stop the feed does not serve says so, and offers no choice about it:
  // the editor does not change the export, so the panel has no keep-in-feed
  // checkbox.
  await page.goto(`/gtfs/${versionId}/stops/map?stop=1531`);
  await waitForLiveView(page);
  await expect(page.locator("#stops-map-edit-panel")).toContainText(
    "Not served",
  );
  await expect(
    page.locator("#stops-map-edit-panel input[type=checkbox]"),
  ).toHaveCount(0);
  await expect(page.locator("#stops-map-edit-used-empty")).toBeAttached();

  await captureBoth(page, testInfo, "unserved", "edit-");

  // A station is the other kind of stop: trips stop at its bays, so the panel
  // lists them rather than offering fields a station has no use for.
  await page.goto(`/gtfs/${versionId}/stops/map?stop=ST-NTC`);
  await waitForLiveView(page);
  await expect(page.locator("#stops-map-edit-panel h2")).toHaveText(
    "Newport Transit Center",
  );
  await expect(page.locator("#stops-map-edit-bay-items")).toContainText(
    "Bay A",
  );

  await capture(page, testInfo, "edit-station-desktop");

  // The save-failed and conflict states are left to the ExUnit cases: the save
  // submits through the panel's own form, and this journey's presses on that
  // form did not reach the server, which is a known limit of this harness
  // rather than something to paper over with a synthetic event.

  // The prototype's own states for the same moments, captured last because the
  // reference is a file:// page: driving the app and reading the prototype are
  // two navigations, not one.
  await captureReference(page, testInfo, "edit", "edit", "edit-ref-");
  await captureReference(page, testInfo, "edit-dirty", "dirty", "edit-ref-");
  await captureReference(page, testInfo, "unserved", "unserved", "edit-ref-");
});

// A click on the canvas in the middle of the map, the way a person places a
// stop: the middle is a point the assertions and the capture can both name.
async function clickCentre(page) {
  const canvas = await page.locator("#stop-map").boundingBox();
  await page.mouse.click(
    canvas.x + canvas.width / 2,
    canvas.y + canvas.height / 2,
  );
}
// A click on the line the map drew, at a point on the stroke itself: the
// placement is then on a route's shape, which is what gives the panel a side to
// describe. The point comes from the SVG's own geometry, because a route's
// bounding box is not the route and a click in the middle of one is somewhere
// along it at best.
async function clickOnLine(page) {
  const points = await page.evaluate(() => {
    const map = document.querySelector("#stop-map").getBoundingClientRect();

    return [
      ...document.querySelectorAll("#stop-map .leaflet-overlay-pane path"),
    ]
      .map((path) => {
        const length = path.getTotalLength();
        if (!length) return null;

        const matrix = path.getScreenCTM();
        if (!matrix) return null;

        return [0.5, 0.35, 0.65, 0.2, 0.8]
          .map((fraction) => path.getPointAtLength(length * fraction))
          .map((point) => ({
            x: matrix.a * point.x + matrix.c * point.y + matrix.e,
            y: matrix.b * point.x + matrix.d * point.y + matrix.f,
          }))
          .filter(
            (point) =>
              point.x > map.left &&
              point.x < map.right &&
              point.y > map.top &&
              point.y < map.bottom,
          );
      })
      .filter(Boolean)
      .flat();
  });

  if (points.length === 0) {
    throw new Error("the map drew no line point inside the window to place on");
  }

  for (const point of points) {
    await page.mouse.click(point.x, point.y);

    const where = await page.locator("#stops-map-add-where").textContent();
    if (where && where.includes("side of the")) return;
  }

  throw new Error(
    "no point on a drawn line placed a draft the panel could give a side",
  );
}

// The move: a pin the editor drags, the ghost it left behind, the distance
// between them, and the review a served stop needs before its coordinates are
// written. Every state is driven the way a person drives it — a pointer drag on
// the pin, then a press of the panel's own button — so a capture is a state a
// reader could have reached.
test("moving a stop @move", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  await page.goto(`/gtfs/${versionId}/stops/map?stop=1434`);
  await waitForLiveView(page);
  await waitForMapReady(page);

  await expect(page.locator("#stops-map-edit-panel")).toBeAttached();

  // The pin is the stop's own position, so the editor has something to drag
  // before anything has been moved at all.
  const pin = page.locator(".stop-map-pin");
  await expect(pin).toHaveCount(1);
  await expect(pin).toBeVisible();

  // The keyboard nudge is the correction: about three feet a press, which is
  // the move an editor makes to put a stop back on the curb it belongs on. The
  // panel's own words for the nudge and the distance agree, so they are what is
  // asserted here.
  await pin.focus();
  await page.keyboard.press("ArrowUp");
  await expect(page.locator("#stops-map-edit-moved")).toContainText(
    /Moved \d+ ft of where it was\./,
  );
  await expect(page.locator("#stops-map-edit-save")).toContainText(
    "Save changes",
  );

  // The ghost and its distance label are drawn by the hook from the pin and the
  // saved position the server echoed, so their presence here is the proof that
  // the pair reaches the browser.
  await expect(page.locator(".stop-map-ghost-marker")).toHaveCount(1);
  await expect(page.locator(".stop-map-distance")).toHaveCount(1);

  await captureBoth(page, testInfo, "nudge", "move-nudge-");
  await captureBoth(page, testInfo, "move", "move-");

  // Put it back: the draft returns to the saved position and every other typed
  // field survives, because the editor asked to undo the move, not the edit.
  await page.locator("#stops-map-edit-put-back").click();
  await expect(page.locator("#stops-map-edit-moved")).toHaveCount(0);

  // A drag is the other move: at this zoom a drag is hundreds of metres, which
  // is well past the correction band, so the button is no longer Save — it says
  // what pressing it does.
  await dragPinBy(page, 0, -60);
  await expect(page.locator("#stops-map-edit-save")).toContainText(
    "Review move",
  );

  await captureBoth(page, testInfo, "far", "move-far-");

  await submitEditForm(page);
  await expect(page.locator("#stops-map-move-panel")).toBeAttached();
  await expect(page.locator("#stops-map-move-heading")).toHaveText(
    "Review move",
  );

  // Each pattern that shares the pair is listed with its own outcome, and the
  // lines get the one question that decides whether they are redrawn.
  await expect(page.locator("#stops-map-move-patterns li")).not.toHaveCount(0);
  await expect(page.locator("#stops-map-move-patterns")).toContainText(
    "Will redraw",
  );
  await expect(page.locator("#stops-map-move-also")).toContainText(
    "weekday trips",
  );

  await captureBoth(page, testInfo, "review", "move-review-");

  // The far question has no default, and the review says why it is being asked.
  await expect(
    page.locator("#stops-map-move-far input[type='radio']:checked"),
  ).toHaveCount(0);
  await expect(page.locator("#stops-map-move-far")).toContainText(
    "Is this the same stop?",
  );

  // A click on the panel's own submit button does not reach the server from this
  // harness, so the review states are reached by asking the form to submit
  // itself. The save outcomes are covered by stops_map_move_test.exs instead.
  await page.locator("#stops-map-move-back").click();
  await expect(page.locator("#stops-map-edit-panel")).toBeAttached();

  await captureReference(page, testInfo, "move", "move", "move-ref-");
  await captureReference(
    page,
    testInfo,
    "move-far-review",
    "far-review",
    "move-ref-",
  );
  await captureReference(page, testInfo, "move-review", "review", "move-ref-");
});

test("deleting a stop @delete", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  // A stop the feed serves: the answer is a refusal, and the refusal names
  // every dependent rather than counting them.
  await page.goto(`/gtfs/${versionId}/stops/map?stop=1434`);
  await waitForLiveView(page);
  await waitForMapReady(page);

  await page.locator("#stops-map-edit-more").click();
  await expect(page.locator("#stops-map-edit-more-menu")).toBeAttached();
  await expect(page.locator("#stops-map-edit-delete")).toContainText(
    "Delete stop",
  );
  await capture(page, testInfo, "delete-menu-desktop");

  await page.locator("#stops-map-edit-delete").click();
  await expect(page.locator("#stops-map-delete-panel")).toBeAttached();
  await expect(page.locator("#stops-map-delete-heading")).toHaveText(
    "Can\u2019t delete US 101 & SE 1st St yet",
  );
  // The seed's patterns carry no weekday trips, so the message names the
  // patterns rather than a service count; the ExUnit cases cover the figure.
  await expect(page.locator("#stops-map-delete-blocked-message")).toContainText(
    "2 patterns stop here",
  );

  // Every dependent is named, and the ones that live somewhere else link to it.
  await expect(
    page.locator("#stops-map-delete-blocked-list li"),
  ).not.toHaveCount(0);
  await expect(page.locator("#stops-map-delete-blocked-list")).toContainText(
    "toward Lincoln City",
  );
  await expect(
    page.locator("[id^='stops-map-delete-blocked-run-']"),
  ).toHaveCount(1);
  await expect(
    page.locator("[id^='stops-map-delete-open-pattern-']").first(),
  ).toBeAttached();

  // A refusal has no primary action: there is nothing here to press that would
  // delete anything.
  await expect(page.locator("#stops-map-delete-go")).toHaveCount(0);
  await expect(page.locator("#stops-map-delete-keep")).toHaveText(
    "Back to stop",
  );

  await captureBoth(page, testInfo, "blocked", "delete-");
  await captureReference(
    page,
    testInfo,
    "delete-blocked",
    "blocked",
    "delete-ref-",
  );

  // A stop nothing uses: the answer is a confirmation, and it names the rows
  // that go with it.
  await page.goto(`/gtfs/${versionId}/stops/map?stop=1531`);
  await waitForLiveView(page);
  await expect(page.locator("#stops-map-edit-panel")).toContainText(
    "Not served",
  );

  await page.locator("#stops-map-edit-more").click();
  await page.locator("#stops-map-edit-delete").click();
  await expect(page.locator("#stops-map-delete-panel")).toBeAttached();
  await expect(page.locator("#stops-map-delete-heading")).toHaveText(
    "Delete SE Bay Blvd & SE Moore Dr?",
  );
  await expect(page.locator("#stops-map-delete-clear")).toContainText(
    "No pattern or trip stops here",
  );
  await expect(page.locator("#stops-map-delete-removed")).toContainText(
    "Spanish name",
  );
  await expect(page.locator("#stops-map-delete-go")).toContainText(
    "Delete stop",
  );

  await captureBoth(page, testInfo, "confirm", "delete-");

  // Keeping the stop writes nothing and returns to the form. The reference
  // captures come last because they leave the page on the prototype file.
  await page.locator("#stops-map-delete-keep").click();
  await expect(page.locator("#stops-map-edit-panel")).toBeAttached();
  await expect(page.locator("#stops-map-delete-panel")).toHaveCount(0);

  await captureReference(
    page,
    testInfo,
    "delete-confirm",
    "confirm",
    "delete-ref-",
  );
});

test("replacing a stop @replace", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  await page.goto(`/gtfs/${versionId}/stops/map?stop=1433`);
  await waitForLiveView(page);
  await waitForMapReady(page);

  await page.locator("#stops-map-edit-more").click();
  await page.locator("#stops-map-edit-replace").click();

  await expect(page.locator("#stops-map-replace-panel")).toBeAttached();
  await expect(page.locator("#stops-map-replace-heading")).toHaveText(
    "Replace US 101 & SE 1st St",
  );

  // The candidates are the nearest stops within a walk of each other, and in
  // this seed only one other stop is: 1434, the pair the checks list already
  // reports as 5 ft apart. Everything else in the version is further away than
  // a rider would call the same place, so it is not offered.
  await expect(page.locator("#stops-map-replace-candidates label")).toHaveCount(
    1,
  );
  await expect(page.locator("#stops-map-replace-candidate-1434")).toContainText(
    "5 ft away",
  );
  await expect(
    page.locator("#stops-map-replace-candidate-1434 input[type=radio]"),
  ).toBeChecked();

  // The panel opens on an answer, so the review below it is about a real pair.
  // Each pattern is a sentence rather than a count: which route, which way, and
  // what moves. The rest of the kinds are one line each with their row count.
  await expect(page.locator("#stops-map-replace-changes")).toContainText(
    "toward Newport Transit Center stops at US 101 & SE 1st St instead.",
  );
  await expect(page.locator("#stops-map-replace-changes")).toContainText(
    "Map line sections",
  );
  await expect(page.locator("#stops-map-replace-go")).toContainText(
    "Replace in 1 pattern",
  );

  // The map's own caption changes with the question it is being asked.
  await expect(page.locator("#stops-map-caption")).toContainText(
    "Choose the stop to keep",
  );

  await captureBoth(page, testInfo, "review", "replace-");

  // Cancelling writes nothing and returns to the form.
  await page.locator("#stops-map-replace-cancel").click();
  await expect(page.locator("#stops-map-edit-panel")).toBeAttached();
  await expect(page.locator("#stops-map-replace-panel")).toHaveCount(0);

  await captureReference(page, testInfo, "replace", "review", "replace-ref-");
});

test("making a stop a station @station", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  await page.goto(`/gtfs/${versionId}/stops/map?stop=1433`);
  await waitForLiveView(page);
  await waitForMapReady(page);

  await page.locator("#stops-map-edit-more").click();
  await page.locator("#stops-map-edit-station").click();

  await expect(page.locator("#stops-map-station-panel")).toBeAttached();
  await expect(page.locator("#stops-map-station-heading")).toHaveText(
    "Make US 101 & SE 1st St a station",
  );

  // The name the editor has to agree with or change, never to supply from
  // nothing, and the reason they can agree to it: the stop keeps its ID.
  await expect(page.locator("#stops-map-station-bay")).toHaveValue("A");
  await expect(page.locator("#stops-map-station-keeps")).toContainText(
    "keeps ID 1433",
  );

  // The seed's amenity is 42 m from the point, so it is suggested and it
  // pre-fills the field the editor has not typed in — and the
  // suggestion says it came from a landmark, so an editor can see it is one and
  // not the answer. The name field itself keeps the stop's own name until the
  // editor takes the suggestion: a suggestion that silently overwrites what was
  // typed would be an edit nobody made.
  await expect(page.locator("#stops-map-station-landmark")).toContainText(
    "Suggested from the nearest landmark",
  );
  await expect(page.locator("#stops-map-station-landmark")).toContainText(
    "Cedar Valley Transit Center",
  );
  await expect(page.locator("#stops-map-station-name")).toHaveValue(
    "Cedar Valley Transit Center",
  );

  // The panel is the journey's subject; the write it makes is proven in ExUnit,
  // which reads the station and the bay back out of the rows.
  await captureBoth(page, testInfo, "panel", "station-panel-");
  await captureReference(
    page,
    testInfo,
    "make-station",
    "panel",
    "station-ref-",
  );
});

// A pointer drag on the pin. The hook reports one move per gesture, on pointer
// up, so the drag is a down, a move and a release — never a click.
async function dragPinBy(page, dx, dy) {
  const box = await page.locator(".stop-map-pin").boundingBox();

  if (!box) throw new Error("the map drew no pin to drag");

  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;

  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + dx, y + dy, { steps: 6 });
  await page.mouse.up();
}

// The form asked to submit itself. `requestSubmit` fires the same submit event
// the button would; it is here because the button click does not reach the
// server from this harness (a known limit of the harness), not because the panel
// needs it.
async function submitEditForm(page) {
  await page
    .locator("#stops-map-edit-form")
    .evaluate((form) => form.requestSubmit());
}

// A mark the reader can see. Leaflet keeps a marker for every stop in the
// version, including the ones outside the window, so the first in the DOM is
// often somewhere a click cannot reach: this is the first one whose own box is
// inside the map's box.
async function onMapMarkerBox(page) {
  return page.evaluate(() => {
    const map = document.querySelector("#stop-map").getBoundingClientRect();
    const marks = [
      ...document.querySelectorAll("#stop-map .stop-map-marker"),
    ].map((mark) => mark.getBoundingClientRect());

    const rect = marks.find(
      (candidate) =>
        candidate.width > 0 &&
        candidate.left >= map.left &&
        candidate.right <= map.right &&
        candidate.top >= map.top &&
        candidate.bottom <= map.bottom,
    );

    if (!rect) throw new Error("the map drew no stop mark inside the window");

    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  });
}

// ── list entry points ──────────────────────────────────────────────────────

// The list's own header is where an editor who is not on the map reaches the
// map. The switch says which view is being looked at, and the Add stop primary
// carries `?add=1`, so the Map view opens straight into the placement flow
// rather than at a browse panel an editor has to start from.
test("the list's map entry points @list", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  await page.goto(`/gtfs/${versionId}/stops`);
  await waitForLiveView(page);

  await expect(page.locator("#stops-page")).toBeAttached();
  await expect(page.locator("#stops-view-list")).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.locator("#stops-view-map")).toHaveText("Map");
  await expect(page.locator("#stops-view-map")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/stops/map`,
  );
  await expect(page.locator("#stops-add-stop")).toHaveText("Add stop");
  await expect(page.locator("#stops-add-stop")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/stops/map?add=1`,
  );
  await expect(page.locator("#stops-add-stop-note")).toContainText(
    "Add stop opens the map",
  );

  await captureBoth(page, testInfo, "header", "list-");

  // The reference is a file:// page, so the production route is reopened
  // before the entry point is followed.
  await captureReference(page, testInfo, "list", "header", "list-ref-");

  await page.goto(`/gtfs/${versionId}/stops`);
  await waitForLiveView(page);

  // The Add stop primary lands on the add panel, not on the browse panel: the
  // link's whole claim is that placing a stop starts from the place.
  await page.locator("#stops-add-stop").click();
  await waitForLiveView(page);
  await waitForMapReady(page);

  await expect(page.locator("#stops-map-add-panel")).toBeAttached();

  // The map asks for a place, not for a name: the caption is the mode the
  // panel asked for.
  await expect(page.locator("#stops-map-caption")).toContainText(
    "Click the curb",
  );
});

// A version with no stops offers the same entry point from the first-use state,
// where an editor who has neither a feed nor a stop needs one of the two.
test("the list's first-use state @list", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);

  // The seed's second version for this organization is published and has no
  // stops, so the first-use state is a page an editor can actually open.
  const versionId = await versionIdByName(page, EMPTY_VERSION_NAME);

  await page.goto(`/gtfs/${versionId}/stops`);
  await waitForLiveView(page);

  await captureBoth(page, testInfo, "first-use", "list-");

  // One primary per view: Add stop is the filled button and Import feed is the
  // outlined one beside it.
  await page.goto(`/gtfs/${versionId}/stops`);
  await waitForLiveView(page);
  await expect(page.locator("#stops-first-use-empty")).toBeVisible();
  await expect(page.locator("#stops-first-use-add-stop")).toHaveClass(
    /btn-primary/,
  );
  await expect(page.locator("#stops-first-use-add-stop")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/stops/map?add=1`,
  );
  await expect(page.locator("#stops-first-use-import")).toHaveClass(
    /btn-outline/,
  );

  // The header's own switch and primary stay in this state too, so an editor
  // who scrolls past the empty card still has both ways onward.
  await expect(page.locator("#stops-view-map")).toBeVisible();
  await expect(page.locator("#stops-add-stop")).toBeVisible();

  await captureReference(page, testInfo, "list", "first-use", "list-ref-");
});

// ── detail entry points ────────────────────────────────────────────────────

// The stop page is where an editor already is, so it carries the entry points
// into the Map view's three non-edit operations. This asserts the links are the
// requests they claim to be: each carries the action, and following one opens
// that panel rather than the browse panel.
test("the stop page's entry points @detail", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  await page.goto(`/gtfs/${versionId}/stops/1434`);
  await waitForLiveView(page);

  await expect(page.locator("#stop-detail-page")).toBeAttached();
  await expect(page.locator("#station-title")).toHaveText("US 101 & SE 1st St");

  await expect(page.locator("#edit-stop")).toContainText("Edit stop");
  await expect(page.locator("#edit-stop")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/stops/map?stop=1434`,
  );

  // The More actions menu is a <details>, so it opens with the click a person
  // makes and works without JavaScript.
  await page.locator("#stop-more-actions summary").click();
  await expect(page.locator("#stop-action-make-station")).toBeAttached();
  await expect(page.locator("#stop-action-replace")).toBeAttached();
  await expect(page.locator("#stop-action-delete")).toBeAttached();

  await expect(page.locator("#stop-action-delete")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/stops/map?stop=1434&action=delete`,
  );

  await captureBoth(page, testInfo, "stop", "detail-");
  await captureReference(page, testInfo, "detail", "stop", "detail-ref-");

  // A following link lands on the panel the link asked for, not on the browse
  // panel an editor would then have to find the operation in again.
  await page.goto(`/gtfs/${versionId}/stops/1434`);
  await waitForLiveView(page);
  await page.locator("#stop-more-actions summary").click();
  await page.locator("#stop-action-delete").click();
  await waitForLiveView(page);

  await expect(page.locator("#stops-map-delete-panel")).toBeAttached();
  await capture(page, testInfo, "detail-action-delete-desktop");
});

// A station keeps Open floorplans as its one primary; the map is beside it.
test("the station page's entry points @detail", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  await page.goto(`/gtfs/${versionId}/stops/ST-NTC`);
  await waitForLiveView(page);

  await expect(page.locator("#station-title")).toHaveText(
    "Newport Transit Center",
  );
  await expect(page.locator("#open-floorplans")).toContainText(
    "Open floorplans",
  );
  await expect(page.locator("#station-edit-on-map")).toContainText(
    "Edit on map",
  );
  await expect(page.locator("#station-edit-on-map")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/stops/map?stop=ST-NTC`,
  );

  // A station's own point is not where riders wait, so it has no More actions
  // and no Move on map.
  await expect(page.locator("#stop-more-actions")).toHaveCount(0);
  await expect(page.locator("#move-on-map")).toHaveCount(0);

  await captureBoth(page, testInfo, "station", "detail-");
});

// The usage card: what names this stop, and where each of those places is
// edited. The read is asynchronous, so the card is captured after it lands.
test("where this stop is used @detail", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  await page.goto(`/gtfs/${versionId}/stops/1434`);
  await waitForLiveView(page);

  // 1531 is the seed's unserved stop, so the card's empty answer is a real
  // page rather than a state that cannot be opened.
  await page.goto(`/gtfs/${versionId}/stops/1531`);
  await waitForLiveView(page);

  await expect(page.locator("#usage-card")).toBeVisible();
  await expect(page.locator("#usage-patterns-none")).toHaveText(
    "No route serves this stop.",
  );

  // 1433 is the other duplicate, and it is the stop the southbound pattern
  // actually calls at.
  await page.goto(`/gtfs/${versionId}/stops/1433`);
  await waitForLiveView(page);
  await expect(page.locator("#usage-patterns")).toBeAttached();
  await expect(page.locator("#usage-weekday-trips")).toBeAttached();

  await captureBoth(page, testInfo, "usage", "detail-");
  await captureReference(page, testInfo, "detail", "usage", "detail-ref-");
});

// ── the whole job, in one session ──────────────────────────────────────────

// One test that does the five things this spec exists for, in the order a
// person does them: put a stop on the map, put it on a route, move it, find out
// why it cannot be deleted, and replace a duplicate. Each step is covered on
// its own above; what this adds is the seams — that the stop created at the
// start is the stop the pattern editor stages at the second, that coming back
// from the pattern editor leaves the map where it was, and that a move, a
// refusal and a replacement all describe the same two stops 5 ft apart.
test("from a curb to a route @journey", async ({ page }, testInfo) => {
  test.setTimeout(900_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);

  // 1 · Put a stop on the map. The click lands on the northbound line and the
  // streets name it, which is the only way in this spec asks an editor to make:
  // two coordinates typed by hand are a copy of the feed's job, not a new
  // feature.
  await openMap(page, versionId);
  await waitForMapReady(page);
  await zoom(page, 3);
  await waitForMapReady(page);

  await page.locator("#stops-map-add-stop").click();
  await clickOnLine(page);
  await expect(page.locator("#stops-map-add-name")).toHaveValue("Depot Road", {
    timeout: 30_000,
  });

  await page.locator("#stops-map-add-create").click();
  await expect(page.locator("#stops-map-created-panel")).toContainText(
    "Stop created",
  );

  // 2 · Put it on a route. The panel lists the patterns this point passes, each
  // with the two stops the new one would fall between, and the link carries
  // this stop — so following it opens the editor with the stop already in hand
  // rather than asking which one this was.
  const patterns = page.locator("#stops-map-created-patterns li");
  await expect(patterns.first()).toContainText("Between ");
  const href = await patterns.first().locator("a").getAttribute("href");
  expect(href).toMatch(/\?task=stops&add_stop=\d+$/);

  await captureBoth(page, testInfo, "created", "journey-");
  await patterns.first().locator("a").click();

  await waitForLiveView(page);
  await expect(page.locator("#pattern-stops")).toBeAttached();

  // The staged row is dashed and badged "New · unsaved": staged is not saved,
  // and the list says which of the two this is. Its position is the one its own
  // coordinates imply — the two neighbours the created panel named — and not
  // the end of the route, which is what a link that merely appended would give.
  const staged = page.locator("#pattern-stops li", {
    hasText: "Depot Road",
  });
  await expect(staged).toHaveCount(1);
  await expect(staged).toContainText("New · unsaved");
  await expect(page.locator("#pattern-stops")).toHaveAttribute(
    "data-dirty",
    "true",
  );

  const names = await page
    .locator("#pattern-stops li span.text-sm.font-semibold")
    .allTextContents();
  const at = names.findIndex((name) => name === "Depot Road");
  expect(at).toBeGreaterThan(0);
  expect(at).toBeLessThan(names.length - 1);

  await captureBoth(page, testInfo, "staged", "journey-");

  // The rest of the job is about stops the feed brought, so the journey goes
  // back to the map and selects them by the parameter the list and the stop
  // page both use.
  await page.goto(`/gtfs/${versionId}/stops/map?stop=1434`);
  await waitForLiveView(page);
  await waitForMapReady(page);
  await expect(page.locator("#stops-map-edit-panel")).toBeAttached();

  // 3 · Move it. The nudge is a correction rather than a different place —
  // the band below which a move is a fix, not a question — so the button is
  // still Save changes. A pixel drag cannot name a metre at a fitted zoom (the
  // band is 8 m and the journey's own first drag overshot it), so the
  // correction is driven by the keyboard, and the far drag below is the one
  // that asks the question.
  const pin = page.locator(".stop-map-pin");
  await expect(pin).toHaveCount(1);

  await pin.focus();
  await page.keyboard.press("ArrowUp");
  await expect(page.locator("#stops-map-edit-moved")).toContainText(
    /Moved \d+ ft of where it was\./,
  );
  await expect(page.locator("#stops-map-edit-save")).toContainText(
    "Save changes",
  );
  await expect(page.locator(".stop-map-ghost-marker")).toHaveCount(1);
  await expect(page.locator(".stop-map-distance")).toHaveCount(1);

  // A click on a panel submit button does not reach the server from this
  // harness, so the review state is reached by asking the form to submit
  // itself. The write itself, and the
  // out-of-date message the save produces, are the ExUnit claim in
  // stops_map_move_test.exs; what this journey proves is that the review is
  // reachable from the same panel the journey arrived on.
  await dragPinBy(page, 0, -60);
  await expect(page.locator("#stops-map-edit-save")).toContainText(
    "Review move",
  );
  await submitEditForm(page);

  await expect(page.locator("#stops-map-move-panel")).toBeAttached();
  await expect(page.locator("#stops-map-move-patterns")).toContainText(
    "Will redraw",
  );
  await captureBoth(page, testInfo, "move-review", "journey-");
  await page.locator("#stops-map-move-back").click();

  // 4 · Find out why it cannot be deleted. The unsaved far drag is still on the
  // form, so the way out of it is asked before anything else is — the same
  // guard every other way off this panel goes through. Keeping the draft
  // leaves the panel exactly as it was, which is the answer worth checking
  // here: an editor who came back to find their drag still there has lost
  // nothing.
  await page.locator("#stops-map-edit-more").click();
  await expect(page.locator("#stops-map-edit-more-menu")).toBeAttached();
  await page.locator("#stops-map-edit-delete").click();
  await expect(page.locator("#stops-map-discard")).toBeAttached();
  await expect(page.locator("#stops-map-discard")).toHaveAttribute(
    "data-open",
    "true",
  );
  await expect(page.locator("#stops-map-discard")).toContainText(
    "Discard changes to US 101 & SE 1st St?",
  );
  await captureBoth(page, testInfo, "guard", "journey-");

  await page.locator("#stops-map-discard-keep").click();
  await expect(page.locator("#stops-map-discard")).toHaveAttribute(
    "data-open",
    "false",
  );
  await expect(page.locator("#stops-map-edit-panel")).toBeAttached();
  await expect(page.locator("#stops-map-edit-moved")).toBeAttached();

  // Leaving the panel is the same question, and Discard changes is what
  // carries it out. The page is reloaded rather than the menu re-opened: the
  // second open of this menu inside one journey repeatedly detaches the item
  // under the click, which is a harness artefact and not a claim worth making.
  await page.locator("#stops-map-edit-cancel").click();
  await expect(page.locator("#stops-map-discard")).toHaveAttribute(
    "data-open",
    "true",
  );
  await page.locator("#stops-map-discard-go").click();
  await expect(page.locator("#stops-map-panel")).toBeAttached();

  await page.goto(`/gtfs/${versionId}/stops/map?stop=1434`);
  await waitForLiveView(page);
  await waitForMapReady(page);
  await page.locator("#stops-map-edit-more").click();
  await expect(page.locator("#stops-map-edit-more-menu")).toBeAttached();
  await page.locator("#stops-map-edit-delete").click();
  await expect(page.locator("#stops-map-delete-panel")).toBeAttached();
  await expect(page.locator("#stops-map-delete-heading")).toHaveText(
    "Can\u2019t delete US 101 & SE 1st St yet",
  );
  await expect(
    page.locator("#stops-map-delete-blocked-list li"),
  ).not.toHaveCount(0);
  await expect(page.locator("#stops-map-delete-go")).toHaveCount(0);
  await captureBoth(page, testInfo, "delete-blocked", "journey-");
  await page.locator("#stops-map-delete-keep").click();

  // 5 · Replace its duplicate. The pair is the same place 5 ft apart, so the
  // panel offers exactly one candidate, the route's own sentence says which
  // pattern stops where instead, and the answer is a count of the writes.
  await page.goto(`/gtfs/${versionId}/stops/map?stop=1433`);
  await waitForLiveView(page);
  await waitForMapReady(page);
  await page.locator("#stops-map-edit-more").click();
  await expect(page.locator("#stops-map-edit-more-menu")).toBeAttached();
  await page.locator("#stops-map-edit-replace").click();

  await expect(page.locator("#stops-map-replace-candidates label")).toHaveCount(
    1,
  );
  await expect(
    page.locator("#stops-map-replace-candidate-1434 input[type=radio]"),
  ).toBeChecked();
  await expect(page.locator("#stops-map-replace-changes")).toContainText(
    "instead.",
  );
  await expect(page.locator("#stops-map-replace-go")).toContainText(
    "Replace in 1 pattern",
  );
  await captureBoth(page, testInfo, "replace", "journey-");

  // The replacement write is covered by stops_map_replace_test.exs; the journey
  // ends on the review, which is the last state a person sees before deciding.
  await page.locator("#stops-map-replace-cancel").click();
  await expect(page.locator("#stops-map-edit-panel")).toBeAttached();

  await captureReference(
    page,
    testInfo,
    "journey-staged",
    "staged",
    "journey-ref-",
  );
});
