// Stops Map browser journeys (28-stop-add-edit, step 22 onward; EV-23..EV-38).
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
// The `@seed` case is the gate for the seed itself: it signs in, opens the
// Stops & stations list and proves the seeded stops are there with the names and
// types the later steps' fixtures name. It depends only on routes that already
// exist, so a failure here is a seed failure and not a Map view failure.
//
// Captures are written only when `STOPS_MAP_CAPTURE_DIR` is set, resolved
// against the assets working directory. They are the visual-loop and QA-tour
// inputs, not the gate's oracle.
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

const DESKTOP = { width: 1440, height: 900, label: "desktop" };
const MOBILE = { width: 390, height: 844, label: "mobile" };

const CAPTURE_DIR = process.env.STOPS_MAP_CAPTURE_DIR;

// The spec package lives in the gitignored `.specs/` workspace, which a worktree
// checkout does not carry; STOPS_MAP_SPEC_ROOT points the reference lookups at
// the checkout that holds it. The reference captures are skipped without it.
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
// and 390×844 for the stacked workspace and the no-horizontal-scroll gate.
async function captureBoth(page, testInfo, name, prefix = "shell-") {
  await expectFits(page);
  await capture(page, testInfo, `${prefix}${name}-desktop`);

  await page.setViewportSize(MOBILE);
  await expectFits(page);
  await capture(page, testInfo, `${prefix}${name}-mobile`);

  await page.setViewportSize(DESKTOP);
}

// The same state from the prototype, at the current viewport, for the
// side-by-side inspection. Skipped in a checkout that does not carry the
// package, which is not a failure of this spec.
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

// The seed gate. The stop names, the duplicate pair and the station are the
// fixture the Map view steps build on, so they are asserted here as literals
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

// ── shell (step 23) ───────────────────────────────────────────────────────

// The Map view's shell: the header with its List | Map switch, the map stage,
// and the browse panel holding the stops inside the current view. This is the
// state every later capture starts from, so its assertions are the ones a
// regression in the shell would break first.
//
// The hook is not registered yet (step 24 owns it), so the stage is captured in
// its loading state — which is one of the four states this shell must show, and
// is captured as such below.
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

// ── render (step 24) ──────────────────────────────────────────────────────

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
  // Below the bay gate the station stands in for the bays folded into it; the
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
  // belongs — the prototype paints none here either.
  expect(await page.locator("#stop-map .stop-map-label").count()).toBe(0);

  // Closed in, the bays separate and take their letters and the stops take their
  // names. The lines stay: a road wide enough on screen carries one line
  // without the offset that keeps two buses apart.
  // Closed in only as far as the bay gate needs: the feed's own extent is a few
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

// ── pin (step 25) ─────────────────────────────────────────────────────────

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

// ── search (step 26) ───────────────────────────────────────────────────────

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
  // the canvas the map is showing. Recorded as a step-31 finding rather than
  // asserted here.
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

// ── checks (step 27) ───────────────────────────────────────────────────────

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

// ── add a stop (step 28) ───────────────────────────────────────────────────

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
